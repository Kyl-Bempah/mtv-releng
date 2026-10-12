import logging
from asyncio import TaskGroup

from config import config
from models.fbc_repo import FBCRepo
from models.iib import IIB
from semver.version import Version
from tasks.process_ocp_catalog import process_ocp_catalog
from utils import parse_version
from wrappers.skopeo import ImageNotFoundError, Skopeo

logger = logging.getLogger(__name__)


def _resolve_previous_iib_url(ocps: list[str], sha: str) -> str | None:
    """First `on-pr-<sha>` OCP fragment that still exists (highest OCP first).

    Every OCP fragment of a commit wraps the same operator bundle, so any that
    resolves yields the same component commits. Probing avoids pinning to
    ocps[0], whose per-OCP tag may be expired (quay time-machine GC) or was
    never built for that OCP range. Returns None if none resolve.
    """
    template = config.get_fbc_component_url()
    for ocp in sorted(
        ocps,
        key=lambda v: Version.parse(v.lstrip("v"), optional_minor_and_patch=True),
        reverse=True,
    ):
        url = template.replace("{ocp}", ocp.replace(".", "")).replace(
            "{commit}", sha
        )
        try:
            Skopeo().inspect(url)
        except ImageNotFoundError:
            logger.info(f"Previous IIB fragment absent for {ocp}: {url}")
            continue
        except RuntimeError as e:
            logger.warning(f"Could not probe previous IIB {url}: {e}")
            continue
        logger.info(f"Resolved previous IIB from the {ocp} fragment")
        return url
    return None


async def process_fbc_repo(fbc_repo: FBCRepo, tg: TaskGroup, branch: str = ""):
    bundle = fbc_repo.for_bundle
    logger.info(f"Looking for previous commit with {bundle.version}")
    commits = fbc_repo.git.log(config.get_iib_max_commits())
    for commit in commits:
        if str(bundle.version) in commit.get("message", "") and "-release" not in commit.get("message", ""):
            logger.info(
                f"Found previous commit {commit.get("message")}"
                f" ({commit.get("sha")})"
            )
            fbc_repo.previous_commit = commit
            break
    if not fbc_repo.previous_commit:
        logger.info(f"Previous commit not found for {bundle.version}")
        parse_version(fbc_repo, bundle.version)
        fbc_repo.current_iib_version = Version(
            bundle.version.major,
            bundle.version.minor,
            bundle.version.patch,
            1,
        )
    else:
        # Only interest is in version so split away the Signed-off part
        fbc_repo.previous_iib_version = Version.parse(
            fbc_repo.previous_commit.get("message", "").split()[0]
        )

        # Construct prev IIB url — probe OCP fragments for the one whose
        # on-pr-<sha> tag still exists (any resolves the same component commits).
        prev_sha = fbc_repo.previous_commit.get("sha", "")
        prev_iib_url = _resolve_previous_iib_url(bundle.ocps, prev_sha)
        if prev_iib_url:
            fbc_repo.previous_iib = IIB(
                prev_iib_url, fbc_repo.previous_iib_version
            )
        else:
            logger.warning(
                f"No OCP fragment found for previous build {prev_sha[:12]}; "
                "diff against the previous build will be skipped"
            )

        # Bump the prerelease ver for new IIB
        fbc_repo.current_iib_version = (
            fbc_repo.previous_iib_version.bump_prerelease()
        )

    ocp_tasks = []
    for ocp in bundle.ocps:
        # ocp_tasks.append(
        #     tg.create_task(process_ocp_catalog(fbc_repo, ocp, bundle, tg))
        # )
        await process_ocp_catalog(fbc_repo, ocp, bundle, tg)
    for task in ocp_tasks:
        await task

    # Commit all changes if any
    if fbc_repo.git.has_changes():
        for ocp in bundle.ocps:
            fbc_repo.git.add_files([f"{ocp}/"])
        fbc_repo.git.commit(str(fbc_repo.current_iib_version))

        # get our new commit
        curr_commit = fbc_repo.git.log(1)[0]
        fbc_repo.current_commit = curr_commit

        # Construct current IIB url
        curr_iib_url = config.get_fbc_component_url()
        curr_iib_url = curr_iib_url.replace(
            "{ocp}", bundle.ocps[0].replace(".", "")
        )
        curr_iib_url = curr_iib_url.replace(
            "{commit}", fbc_repo.current_commit.get("sha", "")
        )
        fbc_repo.current_iib = IIB(curr_iib_url, fbc_repo.current_iib_version)

        if not branch:
            fbc_repo.git.push(branch=str(bundle.version))
        else:
            fbc_repo.git.push(branch=branch)
        return fbc_repo
    # Return None if no changes were made
    return None
