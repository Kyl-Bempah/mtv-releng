import logging

from models.dto import RepoCommitDTO
from models.git_repo import GitRepo
from models.iib import IIB
from tasks.extract_bundle_from_iib import extract_bundle_from_iib
from tasks.extract_cmps_from_bundle import extract_cmps_from_bundle
from tasks.get_origin_commits_from_cmps import get_origin_commits_from_cmps

logger = logging.getLogger(__name__)


async def extract_info(
    iib: IIB, git_repos: list[GitRepo]
) -> list[RepoCommitDTO]:
    results = []
    bundle = extract_bundle_from_iib(iib)
    if not bundle:
        logger.error(f"Failed to extract Bundle from {iib}, skipping IIB")
        return results

    cmps = extract_cmps_from_bundle(bundle)
    if not cmps:
        logger.error(
            f"Failed to extract Components from {bundle}, skipping bundle"
        )
        return results

    # only pick repos relevant to the IIB/bundle version
    logger.debug(f"Filtering git repos {git_repos}")
    grs = {}
    for gr in git_repos:
        gv = ".".join(gr.version.split(".")[:2])
        bv = ".".join(str(bundle.version).split(".")[:2])
        if gv == bv:
            grs[gr.name] = gr
    logger.debug(f"Filtered git repos {grs}")

    commits = await get_origin_commits_from_cmps(cmps, grs)
    if not commits:
        logger.error(
            f"Failed to extract commits from {bundle}, skipping bundle"
        )
        return results

    for repo, commit in commits.items():
        rc = RepoCommitDTO(
            repo=repo, sha=commit, version=str(iib.version).split("-")[0]
        )
        results.append(rc)
    return results
