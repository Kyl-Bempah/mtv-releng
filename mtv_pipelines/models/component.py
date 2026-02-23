import logging

from semver.version import Version
from wrappers.skopeo import Skopeo

logger = logging.getLogger(__name__)


class Component:
    def __init__(self, url: str):
        self.url: str = url
        self._inspection: dict
        self.digest: str = ""
        self.arch: str = ""
        self.version: Version
        self.commit: str = ""
        self.name: str = ""

    # Inspect component image
    def inspect(self):
        logger.info(f"Inspecting component {self.url}")
        self._inspection = Skopeo().inspect(self.url)
        if not self._inspection:
            raise RuntimeError(
                f"Inspection data for component {self.url} is empty"
            )

    # Gather info from inspection data
    def parse_inspection(self):
        logger.info("Parsing component inspection data")
        if not self._inspection:
            raise RuntimeError(
                f"Inspection data for component {self.url} is empty"
            )

        digest = self._inspection.get("Digest")
        if not digest:
            raise RuntimeError(f"Couldn't get Digest from {self._inspection}")
        self.digest = digest.split(":")[1]
        # If digest was found, then modify bundle URL to use digest
        self.url = f"{self.url.split(":")[0]}@sha256:{self.digest}"

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

        logger.debug(f"Getting component name from {labels}")
        name = labels.get("com.redhat.component")
        if not name:
            raise RuntimeError(
                f"Couldn't get component name from {self._inspection}"
            )
        self.name = name

    def __str__(self):
        s = "Component:\n"
        s += f"  URL: {self.url}"
        if hasattr(self, "_inspection"):
            s += f"\n  Name: {self.name}\n"
            s += f"  Digest: {self.digest}\n"
            s += f"  MTV version: {self.version}\n"
            s += f"  Commit: {self.commit}\n"
        return s
