import argparse

from modules.bundle.mtv import parse_bundle
from modules.component.mtv import parse_component
from modules.iib.mtv import parse_iib
from modules.utils import utils

parser = argparse.ArgumentParser(
    prog="MTV Releng tooling",
    description="Simplify some tasks",
)

parser.add_argument("-i", "--iib", required=True)
parser.add_argument("-v", "--version", required=True)

parser.usage = """
python main.py -i <iib_url> -v <bundle_version>

Examples:
python main.py -i quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v418:on-pr-76657e65fa4e6ff445965976200aed1ad7adbb7d -v 2.9.0
python main.py -i registry-proxy.engineering.redhat.com/rh-osbs/iib:985689 -v 2.8.5
python main.py -i registry.redhat.io/redhat/redhat-operator-index:v4.18 -v 2.8.5

"""


# TODO: Expand to sub commands e.g. 'main.py inspect' for info extraction or 'main.py branch' for new release branching
def run():
    args = parser.parse_args()
    bundle = parse_iib(args.iib, args.version)["BUNDLE_IMAGE"]
    bundle = utils.convert_tag_to_sha(bundle)
    bundle = replace_for_quay(bundle, args.version)
    components = parse_bundle(bundle)
    commits = {}
    for component, component_url in components.items():
        component_url = replace_for_quay(component_url, args.version)
        commits[component] = parse_component(component_url).get("COMMIT", "")

    pretty_print_commits(commits)


def pretty_print_commits(commits: dict):
    print(f"\n\nCommits")
    for component, commit in commits.items():
        print(f"{component}: {commit}")


def replace_for_quay(img: str, version: str) -> str:
    if version < "2.8.6":
        return img
    if "redhat.io" in img:
        parts = img.split("/")
        registry = "quay.io/redhat-user-workloads/rh-mtv-1-tenant/"
        if parts[1] == "mtv-candidate":
            version = "dev-preview"
        else:
            version = version[:-2].replace(".", "-")
        repo = f"forklift-operator-{version}/"
        component = map_component(parts[2].split("@")[0])
        if not component:
            return img
        return f"{registry}{repo}{component}-{version}@{parts[2].split("@")[1]}"
    elif "quay.io" in img:
        return img

def map_component(cmp: str)-> str:
    cmps = {
        "mtv-controller-rhel9": "forklift-controller",
        "mtv-must-gather-rhel8": "forklift-must-gather",
        "mtv-validation-rhel9":"validation",
        "mtv-api-rhel9":"forklift-api",
        "mtv-populator-controller-rhel9":"populator-controller",
        "mtv-rhv-populator-rhel8":"ovirt-populator",
        "mtv-virt-v2v-rhel9":"virt-v2v",
        "mtv-openstack-populator-rhel9":"openstack-populator",
        "mtv-console-plugin-rhel9":"forklift-console-plugin",
        "mtv-ova-provider-server-rhel9":"ova-provider-server",
        "mtv-vsphere-xcopy-volume-populator-rhel9":"vsphere-xcopy-volume-populator",
        "mtv-rhel9-operator":"forklift-operator",
        "mtv-operator-bundle": "forklift-operator-bundle"
    }
    return cmps.get(cmp)

if __name__ == "__main__":
    run()
