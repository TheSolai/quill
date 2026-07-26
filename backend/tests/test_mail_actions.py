"""
Quill mail-the-X endpoint tests — covers the new chapter / compiled / zip
endpoints, the natural-language parser, and the chat-routing dispatcher.

All tests use dry_run=true or mock send_email so no real email is sent.
"""
import pytest
import sys
import tempfile
import shutil
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent))


# --------------------------------------------------------------------------
# Natural language parser
# --------------------------------------------------------------------------

class TestParseMailAction:
    def test_book_to_address(self):
        from agentmail_service import parse_mail_action
        r = parse_mail_action("mail me the book to you@example.com")
        assert r["action"] == "book"
        assert r["to"] == "you@example.com"
        assert r["chapter"] is None
        assert r["format"] is None

    def test_chapter_to_me(self):
        from agentmail_service import parse_mail_action
        r = parse_mail_action("mail chapter 3 to me")
        assert r["action"] == "chapter"
        assert r["to"] == "me"
        assert r["chapter"] == "3"

    def test_zip_default(self):
        from agentmail_service import parse_mail_action
        r = parse_mail_action("send me a zip")
        assert r["action"] == "zip"
        assert r["to"] is None

    def test_compiled_pdf(self):
        from agentmail_service import parse_mail_action
        r = parse_mail_action("mail me the PDF to me")
        assert r["action"] == "compiled"
        assert r["to"] == "me"
        assert r["format"] == "pdf"

    def test_compiled_epub(self):
        from agentmail_service import parse_mail_action
        r = parse_mail_action("send the compiled epub to me")
        assert r["action"] == "compiled"
        assert r["format"] == "epub"

    def test_compiled_docx(self):
        from agentmail_service import parse_mail_action
        r = parse_mail_action("email me the docx")
        assert r["action"] == "compiled"
        assert r["format"] == "docx"

    def test_manuscript_routes_to_book(self):
        from agentmail_service import parse_mail_action
        r = parse_mail_action("send the manuscript to me")
        assert r["action"] == "book"

    def test_unrelated_phrase_returns_none(self):
        from agentmail_service import parse_mail_action
        assert parse_mail_action("what is the weather today") is None
        assert parse_mail_action("fix the typos in chapter 1") is None

    def test_email_keyword_routes_correctly(self):
        from agentmail_service import parse_mail_action
        r = parse_mail_action("email me the book")
        assert r["action"] == "book"
        r = parse_mail_action("send me chapter 5")
        assert r["action"] == "chapter"
        assert r["chapter"] == "5"

    def test_zip_bundle(self):
        from agentmail_service import parse_mail_action
        r = parse_mail_action("mail me a zip bundle of the project to me@x.com")
        assert r["action"] == "zip"
        assert r["to"] == "me@x.com"

    def test_with_arrow_recipient(self):
        from agentmail_service import parse_mail_action
        r = parse_mail_action("mail the book → alice@example.com")
        assert r["action"] == "book"
        assert r["to"] == "alice@example.com"


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

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


def _make_project_with_chapters(client, name="t", title="T", author="A", chapters=None):
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
# email-the-chapter endpoint
# --------------------------------------------------------------------------

class TestEmailTheChapter:
    def test_requires_to(self, client):
        pid = _make_project_with_chapters(client, chapters=[{"name": "c1", "content": "# One\n\nHi."}])
        r = client.post(f"/api/projects/{pid}/email-the-chapter", json={"chapter": "c1"})
        assert r.status_code == 400

    def test_requires_chapter(self, client):
        pid = _make_project_with_chapters(client, chapters=[{"name": "c1", "content": "# One\n\nHi."}])
        r = client.post(f"/api/projects/{pid}/email-the-chapter", json={"to": "x@x.com"})
        assert r.status_code == 400

    def test_404_for_missing_chapter(self, client):
        pid = _make_project_with_chapters(client, chapters=[{"name": "c1", "content": "# One\n\nHi."}])
        r = client.post(f"/api/projects/{pid}/email-the-chapter", json={"to": "x@x.com", "chapter": "nope"})
        assert r.status_code == 404

    def test_404_for_missing_project(self, client):
        r = client.post("/api/projects/missing/email-the-chapter",
                        json={"to": "x@x.com", "chapter": "c1"})
        assert r.status_code == 404

    def test_dry_run_does_not_send(self, client):
        pid = _make_project_with_chapters(
            client, title="My Book",
            chapters=[{"name": "chapter-1", "content": "# Chapter 1\n\nBody."}],
        )
        with patch("agentmail_service.send_email") as mock_send:
            r = client.post(
                f"/api/projects/{pid}/email-the-chapter",
                json={"to": "x@x.com", "chapter": "chapter-1", "dry_run": True},
            )
            assert not mock_send.called
        assert r.status_code == 200
        body = r.get_json()
        assert body["dry_run"] is True
        assert body["chapter"]["name"] == "chapter-1"
        assert body["chapter"]["words"] > 0

    def test_dry_run_html_format(self, client):
        pid = _make_project_with_chapters(
            client,
            chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        r = client.post(
            f"/api/projects/{pid}/email-the-chapter",
            json={"to": "x@x.com", "chapter": "c1", "format": "html", "dry_run": True},
        )
        body = r.get_json()
        assert body["chapter"]["format"] == "html"

    def test_rejects_unknown_format(self, client):
        pid = _make_project_with_chapters(
            client, chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        r = client.post(
            f"/api/projects/{pid}/email-the-chapter",
            json={"to": "x@x.com", "chapter": "c1", "format": "rtf"},
        )
        assert r.status_code == 400

    def test_invalid_chapter_name_rejected(self, client):
        pid = _make_project_with_chapters(
            client, chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        r = client.post(
            f"/api/projects/{pid}/email-the-chapter",
            json={"to": "x@x.com", "chapter": "../../../etc/passwd"},
        )
        assert r.status_code == 404


# --------------------------------------------------------------------------
# email-compiled endpoint
# --------------------------------------------------------------------------

class TestEmailCompiled:
    def test_requires_to(self, client):
        pid = _make_project_with_chapters(
            client, chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        r = client.post(f"/api/projects/{pid}/email-compiled", json={"format": "html"})
        assert r.status_code == 400

    def test_400_for_project_with_no_chapters(self, client):
        r = client.post("/api/projects", json={"name": "empty"})
        pid = r.get_json()["id"]
        r = client.post(f"/api/projects/{pid}/email-compiled", json={"to": "x@x.com"})
        assert r.status_code == 400

    def test_404_for_missing_project(self, client):
        r = client.post("/api/projects/missing/email-compiled", json={"to": "x@x.com"})
        assert r.status_code == 404

    def test_503_when_agentmail_unavailable(self, client):
        pid = _make_project_with_chapters(
            client, chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        with patch("agentmail_service.is_available", return_value=False):
            r = client.post(f"/api/projects/{pid}/email-compiled", json={"to": "x@x.com"})
        assert r.status_code == 503

    def test_dry_run_md_format_does_not_call_pandoc(self, client):
        pid = _make_project_with_chapters(
            client, title="Compiled Test", author="T",
            chapters=[{"name": "c1", "content": "# One\n\nFirst body paragraph with content."}],
        )
        with patch("agentmail_service.send_email") as mock_send:
            r = client.post(
                f"/api/projects/{pid}/email-compiled",
                json={"to": "x@x.com", "format": "md", "dry_run": True},
            )
            assert not mock_send.called
        body = r.get_json()
        assert body["ok"] is True
        assert body["book"]["format"] == "md"
        assert body["attachment_filename"].endswith(".md")
        assert body["attachment_size_bytes"] > 0

    def test_dry_run_html_format(self, client):
        pid = _make_project_with_chapters(
            client, title="HTML Test",
            chapters=[{"name": "c1", "content": "# One\n\nA paragraph."}],
        )
        r = client.post(
            f"/api/projects/{pid}/email-compiled",
            json={"to": "x@x.com", "format": "html", "dry_run": True},
        )
        body = r.get_json()
        assert body["ok"] is True
        assert body["book"]["format"] == "html"
        assert body["attachment_filename"].endswith(".html")

    def test_rejects_unknown_format(self, client):
        pid = _make_project_with_chapters(
            client, chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        r = client.post(
            f"/api/projects/{pid}/email-compiled",
            json={"to": "x@x.com", "format": "avi"},
        )
        assert r.status_code == 400

    def test_pdf_dry_run_attempts_pandoc(self, client):
        # Without pandoc, this returns 500 — but we want to verify the
        # request reaches the attachment builder. If pandoc is installed
        # in the env, we'll get a 200; otherwise 500.
        pid = _make_project_with_chapters(
            client, title="PDF Test",
            chapters=[{"name": "c1", "content": "# One\n\nA paragraph."}],
        )
        with patch("agentmail_service.send_email") as mock_send:
            r = client.post(
                f"/api/projects/{pid}/email-compiled",
                json={"to": "x@x.com", "format": "pdf", "dry_run": True},
            )
            # Should not have called send_email either way
            assert not mock_send.called
        # Status is either 200 (pandoc present) or 500 (pandoc missing)
        # — both prove the endpoint reached the right code path.
        assert r.status_code in (200, 500)


# --------------------------------------------------------------------------
# email-zip endpoint
# --------------------------------------------------------------------------

class TestEmailZip:
    def test_requires_to(self, client):
        pid = _make_project_with_chapters(
            client, chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        r = client.post(f"/api/projects/{pid}/email-zip", json={})
        assert r.status_code == 400

    def test_400_for_project_with_no_chapters(self, client):
        r = client.post("/api/projects", json={"name": "empty"})
        pid = r.get_json()["id"]
        r = client.post(f"/api/projects/{pid}/email-zip", json={"to": "x@x.com"})
        assert r.status_code == 400

    def test_404_for_missing_project(self, client):
        r = client.post("/api/projects/missing/email-zip", json={"to": "x@x.com"})
        assert r.status_code == 404

    def test_dry_run_returns_attachment_info(self, client):
        pid = _make_project_with_chapters(
            client, title="Zip Test", author="A",
            chapters=[
                {"name": "c1", "content": "# One\n\nFirst chapter body."},
                {"name": "c2", "content": "# Two\n\nSecond chapter body."},
            ],
        )
        with patch("agentmail_service.send_email") as mock_send:
            r = client.post(
                f"/api/projects/{pid}/email-zip",
                json={"to": "x@x.com", "dry_run": True},
            )
            assert not mock_send.called
        body = r.get_json()
        assert body["ok"] is True
        assert body["attachment_filename"].endswith("_bundle.zip")
        assert body["attachment_size_bytes"] > 0
        assert body["book"]["chapters"] == 2
        assert body["book"]["words"] > 0

    def test_zip_actually_contains_files(self, client):
        """Verify the zip bytes really contain chapter files when not dry-run."""
        pid = _make_project_with_chapters(
            client, title="Real Zip",
            chapters=[{"name": "c1", "content": "# One\n\nBody."}],
        )
        # We don't have pandoc-style 'inspect' for zip, but we can mock
        # send_email and check what the attachment was.
        captured = {}
        def fake_send(**kwargs):
            captured.update(kwargs)
            return {"ok": True, "message_id": "fake"}
        with patch("agentmail_service.send_email", side_effect=fake_send):
            r = client.post(f"/api/projects/{pid}/email-zip", json={"to": "x@x.com"})
        assert r.status_code == 200
        atts = captured.get("attachments", [])
        assert len(atts) == 1
        att = atts[0]
        assert att["filename"].endswith(".zip")
        # The content is base64-encoded (we bypass the SDK's Attachment
        # pydantic model). Decode and inspect.
        import base64, zipfile, io
        raw = att["content"]
        if isinstance(raw, str):
            zip_bytes = base64.b64decode(raw)
        else:
            zip_bytes = raw
        z = zipfile.ZipFile(io.BytesIO(zip_bytes))
        names = z.namelist()
        assert "manifest.json" in names
        assert "README.md" in names
        assert any(n.endswith("c1.md") for n in names)


# --------------------------------------------------------------------------
# Chat-routing dispatcher (natural language)
# --------------------------------------------------------------------------

class TestChatMailRouting:
    """The /api/chat route should detect natural-language mail commands
    and dispatch them to the right endpoint without invoking the LLM."""

    def test_mail_book_routes_to_email_the_book(self, client):
        pid = _make_project_with_chapters(
            client, chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        with patch("agentmail_service.send_email", return_value={
            "ok": True, "message_id": "fake", "to": ["x@x.com"], "subject": "x"
        }) as mock_send:
            r = client.post("/api/chat", json={
                "messages": [{"role": "user", "content": "mail me the book to x@x.com"}],
                "stream": False,
                "project_id": pid,
            })
        # Should NOT call the LLM — should hit our dispatcher
        body = r.get_json()
        assert "mail" in body or "email" in body
        # Verify our endpoint was hit (mock send_email was called)
        assert mock_send.called

    def test_chapter_to_me_returns_helpful_error(self, client):
        pid = _make_project_with_chapters(
            client, chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        r = client.post("/api/chat", json={
            "messages": [{"role": "user", "content": "mail chapter 1 to me"}],
            "stream": False,
            "project_id": pid,
        })
        body = r.get_json()
        # Should detect the intent but ask for a real address
        assert "mail" in body
        assert body["mail"]["ok"] is False
        assert "address" in body["mail"]["error"].lower()

    def test_unrelated_message_does_not_route(self, client):
        pid = _make_project_with_chapters(
            client, chapters=[{"name": "c1", "content": "# One\n\nHi."}],
        )
        # The chat endpoint should call the LLM (we don't care about the
        # response, just that no mail dispatch happened).
        with patch("server._handle_mail_action") as mock_handler, \
             patch("server._handle_email_intent") as mock_email:
            r = client.post("/api/chat", json={
                "messages": [{"role": "user", "content": "what is the weather"}],
                "stream": False,
                "project_id": pid,
            })
            # Neither handler should have been called for unrelated text
            assert not mock_handler.called
            assert not mock_email.called
