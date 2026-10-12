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
        except FileNotFoundError:
            raise RuntimeError(
                f"`{self.cmd[0]}` not found on PATH; is the OpenShift CLI "
                "installed in the image?"
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

    def current_server(self) -> str:
        """The cluster the current session is logged into, or '' if none."""
        self.cmd = COMMAND + ["whoami", "--show-server"]
        try:
            return self.__exec__().decode("utf-8").strip()
        except RuntimeError:
            return ""

    def login(self, server: str, token: str) -> None:
        """`oc login --token=... --server=...`; never logs the token."""
        logger.info(f"Logging into {server}")
        try:
            result = subprocess.run(
                COMMAND + ["login", f"--token={token}", f"--server={server}"],
                capture_output=True,
                timeout=config.get_timeouts()["oc_command_seconds"],
            )
        except FileNotFoundError:
            raise RuntimeError(
                "`oc` not found on PATH; is the OpenShift CLI installed in the image?"
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"`oc login` to {server} timed out")
        if result.returncode != 0:
            raise RuntimeError(
                f"oc login to {server} failed: "
                f"{result.stderr.decode('utf-8').strip()}"
            )

    def ensure_login(self, server: str, token: str) -> None:
        """Reuse an existing session for this cluster, else log in.

        Port of util.sh's ensure_oc_login.
        """
        if self.current_server() == server:
            return
        self.login(server, token)

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
