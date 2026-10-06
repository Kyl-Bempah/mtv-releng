"""Tests for pipelines/automatic_iib.py task logic — external I/O is mocked."""

import asyncio
from argparse import Namespace
from unittest.mock import MagicMock, patch

import pytest
import requests

from models.dto import (
    CollectorDTO,
    CommitDTO,
    EmptyDTO,
    JenkinsJobAnalysisDTO,
    JenkinsJobDTO,
    JenkinsJobResultDTO,
    RepoDiffDTO,
)
from pipelines import automatic_iib as pipeline
from pipelines.automatic_iib import (
    analyze_jobs,
    extract_commit_diff,
    notify_jira_fixed_in_build,
    wait_for_prs,
)


def run(coro):
    """Run an async coroutine in tests without pytest-asyncio."""
    return asyncio.run(coro)


def run_task(task, data, args):
    async def _inner():
        async with asyncio.TaskGroup() as tg:
            return await task.run(data, args, tg)

    return asyncio.run(_inner())


def _diff(version: str, issues: list[str]) -> RepoDiffDTO:
    return RepoDiffDTO(
        repo="forklift",
        version=version,
        diff=[
            CommitDTO(
                sha="abc123",
                msg="fix bug",
                date="2026-01-01",
                author="Alice",
                issues=issues,
            )
        ],
    )


def _fbc_repo(iib_version: str, bundle_version: str) -> MagicMock:
    repo = MagicMock()
    repo.current_iib_version = iib_version
    repo.for_bundle.version = bundle_version
    return repo


def _collector(diffs, fbc_repos) -> CollectorDTO:
    return CollectorDTO(
        task_outputs={
            extract_commit_diff.name: diffs,
            wait_for_prs.name: fbc_repos,
        }
    )


class TestNotifyJiraFixedInBuild:
    def test_single_version_sends_only_its_keys_to_its_build(self):
        """The common `-f 2.12.6` path: one build gets exactly that stream's keys."""
        data = _collector(
            diffs=[_diff("2.12.6", ["MTV-1", "MTV-2"])],
            fbc_repos=[_fbc_repo("2.12.6-2", "2.12.6")],
        )
        args = Namespace(skip_fixed_in_build=False)

        mock_jira = MagicMock()
        with patch(
            "pipelines.automatic_iib.JiraFixedInBuild", return_value=mock_jira
        ):
            run(notify_jira_fixed_in_build.func(data, args, MagicMock()))

        mock_jira.notify_build.assert_called_once_with(["MTV-1", "MTV-2"], "2.12.6-2")

    def test_multi_version_isolates_keys_per_build(self):
        """A run spanning two X.Y streams must not cross-stamp keys."""
        data = _collector(
            diffs=[_diff("2.12.6", ["MTV-100"]), _diff("2.13.1", ["MTV-200"])],
            fbc_repos=[
                _fbc_repo("2.12.6-2", "2.12.6"),
                _fbc_repo("2.13.1-1", "2.13.1"),
            ],
        )
        args = Namespace(skip_fixed_in_build=False)

        mock_jira = MagicMock()
        with patch(
            "pipelines.automatic_iib.JiraFixedInBuild", return_value=mock_jira
        ):
            run(notify_jira_fixed_in_build.func(data, args, MagicMock()))

        mock_jira.notify_build.assert_any_call(["MTV-100"], "2.12.6-2")
        mock_jira.notify_build.assert_any_call(["MTV-200"], "2.13.1-1")
        assert mock_jira.notify_build.call_count == 2

    def test_skip_flag_notifies_nothing(self):
        data = _collector(
            diffs=[_diff("2.12.6", ["MTV-1"])],
            fbc_repos=[_fbc_repo("2.12.6-2", "2.12.6")],
        )
        args = Namespace(skip_fixed_in_build=True)

        with patch("pipelines.automatic_iib.JiraFixedInBuild") as m_jira:
            run(notify_jira_fixed_in_build.func(data, args, MagicMock()))

        m_jira.assert_not_called()

    def test_no_issue_keys_does_not_construct_wrapper(self):
        """Empty keys must return before touching config/auth (best-effort)."""
        data = _collector(
            diffs=[_diff("2.12.6", [])],
            fbc_repos=[_fbc_repo("2.12.6-2", "2.12.6")],
        )
        args = Namespace(skip_fixed_in_build=False)

        with patch("pipelines.automatic_iib.JiraFixedInBuild") as m_jira:
            run(notify_jira_fixed_in_build.func(data, args, MagicMock()))

        m_jira.assert_not_called()


def _job_result(job_name: str, url: str) -> JenkinsJobResultDTO:
    return JenkinsJobResultDTO(
        job=JenkinsJobDTO(
            iib_version="2.12.6-2",
            job_name=job_name,
            build_number=1,
            ocp_version="v4.22",
            job_url=url,
        ),
        result="SUCCESS",
        url=url,
    )


def _analysis(job_result: JenkinsJobResultDTO) -> JenkinsJobAnalysisDTO:
    return JenkinsJobAnalysisDTO(
        job_result=job_result,
        summary="ok",
        child_jobs=[],
        html_report_url=job_result.url,
    )


class TestAnalyzeJobs:
    def test_analyzer_failure_skips_job_without_failing_pipeline(self):
        """A failing analyzer must not abort the run or drop other jobs' analysis."""
        bad = _job_result("mtv-gate", "http://jenkins/bad/1")
        good = _job_result("mtv-non-gate", "http://jenkins/good/2")
        good_analysis = _analysis(good)

        mock_analyzer = MagicMock()
        mock_analyzer.analyze_job.side_effect = [
            requests.HTTPError("500 Server Error"),
            good_analysis,
        ]

        with patch(
            "pipelines.automatic_iib.JenkinsAnalyzer", return_value=mock_analyzer
        ):
            results = run(analyze_jobs.func([bad, good], Namespace(), MagicMock()))

        # Only the job that analyzed successfully survives; no exception raised.
        assert results == [good_analysis]
        assert mock_analyzer.analyze_job.call_count == 2


class TestRecordLatestIib:
    @pytest.mark.parametrize(
        "error",
        [
            OSError("disk full"),
            RuntimeError("missing config"),
        ],
    )
    def test_state_write_failure_does_not_fail_task(self, error):
        data = [MagicMock()]
        with (
            patch(
                "pipelines.automatic_iib.config.get_latest_iib_state_path",
                return_value="/tmp/latest_iib.json",
            ),
            patch(
                "pipelines.automatic_iib.config.get_tier1_jobs",
                return_value={"2.12": {"ocp_version": "4.22"}},
            ),
            patch(
                "pipelines.automatic_iib.record_from_fbc_repos",
                side_effect=error,
            ),
        ):
            result = run_task(
                pipeline.record_latest_iib, data, Namespace()
            )
        assert isinstance(result, EmptyDTO)

    def test_config_getter_failure_does_not_fail_task(self):
        data = [MagicMock()]
        with patch(
            "pipelines.automatic_iib.config.get_latest_iib_state_path",
            side_effect=RuntimeError(
                'Couldn\'t find "latest_iib_state_path" in config'
            ),
        ):
            result = run_task(
                pipeline.record_latest_iib, data, Namespace()
            )
        assert isinstance(result, EmptyDTO)
