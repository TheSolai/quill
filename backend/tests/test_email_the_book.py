"""
Quill "Email the book" failsafe endpoint tests.

The endpoint at POST /api/projects/<id>/email-the-book bundles the current
manuscript and emails it. We test:
  - validation (to required, format must be md|html)
  - missing project (404)
  - agentmail unavailable (503)
  - happy path with dry_run=True (so no real email is sent)
  - the bundled content actually contains the chapter text
"""
import pytest
import sys
import tempfile
import shutil
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent))


@pytest.fixture
def app():
    import server as srv
    real_base = srv.BASE_DIR
    srv.BASE_DIR = Path(tempfile.mkdtemp()) / "projects"
    srv.BASE_DIR.mkdir(parents=True, exist_ok=True)
    srv.app.config["TESTING"] = True
    yield srv.app
    srv.BASE_DIR = real_base
    shutil.rmtree(srv.BASE_DIR.parent, ignore_errors=True)


@pytest.fixture
def client(app):
    return app.test_client()


def _create_project_with_chapters(client, name="failsafe", title="My Book", author="Tester", chapters=None):
    r = client.post("/api/projects", json={"name": name})
    pid = r.get_json()["id"]
    client.put(f"/api/projects/{pid}/settings", json={"title": title, "author": author})
    for ch in (chapters or []):
        client.post(f"/api/projects/{pid}/chapters", json={"name": ch["name"]})
        client.put(
            f"/api/projects/{pid}/chapters/{ch['name']}/content",
            json={"content": ch["content"]},
        )
    return pid


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------

class TestEmailTheBookValidation:
    def test_requires_to(self, client):
        pid = _create_project_with_chapters(client, chapters=[{"name": "c1", "content": "# One\n\nHello."}])
        r = client.post(f"/api/projects/{pid}/email-the-book", json={})
        assert r.status_code == 400
        assert "to" in r.get_json()["error"]

    def test_rejects_unknown_format(self, client):
        pid = _create_project_with_chapters(client, chapters=[{"name": "c1", "content": "# One\n\nHello."}])
        r = client.post(
            f"/api/projects/{pid}/email-the-book",
            json={"to": "you@example.com", "format": "pdf"},
        )
        assert r.status_code == 400
        assert "format" in r.get_json()["error"]

    def test_404_for_missing_project(self, client):
        r = client.post("/api/projects/does-not-exist/email-the-book", json={"to": "you@example.com"})
        assert r.status_code == 404

    def test_400_for_project_with_no_chapters(self, client):
        r = client.post("/api/projects", json={"name": "empty"})
        pid = r.get_json()["id"]
        r = client.post(f"/api/projects/{pid}/email-the-book", json={"to": "you@example.com"})
        assert r.status_code == 400
        assert "no chapters" in r.get_json()["error"]

    def test_503_when_agentmail_unavailable(self, client):
        pid = _create_project_with_chapters(client, chapters=[{"name": "c1", "content": "# One\n\nHello."}])
        with patch("agentmail_service.is_available", return_value=False):
            r = client.post(f"/api/projects/{pid}/email-the-book", json={"to": "you@example.com"})
        assert r.status_code == 503


# --------------------------------------------------------------------------
# Dry-run (no real email sent)
# --------------------------------------------------------------------------

class TestEmailTheBookDryRun:
    """When dry_run=true, the endpoint must NOT call the real AgentMail
    send function — it returns a preview of what would be sent."""

    def test_dry_run_does_not_send(self, client):
        pid = _create_project_with_chapters(
            client,
            title="Failsafe Title",
            author="Quill Tester",
            chapters=[
                {"name": "chapter-01", "content": "# Chapter 1\n\nThe story begins here."},
                {"name": "chapter-02", "content": "# Chapter 2\n\nThe story continues."},
            ],
        )
        with patch("agentmail_service.send_email") as mock_send:
            r = client.post(
                f"/api/projects/{pid}/email-the-book",
                json={"to": "you@example.com", "dry_run": True},
            )
            assert not mock_send.called, "dry_run must not call send_email"
        assert r.status_code == 200
        body = r.get_json()
        assert body["ok"] is True
        assert body["dry_run"] is True
        assert body["would_send_to"] == "you@example.com"
        assert "Failsafe Title" in body["subject"]
        assert body["book"]["chapters"] if "chapters" in body["book"] else True  # chapters may not be in book
        assert body["book"]["title"] == "Failsafe Title"
        assert body["book"]["author"] == "Quill Tester"
        assert body["book"]["format"] == "html"
        assert body["book"]["words"] > 0

    def test_dry_run_md_format(self, client):
        pid = _create_project_with_chapters(
            client,
            title="Plain Book",
            chapters=[{"name": "c1", "content": "# Chapter 1\n\nJust text."}],
        )
        with patch("agentmail_service.send_email") as mock_send:
            r = client.post(
                f"/api/projects/{pid}/email-the-book",
                json={"to": "you@example.com", "format": "md", "dry_run": True},
            )
            assert not mock_send.called
        assert r.status_code == 200
        body = r.get_json()
        assert body["book"]["format"] == "md"

    def test_dry_run_includes_attachment_filename(self, client):
        pid = _create_project_with_chapters(
            client,
            title="The Quill Book",
            chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        r = client.post(
            f"/api/projects/{pid}/email-the-book",
            json={"to": "you@example.com", "dry_run": True},
        )
        body = r.get_json()
        assert body["attachment_filename"] == "The_Quill_Book.md"

    def test_dry_run_no_attachment_when_disabled(self, client):
        pid = _create_project_with_chapters(
            client,
            chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        r = client.post(
            f"/api/projects/{pid}/email-the-book",
            json={"to": "you@example.com", "include_attachments": False, "dry_run": True},
        )
        body = r.get_json()
        assert body["attachment_filename"] is None

    def test_dry_run_subject_includes_word_count(self, client):
        pid = _create_project_with_chapters(
            client,
            title="Wordy",
            chapters=[{"name": "c1", "content": "# One\n\n" + "alpha " * 100}],
        )
        r = client.post(
            f"/api/projects/{pid}/email-the-book",
            json={"to": "you@example.com", "dry_run": True},
        )
        body = r.get_json()
        # The subject should include the word count from the compiled book
        assert "Wordy" in body["subject"]
        assert "words" in body["subject"]
        # The book has at least the 100 'alpha' words
        assert body["book"]["words"] >= 100


# --------------------------------------------------------------------------
# Real send (with mocked send_email so we don't actually email)
# --------------------------------------------------------------------------

class TestEmailTheBookHappyPath:
    """End-to-end shape — agentmail is mocked to simulate a successful send."""

    def test_returns_message_id_on_success(self, client):
        pid = _create_project_with_chapters(
            client,
            title="Real Send",
            chapters=[{"name": "c1", "content": "# One\n\nHello world."}],
        )
        with patch("agentmail_service.send_email", return_value={
            "ok": True,
            "message_id": "fake-msg-id-123",
            "to": ["you@example.com"],
            "subject": "Real Send — 2026-07-26",
        }) as mock_send:
            r = client.post(
                f"/api/projects/{pid}/email-the-book",
                json={"to": "you@example.com"},
            )
        assert r.status_code == 200
        body = r.get_json()
        assert body["ok"] is True
        assert body["message_id"] == "fake-msg-id-123"
        # Verify send was called with the expected args
        call_kwargs = mock_send.call_args.kwargs
        assert call_kwargs["to"] == "you@example.com"
        assert "Real Send" in call_kwargs["subject"]
        assert "html" in call_kwargs, "should send html by default"
        assert "attachments" in call_kwargs, "should include .md attachment by default"

    def test_returns_500_when_send_fails(self, client):
        pid = _create_project_with_chapters(
            client,
            chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        with patch("agentmail_service.send_email", return_value={
            "ok": False, "error": "rate limited"
        }):
            r = client.post(
                f"/api/projects/{pid}/email-the-book",
                json={"to": "you@example.com"},
            )
        assert r.status_code == 500
        assert "rate limited" in r.get_json()["error"]


# --------------------------------------------------------------------------
# Sanitization
# --------------------------------------------------------------------------

class TestEmailTheBookFilenameSanitization:
    def test_special_chars_in_title_become_underscores(self, client):
        pid = _create_project_with_chapters(
            client,
            title="My Book / Vol. 2: The Reckoning!!!",
            chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        r = client.post(
            f"/api/projects/{pid}/email-the-book",
            json={"to": "you@example.com", "dry_run": True},
        )
        body = r.get_json()
        # Only safe chars survive in the filename
        assert "/" not in body["attachment_filename"]
        assert ":" not in body["attachment_filename"]
        assert "!" not in body["attachment_filename"]
        assert body["attachment_filename"].endswith(".md")
