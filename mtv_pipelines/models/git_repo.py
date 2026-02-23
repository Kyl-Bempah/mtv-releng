import logging

from utils import create_temp_dir
from wrappers.git import Git


class GitRepo:
    def __init__(self, url: str, name: str, version: str):
        self.tmp_dir = create_temp_dir(name + version)
        self.url = url
        self.name = name
        self.version = version
        self.logger = logging.getLogger(self.tmp_dir.name)

    async def init(self):
        self.git = Git(self.tmp_dir.name)
        await self.git.clone(self.url)

    def __str__(self):
        s = "GitRepo:\n"
        s += f"  Name: {self.name}"
        s += f"  URL: {self.url}"
        s += f"  Version: {self.version}"
        s += f"  TmpDir: {self.tmp_dir.name}"
        return s
