import asyncio
import logging
import os
import sys
from argparse import ArgumentParser
from importlib import import_module

from core.pipeline import Pipeline
from core.task import get_pipeline_tasks

PRETTY_PRINT = "  "
PIPELINES = {}
PL_DIR = os.path.join(os.getcwd(), "mtv_pipelines", "pipelines")


# Dynamically import all of the pipelines
def import_pipelines():
    # print(f"Importing pipelines from {PL_DIR}")
    for pl in os.listdir(PL_DIR):
        if pl not in [
            "__pycache__",
            "__init__.py",
        ]:
            pl_name = pl.removesuffix(".py")
            PIPELINES[pl_name] = import_module(f"pipelines.{pl_name}")


def setup_logging(level, pipeline_name):
    log_format = (
        '{"level":"$levelname","time":"$asctime",'
        '"source":"$name","msg":"$message"}'
    )

    formatter = logging.Formatter(fmt=log_format, style="$")

    logger = logging.getLogger()
    logger.setLevel(logging.DEBUG)

    file_handler = logging.FileHandler(f"logs/{pipeline_name}.log", mode="w")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    console_handler = logging.StreamHandler(sys.stdout)

    console_handler.setLevel(level)

    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)


def init_subparsers(root_parser: ArgumentParser):
    sub_parsers = root_parser.add_subparsers(
        title="Available pipelines",
        description="List of available pipelines that can be executed",
        help="Description",
        required=True,
        metavar="pipeline",
        dest="pipeline",
    )
    for pl_name, pl_module in PIPELINES.items():
        sub_parser = sub_parsers.add_parser(
            pl_name, help=pl_module.DESCRIPTION
        )
        pl_module.arg_parse(sub_parser)

        sub_parser.set_defaults(func=exec_pipeline)


def arg_parse():
    parser = ArgumentParser(
        description="MTV Pipelines runner",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Increase verbosity to DEBUG level",
    )
    parser.add_argument(
        "--quay",
        action="store_true",
        help="Try to replace image URLs with quay image URLs where possible",
    )
    parser.add_argument(
        "--parallel",
        action="store_true",
        help="Parallelize tasks (rendering of catalogs, downloading resources...)",
    )

    init_subparsers(parser)

    args = parser.parse_args()
    if args.verbose:
        setup_logging(logging.DEBUG, args.pipeline)
    else:
        setup_logging(logging.INFO, args.pipeline)
    return args


# Define subcommand exec function
def exec_pipeline(args):
    pipeline = Pipeline(args.pipeline, get_pipeline_tasks(args.pipeline))
    pipeline.args = args
    asyncio.run(pipeline.start())


def run():
    import_pipelines()
    args = arg_parse()
    exec_pipeline(args)


if __name__ == "__main__":
    try:
        run()
    except Exception as e:
        logging.exception(e)
