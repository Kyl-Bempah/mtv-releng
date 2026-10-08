import json
import logging
import subprocess

from config import config

COMMAND = ["oc"]

logger = logging.getLogger(__name__)


class Oc:
    """Thin wrapper around the parts of `oc` the sync pipelines need.

    Mirrors the behaviour of scripts/latest_release.sh, snapshot_from_release.sh
    and snapshot_content.sh. Assumes the caller is already logged into the right
    cluster (same assumption the shell scripts make).
    """

    def __init__(self):
        self.cmd = COMMAND.copy()

    def __exec__(self, timeout: int | None = None) -> bytes:
        timeout = timeout or config.get_timeouts()["oc_command_seconds"]
        logger.info(f"Executing {self.cmd}")
        try:
            result = subprocess.run(
                self.cmd, capture_output=True, timeout=timeout
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError(
                f"`oc` timed out after {timeout}s: {' '.join(self.cmd)}"
            )
        try:
            result.check_returncode()
            return result.stdout
        except subprocess.CalledProcessError:
            raise RuntimeError(result.stderr.decode("utf-8"))

    # Mirrors latest_release.sh: newest Succeeded release for the version/target.
    def latest_release(
        self, version: str, target: str, rhel: str | None = None
    ) -> str:
        self.cmd = COMMAND.copy()
        self.cmd.extend(
            ["get", "releases", "--sort-by={.metadata.creationTimestamp}"]
        )
        output = self.__exec__().decode("utf-8")

        # Trailing "-" bounds the version so e.g. "2-11" doesn't match "2-110"
        # and "2.10.1" doesn't match "2.10.10" (the version is always followed
        # by "-rp-..." in the release name).
        needles = ["Succeeded", f"forklift-operator-{version}-", f"rp-{target}"]
        if rhel:
            needles.append(f"-rhel{rhel}")

        latest = ""
        for line in output.splitlines():
            if all(n in line for n in needles):
                latest = line.split()[0]
        return latest

    # Mirrors snapshot_from_release.sh: the snapshot a release was built from.
    def snapshot_from_release(self, release: str) -> str:
        self.cmd = COMMAND.copy()
        self.cmd.extend(["get", "-o", "json", "release", release])
        data = json.loads(self.__exec__())
        return data.get("spec", {}).get("snapshot", "")

    # Mirrors snapshot_content.sh: component -> containerImage pairs, sorted.
    def snapshot_content(self, snapshot: str) -> list[dict]:
        self.cmd = COMMAND.copy()
        self.cmd.extend(["get", "-o", "json", "snapshot", snapshot])
        data = json.loads(self.__exec__())
        components = [
            {"name": c.get("name"), "containerImage": c.get("containerImage")}
            for c in data.get("spec", {}).get("components", [])
        ]
        return sorted(components, key=lambda c: c["name"] or "")
