import asyncio
import logging
from typing import Any, Dict, List

import git

logger = logging.getLogger(__name__)


class Git:
    def __init__(self, repo_path: str):
        self.repo_path = repo_path

    async def clone(self, url: str) -> None:
        logger.info(f"Cloning from {url} to {self.repo_path}")
        self.repo = await asyncio.to_thread(
            git.Repo.clone_from, url, self.repo_path
        )
        logger.info(f"Finished cloning from {url} to {self.repo_path}")

    async def pull(
        self, branch: str = "main", remote_name: str = "origin"
    ) -> None:
        self._ensure_repo()
        try:
            remote = self.repo.remote(name=remote_name)
            logger.info(f"Pulling from {str(remote)}/{branch}...")
            await asyncio.to_thread(remote.pull, branch)
            logger.info("Pull successful")
        except ValueError:
            raise RuntimeError(f"Remote {remote_name} not found")
        except git.GitCommandError as e:
            raise RuntimeError(f"Error pulling changes: {e}")

    def push(self, branch: str = "main", remote_name: str = "origin") -> None:
        self._ensure_repo()
        try:
            remote = self.repo.remote(name=remote_name)
            logger.info(f"Pushing to {remote}/{branch}...")
            remote.push(refspec=f"{branch}:{branch}")
            logger.info("Push successful")
        except ValueError:
            raise RuntimeError(f"Remote {remote_name} not found")
        except git.GitCommandError as e:
            raise RuntimeError(f"Error pushing changes: {e}")

    def log(self, max_count: int = 10) -> List[Dict[str, Any]]:
        self._ensure_repo()
        logs = []
        for commit in self.repo.iter_commits(max_count=max_count):
            logs.append(
                {
                    "sha": commit.hexsha,
                    "author": commit.author.name,
                    "date": commit.committed_datetime.isoformat(),
                    "message": commit.message.strip(),
                }
            )
        return logs

    def branches(self) -> List[str]:
        self._ensure_repo()
        return [head.name for head in self.repo.heads]

    def remote_branches(self) -> List[str]:
        self._ensure_repo()
        branches = []
        for remote in self.repo.remotes:
            for ref in remote.refs:
                branches.append(ref.name)
        return branches

    def checkout(self, branch: str, create: bool = False) -> None:
        self._ensure_repo()
        if create:
            logger.info(f"Creating and checking out new branch {branch}")
            self.repo.git.checkout("-b", branch)
        else:
            logger.info(f"Checking out {branch}")
            self.repo.git.checkout(branch)

        if not self.repo.head.is_detached:
            logger.info(f"Switched to branch: {self.repo.active_branch.name}")
        else:
            logger.info(
                f"HEAD is now detached at {self.repo.head.commit.hexsha[:7]}"
            )

    def fetch(self, branch: str, origin: str = "origin") -> None:
        self._ensure_repo()
        logger.info(f"Fetching branch '{branch}' from origin '{origin}'")
        self.repo.git.fetch(origin, branch)

    def config(self, option: str, value: str):
        self._ensure_repo()
        self.repo.git.config(option, value)

    def has_changes(self):
        logger.debug(
            f"Repo {self.repo_path} has these changes "
            f"{self.repo.git.execute(["git", "--no-pager", "diff"])}"
        )
        return self.repo.is_dirty(untracked_files=True)

    def add_files(self, files: list[str]):
        self.repo.index.add(files)

    def commit(self, message: str):
        self.repo.git.commit("-s", "-m", message)

    def _ensure_repo(self):
        if self.repo is None:
            raise RuntimeError(
                "Repository not initialized. Run clone() or ensure path is valid."
            )
