import logging

from config import config
from models.dto import JenkinsJobDTO
from semver import Version
from utils import iib_short_for_target_ocp

logger = logging.getLogger(__name__)


def _upgrade_plan(bundle_ver: Version, override: str | None) -> list[tuple[int, str]]:
    """(ocp_index, upgrade_from) pairs for the upgrade matrix.

    ocp_index 0 = highest OCP (upgrade from the prior Z-stream);
    ocp_index 1 = next OCP (upgrade from the prior Y-stream).
    ``override`` supplies the cross-major predecessor (e.g. 2.12 for 5.0)
    when it can't be derived at a major boundary.
    """
    plan = []
    # highest OCP: prior Z-stream, or the cross-major GA on a fresh .0.0
    if bundle_ver.patch > 0:
        plan.append((0, f"{bundle_ver.major}.{bundle_ver.minor}"))
    elif bundle_ver.minor == 0 and override:
        plan.append((0, override))
    # next OCP: prior Y-stream, or the cross-major predecessor at a boundary
    if bundle_ver.minor > 0:
        plan.append((1, f"{bundle_ver.major}.{bundle_ver.minor - 1}"))
    elif override:
        plan.append((1, override))
    return plan


async def trigger_upgrade_jobs(
    jm, version: str, iib_version: str, ocps: list[str], iib_short: str
) -> list[JenkinsJobDTO]:
    """Trigger the release-upgrade Jenkins jobs for a build.

    ``ocps`` must be ordered high -> low. The upgrade-from version is computed
    from the bundle semver; ``upgrade_from_versions`` config is only consulted
    as an override for major cutovers where the predecessor can't be derived.
    """
    bundle_ver = Version.parse(version)
    mtv_xy = ".".join(version.split(".")[:2])
    override = config.get_upgrade_from_versions().get(mtv_xy)
    results = []
    for idx, from_ver in _upgrade_plan(bundle_ver, override):
        if idx >= len(ocps):
            continue
        ocp = ocps[idx]
        job = await jm.trigger_upgrade(
            version, ocp, iib_short_for_target_ocp(iib_short, ocp), from_ver
        )
        if not job:
            continue
        info = await jm.get_job_info(job["job_name"], job["job_number"])
        results.append(
            JenkinsJobDTO(
                iib_version=iib_version,
                job_name=job["job_name"],
                build_number=job["job_number"],
                ocp_version=ocp,
                job_url=info.get("url", ""),
            )
        )
    return results
