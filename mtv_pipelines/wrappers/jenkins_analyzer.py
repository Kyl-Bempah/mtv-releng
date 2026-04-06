import json
import logging

import requests
from config import config
from models.dto import (
    JenkinsChildJobAnalysisDTO,
    JenkinsJobAnalysisDTO,
    JenkinsJobResultDTO,
)

logger = logging.getLogger(__name__)


class JenkinsAnalyzer:
    def analyze_job(
        self, job_result: JenkinsJobResultDTO
    ) -> JenkinsJobAnalysisDTO:
        logger.info(f"Analyzing job result for {job_result.url}")
        resp = requests.post(
            f"{config.get_jenkins_analyzer_url().rstrip("/")}/analyze",
            headers={"Content-Type": "application/json"},
            json={
                "job_name": job_result.job.job_name,
                "build_number": job_result.job.build_number,
                "ai_provider": "cursor",
                "ai_model": "gpt-5.4-xhigh-fast",
            },
            verify=False,
        )
        resp.raise_for_status()
        data = json.loads(resp.content)
        analysis = self._process_data(data, job_result)

        return analysis

    def _process_data(
        self, data: dict, job_result: JenkinsJobResultDTO
    ) -> JenkinsJobAnalysisDTO:
        children = []
        for child in data.get("child_job_analyses") or []:
            if not isinstance(child, dict):
                continue
            try:
                bn = int(child.get("build_number") or 0)
            except (TypeError, ValueError):
                bn = 0
            children.append(
                JenkinsChildJobAnalysisDTO(
                    job_name=child.get("job_name", ""),
                    build_number=bn,
                    job_url=child.get("jenkins_url") or child.get("job_url", ""),
                    summary=child.get("summary", ""),
                )
            )
        summary = data.get("summary")
        if not summary:
            summary = "No summary available from the analyzer."
        report_url = data.get("result_url") or data.get("html_report_url")
        if not report_url:
            report_url = job_result.url
        return JenkinsJobAnalysisDTO(
            job_result=job_result,
            summary=summary,
            child_jobs=children,
            html_report_url=report_url,
        )

    def _prepare_output_for_mrkdwn(self, output: dict):
        logger.debug(f"Sanitizing output for slack mrkdwn: {output}")

        return output
