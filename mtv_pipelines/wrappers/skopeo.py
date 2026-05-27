import json
import logging
import subprocess

from auth.auth import (
    REGISTRY_PROD_TOKEN,
    REGISTRY_PROD_USER,
    REGISTRY_STAGE_TOKEN,
    REGISTRY_STAGE_USER,
)

COMMAND = ["skopeo"]
PROTOCOL = "docker://"


logger = logging.getLogger(__name__)


class Skopeo:
    def __init__(self):
        self.cmd = COMMAND.copy()

    def __exec__(self):
        logger.info(f"Executing {self.cmd}")

        result = subprocess.run(
            self.cmd,
            capture_output=True,
        )
        try:
            result.check_returncode()
            return result.stdout
        except subprocess.CalledProcessError:
            err = result.stderr.decode("utf-8")
            raise RuntimeError(err)

    def __prepare_url__(self, url: str) -> str:
        if PROTOCOL in url:
            return url
        return PROTOCOL + url

    def inspect(self, img_url: str) -> dict:
        self.cmd.extend(
            [
                "inspect",
                "--no-tags",
                self.__prepare_url__(img_url),
            ]
        )

        return json.loads(self.__exec__())

    def copy(self, img_url: str, target_path: str) -> None:
        self.cmd.extend(
            [
                "copy",
                self.__prepare_url__(img_url),
                f"dir://{target_path}",
            ]
        )
        self.__exec__()

    def auth(self) -> None:
        self.cmd = ["bash", "-c"]
        s = "skopeo login registry.stage.redhat.io "
        s += f"-u ${REGISTRY_STAGE_USER} -p ${REGISTRY_STAGE_TOKEN}"
        self.cmd.append(s)
        self.__exec__()

        self.cmd = ["bash", "-c"]
        s = "skopeo login registry.redhat.io "
        s += f"-u ${REGISTRY_PROD_USER} -p ${REGISTRY_PROD_TOKEN}"
        self.cmd.append(s)
        self.__exec__()
