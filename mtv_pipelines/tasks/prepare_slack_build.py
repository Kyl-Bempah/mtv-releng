from config import config
from models.dto import RepoDiffDTO, SlackBuildMessageDTO
from models.fbc_repo import FBCRepo
from tasks.extract_cmps_from_bundle import extract_cmps_from_bundle


def prepare_slack_build(fbc_repo: FBCRepo, diffs: list[RepoDiffDTO]):
    version = fbc_repo.current_iib_version

    ocp_urls = {}
    ocps = fbc_repo.for_bundle.ocps
    curr_commit = fbc_repo.current_commit.get("sha")
    if not ocps or not curr_commit:
        raise ValueError(
            f"One of {ocps}, {curr_commit} in {fbc_repo} was empy, can't continue"
        )
    for ocp in ocps:
        url = config.get_fbc_component_url()
        url = url.replace("{ocp}", ocp.replace(".", ""))
        url = url.replace("{commit}", curr_commit)
        ocp_urls[ocp] = url

    bundle_url = fbc_repo.for_bundle.url

    prev_iib = fbc_repo.previous_iib
    if prev_iib:
        prev_build = (str(prev_iib.version), prev_iib.url)
    else:
        prev_build = ("", "")

    cmp_commits = {}
    cmps = extract_cmps_from_bundle(fbc_repo.for_bundle)
    for cmp in cmps:
        cmp_commits[cmp.name] = cmp.commit

    return SlackBuildMessageDTO(
        iib_version=str(version),
        ocp_urls=ocp_urls,
        bundle_url=bundle_url,
        snapshot="",
        commits=cmp_commits,
        changes=diffs,
        prev_build=prev_build,
    )
