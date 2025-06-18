from ..utils import utils


def parse_bundle(bundle_url: str) -> dict:
    """Parses BUNDLE and returns components images"""

    if not bundle_url:
        raise Exception("BUNDLE URL was not supplied")

    command = ["bash", "scripts/bundle.sh", bundle_url]

    out = utils.run_command(command)

    if not out:
        print("Was unable to find COMPONENT images in specified BUNDLE")

    return utils.parse_key_val_output(out)