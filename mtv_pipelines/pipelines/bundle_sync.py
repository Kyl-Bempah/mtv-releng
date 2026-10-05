import argparse
import datetime
import logging
import os
from argparse import ArgumentParser, Namespace
from asyncio import TaskGroup

import requests
from config import config
from core.task import task
from models.dto import BundleSyncResultDTO
from tasks.bundle_sync_sha import (
    VirtV2vProbe,
    add_virt_v2v_int_sha,
    build_sha_mapping,
    compute_containerfile_updates,
    probe_containerfile_virt_v2v,
    validate_components_in_quay,
)
from utils import create_temp_dir
from wrappers.gh_cli import GHCLI
from wrappers.git import Git
from wrappers.oc import Oc

DESCRIPTION = (
    "Update Containerfile-downstream SHA references from the latest snapshot.\n\n"
    "Finds the newest stage release for a version, resolves its snapshot, and\n"
    "rewrites the ARG *_IMAGE SHAs in build/forklift-operator-bundle/\n"
    "Containerfile-downstream (pulling the virt-v2v-int SHA from the internal\n"
    "quay tenant). Opens a PR against the target branch, or rebases and updates\n"
    "an existing open sync PR. Dry-run by default; pass --apply to push."
)

logger = logging.getLogger(__name__)

CONTAINERFILE_BASE_URL = "https://raw.githubusercontent.com/kubev2v/forklift"
CONTAINERFILE_PATH = "build/forklift-operator-bundle/Containerfile-downstream"
TARGET_REPO = "kubev2v/forklift"
TARGET_REPO_URL = "https://github.com/kubev2v/forklift.git"
RELEASE_TARGET = "stage"
PR_TITLE = "chore(automation): Bundle SHA reference update for {version}"


def arg_parse(arg_parser: ArgumentParser):
    arg_parser.formatter_class = argparse.RawTextHelpFormatter
    arg_parser.add_argument(
        "version",
        help="[required] Version to get the snapshot for (e.g. '2-11', 'dev-preview').",
    )
    arg_parser.add_argument(
        "-t",
        "--target-branch",
        dest="target_branch",
        default="main",
        help="[optional] Target branch for the PR (default: main).",
    )
    arg_parser.add_argument(
        "--apply",
        action="store_true",
        default=False,
        help="[optional] Perform the update (clone, commit, push, PR). Without it, dry-run only.",
    )


def _fetch_raw_containerfile(branch: str) -> str | None:
    url = f"{CONTAINERFILE_BASE_URL}/{branch}/{CONTAINERFILE_PATH}"
    # raw.githubusercontent.com has a valid public cert; keep TLS verification on
    # (a self-signed cert here would mean interception, not a legit endpoint).
    resp = requests.get(url, timeout=30)
    if resp.status_code != 200:
        logger.warning(f"{url} returned {resp.status_code}")
        return None
    return resp.text


def _find_existing_sync_pr(version: str, target_branch: str) -> str:
    """Head branch of the newest open sync PR with a matching title, else ''."""
    title = PR_TITLE.format(version=version)
    try:
        prs = GHCLI(".").list_open_prs_for_base(
            base=target_branch, repo=TARGET_REPO
        )
    except RuntimeError as e:
        logger.warning(f"Could not list open PRs: {e}")
        return ""

    matches = [p for p in prs if p.get("title") == title]
    if not matches:
        return ""
    if len(matches) > 1:
        logger.info(
            f"Multiple open PRs with matching title; using the newest "
            f"(branch: {matches[0].get('headRefName')})"
        )
    return matches[0].get("headRefName") or ""


@task
async def sync_bundle(
    data, args: Namespace, tg: TaskGroup
) -> BundleSyncResultDTO:
    version = args.version
    target_branch = args.target_branch
    dry_run = not args.apply

    logger.info(
        {
            "msg": "Starting bundle SHA reference update",
            "version": version,
            "target_branch": target_branch,
            "dry_run": dry_run,
        }
    )

    oc = Oc()
    release = oc.latest_release(version, RELEASE_TARGET)
    if not release:
        return BundleSyncResultDTO(
            version=version,
            target_branch=target_branch,
            dry_run=dry_run,
            skipped=True,
            skip_reason=f"No Succeeded release found for version {version}",
        )
    snapshot = oc.snapshot_from_release(release)
    if not snapshot:
        return BundleSyncResultDTO(
            version=version,
            target_branch=target_branch,
            dry_run=dry_run,
            skipped=True,
            skip_reason=f"No snapshot found for release {release}",
        )
    logger.info(f"Found snapshot: {snapshot}")

    # Probe the Containerfile on the target branch to learn the virt-v2v slots.
    # Default (if it can't be fetched): single ARG + virt-v2v-int fallback.
    probe = VirtV2vProbe(int_key=f"virt-v2v-{version}")
    probe_content = _fetch_raw_containerfile(target_branch)
    if probe_content is not None:
        probe = probe_containerfile_virt_v2v(probe_content, version)
        if probe.arg_count == 1 and not probe.int_key:
            probe.int_key = f"virt-v2v-{version}"
        logger.info(
            f"Containerfile on {target_branch}: {probe.arg_count} virt-v2v "
            f"ARG(s) (VIRT_V2V_IMAGE={probe.has_main}, "
            f"VIRT_V2V_IMAGE_RHEL9={probe.has_rhel9})"
        )
    else:
        logger.warning(
            "Could not fetch Containerfile to detect virt-v2v ARGs; "
            "assuming single ARG and virt-v2v-int fallback"
        )

    snapshot_data = oc.snapshot_content(snapshot)
    validate_components_in_quay(snapshot_data, probe.arg_count)

    sha_mapping = build_sha_mapping(snapshot_data, probe)
    add_virt_v2v_int_sha(sha_mapping, version, probe)
    if not sha_mapping:
        return BundleSyncResultDTO(
            version=version,
            target_branch=target_branch,
            snapshot=snapshot,
            dry_run=dry_run,
            skipped=True,
            skip_reason="SHA mapping is empty",
        )
    logger.info(f"Found {len(sha_mapping)} components with SHA references")

    mappings = config.get_component_arg_mappings()
    existing_branch = _find_existing_sync_pr(version, target_branch)
    if existing_branch:
        logger.info(
            f"Found existing open sync PR (head {existing_branch} -> base "
            f"{target_branch})"
        )

    if dry_run:
        file_branch = existing_branch or target_branch
        content = _fetch_raw_containerfile(file_branch)
        if content is None:
            return BundleSyncResultDTO(
                version=version,
                target_branch=target_branch,
                snapshot=snapshot,
                existing_branch=existing_branch,
                dry_run=True,
                skipped=True,
                skip_reason=f"Failed to download Containerfile from {file_branch}",
            )
        _, updates, skipped, missing = compute_containerfile_updates(
            content, sha_mapping, mappings
        )
        for u in updates:
            logger.info(
                f"DRY RUN: would update {u.arg_name}:\n  {u.old_line}\n  to:\n  {u.new_line}"
            )
        logger.info(
            {
                "msg": "DRY RUN: Containerfile preview summary",
                "would_update": len(updates),
                "already_up_to_date": skipped,
                "missing_or_unknown": missing,
            }
        )
        return BundleSyncResultDTO(
            version=version,
            target_branch=target_branch,
            snapshot=snapshot,
            components_updated=len(updates),
            existing_branch=existing_branch,
            dry_run=True,
        )

    # Live run: clone, (rebase existing PR branch or create a new branch), edit,
    # commit, push, and create/update the PR.
    tmp_dir = create_temp_dir(f"bundle-sync-{version}")
    git = Git(tmp_dir.name)
    await git.clone(TARGET_REPO_URL)
    git.config("user.email", config.get_git_email())
    git.config("user.name", config.get_git_name())
    GHCLI(tmp_dir.name).auth()

    git.checkout(target_branch)
    await git.pull(target_branch)

    push_force: str | None = None
    if existing_branch:
        git.fetch(existing_branch, origin="origin")
        git.checkout(existing_branch)
        git.fetch(target_branch, origin="origin")
        logger.info(f"Rebasing {existing_branch} onto origin/{target_branch}")
        try:
            git.rebase(f"origin/{target_branch}")
            push_force = "lease"  # history rewritten by rebase
        except Exception as e:
            logger.warning(
                f"Rebase stopped ({e}); aborting and merging origin/{target_branch}"
            )
            try:
                git.rebase_abort()
            except Exception as abort_err:
                return BundleSyncResultDTO(
                    version=version,
                    target_branch=target_branch,
                    snapshot=snapshot,
                    existing_branch=existing_branch,
                    skipped=True,
                    skip_reason=f"Could not abort rebase: {abort_err}",
                )
            try:
                git.merge(
                    f"origin/{target_branch}",
                    message=(
                        f"Merge {target_branch} into {existing_branch} "
                        "(bundle_sync: rebase had conflicts)"
                    ),
                )
                push_force = None  # linear merge commit, plain push
            except Exception as merge_err:
                try:
                    git.merge_abort()
                except Exception:
                    pass
                return BundleSyncResultDTO(
                    version=version,
                    target_branch=target_branch,
                    snapshot=snapshot,
                    existing_branch=existing_branch,
                    skipped=True,
                    skip_reason=(
                        f"Rebase and merge of origin/{target_branch} both "
                        f"failed; resolve on {existing_branch} manually: {merge_err}"
                    ),
                )
        branch_name = existing_branch
    else:
        branch_name = (
            f"update-sha-refs-"
            f"{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}"
        )
        git.checkout(branch_name, create=True)

    cf_path = os.path.join(tmp_dir.name, CONTAINERFILE_PATH)
    if not os.path.exists(cf_path):
        return BundleSyncResultDTO(
            version=version,
            target_branch=target_branch,
            snapshot=snapshot,
            existing_branch=existing_branch,
            skipped=True,
            skip_reason=f"Containerfile-downstream not found at {CONTAINERFILE_PATH}",
        )

    with open(cf_path) as f:
        content = f.read()
    new_content, updates, _, _ = compute_containerfile_updates(
        content, sha_mapping, mappings
    )
    if not updates:
        logger.info("No changes needed in Containerfile-downstream")
        return BundleSyncResultDTO(
            version=version,
            target_branch=target_branch,
            snapshot=snapshot,
            components_updated=0,
            existing_branch=existing_branch,
        )

    with open(cf_path, "w") as f:
        f.write(new_content)

    git.add_files([CONTAINERFILE_PATH])
    git.commit(
        "chore(automation): update Containerfile-downstream SHA references "
        "from snapshot\n\n"
        f"- Updated SHA references for version {version}\n"
        "- Generated from latest snapshot\n"
        "- Automated update via mtv-releng pipeline"
    )
    git.push(branch=branch_name, force=push_force)

    if existing_branch:
        logger.info(f"Open PR updated (pushed {branch_name})")
    else:
        body = (
            "This PR updates the SHA references in Containerfile-downstream "
            f"based on the latest snapshot for version {version}.\n\n"
            "## Changes\n"
            "- Updated SHA references in Containerfile-downstream\n"
            f"- Generated from latest snapshot: {snapshot}\n\n"
            "## Automated Update\n"
            "This PR was created automatically by the mtv-releng pipeline."
        )
        GHCLI(tmp_dir.name).create_pr_for_repo(
            repo=TARGET_REPO,
            title=PR_TITLE.format(version=version),
            body=body,
            base=target_branch,
            head=branch_name,
        )
        logger.info("PR created successfully")

    return BundleSyncResultDTO(
        version=version,
        target_branch=target_branch,
        snapshot=snapshot,
        components_updated=len(updates),
        existing_branch=existing_branch,
    )
