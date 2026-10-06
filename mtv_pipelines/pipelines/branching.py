import argparse
import logging
from argparse import ArgumentParser, Namespace
from asyncio import TaskGroup

from config import config
from core.task import task
from models.dto import BranchingResultDTO
from tasks.branching import branch_one

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
        required=False,
        help="[optional] Origin repo to branch. Repeatable. Defaults to all.\nChoices:\n"
        + "\n".join(f"  {o}" for o in origins),
    )
    arg_parser.add_argument(
        "--release",
        metavar="RELEASE",
        required=False,
        help='[optional] RELEASE field, format vX.Y (default: derived, e.g. "v2.11").',
    )
    arg_parser.add_argument(
        "--channel",
        metavar="CHANNEL",
        required=False,
        help='[optional] CHANNEL field (default: "release-vX.Y").',
    )
    arg_parser.add_argument(
        "--default-channel",
        dest="default_channel",
        metavar="DEFAULT_CHANNEL",
        required=False,
        help='[optional] DEFAULT_CHANNEL field (default: "release-vX.Y").',
    )
    arg_parser.add_argument(
        "--registry",
        metavar="REGISTRY",
        required=False,
        help="[optional] REGISTRY field (default: the release namespace from config).",
    )
    arg_parser.add_argument(
        "--ocp-versions",
        dest="ocp_versions",
        metavar="OCP_VERSIONS",
        required=False,
        help='[required for forklift] OCP_VERSIONS field (e.g. "v4.17-v4.19").',
    )
    arg_parser.add_argument(
        "--apply",
        action="store_true",
        default=False,
        required=False,
        help="[optional] Create branches, push, and open PRs. Without it, dry-run only.",
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
        results.append(await branch_one(origin, repo_url, args))

    return results
