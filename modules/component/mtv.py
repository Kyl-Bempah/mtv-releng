from ..utils import utils


def parse_component(component_url: str) -> dict:
    """Parses COMPONENT and returns it's build commit"""

    if not component_url:
        raise Exception("COMPONENT URL was not supplied")

    command = ["bash", "scripts/component.sh", component_url]

    out = utils.run_command(command)

    if not out:
        print("Was unable to find commit in specified COMPONENT")

    return utils.parse_key_val_output(out)
