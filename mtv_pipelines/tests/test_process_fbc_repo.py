from unittest.mock import patch

from tasks.process_fbc_repo import _resolve_previous_iib_url
from wrappers.skopeo import ImageNotFoundError


class TestResolvePreviousIibUrl:
    def test_picks_highest_available_ocp(self):
        with patch("tasks.process_fbc_repo.Skopeo") as m:
            # highest OCP (v4.20) resolves on the first probe
            m.return_value.inspect.side_effect = (
                lambda url: {} if "v420" in url else _raise_absent()
            )
            url = _resolve_previous_iib_url(["v4.18", "v4.19", "v4.20"], "abc")
        assert url is not None
        assert "forklift-fbc-prod-v420:on-pr-abc" in url

    def test_falls_back_to_lower_ocp_when_higher_missing(self):
        with patch("tasks.process_fbc_repo.Skopeo") as m:
            # only the lowest fragment still exists; probe must fall through to it
            m.return_value.inspect.side_effect = (
                lambda url: {} if "v418" in url else _raise_absent()
            )
            url = _resolve_previous_iib_url(["v4.18", "v4.19", "v4.20"], "abc")
        assert url is not None
        assert "forklift-fbc-prod-v418:on-pr-abc" in url

    def test_returns_none_when_no_fragment_resolves(self):
        with patch("tasks.process_fbc_repo.Skopeo") as m:
            m.return_value.inspect.side_effect = ImageNotFoundError("expired")
            url = _resolve_previous_iib_url(["v4.18", "v4.20"], "abc")
        assert url is None


def _raise_absent():
    raise ImageNotFoundError("Tag was deleted or has expired")
