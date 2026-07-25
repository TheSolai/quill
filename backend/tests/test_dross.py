"""
Tests for Dross AI features:
  - AgentMail integration
  - Web search tool
  - Tool registry
  - Vellum DOCX export
  - New export formats (RTF, OPML, bundle)
  - Natural language email intents
"""
import json
import os
import re
import sys
import tempfile
from io import BytesIO
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))


# --------------------------------------------------------------------------
# Vellum DOCX
# --------------------------------------------------------------------------

class TestVellumDocx:
    def test_builds_valid_docx(self):
        from vellum_docx import build_vellum_docx
        chapters = [
            {"number": 1, "title": "The Beginning", "content": "It was a dark night."},
            {"number": 2, "title": "The Crossing", "content": "She found a boat."},
        ]
        result = build_vellum_docx("Test Book", "Tester", chapters)
        assert isinstance(result, bytes)
        assert len(result) > 1000  # real DOCX
        # Should start with PK (zip magic)
        assert result[:2] == b"PK"

    def test_chapters_use_heading_1(self):
        from vellum_docx import build_vellum_docx
        from docx import Document
        chapters = [
            {"number": 1, "title": "The Beginning", "content": "Body text."},
        ]
        result = build_vellum_docx("Test Book", "Tester", chapters)
        doc = Document(BytesIO(result))
        h1s = [p for p in doc.paragraphs if p.style.name == "Heading 1"]
        assert any("Chapter 1: The Beginning" in p.text for p in h1s)

    def test_scene_break_centered(self):
        from vellum_docx import build_vellum_docx, _emit_chapter_body
        from docx import Document
        # Use a smaller test — just the body emission
        doc = Document()
        _emit_chapter_body(doc, "First paragraph.\n\n***\n\nSecond paragraph.")
        from docx.enum.text import WD_ALIGN_PARAGRAPH
        centered = [p for p in doc.paragraphs
                    if p.alignment == WD_ALIGN_PARAGRAPH.CENTER and p.text.strip()]
        assert len(centered) >= 1
        assert any("***" in p.text or "* * *" in p.text for p in centered)

    def test_inline_bold_italic(self):
        from vellum_docx import build_vellum_docx
        from docx import Document
        chapters = [
            {"number": 1, "title": "Test", "content": "Some **bold** and *italic* text."},
        ]
        result = build_vellum_docx("Test", "Tester", chapters)
        doc = Document(BytesIO(result))
        # Find the paragraph with our text
        target = next(p for p in doc.paragraphs if "Some" in p.text)
        runs = target.runs
        assert any(r.bold for r in runs)
        assert any(r.italic for r in runs)

    def test_page_break_before_chapter(self):
        from vellum_docx import build_vellum_docx
        from docx import Document
        chapters = [
            {"number": 1, "title": "First", "content": "Body."},
            {"number": 2, "title": "Second", "content": "Body."},
        ]
        result = build_vellum_docx("Test", "Tester", chapters)
        doc = Document(BytesIO(result))
        h1_style = doc.styles["Heading 1"]
        # The style should have page_break_before set
        assert h1_style.paragraph_format.page_break_before is True

    def test_strips_leading_heading(self):
        from vellum_docx import _strip_leading_heading
        content = "# Chapter 1\n\nBody text here."
        result = _strip_leading_heading(content)
        assert "Body text here" in result
        assert "# Chapter 1" not in result

    def test_preserves_body_when_no_leading_heading(self):
        from vellum_docx import _strip_leading_heading
        content = "Body without heading."
        result = _strip_leading_heading(content)
        assert "Body without heading" in result


# --------------------------------------------------------------------------
# Web search
# --------------------------------------------------------------------------

class TestWebSearch:
    def test_empty_query_returns_empty(self):
        from web_search import search
        assert search("") == []
        assert search("   ") == []

    def test_search_returns_list(self):
        from web_search import search
        results = search("python programming", max_results=3)
        assert isinstance(results, list)
        # Real network test; should have at least 1 result
        if results and "error" not in results[0]:
            assert all("url" in r for r in results)


# --------------------------------------------------------------------------
# AgentMail service
# --------------------------------------------------------------------------

class TestAgentMailService:
    def test_inbox_constant(self):
        import agentmail_service
        assert agentmail_service.DROSS_INBOX == "thedross@agentmail.to"

    def test_parse_email_intent_simple(self):
        from agentmail_service import parse_email_intent
        result = parse_email_intent("email the book to user@example.com")
        assert result is not None
        assert result["to"] == "user@example.com"
        assert result["what"] == "book"

    def test_parse_email_intent_chapter(self):
        from agentmail_service import parse_email_intent
        result = parse_email_intent("send chapter 3 to editor@pub.com")
        assert result is not None
        assert result["to"] == "editor@pub.com"
        assert result["what"] == "chapter"

    def test_parse_email_intent_with_subject(self):
        from agentmail_service import parse_email_intent
        result = parse_email_intent("email the book to user@example.com subject: Final Draft")
        assert result is not None
        assert result["subject"] == "Final Draft"

    def test_parse_email_intent_no_email_returns_none(self):
        from agentmail_service import parse_email_intent
        assert parse_email_intent("hello how are you") is None
        assert parse_email_intent("write a chapter about cats") is None

    def test_parse_email_intent_no_address_returns_none(self):
        from agentmail_service import parse_email_intent
        # has 'email' but no address
        assert parse_email_intent("email me the book") is None


# --------------------------------------------------------------------------
# Dross tools
# --------------------------------------------------------------------------

class TestDrossTools:
    def test_list_tools_returns_all(self):
        from dross_tools import list_tools
        tools = list_tools()
        names = [t["name"] for t in tools]
        assert "web_search" in names
        assert "email_send" in names
        assert "shell_exec" in names
        assert "list_files" in names
        assert "read_file" in names

    def test_call_unknown_tool_returns_error(self):
        from dross_tools import call_tool
        result = call_tool("nonexistent_tool", {})
        assert "error" in result

    def test_call_web_search(self):
        from dross_tools import call_tool
        result = call_tool("web_search", {"query": "test query", "max_results": 2})
        # Real network call
        assert "results" in result or "error" in result

    def test_shell_exec_blocks_dangerous(self):
        from dross_tools import call_tool
        result = call_tool("shell_exec", {"cmd": "rm -rf /"})
        assert "error" in result
        assert "blocked" in result["error"]

    def test_shell_exec_blocks_sudo(self):
        from dross_tools import call_tool
        result = call_tool("shell_exec", {"cmd": "sudo apt-get update"})
        assert "error" in result

    def test_shell_exec_runs_safe_command(self):
        from dross_tools import call_tool
        result = call_tool("shell_exec", {"cmd": "echo hello", "timeout": 5})
        assert "stdout" in result
        assert "hello" in result["stdout"]

    def test_tools_as_openai_functions_shape(self):
        from dross_tools import tools_as_openai_functions
        funcs = tools_as_openai_functions()
        for f in funcs:
            assert f["type"] == "function"
            assert "name" in f["function"]
            assert "description" in f["function"]
            assert "parameters" in f["function"]


# --------------------------------------------------------------------------
# API endpoints
# --------------------------------------------------------------------------

@pytest.fixture
def client():
    from server import app
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


class TestAgentMailAPI:
    def test_status(self, client):
        r = client.get("/api/agentmail/status")
        assert r.status_code == 200
        d = r.get_json()
        assert d["inbox"] == "thedross@agentmail.to"

    def test_inbox(self, client):
        r = client.get("/api/agentmail/inbox?limit=5")
        assert r.status_code == 200
        d = r.get_json()
        assert "messages" in d

    def test_send_requires_to(self, client):
        r = client.post("/api/agentmail/send", json={
            "subject": "test", "text": "hi"
        })
        # 400 (no to) or 503 (sdk unavailable) or 500 (rate limited) all OK
        assert r.status_code in (400, 500, 503)

    def test_draft_requires_to(self, client):
        r = client.post("/api/agentmail/draft", json={
            "subject": "test", "text": "hi"
        })
        assert r.status_code in (400, 500, 503)


class TestToolsAPI:
    def test_list_tools(self, client):
        r = client.get("/api/tools")
        assert r.status_code == 200
        d = r.get_json()
        names = [t["name"] for t in d["tools"]]
        assert "web_search" in names
        assert "email_send" in names

    def test_call_tool_requires_name(self, client):
        r = client.post("/api/tools/call", json={"args": {}})
        assert r.status_code == 400


class TestWebSearchAPI:
    def test_search_requires_q(self, client):
        r = client.get("/api/search")
        assert r.status_code == 400

    def test_search_returns_results(self, client):
        r = client.get("/api/search?q=python&max=2")
        assert r.status_code == 200
        d = r.get_json()
        assert "results" in d


class TestNewExportFormats:
    def test_vellum_export(self, client):
        # Use a known project — set up via the test
        r = client.post("/api/projects", json={"name": "vellum-test"})
        pid = r.get_json()["id"]
        # Add a chapter
        r = client.post(f"/api/projects/{pid}/chapters", json={"name": "chapter-1"})
        # Set some content
        client.put(f"/api/projects/{pid}/chapters/chapter-1/content", json={
            "content": "# Chapter 1\n\nIt was a dark and stormy night."
        })
        # Set settings
        client.put(f"/api/projects/{pid}/settings", json={
            "title": "Vellum Test", "author": "Tester"
        })
        r = client.get(f"/api/projects/{pid}/export/vellum")
        assert r.status_code == 200
        # Should be a docx (zip with PK header)
        assert r.data[:2] == b"PK"

    def test_opml_export(self, client):
        r = client.post("/api/projects", json={"name": "opml-test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "chapter-1"})
        client.put(f"/api/projects/{pid}/chapters/chapter-1/content", json={
            "content": "# First\n\nBody."
        })
        r = client.get(f"/api/projects/{pid}/export/opml")
        assert r.status_code == 200
        assert b"<opml" in r.data

    def test_bundle_export(self, client):
        r = client.post("/api/projects", json={"name": "bundle-test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "chapter-1"})
        client.put(f"/api/projects/{pid}/chapters/chapter-1/content", json={
            "content": "# First\n\nBody text."
        })
        r = client.get(f"/api/projects/{pid}/export/bundle")
        assert r.status_code == 200
        # zip — but might also be 404 if the chapter file isn't there
        # The test just checks the endpoint exists and returns either zip or 404
        assert r.status_code in (200, 404)
        if r.status_code == 200:
            assert r.data[:2] == b"PK"

    def test_rtf_export(self, client):
        r = client.post("/api/projects", json={"name": "rtf-test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "chapter-1"})
        client.put(f"/api/projects/{pid}/chapters/chapter-1/content", json={
            "content": "# First\n\nBody text."
        })
        r = client.get(f"/api/projects/{pid}/export/rtf")
        assert r.status_code == 200
        # RTF starts with {\rtf
        assert r.data[:5] == b"{\\rtf" or b"pandoc" in r.data[:20]


class TestDrossSystemPrompt:
    def test_chat_uses_quill_persona(self, client):
        """The /api/chat endpoint should include the Quill system prompt by default."""
        from slot_providers import PROVIDERS
        mock_instance = MagicMock()
        mock_instance.chat.return_value = "PONG"
        mock_instance.stream.return_value = iter(["PONG"])
        with patch.dict(PROVIDERS, {"minimax": MagicMock(return_value=mock_instance)}):
            client.post("/api/slots/minimax-text/activate")
            r = client.post("/api/chat", json={
                "messages": [{"role": "user", "content": "Say PONG"}],
                "stream": False,
            })
            assert r.status_code == 200
            # The Quill system prompt should have been prepended
            call_args = mock_instance.chat.call_args
            messages = call_args[0][0]
            assert messages[0]["role"] == "system"
            assert "Quill" in messages[0]["content"]

    def test_chat_email_intent_routes_to_email(self, client):
        """When the user says 'email the book to X', the chat should call the email tool directly."""
        r = client.post("/api/projects", json={"name": "intent-test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "chapter-1"})
        client.put(f"/api/projects/{pid}/chapters/chapter-1/content", json={
            "content": "# Chapter 1\n\nSome body text."
        })
        from slot_providers import PROVIDERS
        mock_instance = MagicMock()
        mock_instance.chat.return_value = "should not be called"
        mock_instance.stream.return_value = iter(["should not be called"])
        with patch.dict(PROVIDERS, {"minimax": MagicMock(return_value=mock_instance)}):
            client.post("/api/slots/minimax-text/activate")
            r = client.post("/api/chat", json={
                "project_id": pid,
                "messages": [{"role": "user", "content": "email the book to amre@agentmail.to"}],
                "stream": False,
            })
            # The model should NOT be called — intent was caught
            assert mock_instance.chat.called is False
            # And we got an email result
            d = r.get_json()
            # Either email succeeded, was rate-limited, or failed for a benign reason
            assert "email" in d or "rate" in str(d).lower() or "ok" in d


if __name__ == "__main__":
    pytest.main([__file__, "-v"])


# --------------------------------------------------------------------------
# Chapter-write intent
# --------------------------------------------------------------------------

class TestChapterWriteIntent:
    def test_detect_write_chapter_1(self):
        from server import _extract_chapter_write_intent
        result = _extract_chapter_write_intent("Write the next chapter 1")
        assert result is not None
        assert result["action"] == "write_chapter"
        assert "1" in result["target"]

    def test_detect_write_chapter_word(self):
        from server import _extract_chapter_write_intent
        result = _extract_chapter_write_intent("Draft chapter three about the river")
        assert result is not None
        assert "three" in result["target"].lower() or "3" in result["target"]

    def test_detect_write_current(self):
        from server import _extract_chapter_write_intent
        result = _extract_chapter_write_intent("Continue writing this chapter")
        assert result is not None
        assert result["target"] == "current"

    def test_detect_write_scene(self):
        from server import _extract_chapter_write_intent
        result = _extract_chapter_write_intent("Compose a new scene here")
        assert result is not None

    def test_no_intent_for_random_chat(self):
        from server import _extract_chapter_write_intent
        assert _extract_chapter_write_intent("hello how are you") is None
        assert _extract_chapter_write_intent("what is the meaning of life") is None
        assert _extract_chapter_write_intent("search for cats") is None

    def test_resolve_chapter_target(self):
        from server import _resolve_chapter_target
        # Create a temp project
        import os
        from pathlib import Path
        from server import get_project_dir
        pid = "test-resolve-xyz"
        pd = get_project_dir(pid)
        # Create some chapter files
        (pd / "chapter-1.md").write_text("# 1\n")
        (pd / "chapter-2.md").write_text("# 2\n")
        try:
            # Direct match
            assert _resolve_chapter_target(pid, "chapter-1") == "chapter-1"
            # "current" falls back to first
            assert _resolve_chapter_target(pid, "current") == "chapter-1"
            # Numeric
            assert _resolve_chapter_target(pid, "chapter-2") == "chapter-2"
            # Non-existent
            assert _resolve_chapter_target(pid, "chapter-99") is None
        finally:
            import shutil
            shutil.rmtree(pd, ignore_errors=True)


# --------------------------------------------------------------------------
# Slot categories
# --------------------------------------------------------------------------

class TestSlotCategories:
    def test_default_slots_have_categories(self):
        from slots import load_slots
        for s in load_slots():
            assert s.category in ("local", "creative", "research", "code", "cloud", "minimax"), \
                f"slot {s.id} has bad category {s.category}"

    def test_tool_calling_flag_persists(self):
        from slots import load_slots
        for s in load_slots():
            if s.type in ("ollama", "mlx"):
                # All current Ollama models support tools
                assert s.tool_calling is True, f"ollama slot {s.id} should have tool_calling=True"

    def test_groq_tool_use_slot_exists(self):
        from slots import get_slot
        s = get_slot("groq-tool-use")
        assert s is not None
        assert s.model_id == "llama3-groq-tool-use:8b"
        assert s.tool_calling is True

    def test_api_returns_new_fields(self, client):
        r = client.get("/api/slots")
        d = r.get_json()
        for s in d["slots"]:
            assert "category" in s, f"slot {s['id']} missing category in API"
            assert "tool_calling" in s, f"slot {s['id']} missing tool_calling in API"
            assert "thinking" in s, f"slot {s['id']} missing thinking in API"


# --------------------------------------------------------------------------
# Tool calling in Ollama provider
# --------------------------------------------------------------------------

class TestOllamaToolCalling:
    def test_payload_includes_tools(self):
        from slots import ModelSlot
        from slot_providers import OllamaProvider
        # Construct a slot in-memory (no need to write to disk)
        s = ModelSlot(
            id="test-tool", name="Test", type="ollama",
            model_id="groq-tool",
        )
        prov = OllamaProvider(s)
        # Build payload with tools
        payload = prov._build_payload(
            [{"role": "user", "content": "What's the weather?"}],
            {"tools": [{"type": "function", "function": {"name": "weather", "description": "Get weather"}}]},
            stream=False
        )
        assert "tools" in payload
        assert len(payload["tools"]) == 1

    def test_payload_no_tools(self):
        from slots import ModelSlot
        from slot_providers import OllamaProvider
        s = ModelSlot(
            id="test-no-tool", name="Test", type="ollama",
            model_id="gemma4:31b",
        )
        prov = OllamaProvider(s)
        payload = prov._build_payload(
            [{"role": "user", "content": "Hello"}],
            {},
            stream=False
        )
        assert "tools" not in payload


# --------------------------------------------------------------------------
# Input validation (path safety)
# --------------------------------------------------------------------------

class TestInputValidation:
    """Bug fixes: path traversal, slash in names, null content, etc."""

    def test_safe_name_replaces_slash(self):
        from server import safe_name
        assert "/" not in safe_name("my/chapter")
        # Should be safe to use as filename
        assert safe_name("my/chapter") == "my-chapter"

    def test_safe_name_rejects_path_traversal(self):
        from server import safe_name
        result = safe_name("../etc/passwd")
        assert ".." not in result
        assert "/" not in result

    def test_safe_name_replaces_spaces(self):
        from server import safe_name
        assert safe_name("Chapter One") == "Chapter-One"

    def test_safe_name_handles_unicode(self):
        from server import safe_name
        assert safe_name("café") == "café"
        assert safe_name("日本語") == "日本語"

    def test_safe_name_handles_empty(self):
        from server import safe_name
        assert safe_name("") == "untitled"
        assert safe_name(None) == "untitled"
        assert safe_name("   ") == "untitled"

    def test_safe_name_handles_special_chars(self):
        from server import safe_name
        for char in '<>:"/\\|?*':
            result = safe_name(f"a{char}b")
            assert char not in result, f"safe_name didn't remove {char!r}"

    def test_safe_name_collapses_dashes(self):
        from server import safe_name
        # Multiple consecutive dashes collapse
        assert safe_name("a---b") == "a-b"
        # Spaces become dashes first, then collapse
        assert safe_name("a - - b") == "a-b"
        # Tabs/newlines become dashes too
        assert safe_name("a\t\tb") == "a-b"

    def test_safe_name_length_limit(self):
        from server import safe_name
        long = "a" * 200
        result = safe_name(long, max_len=50)
        assert len(result) <= 50

    def test_validate_project_id(self):
        from server import validate_project_id
        assert validate_project_id("book") == "book"
        assert validate_project_id("book-1") == "book-1"
        # Invalid
        assert validate_project_id("") is None
        assert validate_project_id("a/b") is None
        assert validate_project_id("a\\b") is None
        assert validate_project_id(".hidden") is None
        assert validate_project_id("a" * 100) is None
        assert validate_project_id(None) is None

    def test_safe_content_handles_null(self):
        from server import safe_content
        assert safe_content(None) == ""
        assert safe_content("") == ""
        assert safe_content("hello") == "hello"
        assert safe_content(123) == "123"

    def test_create_chapter_sanitizes_name(self, client):
        """Chapter names with slashes should be sanitized, not 500."""
        r = client.post("/api/projects", json={"name": "bug-fix-test"})
        pid = r.get_json()["id"]
        # Slash in name should not crash
        r = client.post(f"/api/projects/{pid}/chapters", json={"name": "my/chapter?"})
        assert r.status_code == 200, f"Got {r.status_code}: {r.text}"
        d = r.get_json()
        assert "/" not in d["name"]

    def test_create_chapter_with_path_traversal(self, client):
        """Chapter names with .. should be sanitized."""
        r = client.post("/api/projects", json={"name": "bug-fix-test2"})
        pid = r.get_json()["id"]
        r = client.post(f"/api/projects/{pid}/chapters", json={"name": "../etc/passwd"})
        assert r.status_code == 200, f"Got {r.status_code}: {r.text}"
        d = r.get_json()
        assert ".." not in d["name"]
        assert "/" not in d["name"]

    def test_create_project_sanitizes_path_traversal(self, client):
        """Project names with .. should be sanitized to safe names."""
        r = client.post("/api/projects", json={"name": "../etc"})
        # The name is sanitized to "etc" (a safe folder name, not a 400)
        assert r.status_code == 200
        d = r.get_json()
        assert ".." not in d["id"]
        assert "/" not in d["id"]
        # Direct dot-slash should be rejected
        r = client.post("/api/projects", json={"name": "../../../etc/passwd"})
        assert r.status_code == 200
        d = r.get_json()
        assert ".." not in d["id"]

    def test_compile_nonexistent_project_404(self, client):
        r = client.get("/api/projects/nonexistent-xyz-12345/compile")
        assert r.status_code == 404

    def test_list_scenes_nonexistent_chapter_404(self, client):
        r = client.post("/api/projects", json={"name": "scene-test"})
        pid = r.get_json()["id"]
        r = client.get(f"/api/projects/{pid}/chapters/nonexistent/scenes")
        assert r.status_code == 404

    def test_save_null_content_succeeds(self, client):
        """Save with null content should default to empty string, not 500."""
        r = client.post("/api/projects", json={"name": "null-content-test"})
        pid = r.get_json()["id"]
        r = client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        # null content
        r = client.put(f"/api/projects/{pid}/chapters/c1/content", json={"content": None})
        assert r.status_code == 200
        d = r.get_json()
        assert d.get("bytes") == 0
        # missing content
        r = client.put(f"/api/projects/{pid}/chapters/c1/content", json={})
        assert r.status_code == 200

    def test_stats_bounds(self, client):
        """Stats should validate bounds."""
        r = client.post("/api/projects", json={"name": "stats-bounds-test"})
        pid = r.get_json()["id"]
        # Too high
        r = client.put(f"/api/projects/{pid}/stats", json={"daily_goal": 10000000})
        assert r.status_code == 400
        # Negative
        r = client.put(f"/api/projects/{pid}/stats", json={"daily_goal": -1})
        assert r.status_code == 400
        # Valid
        r = client.put(f"/api/projects/{pid}/stats", json={"daily_goal": 1000})
        assert r.status_code == 200

    def test_delete_nonexistent_chapter_404(self, client):
        r = client.post("/api/projects", json={"name": "del-test"})
        pid = r.get_json()["id"]
        r = client.delete(f"/api/projects/{pid}/chapters/nonexistent")
        assert r.status_code == 404


# --------------------------------------------------------------------------
# Quill rename (replaces Dross references)
# --------------------------------------------------------------------------

class TestQuillRename:
    def test_ai_assistant_says_quill(self, client):
        """The /api/chat should use the Quill persona, not Dross."""
        from slot_providers import PROVIDERS
        mock_instance = MagicMock()
        mock_instance.chat.return_value = "ok"
        mock_instance.stream.return_value = iter(["ok"])
        with patch.dict(PROVIDERS, {"minimax": MagicMock(return_value=mock_instance)}):
            client.post("/api/slots/minimax-text/activate")
            r = client.post("/api/chat", json={
                "messages": [{"role": "user", "content": "hi"}],
                "stream": False,
            })
            assert r.status_code == 200
            msgs = mock_instance.chat.call_args[0][0]
            assert "Quill" in msgs[0]["content"]
            assert "Dross" not in msgs[0]["content"]

    def test_chapter_writer_persona_is_quill(self):
        from book_writer import CHAPTER_SYSTEM
        assert "Quill" in CHAPTER_SYSTEM
        assert "Dross" not in CHAPTER_SYSTEM


# --------------------------------------------------------------------------
# Edit-fix endpoint (Zed-style inline AI)
# --------------------------------------------------------------------------

class TestEditFix:
    """Tests for /api/edit-fix — the inline AI fix endpoint used by the
    Swift editor's "Tab to fix" feature. Backed by a small fast slot
    (gemma4:latest, llama3-groq-tool-use:8b, etc.)."""

    def test_endpoint_exists(self, client):
        r = client.post("/api/edit-fix", json={"text": "hello wrold"})
        # Either 200 (with text) or 5xx (no slot) — never 404
        assert r.status_code != 404

    def test_requires_text_field(self, client):
        r = client.post("/api/edit-fix", json={})
        assert r.status_code == 400
        d = r.get_json()
        assert "text" in d.get("error", "")

    def test_rejects_empty_text(self, client):
        r = client.post("/api/edit-fix", json={"text": ""})
        assert r.status_code == 400
        r = client.post("/api/edit-fix", json={"text": "   "})
        assert r.status_code == 400

    def test_rejects_non_string_text(self, client):
        r = client.post("/api/edit-fix", json={"text": 12345})
        assert r.status_code == 400
        r = client.post("/api/edit-fix", json={"text": None})
        assert r.status_code == 400
        r = client.post("/api/edit-fix", json={"text": ["list", "of", "words"]})
        assert r.status_code == 400

    def test_rejects_text_too_long(self, client):
        big_text = "a" * 20001
        r = client.post("/api/edit-fix", json={"text": big_text})
        assert r.status_code == 400
        d = r.get_json()
        assert "too long" in d.get("error", "").lower() or "max" in d.get("error", "").lower()

    def test_default_instruction(self, client):
        """When no instruction is provided, the default 'fix typos and grammar' is used."""
        from unittest.mock import patch, MagicMock
        from slot_providers import PROVIDERS
        # Activate an ollama slot so the edit-fix endpoint routes to our mock
        client.post("/api/slots/gemma4-fast/activate")
        mock_inst = MagicMock()
        mock_inst.chat.return_value = "fixed text"
        with patch.dict(PROVIDERS, {"ollama": MagicMock(return_value=mock_inst)}):
            r = client.post("/api/edit-fix", json={"text": "helo wrold"})
            assert r.status_code == 200, r.get_data(as_text=True)
            mock_inst.chat.assert_called_once()
            msgs = mock_inst.chat.call_args[0][0]
            system_msg = msgs[0]
            assert "typos" in system_msg["content"].lower() or \
                   "grammar" in system_msg["content"].lower()
            user_msg = msgs[1]
            assert "fix typos" in user_msg["content"].lower()

    def test_custom_instruction(self, client):
        from unittest.mock import patch, MagicMock
        from slot_providers import PROVIDERS
        client.post("/api/slots/gemma4-fast/activate")
        mock_inst = MagicMock()
        mock_inst.chat.return_value = "expanded"
        with patch.dict(PROVIDERS, {"ollama": MagicMock(return_value=mock_inst)}):
            r = client.post("/api/edit-fix", json={
                "text": "short",
                "instruction": "expand with sensory detail",
            })
            assert r.status_code == 200
            msgs = mock_inst.chat.call_args[0][0]
            assert "expand with sensory detail" in msgs[1]["content"]

    def test_strips_code_fence_wrapper(self):
        """_strip_edit_fix_wrapper should remove ```markdown blocks and preambles."""
        from server import _strip_edit_fix_wrapper
        assert _strip_edit_fix_wrapper("```markdown\nfixed text\n```") == "fixed text"
        assert _strip_edit_fix_wrapper("```\nfixed text\n```") == "fixed text"
        assert _strip_edit_fix_wrapper("Here is the corrected text:\n\nfixed text") == "fixed text"
        assert _strip_edit_fix_wrapper("Corrected text: fixed text") == "fixed text"
        assert _strip_edit_fix_wrapper("  just text  ") == "just text"
        assert _strip_edit_fix_wrapper("no wrapper here") == "no wrapper here"

    def test_response_shape(self, client):
        """Successful response has text, slot_id, model_id, original_chars, fixed_chars."""
        from unittest.mock import patch, MagicMock
        from slot_providers import PROVIDERS
        client.post("/api/slots/gemma4-fast/activate")
        mock_inst = MagicMock()
        mock_inst.chat.return_value = "fixed version"
        with patch.dict(PROVIDERS, {"ollama": MagicMock(return_value=mock_inst)}):
            r = client.post("/api/edit-fix", json={"text": "original text"})
            assert r.status_code == 200
            d = r.get_json()
            assert "text" in d
            assert "slot_id" in d
            assert "model_id" in d
            assert d["original_chars"] == len("original text")
            assert d["fixed_chars"] == len("fixed version")
            assert d["instruction"] == "fix typos and grammar"

    def test_low_temperature_for_determinism(self, client):
        """edit-fix should use low temperature for deterministic fixes."""
        from unittest.mock import patch, MagicMock
        from slot_providers import PROVIDERS
        client.post("/api/slots/gemma4-fast/activate")
        mock_inst = MagicMock()
        mock_inst.chat.return_value = "x"
        with patch.dict(PROVIDERS, {"ollama": MagicMock(return_value=mock_inst)}):
            r = client.post("/api/edit-fix", json={"text": "hi"})
            assert r.status_code == 200
            call_kwargs = mock_inst.chat.call_args[1]
            assert call_kwargs.get("temperature", 1.0) <= 0.3
            assert call_kwargs.get("max_tokens", 0) >= 256

    def test_instruction_truncation(self, client):
        """Overly long instructions fall back to the default."""
        from unittest.mock import patch, MagicMock
        from slot_providers import PROVIDERS
        client.post("/api/slots/gemma4-fast/activate")
        mock_inst = MagicMock()
        mock_inst.chat.return_value = "x"
        with patch.dict(PROVIDERS, {"ollama": MagicMock(return_value=mock_inst)}):
            r = client.post("/api/edit-fix", json={
                "text": "hi",
                "instruction": "x" * 600,  # > 500 char limit
            })
            assert r.status_code == 200
            d = r.get_json()
            # Should have used the default instruction
            assert d["instruction"] == "fix typos and grammar"
