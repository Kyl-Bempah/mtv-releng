from argparse import Namespace
from asyncio import TaskGroup

from core.task import depends_on, task
from models.dto import EmptyDTO

DESCRIPTION = "Simplest pipeline possible"


def arg_parse(arg_parser):
    pass


@task
async def simple_task(
    data: EmptyDTO, args: Namespace, tg: TaskGroup
) -> EmptyDTO:
    print("Hello world")
    return data
