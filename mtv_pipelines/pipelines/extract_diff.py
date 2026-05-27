import logging
from argparse import Namespace
from asyncio import TaskGroup

from config import config
from core.task import depends_on, task
from models.dto import CollectorDTO, EmptyDTO, RepoCommitDTO, RepoDiffDTO
from models.git_repo import GitRepo
from models.iib import IIB
from semver.version import Version
from tasks.extract_info import extract_info
from tasks.get_commit_diff import get_commit_diff
from tasks.get_mtv_versions import get_mtv_versions

DESCRIPTION = "Pipeline to extract commit diff from 2 IIBs"

logger = logging.getLogger(__name__)


def arg_parse(arg_parser):
    arg_parser.add_argument(
        "--new_iib",
        help='MTV new IIB Url, example: "quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v419:on-pr-371c8c5a82e33ba70d0a3f387ac5e91162b38c0e"',
        required=True,
    )

    arg_parser.add_argument(
        "--old_iib",
        help='MTV old IIB Url, example: "quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v419:on-pr-371c8c5a82e33ba70d0a3f387ac5e91162b38c0e"',
        required=True,
    )

    arg_parser.add_argument(
        "--old_version",
        help='Old MTV version, example: "2.10.5',
        required=True,
    )

    arg_parser.add_argument(
        "--new_version",
        help='New MTV version, example: "2.10.5',
        required=True,
    )


@task
async def prepare_cmp_git_repos(
    data: EmptyDTO, args: Namespace, tg: TaskGroup
) -> list[GitRepo]:
    origin_versions = get_mtv_versions()
    mtv_repos = config.get_mtv_repositories()
    result = []

    git_repos: dict[str, GitRepo] = {}
    xy_version = args.new_version.split(".")[:2]

    logger.debug("Cloning MTV repositories")
    for origin, repo_url in mtv_repos.items():
        gr = GitRepo(repo_url, origin, args.new_version)
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
@depends_on(prepare_cmp_git_repos)
async def extract_commits_next(
    data: list[GitRepo], args: Namespace, tg: TaskGroup
) -> list[RepoCommitDTO]:
    if not data:
        logger.warning(f"Previous task didn't return any Git Repositories")
        return []

    results = []

    iib = IIB(args.new_iib, Version.parse(args.new_version))

    results.extend(await extract_info(iib, data))

    return results


@task
@depends_on(prepare_cmp_git_repos)
async def extract_commits_prev(
    data: list[GitRepo], args: Namespace, tg: TaskGroup
) -> list[RepoCommitDTO]:
    if not data:
        logger.warning(f"Previous task didn't return any Git Repositories")
        return []

    results = []

    iib = IIB(args.old_iib, Version.parse(args.old_version))

    results.extend(await extract_info(iib, data))

    return results


@task
@depends_on(
    extract_commits_prev,
    extract_commits_next,
    prepare_cmp_git_repos,
)
async def extract_commit_diff(
    data: CollectorDTO, args: Namespace, tg: TaskGroup
) -> list[RepoDiffDTO]:
    if not data:
        logger.warning(f"Previous task didn't return any data")
        return []

    next_commits = data.task_outputs.get(extract_commits_next.name)
    prev_commits = data.task_outputs.get(extract_commits_prev.name)
    git_repos = data.task_outputs.get(prepare_cmp_git_repos.name)
    results = []

    def find_git_repo_for_ver(
        git_repos: list[GitRepo], repo: str, ver: str
    ) -> GitRepo:
        for gr in git_repos:
            if gr.name != repo:
                continue
            if ".".join(gr.version.split(".")[:2]) != ".".join(
                ver.split(".")[:2]
            ):
                continue
            return gr
        raise ValueError(f"No git repo found for {repo} {ver}")

    if not git_repos:
        logger.error(f"Previous task didn't return any git repositories")
        return []

    if not next_commits:
        logger.error(f"Previous task didn't return any current commits")
        return []

    if not prev_commits:
        logger.info(f"No previous commits, build is new Y-stream")
        for next_commit in next_commits:
            results.append(
                RepoDiffDTO(
                    repo=next_commit.repo,
                    diff=[],
                    version=next_commit.version,
                )
            )
        return results

    for ncommit in next_commits:
        repo = ncommit.repo
        version = ncommit.version
        commit = ncommit.sha

        for pcommit in prev_commits:
            if pcommit.repo != repo:
                continue
            if ".".join(pcommit.version.split(".")[:2]) != ".".join(
                version.split(".")[:2]
            ):
                continue

            gr = find_git_repo_for_ver(git_repos, repo, version)
            diff = get_commit_diff(pcommit.sha, commit, gr)
            results.append(RepoDiffDTO(repo=repo, diff=diff, version=version))
            break
    logger.info({"Results": [str(res) for res in results]})
    return results
