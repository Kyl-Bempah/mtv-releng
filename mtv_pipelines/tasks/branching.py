"""Pure transforms for the branching pipeline.

Port of the file-rewriting parts of scripts/branching.sh (the ``release_conf_*``
heredocs and the ``.tekton`` sed edits of ``process_repo``). Kept free of I/O so
the rewrite rules stay testable; the pipeline module does the clone/commit/push.
"""

from semver import Version

# release.conf differs per repo only in the name of the global version key and
# whether it carries OCP_VERSIONS (forklift does, the others do not).
_VERSION_KEY = {
    "forklift": "MTV_VERSION",
    "forklift-console-plugin": "RVERSION",
    "forklift-must-gather": "VERSION",
}


def mtv_version_parts(version: str) -> tuple[str, str]:
    """(xy, version_name) for an x.y.z version, e.g. "2.11.0" -> ("2.11", "2-11")."""
    v = Version.parse(version)
    return f"{v.major}.{v.minor}", f"{v.major}-{v.minor}"


def render_release_conf(
    origin: str,
    version: str,
    release: str,
    channel: str,
    default_channel: str,
    registry: str,
    ocp_versions: str,
) -> str:
    """Regenerate build/release.conf for *origin* (matches the shell heredocs)."""
    version_key = _VERSION_KEY.get(origin)
    if version_key is None:
        raise ValueError(f"No release.conf template for origin '{origin}'")
    xy, _ = mtv_version_parts(version)

    lines = [
        '# Global version specifying version for every component and for bundle, format "x.y.z"',
        f"{version_key}={version}",
        "",
        '# Release version, format "vX.Y"',
        f"RELEASE={release}",
        "",
        '# This setting must mirror the Y stream version specified above, e.g. if RELEASE == v2.10 then CPE == 2.10 (without the "v")',
        f"CPE={xy}",
        "",
        "# Operator channel where the version will be deployed, e.g. dev-preview, release-v2.9 ...",
        f"CHANNEL={channel}",
        "",
        "# Default operator channel for other operators to pull from, if they depend on MTV",
        f"DEFAULT_CHANNEL={default_channel}",
        "",
        "# Registry where all components should be released to, for dev-preview -> mtv-candidate, for release-X.Y -> migration-toolkit-virtualization",
        f"REGISTRY={registry}",
    ]
    if origin == "forklift":
        lines += [
            "",
            "# Which OCP versions are supported by this release",
            f"OCP_VERSIONS={ocp_versions}",
        ]
    return "\n".join(lines) + "\n"


def transform_tekton_content(content: str, version_name: str, xy: str) -> str:
    """Retarget a .tekton file from dev-preview/main to the release stream.

    Mirrors the two sed passes in process_repo: on-cel branch filter
    ``"main"`` -> ``"release-X.Y"``, then every ``dev-preview`` -> version_name.
    """
    content = content.replace('"main"', f'"release-{xy}"')
    content = content.replace("dev-preview", version_name)
    return content
