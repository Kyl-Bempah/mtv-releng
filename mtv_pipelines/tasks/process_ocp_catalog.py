import asyncio
import logging

from models.bundle import Bundle
from models.fbc_repo import FBCRepo
from semver.version import Version

logger = logging.getLogger(__name__)


async def process_ocp_catalog(
    fbc: FBCRepo,
    ocp: str,
    bundle: Bundle,
    tg: asyncio.TaskGroup,
):
    logger.info(f"Processing {ocp} catalog")
    # If catalog is missing, create it
    new_catalog = False
    if not fbc.has_catalog(ocp):
        await tg.create_task(asyncio.to_thread(fbc.init_catalog, ocp))
        new_catalog = True

    # Exit if bundle already present in the catalog
    if fbc.catalog_has_bundle(ocp):
        logger.info(f"Bundle {bundle.digest} already present in catalog {ocp}")
        return

    # Regenerate the catalog in case the bundle was added
    if not new_catalog:
        await tg.create_task(asyncio.to_thread(fbc.init_catalog, ocp))

    # Check again in case bundle was added
    if fbc.catalog_has_bundle(ocp):
        logger.info(f"Bundle {bundle.digest} already present in catalog {ocp}")
        return

    # Bundle entry is missing from catalog
    bundle_entry = {
        "schema": "olm.bundle",
        "image": bundle.url,
    }

    # Create channel if missing from catalog
    if not fbc.catalog_has_channel(ocp, bundle.channel):
        logger.info(
            f"Channel {bundle.channel} does not exit in the catalog,"
            " creating it"
        )
        channel_entry = {
            "entries": [
                {
                    "name": f"mtv-operator.v{bundle.version}",
                    "skipRange": f">=0.0.0 <{bundle.version}",
                }
            ],
            "name": bundle.channel,
            "package": "mtv-operator",
            "schema": "olm.channel",
        }
        fbc.add_entry_to_catalog(ocp, channel_entry)
        logger.info(f"Added channel entry {bundle.channel} to catalog {ocp}")
        fbc.add_entry_to_catalog(ocp, bundle_entry)
        logger.info(f"Added bundle entry {bundle_entry} to catalog {ocp}")
        fbc.render_catalog(ocp)
        return

    # If found channel
    logger.info(f"Found {bundle.channel} channel in catalog")

    # Check and add version entry
    prev_ver = bundle.version
    if prev_ver.patch == 0:
        version_entry = {
            "name": f"mtv-operator.v{bundle.version}",
            "skipRange": f">=0.0.0 <{bundle.version}",
        }
    else:
        prev_ver = Version(prev_ver.major, prev_ver.minor, prev_ver.patch - 1)
        version_entry = {
            "name": f"mtv-operator.v{bundle.version}",
            "replaces": f"mtv-operator.v{prev_ver}",
            "skipRange": f">=0.0.0 <{bundle.version}",
        }

    # Check for already existing version entry
    # If found, replace just the bundle image for that version
    logger.info(
        f"Check if version entry {version_entry} exists in catalog {ocp}"
    )
    if not fbc.catalog_has_version_entry(ocp, bundle.channel, version_entry):
        logger.info(
            f"Version entry {version_entry} doesn't exist "
            f"in catalog {ocp}, creating it"
        )
        fbc.add_version_entry_to_channel(ocp, bundle.channel, version_entry)
        fbc.add_entry_to_catalog(ocp, bundle_entry)
        logger.info(f"Added bundle entry {bundle_entry} to catalog {ocp}")
        fbc.render_catalog(ocp)
        return

    # If found version entry
    logger.info(f"Found version entry {version_entry} in catalog {ocp}")
    logger.info(
        "Searching for the used bundle in the"
        f" {version_entry} version entry"
    )
    old_bundles = fbc._get_bundles(ocp)
    old_bundle = {}
    # TODO: Inspection is sequential and could take a long time
    # depending on the number of bundles
    for o_bundle in old_bundles:
        img = o_bundle.get("image", "")
        b = Bundle(img)
        b.inspect()
        b.parse_inspection()
        if b.version == fbc.for_bundle.version:
            old_bundle = o_bundle
            logger.info(
                f"Found the used bundle {b.url} in the {version_entry}"
                f" version entry. Removing it from catalog {ocp}"
            )
            break
    if old_bundle:
        content = fbc._read_catalog(ocp)
        content.get("entries").remove(old_bundle)
        fbc._write_catalog(ocp, content)

    fbc.add_entry_to_catalog(ocp, bundle_entry)
    logger.info(f"Added bundle entry {bundle_entry} to catalog {ocp}")
    fbc.render_catalog(ocp)
