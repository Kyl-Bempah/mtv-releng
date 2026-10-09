"""Branching logic for the branching pipeline.

Port of the file-rewriting parts of scripts/branching.sh (the ``release_conf_*``
heredocs and the ``.tekton`` sed edits of ``process_repo``), plus the per-repo
clone/commit/push orchestration (``branch_one``). The pure transforms are kept
free of I/O so the rewrite rules stay testable.
"""

import logging
import os
from argparse import Namespace

from config import config
from models.dto import BranchingResultDTO
from models.git_repo import GitRepo
from semver import Version
from wrappers.gh_cli import GHCLI

logger = logging.getLogger(__name__)


def mtv_version_parts(version: str) -> tuple[str, str]:
    """(xy, version_name) for an x.y.z version, e.g. "2.11.0" -> ("2.11", "2-11")."""
    v = Version.parse(version)
    return f"{v.major}.{v.minor}", f"{v.major}-{v.minor}"


def render_release_conf(
    origin: str,
    version: str,
    release: str,
    channel: str,
    default_channel: str,
    registry: str,
    ocp_versions: str,
) -> str:
    """Regenerate build/release.conf for *origin* (matches the shell heredocs).

    The per-origin global-version key (MTV_VERSION/RVERSION/VERSION) comes from
    the release_conf_version_keys config map; only forklift carries OCP_VERSIONS.
    """
    version_key = config.get_release_conf_version_keys().get(origin)
    if version_key is None:
        raise ValueError(f"No release.conf template for origin '{origin}'")
    xy, _ = mtv_version_parts(version)

    lines = [
        '# Global version specifying version for every component and for bundle, format "x.y.z"',
        f"{version_key}={version}",
        "",
        '# Release version, format "vX.Y"',
        f"RELEASE={release}",
        "",
        '# This setting must mirror the Y stream version specified above, e.g. if RELEASE == v2.10 then CPE == 2.10 (without the "v")',
        f"CPE={xy}",
        "",
        "# Operator channel where the version will be deployed, e.g. dev-preview, release-v2.9 ...",
        f"CHANNEL={channel}",
        "",
        "# Default operator channel for other operators to pull from, if they depend on MTV",
        f"DEFAULT_CHANNEL={default_channel}",
        "",
        "# Registry where all components should be released to, for dev-preview -> mtv-candidate, for release-X.Y -> migration-toolkit-virtualization",
        f"REGISTRY={registry}",
    ]
    if origin == "forklift":
        lines += [
            "",
            "# Which OCP versions are supported by this release",
            f"OCP_VERSIONS={ocp_versions}",
        ]
    return "\n".join(lines) + "\n"


def transform_tekton_content(
    content: str, version_name: str, xy: str, marker: str
) -> str:
    """Retarget a .tekton file from marker/main to the release stream.

    Mirrors the two sed passes in process_repo: on-cel branch filter
    ``"main"`` -> ``"release-X.Y"``, then every *marker* -> version_name.
    """
    content = content.replace('"main"', f'"release-{xy}"')
    content = content.replace(marker, version_name)
    return content


async def branch_one(
    origin: str, repo_url: str, args: Namespace
) -> BranchingResultDTO:
    """Branch a single origin: release branch + CF-<version> code-freeze PR."""
    dry_run = not args.apply
    try:
        xy, version_name = mtv_version_parts(args.version)
    except ValueError as e:
        return BranchingResultDTO(
            origin=origin,
            version=args.version,
            release_branch="",
            cf_branch="",
            dry_run=dry_run,
            skipped=True,
            skip_reason=f"Invalid version '{args.version}': {e}",
        )

    release_branch = f"release-{xy}"
    cf_branch = f"CF-{args.version}"
    release = args.release or f"v{xy}"
    channel = args.channel or f"release-v{xy}"
    default_channel = args.default_channel or f"release-v{xy}"
    registry = args.registry or config.get_release_namespace()
    ocp_versions = args.ocp_versions or ""

    base = BranchingResultDTO(
        origin=origin,
        version=args.version,
        release_branch=release_branch,
        cf_branch=cf_branch,
        dry_run=dry_run,
    )

    if origin == "forklift" and not ocp_versions:
        return base.model_copy(
            update={
                "skipped": True,
                "skip_reason": "forklift requires --ocp-versions",
            }
        )

    repo = GitRepo(url=repo_url, name=origin, version=args.version)
    await repo.init()
    git = repo.git
    git.config("user.email", config.get_git_email())
    git.config("user.name", config.get_git_name())
    if not dry_run:
        GHCLI(repo.tmp_dir.name).auth()

    # Create (or reuse) the release branch, then branch CF-<version> off it.
    release_branch_created = False
    if git.ref_exists(f"origin/{release_branch}"):
        logger.info(f"[{origin}] {release_branch} exists on origin, reusing")
        git.checkout(release_branch)
    else:
        logger.info(f"[{origin}] Creating {release_branch} from main")
        git.checkout(release_branch, create=True)
        release_branch_created = True
        if not dry_run:
            try:
                git.push(branch=release_branch)
            except RuntimeError as e:
                # Protected release-* branches (branch ruleset / required status
                # checks) reject a direct bot push. Skip this repo with guidance
                # rather than crashing the whole run; create the branch via an
                # allowed path (admin/bypass or the GitHub UI from main), then
                # re-run — the reuse path above will open the code-freeze PR.
                logger.warning(
                    f"[{origin}] Could not push {release_branch}: {e}"
                )
                return base.model_copy(
                    update={
                        "skipped": True,
                        "skip_reason": (
                            f"Could not create {release_branch} on origin "
                            f"(likely branch protection/ruleset). Create it from "
                            f"main manually, then re-run to open the code-freeze "
                            f"PR. Error: {e}"
                        ),
                    }
                )

    git.checkout(cf_branch, create=True)

    root = repo.tmp_dir.name
    marker = config.get_dev_preview_marker()

    conf_path = os.path.join(root, config.get_release_conf_path())
    with open(conf_path, "w") as f:
        f.write(
            render_release_conf(
                origin,
                version=args.version,
                release=release,
                channel=channel,
                default_channel=default_channel,
                registry=registry,
                ocp_versions=ocp_versions,
            )
        )

    tekton_dir = os.path.join(root, ".tekton")
    tekton_count = 0
    if os.path.isdir(tekton_dir):
        for name in sorted(os.listdir(tekton_dir)):
            old = os.path.join(tekton_dir, name)
            if not os.path.isfile(old):
                continue
            new = os.path.join(
                tekton_dir, name.replace(marker, version_name)
            )
            if new != old:
                os.rename(old, new)
            with open(new) as f:
                content = f.read()
            with open(new, "w") as f:
                f.write(
                    transform_tekton_content(content, version_name, xy, marker)
                )
            tekton_count += 1

    images_conf_path = config.get_images_conf_path()
    paths = [".tekton", config.get_release_conf_path()]
    # images.conf is forklift-only. The shell regressed here (commit e034029):
    # it compared the release-conf *function name* ("release_conf_forklift") to
    # "forklift", so the guard never fired and this previously-unconditional
    # retarget silently stopped running. Restore the intended behavior.
    if origin == "forklift":
        images_path = os.path.join(root, images_conf_path)
        if os.path.exists(images_path):
            with open(images_path) as f:
                images = f.read()
            with open(images_path, "w") as f:
                f.write(images.replace(marker, version_name))
            paths.append(images_conf_path)

    if dry_run:
        logger.info(
            {
                "msg": "Dry-run: would commit code freeze and open PR",
                "origin": origin,
                "release_branch": release_branch,
                "release_branch_created": release_branch_created,
                "cf_branch": cf_branch,
                "tekton_files": tekton_count,
                "target_branch": release_branch,
            }
        )
        return base.model_copy(
            update={"release_branch_created": release_branch_created}
        )

    git.add_paths(paths)
    git.commit(f"Code freeze for {xy}")
    # On a rerun (e.g. after a prior PR-creation failure) CF-<version> may already
    # exist on origin; with-lease lets us update it without clobbering unexpected
    # remote work. The remote-tracking ref is present from the full clone.
    if git.ref_exists(f"origin/{cf_branch}"):
        git.push(branch=cf_branch, force="lease")
    else:
        git.push(branch=cf_branch)

    body = (
        f"Code freeze for {xy}.\n\n"
        f"- Regenerated {config.get_release_conf_path()}\n"
        f"- Retargeted .tekton pipelines to the {release_branch} stream\n"
        "- Automated via the mtv-releng branching pipeline."
    )
    pr_url = ""
    try:
        pr_url = GHCLI(root).create_pr(
            title=f"Code freeze for {xy}",
            body=body,
            target_branch=release_branch,
            head_branch=cf_branch,
        )
        logger.info({"msg": "PR created", "origin": origin, "pr_url": pr_url})
    except RuntimeError as e:
        logger.warning(
            {"msg": "PR creation failed", "origin": origin, "error": str(e)}
        )
        # The branch was pushed; surface the PR failure instead of looking like
        # a clean success with an empty pr_url.
        return base.model_copy(
            update={
                "release_branch_created": release_branch_created,
                "skipped": True,
                "skip_reason": (
                    f"{cf_branch} pushed but PR creation failed: {e}"
                ),
            }
        )

    return base.model_copy(
        update={
            "release_branch_created": release_branch_created,
            "pr_url": pr_url,
        }
    )
