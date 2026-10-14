"""Tests for handle_pr task logic — external I/O is mocked."""

import asyncio
from argparse import Namespace
from unittest.mock import MagicMock, patch

from models.dto import CollectorDTO, CommitDTO, RepoDiffDTO
from pipelines.handle_pr import (
    extract_commit_diff,
    notify_jira_fixed_in_build,
    process_pull_request,
)
from semver import Version


def run(coro):
    return asyncio.run(coro)


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
    repo.for_bundle.version = Version.parse(bundle_version)
    return repo


def _collector(diffs, fbc_repo) -> CollectorDTO:
    return CollectorDTO(
        task_outputs={
            extract_commit_diff.name: diffs,
            process_pull_request.name: fbc_repo,
        }
    )


class TestNotifyJiraFixedInBuild:
    def test_stamps_the_build_with_its_stream_keys(self):
        data = _collector(
            diffs=[_diff("5.0.0", ["MTV-1", "MTV-2"])],
            fbc_repo=_fbc_repo("5.0.0-24", "5.0.0"),
        )
        args = Namespace(skip_fixed_in_build=False)

        mock_jira = MagicMock()
        with patch(
            "pipelines.handle_pr.JiraFixedInBuild", return_value=mock_jira
        ):
            run(notify_jira_fixed_in_build.func(data, args, MagicMock()))

        mock_jira.notify_build.assert_called_once_with(
            ["MTV-1", "MTV-2"], "5.0.0-24"
        )

    def test_skip_flag_notifies_nothing(self):
        data = _collector(
            diffs=[_diff("5.0.0", ["MTV-1"])],
            fbc_repo=_fbc_repo("5.0.0-24", "5.0.0"),
        )
        args = Namespace(skip_fixed_in_build=True)

        with patch("pipelines.handle_pr.JiraFixedInBuild") as m_jira:
            run(notify_jira_fixed_in_build.func(data, args, MagicMock()))

        m_jira.assert_not_called()

    def test_empty_diff_notifies_nothing(self):
        data = _collector(
            diffs=[_diff("5.0.0", [])],
            fbc_repo=_fbc_repo("5.0.0-24", "5.0.0"),
        )
        args = Namespace(skip_fixed_in_build=False)

        with patch("pipelines.handle_pr.JiraFixedInBuild") as m_jira:
            run(notify_jira_fixed_in_build.func(data, args, MagicMock()))

        m_jira.assert_not_called()
