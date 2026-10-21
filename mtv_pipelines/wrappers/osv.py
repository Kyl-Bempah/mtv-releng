import logging

import requests
from config import config

logger = logging.getLogger(__name__)


def get_vuln(vuln_id: str) -> dict | None:
    """Fetch an OSV record (CVE-*, GHSA-*, GO-*, PYSEC-*); None if unknown."""
    url = f"{config.get_cve_triage()['osv_api']}/{vuln_id}"
    try:
        resp = requests.get(url, timeout=config.get_timeouts()["http_seconds"])
    except requests.RequestException as e:
        logger.warning(f"OSV lookup for {vuln_id} failed: {e}")
        return None
    if resp.status_code != 200:
        logger.info(f"OSV has no record for {vuln_id} ({resp.status_code})")
        return None
    return resp.json()
