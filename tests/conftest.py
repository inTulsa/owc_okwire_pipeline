"""Shared fixtures.

The enrollment fixtures are the important ones: they serve a saved copy of
oklahoma.gov's markup and workbooks through a stubbed ``requests.get``, so the
parsing behavior is pinned without a live scrape. When Oklahoma next changes
their page, saving the new HTML here proves what broke.
"""

from __future__ import annotations

import urllib.parse
from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures"
ENROLLMENT_FIXTURES = FIXTURES / "enrollment"
PAGE_URL = "https://example.test/enrollment/state-public-enrollment-totals.html"


class _Response:
    def __init__(self, content: bytes, status: int = 200, url: str = "") -> None:
        self.content = content
        self.status_code = status
        self._url = url

    @property
    def text(self) -> str:
        return self.content.decode("utf-8")

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            import requests

            raise requests.exceptions.HTTPError(f"{self.status_code} for {self._url}")


@pytest.fixture
def serve_fixtures(monkeypatch):
    """Stub ``requests.get`` to serve tests/fixtures/enrollment/.

    Returns a callable taking the page filename, so one test can serve the
    normal page and another the redesigned one. A URL with no matching fixture
    file 404s, which is how the "companion is linked but missing" case is set
    up — the live page has had exactly that.
    """

    def install(page_file: str = "page.html", delay_calls: list | None = None):
        page_html = (ENROLLMENT_FIXTURES / page_file).read_bytes()

        def fake_get(url, headers=None, timeout=None, **kwargs):
            if url == PAGE_URL:
                return _Response(page_html, url=url)
            name = Path(urllib.parse.unquote(urllib.parse.urlsplit(url).path)).name
            candidate = ENROLLMENT_FIXTURES / name
            if candidate.is_file():
                return _Response(candidate.read_bytes(), url=url)
            return _Response(b"not found", status=404, url=url)

        import requests

        monkeypatch.setattr(requests, "get", fake_get)
        return PAGE_URL

    return install


@pytest.fixture
def enrollment_env(tmp_path, monkeypatch):
    """A clean data dir and a reset scrape module for one run."""
    from owcdata.pipelines.enrollment import scrape

    scrape.reset_state()
    scrape.ON_PAGE_HTML = None
    scrape.ON_FILE_DOWNLOADED = None
    data_dir = tmp_path / "data"
    scrape.configure(data_dir)
    monkeypatch.setattr(scrape, "PAGE_URL", PAGE_URL)
    yield data_dir
    scrape.reset_state()
    scrape.ON_PAGE_HTML = None
    scrape.ON_FILE_DOWNLOADED = None


@pytest.fixture
def settings(tmp_path, monkeypatch):
    """Local-target Settings pointed at a temp dir."""
    from owcdata.config import Settings

    monkeypatch.delenv("OWC_TARGET", raising=False)
    s = Settings(
        target="local",
        env="test",
        run_id="test_run",
        local_output_dir=tmp_path / "exports",
        enrollment_data_dir=tmp_path / "data",
    )
    return s
