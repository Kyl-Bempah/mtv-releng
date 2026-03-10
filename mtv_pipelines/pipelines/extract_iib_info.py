import logging
from argparse import Namespace
from asyncio import TaskGroup

from config import config
from core.task import depends_on, task
from models.dto import EmptyDTO, RepoCommitDTO
from models.git_repo import GitRepo
from models.iib import IIB
from semver.version import Version
from tasks.extract_info import extract_info
from tasks.get_mtv_versions import get_mtv_versions

from mtv_pipelines.wrappers.skopeo import Skopeo

DESCRIPTION = "Pipeline to extract info (bundle, commits...) from IIB"

logger = logging.getLogger(__name__)


def arg_parse(arg_parser):
    arg_parser.add_argument(
        "--iib",
        help='MTV IIB Url, example: "quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v419:on-pr-371c8c5a82e33ba70d0a3f387ac5e91162b38c0e"',
        required=True,
    )

    arg_parser.add_argument(
        "--mtv",
        help='MTV version, example: "2.10.5',
        required=True,
    )


@task
async def skopeo_login_task(
    data: EmptyDTO, args: Namespace, tg: TaskGroup
) -> EmptyDTO:
    try:
        Skopeo().auth()
    except RuntimeError as e:
        logger.error(f"Failed to login to registries: {e}")
        raise e
    return EmptyDTO()


@task
async def prepare_cmp_git_repos(
    data: EmptyDTO, args: Namespace, tg: TaskGroup
) -> list[GitRepo]:
    origin_versions = get_mtv_versions()
    mtv_repos = config.get_mtv_repositories()
    result = []

    git_repos: dict[str, GitRepo] = {}
    xy_version = args.mtv.split(".")[:2]

    logger.debug("Cloning MTV repositories")
    for origin, repo_url in mtv_repos.items():
        gr = GitRepo(repo_url, origin, args.mtv)
        await gr.init()
        git_repos[origin] = gr

    logger.debug("Checking out branches")
    for origin, branch_ver in origin_versions.items():
        for branch, ver in branch_ver.items():
            if ver.split(".")[:2] == xy_version:
                git_repos[origin].git.fetch(branch)
                git_repos[origin].git.checkout(branch)
                await git_repos[origin].git.pull(branch)
                logger.debug(f"Checked out {branch}")

        result.extend(git_repos.values())
    return result


@task
@depends_on(
    prepare_cmp_git_repos,
)
async def extract_commits(
    data: list[GitRepo], args: Namespace, tg: TaskGroup
) -> list[RepoCommitDTO]:
    if not data:
        logger.warning(f"Previous task didn't return any Git Repositories")
        return []

    results = []

    iib = IIB(args.iib, Version.parse(args.mtv))

    results.extend(await extract_info(iib, data))

    for res in results:
        logger.info(res.model_dump_json())

    return results
