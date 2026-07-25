#!/usr/bin/env python3
"""Quill Backend — Flask server."""
import os, re, json, subprocess
from pathlib import Path
from datetime import datetime
from flask import Flask, request, Response, send_file as flask_send_file
from flask_cors import CORS

try:
    import ollama
except ImportError:
    ollama = None

BASE_DIR = Path.home() / "Quill" / "projects"
PORT = 5323
MODEL = "gemma4:latest"

app = Flask(__name__)
CORS(app)


def send_file(path, mimetype, as_attachment, download_name):
    return flask_send_file(path, mimetype=mimetype, as_attachment=as_attachment, download_name=download_name)


def ensure_base_dir():
    BASE_DIR.mkdir(parents=True, exist_ok=True)


def get_project_dir(project_id):
    p = BASE_DIR / project_id
    p.mkdir(parents=True, exist_ok=True)
    return p


def list_markdown_files(project_id):
    project_dir = get_project_dir(project_id)
    files = sorted(project_dir.glob("*.md"))
    return [
        {"name": f.stem, "path": str(f), "modified": os.path.getmtime(f), "size": os.path.getsize(f)}
        for f in files
    ]


def get_project_context(project_id):
    ctx_file = get_project_dir(project_id) / ".quill_context.json"
    if ctx_file.exists():
        return json.loads(ctx_file.read_text(encoding="utf-8"))
    return {"characters": "", "world": "", "summary": "",
            "style": "literary, vivid, atmospheric prose in the style of a published novelist"}


def save_project_context(project_id, ctx):
    ctx_file = get_project_dir(project_id) / ".quill_context.json"
    ctx_file.write_text(json.dumps(ctx, indent=2), encoding="utf-8")


def read_chapter(project_id, chapter_name):
    name = chapter_name.replace(".md", "")
    fp = get_project_dir(project_id) / f"{name}.md"
    if fp.exists():
        return fp.read_text(encoding="utf-8")
    return None


def safe_json() -> dict:
    """request.json with safety: returns {} if body is null, not a dict, or missing."""
    data = request.json
    if not isinstance(data, dict):
        return {}
    return data


def write_chapter(project_id, chapter_name, content):
    name = chapter_name.replace(".md", "")
    fp = get_project_dir(project_id) / f"{name}.md"
    fp.write_text(content, encoding="utf-8")


class FileOpResult:
    def __init__(self, op, target, detail="", success=True, error=""):
        self.op = op
        self.target = target
        self.detail = detail
        self.success = success
        self.error = error

    def to_json(self):
        return {
            "file_op": {
                "op": self.op,
                "target": self.target,
                "detail": self.detail,
                "success": self.success,
                "error": self.error,
            }
        }


def parse_file_command(text):
    t = text.strip()

    def normalize(name):
        name = name.strip().lower().replace(".md", "").replace("_", "-")
        for pf in ["chapter-", "chapter "]:
            if name.startswith(pf):
                name = name[len(pf):]
                break
        if re.match(r"^\d[\d\-]*$", name) and not name.startswith("chapter"):
            name = f"chapter-{name}"
        elif name and not name.startswith("chapter-"):
            name = f"chapter-{name}"
        return name

    m = re.match(r"(?:create|make|add)\s+(?:a\s+)?(?:new\s+)?chapter[\s\-]+(?:named\s+)?(?:called\s+)?(.+)", t, re.IGNORECASE)
    if m:
        name = normalize(m.group(1).strip())
        if name:
            return FileOpResult(op="create_chapter", target=name)

    m = re.match(r"(?:rename|change)\s+chapter[\s\-]+(.+?)[\s]+(?:to|into)[\s]+(.+)", t, re.IGNORECASE)
    if m:
        old = normalize(m.group(1))
        new = normalize(m.group(2))
        return FileOpResult(op="rename_chapter", target=old, detail=new)

    m = re.match(r"(?:delete|remove)\s+chapter[\s\-]+(.+)", t, re.IGNORECASE)
    if m:
        name = normalize(m.group(1))
        return FileOpResult(op="delete_chapter", target=name)

    m = re.match(r"(?:write|populate|save|fill)\s+(?:to\s+)?(?:in\s+)?(?:the\s+)?chapter[\s\-]+(.+?)\s*$", t, re.IGNORECASE)
    if m:
        name = normalize(m.group(1))
        return FileOpResult(op="write_to_chapter", target=name)

    return None


def execute_file_op(project_id, op_result):
    project_dir = get_project_dir(project_id)

    if op_result.op == "create_chapter":
        name = op_result.target
        filepath = project_dir / f"{name}.md"
        if filepath.exists():
            op_result.success = False
            op_result.error = f"Chapter '{name}' already exists"
        else:
            content = f"# {name.replace('-', ' ').title()}\n\n"
            filepath.write_text(content, encoding="utf-8")
            op_result.success = True
            op_result.detail = str(filepath)
    elif op_result.op == "rename_chapter":
        old = op_result.target
        new = op_result.detail
        old_path = project_dir / f"{old}.md"
        new_path = project_dir / f"{new}.md"
        if not old_path.exists():
            op_result.success = False
            op_result.error = f"Chapter '{old}' not found"
        elif new_path.exists():
            op_result.success = False
            op_result.error = f"Chapter '{new}' already exists"
        else:
            old_path.rename(new_path)
            op_result.success = True
            op_result.detail = f"{old}.md → {new}.md"
    elif op_result.op == "delete_chapter":
        name = op_result.target
        fp = project_dir / f"{name}.md"
        if not fp.exists():
            op_result.success = False
            op_result.error = f"Chapter '{name}' not found"
        else:
            fp.unlink()
            op_result.success = True
            op_result.detail = f"Deleted {name}.md"

    return op_result


def file_op_to_sse_message(op_result):
    return f"data: {json.dumps(op_result.to_json())}\n\n"


# ---- Routes ----

@app.route("/api/health", methods=["GET"])
def health():
    return {"backend": "ok", "ollama": "unknown", "model": MODEL}


@app.route("/api/projects", methods=["GET"])
def get_projects():
    ensure_base_dir()
    projects = []
    for d in sorted(BASE_DIR.iterdir()):
        if d.is_dir() and not d.name.startswith("."):
            chapters = list_markdown_files(d.name)
            projects.append({
                "id": d.name, "name": d.name.replace("-", " ").replace("_", " ").title(),
                "path": str(d), "chapter_count": len(chapters),
            })
    return projects


@app.route("/api/projects", methods=["POST"])
def create_project():
    data = safe_json()
    name = (data.get("name") or "Untitled").strip() or "Untitled"
    project_id = re.sub(r"[^a-z0-9\-_]", "-", name.lower()).strip("-")
    if not project_id:
        project_id = "untitled"
    get_project_dir(project_id)
    ctx = {
        "characters": data.get("characters", ""),
        "world": data.get("world", ""),
        "summary": "",
        "style": data.get("style", "literary, vivid, atmospheric prose"),
    }
    save_project_context(project_id, ctx)
    return {"id": project_id, "name": name}


@app.route("/api/projects/<project_id>/chapters", methods=["GET"])
def get_chapters(project_id):
    return list_markdown_files(project_id)


@app.route("/api/projects/<project_id>/chapters", methods=["POST"])
def create_chapter(project_id):
    data = safe_json()
    name = (data.get("name") or "Untitled").strip().replace(" ", "-").replace(".md", "")
    if not name:
        name = "untitled"
    filepath = get_project_dir(project_id) / f"{name}.md"
    if filepath.exists():
        return {"error": "Chapter already exists"}, 409
    content = f"# {name.replace('-', ' ').title()}\n\n"
    filepath.write_text(content, encoding="utf-8")
    return {"name": name, "path": str(filepath)}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/content", methods=["GET"])
def get_chapter_content(project_id, chapter_name):
    name = chapter_name.replace(".md", "")
    content = read_chapter(project_id, name)
    if content is None:
        return {"error": "Not found"}, 404
    return {"name": name, "content": content, "path": str(get_project_dir(project_id) / f"{name}.md")}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/content", methods=["PUT"])
def save_chapter_content(project_id, chapter_name):
    data = safe_json()
    name = chapter_name.replace(".md", "")
    write_chapter(project_id, name, data.get("content", ""))
    return {"ok": True}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>", methods=["DELETE"])
def delete_chapter(project_id, chapter_name):
    name = chapter_name.replace(".md", "")
    fp = get_project_dir(project_id) / f"{name}.md"
    if fp.exists():
        fp.unlink()
    return {"ok": True}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/rename", methods=["POST"])
def rename_chapter(project_id, chapter_name):
    data = safe_json()
    old_name = chapter_name.replace(".md", "")
    new_name = (data.get("new_name") or old_name).strip().replace(" ", "-").replace(".md", "")
    if not new_name or new_name == old_name:
        return {"error": "new_name required and must differ from current name"}, 400
    project_dir = get_project_dir(project_id)
    old_path = project_dir / f"{old_name}.md"
    new_path = project_dir / f"{new_name}.md"
    if not old_path.exists():
        return {"error": f"Chapter '{old_name}' not found"}, 404
    if new_path.exists() and old_path != new_path:
        return {"error": f"Chapter '{new_name}' already exists"}, 409
    old_path.rename(new_path)
    return {"name": new_name, "path": str(new_path)}


@app.route("/api/projects/<project_id>/context", methods=["GET"])
def get_context(project_id):
    return get_project_context(project_id)


@app.route("/api/projects/<project_id>/context", methods=["PUT"])
def update_context(project_id):
    data = safe_json()
    ctx = get_project_context(project_id)
    for key in ["characters", "world", "summary", "style"]:
        if key in data:
            ctx[key] = data[key]
    save_project_context(project_id, ctx)
    return ctx


# ---- Compile & Export ----

def compile_book(project_id):
    project_dir = get_project_dir(project_id)
    ctx = get_project_context(project_id)
    title = ctx.get("title", project_id.replace("-", " ").title())
    author = ctx.get("author", "")
    genre = ctx.get("genre", "")
    style_notes = ctx.get("style", "")
    dedication = ctx.get("dedication", "")
    epigraph = ctx.get("epigraph", "")

    chapters = sorted(project_dir.glob("*.md"))
    chapters = [c for c in chapters if not c.stem.startswith(".")]

    body = []
    for ch in chapters:
        content = ch.read_text(encoding="utf-8")
        # Strip leading whitespace and split into lines
        lines = [l for l in content.splitlines() if l.strip()]
        # A "bare heading" file is one that's just a heading and nothing else
        # Skip only if there's no content beyond the heading
        non_heading_lines = [l for l in lines if not re.match(r"^#\s", l)]
        if len(non_heading_lines) == 0:
            # Empty chapter (just heading) — skip
            continue
        body.append(content)

    front_matter = f'---\ntitle: "{title}"\nauthor: "{author}"\ndate: "{datetime.now().strftime("%B %Y")}"\n---\n\n'
    if dedication:
        front_matter += f"\\raggedright*{{\\Large *{dedication}*}}\n\n"
    if epigraph:
        front_matter += f"\\raggedleft*{{\\smaller *{epigraph}*}}\n\n"
    front_matter += f"# {title}\n\n"
    if author:
        front_matter += f"*by {author}*\n\n"
    if genre:
        front_matter += f"*{genre}*\n\n"
    front_matter += "---\n\n"
    if style_notes:
        front_matter += f"*Style: {style_notes}*\n\n---\n\n"

    compiled = front_matter + "\n\n".join(body)
    return compiled, title, ctx


@app.route("/api/projects/<project_id>/compile", methods=["GET"])
def get_compile_preview(project_id):
    compiled, title, ctx = compile_book(project_id)
    return {
        "title": title,
        "content": compiled,
        "chapter_count": len([c for c in get_project_dir(project_id).glob("*.md") if not c.stem.startswith(".")]),
        "word_count": len(compiled.split()),
        "author": ctx.get("author", ""),
        "genre": ctx.get("genre", ""),
    }


@app.route("/api/projects/<project_id>/export/<format>", methods=["GET"])
def export_book(project_id, format):
    if format not in ["pdf", "docx", "md", "txt"]:
        return {"error": "Unknown format"}, 400

    compiled, title, _ = compile_book(project_id)
    project_dir = get_project_dir(project_id)
    safe_title = re.sub(r'[^\w\- ]', '', title).strip().replace(' ', '-')

    output_dir = project_dir / "exports"
    output_dir.mkdir(exist_ok=True)
    compiled_path = output_dir / f"{safe_title}-manuscript.md"
    compiled_path.write_text(compiled, encoding="utf-8")

    if format == "md":
        return send_file(str(compiled_path), mimetype="text/markdown",
                         as_attachment=True, download_name=f"{safe_title}.md")

    elif format == "txt":
        txt = re.sub(r'^#{1,6}\s+', '', compiled, flags=re.MULTILINE)
        txt = re.sub(r'\*\*(.+?)\*\*', r'\1', txt)
        txt = re.sub(r'\*(.+?)\*', r'\1', txt)
        txt = re.sub(r'\[(.+?)\]\(.+?\)', r'\1', txt)
        txt = re.sub(r'^[-*_]{3,}$', '', txt, flags=re.MULTILINE)
        txt = re.sub(r'^>\s*', '', txt, flags=re.MULTILINE)
        txt_path = output_dir / f"{safe_title}.txt"
        txt_path.write_text(txt, encoding="utf-8")
        return send_file(str(txt_path), mimetype="text/plain",
                         as_attachment=True, download_name=f"{safe_title}.txt")

    elif format == "docx":
        docx_path = output_dir / f"{safe_title}.docx"
        md_temp = output_dir / f"{safe_title}-temp.md"
        md_temp.write_bytes(compiled.encode("utf-8-sig"))
        try:
            result = subprocess.run(
                ["pandoc", str(md_temp), "-o", str(docx_path), "--reference-doc=/dev/null"],
                capture_output=True, text=True, timeout=120
            )
            md_temp.unlink()
            if result.returncode != 0:
                return {"error": f"Pandoc error: {result.stderr}"}, 500
        except subprocess.TimeoutExpired:
            return {"error": "Export timed out"}, 500
        except FileNotFoundError:
            return {"error": "Pandoc not found"}, 500
        return send_file(str(docx_path),
                         mimetype="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                         as_attachment=True, download_name=f"{safe_title}.docx")

    elif format == "pdf":
        return {"error": "PDF requires pandoc + weasyprint/wkhtmltopdf"}, 500


@app.route("/api/projects/<project_id>/settings", methods=["GET"])
def get_settings(project_id):
    ctx = get_project_context(project_id)
    return {
        "title": ctx.get("title", project_id.replace("-", " ").title()),
        "author": ctx.get("author", ""),
        "genre": ctx.get("genre", ""),
        "dedication": ctx.get("dedication", ""),
        "epigraph": ctx.get("epigraph", ""),
        "style": ctx.get("style", "literary, vivid, atmospheric prose"),
        "model": MODEL,
        "chapters_dir": str(get_project_dir(project_id)),
    }


@app.route("/api/projects/<project_id>/settings", methods=["PUT"])
def update_settings(project_id):
    data = safe_json()
    ctx = get_project_context(project_id)
    for key in ["title", "author", "genre", "dedication", "epigraph", "style"]:
        if key in data:
            ctx[key] = data[key]
    save_project_context(project_id, ctx)
    return ctx


@app.route("/api/tasks", methods=["POST"])
def run_task():
    data = safe_json()
    project_id = data.get("project_id", "default")
    user_input = data.get("task", "")

    def generate():
        file_op = parse_file_command(user_input)
        if file_op:
            executed = execute_file_op(project_id, file_op)
            yield file_op_to_sse_message(executed)
        yield f"data: {json.dumps({'done': True})}\n\n"

    return Response(generate(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache"})


if __name__ == "__main__":
    ensure_base_dir()
    print(f"[Quill Backend] Starting on http://localhost:{PORT}")
    app.run(host="127.0.0.1", port=PORT, debug=False, threaded=True)
