import json
import logging
import os
import tarfile

import utils
import yaml
from config import config
from models.bundle import Bundle
from models.component import Component
from wrappers.skopeo import Skopeo

logger = logging.getLogger(__name__)

MANIFESTS_FILE = "manifest.json"
CSV_PATH = f"manifests/{config.get_name()}.clusterserviceversion.yaml"


def extract_cmps_from_bundle(bundle: Bundle) -> list[Component]:
    tmp_dir = utils.create_temp_dir(suffix="bundle")

    logger.info(f"Extracting components from bundle {bundle}")
    logger.debug(f"Pulling Bundle {bundle.url}")

    Skopeo().copy(bundle.url, tmp_dir.name)
    manifest_file = os.path.join(tmp_dir.name, MANIFESTS_FILE)
    with open(manifest_file, "r") as file:
        manifest = json.load(file)
    if not manifest:
        raise ValueError(f"Couldn't get json from {manifest_file}")

    logger.debug("Extracting the CSV layer")
    layer_sha = manifest.get("layers")[-1].get("digest")
    logger.info(f"Layer containg the CSV: {layer_sha}")
    layer_sha = layer_sha.split(":")[-1]

    logger.debug("Extracting the components")
    layer_tar = os.path.join(tmp_dir.name, layer_sha)
    with tarfile.open(layer_tar, mode="r") as tar_file:
        tar_file.extract(CSV_PATH, path=tmp_dir.name)

    csv_file = os.path.join(tmp_dir.name, CSV_PATH)
    with open(csv_file, "r") as file:
        data = yaml.safe_load(file)
    try:
        images = data.get("spec").get("relatedImages")
    except AttributeError as ex:
        logger.error(f"Failed to extract component images from relatedImages")
        return []

    if not images:
        logger.error(f"relatedImages was empty")
        return []

    logger.debug(f"Extracted: {[image.get("image") for image in images]}")
    cmps = []
    logger.debug("Extracting the component commits")
    for img in images:
        if not img.get("image"):
            logger.warning(
                f"Image field in relatedImages for {img.get('name')} was empty"
            )
            continue
        cmp = Component(
            utils.replace_for_quay(img.get("image"), bundle.version)
        )
        cmp.inspect()
        cmp.parse_inspection()
        if cmp.version != bundle.version:
            logger.error(
                f"Mismatch of component {cmp.name} and bundle"
                f" version: {cmp.version} vs {bundle.version}"
            )
        cmps.append(cmp)
    logger.debug(f"Extracted commits: {[str(cmp) for cmp in cmps]}")
    return cmps
