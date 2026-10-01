import argparse
import glob
import logging
import os
import subprocess
import urllib.parse
from argparse import ArgumentParser, Namespace
from asyncio import TaskGroup

import requests
from auth.auth import GitlabAuth
from config import config
from core.task import task
from models.dto import KonfluxStreamResultDTO
from tasks.branching import mtv_version_parts
from tasks.konflux_stream import (
    build_btrfs_pds_block,
    transform_prod_stream,
    transform_rpa,
)
from utils import create_temp_dir
from wrappers.git import Git

DESCRIPTION = (
    "Add a release stream to the Konflux releng repo (post-#53).\n\n"
    "Clones konflux-release-data, then for the new X.Y: renders the prod tenant's\n"
    "operator/streams/<version>.yaml from dev-preview.yaml and registers it in\n"
    "kustomization.yaml, appends the btrfs tenant ProjectDevelopmentStream, and\n"
    "retargets the rh-mtv-1 and rh-mtv-btrfs ReleasePlanAdmissions. Runs\n"
    "build-single.sh (and optionally tox), commits, pushes mtv_add_stream, and\n"
    "opens the merge request via the GitLab API. Dry-run by default; pass --apply."
)

logger = logging.getLogger(__name__)

KONFLUX_HOST = "https://gitlab.cee.redhat.com"
KONFLUX_PROJECT_PATH = "releng/konflux-release-data"
KONFLUX_REPO = f"{KONFLUX_HOST}/{KONFLUX_PROJECT_PATH}.git"
STREAM_BRANCH = "mtv_add_stream"
MR_TARGET_BRANCH = "main"

PROD_OPERATOR_DIR = (
    "tenants-config/cluster/stone-prd-rh01/tenants/rh-mtv-1-tenant/operator"
)
BTRFS_STREAMS = (
    "tenants-config/cluster/stone-prod-p02/tenants/"
    "rh-mtv-btrfs-tenant/streams.yaml"
)
RH_MTV_1_RPA_DIR = (
    "config/stone-prd-rh01.pg1f.p1/product/ReleasePlanAdmission/rh-mtv-1"
)
RH_MTV_BTRFS_RPA_DIR = (
    "config/stone-prod-p02.hjvn.p1/product/ReleasePlanAdmission/rh-mtv-btrfs"
)


def arg_parse(arg_parser: ArgumentParser):
    arg_parser.formatter_class = argparse.RawTextHelpFormatter
    arg_parser.add_argument(
        "version",
        help="[required] Global version, format x.y.z (e.g. 2.11.0).",
    )
    arg_parser.add_argument(
        "--registry",
        metavar="REGISTRY",
        help="[optional] Registry to retarget RPAs to (default: the release namespace from config).",
    )
    arg_parser.add_argument(
        "--run-tox",
        dest="run_tox",
        action="store_true",
        default=False,
        help="[optional] Run the konflux repo's tox suite (~5 min) before pushing.",
    )
    arg_parser.add_argument(
        "--apply",
        action="store_true",
        default=False,
        help="[optional] Run build-single.sh, commit, and push. Without it, dry-run only.",
    )


def _append_text(path: str, text: str) -> None:
    """Append text, inserting a newline first if the file lacks a trailing one."""
    content = ""
    if os.path.exists(path):
        with open(path) as f:
            content = f.read()
    if content and not content.endswith("\n"):
        content += "\n"
    with open(path, "w") as f:
        f.write(content + text)


def _create_konflux_mr(token: str, title: str, description: str) -> str:
    """Open the mtv_add_stream -> main MR via the GitLab API; '' on failure.

    Non-fatal: the branch is already pushed, so a failure here (e.g. a token
    without `api` scope, or an MR that already exists) just means opening it by
    hand. Internal GitLab serves a self-signed chain, hence verify=False.
    """
    project = urllib.parse.quote_plus(KONFLUX_PROJECT_PATH)
    url = f"{KONFLUX_HOST}/api/v4/projects/{project}/merge_requests"
    resp = requests.post(
        url,
        headers={"PRIVATE-TOKEN": token},
        data={
            "source_branch": STREAM_BRANCH,
            "target_branch": MR_TARGET_BRANCH,
            "title": title,
            "description": description,
            "remove_source_branch": "true",
        },
        verify=False,
    )
    if resp.status_code in (200, 201):
        return resp.json().get("web_url", "")
    raise RuntimeError(f"GitLab MR create failed ({resp.status_code}): {resp.text[:200]}")


def _process_rpa_dir(
    base_dir: str, prefix: str, version_name: str, registry: str, xy: str
) -> int:
    """Copy+retarget dev-preview RPAs to version_name for stage and prod."""
    count = 0
    for variant in ("stage", "prod"):
        pattern = os.path.join(base_dir, f"{prefix}-{variant}-dev-preview-*")
        for src in sorted(glob.glob(pattern)):
            dst = os.path.join(
                base_dir,
                os.path.basename(src).replace("dev-preview", version_name),
            )
            with open(src) as f:
                content = f.read()
            with open(dst, "w") as f:
                f.write(transform_rpa(content, version_name, registry, xy))
            count += 1
    return count


@task
async def add_stream(
    data, args: Namespace, tg: TaskGroup
) -> KonfluxStreamResultDTO:
    dry_run = not args.apply
    try:
        xy, version_name = mtv_version_parts(args.version)
    except ValueError as e:
        return KonfluxStreamResultDTO(
            version=args.version,
            version_name="",
            dry_run=dry_run,
            skipped=True,
            skip_reason=f"Invalid version '{args.version}': {e}",
        )

    registry = args.registry or config.get_release_namespace()

    try:
        gitlab_auth = GitlabAuth()
        clone_url = gitlab_auth.authenticated_url(KONFLUX_REPO)
    except ValueError as e:
        return KonfluxStreamResultDTO(
            version=args.version,
            version_name=version_name,
            dry_run=dry_run,
            skipped=True,
            skip_reason=str(e),
        )

    logger.info(
        {
            "msg": "Starting konflux stream add",
            "version": args.version,
            "version_name": version_name,
            "dry_run": dry_run,
        }
    )

    # Internal GitLab serves a self-signed chain; the btrfs_sync pipeline
    # disables verification the same way for this host.
    os.environ["GIT_SSL_NO_VERIFY"] = "true"

    tmp_dir = create_temp_dir(f"konflux-stream-{version_name}")
    git = Git(tmp_dir.name)
    await git.clone(clone_url, depth=1)
    git.config("http.sslVerify", "false")
    git.config("user.email", config.get_git_email())
    git.config("user.name", config.get_git_name())
    git.checkout(STREAM_BRANCH, create=True)

    root = tmp_dir.name

    # Prod tenant (rh-mtv-1): render operator/streams/<version>.yaml from
    # dev-preview.yaml and register it in kustomization.yaml.
    dev_preview = os.path.join(root, PROD_OPERATOR_DIR, "dev-preview.yaml")
    prod_stream_rel = os.path.join(
        PROD_OPERATOR_DIR, "streams", f"{version_name}.yaml"
    )
    prod_stream = os.path.join(root, prod_stream_rel)
    if not os.path.exists(dev_preview):
        return KonfluxStreamResultDTO(
            version=args.version,
            version_name=version_name,
            dry_run=dry_run,
            skipped=True,
            skip_reason=f"dev-preview.yaml not found at {PROD_OPERATOR_DIR}",
        )
    with open(dev_preview) as f:
        content = f.read()
    with open(prod_stream, "w") as f:
        f.write(transform_prod_stream(content, version_name, xy))
    _append_text(
        os.path.join(root, PROD_OPERATOR_DIR, "streams", "kustomization.yaml"),
        f"  - {version_name}.yaml\n",
    )

    # BTRFS tenant (rh-mtv-btrfs): still uses a ProjectDevelopmentStream append.
    _append_text(
        os.path.join(root, BTRFS_STREAMS),
        build_btrfs_pds_block(version_name, xy),
    )

    # ReleasePlanAdmissions for both tenants.
    rpa_count = _process_rpa_dir(
        os.path.join(root, RH_MTV_1_RPA_DIR),
        "forklift-operator-rpa",
        version_name,
        registry,
        xy,
    )
    rpa_count += _process_rpa_dir(
        os.path.join(root, RH_MTV_BTRFS_RPA_DIR),
        "forklift-operator-int-rpa",
        version_name,
        registry,
        xy,
    )

    if dry_run:
        logger.info(
            {
                "msg": "Dry-run: prepared stream files (not building/pushing)",
                "version": args.version,
                "prod_stream_file": prod_stream_rel,
                "rpa_files_created": rpa_count,
                "branch": STREAM_BRANCH,
            }
        )
        return KonfluxStreamResultDTO(
            version=args.version,
            version_name=version_name,
            branch=STREAM_BRANCH,
            prod_stream_file=prod_stream_rel,
            btrfs_updated=True,
            rpa_files_created=rpa_count,
            dry_run=True,
        )

    for tenant in ("rh-mtv-1", "rh-mtv-btrfs"):
        logger.info(f"Building manifests for {tenant}")
        subprocess.run(
            ["bash", "tenants-config/build-single.sh", tenant],
            cwd=root,
            check=True,
        )

    if args.run_tox:
        logger.info("Running tox (required by the konflux repo to merge)")
        result = subprocess.run(["tox"], cwd=root)
        if result.returncode != 0:
            return KonfluxStreamResultDTO(
                version=args.version,
                version_name=version_name,
                branch=STREAM_BRANCH,
                prod_stream_file=prod_stream_rel,
                btrfs_updated=True,
                rpa_files_created=rpa_count,
                skipped=True,
                skip_reason=f"tox failed; fix and push manually from {root}",
            )

    title = f"MTV: Add new PDS for {xy}"
    git.add_paths(["config", "tenants-config"])
    git.commit(title)
    git.push(branch=STREAM_BRANCH)

    mr_url = ""
    try:
        mr_url = _create_konflux_mr(
            gitlab_auth.token,
            title=title,
            description=(
                f"Add the {version_name} release stream (prod rendered manifest, "
                "btrfs ProjectDevelopmentStream, and ReleasePlanAdmissions).\n\n"
                "Automated via the mtv-releng konflux_stream pipeline."
            ),
        )
        logger.info({"msg": "MR created", "mr_url": mr_url})
    except RuntimeError as e:
        logger.warning(
            f"Could not auto-create MR ({e}); push succeeded, open it manually "
            f"at {KONFLUX_HOST}/{KONFLUX_PROJECT_PATH}/-/merge_requests/new"
        )

    return KonfluxStreamResultDTO(
        version=args.version,
        version_name=version_name,
        branch=STREAM_BRANCH,
        prod_stream_file=prod_stream_rel,
        btrfs_updated=True,
        rpa_files_created=rpa_count,
        pushed=True,
        mr_url=mr_url,
    )
