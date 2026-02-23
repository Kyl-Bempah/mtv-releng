import logging

from config import config
from models.component import Component
from models.git_repo import GitRepo

"""Return example
{
    "forklift": "1234...",
    "forklift-console-plugin": "4321..."
    ...
}
"""

logger = logging.getLogger(__name__)


async def get_origin_commits_from_cmps(
    cmps: list[Component], git_repos: dict[str, GitRepo]
) -> dict[str, str]:
    origin_commit_map: dict[str, set] = {}
    mtv_repos = config.get_mtv_repositories()
    mappings = config.get_cmp_mappings()

    for mtv_repo in mtv_repos:
        origin_commit_map[mtv_repo] = set()

    logger.info("Matching commits from components to origins")
    for cmp in cmps:
        # quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-operator-2-11/forklift-api-2-11@sha256:1234... -> forklift-api-2-11@sha...
        image = cmp.url.split("/")[-1]
        for _, mapping in mappings.items():
            upstream = mapping.get("upstream")
            if upstream in image:
                origin = mapping.get("origin")
                if origin not in origin_commit_map.keys():
                    logger.error(
                        f"Origin {origin} from component {upstream}"
                        f" not found in config repos {mtv_repos}"
                    )
                    return {}
                origin_commit_map[origin].add(cmp.commit)
    logger.debug(f"Found these commits: {origin_commit_map}")

    logger.debug("Finding the latest commit for origin")
    result = {}
    for origin, commits in origin_commit_map.items():
        # 200 commits to take into account as history
        git_log = git_repos[origin].git.log(max_count=200)
        git_log.reverse()
        for commit in git_log:
            sha = commit.get("sha")
            if sha in commits:
                result[origin] = sha

    return result
