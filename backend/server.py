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
    files = sorted(
        [f for f in project_dir.glob("*.md") if f.is_file()],
        key=lambda p: natural_sort_key(p.stem)
    )
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


def natural_sort_key(name: str):
    """Sort key that handles numbers naturally: chapter-2 before chapter-10."""
    parts = re.split(r"(\d+)", name)
    return [int(p) if p.isdigit() else p.lower() for p in parts]


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

    chapters = sorted(project_dir.glob("*.md"), key=lambda p: natural_sort_key(p.stem))
    chapters = [c for c in chapters if not c.stem.startswith(".")]

    body = []
    included = []
    for ch in chapters:
        # Skip chapter subdirectories at the top level — they contain scenes
        if ch.is_dir():
            continue
        content = ch.read_text(encoding="utf-8")
        # Strip leading whitespace and split into lines
        lines = [l for l in content.splitlines() if l.strip()]
        # A "bare heading" file is one that's just a heading and nothing else
        # Skip only if there's no content beyond the heading
        non_heading_lines = [l for l in lines if not re.match(r"^#\s", l)]
        if len(non_heading_lines) == 0:
            # Empty chapter (just heading) — skip
            continue

        # Append scenes (sub-chapter files in chapter-NN/) as H2 sub-sections
        chapter_name = ch.stem
        scene_dir = project_dir / chapter_name
        if scene_dir.is_dir():
            scenes = sorted(scene_dir.glob("scene-*.md"), key=lambda p: natural_sort_key(p.stem))
            for scene_path in scenes:
                scene_content = scene_path.read_text(encoding="utf-8")
                # Promote scene's # heading to ## (subsection of chapter)
                scene_lines = scene_content.split("\n", 1)
                if scene_lines and scene_lines[0].startswith("# "):
                    scene_title = scene_lines[0][2:].strip()
                    rest = scene_lines[1] if len(scene_lines) > 1 else ""
                    content += f"\n\n## {scene_title}\n{rest}"
                else:
                    content += f"\n\n{scene_content}"

        body.append(content)
        included.append(ch)

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
    return compiled, title, ctx, len(included)


@app.route("/api/projects/<project_id>/compile", methods=["GET"])
def get_compile_preview(project_id):
    compiled, title, ctx, chapter_count = compile_book(project_id)
    return {
        "title": title,
        "content": compiled,
        "chapter_count": chapter_count,
        "word_count": len(compiled.split()),
        "author": ctx.get("author", ""),
        "genre": ctx.get("genre", ""),
    }


@app.route("/api/projects/<project_id>/export/<format>", methods=["GET"])
def export_book(project_id, format):
    if format not in ["pdf", "docx", "md", "txt", "html", "epub"]:
        return {"error": f"Unknown format. Use: pdf, docx, md, txt, html, epub"}, 400

    compiled, title, ctx, _ = compile_book(project_id)
    project_dir = get_project_dir(project_id)
    safe_title = re.sub(r'[^\w\- ]', '', title).strip().replace(' ', '-')
    author = ctx.get("author", "")

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

    elif format == "html":
        # Convert markdown → HTML using a built-in minimal converter
        # (we don't depend on pandoc for HTML; keep the conversion in-process)
        html_body = markdown_to_html(compiled)
        html_doc = build_html_document(title, author, html_body, ctx)
        html_path = output_dir / f"{safe_title}.html"
        html_path.write_text(html_doc, encoding="utf-8")
        return send_file(str(html_path), mimetype="text/html",
                         as_attachment=True, download_name=f"{safe_title}.html")

    elif format == "epub":
        # ePub via pandoc (industry standard)
        epub_path = output_dir / f"{safe_title}.epub"
        md_temp = output_dir / f"{safe_title}-temp.md"
        # Pandoc needs a proper title in the metadata
        md_with_meta = (
            f"---\n"
            f"title: {json.dumps(title)}\n"
            f"author: {json.dumps(author)}\n"
            f"---\n\n"
            + compiled
        )
        md_temp.write_text(md_with_meta, encoding="utf-8")
        try:
            result = subprocess.run(
                ["pandoc", str(md_temp), "-o", str(epub_path),
                 "--from", "markdown", "--to", "epub3",
                 "--standalone", "--toc"],
                capture_output=True, text=True, timeout=180
            )
            md_temp.unlink()
            if result.returncode != 0:
                return {"error": f"Pandoc ePub error: {result.stderr}"}, 500
        except subprocess.TimeoutExpired:
            return {"error": "ePub export timed out"}, 500
        except FileNotFoundError:
            return {"error": "Pandoc not found (required for ePub)"}, 500
        return send_file(str(epub_path), mimetype="application/epub+zip",
                         as_attachment=True, download_name=f"{safe_title}.epub")


# ---- HTML conversion -------------------------------------------------------

def markdown_to_html(md: str) -> str:
    """Minimal but robust markdown → HTML converter.
    Handles: headings, bold, italic, code, links, blockquotes, lists, hrules, paragraphs.
    Does NOT handle: tables, images (passes through), nested lists beyond 2 levels.
    """
    html_lines = []
    in_para = False
    in_code = False
    in_list = False
    list_type = None  # 'ul' or 'ol'

    def close_para():
        nonlocal in_para
        if in_para:
            html_lines.append("</p>")
            in_para = False

    def close_list():
        nonlocal in_list, list_type
        if in_list:
            html_lines.append(f"</{list_type}>")
            in_list = False
            list_type = None

    lines = md.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Code block
        if stripped.startswith("```"):
            if in_code:
                html_lines.append("</code></pre>")
                in_code = False
            else:
                close_para()
                close_list()
                html_lines.append("<pre><code>")
                in_code = True
            i += 1
            continue
        if in_code:
            html_lines.append(line.replace("<", "&lt;").replace(">", "&gt;"))
            i += 1
            continue

        # Headings
        m = re.match(r"^(#{1,6})\s+(.+)$", stripped)
        if m:
            close_para()
            close_list()
            level = len(m.group(1))
            content = inline_md(m.group(2))
            html_lines.append(f"<h{level}>{content}</h{level}>")
            i += 1
            continue

        # Horizontal rule
        if re.match(r"^[-*_]{3,}$", stripped):
            close_para()
            close_list()
            html_lines.append("<hr>")
            i += 1
            continue

        # Blockquote
        if stripped.startswith("> "):
            close_para()
            close_list()
            content = inline_md(stripped[2:])
            html_lines.append(f"<blockquote>{content}</blockquote>")
            i += 1
            continue

        # LaTeX commands (skip in HTML — they came from compile_book front matter)
        if stripped.startswith("\\"):
            i += 1
            continue

        # Front-matter delimiter (--- at start)
        if stripped == "---":
            i += 1
            continue

        # Unordered list
        if re.match(r"^[\-\*]\s+", stripped):
            if not in_list or list_type != "ul":
                close_para()
                close_list()
                html_lines.append("<ul>")
                in_list = True
                list_type = "ul"
            content = inline_md(re.sub(r"^[\-\*]\s+", "", stripped))
            html_lines.append(f"<li>{content}</li>")
            i += 1
            continue

        # Ordered list
        if re.match(r"^\d+\.\s+", stripped):
            if not in_list or list_type != "ol":
                close_para()
                close_list()
                html_lines.append("<ol>")
                in_list = True
                list_type = "ol"
            content = inline_md(re.sub(r"^\d+\.\s+", "", stripped))
            html_lines.append(f"<li>{content}</li>")
            i += 1
            continue

        # Blank line — close paragraph and list
        if not stripped:
            close_para()
            close_list()
            i += 1
            continue

        # Paragraph content
        if not in_para:
            close_list()
            html_lines.append("<p>")
            in_para = True
        else:
            html_lines.append(" ")
        html_lines.append(inline_md(stripped))
        i += 1

    close_para()
    close_list()
    return "\n".join(html_lines)


def inline_md(text: str) -> str:
    """Convert inline markdown (bold, italic, code, links)."""
    # Escape HTML first
    s = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    # Code
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    # Bold
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"__([^_]+)__", r"<strong>\1</strong>", s)
    # Italic
    s = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", s)
    s = re.sub(r"(?<!\w)_([^_]+)_(?!\w)", r"<em>\1</em>", s)
    # Links
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    return s


def build_html_document(title, author, body, ctx):
    """Build a complete standalone HTML document."""
    style = ctx.get("style", "")
    genre = ctx.get("genre", "")
    css = """\
* { box-sizing: border-box; }
body {
  font-family: Georgia, 'Iowan Old Style', 'Charter', serif;
  font-size: 18px;
  line-height: 1.7;
  color: #222;
  background: #fafaf8;
  max-width: 38em;
  margin: 3em auto;
  padding: 0 1.5em;
}
h1 { font-size: 2.4em; margin: 1.4em 0 0.4em; text-align: center; }
h2 { font-size: 1.7em; margin: 1.6em 0 0.5em; border-bottom: 1px solid #ddd; padding-bottom: 0.2em; }
h3 { font-size: 1.3em; margin: 1.4em 0 0.4em; }
.author { text-align: center; font-style: italic; color: #666; margin: 0; }
.genre { text-align: center; font-size: 0.9em; color: #888; margin: 0.2em 0 2em; }
blockquote { border-left: 3px solid #ccc; margin: 1em 0; padding: 0.5em 1em; color: #555; font-style: italic; }
pre, code { font-family: 'SF Mono', Menlo, Consolas, monospace; font-size: 0.9em; background: #f3f3f1; }
pre { padding: 1em; border-radius: 4px; overflow-x: auto; }
pre code { background: none; padding: 0; }
hr { border: 0; border-top: 1px solid #ddd; margin: 2em 0; }
a { color: #2c5aa0; text-decoration: none; }
a:hover { text-decoration: underline; }
"""
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<meta name="author" content="{author}">
<meta name="generator" content="Quill">
<style>{css}</style>
</head>
<body>
<h1>{title}</h1>
<p class="author">by {author}</p>
<p class="genre">{genre}</p>
<hr>
{body}
</body>
</html>
"""


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


# ---- Scenes (sub-chapters within a chapter) ---------------------------------

def get_chapter_dir(project_id: str, chapter_name: str) -> Path:
    """Get the directory for a chapter's scenes: <project>/chapter-NN/."""
    return get_project_dir(project_id) / chapter_name


def list_scenes(project_id: str, chapter_name: str):
    """List scene files for a chapter. Stored as <project>/chapter-NN/scene-NN.md."""
    chapter_dir = get_chapter_dir(project_id, chapter_name)
    if not chapter_dir.exists():
        return []
    files = sorted(chapter_dir.glob("scene-*.md"), key=lambda p: natural_sort_key(p.stem))
    return [
        {"name": f.stem, "path": str(f), "modified": os.path.getmtime(f), "size": os.path.getsize(f)}
        for f in files
    ]


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/scenes", methods=["GET"])
def get_scenes(project_id, chapter_name):
    return list_scenes(project_id, chapter_name)


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/scenes", methods=["POST"])
def create_scene(project_id, chapter_name):
    data = safe_json()
    raw_name = (data.get("name") or "scene-1").strip()
    safe = raw_name.replace(" ", "-").replace(".md", "").replace("/", "-")
    chapter_dir = get_chapter_dir(project_id, chapter_name)
    chapter_dir.mkdir(parents=True, exist_ok=True)
    filepath = chapter_dir / f"{safe}.md"
    if filepath.exists():
        return {"error": "Scene already exists"}, 409
    filepath.write_text(f"# {safe.replace('-', ' ').title()}\n\n", encoding="utf-8")
    return {"name": safe, "path": str(filepath), "chapter": chapter_name}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/scenes/<scene_name>/content", methods=["GET"])
def get_scene_content(project_id, chapter_name, scene_name):
    name = scene_name.replace(".md", "")
    fp = get_chapter_dir(project_id, chapter_name) / f"{name}.md"
    if not fp.exists():
        return {"error": "Not found"}, 404
    return {"name": name, "content": fp.read_text(encoding="utf-8"), "path": str(fp)}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/scenes/<scene_name>/content", methods=["PUT"])
def save_scene_content(project_id, chapter_name, scene_name):
    data = safe_json()
    name = scene_name.replace(".md", "")
    chapter_dir = get_chapter_dir(project_id, chapter_name)
    chapter_dir.mkdir(parents=True, exist_ok=True)
    (chapter_dir / f"{name}.md").write_text(data.get("content", ""), encoding="utf-8")
    return {"ok": True}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/scenes/<scene_name>", methods=["DELETE"])
def delete_scene(project_id, chapter_name, scene_name):
    name = scene_name.replace(".md", "")
    fp = get_chapter_dir(project_id, chapter_name) / f"{name}.md"
    if fp.exists():
        fp.unlink()
    return {"ok": True}


# ---- Story Bible / Codex ---------------------------------------------------

@app.route("/api/projects/<project_id>/codex", methods=["GET"])
def get_codex(project_id):
    """Return the structured Story Bible: characters, world, summary, style, plot."""
    ctx = get_project_context(project_id)
    return {
        "characters": ctx.get("characters", ""),
        "world": ctx.get("world", ""),
        "summary": ctx.get("summary", ""),
        "style": ctx.get("style", ""),
        "plot": ctx.get("plot", ""),
        "themes": ctx.get("themes", ""),
    }


@app.route("/api/projects/<project_id>/codex", methods=["PUT"])
def update_codex(project_id):
    """Update the Story Bible fields. Only provided fields are updated."""
    data = safe_json()
    ctx = get_project_context(project_id)
    for key in ["characters", "world", "summary", "style", "plot", "themes"]:
        if key in data and isinstance(data[key], str):
            ctx[key] = data[key]
    save_project_context(project_id, ctx)
    return {
        "characters": ctx.get("characters", ""),
        "world": ctx.get("world", ""),
        "summary": ctx.get("summary", ""),
        "style": ctx.get("style", ""),
        "plot": ctx.get("plot", ""),
        "themes": ctx.get("themes", ""),
    }


# ---- Session stats + writing goals -----------------------------------------

def get_stats_file(project_id: str) -> Path:
    return get_project_dir(project_id) / ".quill_stats.json"


def load_stats(project_id: str) -> dict:
    f = get_stats_file(project_id)
    if f.exists():
        try:
            return json.loads(f.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass
    return {
        "daily_goal": 500,
        "words_today": 0,
        "total_words": 0,
        "last_session_start": None,
        "sessions": [],  # list of {start, end, words_written}
        "last_active_date": None,
    }


def save_stats(project_id: str, stats: dict):
    get_stats_file(project_id).write_text(json.dumps(stats, indent=2), encoding="utf-8")


def today_iso() -> str:
    return datetime.now().strftime("%Y-%m-%d")


@app.route("/api/projects/<project_id>/stats", methods=["GET"])
def get_stats(project_id):
    stats = load_stats(project_id)
    # Recompute words_today if the last active date is different
    if stats.get("last_active_date") != today_iso():
        stats["words_today"] = 0
    return stats


@app.route("/api/projects/<project_id>/stats", methods=["PUT"])
def update_stats(project_id):
    """Update writing stats. Used to record sessions, set goals, etc."""
    data = safe_json()
    stats = load_stats(project_id)
    if "daily_goal" in data:
        try:
            stats["daily_goal"] = int(data["daily_goal"])
        except (TypeError, ValueError):
            return {"error": "daily_goal must be an integer"}, 400
    if "session_start" in data:
        stats["last_session_start"] = data["session_start"]
    if "session_end" in data:
        if stats.get("last_session_start"):
            stats["sessions"].append({
                "start": stats["last_session_start"],
                "end": data["session_end"],
            })
            stats["last_session_start"] = None
    if "words_written" in data:
        try:
            words = int(data["words_written"])
            # Clamp the addition (deletions don't subtract, they just don't add)
            delta = max(0, words)
            if stats.get("last_active_date") == today_iso():
                stats["words_today"] = stats.get("words_today", 0) + delta
            else:
                stats["words_today"] = delta
            stats["last_active_date"] = today_iso()
            stats["total_words"] = stats.get("total_words", 0) + delta
        except (TypeError, ValueError):
            pass
    save_stats(project_id, stats)
    return stats


# ---- Corkboard / Synopsis -------------------------------------------------

@app.route("/api/projects/<project_id>/chapters/<chapter_name>/synopsis", methods=["GET"])
def get_synopsis(project_id, chapter_name):
    """Get the one-line synopsis for a chapter (used in corkboard view)."""
    name = chapter_name.replace(".md", "")
    ctx = get_project_context(project_id)
    synopses = ctx.get("synopses", {})
    return {"synopsis": synopses.get(name, "")}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/synopsis", methods=["PUT"])
def set_synopsis(project_id, chapter_name):
    """Set the one-line synopsis for a chapter (used in corkboard view)."""
    name = chapter_name.replace(".md", "")
    data = safe_json()
    ctx = get_project_context(project_id)
    synopses = ctx.get("synopses", {})
    synopses[name] = data.get("synopsis", "")
    ctx["synopses"] = synopses
    save_project_context(project_id, ctx)
    return {"synopsis": synopses[name]}


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
