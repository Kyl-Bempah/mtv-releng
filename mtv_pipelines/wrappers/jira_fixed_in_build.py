import logging

import requests
from auth.auth import JiraFixedInBuildAuth
from config import config

logger = logging.getLogger(__name__)


class JiraFixedInBuild:
    """Notifies the Jira "fixed-in-build" automation webhook that a build shipped.

    The webhook endpoint is public config; the ``X-Automation-Webhook-Token``
    is the secret and comes from the JIRA_FIXED_IN_BUILD_TOKEN env var.
    """

    def __init__(self):
        self.webhook_url = config.get_jira_fixed_in_build_webhook_url()
        self.token = JiraFixedInBuildAuth().token

    def notify_build(self, issue_keys: list[str], build_version: str) -> bool:
        """Tag *issue_keys* with *build_version*. Returns True on success.

        A notification failure is logged and swallowed so it can never fail
        the build pipeline.
        """
        if not issue_keys:
            logger.info(f"No Jira issues to notify for build {build_version}")
            return False

        try:
            resp = requests.post(
                self.webhook_url,
                headers={
                    "Content-Type": "application/json",
                    "X-Automation-Webhook-Token": self.token,
                },
                json={
                    "issues": issue_keys,
                    "data": {"buildVersion": build_version},
                },
                timeout=30,
            )
            resp.raise_for_status()
        except requests.RequestException as e:
            logger.error(
                f"Failed to notify Jira fixed-in-build for {build_version}: {e}"
            )
            return False

        logger.info(
            f"Notified Jira fixed-in-build: {build_version} -> {issue_keys}"
        )
        return True
