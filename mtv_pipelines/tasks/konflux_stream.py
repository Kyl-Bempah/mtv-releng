"""Pure transforms for the konflux_stream pipeline.

Port of the file-rewriting parts of the "Konflux side" of scripts/branching.sh
(post-#53): the prod tenant rendered-stream transform, the btrfs tenant
ProjectDevelopmentStream block, and the ReleasePlanAdmission retargeting. I/O
(clone, build-single.sh, tox, commit, push) lives in the pipeline module.
"""

import re

_PIPELINE_ANNOTATION = "build.appstudio.openshift.io/pipeline:"
# The configure-pac-no-mr request annotation release streams carry (Components
# only). The shell hardcodes a 4-space indent regardless of the matched line's.
_PAC_NO_MR_LINE = "    build.appstudio.openshift.io/request: configure-pac-no-mr"
_PRODUCT_VERSION_RE = re.compile(r'      product_version: "[0-9]+\.[0-9]+"')


def transform_prod_stream(content: str, version_name: str, xy: str) -> str:
    """Turn operator/dev-preview.yaml into this version's rendered stream.

    Mirrors the three sed passes: dev-preview -> version_name, retarget
    ``revision: "main"`` -> the release branch, and append the configure-pac-no-mr
    request annotation after every pipeline annotation line.
    """
    content = content.replace("dev-preview", version_name)
    content = content.replace('revision: "main"', f'revision: "release-{xy}"')

    out: list[str] = []
    for line in content.split("\n"):
        out.append(line)
        if _PIPELINE_ANNOTATION in line:
            out.append(_PAC_NO_MR_LINE)
    return "\n".join(out)


def build_btrfs_pds_block(version_name: str, xy: str) -> str:
    """ProjectDevelopmentStream appended to the btrfs tenant's streams.yaml."""
    return (
        "---\n"
        "apiVersion: projctl.konflux.dev/v1beta1\n"
        "kind: ProjectDevelopmentStream\n"
        "metadata:\n"
        f"  name: forklift-operator-int-pds-{version_name}\n"
        "  namespace: rh-mtv-btrfs-tenant\n"
        "spec:\n"
        "  project: forklift-operator-int-project\n"
        "  template:\n"
        "    name: forklift-operator-int-template\n"
        "    values:\n"
        "      - name: versionName\n"
        f'        value: "{version_name}"\n'
        "      - name: revision\n"
        f'        value: "release-{xy}"\n'
    )


def transform_rpa(
    content: str, version_name: str, registry: str, xy: str
) -> str:
    """Retarget a ReleasePlanAdmission from dev-preview to this version.

    dev-preview -> version_name, mtv-candidate -> the release registry, and the
    product_version bumped to the X.Y stream.
    """
    content = content.replace("dev-preview", version_name)
    content = content.replace("mtv-candidate", registry)
    content = _PRODUCT_VERSION_RE.sub(
        f'      product_version: "{xy}"', content
    )
    return content
