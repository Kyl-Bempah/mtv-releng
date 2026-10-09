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


def arg_parse(arg_parser: ArgumentParser):
    arg_parser.formatter_class = argparse.RawTextHelpFormatter
    arg_parser.add_argument(
        "version",
        help="[required] Global version, format x.y.z (e.g. 2.11.0).",
    )
    arg_parser.add_argument(
        "--registry",
        metavar="REGISTRY",
        required=False,
        help="[optional] Registry to retarget RPAs to (default: the release namespace from config).",
    )
    arg_parser.add_argument(
        "--run-tox",
        dest="run_tox",
        action="store_true",
        default=False,
        required=False,
        help="[optional] Run the konflux repo's tox suite (~5 min) before pushing.",
    )
    arg_parser.add_argument(
        "--apply",
        action="store_true",
        default=False,
        required=False,
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
    ks = config.get_konflux_stream()
    t = config.get_timeouts()
    project = urllib.parse.quote_plus(ks["project_path"])
    url = f"{ks['host']}/api/v4/projects/{project}/merge_requests"
    # Trust the internal CA bundle rather than disabling verification (same as
    # wrappers/jenkins.py): the PRIVATE-TOKEN header must not be sent over an
    # unverified connection. If the bundle doesn't cover the host this raises an
    # SSLError, which the caller treats as non-fatal (branch is already pushed).
    resp = requests.post(
        url,
        headers={"PRIVATE-TOKEN": token},
        data={
            "source_branch": ks["stream_branch"],
            "target_branch": ks["mr_target_branch"],
            "title": title,
            "description": description,
            "remove_source_branch": "true",
        },
        verify=config.get_root_cert_path(),
        timeout=(t["gitlab_mr_connect_seconds"], t["gitlab_mr_read_seconds"]),
    )
    if resp.status_code in (200, 201):
        return resp.json().get("web_url", "")
    raise RuntimeError(f"GitLab MR create failed ({resp.status_code}): {resp.text[:200]}")


def _process_rpa_dir(
    base_dir: str,
    prefix: str,
    version_name: str,
    registry: str,
    xy: str,
    marker: str,
    dev_registry: str,
) -> int:
    """Copy+retarget marker RPAs to version_name for stage and prod."""
    count = 0
    for variant in ("stage", "prod"):
        pattern = os.path.join(base_dir, f"{prefix}-{variant}-{marker}-*")
        for src in sorted(glob.glob(pattern)):
            dst = os.path.join(
                base_dir,
                os.path.basename(src).replace(marker, version_name),
            )
            with open(src) as f:
                content = f.read()
            with open(dst, "w") as f:
                f.write(
                    transform_rpa(
                        content, version_name, registry, xy, marker, dev_registry
                    )
                )
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
    ks = config.get_konflux_stream()
    timeouts = config.get_timeouts()
    stream_branch = ks["stream_branch"]
    prod_operator_dir = ks["prod_operator_dir"]
    marker = config.get_dev_preview_marker()
    dev_registry = config.get_dev_preview_namespace()

    try:
        gitlab_auth = GitlabAuth()
        clone_url = gitlab_auth.authenticated_url(
            f"{ks['host']}/{ks['project_path']}.git"
        )
    except ValueError as e:
        # Most commonly GITLAB_TOKEN missing from the env; this pipeline needs it
        # even for a dry-run (it clones the internal GitLab repo up front).
        return KonfluxStreamResultDTO(
            version=args.version,
            version_name=version_name,
            dry_run=dry_run,
            skipped=True,
            skip_reason=f"GitLab auth failed (is GITLAB_TOKEN set?): {e}",
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
    git.checkout(stream_branch, create=True)

    root = tmp_dir.name

    # Prod tenant (rh-mtv-1): render operator/streams/<version>.yaml from
    # the marker manifest (<marker>.yaml) and register it in kustomization.yaml.
    dev_preview = os.path.join(root, prod_operator_dir, f"{marker}.yaml")
    prod_stream_rel = os.path.join(
        prod_operator_dir, "streams", f"{version_name}.yaml"
    )
    prod_stream = os.path.join(root, prod_stream_rel)
    if not os.path.exists(dev_preview):
        return KonfluxStreamResultDTO(
            version=args.version,
            version_name=version_name,
            dry_run=dry_run,
            skipped=True,
            skip_reason=f"{marker}.yaml not found at {prod_operator_dir}",
        )
    with open(dev_preview) as f:
        content = f.read()
    with open(prod_stream, "w") as f:
        f.write(transform_prod_stream(content, version_name, xy, marker))
    _append_text(
        os.path.join(root, prod_operator_dir, "streams", "kustomization.yaml"),
        f"  - {version_name}.yaml\n",
    )

    # BTRFS tenant (rh-mtv-btrfs): still uses a ProjectDevelopmentStream append.
    _append_text(
        os.path.join(root, ks["btrfs_streams"]),
        build_btrfs_pds_block(version_name, xy),
    )

    # ReleasePlanAdmissions for each configured tenant.
    rpa_count = 0
    for tenant in ks["tenants"]:
        rpa_count += _process_rpa_dir(
            os.path.join(root, tenant["rpa_dir"]),
            tenant["rpa_prefix"],
            version_name,
            registry,
            xy,
            marker,
            dev_registry,
        )

    if dry_run:
        logger.info(
            {
                "msg": "Dry-run: prepared stream files (not building/pushing)",
                "version": args.version,
                "prod_stream_file": prod_stream_rel,
                "rpa_files_created": rpa_count,
                "branch": stream_branch,
            }
        )
        return KonfluxStreamResultDTO(
            version=args.version,
            version_name=version_name,
            branch=stream_branch,
            prod_stream_file=prod_stream_rel,
            btrfs_updated=True,
            rpa_files_created=rpa_count,
            dry_run=True,
        )

    for tenant in ks["tenants"]:
        build_name = tenant["build_name"]
        logger.info(f"Building manifests for {build_name}")
        # Capture output: build-single.sh needs the konflux toolchain (kustomize,
        # etc.) which this image may not carry; surface its error instead of a
        # bare non-zero exit, and skip rather than crashing the whole run.
        try:
            result = subprocess.run(
                ["bash", ks["build_single_script"], build_name],
                cwd=root,
                capture_output=True,
                text=True,
                timeout=timeouts["build_single_seconds"],
            )
        except subprocess.TimeoutExpired:
            return KonfluxStreamResultDTO(
                version=args.version,
                version_name=version_name,
                branch=stream_branch,
                prod_stream_file=prod_stream_rel,
                btrfs_updated=True,
                rpa_files_created=rpa_count,
                skipped=True,
                skip_reason=(
                    f"build-single.sh for {build_name} timed out after "
                    f"{timeouts['build_single_seconds']}s"
                ),
            )
        if result.returncode != 0:
            logger.error(
                {
                    "msg": "build-single.sh failed",
                    "tenant": build_name,
                    "stdout_tail": (result.stdout or "").strip()[-1500:],
                    "stderr_tail": (result.stderr or "").strip()[-1500:],
                }
            )
            return KonfluxStreamResultDTO(
                version=args.version,
                version_name=version_name,
                branch=stream_branch,
                prod_stream_file=prod_stream_rel,
                btrfs_updated=True,
                rpa_files_created=rpa_count,
                skipped=True,
                skip_reason=(
                    f"build-single.sh failed for {build_name} (exit "
                    f"{result.returncode}); needs the konflux build toolchain "
                    f"(e.g. kustomize). stderr: "
                    f"{(result.stderr or '').strip()[-300:]}"
                ),
            )

    if args.run_tox:
        logger.info("Running tox (required by the konflux repo to merge)")
        try:
            result = subprocess.run(
                ["tox"], cwd=root, timeout=timeouts["tox_seconds"]
            )
        except subprocess.TimeoutExpired:
            return KonfluxStreamResultDTO(
                version=args.version,
                version_name=version_name,
                branch=stream_branch,
                prod_stream_file=prod_stream_rel,
                btrfs_updated=True,
                rpa_files_created=rpa_count,
                skipped=True,
                skip_reason=f"tox timed out after {timeouts['tox_seconds']}s",
            )
        if result.returncode != 0:
            return KonfluxStreamResultDTO(
                version=args.version,
                version_name=version_name,
                branch=stream_branch,
                prod_stream_file=prod_stream_rel,
                btrfs_updated=True,
                rpa_files_created=rpa_count,
                skipped=True,
                skip_reason=f"tox failed; fix and push manually from {root}",
            )

    title = f"MTV: Add new PDS for {xy}"
    git.add_paths(["config", "tenants-config"])
    git.commit(title)
    git.push(branch=stream_branch)

    pr_url = ""
    try:
        pr_url = _create_konflux_mr(
            gitlab_auth.token,
            title=title,
            description=(
                f"Add the {version_name} release stream (prod rendered manifest, "
                "btrfs ProjectDevelopmentStream, and ReleasePlanAdmissions).\n\n"
                "Automated via the mtv-releng konflux_stream pipeline."
            ),
        )
        logger.info({"msg": "MR created", "pr_url": pr_url})
    except (RuntimeError, requests.exceptions.RequestException) as e:
        logger.warning(
            f"Could not auto-create MR ({e}); push succeeded, open it manually "
            f"at {ks['host']}/{ks['project_path']}/-/merge_requests/new"
        )

    return KonfluxStreamResultDTO(
        version=args.version,
        version_name=version_name,
        branch=stream_branch,
        prod_stream_file=prod_stream_rel,
        btrfs_updated=True,
        rpa_files_created=rpa_count,
        pushed=True,
        pr_url=pr_url,
    )
