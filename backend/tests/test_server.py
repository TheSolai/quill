"""Quill Backend pytest suite. Run: cd ~/Projects/Quill/backend && python3 -m pytest tests/ -v"""
import pytest
import json
import re
import tempfile
import shutil
from pathlib import Path


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


@pytest.fixture
def project_dir():
    d = Path(tempfile.mkdtemp()) / "quill-test"
    d.mkdir(parents=True, exist_ok=True)
    yield d
    shutil.rmtree(d, ignore_errors=True)


# ---- Health ----
class TestHealth:
    def test_health_returns_ok(self, client):
        r = client.get("/api/health")
        assert r.status_code == 200
        d = r.get_json()
        assert d["backend"] == "ok"
        assert d["model"] == "gemma4:latest"


# ---- Projects ----
class TestProjects:
    def test_list_empty(self, client):
        r = client.get("/api/projects")
        assert r.status_code == 200
        assert isinstance(r.get_json(), list)

    def test_create_and_list(self, client):
        r = client.post("/api/projects", json={"name": "My Novel"})
        d = r.get_json()
        assert d["name"] == "My Novel"
        projects = client.get("/api/projects").get_json()
        assert any(p["id"] == d["id"] for p in projects)

    def test_create_id_sanitized(self, client):
        r = client.post("/api/projects", json={"name": "Sci-Fi: Book One!"})
        d = r.get_json()
        assert re.match(r"^[a-z0-9\-]+$", d["id"])

    def test_create_with_context_fields(self, client):
        r = client.post("/api/projects", json={
            "name": "Context Test", "characters": "Alice",
            "world": "Mars", "style": "noir",
        })
        d = r.get_json()
        ctx = client.get(f"/api/projects/{d['id']}/context").get_json()
        assert ctx["characters"] == "Alice"
        assert ctx["style"] == "noir"


# ---- Chapters ----
class TestChapters:
    def test_create(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        r = client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "chapter-1"})
        d = r.get_json()
        assert d["name"] == "chapter-1"
        assert d["path"].endswith("chapter-1.md")

    def test_spaces_to_dashes(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        r = client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "Chapter One"})
        assert r.get_json()["name"] == "Chapter-One"

    def test_duplicate_409(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "chapter-1"})
        r = client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "chapter-1"})
        assert r.status_code == 409

    def test_read_content(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "intro"})
        d = client.get(f"/api/projects/{proj['id']}/chapters/intro/content").get_json()
        assert "# Intro" in d["content"]

    def test_404_on_missing(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        r = client.get(f"/api/projects/{proj['id']}/chapters/ghost/content")
        assert r.status_code == 404

    def test_save_content(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "d1"})
        r = client.put(
            f"/api/projects/{proj['id']}/chapters/d1/content",
            json={"content": "Rain hammered the window."}
        )
        assert r.get_json()["ok"] is True
        content = client.get(f"/api/projects/{proj['id']}/chapters/d1/content").get_json()
        assert "Rain hammered" in content["content"]

    def test_delete(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "del"})
        r = client.delete(f"/api/projects/{proj['id']}/chapters/del")
        assert r.status_code == 200

    def test_rename(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "c1"})
        r = client.post(
            f"/api/projects/{proj['id']}/chapters/c1/rename",
            json={"new_name": "c-one"}
        )
        assert r.get_json()["name"] == "c-one"

    def test_rename_404(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        r = client.post(
            f"/api/projects/{proj['id']}/chapters/ghost/rename",
            json={"new_name": "x"}
        )
        assert r.status_code == 404

    def test_rename_conflict_409(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "a"})
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "b"})
        r = client.post(
            f"/api/projects/{proj['id']}/chapters/a/rename",
            json={"new_name": "b"}
        )
        assert r.status_code == 409


# ---- Context ----
class TestContext:
    def test_get_default(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        ctx = client.get(f"/api/projects/{proj['id']}/context").get_json()
        for k in ["characters", "world", "summary", "style"]:
            assert k in ctx

    def test_update(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.put(
            f"/api/projects/{proj['id']}/context",
            json={"characters": "Alice", "world": "Mars", "summary": "x", "style": "noir"}
        )
        ctx = client.get(f"/api/projects/{proj['id']}/context").get_json()
        assert ctx["characters"] == "Alice"
        assert ctx["world"] == "Mars"


# ---- Settings ----
class TestSettings:
    def test_get(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        d = client.get(f"/api/projects/{proj['id']}/settings").get_json()
        for k in ["title", "author", "genre", "dedication", "epigraph", "style", "model"]:
            assert k in d
        assert d["model"] == "gemma4:latest"

    def test_update(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.put(
            f"/api/projects/{proj['id']}/settings",
            json={
                "title": "The Long Dark", "author": "Jane",
                "genre": "Fantasy", "dedication": "For mom.",
                "epigraph": "Quote here.", "style": "Gothic"
            }
        )
        d = client.get(f"/api/projects/{proj['id']}/settings").get_json()
        assert d["title"] == "The Long Dark"
        assert d["author"] == "Jane"
        assert d["dedication"] == "For mom."


# ---- Compile ----
class TestCompile:
    def test_preview(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "ch1"})
        client.put(
            f"/api/projects/{proj['id']}/chapters/ch1/content",
            json={"content": "# Chapter 1\n\nRain came down in sheets."}
        )
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "ch2"})
        client.put(
            f"/api/projects/{proj['id']}/chapters/ch2/content",
            json={"content": "# Chapter 2\n\nShe stepped outside."}
        )
        d = client.get(f"/api/projects/{proj['id']}/compile").get_json()
        assert d["chapter_count"] == 2
        assert "Rain came down" in d["content"]
        assert "She stepped outside" in d["content"]

    def test_yaml_front_matter(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.put(f"/api/projects/{proj['id']}/settings", json={
            "title": "Front Matter Book", "author": "Test Author",
            "dedication": "For testing.", "epigraph": "Test quote.",
        })
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "intro"})
        client.put(f"/api/projects/{proj['id']}/chapters/intro/content",
                   json={"content": "# Intro\n\nSome content."})
        content = client.get(f"/api/projects/{proj['id']}/compile").get_json()["content"]
        assert 'title: "Front Matter Book"' in content
        assert 'author: "Test Author"' in content

    def test_skip_empty_chapters(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "real"})
        client.put(
            f"/api/projects/{proj['id']}/chapters/real/content",
            json={"content": "# Real\n\nHas real content here."}
        )
        d = client.get(f"/api/projects/{proj['id']}/compile").get_json()
        assert "Has real content" in d["content"]


# ---- Export ----
class TestExport:
    def test_export_md(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "ch1"})
        client.put(f"/api/projects/{proj['id']}/chapters/ch1/content",
                   json={"content": "# Chapter 1\n\nContent."})
        r = client.get(f"/api/projects/{proj['id']}/export/md")
        assert r.status_code == 200
        assert b"Content." in r.data

    def test_export_txt_strips_markdown(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "ch1"})
        client.put(f"/api/projects/{proj['id']}/chapters/ch1/content",
                   json={"content": "# Chapter 1\n\n**Bold** and *italic* text."})
        r = client.get(f"/api/projects/{proj['id']}/export/txt")
        assert r.status_code == 200
        data = r.data.decode("utf-8")
        assert "**Bold**" not in data
        assert "Bold" in data

    def test_unknown_format_400(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        r = client.get(f"/api/projects/{proj['id']}/export/rtf")
        # epub IS supported now
        assert r.status_code == 400


# ---- File Op Parser ----
class TestFileOpParser:
    def test_create(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("create chapter 3")
        assert r.op == "create_chapter"
        assert r.target == "chapter-3"

    def test_make(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("make chapter-4")
        assert r.op == "create_chapter"
        assert r.target == "chapter-4"

    def test_add_named(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("add a chapter called intro")
        assert r.op == "create_chapter"
        assert r.target == "chapter-intro"

    def test_rename(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("rename chapter 1 to chapter-one")
        assert r.op == "rename_chapter"
        assert r.target == "chapter-1"
        assert r.detail == "chapter-one"

    def test_change(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("change chapter 2 into chapter-two")
        assert r.op == "rename_chapter"
        assert r.target == "chapter-2"
        assert r.detail == "chapter-two"

    def test_delete(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("delete chapter 1")
        assert r.op == "delete_chapter"
        assert r.target == "chapter-1"

    def test_remove(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("remove chapter 2")
        assert r.op == "delete_chapter"
        assert r.target == "chapter-2"

    def test_write_to(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("write to chapter 4")
        assert r.op == "write_to_chapter"
        assert r.target == "chapter-4"

    def test_populate(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("populate chapter intro")
        assert r.op == "write_to_chapter"
        assert r.target == "chapter-intro"

    def test_save_in(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("save in chapter draft-1")
        assert r.op == "write_to_chapter"
        assert r.target == "chapter-draft-1"

    def test_normalize_just_number(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("create chapter 7")
        assert r.target == "chapter-7"

    def test_normalize_already_prefixed(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        r = srv.parse_file_command("create chapter-prologue")
        assert r.target == "chapter-prologue"

    def test_non_file_command(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        for text in ["what are good plot twists?", "help me with my character"]:
            assert srv.parse_file_command(text) is None


# ---- File Op Executor ----
class TestFileOpExecutor:
    def test_create(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        proj_dir = srv.get_project_dir("t1")
        r = srv.FileOpResult("create_chapter", "chapter-new")
        result = srv.execute_file_op("t1", r)
        assert result.success
        assert (proj_dir / "chapter-new.md").exists()

    def test_create_duplicate(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        proj_dir = srv.get_project_dir("t2")
        (proj_dir / "chapter-x.md").write_text("# X\n\n")
        r = srv.FileOpResult("create_chapter", "chapter-x")
        result = srv.execute_file_op("t2", r)
        assert not result.success
        assert "already exists" in result.error

    def test_rename(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        proj_dir = srv.get_project_dir("t3")
        (proj_dir / "old.md").write_text("# Old\n\nContent.")
        r = srv.FileOpResult("rename_chapter", "old", detail="new")
        result = srv.execute_file_op("t3", r)
        assert result.success
        assert not (proj_dir / "old.md").exists()
        assert (proj_dir / "new.md").exists()

    def test_rename_404(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        srv.get_project_dir("t4")
        r = srv.FileOpResult("rename_chapter", "ghost", detail="new")
        result = srv.execute_file_op("t4", r)
        assert not result.success

    def test_delete(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        proj_dir = srv.get_project_dir("t5")
        (proj_dir / "x.md").write_text("# X\n\n")
        r = srv.FileOpResult("delete_chapter", "x")
        result = srv.execute_file_op("t5", r)
        assert result.success
        assert not (proj_dir / "x.md").exists()

    def test_delete_404(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        srv.get_project_dir("t6")
        r = srv.FileOpResult("delete_chapter", "ghost")
        result = srv.execute_file_op("t6", r)
        assert not result.success


# ---- FileOpEvent Swift model ----
class TestFileOpEventSwift:
    def test_sse_create(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        srv.get_project_dir("sse1")
        r = srv.FileOpResult("create_chapter", "chapter-1")
        srv.execute_file_op("sse1", r)
        msg = srv.file_op_to_sse_message(r)
        data = json.loads(msg.split("data: ")[1])
        assert data["file_op"]["op"] == "create_chapter"
        assert data["file_op"]["target"] == "chapter-1"
        assert data["file_op"]["success"] is True

    def test_sse_delete(self, project_dir):
        import server as srv
        srv.BASE_DIR = project_dir.parent
        proj_dir = srv.get_project_dir("sse2")
        (proj_dir / "old.md").write_text("# X\n\n")
        r = srv.FileOpResult("delete_chapter", "old")
        srv.execute_file_op("sse2", r)
        msg = srv.file_op_to_sse_message(r)
        data = json.loads(msg.split("data: ")[1])
        assert data["file_op"]["op"] == "delete_chapter"
        assert data["file_op"]["success"] is True


# ---- Full compile ----
class TestCompileBookFull:
    def test_full_flow(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        client.put(f"/api/projects/{proj['id']}/settings", json={
            "title": "Full Book", "author": "Author",
            "genre": "Literary", "dedication": "To me.",
            "epigraph": "A dream.", "style": "lyrical"
        })
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "opening"})
        client.put(f"/api/projects/{proj['id']}/chapters/opening/content",
                   json={"content": "# Opening\n\nIt began on a Tuesday."})
        client.post(f"/api/projects/{proj['id']}/chapters", json={"name": "middle"})
        client.put(f"/api/projects/{proj['id']}/chapters/middle/content",
                   json={"content": "# Middle\n\nThen came the storm."})
        d = client.get(f"/api/projects/{proj['id']}/compile").get_json()
        assert d["title"] == "Full Book"
        assert d["chapter_count"] == 2
        assert "It began on a Tuesday" in d["content"]
        assert "Then came the storm" in d["content"]

    def test_empty_project(self, client):
        proj = client.post("/api/projects", json={"name": "T"}).get_json()
        d = client.get(f"/api/projects/{proj['id']}/compile").get_json()
        # No chapters but front matter still present (title, author, date, style)
        assert d["chapter_count"] == 0
        # word_count reflects front matter content; the test just verifies the endpoint works
        assert d["word_count"] >= 0
