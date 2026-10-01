"""SHA-extraction and Containerfile-editing logic for the bundle_sync pipeline.

Port of the pure/domain parts of scripts/bundle_sync.sh: probing the
Containerfile-downstream for virt-v2v ARGs, validating snapshot components in
quay, building the component -> SHA mapping (including the virt-v2v-int SHA
pulled from the internal quay tenant), resolving ARG names, and computing the
ARG line edits. Network calls live here too (quay API, skopeo) but are kept out
of the pipeline module so the mapping rules stay testable.
"""

import logging
import re
from dataclasses import dataclass

import requests

from wrappers.skopeo import Skopeo

logger = logging.getLogger(__name__)

QUAY_TAG_API = "https://quay.io/api/v1/repository/{repo_path}/tag/"
VIRT_V2V_INT_REPO_PATH = (
    "redhat-user-workloads/rh-mtv-btrfs-tenant/"
    "forklift-operator-int-{version}/virt-v2v-int-{version}"
)

_SHA_RE = re.compile(r"^[a-f0-9]{64}$")
# VIRT_V2V_IMAGE line must not match VIRT_V2V_IMAGE_RHEL9 (stops before _RHEL9).
_ARG_VIRT_V2V_MAIN = re.compile(r'^ARG VIRT_V2V_IMAGE[\s="]', re.M)
_ARG_VIRT_V2V_RHEL9 = re.compile(r'^ARG VIRT_V2V_IMAGE_RHEL9[\s="]', re.M)
_ARG_IMAGE_LINE = re.compile(r"^ARG\s+([A-Za-z0-9_]+_IMAGE)\s*=", re.M)
_SHA_IN_IMAGE = re.compile(r"@sha256:[a-f0-9]{64}")


@dataclass
class VirtV2vProbe:
    arg_count: int = 1
    has_main: bool = False
    has_rhel9: bool = False
    int_key: str = ""


@dataclass
class ContainerfileUpdate:
    arg_name: str
    old_line: str
    new_line: str


def probe_containerfile_virt_v2v(content: str, version: str) -> VirtV2vProbe:
    """Count the virt-v2v ARG slots in a Containerfile-downstream.

    Returns the ARG count (0, 1 or 2), which slots are present, and the
    single-slot virt-v2v-int mapping key (empty unless exactly one slot).
    """
    has_main = bool(_ARG_VIRT_V2V_MAIN.search(content))
    has_rhel9 = bool(_ARG_VIRT_V2V_RHEL9.search(content))
    count = int(has_main) + int(has_rhel9)
    int_key = ""
    if count == 1:
        int_key = (
            f"virt-v2v-{version}" if has_main else f"virt-v2v-rhel9-{version}"
        )
    return VirtV2vProbe(count, has_main, has_rhel9, int_key)


# ---------------------------------------------------------------------------
# virt-v2v special-casing (this function + add_virt_v2v_int_sha below).
#
# virt-v2v is built internally and is NOT in the Konflux snapshot, so its SHA
# is pulled separately from the internal quay tenant. Two functions cooperate:
#   - virt_v2v_should_skip_snapshot_row drops the snapshot virt-v2v rows that
#     will instead be filled from the internal build.
#   - add_virt_v2v_int_sha fetches the internal SHA and writes it to the slot.
#
# WHEN virt-v2v MOVES BACK INTO THE PUBLIC REPO / KONFLUX SNAPSHOT:
#   Undo this special-casing, or the bundle will ignore the snapshot SHA and
#   keep pinning the (now stale/absent) internal build. The change is:
#     1. Make virt_v2v_should_skip_snapshot_row return False always, so the
#        virt-v2v rows flow through build_sha_mapping like any other component.
#     2. Stop calling add_virt_v2v_int_sha from the pipeline (and delete it).
#   Nothing else changes: config already maps virt-v2v -> VIRT_V2V_IMAGE and
#   virt-v2v-rhel9 -> VIRT_V2V_IMAGE_RHEL9, and get_base_component_name strips
#   the version suffix, so the snapshot rows resolve to the right ARGs.
# ---------------------------------------------------------------------------
def virt_v2v_should_skip_snapshot_row(name: str, arg_count: int) -> bool:
    """Whether a snapshot virt-v2v row's SHA should be ignored.

    Single-slot bundles take the virt-v2v slot from virt-v2v-int instead of the
    snapshot. Dual-slot bundles take VIRT_V2V_IMAGE from virt-v2v-int and only
    VIRT_V2V_IMAGE_RHEL9 from the snapshot.
    """
    if "virt-v2v" not in name or "virt-v2v-int" in name:
        return False
    if arg_count < 2:
        return True
    if "virt-v2v-rhel9" not in name:
        return True
    return False


def get_base_component_name(component: str) -> str:
    """Strip version/channel suffixes so an ARG lookup has a single key."""
    base = re.sub(r"-[0-9].*$", "", component)
    base = re.sub(r"-dev-preview$", "", base)
    base = re.sub(r"-rc[0-9]*$", "", base)
    base = re.sub(r"-alpha$|-beta$|-stable$", "", base)
    return base


def get_arg_name_for_component(
    component: str, containerfile: str, mappings: dict
) -> str:
    """Resolve the Containerfile ARG name for a snapshot component.

    Prefers the configured mapping; falls back to the longest matching existing
    *_IMAGE ARG so e.g. populator-controller maps to POPULATOR_CONTROLLER_IMAGE,
    not CONTROLLER_IMAGE.
    """
    base = get_base_component_name(component)

    arg_name = mappings.get(base)
    if arg_name and re.search(
        rf"^ARG {re.escape(arg_name)}\s*=", containerfile, re.M
    ):
        return arg_name

    best_arg = ""
    best_len = 0
    for arg in _ARG_IMAGE_LINE.findall(containerfile):
        pattern = arg.removesuffix("_IMAGE").replace("_", "-").lower()
        if base in pattern or pattern in base:
            if len(pattern) > best_len:
                best_arg = arg
                best_len = len(pattern)
    return best_arg


def validate_components_in_quay(
    snapshot_data: list[dict], arg_count: int
) -> None:
    """Confirm every (non-skipped) snapshot component exists in quay.

    Raises RuntimeError listing the components that could not be inspected.
    """
    logger.info("Validating components exist in quay...")
    failed: list[str] = []
    for comp in snapshot_data:
        name = comp.get("name") or ""
        image = comp.get("containerImage")
        if not image:
            logger.warning(
                f"Component {name} has no containerImage, skipping validation"
            )
            continue
        if "virt-v2v" in name and "virt-v2v-int" not in name:
            if virt_v2v_should_skip_snapshot_row(name, arg_count):
                logger.info(
                    f"Skipping validation for {name} "
                    "(virt-v2v slot comes from virt-v2v-int, not snapshot)"
                )
                continue
        try:
            Skopeo().inspect(image)
            logger.info(f"Validated: {name}")
        except Exception as e:
            logger.error(f"Failed to validate {name} (image: {image}): {e}")
            failed.append(name)

    if failed:
        raise RuntimeError(
            f"Components do not exist in quay: {', '.join(failed)}"
        )
    logger.info("All components validated successfully in quay")


def build_sha_mapping(
    snapshot_data: list[dict], probe: VirtV2vProbe
) -> dict[str, str]:
    """Map base component name -> SHA from the snapshot (bundle row excluded)."""
    mapping: dict[str, str] = {}
    for comp in snapshot_data:
        name = comp.get("name") or ""
        image = comp.get("containerImage") or ""
        if not image:
            continue
        if "virt-v2v" in name and "virt-v2v-int" not in name:
            if virt_v2v_should_skip_snapshot_row(name, probe.arg_count):
                continue
        sha = image.rsplit("sha256:", 1)[-1]
        if not _SHA_RE.match(sha):
            continue
        # Skip the bundle component: we're updating the bundle's own Containerfile.
        if "bundle" in name:
            continue
        mapping[get_base_component_name(name)] = sha
    return mapping


def get_latest_virt_v2v_int_sha(version: str) -> str:
    """Latest virt-v2v-int digest from the internal quay tenant (on-push tag)."""
    if not version:
        raise ValueError("Version is required to fetch virt-v2v-int SHA")

    repo_path = VIRT_V2V_INT_REPO_PATH.format(version=version)
    image_base = f"quay.io/{repo_path}"
    api_url = QUAY_TAG_API.format(repo_path=repo_path)

    logger.info(
        f"Fetching latest virt-v2v-int SHA for version {version} "
        f"(repo: {image_base})"
    )
    resp = requests.get(api_url)
    if resp.status_code != 200:
        raise RuntimeError(
            f"Failed to fetch tags from Quay.io API "
            f"({resp.status_code}): {api_url}"
        )
    data = resp.json()
    if data.get("error_message"):
        raise RuntimeError(f"Quay.io API error: {data['error_message']}")
    tags = data.get("tags")
    if tags is None:
        raise RuntimeError(
            f"Invalid API response from Quay.io: {resp.text[:200]}"
        )

    on_push = [t for t in tags if "on-push" in (t.get("name") or "")]
    if not on_push:
        raise RuntimeError(f"No on-push tags found for virt-v2v-int-{version}")
    latest_tag = max(on_push, key=lambda t: t.get("start_ts") or 0)["name"]
    logger.info(f"Found latest on-push tag: {latest_tag}")

    digest = Skopeo().inspect(f"{image_base}:{latest_tag}").get("Digest", "")
    sha = digest.removeprefix("sha256:")
    if not _SHA_RE.match(sha):
        raise RuntimeError(f"Invalid SHA format: {sha}")
    logger.info(f"Found virt-v2v-int SHA: {sha} (from tag {latest_tag})")
    return sha


def add_virt_v2v_int_sha(
    mapping: dict[str, str], version: str, probe: VirtV2vProbe
) -> None:
    """Append the virt-v2v-int SHA to the mapping based on the probed ARG slots.

    Single-slot fills the only ARG; dual-slot fills VIRT_V2V_IMAGE (RHEL9 comes
    from the snapshot). A failed fetch is logged and left non-fatal (matching the
    shell): the other components still update. Note this only catches an
    *unreachable* int repo — a reachable-but-frozen repo returns a stale SHA that
    this cannot detect (see the note above virt_v2v_should_skip_snapshot_row).
    """
    if not version:
        logger.warning("Version not provided, skipping virt-v2v-int SHA fetch")
        return
    if probe.arg_count == 0:
        logger.info("No virt-v2v ARGs in Containerfile; skipping virt-v2v-int")
        return

    if probe.arg_count == 1:
        map_key = probe.int_key or f"virt-v2v-{version}"
    elif probe.has_main:
        map_key = f"virt-v2v-{version}"
    else:
        logger.info("No VIRT_V2V_IMAGE ARG in Containerfile; skipping virt-v2v-int")
        return

    try:
        mapping[map_key] = get_latest_virt_v2v_int_sha(version)
        logger.info(f"Added virt-v2v-int SHA to mapping as: {map_key}")
    except Exception as e:
        # Non-fatal: the other components still update. A hard failure here was
        # considered but only catches a *vanished* int repo (not the likelier
        # frozen-repo staleness), at the cost of failing on transient quay blips.
        # The real safeguard is the move-back procedure above.
        logger.warning(f"Failed to get virt-v2v-int SHA from quay: {e}")


def compute_containerfile_updates(
    content: str, sha_mapping: dict[str, str], mappings: dict
) -> tuple[str, list[ContainerfileUpdate], int, int]:
    """Apply SHA updates to ARG lines; return new content and a change summary.

    Returns (new_content, updates, skipped_up_to_date, missing).
    """
    lines = content.splitlines()
    updates: list[ContainerfileUpdate] = []
    skipped = 0
    missing = 0

    for component, new_sha in sha_mapping.items():
        arg_name = get_arg_name_for_component(component, content, mappings)
        if not arg_name:
            logger.warning(
                f"Could not determine ARG name for component: {component}"
            )
            missing += 1
            continue

        idx = next(
            (i for i, ln in enumerate(lines) if ln.startswith(f"ARG {arg_name}=")),
            None,
        )
        if idx is None:
            logger.warning(f"ARG {arg_name} not found in Containerfile")
            missing += 1
            continue

        old_line = lines[idx]
        m = re.search(r"@sha256:([a-f0-9]{64})", old_line)
        current_sha = m.group(1) if m else ""
        if current_sha == new_sha:
            logger.info(f"Skipping {arg_name} - SHA already up to date ({new_sha})")
            skipped += 1
            continue

        im = re.search(r'^ARG [^=]*="([^"]*)"', old_line)
        current_image = im.group(1) if im else ""
        new_image = _SHA_IN_IMAGE.sub(f"@sha256:{new_sha}", current_image)
        new_line = f'ARG {arg_name}="{new_image}"'
        lines[idx] = new_line
        updates.append(ContainerfileUpdate(arg_name, old_line, new_line))
        logger.info(f"Updated {arg_name}")

    new_content = "\n".join(lines)
    if content.endswith("\n"):
        new_content += "\n"
    return new_content, updates, skipped, missing
