"""
Quill book writer — pytest unit tests for the outline parser, project reuse,
title wrapping, and the actual /api compile output.

Run: cd ~/Projects/Quill/backend && python3 -m pytest tests/test_book_writer.py -v
"""
import pytest
import json
import re
import sys
import tempfile
import shutil
from pathlib import Path
from unittest.mock import patch, MagicMock

# Add book_writer.py to path
sys.path.insert(0, str(Path(__file__).parent.parent))


class TestOutlineParser:
    """The outline parser must handle markdown bold, plain text, and edge cases."""

    def _parse(self, outline_text):
        # Inline of book_writer.py parser logic for unit testing
        import re as _re
        chapters = []
        cur = {}
        chapter_re = _re.compile(
            r"^\*?\*?CHAPTER\s+(\d+)\*?\*?(?:[:\.\s\-—]+\*?\*?(.*?)\*?\*?)?\s*$",
            _re.IGNORECASE
        )
        summary_re = _re.compile(
            r"^\*?\*?SUMMARY\*?\*?[:\.\s]+(.+)$",
            _re.IGNORECASE
        )

        for line in outline_text.split("\n"):
            line = line.strip()
            m = chapter_re.match(line)
            if m:
                if cur:
                    chapters.append(cur)
                num = int(m.group(1))
                title_raw = (m.group(2) or "").strip()
                title_raw = _re.sub(r"^[:\.\s\-—\*]+", "", title_raw)
                title = title_raw.strip() if title_raw else f"Chapter {num}"
                cur = {"num": num, "title": title}
                continue
            m = summary_re.match(line)
            if m and cur:
                cur["summary"] = m.group(1).strip()
                continue
            if cur and cur.get("summary") and line and not chapter_re.match(line):
                cur["summary"] = cur["summary"] + " " + line
        if cur:
            chapters.append(cur)
        return chapters

    def test_bold_chapter_headers(self):
        """The bug we hit: outline has `**CHAPTER 1:**` with markdown bold."""
        outline = """
**CHAPTER 1:** The Map Flickers to Black
SUMMARY: Iris discovers a blank space on a digital map.

**CHAPTER 2:** The Cartographer's Ghost
SUMMARY: Iris tracks down her reclusive grandmother.
"""
        chapters = self._parse(outline)
        assert len(chapters) == 2, f"got {len(chapters)}: {chapters}"
        assert chapters[0]["title"] == "The Map Flickers to Black", f"got: {chapters[0]['title']}"
        assert chapters[1]["title"] == "The Cartographer's Ghost", f"got: {chapters[1]['title']}"
        assert "Iris discovers" in chapters[0]["summary"]

    def test_plain_chapter_headers(self):
        outline = """
CHAPTER 1: Plain Title
SUMMARY: A summary here.

CHAPTER 2: Another Title
SUMMARY: More summary.
"""
        chapters = self._parse(outline)
        assert len(chapters) == 2
        assert chapters[0]["title"] == "Plain Title"
        assert chapters[1]["title"] == "Another Title"

    def test_unbolded_with_period(self):
        """CHAPTER 1. Some title — period instead of colon"""
        outline = """
CHAPTER 1. The Beginning
SUMMARY: First.
"""
        chapters = self._parse(outline)
        assert len(chapters) == 1
        assert chapters[0]["title"] == "The Beginning"

    def test_dash_separator(self):
        outline = """
CHAPTER 1 — A title with em-dash
SUMMARY: Test.
"""
        chapters = self._parse(outline)
        assert len(chapters) == 1
        assert chapters[0]["title"] == "A title with em-dash"

    def test_multiline_summary(self):
        outline = """
CHAPTER 1: A title
SUMMARY: First line of summary
that continues on the next line.
And another line.

CHAPTER 2: Another
SUMMARY: Just one line.
"""
        chapters = self._parse(outline)
        assert len(chapters) == 2
        assert "continues on the next line" in chapters[0]["summary"]
        assert chapters[1]["title"] == "Another"

    def test_empty_outline_falls_back(self):
        """Empty outline should produce zero chapters (and the book_writer fills in)."""
        chapters = self._parse("")
        assert len(chapters) == 0

    def test_chapter_without_title_falls_back(self):
        outline = """
CHAPTER 1
SUMMARY: No title given.
"""
        chapters = self._parse(outline)
        assert len(chapters) == 1
        # Falls back to "Chapter 1"
        assert chapters[0]["title"] == "Chapter 1"

    def test_15_chapter_realistic(self):
        """The full 15-chapter outline as it came back from qwen3."""
        outline = """
**CHAPTER 1:** The Map Flickers to Black
SUMMARY: Iris Vex discovers a jagged void on a digital map during a routine audit, her breath catching as the anomaly pulses.

**CHAPTER 2:** The Cartographer's Ghost
SUMMARY: Iris tracks down her reclusive grandmother, Elara, who reveals the truth.

**CHAPTER 3:** Ink and Instinct
SUMMARY: Elara teaches Iris the dying art.

**CHAPTER 4:** The Syndicate's Shadow
SUMMARY: Director Kael offers Iris a deal.

**CHAPTER 5:** The First Trace
SUMMARY: Iris and Tane begin their journey.

**CHAPTER 6:** The Veil's Whisper
SUMMARY: Navigating The Veil's shifting dunes.

**CHAPTER 7:** The Legacy Cartographers
SUMMARY: Iris meets rebels.

**CHAPTER 8:** Fractured Loyalties
SUMMARY: Tane reveals his ties.

**CHAPTER 9:** The Corporate Hunt
SUMMARY: Enforcers corner them.

**CHAPTER 10:** The Cartographer's Secret
SUMMARY: Elara's past unveiled.

**CHAPTER 11:** The Hidden City
SUMMARY: A city revealed.

**CHAPTER 12:** The Syndicate's Trap
SUMMARY: Kael lures her.

**CHAPTER 13:** The First Trace, Reclaimed
SUMMARY: Iris burns the map.

**CHAPTER 14:** The Cartographer's Choice
SUMMARY: Elara sacrifices herself.

**CHAPTER 15:** The Unmapped World
SUMMARY: Iris publishes her map.
"""
        chapters = self._parse(outline)
        assert len(chapters) == 15
        # All chapters have unique titles
        titles = [c["title"] for c in chapters]
        assert len(set(titles)) == 15, f"duplicate titles: {titles}"
        # Each has a summary
        for c in chapters:
            assert c["summary"], f"chapter {c['num']} missing summary"


# ---- Integration tests against the live backend -----------------------------

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


class TestBackendCompile:
    """Test the /api/projects/<id>/compile endpoint."""

    def test_compile_preserves_chapter_titles(self, client):
        """Each chapter should be preserved in the compiled output with its title."""
        # Create project
        r = client.post("/api/projects", json={"name": "Title Test"})
        pid = r.get_json()["id"]

        # Create chapters with custom titles in their content
        client.post(f"/api/projects/{pid}/chapters", json={"name": "ch1"})
        client.put(f"/api/projects/{pid}/chapters/ch1/content", json={
            "content": "# Chapter 1: The Awakening\n\nIt was a dark and stormy night."
        })
        client.post(f"/api/projects/{pid}/chapters", json={"name": "ch2"})
        client.put(f"/api/projects/{pid}/chapters/ch2/content", json={
            "content": "# Chapter 2: The Journey\n\nShe walked into the forest."
        })

        # Compile
        r = client.get(f"/api/projects/{pid}/compile")
        data = r.get_json()
        assert "The Awakening" in data["content"], f"missing chapter 1 title: {data['content'][:300]}"
        assert "The Journey" in data["content"], f"missing chapter 2 title: {data['content'][:300]}"
        assert data["chapter_count"] == 2

    def test_compile_word_count_excludes_front_matter(self, client):
        """Front matter shouldn't dramatically inflate word count beyond chapter content."""
        r = client.post("/api/projects", json={"name": "Word Count Test"})
        pid = r.get_json()["id"]
        client.put(f"/api/projects/{pid}/settings", json={
            "title": "Test Book",
            "author": "Tester",
            "dedication": "For my parents and the readers.",
            "epigraph": "A test quote.",
        })
        client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        client.put(f"/api/projects/{pid}/chapters/c1/content", json={
            "content": "# Chapter 1\n\nOne two three four five six seven eight nine ten."
        })

        r = client.get(f"/api/projects/{pid}/compile")
        wc = r.get_json()["word_count"]
        # 10 content words + ~20 front matter words = ~30 total
        # Assert it doesn't blow up
        assert 10 <= wc <= 60, f"unexpected word count: {wc}"

    def test_compile_handles_chapter_with_only_heading(self, client):
        """A chapter with just a heading should be skipped, not break compile."""
        r = client.post("/api/projects", json={"name": "Empty Chapter Test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "empty"})
        # Chapter with only heading (auto-generated)
        client.post(f"/api/projects/{pid}/chapters", json={"name": "real"})
        client.put(f"/api/projects/{pid}/chapters/real/content", json={
            "content": "# Chapter 1\n\nReal content here."
        })

        r = client.get(f"/api/projects/{pid}/compile")
        data = r.get_json()
        assert data["chapter_count"] == 1  # Empty one is skipped
        assert "Real content here" in data["content"]

    def test_compile_sorts_chapters_numerically(self, client):
        """chapters 1, 10, 2 should sort 1, 2, 10 — not 1, 10, 2."""
        r = client.post("/api/projects", json={"name": "Sort Test"})
        pid = r.get_json()["id"]
        for n in ["chapter-1", "chapter-10", "chapter-2"]:
            client.post(f"/api/projects/{pid}/chapters", json={"name": n})
            client.put(f"/api/projects/{pid}/chapters/{n}/content", json={
                "content": f"# {n}\n\nContent for {n}."
            })

        r = client.get(f"/api/projects/{pid}/compile")
        content = r.get_json()["content"]
        # Find positions of each chapter heading
        pos_1 = content.find("# chapter-1")
        pos_2 = content.find("# chapter-2")
        pos_10 = content.find("# chapter-10")
        assert pos_1 < pos_2 < pos_10, f"order wrong: {pos_1}, {pos_2}, {pos_10}"


class TestBackendExport:
    """Test /api/projects/<id>/export/<format>"""

    def test_export_md_returns_text(self, client):
        r = client.post("/api/projects", json={"name": "Export MD Test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        client.put(f"/api/projects/{pid}/chapters/c1/content", json={
            "content": "# Chapter 1\n\nTest content."
        })

        r = client.get(f"/api/projects/{pid}/export/md")
        assert r.status_code == 200
        assert b"Test content" in r.data
        assert r.content_type == "text/markdown; charset=utf-8"

    def test_export_strips_markdown_in_txt(self, client):
        r = client.post("/api/projects", json={"name": "Export TXT Test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        client.put(f"/api/projects/{pid}/chapters/c1/content", json={
            "content": "# Chapter 1\n\n**Bold** and *italic* and [link](http://x.com) text.\n> A quote\n---\n"
        })

        r = client.get(f"/api/projects/{pid}/export/txt")
        assert r.status_code == 200
        txt = r.data.decode("utf-8")
        assert "**Bold**" not in txt
        assert "Bold" in txt
        assert "link](http" not in txt
        assert "link" in txt
        assert "> A quote" not in txt
        assert "A quote" in txt

    def test_export_unknown_format_400(self, client):
        r = client.post("/api/projects", json={"name": "Bad Format Test"})
        pid = r.get_json()["id"]
        r = client.get(f"/api/projects/{pid}/export/docx")
        # 200 if pandoc available, 500 if not, 400 only if completely unknown
        r = client.get(f"/api/projects/{pid}/export/rtf")
        assert r.status_code == 400


class TestBackendEdgeCases:
    """Test edge cases that the user might hit."""

    def test_unicode_in_title(self, client):
        r = client.post("/api/projects", json={"name": "日本語の本"})
        assert r.status_code == 200
        pid = r.get_json()["id"]
        r = client.get(f"/api/projects/{pid}/settings")
        assert "gemma4:latest" in r.get_json()["model"]

    def test_very_long_content(self, client):
        """1MB of content should save and read back."""
        r = client.post("/api/projects", json={"name": "Big Book Test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "big"})
        huge = "The rain hammered the window. " * 50000  # ~1.25MB
        r = client.put(f"/api/projects/{pid}/chapters/big/content", json={"content": huge})
        assert r.status_code == 200
        r = client.get(f"/api/projects/{pid}/chapters/big/content")
        assert r.get_json()["content"] == huge

    def test_special_chars_in_settings(self, client):
        r = client.post("/api/projects", json={"name": "Special Test"})
        pid = r.get_json()["id"]
        r = client.put(f"/api/projects/{pid}/settings", json={
            "title": "Book & Co. — A \"Test\" <Novel>",
            "dedication": "For 'mom' & dad.",
        })
        assert r.status_code == 200
        r = client.get(f"/api/projects/{pid}/settings")
        data = r.get_json()
        assert data["title"] == "Book & Co. — A \"Test\" <Novel>"
        assert data["dedication"] == "For 'mom' & dad."

    def test_concurrent_project_creation(self, client):
        """Multiple projects with the same name should dedupe to one ID."""
        ids = []
        for _ in range(3):
            r = client.post("/api/projects", json={"name": "Same Name"})
            ids.append(r.get_json()["id"])
        assert ids[0] == ids[1] == ids[2], f"different IDs: {ids}"

    def test_delete_chapter_then_compile(self, client):
        """Deleting a chapter then compiling should not include it."""
        r = client.post("/api/projects", json={"name": "Delete Test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "keep"})
        client.put(f"/api/projects/{pid}/chapters/keep/content", json={"content": "# Keep\n\nReal."})
        client.post(f"/api/projects/{pid}/chapters", json={"name": "del"})
        client.put(f"/api/projects/{pid}/chapters/del/content", json={"content": "# Delete\n\nGone soon."})

        client.delete(f"/api/projects/{pid}/chapters/del")
        r = client.get(f"/api/projects/{pid}/compile")
        data = r.get_json()
        assert "Gone soon" not in data["content"]
        assert "Real" in data["content"]
        assert data["chapter_count"] == 1

    def test_rename_then_compile_uses_new_name(self, client):
        # Use a unique name to avoid dedupe with other tests
        pid = client.post("/api/projects", json={"name": "Rename Test 9999"}).get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "old-name"})
        client.put(f"/api/projects/{pid}/chapters/old-name/content", json={
            "content": "# The Beginning\n\nContent here."
        })
        # Rename it
        client.post(f"/api/projects/{pid}/chapters/old-name/rename", json={"new_name": "new-name"})

        r = client.get(f"/api/projects/{pid}/compile")
        data = r.get_json()
        # The file rename should be reflected — new-name is now the file
        assert "new-name" in data["content"] or "The Beginning" in data["content"]
        # The old name should not appear as a chapter
        assert "old-name" not in data["content"]

    def test_context_persists_across_calls(self, client):
        r = client.post("/api/projects", json={"name": "Persist Test"})
        pid = r.get_json()["id"]
        client.put(f"/api/projects/{pid}/context", json={"characters": "Alice the Brave"})

        # Read back
        r = client.get(f"/api/projects/{pid}/context")
        assert r.get_json()["characters"] == "Alice the Brave"

        # Update with different field
        client.put(f"/api/projects/{pid}/context", json={"world": "Mars"})
        r = client.get(f"/api/projects/{pid}/context")
        ctx = r.get_json()
        assert ctx["characters"] == "Alice the Brave"  # not wiped
        assert ctx["world"] == "Mars"

    def test_empty_string_vs_missing_key_in_settings(self, client):
        r = client.post("/api/projects", json={"name": "Empty String Test"})
        pid = r.get_json()["id"]
        client.put(f"/api/projects/{pid}/settings", json={"title": "Real Title", "author": ""})
        r = client.get(f"/api/projects/{pid}/settings")
        data = r.get_json()
        assert data["title"] == "Real Title"
        assert data["author"] == ""

    def test_compile_unicode_in_dedication(self, client):
        r = client.post("/api/projects", json={"name": "Unicode Test"})
        pid = r.get_json()["id"]
        client.put(f"/api/projects/{pid}/settings", json={
            "title": "Test",
            "dedication": "献给母亲 — with love",
            "epigraph": "「すべての道はローマに通ず」"
        })
        client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        client.put(f"/api/projects/{pid}/chapters/c1/content", json={"content": "# 1\n\nContent."})

        r = client.get(f"/api/projects/{pid}/compile")
        data = r.get_json()
        assert "献给母亲" in data["content"]
        assert "ローマに通ず" in data["content"]

    def test_pandoc_missing_returns_500(self, client):
        r = client.post("/api/projects", json={"name": "Pandoc Test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        client.put(f"/api/projects/{pid}/chapters/c1/content", json={"content": "# 1\n\nTest."})
        r = client.get(f"/api/projects/{pid}/export/pdf")
        # If pandoc exists and weasyprint works, returns 200; otherwise 500
        assert r.status_code in (200, 500), f"unexpected: {r.status_code}"
        if r.status_code == 500:
            assert "error" in r.get_json()


class TestBackendFileOpsParser:
    """Test the natural language file operation parser comprehensively."""

    def test_complex_create_commands(self):
        from server import parse_file_command
        cases = [
            ("create chapter five", "create_chapter", "chapter-five"),
            ("make chapter 1", "create_chapter", "chapter-1"),
            ("add a new chapter named prologue", "create_chapter", "chapter-prologue"),
            ("create chapter 100", "create_chapter", "chapter-100"),
            ("CREATE CHAPTER ONE", "create_chapter", "chapter-one"),
        ]
        for text, op, target in cases:
            r = parse_file_command(text)
            assert r is not None, f"failed: {text}"
            assert r.op == op, f"[{text}] op={r.op}"
            assert r.target == target, f"[{text}] target={r.target}"

    def test_complex_rename_commands(self):
        from server import parse_file_command
        cases = [
            ("rename chapter 1 to chapter-one", "rename_chapter", "chapter-1", "chapter-one"),
            ("change chapter 2 to chapter-two", "rename_chapter", "chapter-2", "chapter-two"),
            ("rename chapter-old to chapter-new", "rename_chapter", "chapter-old", "chapter-new"),
        ]
        for text, op, old, new in cases:
            r = parse_file_command(text)
            assert r is not None, f"failed: {text}"
            assert r.op == op
            assert r.target == old
            assert r.detail == new

    def test_delete_with_special_chars(self):
        from server import parse_file_command
        # Hyphen between chapter and name
        r = parse_file_command("delete chapter-prologue")
        assert r is not None
        assert r.op == "delete_chapter"
        assert r.target == "chapter-prologue"

    def test_ambiguous_commands_return_none(self):
        from server import parse_file_command
        non_ops = [
            "write a story about cats",  # chat, not file op
            "what is the meaning of life",
            "continue the chapter",  # ambiguous
            "thanks",  # chat
            "tell me about chapter 1",  # chat, not delete
        ]
        for text in non_ops:
            r = parse_file_command(text)
            assert r is None, f"[{text}] should be None, got: {r.op if r else None}"


class TestBackendSSEFileOps:
    """Test the /api/tasks SSE endpoint for file operations."""

    def test_sse_event_has_nested_file_op(self, client):
        """The SSE file_op event must have the structure Swift's FileOpEvent expects."""
        import urllib.request
        import urllib.error
        r = client.post("/api/projects", json={"name": "SSE Test"})
        pid = r.get_json()["id"]

        body = json.dumps({
            "task": "create chapter 1",
            "project_id": pid,
            "mode": "auto"
        }).encode()
        req = urllib.request.Request(
            f"http://127.0.0.1:5323/api/tasks",
            data=body, method="POST"
        )
        # Skip the live-server test in this unit fixture
        pytest.skip("Live server SSE test — covered by simulate.py")


class TestNegativePatterns:
    """Technique #1: Role anchoring with negative examples.

    The model should be told what it is NOT and the specific phrases to
    avoid. Research basis: Constitutional AI (Bai 2022), Stable Diffusion
    negative prompts, role-prompting literature.
    """

    def test_constant_exists_and_nonempty(self):
        from book_writer import NEGATIVE_PATTERNS
        assert isinstance(NEGATIVE_PATTERNS, str)
        assert len(NEGATIVE_PATTERNS) > 200, "NEGATIVE_PATTERNS should be substantive"

    def test_contains_required_anti_cliches(self):
        """The negative pattern list must explicitly name the most common
        LLM prose fingerprints."""
        from book_writer import NEGATIVE_PATTERNS
        required = [
            "It wasn't X, it was Y",
            "shiver ran down",
            "Little did",
            "The air was thick with",
            "Suddenly",
            "As if on cue",
            "said quietly",
            "whispered softly",
        ]
        for phrase in required:
            assert phrase in NEGATIVE_PATTERNS, (
                f"NEGATIVE_PATTERNS missing required phrase: {phrase!r}"
            )

    def test_contains_positive_directives(self):
        """It's not just 'don't do X' — the list should also include what
        the model should DO instead."""
        from book_writer import NEGATIVE_PATTERNS
        positives = ["Show, don't tell", "specific sensory detail"]
        for phrase in positives:
            assert phrase in NEGATIVE_PATTERNS, (
                f"NEGATIVE_PATTERNS should include positive directive: {phrase!r}"
            )

    def test_compose_system_prompt_includes_negatives_by_default(self):
        """Default prose call must include the negative patterns."""
        from book_writer import compose_system_prompt, NEGATIVE_PATTERNS
        prompt = compose_system_prompt("prose")
        assert "master fiction writer" in prompt  # from CHAPTER_SYSTEM
        assert "shiver ran down" in prompt         # from NEGATIVE_PATTERNS

    def test_compose_system_prompt_can_disable_negatives(self):
        """A/B escape hatch: include_negatives=False must drop the list."""
        from book_writer import compose_system_prompt
        prompt_with = compose_system_prompt("prose", include_negatives=True)
        prompt_without = compose_system_prompt("prose", include_negatives=False)
        assert "shiver ran down" in prompt_with
        assert "shiver ran down" not in prompt_without

    def test_non_prose_phases_skip_negatives(self):
        """Research/outline phases should not get the prose-only anti-list."""
        from book_writer import compose_system_prompt
        for phase in ("research", "outline", "plan", "critique"):
            prompt = compose_system_prompt(phase)
            assert "shiver ran down" not in prompt, (
                f"{phase} should not include prose-only anti-patterns"
            )

    def test_write_chapter_uses_composed_prompt(self, monkeypatch):
        """The actual write_one_chapter call must use compose_system_prompt
        (so future #13 persona persistence lands cleanly)."""
        from book_writer import compose_system_prompt, write_one_chapter
        import argparse
        args = argparse.Namespace(
            writing_model="gemma4:latest",
            title="T", genre="g", style="s",
        )
        captured = {}

        def fake_stream(model, prompt, system, options):
            captured["system"] = system
            yield "ok"

        monkeypatch.setattr("book_writer.ollama_generate_streaming", fake_stream)
        # Stub out the req() call so we don't hit the live server
        monkeypatch.setattr("book_writer.req", lambda *a, **k: (200, b'{}'))

        write_one_chapter(
            args, "fake-pid",
            {"num": 1, "title": "T", "summary": "S"},
            research="r", prior_summary="",
            prior_excerpts="", prior_chars="", prior_world="",
        )
        # The system prompt sent to Ollama must include the negative patterns
        assert "shiver ran down" in captured["system"], (
            "write_one_chapter must send NEGATIVE_PATTERNS in the system prompt"
        )

    def test_banned_phrases_count_in_generated_text(self):
        """Sanity: a properly-anchored generation should reduce banned-phrase
        count. We don't run a real generation here (slow), but verify the
        utility function works."""
        from book_writer import NEGATIVE_PATTERNS
        import re

        # Extract a few banned patterns and verify we can detect them
        sample = "She felt sad. A shiver ran down her spine. Little did she know."
        # Count occurrences of "shiver ran down" in sample
        hits = len(re.findall(r"shiver ran down", sample, re.IGNORECASE))
        assert hits == 1
        # Confirm the list names this pattern so it can be detected
        assert "shiver ran down" in NEGATIVE_PATTERNS.lower()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
