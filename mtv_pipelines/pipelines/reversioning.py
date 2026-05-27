import logging
import os
import re
import argparse
from argparse import ArgumentParser, Namespace
from asyncio import TaskGroup, to_thread

from config import config
from core.task import depends_on, task
from models.dto import (
    EmptyDTO,
    MTVBranchVersionDTO,
    MTVRepoBranchVersionsDTO,
    MTVVersionsDTO,
    VersionDTO,
    ReversionResultDTO,
)
from models.git_repo import GitRepo
from semver import Version
from tasks.get_mtv_versions import get_mtv_versions
from wrappers.gh_cli import GHCLI

DESCRIPTION = (
    "Re-version MTV across all configured origin repositories.\n\n"
    "Reads the current version from each repo's release.conf, increments the patch\n"
    "number (or uses an explicit --new-version), updates the file, and opens a PR\n"
    "targeting the release branch. Multiple branches and origins can be processed\n"
    "in a single run."
)

logger = logging.getLogger(__name__)


def arg_parse(arg_parser: ArgumentParser):
    arg_parser.formatter_class = argparse.RawTextHelpFormatter
    origins = list(config.get_mtv_repositories().keys())
    arg_parser.add_argument(
        "-b",
        "--branch",
        help="[required] Release branch to process (e.g. release-2.10). Can be specified multiple times.",
        action="append",
        dest="branches",
        metavar="BRANCH",
        required=True,
    )
    arg_parser.add_argument(
        "-o",
        "--origin",
        help="[optional] Origin repository to process. Can be specified multiple times. Defaults to all origins.\nChoices:\n"
        + "\n".join(f"  {o}" for o in origins),
        action="append",
        dest="origins",
        metavar="ORIGIN",
        choices=origins,
    )
    arg_parser.add_argument(
        "-n",
        "--new-version",
        help=(
            "[optional] Explicitly set the new version (format X.Y.Z) instead of "
            "auto-incrementing the patch number. "
            "Cannot be used when multiple branches are specified."
        ),
        metavar="VERSION",
    )
    arg_parser.add_argument(
        "--release",
        metavar="RELEASE",
        help='[optional] Override the RELEASE field in build/release.conf (e.g. "v2.13").',
    )
    arg_parser.add_argument(
        "--cpe",
        metavar="CPE",
        help='[optional] Override the CPE field in build/release.conf (e.g. "2.13").',
    )
    arg_parser.add_argument(
        "--channel",
        metavar="CHANNEL",
        help='[optional] Override the CHANNEL field in build/release.conf (e.g. "release-v2.13").',
    )
    arg_parser.add_argument(
        "--default-channel",
        dest="default_channel",
        metavar="DEFAULT_CHANNEL",
        help="[optional] Override the DEFAULT_CHANNEL field in build/release.conf.",
    )
    arg_parser.add_argument(
        "--registry",
        metavar="REGISTRY",
        help='[optional] Override the REGISTRY field in build/release.conf (e.g. "migration-toolkit-virtualization").',
    )
    arg_parser.add_argument(
        "--ocp-versions",
        dest="ocp_versions",
        metavar="OCP_VERSIONS",
        help='[optional] Override the OCP_VERSIONS field in build/release.conf (e.g. "v4.17-v4.19").',
    )
    arg_parser.add_argument(
        "--dry-run",
        help="[optional] Log what would be done without pushing any changes or creating PRs.",
        action="store_true",
        default=False,
    )


@task
async def fetch_versions(
    data: EmptyDTO, args: Namespace, tg: TaskGroup
) -> MTVVersionsDTO:
    if args.new_version and len(args.branches) > 1:
        raise ValueError(
            "--new-version cannot be used when multiple branches are specified. "
            "An explicit version is ambiguous across different Y-streams."
        )

    logger.info("Fetching current MTV versions from all configured origins...")
    raw: dict[str, dict[str, str]] = await to_thread(get_mtv_versions)

    all_branches = config.get_mtv_branches()
    unknown = [b for b in args.branches if b not in all_branches]
    if unknown:
        logger.warning(
            {
                "msg": "Branches not found in config, will be ignored",
                "branches": unknown,
            }
        )
    target_branches = [b for b in args.branches if b in all_branches]

    logger.info({"msg": "Targeting branches", "branches": target_branches})

    target_origins = args.origins or list(raw.keys())

    repo_versions: list[MTVRepoBranchVersionsDTO] = []
    for origin, branch_map in raw.items():
        if origin not in target_origins:
            continue
        branch_versions: list[MTVBranchVersionDTO] = []
        for branch, version_str in branch_map.items():
            if branch not in target_branches:
                continue
            v = Version.parse(version_str)
            branch_versions.append(
                MTVBranchVersionDTO(
                    branch=branch,
                    version=VersionDTO(
                        major=v.major,
                        minor=v.minor,
                        patch=v.patch,
                        prerelease=None,
                    ),
                )
            )
        if branch_versions:
            repo_versions.append(
                MTVRepoBranchVersionsDTO(repo=origin, branch_versions=branch_versions)
            )

    return MTVVersionsDTO(versions=repo_versions)


@task
@depends_on(fetch_versions)
async def apply_version_changes(
    data: MTVVersionsDTO, args: Namespace, tg: TaskGroup
) -> list[ReversionResultDTO]:
    repositories = config.get_mtv_repositories()
    release_conf_path = config.get_release_conf_path()
    results: list[ReversionResultDTO] = []

    async def reversion_one(
        origin: str, branch: str, old_version_str: str
    ) -> ReversionResultDTO:
        old_v = Version.parse(old_version_str)

        if args.new_version:
            try:
                new_v = Version.parse(args.new_version)
            except ValueError as e:
                return ReversionResultDTO(
                    origin=origin,
                    branch=branch,
                    old_version=old_version_str,
                    new_version=args.new_version,
                    skipped=True,
                    skip_reason=f"Invalid --new-version value: {e}",
                )
        else:
            new_v = old_v.bump_patch()

        if new_v <= old_v:
            return ReversionResultDTO(
                origin=origin,
                branch=branch,
                old_version=old_version_str,
                new_version=str(new_v),
                skipped=True,
                skip_reason=f"New version {new_v} is not greater than current {old_v}",
            )

        repo_url = (repositories.get(origin) or "").rstrip("/") or None
        if not repo_url:
            return ReversionResultDTO(
                origin=origin,
                branch=branch,
                old_version=old_version_str,
                new_version=str(new_v),
                skipped=True,
                skip_reason=f"No URL configured for origin '{origin}'",
            )

        logger.info(
            {
                "msg": f"Version changed to {new_v}",
                "origin": origin,
                "branch": branch,
                "old_version": str(old_v),
                "new_version": str(new_v),
            }
        )

        if args.dry_run:
            logger.info(
                {
                    "msg": f"Dry-run: would update version to {new_v} and open PR",
                    "origin": origin,
                    "branch": branch,
                    "old_version": str(old_v),
                    "new_version": str(new_v),
                    "target_branch": branch,
                    "extra_params": {
                        k: v for k, v in {
                            "RELEASE": args.release,
                            "CPE": args.cpe,
                            "CHANNEL": args.channel,
                            "DEFAULT_CHANNEL": args.default_channel,
                            "REGISTRY": args.registry,
                            "OCP_VERSIONS": args.ocp_versions,
                        }.items() if v is not None
                    },
                }
            )
            return ReversionResultDTO(
                origin=origin,
                branch=branch,
                old_version=str(old_v),
                new_version=str(new_v),
            )

        # Clone the origin repository
        repo = GitRepo(url=repo_url, name=origin, version=str(old_v))
        await repo.init()

        repo.git.config("user.email", config.get_git_email())
        repo.git.config("user.name", config.get_git_name())

        GHCLI(repo.tmp_dir.name).auth()

        # Checkout the target release branch
        try:
            repo.git.checkout(branch=branch)
        except Exception as e:
            return ReversionResultDTO(
                origin=origin,
                branch=branch,
                old_version=str(old_v),
                new_version=str(new_v),
                skipped=True,
                skip_reason=f"Could not checkout '{branch}': {e}",
            )

        # Read build/release.conf
        conf_path = os.path.join(repo.tmp_dir.name, release_conf_path)
        if not os.path.exists(conf_path):
            return ReversionResultDTO(
                origin=origin,
                branch=branch,
                old_version=str(old_v),
                new_version=str(new_v),
                skipped=True,
                skip_reason=f"'{release_conf_path}' not found in cloned repo",
            )

        with open(conf_path) as f:
            content = f.read()

        # Match any *VERSION=X.Y.Z line (covers VERSION=, RVERSION=, MTV_VERSION=, etc.)
        # mirrors the same pattern used in get_mtv_versions
        pattern = r"^(\w*VERSION=)(\d+\.\d+\.\d+)$"
        new_content, substitutions = re.subn(
            pattern, rf"\g<1>{new_v}", content, flags=re.MULTILINE
        )

        if substitutions == 0:
            return ReversionResultDTO(
                origin=origin,
                branch=branch,
                old_version=str(old_v),
                new_version=str(new_v),
                skipped=True,
                skip_reason=f"No '*VERSION=X.Y.Z' line found in '{release_conf_path}'",
            )

        # Apply explicit field overrides
        _overridable = {
            "RELEASE": args.release,
            "CPE": args.cpe,
            "CHANNEL": args.channel,
            "DEFAULT_CHANNEL": args.default_channel,
            "REGISTRY": args.registry,
            "OCP_VERSIONS": args.ocp_versions,
        }
        extra_overrides: dict[str, str] = {}
        for key, value in _overridable.items():
            if value is None:
                continue
            new_content, n = re.subn(
                rf"^({re.escape(key)}=).*$",
                rf"\g<1>{value}",
                new_content,
                flags=re.MULTILINE,
            )
            if n == 0:
                logger.warning(
                    f"[{origin}] '{key}' not found in {release_conf_path}, skipping override"
                )
            else:
                extra_overrides[key] = value
                logger.info(f"[{origin}] Set {key}={value} in {release_conf_path}")

        with open(conf_path, "w") as f:
            f.write(new_content)

        # Build commit/PR description lines
        change_lines = [f"Version changed from {old_v} to {new_v} in {release_conf_path}"]
        change_lines += [f"Set {k}={v}" for k, v in extra_overrides.items()]
        change_summary = "\n".join(f"- {l}" for l in change_lines)

        # Create a new branch for the PR
        pr_branch = f"reversion-{branch}-{new_v}"
        repo.git.checkout(branch=pr_branch, create=True)
        repo.git.add_files([release_conf_path])
        repo.git.commit(
            f"chore(version): version changed to {new_v}\n\n{change_summary}"
        )

        try:
            repo.git.push(branch=pr_branch)
        except RuntimeError as e:
            logger.error(
                {
                    "msg": "Push failed",
                    "origin": origin,
                    "branch": branch,
                    "pr_branch": pr_branch,
                    "error": str(e),
                }
            )
            return ReversionResultDTO(
                origin=origin,
                branch=branch,
                old_version=str(old_v),
                new_version=str(new_v),
                skipped=True,
                skip_reason=f"Push failed: {e}",
            )

        # Open a PR targeting the release branch, or reuse one that already exists
        pr_url = ""
        gh = GHCLI(repo.tmp_dir.name)
        try:
            existing = gh.list_pr(branch=pr_branch)
            if existing:
                pr_url = existing[0]["url"]
                logger.info(
                    {
                        "msg": "PR already exists, reusing",
                        "origin": origin,
                        "branch": branch,
                        "pr_url": pr_url,
                    }
                )
            else:
                pr_url = gh.create_pr(
                    title=f"chore(version): version changed to {new_v}",
                    body=change_summary,
                    target_branch=branch,
                    head_branch=pr_branch,
                )
                logger.info(
                    {
                        "msg": "PR created",
                        "origin": origin,
                        "branch": branch,
                        "pr_url": pr_url,
                    }
                )
        except RuntimeError as e:
            logger.warning(
                {
                    "msg": "PR creation failed",
                    "origin": origin,
                    "branch": branch,
                    "error": str(e),
                }
            )

        return ReversionResultDTO(
            origin=origin,
            branch=branch,
            old_version=str(old_v),
            new_version=str(new_v),
            pr_url=pr_url,
        )

    reversion_tasks = []
    for repo_dto in data.versions:
        for bv in repo_dto.branch_versions:
            old_version_str = (
                f"{bv.version.major}.{bv.version.minor}.{bv.version.patch}"
            )
            reversion_tasks.append(
                tg.create_task(reversion_one(repo_dto.repo, bv.branch, old_version_str))
            )

    for t in reversion_tasks:
        results.append(await t)

    return results
