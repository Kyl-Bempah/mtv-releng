import logging
from asyncio import sleep

from config import config
from models.dto import CheckStatus, CheckStatusDTO
from models.fbc_repo import FBCRepo
from wrappers.gh_cli import GHCLI

logger = logging.getLogger(__name__)


async def wait_for_pr(fbc_repo: FBCRepo) -> FBCRepo | None:
    ocps = fbc_repo.for_bundle.ocps
    if not ocps:
        logger.error(
            f"OCP Versions was empty for bundle {fbc_repo.for_bundle}"
        )
        return None

    statuses: list[CheckStatusDTO] = []
    for ocp in ocps:
        # v4.21 -> v421
        ocp = ocp.replace(".", "")
        check_name = config.get_fbc_component_name()
        check_name = check_name.replace("{ocp}", ocp)
        cs = CheckStatusDTO(name=check_name, status=CheckStatus.NOT_FOUND)
        statuses.append(cs)

    attempts = 1
    sleep_time = config.get_fbc_pr_refresh_seconds()
    while True:
        url = fbc_repo.pr_url

        try:
            checks_data = GHCLI(fbc_repo.tmp_dir.name).list_pr_checks(url)
        except Exception as e:
            logger.warning(f"Will retry fetching PR checks because: {e}")
            if attempts > config.get_fbc_pr_max_retries():
                logger.error(f"Error fetching PR checks")
                logger.exception(e)
                return None
            attempts += 1
            await sleep(sleep_time)
            continue

        for check_status in statuses:
            for check_data in checks_data:
                name = check_data.get("name", "")
                state = check_data.get("state", "")
                logger.debug(f"Found '{url}' '{name}' with status '{state}'")
                if f"{check_status.name}-on-pull-request" in name:
                    check_status.status = CheckStatus(state.lower())

        finished = 0
        for cs in statuses:
            if cs.status == CheckStatus.FAILURE:
                if attempts > config.get_fbc_pr_max_retries():
                    logger.error(f"Check '{url}' '{cs.name}' failed")
                    logger.error(f"Number of retries exceeded for PR {url}")
                    return None
                attempts += 1
                logger.warning(f"Check '{url}' '{cs.name}' failed, retrying")
                comment = f"/retest {cs.name}-on-pull-request"
                GHCLI(fbc_repo.tmp_dir.name).comment_on_pr(url, comment)
            elif cs.status in [CheckStatus.QUEUED, CheckStatus.IN_PROGRESS]:
                logger.info(f"Check {url} {cs.name} is still {cs.status}")
            elif cs.status == CheckStatus.SUCCESS:
                logger.info(f"Check {url} {cs.name} finished")
                finished += 1
                if finished == len(ocps):
                    logger.info(f"All checks succeeded for {url}")
                    return fbc_repo
            else:
                if attempts > config.get_fbc_pr_max_retries():
                    logger.error(
                        f"Check {url} {cs.name} unknown status {cs.status}"
                    )
                    logger.error(f"Number of retries exceeded for PR {url}")
                    return None
                attempts += 1
                logger.warning(
                    f"Unknown status '{url}' '{cs.name}' '{cs.status}'"
                )
                comment = f"/retest {cs.name}-on-pull-request"
                GHCLI(fbc_repo.tmp_dir.name).comment_on_pr(url, comment)
        # wait for konflux to schedule PLR
        logger.info(f"Waiting for {sleep_time}s")
        await sleep(sleep_time)
