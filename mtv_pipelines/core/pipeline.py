import asyncio
import logging
from argparse import Namespace

from core.task import Task, TaskState
from models.dto import CollectorDTO, EmptyDTO

PRETTY_PRINT = "  "
logger = logging.getLogger(__name__)


class Pipeline:
    def __init__(self, name: str, tasks: list[Task]):
        self.name = name
        self.tasks = tasks
        self.args: Namespace

    def validate(self):
        if len(self.tasks) == 0:
            raise RuntimeError(f"[Pipeline] {self.name} | No tasks present")

        for task in self.tasks:
            if task.can_run():
                task.validate()

    async def _run_task(self, task: Task):
        logger.info(f"{task} | Started")
        logger.debug(f"{task} | input_model: {task.input_model}")
        task.state = TaskState.RUNNING

        input_data = EmptyDTO()
        if task.is_aggregated():
            output_data = {}
            for dep in task.dependencies:
                if output_data.get(dep.name):
                    logger.warning(f"{task} | Overwriting output data")
                output_data[dep.name] = dep.output_data
            input_data = CollectorDTO(task_outputs=output_data)
            logger.debug(f"{task} | Using aggregator")
        elif task.has_deps():
            input_data = task.dependencies[0].output_data
            logger.debug(f"{task} | Using deps output")
        elif task.has_input_data():
            input_data = task.input_data
            logger.debug(f"{task} | Using task.input_data")
        else:
            logger.debug(f"{task} | Using Empty()")
        logger.debug(f"{task} | input_data: {input_data}")
        # if type(input_data) != task.input_model:
        #     raise RuntimeError(
        #         "Input models mismatch!\n"
        #         f"{task}\n"
        #         f"{PRETTY_PRINT}expected: {task.input_model}\n"
        #         f"{PRETTY_PRINT}got: {type(input_data)}\n"
        #         f"{PRETTY_PRINT}from: {[d.name for d in task.dependencies]}"
        #     )
        output_data = await task.run(input_data, self.args, self.tg)
        task.output_data = output_data
        logger.debug(f"{task} | output_data: {output_data}")
        # if not output_data:
        #     task.state = TaskState.SKIPPED
        #     logger.info(f"{task} | Skipped")
        # else:
        task.state = TaskState.FINISHED
        logger.info(f"{task} | Finished")
        for subscriber in task.subscribers:
            logger.debug(f"{task} | Checking if {subscriber.name} sub can run")
            if subscriber.can_run():
                self.tg.create_task(self._run_task(subscriber))

    async def start(self):
        self.validate()

        async with asyncio.TaskGroup() as tg:
            self.tg = tg
            for task in self.tasks:
                logger.debug(f"{task} | Checking if task can run")
                if task.can_run():
                    tg.create_task(self._run_task(task))
