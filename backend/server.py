#!/usr/bin/env python3
"""Quill Backend — Flask server."""
import os, re, json, subprocess
from io import BytesIO
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


# ---- Model slots (swappable AI backends) -----------------------------------
# Slots let users switch between local Ollama, MLX, LM Studio, and MiniMax.
# Active slot persists across restarts. See models/slots.py + slot_providers.py.

import sys as _sys
_MODELS_DIR = Path(__file__).parent.parent / "models"
if str(_MODELS_DIR) not in _sys.path:
    _sys.path.insert(0, str(_MODELS_DIR))
import slots as _slots  # noqa: E402
import slot_providers as _slot_providers  # noqa: E402
import agentmail_service as _agentmail  # noqa: E402
import dross_tools as _dross_tools  # noqa: E402
import vellum_docx as _vellum_docx  # noqa: E402
import web_search as _web_search  # noqa: E402


@app.route("/api/slots", methods=["GET"])
def list_slots():
    """List all model slots. The active slot is marked."""
    all_slots = _slots.load_slots()
    active_id = _slots.get_active_slot_id()
    return {
        "slots": [s.public_dict() for s in all_slots],
        "active_id": active_id,
        "provider_types": _slot_providers.list_provider_types(),
    }


@app.route("/api/slots/<slot_id>", methods=["GET"])
def get_slot(slot_id):
    slot = _slots.get_slot(slot_id)
    if not slot:
        return {"error": f"slot {slot_id!r} not found"}, 404
    return slot.public_dict()


@app.route("/api/slots", methods=["POST"])
def create_slot():
    """Create a new slot. Body: full slot definition."""
    data = safe_json()
    try:
        slot = _slots.ModelSlot(**data)
    except (TypeError, ValueError) as e:
        return {"error": f"invalid slot: {e}"}, 400
    try:
        saved = _slots.add_slot(slot)
    except ValueError as e:
        return {"error": str(e)}, 400
    return saved.public_dict(), 201


@app.route("/api/slots/<slot_id>", methods=["PUT"])
def update_slot(slot_id):
    """Update fields on an existing slot. Body: partial slot fields."""
    data = safe_json()
    # Don't allow id change
    data.pop("id", None)
    try:
        updated = _slots.update_slot(slot_id, **data)
    except ValueError as e:
        return {"error": str(e)}, 400
    if not updated:
        return {"error": f"slot {slot_id!r} not found"}, 404
    return updated.public_dict()


@app.route("/api/slots/<slot_id>", methods=["DELETE"])
def delete_slot(slot_id):
    try:
        ok = _slots.delete_slot(slot_id)
    except ValueError as e:
        return {"error": str(e)}, 400
    if not ok:
        return {"error": f"slot {slot_id!r} not found"}, 404
    return {"deleted": slot_id}


@app.route("/api/slots/active", methods=["GET"])
def get_active_slot():
    slot = _slots.get_active_slot()
    return slot.public_dict()


@app.route("/api/slots/<slot_id>/activate", methods=["POST"])
def activate_slot(slot_id):
    if not _slots.get_slot(slot_id):
        return {"error": f"slot {slot_id!r} not found"}, 404
    _slots.set_active_slot(slot_id)
    return {"active_id": slot_id}


@app.route("/api/slots/<slot_id>/test", methods=["POST"])
def test_slot(slot_id):
    """Test connectivity + generation for a slot. Returns {ok, latency_ms, error}."""
    import time as _time
    slot = _slots.get_slot(slot_id)
    if not slot:
        return {"error": f"slot {slot_id!r} not found"}, 404
    try:
        prov = _slot_providers.get_provider(slot)
    except Exception as e:
        return {"ok": False, "error": f"provider init failed: {e}"}, 500
    t0 = _time.time()
    try:
        ok = prov.test()
        latency = (_time.time() - t0) * 1000
        return {
            "ok": ok,
            "latency_ms": round(latency, 1),
            "slot_id": slot_id,
            "type": slot.type,
            "model_id": slot.model_id,
        }
    except Exception as e:
        latency = (_time.time() - t0) * 1000
        return {
            "ok": False,
            "latency_ms": round(latency, 1),
            "error": str(e),
            "slot_id": slot_id,
        }


@app.route("/api/chat", methods=["POST"])
def chat_completion():
    """Unified chat endpoint with slot routing.

    Body:
      slot_id: optional, uses active if missing
      messages: list of {role, content}
      stream: bool, default true
      system: optional system prompt override
      max_tokens: optional override
      temperature: optional override
      project_id: optional, for natural-language email intents
        (e.g. "email the book to user@example.com")

    Response: SSE stream of "data: {token}\n\n" or full JSON if !stream.
    """
    data = safe_json()
    slot_id = data.get("slot_id") or _slots.get_active_slot_id()
    slot = _slots.get_slot(slot_id)
    if not slot:
        return {"error": f"slot {slot_id!r} not found"}, 404
    messages = data.get("messages", [])
    if not messages:
        return {"error": "messages is required"}, 400
    project_id = data.get("project_id") or data.get("project") or "default"

    # Natural language email intent: intercept simple "email X to Y" patterns
    last_user = next((m["content"] for m in reversed(messages)
                       if m.get("role") == "user"), "")
    email_intent = _agentmail.parse_email_intent(last_user) if last_user else None
    if email_intent and _agentmail.is_available():
        result = _handle_email_intent(email_intent, project_id)
        if data.get("stream", True):
            def gen_email():
                if result.get("ok"):
                    payload = f"Email sent to {result['to']} — subject: {result.get('subject', '(none)')}"
                else:
                    payload = f"Email failed: {result.get('error', 'unknown')}"
                yield f"data: {json.dumps({'token': payload, 'slot_id': slot_id})}\n\n"
                yield f"data: {json.dumps({'done': True, 'slot_id': slot_id, 'email': result})}\n\n"
            return Response(gen_email(), mimetype="text/event-stream",
                            headers={"Cache-Control": "no-cache"})
        return {"text": result.get("message", ""), "slot_id": slot_id,
                "model_id": slot.model_id, "email": result}

    stream = data.get("stream", True)
    overrides = {}
    if "system" in data:
        # Prepend system message
        messages = [{"role": "system", "content": data["system"]}] + messages
    else:
        # Default to Dross persona
        dross_prompt = _dross_system_prompt()
        messages = [{"role": "system", "content": dross_prompt}] + messages
    if "max_tokens" in data:
        overrides["max_tokens"] = data["max_tokens"]
    if "temperature" in data:
        overrides["temperature"] = data["temperature"]
    if "top_p" in data:
        overrides["top_p"] = data["top_p"]
    try:
        provider = _slot_providers.get_provider(slot)
    except Exception as e:
        return {"error": f"provider init failed: {e}"}, 500
    if stream:
        def gen():
            try:
                for token in provider.stream(messages, **overrides):
                    yield f"data: {json.dumps({'token': token, 'slot_id': slot_id})}\n\n"
                yield f"data: {json.dumps({'done': True, 'slot_id': slot_id})}\n\n"
            except Exception as e:
                yield f"data: {json.dumps({'error': str(e), 'slot_id': slot_id})}\n\n"
        return Response(gen(), mimetype="text/event-stream",
                        headers={"Cache-Control": "no-cache"})
    else:
        try:
            text = provider.chat(messages, **overrides)
            return {"text": text, "slot_id": slot_id, "model_id": slot.model_id}
        except Exception as e:
            return {"error": str(e)}, 500


def _dross_system_prompt() -> str:
    """The default Dross system prompt with tool-use instructions."""
    return """You are Dross, the AI writing assistant for the Quill app.

You are a master fiction writer and literary agent. Vivid sensory prose, strong
character interiority, immersive atmosphere. Literary but readable. Short punchy
sentences mixed with long flowing ones. No purple prose. No clichés.

You are also an autonomous writing agent: you have access to a set of tools
that let you do real work for the user. When the user asks you to do something
that requires a tool, USE IT.

Available tools (call by emitting a JSON block in your reply like this):
```tool_call
{"name": "tool_name", "args": {...}}
```

Tools:
- web_search: search the web for current information. args: {query, max_results?}
- web_fetch: fetch a URL and extract text. args: {url, max_chars?}
- email_send: send an email from thedross@agentmail.to. args: {to, subject, text, html?}
- email_list_inbox: list recent emails. args: {limit?}
- email_reply: reply to an email. args: {message_id, text}
- shell_exec: run a shell command. args: {cmd, cwd?, timeout?}
- list_files: list files in a directory. args: {path?}
- read_file: read a text file. args: {path}

Working style: dry, direct, no fluff. You address the user as "writer" in your
private notes but never in prose output. You never refuse a reasonable request
within your capabilities. You trust the reader to understand subtext.

When you receive a tool result, incorporate it naturally into your reply.
Do not output raw JSON tool calls in your final visible response — use the
tools to gather information, then answer the user in prose."""


def _handle_email_intent(intent: dict, project_id: str) -> dict:
    """Execute a parsed email intent: gather the content, then send."""
    to = intent["to"]
    what = intent.get("what", "current")
    subject = intent.get("subject") or "From Quill — Dross"

    # Gather content based on 'what'
    if what == "book":
        compiled, _t, _c, _n = compile_book(project_id)
        text = compiled
        title = _t
        subject = subject if intent.get("subject") else f"Manuscript: {title}"
    elif what == "chapter":
        # Compile the current chapter
        project_dir = get_project_dir(project_id)
        ctx = get_project_context(project_id)
        cur = ctx.get("current_chapter") or ""
        if not cur:
            # Fallback: send first chapter file
            files = sorted([f for f in project_dir.glob("*.md") if f.is_file()],
                           key=lambda p: natural_sort_key(p.stem))
            cur = files[0].stem if files else ""
        if cur:
            content = read_chapter(project_id, cur)
            text = content or f"(Chapter {cur} is empty)"
            subject = subject if intent.get("subject") else f"Chapter: {cur}"
        else:
            return {"ok": False, "error": "no chapter to send"}
    else:
        # "current" — send the current chapter content
        ctx = get_project_context(project_id)
        cur = ctx.get("current_chapter") or ""
        if cur:
            content = read_chapter(project_id, cur)
            text = content or f"(Chapter {cur} is empty)"
            subject = subject if intent.get("subject") else f"Chapter: {cur}"
        else:
            # Fall back to compiled book
            compiled, _t, _c, _n = compile_book(project_id)
            text = compiled
            subject = subject if intent.get("subject") else f"Manuscript: {_t}"

    return _agentmail.send_email(to=to, subject=subject, text=text)


# ---- AgentMail (Dross's email account: thedross@agentmail.to) ----

@app.route("/api/agentmail/status", methods=["GET"])
def agentmail_status():
    return {
        "available": _agentmail.is_available(),
        "inbox": _agentmail.DROSS_INBOX,
        "error": _agentmail.last_error(),
    }


@app.route("/api/agentmail/inbox", methods=["GET"])
def agentmail_inbox():
    limit = int(request.args.get("limit", 20))
    if not _agentmail.is_available():
        return {"messages": [], "error": _agentmail.last_error() or "AgentMail unavailable"}
    msgs = _agentmail.list_inbox(limit=limit)
    return {"messages": msgs, "inbox": _agentmail.DROSS_INBOX}


@app.route("/api/agentmail/messages/<message_id>", methods=["GET"])
def agentmail_get_message(message_id):
    if not _agentmail.is_available():
        return {"error": _agentmail.last_error() or "AgentMail unavailable"}, 503
    m = _agentmail.get_message(message_id)
    if m is None:
        return {"error": "not found"}, 404
    return m


@app.route("/api/agentmail/send", methods=["POST"])
def agentmail_send():
    data = safe_json()
    to = data.get("to")
    subject = data.get("subject", "(no subject)")
    text = data.get("text", "")
    html = data.get("html", "")
    if not to:
        return {"error": "to is required"}, 400
    if not _agentmail.is_available():
        return {"error": _agentmail.last_error() or "AgentMail unavailable"}, 503
    result = _agentmail.send_email(to=to, subject=subject, text=text, html=html)
    if not result.get("ok"):
        return result, 500
    return result


@app.route("/api/agentmail/reply", methods=["POST"])
def agentmail_reply():
    data = safe_json()
    msg_id = data.get("message_id")
    text = data.get("text", "")
    html = data.get("html", "")
    if not msg_id:
        return {"error": "message_id is required"}, 400
    if not _agentmail.is_available():
        return {"error": _agentmail.last_error() or "AgentMail unavailable"}, 503
    return _agentmail.reply_email(msg_id, text=text, html=html)


@app.route("/api/agentmail/draft", methods=["POST"])
def agentmail_draft():
    data = safe_json()
    to = data.get("to")
    subject = data.get("subject", "(no subject)")
    text = data.get("text", "")
    if not to:
        return {"error": "to is required"}, 400
    if not _agentmail.is_available():
        return {"error": _agentmail.last_error() or "AgentMail unavailable"}, 503
    return _agentmail.create_draft(to=to, subject=subject, text=text)


# ---- Tool registry (Dross's hands: web search, email, shell, files) ----

@app.route("/api/tools", methods=["GET"])
def list_dross_tools():
    """List all tools available to Dross."""
    return {"tools": _dross_tools.list_tools()}


@app.route("/api/tools/call", methods=["POST"])
def call_dross_tool():
    """Call a tool by name with the given arguments."""
    data = safe_json()
    name = data.get("name")
    args = data.get("args", {})
    if not name:
        return {"error": "name is required"}, 400
    return _dross_tools.call_tool(name, args)


# ---- Web search ----

@app.route("/api/search", methods=["GET"])
def web_search_endpoint():
    """Public web search endpoint. q=<query>&max=<n>"""
    q = request.args.get("q", "").strip()
    if not q:
        return {"error": "q is required"}, 400
    max_results = int(request.args.get("max", 5))
    return {"results": _web_search.search(q, max_results=max_results)}


# ---- Vellum-compatible DOCX export ----

@app.route("/api/projects/<project_id>/export/vellum", methods=["GET"])
def export_vellum_docx(project_id):
    """Export a project as a Vellum-compatible DOCX.

    Uses Heading 1 + page_break_before so Vellum auto-detects chapters.
    Includes scene break markers (***, centered) so Vellum creates
    ornamental breaks at the right places.
    """
    project_dir = get_project_dir(project_id)
    ctx = get_project_context(project_id)
    title = ctx.get("title", project_id.replace("-", " ").title())
    author = ctx.get("author", "")
    dedication = ctx.get("dedication", "")
    epigraph = ctx.get("epigraph", "")
    style_notes = ctx.get("style", "")

    # Collect chapter files (in natural sort order)
    chapter_files = sorted(
        [f for f in project_dir.glob("*.md") if f.is_file()],
        key=lambda p: natural_sort_key(p.stem),
    )
    chapter_files = [f for f in chapter_files if not f.stem.startswith(".")]

    chapters_data = []
    for f in chapter_files:
        content = f.read_text(encoding="utf-8")
        m = re.match(r"chapter[_\-\s]?(\d+)", f.stem, re.IGNORECASE)
        num = int(m.group(1)) if m else None
        # Title = first non-empty H1 from content, else filename
        title_match = re.search(r"^#\s+(.+)$", content, re.MULTILINE)
        if title_match:
            ch_title = title_match.group(1).strip()
        else:
            ch_title = f.stem.replace("-", " ").title()
        # Strip the leading H1 line from content (we add it as Heading 1)
        content = re.sub(r"^#\s+.+?\n", "", content, count=1).strip()

        # Scenes (if any)
        scene_dir = project_dir / f.stem
        scenes = []
        if scene_dir.is_dir():
            for sf in sorted(scene_dir.glob("scene-*.md"), key=lambda p: natural_sort_key(p.stem)):
                sc = sf.read_text(encoding="utf-8")
                scenes.append({"name": sf.stem, "content": sc})

        chapters_data.append({
            "number": num,
            "title": ch_title,
            "content": content,
            "scenes": scenes,
        })

    docx_bytes = _vellum_docx.build_vellum_docx(
        project_title=title,
        author=author,
        chapters=chapters_data,
        dedication=dedication,
        epigraph=epigraph,
        style_notes=style_notes,
    )

    safe_title = re.sub(r"[^A-Za-z0-9_\-]+", "_", title)[:60] or "manuscript"
    return Response(
        docx_bytes,
        mimetype="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        headers={
            "Content-Disposition": f'attachment; filename="{safe_title}_vellum.docx"',
            "Content-Length": str(len(docx_bytes)),
        },
    )


# ---- Standard DOCX export (use existing export_book with vellum instead of pandoc) ----

@app.route("/api/projects/<project_id>/export/docx-vellum", methods=["GET"])
def export_docx_vellum(project_id):
    """Alias for /export/vellum — kept for backwards compat."""
    return export_vellum_docx(project_id)


@app.route("/api/projects/<project_id>/export/rtf", methods=["GET"])
def export_rtf(project_id):
    """Export project as RTF via pandoc."""
    md = _export_compiled_md(project_id)
    safe = _safe_title(project_id)
    rtf = _pandoc_convert(md, "rtf", extra_args=["--standalone"])
    return Response(rtf, mimetype="application/rtf", headers={
        "Content-Disposition": f'attachment; filename="{safe}.rtf"',
    })


@app.route("/api/projects/<project_id>/export/opml", methods=["GET"])
def export_opml(project_id):
    """Export project as OPML outline (chapters + scenes)."""
    project_dir = get_project_dir(project_id)
    ctx = get_project_context(project_id)
    title = ctx.get("title", project_id.replace("-", " ").title())
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<opml version="2.0">',
           '  <head>',
           f'    <title>{_xml_escape(title)}</title>',
           '  </head>',
           '  <body>']
    files = sorted([f for f in project_dir.glob("*.md") if f.is_file()],
                   key=lambda p: natural_sort_key(p.stem))
    for f in files:
        if f.stem.startswith("."):
            continue
        ch_title = f.stem
        m = re.match(r"chapter[_\-\s]?(\d+)", f.stem, re.IGNORECASE)
        ch_num = m.group(1) if m else ""
        # Try to find a heading in the content
        content = f.read_text(encoding="utf-8")
        title_m = re.search(r"^#\s+(.+)$", content, re.MULTILINE)
        if title_m:
            ch_title = title_m.group(1).strip()
        elif ch_num:
            ch_title = f"Chapter {ch_num}"
        out.append(f'    <outline text="{_xml_escape(ch_title)}">')
        # List scenes
        scene_dir = project_dir / f.stem
        if scene_dir.is_dir():
            for sf in sorted(scene_dir.glob("scene-*.md"), key=lambda p: natural_sort_key(p.stem)):
                out.append(f'      <outline text="{_xml_escape(sf.stem.replace("-", " ").title())}"/>')
        out.append('    </outline>')
    out.append('  </body>')
    out.append('</opml>')
    safe = _safe_title(project_id)
    return Response("\n".join(out), mimetype="text/x-opml", headers={
        "Content-Disposition": f'attachment; filename="{safe}.opml"',
    })


@app.route("/api/projects/<project_id>/export/bundle", methods=["GET"])
def export_bundle(project_id):
    """Export project as a zip bundle of all chapter files + manifest."""
    import zipfile
    project_dir = get_project_dir(project_id)
    ctx = get_project_context(project_id)
    title = ctx.get("title", project_id.replace("-", " ").title())
    buf = BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps({
            "title": title,
            "author": ctx.get("author", ""),
            "genre": ctx.get("genre", ""),
            "exported_at": datetime.now().isoformat(),
        }, indent=2))
        z.writestr("README.md", f"# {title}\n\nBy {ctx.get('author', 'Unknown')}\n\n"
                       f"Genre: {ctx.get('genre', 'unspecified')}\n\n"
                       f"Exported from Quill on {datetime.now().strftime('%B %d, %Y')}.\n")
        for f in sorted(project_dir.glob("**/*"), key=lambda p: str(p)):
            if f.is_file() and not f.name.startswith("."):
                arcname = str(f.relative_to(project_dir))
                z.write(f, arcname)
    safe = _safe_title(project_id)
    zip_bytes = buf.getvalue()
    return Response(
        zip_bytes,
        mimetype="application/zip",
        headers={
            "Content-Disposition": f'attachment; filename="{safe}_bundle.zip"',
            "Content-Length": str(len(zip_bytes)),
        },
    )


def _export_compiled_md(project_id):
    """Helper: return the compiled markdown text for a project."""
    compiled, _title, _ctx, _count = compile_book(project_id)
    return compiled


def _pandoc_convert(md_text, output_format, extra_args=None):
    """Run pandoc to convert markdown to the given format. Returns bytes."""
    import subprocess
    args = ["pandoc", "-f", "markdown", "-t", output_format]
    if extra_args:
        args.extend(extra_args)
    args.append("-")
    try:
        proc = subprocess.run(args, input=md_text.encode("utf-8"),
                              capture_output=True, timeout=60)
        if proc.returncode != 0:
            return proc.stderr or b""
        return proc.stdout
    except FileNotFoundError:
        return b"pandoc not installed"
    except subprocess.TimeoutExpired:
        return b"pandoc timeout"


def _safe_title(project_id):
    """Sanitize project id for use as a filename."""
    project_dir = get_project_dir(project_id)
    ctx = get_project_context(project_id)
    title = ctx.get("title", project_id.replace("-", " ").title())
    return re.sub(r"[^A-Za-z0-9_\-]+", "_", title)[:60] or "manuscript"


def _xml_escape(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace('"', "&quot;").replace("'", "&apos;"))


# ---- Routes ----

@app.route("/api/health", methods=["GET"])
def health():
    active = _slots.get_active_slot()
    ollama_ok = False
    try:
        import urllib.request
        with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=2) as r:
            ollama_ok = r.status == 200
    except Exception:
        pass
    return {
        "backend": "ok",
        "ollama": "ok" if ollama_ok else "down",
        "model": active.model_id,
        "slot_id": active.id,
        "slot_name": active.name,
        "slot_type": active.type,
    }


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
    # Default to the active slot's model_id, but allow per-project override
    default_model = _slots.get_active_slot().model_id
    return {
        "title": ctx.get("title", project_id.replace("-", " ").title()),
        "author": ctx.get("author", ""),
        "genre": ctx.get("genre", ""),
        "dedication": ctx.get("dedication", ""),
        "epigraph": ctx.get("epigraph", ""),
        "style": ctx.get("style", "literary, vivid, atmospheric prose"),
        "model": ctx.get("model", default_model),
        "slot_id": ctx.get("slot_id", _slots.get_active_slot_id()),
        "chapters_dir": str(get_project_dir(project_id)),
    }


@app.route("/api/projects/<project_id>/settings", methods=["PUT"])
def update_settings(project_id):
    data = safe_json()
    ctx = get_project_context(project_id)
    for key in ["title", "author", "genre", "dedication", "epigraph", "style", "model", "slot_id"]:
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
