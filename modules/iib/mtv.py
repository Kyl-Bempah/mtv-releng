from ..utils import utils


def parse_iib(iib_url: str, version: str) -> dict:
    """Parses IIB and returns BUNDLE image"""

    if not iib_url:
        raise Exception("IIB URL was not supplied")
    if not version:
        raise Exception("Version was not supplied")

    command = ["bash", "scripts/iib.sh", iib_url, version]

    out = utils.run_command(command)

    if not out:
        print("Was unable to find BUNDLE image in specified IIB")
        exit(1)

    return utils.parse_key_val_output(out)
