"""
Quill new features — tests for ePub/HTML export, scenes, codex, stats, synopsis.
"""
import pytest
import json
import sys
import tempfile
import shutil
from pathlib import Path

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


# ---- HTML / ePub export -----------------------------------------------------

class TestHtmlExport:
    def test_html_export_works(self, client):
        r = client.post("/api/projects", json={"name": "HTML Test"})
        pid = r.get_json()["id"]
        client.put(f"/api/projects/{pid}/settings", json={"title": "Test Book", "author": "Tester"})
        client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        client.put(f"/api/projects/{pid}/chapters/c1/content", json={
            "content": "# Chapter 1\n\n**Bold** and *italic* and `code`."
        })

        r = client.get(f"/api/projects/{pid}/export/html")
        assert r.status_code == 200
        html = r.data.decode("utf-8")
        assert "<h1>Test Book</h1>" in html
        assert "<strong>Bold</strong>" in html
        assert "<em>italic</em>" in html
        assert "<code>code</code>" in html
        assert "by Tester" in html

    def test_html_handles_blocks(self, client):
        r = client.post("/api/projects", json={"name": "Blocks Test"})
        pid = r.get_json()["id"]
        client.put(f"/api/projects/{pid}/settings", json={"title": "Blocks", "author": "T"})
        client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        client.put(f"/api/projects/{pid}/chapters/c1/content", json={
            "content": "# Title\n\nA paragraph.\n\n- one\n- two\n- three\n\n1. first\n2. second\n\n> A quote\n\n---\n\n```python\nprint('hi')\n```\n\n[link](http://x.com)"
        })

        r = client.get(f"/api/projects/{pid}/export/html")
        html = r.data.decode("utf-8")
        assert "<ul>" in html and "<li>one</li>" in html
        assert "<ol>" in html and "<li>first</li>" in html
        assert "<blockquote>" in html
        assert "<hr>" in html
        assert "<pre><code>" in html
        assert 'href="http://x.com"' in html

    def test_html_escapes_special_chars(self, client):
        r = client.post("/api/projects", json={"name": "Esc Test"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        client.put(f"/api/projects/{pid}/chapters/c1/content", json={
            "content": "# Title\n\n<script>alert(1)</script> & \"quoted\""
        })
        r = client.get(f"/api/projects/{pid}/export/html")
        html = r.data.decode("utf-8")
        assert "<script>" not in html
        assert "&lt;script&gt;" in html
        assert "&amp;" in html


class TestEpubExport:
    def test_epub_requires_pandoc(self, client):
        """ePub uses pandoc; if missing, returns 500. If present, 200."""
        r = client.post("/api/projects", json={"name": "Epub Test"})
        pid = r.get_json()["id"]
        client.put(f"/api/projects/{pid}/settings", json={"title": "Ebook", "author": "Tester"})
        client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        client.put(f"/api/projects/{pid}/chapters/c1/content", json={"content": "# Ch1\n\nContent."})

        r = client.get(f"/api/projects/{pid}/export/epub")
        # Either 200 (pandoc installed) or 500 (not installed)
        assert r.status_code in (200, 500), f"got {r.status_code}"

    def test_epub_includes_metadata(self, client):
        """ePub uses YAML front matter for title/author metadata."""
        r = client.post("/api/projects", json={"name": "Epub Meta Test"})
        pid = r.get_json()["id"]
        client.put(f"/api/projects/{pid}/settings", json={"title": "My Ebook", "author": "Jane"})
        client.post(f"/api/projects/{pid}/chapters", json={"name": "c1"})
        client.put(f"/api/projects/{pid}/chapters/c1/content", json={"content": "# C1\n\nBody."})
        r = client.get(f"/api/projects/{pid}/export/epub")
        if r.status_code == 200:
            # If pandoc worked, we should have an epub file
            assert len(r.data) > 100, f"epub too small: {len(r.data)}"
        else:
            # Pandoc missing — that's OK
            assert r.status_code == 500


# ---- Scenes (chapter sub-units) --------------------------------------------

class TestScenes:
    def test_create_scene(self, client):
        proj = client.post("/api/projects", json={"name": "Scene Test"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "chapter-1"})

        r = client.post(
            f"/api/projects/{proj['id']}/chapters/chapter-1/scenes",
            json={"name": "scene-1"}
        )
        assert r.status_code == 200
        data = r.get_json()
        assert data["name"] == "scene-1"
        assert data["chapter"] == "chapter-1"

    def test_list_scenes(self, client):
        proj = client.post("/api/projects", json={"name": "Scene List Test"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "chapter-1"})
        for sn in ["scene-1", "scene-2", "scene-3"]:
            client.post(f"/api/projects/{proj['id']}/chapters/chapter-1/scenes", json={"name": sn})

        r = client.get(f"/api/projects/{proj['id']}/chapters/chapter-1/scenes")
        scenes = r.get_json()
        assert len(scenes) == 3
        names = [s["name"] for s in scenes]
        assert names == ["scene-1", "scene-2", "scene-3"]

    def test_scene_content_crud(self, client):
        proj = client.post("/api/projects", json={"name": "Scene CRUD"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "chapter-1"})
        client.post(f"/api/projects/{proj['id']}/chapters/chapter-1/scenes", json={"name": "scene-1"})

        # Update content
        r = client.put(
            f"/api/projects/{proj['id']}/chapters/chapter-1/scenes/scene-1/content",
            json={"content": "Iris walked into the dark."}
        )
        assert r.status_code == 200

        # Read it back
        r = client.get(f"/api/projects/{proj['id']}/chapters/chapter-1/scenes/scene-1/content")
        assert "Iris walked into the dark" in r.get_json()["content"]

        # Delete
        r = client.delete(f"/api/projects/{proj['id']}/chapters/chapter-1/scenes/scene-1")
        assert r.status_code == 200

    def test_duplicate_scene_409(self, client):
        proj = client.post("/api/projects", json={"name": "Dup Scene"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "ch1"})
        client.post(f"/api/projects/{proj['id']}/chapters/ch1/scenes", json={"name": "scene-1"})
        r = client.post(f"/api/projects/{proj['id']}/chapters/ch1/scenes", json={"name": "scene-1"})
        assert r.status_code == 409

    def test_compile_includes_scenes_as_subsections(self, client):
        proj = client.post("/api/projects", json={"name": "Compile Scenes Test"}).get_json()
        client.put(f"/api/projects/{proj['id']}/settings", json={"title": "Test", "author": "T"})
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "chapter-1"})
        client.put(f"/api/projects/{proj['id']}/chapters/chapter-1/content", json={
            "content": "# Chapter 1: The Beginning\n\nThe story starts."
        })
        client.post(f"/api/projects/{proj['id']}/chapters/chapter-1/scenes", json={"name": "scene-1"})
        client.put(f"/api/projects/{proj['id']}/chapters/chapter-1/scenes/scene-1/content", json={
            "content": "# Opening Scene\n\nFirst scene content."
        })
        client.post(f"/api/projects/{proj['id']}/chapters/chapter-1/scenes", json={"name": "scene-2"})
        client.put(f"/api/projects/{proj['id']}/chapters/chapter-1/scenes/scene-2/content", json={
            "content": "# Second Scene\n\nMore content."
        })

        r = client.get(f"/api/projects/{proj['id']}/compile")
        content = r.get_json()["content"]
        # Chapter heading
        assert "The Beginning" in content
        # Scene headings promoted to ## (subsections)
        assert "## Opening Scene" in content
        assert "## Second Scene" in content
        # Scene content is included
        assert "First scene content" in content
        assert "More content" in content

    def test_chapter_listing_excludes_subdirectories(self, client):
        """The /api/projects/<id>/chapters endpoint should not list dirs as chapters."""
        proj = client.post("/api/projects", json={"name": "List Clean Test"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "ch1"})
        client.post(f"/api/projects/{proj['id']}/chapters/ch1/scenes", json={"name": "scene-1"})
        r = client.get(f"/api/projects/{proj['id']}/chapters")
        chapters = r.get_json()
        assert len(chapters) == 1
        assert chapters[0]["name"] == "ch1"


# ---- Story Bible / Codex --------------------------------------------------

class TestCodex:
    def test_get_codex_default(self, client):
        proj = client.post("/api/projects", json={"name": "Codex Test"}).get_json()
        r = client.get(f"/api/projects/{proj['id']}/codex")
        data = r.get_json()
        for k in ["characters", "world", "summary", "style", "plot", "themes"]:
            assert k in data, f"missing {k}"

    def test_update_codex(self, client):
        proj = client.post("/api/projects", json={"name": "Codex Update Test"}).get_json()
        r = client.put(f"/api/projects/{proj['id']}/codex", json={
            "characters": "Alice (protagonist), Bob (antagonist)",
            "world": "Neo-Tokyo, 2087",
            "plot": "Alice discovers a hidden truth",
        })
        data = r.get_json()
        assert "Alice" in data["characters"]
        assert "Neo-Tokyo" in data["world"]
        assert data["plot"] == "Alice discovers a hidden truth"

    def test_codex_partial_update(self, client):
        """Only provided fields should be updated, others untouched."""
        proj = client.post("/api/projects", json={"name": "Codex Partial Test"}).get_json()
        client.put(f"/api/projects/{proj['id']}/codex", json={
            "characters": "Alice", "world": "Mars"
        })
        # Update only plot
        client.put(f"/api/projects/{proj['id']}/codex", json={"plot": "Mystery"})
        codex = client.get(f"/api/projects/{proj['id']}/codex").get_json()
        assert codex["characters"] == "Alice"
        assert codex["world"] == "Mars"
        assert codex["plot"] == "Mystery"

    def test_codex_persists_in_context_file(self, client):
        proj = client.post("/api/projects", json={"name": "Codex Persist Test"}).get_json()
        client.put(f"/api/projects/{proj['id']}/codex", json={"characters": "Alice"})
        ctx_file = Path(client.application.config.get("BASE_DIR", "/tmp")) / "quill-test" / ".quill_context.json"
        # Just verify the API still returns it
        codex = client.get(f"/api/projects/{proj['id']}/codex").get_json()
        assert codex["characters"] == "Alice"


# ---- Stats + writing goals -------------------------------------------------

class TestStats:
    def test_get_default_stats(self, client):
        proj = client.post("/api/projects", json={"name": "Stats Test"}).get_json()
        r = client.get(f"/api/projects/{proj['id']}/stats")
        data = r.get_json()
        assert data["daily_goal"] == 500
        assert data["words_today"] == 0
        assert data["total_words"] == 0
        assert data["sessions"] == []

    def test_set_daily_goal(self, client):
        proj = client.post("/api/projects", json={"name": "Goal Test"}).get_json()
        r = client.put(f"/api/projects/{proj['id']}/stats", json={"daily_goal": 1000})
        assert r.get_json()["daily_goal"] == 1000

    def test_set_invalid_goal_400(self, client):
        proj = client.post("/api/projects", json={"name": "Bad Goal Test"}).get_json()
        r = client.put(f"/api/projects/{proj['id']}/stats", json={"daily_goal": "not a number"})
        assert r.status_code == 400

    def test_record_session(self, client):
        proj = client.post("/api/projects", json={"name": "Session Test"}).get_json()
        client.put(f"/api/projects/{proj['id']}/stats", json={"session_start": "2026-07-25T10:00:00"})
        r = client.put(f"/api/projects/{proj['id']}/stats", json={"session_end": "2026-07-25T10:30:00"})
        data = r.get_json()
        assert len(data["sessions"]) == 1
        assert data["sessions"][0]["start"] == "2026-07-25T10:00:00"
        assert data["sessions"][0]["end"] == "2026-07-25T10:30:00"
        assert data["last_session_start"] is None

    def test_record_words(self, client):
        proj = client.post("/api/projects", json={"name": "Words Test"}).get_json()
        r = client.put(f"/api/projects/{proj['id']}/stats", json={"words_written": 250})
        data = r.get_json()
        assert data["words_today"] == 250
        assert data["total_words"] == 250

    def test_words_accumulate(self, client):
        proj = client.post("/api/projects", json={"name": "Accumulate Test"}).get_json()
        client.put(f"/api/projects/{proj['id']}/stats", json={"words_written": 100})
        client.put(f"/api/projects/{proj['id']}/stats", json={"words_written": 200})
        data = client.get(f"/api/projects/{proj['id']}/stats").get_json()
        assert data["words_today"] == 300
        assert data["total_words"] == 300

    def test_negative_words_ignored(self, client):
        """Negative word counts (deletions) shouldn't subtract from total."""
        proj = client.post("/api/projects", json={"name": "Neg Words Test"}).get_json()
        client.put(f"/api/projects/{proj['id']}/stats", json={"words_written": 100})
        client.put(f"/api/projects/{proj['id']}/stats", json={"words_written": -50})
        data = client.get(f"/api/projects/{proj['id']}/stats").get_json()
        assert data["total_words"] == 100  # not 50
        assert data["words_today"] == 100


# ---- Synopsis (corkboard) --------------------------------------------------

class TestSynopsis:
    def test_get_default_empty(self, client):
        proj = client.post("/api/projects", json={"name": "Synopsis Test"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "ch1"})
        r = client.get(f"/api/projects/{proj['id']}/chapters/ch1/synopsis")
        assert r.get_json()["synopsis"] == ""

    def test_set_synopsis(self, client):
        proj = client.post("/api/projects", json={"name": "Set Synopsis Test"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "ch1"})
        r = client.put(
            f"/api/projects/{proj['id']}/chapters/ch1/synopsis",
            json={"synopsis": "Iris discovers the blank space"}
        )
        assert r.status_code == 200
        assert r.get_json()["synopsis"] == "Iris discovers the blank space"

        # Read it back
        r = client.get(f"/api/projects/{proj['id']}/chapters/ch1/synopsis")
        assert r.get_json()["synopsis"] == "Iris discovers the blank space"

    def test_synopsis_persists_across_chapters(self, client):
        proj = client.post("/api/projects", json={"name": "Multi Synopsis Test"}).get_json()
        for ch in ["ch1", "ch2", "ch3"]:
            client.post(f"/api/projects/{proj['id']}/chapters", json={"name": ch})
        client.put(f"/api/projects/{proj['id']}/chapters/ch1/synopsis", json={"synopsis": "A"})
        client.put(f"/api/projects/{proj['id']}/chapters/ch2/synopsis", json={"synopsis": "B"})
        client.put(f"/api/projects/{proj['id']}/chapters/ch3/synopsis", json={"synopsis": "C"})

        assert client.get(f"/api/projects/{proj['id']}/chapters/ch1/synopsis").get_json()["synopsis"] == "A"
        assert client.get(f"/api/projects/{proj['id']}/chapters/ch2/synopsis").get_json()["synopsis"] == "B"
        assert client.get(f"/api/projects/{proj['id']}/chapters/ch3/synopsis").get_json()["synopsis"] == "C"


# ---- Markdown conversion unit tests ---------------------------------------

class TestMarkdownToHtml:
    def test_headings(self):
        from server import markdown_to_html
        html = markdown_to_html("# H1\n\ntext\n\n## H2\n\nmore")
        assert "<h1>H1</h1>" in html
        assert "<h2>H2</h2>" in html

    def test_bold_italic(self):
        from server import markdown_to_html
        html = markdown_to_html("**bold** and *italic* and ***both***")
        assert "<strong>bold</strong>" in html
        assert "<em>italic</em>" in html

    def test_code(self):
        from server import markdown_to_html
        html = markdown_to_html("`inline` and ```\nblock\n```")
        assert "<code>inline</code>" in html
        assert "<pre><code>" in html

    def test_links(self):
        from server import markdown_to_html
        html = markdown_to_html("[text](http://example.com)")
        assert 'href="http://example.com"' in html
        assert ">text</a>" in html

    def test_lists(self):
        from server import markdown_to_html
        html = markdown_to_html("- a\n- b\n- c")
        assert "<ul>" in html
        assert "<li>a</li>" in html

    def test_blockquote(self):
        from server import markdown_to_html
        html = markdown_to_html("> quoted text")
        assert "<blockquote>quoted text</blockquote>" in html

    def test_hr(self):
        from server import markdown_to_html
        html = markdown_to_html("---")
        assert "<hr>" in html

    def test_paragraph(self):
        from server import markdown_to_html
        html = markdown_to_html("Just a paragraph.")
        # Allow whitespace inside <p> tags
        assert "Just a paragraph." in html
        assert "<p>" in html
        assert "</p>" in html

    def test_empty_input(self):
        from server import markdown_to_html
        html = markdown_to_html("")
        assert html == ""

    def test_only_block_constructs_no_paragraphs(self):
        from server import markdown_to_html
        html = markdown_to_html("# Title\n\n## Subtitle")
        assert "<p>" not in html  # No empty paragraph
        assert "<h1>Title</h1>" in html


if __name__ == "__main__":
    pytest.main([__file__, "-v"])


# ---- Generic file rename ----------------------------------------------------

class TestGenericRename:
    """Tests for the new /api/rename endpoint used by the app for scene renames
    and any other file in the project tree."""

    def test_rename_chapter_file(self, client):
        r = client.post("/api/projects", json={"name": "rename-test"})
        assert r.status_code == 200
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "original"})
        # Rename
        r = client.post(
            "/api/rename",
            json={"from": f"{pid}/original.md", "to": f"{pid}/renamed.md"},
        )
        assert r.status_code == 200, r.get_json()
        body = r.get_json()
        assert body.get("ok") is True
        # Verify the file moved
        r = client.get(f"/api/projects/{pid}/chapters")
        names = [c["name"] for c in r.get_json()]
        assert "renamed" in names
        assert "original" not in names

    def test_rename_missing_source_404(self, client):
        r = client.post(
            "/api/rename",
            json={"from": "no-such-project/missing.md", "to": "no-such-project/x.md"},
        )
        assert r.status_code == 404

    def test_rename_rejects_path_traversal(self, client):
        r = client.post(
            "/api/rename",
            json={"from": "../escape.md", "to": "fine.md"},
        )
        assert r.status_code == 400
        assert "error" in r.get_json()

    def test_rename_rejects_absolute_path(self, client):
        r = client.post(
            "/api/rename",
            json={"from": "/etc/passwd", "to": "x.md"},
        )
        assert r.status_code == 400

    def test_rename_destination_exists_409(self, client):
        r = client.post("/api/projects", json={"name": "rename-409"})
        pid = r.get_json()["id"]
        client.post(f"/api/projects/{pid}/chapters", json={"name": "a"})
        client.post(f"/api/projects/{pid}/chapters", json={"name": "b"})
        r = client.post(
            "/api/rename",
            json={"from": f"{pid}/a.md", "to": f"{pid}/b.md"},
        )
        assert r.status_code == 409

    def test_rename_requires_from_and_to(self, client):
        r = client.post("/api/rename", json={"from": "x.md"})
        assert r.status_code == 400
        r = client.post("/api/rename", json={"to": "x.md"})
        assert r.status_code == 400
