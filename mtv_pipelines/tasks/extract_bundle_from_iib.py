import json
import logging
import os
import tarfile

import utils
from models.bundle import Bundle
from models.iib import IIB
from semver.version import Version
from wrappers.skopeo import Skopeo

logger = logging.getLogger(__name__)

MANIFESTS_FILE = "manifest.json"
CATALOG_PATH = "configs/mtv-operator/catalog.json"
BUNDLE_ENTRY_NAME = "mtv-operator.v{version}"


def read_concatenated_json(file_path):
    with open(file_path, "r") as f:
        content = f.read()

    decoder = json.JSONDecoder()
    pos = 0
    results = []

    while pos < len(content):
        # Skip whitespace/newlines between dictionaries
        content = content.lstrip()
        if not content:
            break

        try:
            # raw_decode returns the object and the index where it ended
            obj, index = decoder.raw_decode(content)
            results.append(obj)
            # Advance the content string to the next object
            content = content[index:].lstrip()
        except json.JSONDecodeError as e:
            logger.error(f"Error parsing at: {e}")
            raise e

    return results


def extract_bundle_from_iib(iib: IIB) -> Bundle:
    tmp_dir = utils.create_temp_dir(suffix="iib")

    logger.info(f"Extracting bundle from {iib}")
    logger.debug(f"Pulling IIB {iib.url}")
    Skopeo().copy(iib.url, tmp_dir.name)
    manifest_file = os.path.join(tmp_dir.name, MANIFESTS_FILE)
    with open(manifest_file, "r") as file:
        manifest = json.load(file)
    if not manifest:
        raise ValueError(f"Couldn't get json from {manifest_file}")

    logger.debug("Extracting the catalog layer")
    layer_sha = manifest.get("layers")[-1].get("digest")
    logger.info(f"Layer containg the catalog: {layer_sha}")
    layer_sha = layer_sha.split(":")[-1]

    layer_tar = os.path.join(tmp_dir.name, layer_sha)
    with tarfile.open(layer_tar, mode="r") as tar_file:
        tar_file.extract(CATALOG_PATH, path=tmp_dir.name)

    catalog_file = os.path.join(tmp_dir.name, CATALOG_PATH)
    catalog = read_concatenated_json(catalog_file)

    if not catalog:
        raise ValueError(f"Couldn't get json from {catalog_file}")

    for entry in catalog:
        name = entry.get("name")
        n = BUNDLE_ENTRY_NAME.replace(
            "{version}", str(iib.version).split("-")[0]
        )
        if name == n:
            image = entry.get("image", "")
            if not image:
                raise ValueError(
                    f"Didn't find 'image' in {entry} for {iib.url}"
                )
            logger.info(
                f"Found bundle image {image} in {iib.url} for {iib.version}"
            )
            b = Bundle(image)
            b.version = Version(
                iib.version.major, iib.version.minor, iib.version.patch
            )
            return b

    raise ValueError(
        f"Couldn't find bundle image in {iib.url} for {iib.version}"
    )
