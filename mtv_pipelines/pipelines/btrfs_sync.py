import argparse
import logging
from argparse import ArgumentParser, Namespace
from asyncio import TaskGroup

from auth.auth import GitlabAuth
from config import config
from core.task import task
from models.dto import BtrfsSyncResultDTO
from utils import create_temp_dir
from wrappers.git import Git

DESCRIPTION = (
    "Mirror a public forklift branch into the internal GitLab repository.\n\n"
    "Clones github.com/kubev2v/forklift, checks out (or creates from main) the\n"
    "given branch, rebases it onto the internal mirror and onto origin, then\n"
    "force-pushes the result to the internal GitLab repo. Uses shallow,\n"
    "targeted fetches to keep network load low."
)

logger = logging.getLogger(__name__)

FORKLIFT_REPO = "https://github.com/kubev2v/forklift.git"
FORKLIFT_INTERNAL_REPO = "https://gitlab.cee.redhat.com/mtv/forklift.git"
FETCH_DEPTH = 50

# git settings that make large-repo fetches more reliable (see PR #53)
_LARGE_REPO_CONFIG = {
    "http.postBuffer": "524288000",
    "http.maxRequestBuffer": "100M",
    "core.preloadindex": "true",
    "core.fscache": "true",
    "gc.auto": "256",
}


def arg_parse(arg_parser: ArgumentParser):
    arg_parser.formatter_class = argparse.RawTextHelpFormatter
    arg_parser.add_argument(
        "-b",
        "--branch",
        required=True,
        help="[required] Branch to sync (e.g. main, release-2.12).",
    )
    arg_parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="[optional] Do everything except the final force-push to internal.",
    )


@task
async def sync_branch(
    data, args: Namespace, tg: TaskGroup
) -> BtrfsSyncResultDTO:
    branch = args.branch

    try:
        internal_url = GitlabAuth().authenticated_url(FORKLIFT_INTERNAL_REPO)
    except ValueError as e:
        return BtrfsSyncResultDTO(
            branch=branch, skipped=True, skip_reason=str(e)
        )

    tmp_dir = create_temp_dir(f"btrfs-sync-{branch}")
    git = Git(tmp_dir.name)

    logger.info({"msg": "Cloning (shallow)", "repo": FORKLIFT_REPO})
    await git.clone(FORKLIFT_REPO, depth=FETCH_DEPTH, single_branch=False)

    for option, value in _LARGE_REPO_CONFIG.items():
        git.config(option, value)
    git.config("user.email", config.get_git_email())
    git.config("user.name", config.get_git_name())

    # Checkout the branch, or create it from main when origin doesn't have it yet
    created_from_main = False
    if git.ref_exists(f"origin/{branch}"):
        logger.info(f"Branch {branch} exists on origin, checking out")
        git.checkout(branch)
    else:
        logger.info(f"Branch {branch} not on origin, creating from main")
        git.checkout("main")
        git.checkout(branch, create=True)
        created_from_main = True

    logger.info("Disabling SSL verification for internal remote")
    git.config("http.sslVerify", "false")

    git.add_remote("internal", internal_url)

    # Targeted, shallow fetch of just this branch; fall back to HTTP/1.1 on failure
    logger.info(f"Fetching branch {branch} from internal")
    try:
        git.fetch(branch, origin="internal", depth=FETCH_DEPTH)
    except Exception as e:
        logger.warning(f"Internal fetch failed ({e}); retrying with HTTP/1.1")
        git.config("http.version", "HTTP/1.1")
        git.fetch(branch, origin="internal", depth=FETCH_DEPTH)

    if git.ref_exists(f"internal/{branch}"):
        logger.info(f"Rebasing onto internal/{branch}")
        git.rebase(f"internal/{branch}")
    else:
        logger.info(f"Branch {branch} not on internal, skipping internal rebase")

    if git.ref_exists(f"origin/{branch}"):
        logger.info(f"Fetching and rebasing onto origin/{branch}")
        git.fetch(branch, origin="origin", depth=FETCH_DEPTH)
        git.rebase(f"origin/{branch}")
    else:
        logger.info("Branch created from main, skipping origin rebase")

    if args.dry_run:
        logger.info(
            f"Dry-run: would force-push {branch} to internal GitLab mirror"
        )
        return BtrfsSyncResultDTO(
            branch=branch,
            created_from_main=created_from_main,
            dry_run=True,
        )

    logger.info(f"Force-pushing {branch} to internal")
    git.push(branch=branch, remote_name="internal", force="force")

    return BtrfsSyncResultDTO(
        branch=branch,
        created_from_main=created_from_main,
        pushed=True,
    )
