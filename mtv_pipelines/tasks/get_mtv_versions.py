import json
import logging
import re

import requests
from config import config
from requests.exceptions import SSLError

"""Return example
{
    "forklift": {
        "main": "2.11.0",
        "release-2.10": "2.10.2",
        ...
    },
    "forklift-console-plugin":{
        "main": "2.11.0",
        ...
    },
    "forklift-must-gather":{
    ...
    }
}
"""

logger = logging.getLogger("get_mtv_versions")


def get_mtv_versions():
    repos = config.get_mtv_repositories()
    branches = config.get_mtv_branches()
    raw_mappings = config.get_raw_mappings()
    versions = {}
    for cmp, url in repos.items():
        for branch in branches:
            target = raw_mappings.get(cmp, "").replace("{branch}", branch)
            try:
                resp = requests.get(target)
            except SSLError as ex:
                if "self-signed" in str(ex):
                    resp = requests.get(target, verify=False)
                else:
                    raise ex
            if resp.status_code != 200:
                raise RuntimeError(f"{resp.url} returned {resp.status_code}")
            logger.debug(f"Response: {json.dumps(resp.text)}")
            m = re.search(r"VERSION=(\d*\.\d*\.\d*)", resp.text)
            if m:
                r_ver = m.group(1)
                if not r_ver:
                    raise RuntimeError(
                        f"Failed to extract re.match form {resp.text}"
                    )
                if not versions.get(cmp):
                    versions[cmp] = {}
                versions[cmp][branch] = r_ver
            else:
                raise RuntimeError(f"Didn't find 'VERSION=X.Y.Z' in {url}")
    return versions
