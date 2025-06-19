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
    components = parse_bundle(bundle)
    commits = {}
    for component, component_url in components.items():
        commits[component] = parse_component(component_url).get("COMMIT", "")

    pretty_print_commits(commits)


def pretty_print_commits(commits: dict):
    print(f"\n\nCommits")
    for component, commit in commits.items():
        print(f"{component}: {commit}")


if __name__ == "__main__":
    run()
