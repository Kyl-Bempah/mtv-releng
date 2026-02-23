import logging
import re

from config.config import get_cpe_version_init
from semver import Version
from wrappers.skopeo import Skopeo

logger = logging.getLogger(__name__)


class Bundle:
    def __init__(self, url: str):
        self.url: str = url
        self._inspection: dict
        self.digest: str = ""
        self.arch: str = ""
        self.version: Version
        self.commit: str
        self.ocps: list[str] = []
        self.channel: str = ""
        self.cpe: str = ""
        self.rhel: int | None = None

    # Inspect bundle image
    def inspect(self):
        logger.info(f"Inspecting bundle {self.url}")
        self._inspection = Skopeo().inspect(self.url)
        if not self._inspection:
            raise RuntimeError(
                f"Inspection data for bundle {self.url} is empty"
            )

    # Gather info from inspection data
    def parse_inspection(self):
        logger.info("Parsing bundle inspection data")
        if not self._inspection:
            raise RuntimeError(
                f"Inspection data for bundle {self.url} is empty"
            )

        digest = self._inspection.get("Digest")
        if not digest:
            raise RuntimeError(f"Couldn't get Digest from {self._inspection}")
        self.digest = digest.split(":")[1]
        # If digest was found, then modify bundle URL to use digest
        if "@sha" in self.url:
            self.url = f"{self.url.split(":")[0]}:{self.digest}"
        else:
            self.url = f"{self.url.split(":")[0]}@sha256:{self.digest}"

        logger.debug("Getting image architecture")
        arch = self._inspection.get("Architecture")
        if not arch:
            raise RuntimeError(
                f"Couldn't get Architecture from {self._inspection}"
            )
        self.arch = arch

        logger.debug("Getting image labels")
        labels = self._inspection.get("Labels")
        if not labels:
            raise RuntimeError(f"Couldn't get Labels from {self._inspection}")

        logger.debug(f"Getting MTV build version from {labels}")
        mtv_ver = labels.get("version")
        if not mtv_ver:
            raise RuntimeError(f"Couldn't get version from {self._inspection}")
        self.version = Version.parse(mtv_ver)

        logger.debug(f"Getting build revision from {labels}")
        commit = labels.get("revision")
        if not commit:
            logger.warning(
                f"Couldn't get revision from {self._inspection.get("Labels")}"
                "Will try with vcs-ref"
            )
            commit = labels.get("vcs-ref")
            if not commit:
                logger.error(f"Couldn't get vcs-ref from {self._inspection}")
                raise RuntimeError(f"Couldn't get vcs-ref from bundle {self}")
        self.commit = commit

        logger.debug(f"Getting OCP versions from {labels}")
        ocps = labels.get("com.redhat.openshift.versions")
        if not ocps:
            raise RuntimeError(
                f"Couldn't get ocp versions form {self._inspection}"
            )
        # convert v4.19-4.21 to list [v4.19, v4.20, v4.21]
        # https://redhat-connect.gitbook.io/certified-operator-guide/ocp-deployment/operator-metadata/bundle-directory/managing-openshift-versions
        if "-" in ocps:
            try:
                low_x, low_y = ocps.split("-")[0].lstrip("v").split(".")
                high_x, high_y = ocps.split("-")[1].lstrip("v").split(".")
                for x in range(int(low_x), int(high_x) + 1):
                    for y in range(int(low_y), int(high_y) + 1):
                        self.ocps.append(f"v{x}.{y}")
            except Exception:
                raise RuntimeError(
                    f"Couldn't parse {ocps} in individual versions"
                )
        elif "=" in ocps:
            self.ocps = [ocps.replace("=", "")]
        else:
            self.ocps = [ocps]

        logger.debug(f"Getting OCP channel from {labels}")
        channel = labels.get(
            "operators.operatorframework.io.bundle.channels.v1"
        )
        if not channel:
            raise RuntimeError(
                f"Couldn't get operator channel from {self._inspection}"
            )
        self.channel = channel

        # CPEs started with MTV 2.9.5
        if self.version >= Version.parse(get_cpe_version_init()):
            logger.debug(f"Getting CPE from {labels}")
            cpe = labels.get("cpe")
            if not cpe:
                raise RuntimeError(f"Couldn't get CPE from {self._inspection}")
            self.cpe = cpe

        if self.cpe:
            logger.debug(f"Getting RHEL version from {self.cpe}")
            m = re.search(r"el(\d*)", self.cpe)
            if not m:
                raise RuntimeError(
                    f"Couldn't get RHEL version from {self.cpe}"
                )
            self.rhel = int(m.group(1))

    def __str__(self):
        s = "Bundle:\n"
        s += f"  URL: {self.url}"
        if hasattr(self, "_inspection"):
            s += f"\n  Digest: {self.digest}\n"
            s += f"  MTV version: {self.version}\n"
            s += f"  Commit: {self.commit}\n"
            s += f"  OCPs: {self.ocps}\n"
            s += f"  Channel: {self.channel}\n"
            s += f"  Arch: {self.arch}\n"
            s += f"  CPE: {self.cpe}\n"
            s += f"  RHEL: {self.rhel}"
        return s
