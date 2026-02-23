from semver import Version
from wrappers.skopeo import Skopeo


class IIB:
    def __init__(self, url: str, version: Version):
        self.version = version
        self.url = url

    def inspect(self):
        return Skopeo().inspect(self.url)

    def __str__(self):
        s = "IIB:\n"
        s += f"  Version: {self.version}\n"
        s += f"  URL: {self.url}"
        return s
