import logging
from argparse import Namespace
from asyncio import TaskGroup, to_thread

from config import config
from core.task import depends_on, task
from models.bundle import Bundle
from models.dto import EmptyDTO, MTVVersionsDTO
from models.fbc_repo import FBCRepo
from tasks.process_fbc_repo import process_fbc_repo
from wrappers.gh_cli import GHCLI
from wrappers.skopeo import Skopeo

DESCRIPTION = "Pipeline to create a fbc release"

logger = logging.getLogger(__name__)


def arg_parse(arg_parser):
    arg_parser.add_argument(
        "-b",
        "--process-bundle",
        help='Process selected bundle, example: "registry.redhat.io/migration-toolkit-virtualization/mtv-operator-bundle@sha256:363300946fa8925493fcae3aae096ce2e455f4a5cc50d2cfb4dd56936511c9bd"',
        required=True,
    )


@task
async def skopeo_login_task(
    data: EmptyDTO, args: Namespace, tg: TaskGroup
) -> EmptyDTO:
    try:
        Skopeo().auth()
    except RuntimeError as e:
        logger.error(f"Failed to login to registries: {e}")
        raise e
    return EmptyDTO()


@task
@depends_on(skopeo_login_task)
async def get_latest_stage_bundles(
    data: EmptyDTO, args: Namespace, tg: TaskGroup
) -> list[Bundle]:
    if not args.process_bundle:
        logger.error(f"Bundle must be specified")
        return []

    bundles: list[Bundle] = []

    b = Bundle(args.process_bundle)
    try:
        b.inspect()
    except RuntimeError as e:
        logger.warning(f"Wasn't able to inspect the bundle {b.url}")
        logger.warning(e)
        return []
    b.parse_inspection()
    bundles.append(b)
    return bundles


@task
@depends_on(get_latest_stage_bundles)
async def prepare_fbc_repo(
    data: list[Bundle], args: Namespace, tg: TaskGroup
) -> list[FBCRepo]:
    if not data:
        logger.warning(f"Previous task didn't return any Bundles")
        return []

    async def for_each(bundle: Bundle):
        fbc_repo = FBCRepo()
        fbc_repo.for_bundle = bundle

        # Prepare FBC repository
        await fbc_repo.init()
        fbc_repo.git.checkout(fbc_repo.target)
        fbc_repo.git.config("user.email", config.get_git_email())
        fbc_repo.git.config("user.name", config.get_git_name())

        GHCLI(fbc_repo.tmp_dir.name).auth()

        # Download OPM tool, offload downloading to threads
        await tg.create_task(to_thread(fbc_repo.download_opm))

        # Check if remote branch for MTV version already exists
        remote_branches = fbc_repo.git.remote_branches()
        remote_branch_exists = False
        ver = f"{fbc_repo.for_bundle.version}-release"
        logger.info(f"Checking if remote branch for MTV {ver} exists")
        for branch in remote_branches:
            if ver in branch:
                remote_branch_exists = True

        # If remote branch exists, pull it
        if remote_branch_exists:
            logger.info(f"Found remote branch for {ver}")
            fbc_repo.git.checkout(branch=ver)
            await fbc_repo.git.pull(branch=ver)
        # If not, create a new one
        else:
            logger.info(f"Creating branch for {ver}")
            fbc_repo.git.checkout(branch=ver, create=True)

        return fbc_repo

    tasks = []
    for bundle in data:
        tasks.append(tg.create_task(for_each(bundle)))
    results: list[FBCRepo] = []
    for task in tasks:
        results.append(await task)

    return results


@task
@depends_on(prepare_fbc_repo)
async def process_fbc_repos(
    data: list[FBCRepo], args: Namespace, tg: TaskGroup
) -> list[FBCRepo]:
    if not data:
        logger.warning(f"Previous task didn't return any FBC Repositories")
        return []

    tasks = []
    for fbcrepo in data:
        ver = f"{fbcrepo.for_bundle.version}-release"
        tasks.append(tg.create_task(process_fbc_repo(fbcrepo, tg, ver)))
    results = []
    for task in tasks:
        result = await task
        # only add changed repos
        if result:
            results.append(result)
    return results


@task
@depends_on(process_fbc_repos)
async def process_pull_request(
    data: list[FBCRepo], args: Namespace, tg: TaskGroup
) -> list[FBCRepo]:
    if not data:
        logger.warning(f"Previous task didn't return any FBC Repositories")
        return []
    for fbc_repo in data:
        ver = f"{fbc_repo.for_bundle.version}-release"
        prs = GHCLI(fbc_repo.tmp_dir.name).list_pr(ver)
        if not prs:
            try:
                pr_url = GHCLI(fbc_repo.tmp_dir.name).create_pr(ver)
                fbc_repo.pr_url = pr_url
                logger.info(f"Created PR {pr_url} for {ver}")
            except RuntimeError as e:
                logger.exception(e)
                return []
        else:
            if len(prs) > 1:
                logger.error(f"Found multiple PRs for {ver}, skipping version")
            fbc_repo.pr_url = prs[0]["url"]
            logger.info(f"Found PR {prs[0]["url"]} for {ver}")
    return data
