import json
import logging
import subprocess

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

    def __exec__(self) -> bytes:
        logger.info(f"Executing {self.cmd}")
        result = subprocess.run(self.cmd, capture_output=True)
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

        needles = ["Succeeded", f"forklift-operator-{version}", f"rp-{target}"]
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
