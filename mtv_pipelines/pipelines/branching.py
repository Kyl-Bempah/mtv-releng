import argparse
import logging
import os
from argparse import ArgumentParser, Namespace
from asyncio import TaskGroup

from config import config
from core.task import task
from models.dto import BranchingResultDTO
from models.git_repo import GitRepo
from tasks.branching import (
    mtv_version_parts,
    render_release_conf,
    transform_tekton_content,
)
from wrappers.gh_cli import GHCLI

DESCRIPTION = (
    "Branch the MTV operator repos for a release (code freeze).\n\n"
    "For each selected origin: create the release-X.Y branch from main and push\n"
    "it, then open a 'CF-<version>' PR into it that regenerates build/release.conf,\n"
    "renames/retargets the .tekton pipelines from dev-preview to the release\n"
    "stream (and, for forklift, bumps images.conf). The Konflux releng side is\n"
    "handled by the separate 'konflux_stream' pipeline. Dry-run by default; pass\n"
    "--apply to push and open PRs."
)

logger = logging.getLogger(__name__)

IMAGES_CONF_PATH = "build/forklift-operator-bundle/images.conf"


def arg_parse(arg_parser: ArgumentParser):
    arg_parser.formatter_class = argparse.RawTextHelpFormatter
    origins = list(config.get_mtv_repositories().keys())
    arg_parser.add_argument(
        "version",
        help="[required] Global version for every component and the bundle, format x.y.z (e.g. 2.11.0).",
    )
    arg_parser.add_argument(
        "-o",
        "--origin",
        action="append",
        dest="origins",
        metavar="ORIGIN",
        choices=origins,
        help="[optional] Origin repo to branch. Repeatable. Defaults to all.\nChoices:\n"
        + "\n".join(f"  {o}" for o in origins),
    )
    arg_parser.add_argument(
        "--release",
        metavar="RELEASE",
        help='[optional] RELEASE field, format vX.Y (default: derived, e.g. "v2.11").',
    )
    arg_parser.add_argument(
        "--channel",
        metavar="CHANNEL",
        help='[optional] CHANNEL field (default: "release-vX.Y").',
    )
    arg_parser.add_argument(
        "--default-channel",
        dest="default_channel",
        metavar="DEFAULT_CHANNEL",
        help='[optional] DEFAULT_CHANNEL field (default: "release-vX.Y").',
    )
    arg_parser.add_argument(
        "--registry",
        metavar="REGISTRY",
        help="[optional] REGISTRY field (default: the release namespace from config).",
    )
    arg_parser.add_argument(
        "--ocp-versions",
        dest="ocp_versions",
        metavar="OCP_VERSIONS",
        help='[required for forklift] OCP_VERSIONS field (e.g. "v4.17-v4.19").',
    )
    arg_parser.add_argument(
        "--apply",
        action="store_true",
        default=False,
        help="[optional] Create branches, push, and open PRs. Without it, dry-run only.",
    )


async def _branch_one(
    origin: str, repo_url: str, args: Namespace
) -> BranchingResultDTO:
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
            git.push(branch=release_branch)

    git.checkout(cf_branch, create=True)

    root = repo.tmp_dir.name

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
            new = os.path.join(tekton_dir, name.replace("dev-preview", version_name))
            if new != old:
                os.rename(old, new)
            with open(new) as f:
                content = f.read()
            with open(new, "w") as f:
                f.write(transform_tekton_content(content, version_name, xy))
            tekton_count += 1

    paths = [".tekton", config.get_release_conf_path()]
    # images.conf is forklift-only. The shell regressed here (commit e034029):
    # it compared the release-conf *function name* ("release_conf_forklift") to
    # "forklift", so the guard never fired and this previously-unconditional
    # retarget silently stopped running. Restore the intended behavior.
    if origin == "forklift":
        images_path = os.path.join(root, IMAGES_CONF_PATH)
        if os.path.exists(images_path):
            with open(images_path) as f:
                images = f.read()
            with open(images_path, "w") as f:
                f.write(images.replace("dev-preview", version_name))
            paths.append(IMAGES_CONF_PATH)

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


@task
async def branch_repos(
    data, args: Namespace, tg: TaskGroup
) -> list[BranchingResultDTO]:
    repositories = config.get_mtv_repositories()
    origins = args.origins or list(repositories.keys())

    logger.info(
        {
            "msg": "Starting branching",
            "version": args.version,
            "origins": origins,
            "dry_run": not args.apply,
        }
    )

    results: list[BranchingResultDTO] = []
    for origin in origins:
        repo_url = (repositories.get(origin) or "").rstrip("/")
        if not repo_url:
            results.append(
                BranchingResultDTO(
                    origin=origin,
                    version=args.version,
                    release_branch="",
                    cf_branch="",
                    dry_run=not args.apply,
                    skipped=True,
                    skip_reason=f"No URL configured for origin '{origin}'",
                )
            )
            continue
        results.append(await _branch_one(origin, repo_url, args))

    return results
