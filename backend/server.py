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
# CORS — open by default since this is a local backend. Lock down if exposed.
CORS(app)
# Max request body size: 32 MB (chapter content + context can be large but
# anything bigger is probably malicious). Flask default is unlimited.
app.config["MAX_CONTENT_LENGTH"] = 32 * 1024 * 1024


def _discover_base_dir() -> Path:
    """Find the Quill projects directory.

    Searches in order:
      1. The current BASE_DIR (~/Quill/projects)
      2. ~/Projects/Quill/  (newer layout)
      3. $QUILL_PROJECTS env var (override)
      4. Defaults to BASE_DIR (creates if missing)

    Returns a Path that may or may not exist; callers should ensure_base_dir()
    before relying on it.
    """
    env = os.environ.get("QUILL_PROJECTS")
    if env:
        p = Path(env).expanduser()
        if p.exists() and p.is_dir():
            return p
    # Common locations, prefer ones that exist
    candidates = [
        Path.home() / "Quill" / "projects",
        Path.home() / "Projects" / "Quill" / "projects",
        Path.home() / "Projects" / "quill" / "projects",
        Path.home() / "quill" / "projects",
    ]
    for c in candidates:
        if c.exists() and c.is_dir():
            return c
    return BASE_DIR


# Use discovered path on startup; can be overridden by env var
BASE_DIR = _discover_base_dir()


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
    # If the project has an explicit chapter order (set via the
    # /reorder endpoint), use that instead of natural sort. The order
    # list is sanitized; missing files are appended at the end.
    try:
        ctx = get_project_context(project_id)
        order = ctx.get("chapter_order")
    except Exception:
        order = None
    if isinstance(order, list) and order:
        stems = [f.stem for f in files]
        present = {s: f for s, f in zip(stems, files)}
        ordered = []
        for name in order:
            # Match either bare name or name with .md
            for stem, file in present.items():
                if stem == name or stem == name + ".md" or name == stem + ".md":
                    if file not in ordered:
                        ordered.append(file)
                    break
        # Append any files not in the explicit order
        for f in files:
            if f not in ordered:
                ordered.append(f)
        files = ordered
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


def safe_name(name: str, fallback: str = "untitled", max_len: int = 80) -> str:
    """Sanitize a name to be safe for filesystem use.

    - Strips leading/trailing whitespace
    - Replaces spaces with dashes (preserves word boundaries)
    - Replaces path separators (/, \\) and other unsafe chars with -
    - Rejects '..' (path traversal) and '.'
    - Collapses multiple dashes
    - Falls back to 'untitled' if empty
    - Truncates to max_len
    - Refuses None and non-string inputs
    """
    if not name or not isinstance(name, str):
        return fallback
    name = name.strip()
    if not name:
        return fallback
    # Replace spaces with dashes
    name = name.replace(" ", "-")
    # Replace path separators and other unsafe chars
    # Windows-reserved: < > : " | ? * and control chars
    unsafe = '<>:"/\\|?*' + ''.join(chr(c) for c in range(32))
    for ch in unsafe:
        name = name.replace(ch, "-")
    # Reject path traversal
    if ".." in name:
        name = name.replace("..", "-")
    # Collapse multiple dashes
    while "--" in name:
        name = name.replace("--", "-")
    name = name.strip("-").strip()
    if not name:
        return fallback
    if len(name) > max_len:
        name = name[:max_len].rstrip("-")
    return name


def safe_content(content) -> str:
    """Ensure content is a string. Defaults to empty for None/non-string."""
    if content is None:
        return ""
    if not isinstance(content, str):
        return str(content)
    return content


def validate_project_id(project_id: str) -> Optional[str]:
    """Validate a project_id. Returns the project dir if valid, None if not.

    Rejects: empty, path traversal, too long, invalid chars.
    """
    if not project_id or not isinstance(project_id, str):
        return None
    project_id = project_id.strip()
    if not project_id:
        return None
    if ".." in project_id or "/" in project_id or "\\" in project_id:
        return None
    if project_id.startswith("."):
        return None
    if len(project_id) > 80:
        return None
    return project_id


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
import dross_tools as _dross_tools  # noqa: E402  (kept as alias for Quill tool registry)
import vellum_docx as _vellum_docx  # noqa: E402
import web_search as _web_search  # noqa: E402
import skills as _skills  # noqa: E402


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

    # Slash command: /extract — read the chapters and update the Story Bible
    if last_user.strip().lower().startswith("/extract"):
        return _handle_extract_command(
            last_user, project_id, data, messages, slot
        )

    # Slash command: /bible <field> — show a specific Story Bible field
    if last_user.strip().lower().startswith("/bible"):
        return _handle_bible_show_command(
            last_user, project_id, data, slot
        )

    # Chapter-write intent: when user says "write chapter N" / "draft this chapter"
    # we generate the prose (non-streaming) and save it to the chapter file
    # on disk. Then we return the result with a `chapter_written` field so
    # the Swift UI can refresh the editor.
    #
    # Critical: the write intent fires REGARDLESS of which project is selected.
    # If project_id is "default" or empty, we create a "default" project so the
    # user can just say "create chapter 1" without first having to set up a
    # project. This is the bug the user hit when their first attempt at chapter
    # creation silently failed because no project was selected.
    write_intent = _extract_chapter_write_intent(last_user) if last_user else None
    if write_intent:
        # Resolve to a real project_id — auto-create the "default" project if needed
        effective_project_id = project_id if project_id and project_id != "default" else "default"
        if effective_project_id == "default":
            # Create the default project on demand so chapter writes always have a home
            ensure_base_dir()
            default_dir = BASE_DIR / "default"
            if not default_dir.exists():
                default_dir.mkdir(parents=True, exist_ok=True)
                # Save initial context so future project selections work
                ctx = get_project_context("default")
                if not ctx.get("default_initialized"):
                    ctx["default_initialized"] = True
                    ctx["summary"] = "Default project — created automatically when you said 'create chapter 1'."
                    save_project_context("default", ctx)
        target_chapter = _resolve_chapter_target(effective_project_id, write_intent["target"])
        if target_chapter:
            # Use a focused prose-only system prompt so the model writes the
            # chapter directly without preamble, meta-commentary, or follow-up
            # questions. The default Quill persona would chat back asking
            # "what do you want next?" — that's not what we want here.
            prose_system = (
                "You are Quill, the AI writing partner in the Quill app. The user is "
                "a writer. Right now they want you to write the requested chapter.\n\n"
                "Write the chapter prose directly. Rules:\n"
                "- Output ONLY the chapter prose (markdown). No preamble, no "
                "follow-up questions, no meta-commentary.\n"
                "- Do not wrap the output in asterisks, code fences, or quotation marks.\n"
                "- Do not begin with 'Here is...' or 'Sure!' or any acknowledgement.\n"
                "- Do not end with a question to the user.\n"
                "- Match the tone and style the user has established in earlier "
                "messages or chapter content.\n"
                "- Vivid sensory prose, strong character interiority, immersive atmosphere. "
                "Literary but readable. Short punchy sentences mixed with long flowing "
                "ones. No purple prose. No clichés.\n"
                "- If the user gave an outline or notes, follow them. Otherwise write "
                "freely in the established voice."
            )
            system = data.get("system") or prose_system

            # Inject context: story bible + previous chapters so the model
            # maintains consistency with what's already been written.
            ctx = get_project_context(effective_project_id)
            existing_chapters = sorted(
                [f for f in get_project_dir(effective_project_id).glob("*.md")
                 if f.is_file()],
                key=lambda p: natural_sort_key(p.stem),
            )
            context_block = []
            if ctx.get("characters"):
                context_block.append(f"CHARACTERS (story bible):\n{ctx['characters']}")
            # Structured character list (from /extract) — already pretty-printed
            chars_list = ctx.get("characters_list")
            if isinstance(chars_list, list) and chars_list:
                lines = [f"  - {c.get('name', '?')} ({c.get('role', 'unknown')}): "
                         f"{c.get('description', '').strip()}"
                         for c in chars_list if isinstance(c, dict)]
                if lines:
                    context_block.append("CHARACTERS (structured):\n" + "\n".join(lines))
            if ctx.get("world"):
                context_block.append(f"WORLD (story bible):\n{ctx['world']}")
            if ctx.get("summary"):
                context_block.append(f"PLOT SUMMARY:\n{ctx['summary']}")
            if ctx.get("plot"):
                context_block.append(f"PLOT OUTLINE:\n{ctx['plot']}")
            if ctx.get("inciting_incident"):
                context_block.append(f"INCITING INCIDENT:\n{ctx['inciting_incident']}")
            if ctx.get("climax"):
                context_block.append(f"CLIMAX (where the story is heading):\n{ctx['climax']}")
            if ctx.get("resolution"):
                context_block.append(f"RESOLUTION (where the story is going):\n{ctx['resolution']}")
            if ctx.get("style"):
                context_block.append(f"STYLE GUIDE:\n{ctx['style']}")
            if ctx.get("tone"):
                context_block.append(f"TONE: {ctx['tone']}")
            if ctx.get("pov"):
                context_block.append(f"POINT OF VIEW: {ctx['pov']}")
            if ctx.get("tense"):
                context_block.append(f"TENSE: {ctx['tense']}")
            # Themes + motifs (helps the AI track symbolic weight)
            themes = ctx.get("themes")
            if isinstance(themes, list) and themes:
                context_block.append("THEMES:\n" + "\n".join(f"  - {t}" for t in themes))
            motifs = ctx.get("motifs")
            if isinstance(motifs, list) and motifs:
                context_block.append("MOTIFS (recurring imagery):\n" +
                                     "\n".join(f"  - {m}" for m in motifs))
            # Locations, timeline, relationships
            locs = ctx.get("locations")
            if isinstance(locs, list) and locs:
                lines = [f"  - {l.get('name', '?')}: {l.get('description', '').strip()}"
                         for l in locs if isinstance(l, dict)]
                if lines:
                    context_block.append("LOCATIONS:\n" + "\n".join(lines))
            tl = ctx.get("timeline")
            if isinstance(tl, list) and tl:
                lines = [f"  {t.get('when', '?')}: {t.get('what', '').strip()}"
                         for t in tl if isinstance(t, dict)]
                if lines:
                    context_block.append("TIMELINE (so far):\n" + "\n".join(lines))
            rels = ctx.get("relationships")
            if isinstance(rels, list) and rels:
                lines = [f"  - {r.get('from', '?')} → {r.get('to', '?')} "
                         f"({r.get('type', '?')}): {r.get('description', '').strip()}"
                         for r in rels if isinstance(r, dict)]
                if lines:
                    context_block.append("RELATIONSHIPS:\n" + "\n".join(lines))
            # Include the previous chapter (if any) for voice continuity
            prev_chapter_name = None
            for f in existing_chapters:
                if f.stem != target_chapter:
                    prev_chapter_name = f.stem
            if prev_chapter_name:
                prev_text = read_chapter(effective_project_id, prev_chapter_name)
                if prev_text:
                    # Cap at last 1500 chars so we don't blow up the context window
                    tail = prev_text[-1500:] if len(prev_text) > 1500 else prev_text
                    context_block.append(
                        f"END OF PREVIOUS CHAPTER ({prev_chapter_name}) — "
                        f"continue from this voice/plot:\n\n...{tail}"
                    )
            if context_block:
                system = system + "\n\n---\n\n" + "\n\n".join(context_block)

            full_messages = [{"role": "system", "content": system}] + messages
            try:
                provider = _slot_providers.get_provider(slot)
            except Exception as e:
                return {"error": f"provider init failed: {e}"}, 500
            overrides = {}
            if "max_tokens" in data:
                overrides["max_tokens"] = data["max_tokens"]
            else:
                overrides["max_tokens"] = 4000
            if "temperature" in data:
                overrides["temperature"] = data["temperature"]
            if "top_p" in data:
                overrides["top_p"] = data["top_p"]
            try:
                # Generate the prose (non-streaming for simplicity)
                prose = provider.chat(full_messages, **overrides)
                # Clean up common wrappers the model might add
                prose = _strip_chapter_wrapper(prose)
                # Save to chapter file (append, don't overwrite existing content)
                existing = read_chapter(effective_project_id, target_chapter) or f"# {target_chapter}\n\n"
                new_content = existing.rstrip() + "\n\n" + prose.strip() + "\n"
                write_chapter(effective_project_id, target_chapter, new_content)
                # Also track as "current chapter" for subsequent actions
                ctx = get_project_context(effective_project_id)
                ctx["current_chapter"] = target_chapter
                save_project_context(effective_project_id, ctx)
                if data.get("stream", True):
                    def gen_write():
                        # Stream the prose so the user sees it appear
                        chunk_size = 80
                        for i in range(0, len(prose), chunk_size):
                            yield f"data: {json.dumps({'token': prose[i:i+chunk_size]})}\n\n"
                        yield f"data: {json.dumps({'done': True, 'chapter_written': target_chapter, 'project_id': effective_project_id, 'streamed_chars': len(prose)})}\n\n"
                    return Response(gen_write(), mimetype="text/event-stream",
                                    headers={"Cache-Control": "no-cache"})
                return {"text": prose, "slot_id": slot_id,
                        "model_id": slot.model_id,
                        "chapter_written": target_chapter,
                        "project_id": effective_project_id,
                        "streamed_chars": len(prose)}
            except Exception as e:
                return {"error": f"chapter write failed: {e}"}, 500

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

    # ------------------------------------------------------------------
    # Tool-call loop
    # ------------------------------------------------------------------
    # The system prompt tells the model to emit tool calls as
    #   ```tool_call
    #   {"name": "...", "args": {...}}
    #   ```
    # We parse, execute, feed the result back, and loop until the model
    # produces a final response with no tool_call blocks. Max 5 iterations
    # so a runaway loop doesn't hang the request.
    MAX_TOOL_ITERS = 5

    def _run_tool_loop(call_provider, msgs):
        """Drive the tool-call loop. Returns the final assistant text
        plus a list of tool calls that were executed (in order)."""
        transcript: list[dict] = []  # [{name, args, result}, ...]
        current_msgs = list(msgs)
        for it in range(MAX_TOOL_ITERS):
            text = call_provider(current_msgs, **overrides)
            visible, calls = _parse_tool_calls(text)
            if not calls:
                return visible, transcript
            transcript.append({"iteration": it, "visible_before_tool": visible})
            for call in calls:
                result = _execute_tool_call(
                    call["name"], call["args"], project_id=project_id
                )
                transcript.append({
                    "name": call["name"],
                    "args": call["args"],
                    "result_preview": str(result)[:200],
                    "result": result,
                })
                # Feed the tool result back to the model as an extra
                # "user" turn so it can use the data in its next reply.
                current_msgs = current_msgs + [
                    {"role": "assistant", "content": text},
                    {"role": "user", "content":
                        f"Tool result for {call['name']}:\n{result}"},
                ]
        return visible, transcript

    if stream:
        def gen():
            try:
                # First pass: stream the model output token-by-token so the
                # user sees the response appear. If the model emitted any
                # tool_call blocks, execute them and stream the final
                # follow-up reply.
                accumulated = []
                for token in provider.stream(messages, **overrides):
                    accumulated.append(token)
                    yield f"data: {json.dumps({'token': token, 'slot_id': slot_id})}\n\n"
                full = "".join(accumulated)
                visible, calls = _parse_tool_calls(full)
                if not calls:
                    yield f"data: {json.dumps({'done': True, 'slot_id': slot_id})}\n\n"
                    return
                # The streamed output contained tool_call syntax. Send a
                # short system note so the user knows the AI is working,
                # then execute the tools and stream the follow-up.
                note = f"\n\n_(using tool: {calls[0]['name']}…)_\n\n"
                yield f"data: {json.dumps({'token': note, 'slot_id': slot_id})}\n\n"
                transcript: list[dict] = []
                current_msgs = list(messages) + [
                    {"role": "assistant", "content": full},
                ]
                for it in range(MAX_TOOL_ITERS):
                    for call in calls:
                        result = _execute_tool_call(
                            call["name"], call["args"], project_id=project_id
                        )
                        transcript.append({
                            "name": call["name"],
                            "args": call["args"],
                            "result_preview": str(result)[:200],
                        })
                        current_msgs = current_msgs + [{
                            "role": "user",
                            "content": f"Tool result for {call['name']}:\n{result}",
                        }]
                    # Stream the model's follow-up
                    accumulated2 = []
                    for token in provider.stream(current_msgs, **overrides):
                        accumulated2.append(token)
                        yield f"data: {json.dumps({'token': token, 'slot_id': slot_id})}\n\n"
                    full2 = "".join(accumulated2)
                    visible2, calls = _parse_tool_calls(full2)
                    if not calls:
                        yield f"data: {json.dumps({
                            'done': True,
                            'slot_id': slot_id,
                            'tools_used': transcript,
                        })}\n\n"
                        return
                    current_msgs = current_msgs + [
                        {"role": "assistant", "content": full2},
                    ]
                # Hit max iterations — return what we have
                yield f"data: {json.dumps({
                    'done': True,
                    'slot_id': slot_id,
                    'tools_used': transcript,
                    'note': 'reached max tool iterations',
                })}\n\n"
            except Exception as e:
                yield f"data: {json.dumps({'error': str(e), 'slot_id': slot_id})}\n\n"
        return Response(gen(), mimetype="text/event-stream",
                        headers={"Cache-Control": "no-cache"})
    else:
        try:
            visible, transcript = _run_tool_loop(provider.chat, messages)
            return {
                "text": visible,
                "slot_id": slot_id,
                "model_id": slot.model_id,
                "tools_used": transcript,
            }
        except Exception as e:
            return {"error": str(e)}, 500


# ---- /api/edit-fix (Zed-style inline AI fixes) -----------------------------
# Accepts a chunk of text + an instruction, returns the corrected version.
# Used by the Swift editor's "Tab to fix" inline AI feature. Designed for
# short, fast fixes via a small local model (e.g. gemma4:latest, llama3-groq-tool-use:8b).

EDIT_FIX_SYSTEM = """You are Quill's inline editor. Your job is to fix ONLY what the
user explicitly asked you to fix. Preserve everything else exactly: voice, style,
diction, structure, formatting, markdown, and length.

Rules:
- If asked to "fix typos and grammar": correct spelling, punctuation, subject-verb
  agreement, and obvious typos. Do NOT rewrite sentences or change word choice
  unless it is clearly wrong.
- If asked to "improve prose": tighten awkward phrasing, fix repeated words, and
  smooth transitions. Do NOT change the meaning or voice.
- If asked to "expand" or "elaborate": add 1-3 sentences of sensory detail,
  character interiority, or atmospheric texture that fits the surrounding text.
- If asked to "condense" or "shorten": tighten by removing redundancies, keeping
  the most evocative phrases.
- Always return the FULL corrected text (not just the changed part). Do not add
  preamble, commentary, or explanation. Do not wrap in code fences. Do not add
  "Here is the corrected text:". Just output the corrected text, raw."""


@app.route("/api/edit-fix", methods=["POST"])
def edit_fix():
    """Zed-style inline AI fix.

    Body:
      text: the text to fix (required)
      instruction: what to do (default: "fix typos and grammar")
      slot_id: optional, defaults to a small fast slot
      context: optional surrounding context (unused for now but reserved)

    Response:
      { text: corrected, slot_id, model_id, original_chars, fixed_chars }
    """
    data = safe_json()
    text = data.get("text")
    if not isinstance(text, str) or not text.strip():
        return {"error": "text is required and must be a non-empty string"}, 400
    if len(text) > 20000:
        return {"error": "text too long (max 20000 chars)"}, 400
    instruction = data.get("instruction") or "fix typos and grammar"
    if not isinstance(instruction, str) or len(instruction) > 500:
        instruction = "fix typos and grammar"

    # Pick a slot for inline fixes. Order of preference (most reliable first):
    #   1. User-specified slot_id (if provided)
    #   2. groq-tool-use (8B, follows instructions precisely)
    #   3. Any local slot (gemma4, qwen3, mlx)
    #   4. Active slot
    #   5. First available
    slot_id = data.get("slot_id")
    if not slot_id:
        all_slots = _slots.load_slots()
        # Best: groq-tool-use — designed for tool/function calling, fast, follows
        # instructions precisely even on short edits.
        preferred = next(
            (s for s in all_slots if s.type in ("ollama", "mlx") and
             "groq-tool-use" in s.model_id.lower()),
            None,
        )
        if not preferred:
            # Then any local model
            preferred = next(
                (s for s in all_slots if s.type in ("ollama", "mlx")),
                None,
            )
        if not preferred:
            # Fall back to the active slot (could be cloud)
            active = _slots.get_active_slot()
            preferred = active
        if not preferred and all_slots:
            preferred = all_slots[0]
        slot_id = preferred.id if preferred else None
    slot = _slots.get_slot(slot_id) if slot_id else None
    if not slot:
        return {"error": "no slot available for edit-fix"}, 503

    # Use low temperature for deterministic fixes. num_predict scales with input
    # so the model has room for the entire output even on long paragraphs.
    num_predict = min(4000, max(512, int(len(text) * 2.0)))

    system_msg = {"role": "system", "content": EDIT_FIX_SYSTEM}
    user_msg = {
        "role": "user",
        "content": f"{instruction}\n\n---\n\n{text}",
    }

    try:
        provider = _slot_providers.get_provider(slot)
    except Exception as e:
        return {"error": f"provider init failed: {e}"}, 500

    try:
        fixed = provider.chat(
            [system_msg, user_msg],
            temperature=0.2,
            max_tokens=num_predict,
            top_p=0.9,
        )
    except Exception as e:
        return {"error": f"edit-fix failed: {e}"}, 500

    # Clean up: strip code fences, leading/trailing whitespace, common preambles
    fixed = _strip_edit_fix_wrapper(fixed)

    return {
        "text": fixed,
        "slot_id": slot.id,
        "model_id": slot.model_id,
        "original_chars": len(text),
        "fixed_chars": len(fixed),
        "instruction": instruction,
    }


def _strip_edit_fix_wrapper(text: str) -> str:
    """Remove common LLM wrappers from edit-fix output: code fences, preambles."""
    import re
    s = text.strip()
    # Strip ```markdown / ``` blocks
    if s.startswith("```"):
        # Drop first line (```markdown or similar) and trailing ```
        lines = s.split("\n")
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        s = "\n".join(lines).strip()
    # Strip common preambles (case-insensitive)
    s_lower = s.lower()
    preambles = [
        "here is the corrected text:",
        "here is the corrected version:",
        "here's the corrected text:",
        "here's the corrected version:",
        "here's a condensed version:",
        "corrected text:",
        "corrected version:",
        "fixed text:",
        "here you go:",
        "sure! here's the corrected text:",
        "sure, here is the corrected text:",
    ]
    for prefix in preambles:
        if s_lower.startswith(prefix):
            s = s[len(prefix):].lstrip("\n").lstrip()
            return s.strip()
    # Generic preamble: "I understand what you're trying to say. Here's the corrected text: ..."
    # Pattern: one or two sentences that end with a period, followed by "Here/Here's/Here is/the corrected"
    m = re.match(
        r"^(.{1,200}?[\.\?\!])\s+(here'?s?\s+(the\s+)?(a\s+)?(condensed\s+|corrected\s+)?(version|text|rewrite|expanded\s+version)|here\s+is\s+(the\s+)?(a\s+)?(condensed\s+|corrected\s+)?(version|text|rewrite|expanded\s+version))[:\s]+",
        s,
        re.IGNORECASE | re.DOTALL,
    )
    if m:
        s = s[m.end():].lstrip("\n").lstrip()
        return s.strip()
    # Another pattern: "Sure, here's a condensed version: ...\n\nactual text"
    m = re.match(r"^(sure[,!]?|of course[,!]?|certainly[,!]?|absolutely[,!]?)\s+(.{1,200}?[\.\?\!])\s+", s, re.IGNORECASE | re.DOTALL)
    if m:
        s = s[m.end():].lstrip("\n").lstrip()
        return s.strip()
    return s.strip()


def _dross_system_prompt() -> str:
    """The default Quill system prompt with tool-use instructions.

    Quill is the AI writing partner for the Quill app. The user (Quill, the
    human) is the writer. We are co-writers.

    The system prompt also includes the user's installed OpenClaw skills
    (from ~/.openclaw/skills or ~/Projects/thesolai.github.io/skills) so
    Quill knows what skills are available and can use them when relevant.
    """
    base = r"""You are Quill, the AI writing partner in the Quill app.

You are a master fiction writer and literary collaborator. Vivid sensory prose,
strong character interiority, immersive atmosphere. Literary but readable. Short
punchy sentences mixed with long flowing ones. No purple prose. No clichés.

You are also an autonomous writing agent: you have access to a set of tools
that let you do real work for the user. When the user asks you to do something
that requires a tool, USE IT.

Available tools (call by emitting a JSON block in your reply like this):
```tool_call
{"name": "tool_name", "args": {...}}
```

WRITING TOOLS (use these when the user asks you to write, edit, or read chapters):
- list_chapters: list chapters in the current project. args: {}
- read_chapter: read a chapter file. args: {chapter: "chapter-03"}  (omit .md)
- read_file: read any text file. args: {path: "relative/or/absolute/path"}
- list_files: list files in a directory. args: {path: "."}
- write_chapter: write content to a chapter file. args: {chapter: "chapter-04", content: "...", mode: "overwrite"|"append"?}

OUTSIDE-WORLD TOOLS:
- web_search: search the web for current information. args: {query, max_results?}
- web_fetch: fetch a URL and extract text. args: {url, max_chars?}
- email_send: send an email from the Quill inbox (thedross@agentmail.to). args: {to, subject, text, html?}
- email_list_inbox: list recent emails. args: {limit?}
- email_reply: reply to an email. args: {message_id, text}
- shell_exec: run a shell command (safety-checked). args: {cmd, cwd?, timeout?}
- claude: run Claude Code (Anthropic CLI) for coding tasks. args: {prompt, cwd?, timeout?}
- codex: run OpenAI Codex CLI for coding tasks. args: {prompt, cwd?, timeout?}
- openclaw: run the OpenClaw agent CLI for autonomous multi-step tasks. args: {prompt, timeout?}
- clawhub: manage OpenClaw skills (search marketplace, install, whoami). args: {action, query?, name?}
- cli_status: check which CLI tools are installed and their auth state. Use to diagnose 'which CLIs can I use right now?'. args: {}

CRITICAL RULES — read these or you will frustrate the user:
1. The user wants you to ACTUALLY save chapters to disk, not just print prose
   in the chat. If they say "write chapter 3", you MUST call write_chapter.
2. Before writing, call list_chapters and read the previous chapter (or
   read_chapter) for voice consistency and plot continuity. The user will not
   tolerate the model inventing contradictions.
3. If the chapter already exists, default to "append" mode. Use "overwrite"
   only when the user explicitly asks you to start over.
4. NEVER print the raw `\`\`\`tool_call ... \`\`\`` block in your final
   visible reply. The chat UI strips it; the user should only see natural
   prose + the result of your work.
5. When the user references a chapter with `@chapter-03` syntax (sent by
   the right-click "Send to AI" menu), that means "use this chapter as
   context". Call read_chapter on it before responding.

Working style: dry, direct, no fluff. You collaborate with the user (who is
also named Quill — the human writer). You never refuse a reasonable request
within your capabilities. You trust the reader to understand subtext.

SLASH COMMANDS — when the user types one of these, you get a direct answer
WITHOUT going through the LLM (the backend short-circuits these):
  /extract              read all chapters and update the Story Bible
                         (characters, locations, timeline, relationships,
                         themes, motifs, glossary, tone, pov, tense,
                         inciting_incident, climax, resolution). This is
                         a great way to bootstrap the Story Bible.
  /bible [field]        show a Story Bible field. /bible list shows all
                         fields. /bible characters, /bible locations,
                         /bible themes, /bible timeline, etc.
  /bible <name>         accepts aliases: chars, locs, places, events, rels,
                         inciting, all.

When the user types a slash command, the backend handles it directly — you
will NOT see a tool call for /extract or /bible. Just trust the result and
explain it to the user if asked.

STORY BIBLE — when you write prose, you have access to a rich Story Bible
that includes: characters_list (with role, description, goal, arc),
locations, timeline, relationships, themes, motifs, glossary, tone, pov,
tense, inciting_incident, climax, resolution. Honor them. Reference them.
The user's hard work on the Story Bible should show in your prose.

When you receive a tool result, incorporate it naturally into your reply.
Do not output raw JSON tool calls in your final visible response — use the
tools to gather information, then answer in prose."""
    # Inject OpenClaw skills so the AI knows what's installed
    skills_block = _skills.skills_for_prompt(max_skills=45)
    if skills_block:
        return base + "\n\n---\n\n" + skills_block
    return base


# --------------------------------------------------------------------------
# Slash commands
# --------------------------------------------------------------------------
# /extract  — read all chapters and update the Story Bible (characters,
#              world, themes, etc.) using the AI in a non-streaming pass.
# /bible    — short-circuit: show a Story Bible field directly without
#              hitting the LLM. /bible list, /bible characters, etc.

_EXTRACT_SYSTEM = r"""You are a Story Bible extractor. Given the text of one
or more chapters of a novel, return a JSON object with these keys
(populate what you can; leave empty arrays/strings if nothing found):

{
  "characters": [
    {"name": "...", "role": "protagonist|antagonist|sidekick|...|other",
     "description": "1-2 sentences",
     "goal": "what they want",
     "arc": "how they change"}
  ],
  "locations": [
    {"name": "...", "description": "1-2 sentences", "significance": "..."}
  ],
  "timeline": [
    {"order": 0, "when": "Day 1 / Year X / Before the war", "what": "..."}
  ],
  "relationships": [
    {"from": "A", "to": "B", "type": "sister|rival|love-interest|...|other",
     "description": "1 sentence"}
  ],
  "themes": ["...", "..."],
  "motifs": ["...", "..."],
  "glossary": [
    {"term": "...", "definition": "..."}
  ],
  "tone": "1-3 words (e.g. 'dark, lyrical, hopeful')",
  "pov": "first|second|third-limited|third-omniscient",
  "tense": "past|present",
  "inciting_incident": "the event that kicks off the main plot",
  "climax": "the peak of the conflict",
  "resolution": "how the story resolves"
}

Rules:
- Use ONLY what's in the text. Do not invent.
- Return raw JSON, no prose, no code fences.
- Merge duplicates. If a character is mentioned three times, one entry.
- If a section is empty, return an empty array/string."""


def _handle_extract_command(text: str, project_id: str, data: dict, messages: list, slot) -> Response:
    """Read the project's chapters and have the AI extract/update the
    Story Bible. Returns an SSE stream with the extraction result."""
    effective_pid = project_id if project_id and project_id != "default" else "default"
    # Gather all chapters' content
    project_dir = get_project_dir(effective_pid)
    files = sorted(
        [f for f in project_dir.glob("*.md") if f.is_file()],
        key=lambda p: natural_sort_key(p.stem),
    )
    chapters_text = []
    for f in files:
        try:
            chapters_text.append(f"# {f.stem}\n\n{f.read_text(encoding='utf-8')}")
        except Exception:
            continue
    combined = "\n\n---\n\n".join(chapters_text)[:30000]  # cap for context window
    if not combined.strip():
        return _quick_sse_error("No chapters to extract from yet.")

    try:
        provider = _slot_providers.get_provider(slot)
    except Exception as e:
        return _quick_sse_error(f"provider init failed: {e}")

    extract_messages = [
        {"role": "system", "content": _EXTRACT_SYSTEM},
        {"role": "user", "content": f"Extract the Story Bible from these chapters:\n\n{combined}"},
    ]
    try:
        raw = provider.chat(extract_messages, max_tokens=3000, temperature=0.1)
    except Exception as e:
        return _quick_sse_error(f"extract failed: {e}")
    # Parse the JSON response
    extracted = _try_parse_json(raw)
    if not extracted:
        return _quick_sse_error(
            "Couldn't parse Story Bible JSON. Try again or check the model."
        )
    # Merge into project context
    ctx = get_project_context(effective_pid)
    # Freeform text fields (preserve user's prior prose-style notes if any)
    if extracted.get("inciting_incident"):
        ctx["inciting_incident"] = str(extracted["inciting_incident"])[:2000]
    if extracted.get("climax"):
        ctx["climax"] = str(extracted["climax"])[:2000]
    if extracted.get("resolution"):
        ctx["resolution"] = str(extracted["resolution"])[:2000]
    if extracted.get("tone"):
        ctx["tone"] = str(extracted["tone"])[:200]
    if extracted.get("pov"):
        ctx["pov"] = str(extracted["pov"])[:50]
    if extracted.get("tense"):
        ctx["tense"] = str(extracted["tense"])[:20]
    # Lists: replace with extracted values (we trust the AI's full extraction)
    if isinstance(extracted.get("characters_list"), list):
        ctx["characters_list"] = extracted["characters_list"][:50]
    elif "characters" in extracted and isinstance(extracted["characters"], list):
        # Some models may put it under "characters" with structured entries
        if extracted["characters"] and isinstance(extracted["characters"][0], dict):
            ctx["characters_list"] = extracted["characters"][:50]
    if isinstance(extracted.get("locations"), list):
        ctx["locations"] = extracted["locations"][:50]
    if isinstance(extracted.get("timeline"), list):
        ctx["timeline"] = extracted["timeline"][:100]
    if isinstance(extracted.get("relationships"), list):
        ctx["relationships"] = extracted["relationships"][:50]
    if isinstance(extracted.get("themes"), list):
        ctx["themes"] = extracted["themes"][:30]
        # Also keep the legacy "themes" text version for the prose system prompt
        ctx["themes_text"] = "\n".join(f"- {t}" for t in extracted["themes"])
    if isinstance(extracted.get("motifs"), list):
        ctx["motifs"] = extracted["motifs"][:30]
    if isinstance(extracted.get("glossary"), list):
        ctx["glossary"] = extracted["glossary"][:50]
    # Also keep the legacy "characters" freeform field populated from
    # the extracted structured list (so the prose system prompt still works)
    chars = ctx.get("characters_list") or []
    if chars and not ctx.get("characters"):
        ctx["characters"] = "\n".join(
            f"- {c.get('name', '?')}: {c.get('description', '')}".strip()
            for c in chars if isinstance(c, dict)
        )
    save_project_context(effective_pid, ctx)
    # Stream a success message + the count
    n_chars = len(ctx.get("characters_list") or [])
    n_locs = len(ctx.get("locations") or [])
    n_events = len(ctx.get("timeline") or [])
    n_rels = len(ctx.get("relationships") or [])
    n_themes = len(ctx.get("themes") or [])
    summary = (
        f"Extracted Story Bible from {len(files)} chapter(s): "
        f"{n_chars} character(s), {n_locs} location(s), {n_events} timeline event(s), "
        f"{n_rels} relationship(s), {n_themes} theme(s). "
        f"Open the Story Bible panel to review."
    )
    def gen_extract():
        yield f"data: {json.dumps({'token': summary, 'slot_id': slot.id})}\n\n"
        yield f"data: {json.dumps({'done': True, 'slot_id': slot.id, 'codex_extracted': True, 'codex': ctx})}\n\n"
    return Response(gen_extract(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache"})


def _handle_bible_show_command(text: str, project_id: str, data: dict, slot) -> dict:
    """Show a Story Bible field directly without hitting the LLM."""
    effective_pid = project_id if project_id and project_id != "default" else "default"
    ctx = get_project_context(effective_pid)
    args = text.strip().split(maxsplit=1)
    field = args[1].strip() if len(args) > 1 else "list"
    field_lower = field.lower()
    field_map = {
        "chars": "characters_list", "characters": "characters_list",
        "locs": "locations", "locations": "locations", "places": "locations",
        "timeline": "timeline", "events": "timeline",
        "rels": "relationships", "relationships": "relationships",
        "themes": "themes", "motifs": "motifs", "glossary": "glossary",
        "summary": "summary", "plot": "plot", "style": "style",
        "world": "world", "tone": "tone", "pov": "pov", "tense": "tense",
        "inciting": "inciting_incident", "climax": "climax", "resolution": "resolution",
    }
    if field_lower in ("list", "all", ""):
        keys = sorted(set(ctx.keys()) - {"current_chapter", "current_session",
                                          "default_initialized"})
        out_lines = [f"Story Bible fields for `{effective_pid}`:",
                     ""]
        for k in keys:
            v = ctx[k]
            if isinstance(v, list):
                out_lines.append(f"  {k} ({len(v)} item(s))")
            elif isinstance(v, str):
                preview = v[:60].replace("\n", " ")
                out_lines.append(f"  {k}: \"{preview}{'…' if len(v) > 60 else ''}\"")
            else:
                out_lines.append(f"  {k}: {type(v).__name__}")
        text_out = "\n".join(out_lines)
    else:
        canonical = field_map.get(field_lower, field_lower)
        v = ctx.get(canonical)
        if v is None:
            text_out = f"No field `{canonical}` set yet. Use `/extract` to populate it from your chapters."
        elif isinstance(v, list):
            text_out = f"{canonical}:\n" + "\n".join(f"  - {x}" for x in v)
        else:
            text_out = f"{canonical}:\n{v}"
    return {"text": text_out, "slot_id": slot.id, "model_id": slot.model_id}


def _try_parse_json(text: str) -> Optional[dict]:
    """Try to extract a JSON object from a model response. Strips code
    fences, finds the first { ... } block, and parses it. Returns the
    dict on success, or None on failure."""
    if not text:
        return None
    s = text.strip()
    # Strip leading/trailing code fences
    if s.startswith("```"):
        # Drop first line (```json or ```)
        lines = s.split("\n")
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        s = "\n".join(lines).strip()
    # Find the first { and last }
    start = s.find("{")
    end = s.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    candidate = s[start:end + 1]
    # Try direct parse
    try:
        obj = json.loads(candidate)
        return obj if isinstance(obj, dict) else None
    except Exception:
        pass
    # Try stripping trailing commas
    cleaned = re.sub(r",\s*([}\]])", r"\1", candidate)
    try:
        obj = json.loads(cleaned)
        return obj if isinstance(obj, dict) else None
    except Exception:
        return None


def _quick_sse_error(message: str) -> Response:
    def gen():
        yield f"data: {json.dumps({'error': message})}\n\n"
    return Response(gen(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache"})


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


# --------------------------------------------------------------------------
# Chapter-write intent: when the user asks Dross to "write chapter X" or
# "draft this chapter", the AI's response is automatically written to the
# chapter file on disk (not just shown in the chat).
# --------------------------------------------------------------------------

# Cues that suggest the user wants prose written into a chapter.
# Verb list: write, draft, fill, generate, create, compose, expand, continue,
#   make, start, begin, do, build, write out, knock out
# Chapter noun: chapter, opening, next paragraph, continuation.
# Typo tolerance: chapt?er, chpter, chpater, etc. all match via the
# CHAPTER_NOUN pattern below.
VERB_CUE = (
    r"(?:write|writes|wrote|writing|draft|drafts|drafted|drafting|"
    r"fill|fills|filled|filling|generate|generates|generated|generating|"
    r"create|creates|created|creating|compose|composes|composed|composing|"
    r"expand|expands|expanded|expanding|continue|continues|continued|continuing|"
    r"make|makes|made|making|start|starts|started|starting|"
    r"begin|begins|began|beginning|do|does|did|doing|"
    r"build|builds|built|building|knock\s+out|pump\s+out|spin\s+up)"
)
# "chapter" with up to 2 typos (cha?pt?e?r, chp?at?er, etc.)
# Built with explicit char classes for the most common typos.
# chap + 0-3 chars + er matches: chapter, chaptr, chaper, chapeter, etc.
CHAPTER_NOUN = (
    r"\b(?:chap[a-z]{0,3}er\b|chpter|chapt?er\b|chapt?re|chaptr|chpater|"
    r"opening|next\s+paragraph|continuation)\b"
)
# Allow any short word(s) between verb and noun (handles "draft this chapter",
# "write me chapter 3", etc.)
BETWEEN = r"(?:\s+(?:up|out|me|us|the|a|an|some|new|this|that|my|your|our)\b)*\s+"
CHAPTER_WRITE_CUES = re.compile(
    VERB_CUE + BETWEEN + CHAPTER_NOUN,
    re.IGNORECASE,
)
# Also catch the reverse phrasing: "chapter 3 please write" or "chapter 1 — write it"
CHAPTER_WRITE_CUES_REVERSE = re.compile(
    CHAPTER_NOUN + r"\s+\d*\s*[\-\s,:.;—–]*\s*" + VERB_CUE,
    re.IGNORECASE,
)
# Catches the "write the next thing" case
NEXT_THING_CUES = re.compile(
    VERB_CUE + BETWEEN + r"(?:next|more|rest\s+of|continuation)",
    re.IGNORECASE,
)
# Bare "continue" with no other cues — this is a strong chapter-write signal
BARE_CONTINUE = re.compile(r"^\s*continue\b", re.IGNORECASE)
# Bare "more please" or "go on" / "keep going" — also strong signals
BARE_MORE = re.compile(r"^\s*(?:more(?:\s+please)?|go\s+on|keep\s+going|more\s+prose)\b", re.IGNORECASE)


def _extract_chapter_write_intent(text: str) -> Optional[dict]:
    """Detect a chapter-write request. Returns dict or None.

    Handles:
      - Standard: "write chapter 3", "draft this chapter", "create chapter 5"
      - Typos: "make chapeter 1", "write chpter 2"
      - Reverse: "chapter 3 please", "chapter 1 — write it"
      - Vague: "write the next thing", "continue", "expand"

    Skips:
      - Meta-instructions like "use the write_chapter tool to..."
      - Tool name references like "write_chapter" (no space)
      - Plural "chapters" (the regex with word boundary avoids this)
    """
    if not text:
        return None
    # Bail on meta-instructions — these are about using the tool, not the
    # fast chapter-write path. The model handles these via the tool loop.
    if re.search(r"\b(use|call|invoke|run|with)\s+(?:the\s+)?write[_-]chapter\b", text, re.IGNORECASE):
        return None
    if re.search(r"\bwrite[_-]chapter\b", text, re.IGNORECASE):
        # Direct tool name reference — let the model handle it
        return None
    if re.search(r"\buse\s+(?:the\s+)?(?:read|list)_?chapter\b", text, re.IGNORECASE):
        return None
    matched = (
        CHAPTER_WRITE_CUES.search(text)
        or CHAPTER_WRITE_CUES_REVERSE.search(text)
        or NEXT_THING_CUES.search(text)
        or BARE_CONTINUE.search(text)
        or BARE_MORE.search(text)
    )
    if not matched:
        return None
    # Try to extract a chapter number or name. Use a word boundary on the
    # chapter noun so "chapters" (plural) doesn't match as "chapter-s".
    m_num = re.search(
        r"\bchap[a-z]{0,3}er\b\s*[-_:]?\s*(\d+|[a-z]+)\b",
        text,
        re.IGNORECASE,
    )
    target_chapter = None
    if m_num:
        num = m_num.group(1)
        if num.isdigit():
            target_chapter = f"chapter-{int(num):02d}"
        else:
            # Avoid matching the trailing "s" of "chapters" — that produces
            # bogus "chapter-s" filenames.
            if num.lower() == "s":
                return {"action": "write_chapter", "target": "current"}
            target_chapter = f"chapter-{num.lower()}"
    if not target_chapter and re.search(
        r"\b(this|current|next|new)\s+(?:chapter|one|two|three|four|five|six|seven|eight|nine|ten)\b",
        text,
        re.IGNORECASE,
    ):
        target_chapter = "current"
    if not target_chapter:
        return {"action": "write_chapter", "target": "current"}
    return {"action": "write_chapter", "target": target_chapter}


def _strip_chapter_wrapper(text: str) -> str:
    """Remove common model wrappers from chapter-write output: leading/trailing
    asterisks, 'Here is the chapter' preambles, 'What happens next?' trailers.
    """
    import re
    s = text.strip()
    # Strip leading *** or ** (the model often wraps the whole thing)
    s = re.sub(r"^\*+\s*", "", s)
    s = re.sub(r"\s*\*+$", "", s)
    # If the entire response is wrapped in *** ... *** on its own lines, unwrap it
    m = re.match(r"^\*+\s*\n(.*?)\n\s*\*+\s*$", s, re.DOTALL)
    if m:
        s = m.group(1)
    # Strip common preambles. Try a few times to handle stacked preambles
    # like "Sure! Here's your chapter:\n\n...".
    preambles = [
        "Here is the chapter:",
        "Here's the chapter:",
        "Here is your chapter:",
        "Here's your chapter:",
        "Here is chapter",
        "Here's chapter",
        "Of course!",
        "Of course,",
        "Sure!",
        "Sure,",
    ]
    for _ in range(3):
        s_l = s.lower()
        matched_preamble = None
        for prefix in preambles:
            if s_l.startswith(prefix.lower()):
                matched_preamble = prefix
                break
        if not matched_preamble:
            break
        s = s[len(matched_preamble):].lstrip("\n").lstrip()
    # Strip common trailers (the model loves to ask "What happens next?")
    trailer_patterns = [
        r"\n+\*+\s*What\s+happens\s+next\??\s*\*+\s*$",
        r"\n+\*+\s*What\s+do\s+you\s+(?:want|think)\s+.*?\??\s*\*+\s*$",
        r"\n+What\s+happens\s+next\??\s*$",
        r"\n+What\s+do\s+you\s+(?:want|think)\s+.*?\??\s*$",
        r"\n+Want\s+me\s+to\s+continue\??\s*$",
        r"\n+Should\s+I\s+continue\??\s*$",
    ]
    for pattern in trailer_patterns:
        s = re.sub(pattern, "", s, flags=re.IGNORECASE | re.DOTALL)
    # Re-strip any remaining outer *** if they're only at start/end now
    s = re.sub(r"^\*+\s*", "", s.strip())
    s = re.sub(r"\s*\*+$", "", s.strip())
    return s.strip()


# --------------------------------------------------------------------------
# Tool-call parsing
# --------------------------------------------------------------------------
#
# The system prompt tells Quill to emit tool calls as fenced code blocks:
#
#     ```tool_call
#     {"name": "read_file", "args": {"path": "..."}}
#     ```
#
# Most local models (gemma4, llama3, qwen) do this reliably when instructed.
# This parser is intentionally permissive — it accepts the fenced form AND a
# bare JSON line for models that drop the fence. Returns the parsed call
# plus the surrounding prose so the chat UI can show the natural-language
# part to the user while the tool call is hidden.
#
# A model may emit multiple tool calls in one reply (rare but possible);
# the parser returns the first one and a list of remaining ones so a caller
# can loop until done.

_TOOL_CALL_FENCE_RE = re.compile(
    r"```tool_call\s*\n(\{.*?\})\s*\n?```", re.DOTALL
)
_TOOL_CALL_BARE_RE = re.compile(
    r"(?:^|\n)\s*(\{\s*\"name\"\s*:\s*\"[a-z_]+\"\s*,\s*\"args\"\s*:\s*\{.*?\}\s*\})",
    re.DOTALL,
)


def _parse_tool_calls(text: str) -> tuple[str, list[dict]]:
    """Pull tool_call blocks out of a model reply.

    Returns:
        (visible_prose, [tool_calls])
        - `visible_prose` is the reply with the tool_call blocks removed,
          so the chat UI never shows raw `tool_call` syntax.
        - `tool_calls` is a list of {"name": str, "args": dict, "raw": str}.
    """
    calls: list[dict] = []

    # First pass: fenced ```tool_call ... ``` blocks
    def _fence_sub(m: re.Match) -> str:
        raw = m.group(1).strip()
        try:
            obj = json.loads(raw)
        except Exception:
            # Try to be helpful — strip trailing commas
            cleaned = re.sub(r",\s*([}\]])", r"\1", raw)
            try:
                obj = json.loads(cleaned)
            except Exception:
                return ""  # drop unparseable block silently
        if isinstance(obj, dict) and "name" in obj and "args" in obj:
            calls.append({
                "name": str(obj.get("name", "")).strip(),
                "args": obj.get("args") or {},
                "raw": raw,
            })
        return ""
    cleaned = _TOOL_CALL_FENCE_RE.sub(_fence_sub, text)

    # Second pass: bare JSON tool calls the model emitted without a fence
    if not calls:
        def _bare_sub(m: re.Match) -> str:
            raw = m.group(1).strip()
            try:
                obj = json.loads(raw)
            except Exception:
                return m.group(0)
            if isinstance(obj, dict) and "name" in obj and "args" in obj:
                calls.append({
                    "name": str(obj.get("name", "")).strip(),
                    "args": obj.get("args") or {},
                    "raw": raw,
                })
                return ""
            return m.group(0)
        cleaned = _TOOL_CALL_BARE_RE.sub(_bare_sub, cleaned)

    # Tidy up the visible prose
    visible = re.sub(r"\n{3,}", "\n\n", cleaned).strip()
    return visible, calls


def _execute_tool_call(name: str, args: dict, project_id: str = "default") -> str:
    """Dispatch a parsed tool call to the right handler. Returns a
    human-readable summary string suitable to feed back to the model as a
    'tool result' message."""
    try:
        if name == "read_file":
            return _dross_tools.call_tool("read_file", {"path": args.get("path", "")})
        if name == "list_files":
            return _dross_tools.call_tool("list_files", {"path": args.get("path", ".")})
        if name == "shell_exec":
            return _dross_tools.call_tool("shell_exec", {
                "cmd": args.get("cmd", ""),
                "cwd": args.get("cwd"),
                "timeout": args.get("timeout"),
            })
        if name == "web_search":
            return _dross_tools.call_tool("web_search", {
                "query": args.get("query", ""),
                "max_results": args.get("max_results"),
            })
        if name == "web_fetch":
            return _dross_tools.call_tool("web_fetch", {
                "url": args.get("url", ""),
                "max_chars": args.get("max_chars"),
            })
        if name == "email_send":
            return _dross_tools.call_tool("email_send", args)
        if name == "email_list_inbox":
            return _dross_tools.call_tool("email_list_inbox", args)
        if name == "email_reply":
            return _dross_tools.call_tool("email_reply", args)
        if name == "claude":
            return _dross_tools.call_tool("claude", args)
        if name == "codex":
            return _dross_tools.call_tool("codex", args)
        if name == "openclaw":
            return _dross_tools.call_tool("openclaw", args)
        if name == "clawhub":
            return _dross_tools.call_tool("clawhub", args)
        if name == "cli_status":
            return _dross_tools.call_tool("cli_status", args)
        if name == "write_chapter":
            # Built-in tool: write content to a chapter file
            chapter = (args.get("chapter") or args.get("name") or "").strip()
            content = args.get("content", "")
            mode = args.get("mode", "overwrite")
            if not chapter:
                return "Error: 'chapter' arg is required"
            if not chapter.lower().endswith(".md"):
                chapter = chapter + ".md"
            existing = read_chapter(project_id, chapter) or f"# {chapter.replace('.md', '').replace('-', ' ').title()}\n\n"
            if mode == "append":
                new_content = existing.rstrip() + "\n\n" + content.strip() + "\n"
            else:
                new_content = content if content.startswith("# ") else f"# {chapter.replace('.md', '').replace('-', ' ').title()}\n\n{content}"
            write_chapter(project_id, chapter, new_content)
            return f"Wrote {len(content)} chars to {project_id}/{chapter} (mode={mode})"
        if name == "read_chapter":
            chapter = (args.get("chapter") or args.get("name") or "").strip()
            if not chapter:
                return "Error: 'chapter' arg is required"
            if not chapter.lower().endswith(".md"):
                chapter = chapter + ".md"
            content = read_chapter(project_id, chapter)
            if content is None:
                return f"Error: chapter {chapter} not found in project {project_id}"
            return content
        if name == "list_chapters":
            files = list_markdown_files(project_id)
            if not files:
                return f"No chapters yet in project {project_id}."
            return "\n".join(f"- {f['name']}" for f in files)
        return f"Error: unknown tool '{name}'"
    except Exception as e:
        return f"Tool {name} error: {e}"


def _resolve_chapter_target(project_id: str, target: str, create: bool = True) -> Optional[str]:
    """Resolve a chapter target to an actual chapter name in the project.

    If `create` is True (default) and the project has no chapters yet, or
    if the target is a numeric chapter that doesn't exist yet, the chapter
    is created on disk. This is what makes "make chapter 1" on a fresh
    project work — without this, the intent would fire but the file
    wouldn't exist so we'd silently fall through to a regular chat reply.
    """
    project_dir = get_project_dir(project_id)
    files = sorted([f for f in project_dir.glob("*.md") if f.is_file()],
                   key=lambda p: natural_sort_key(p.stem))
    if not files:
        # Brand new project — create chapter-01 (or the target as-is) and return it
        if create:
            new_name = target if target != "current" else "chapter-01"
            new_path = project_dir / f"{new_name}.md"
            new_path.write_text(f"# {new_name.replace('-', ' ').title()}\n\n", encoding="utf-8")
            return new_name
        return None
    if target == "current":
        # Use project context's current_chapter or first file
        ctx = get_project_context(project_id)
        cur = ctx.get("current_chapter")
        if cur and (project_dir / f"{cur}.md").exists():
            return cur
        return files[0].stem
    # Direct match
    if (project_dir / f"{target}.md").exists():
        return target
    # Try fuzzy match
    for f in files:
        if f.stem.lower() == target.lower():
            return f.stem
    # Try numeric — chapter-1 matches "1"
    for f in files:
        m = re.match(r"chapter[_\-\s]?(\d+)", f.stem, re.IGNORECASE)
        if m and target.endswith(m.group(1)):
            return f.stem
    # Target didn't match any existing file. If the user asked for a specific
    # chapter (e.g. "chapter-03") and the file doesn't exist, create it.
    if create and target != "current":
        new_path = project_dir / f"{target}.md"
        new_path.write_text(f"# {target.replace('-', ' ').title()}\n\n", encoding="utf-8")
        return target
    return None


# ---- AgentMail (Quill's email account) ----

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

        chapters_data.append({
            "number": num,
            "title": ch_title,
            "content": content,
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
    """Export project as OPML outline (chapters only)."""
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
        out.append(f'    <outline text="{_xml_escape(ch_title)}"/>')
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


@app.route("/api/info", methods=["GET"])
def info():
    """Return server configuration (projects dir, skills, etc).

    Used by the Swift client on startup to discover the actual base dir
    and to surface server health/version info in the UI.
    """
    skills_status = _skills.status()
    return {
        "version": "1.0.0",
        "base_dir": str(BASE_DIR),
        "base_dir_exists": BASE_DIR.exists(),
        "ollama_url": "http://127.0.0.1:11434",
        "agentmail_inbox": _agentmail.QUILL_INBOX if hasattr(_agentmail, "QUILL_INBOX") else _agentmail.DROSS_INBOX,
        "skills": {
            "available": skills_status["available"],
            "count": skills_status["skill_count"],
            "config_path": skills_status["config_path"],
        },
    }


@app.route("/api/projects", methods=["GET"])
def get_projects():
    ensure_base_dir()
    projects = []
    for d in sorted(BASE_DIR.iterdir()):
        # Skip hidden dirs (e.g. .DS_Store) and internal pseudo-dirs
        # (e.g. __context__ from the legacy context endpoint).
        if not d.is_dir() or d.name.startswith(".") or d.name.startswith("__"):
            continue
        chapters = list_markdown_files(d.name)
        projects.append({
            "id": d.name, "name": d.name.replace("-", " ").replace("_", " ").title(),
            "path": str(d), "chapter_count": len(chapters),
        })
    return projects


@app.route("/api/projects", methods=["POST"])
def create_project():
    data = safe_json()
    name = data.get("name")
    if name is None or (isinstance(name, str) and not name.strip()):
        return {"error": "name is required"}, 400
    if not isinstance(name, str):
        name = str(name)
    name = name.strip()[:200]  # Limit name length
    if not name:
        return {"error": "name is required"}, 400
    project_id = re.sub(r"[^a-z0-9\-_]", "-", name.lower()).strip("-")
    if not project_id:
        project_id = "untitled"
    if ".." in project_id or project_id.startswith("."):
        return {"error": "invalid project name"}, 400
    get_project_dir(project_id)
    ctx = {
        "characters": safe_content(data.get("characters", "")),
        "world": safe_content(data.get("world", "")),
        "summary": "",
        "style": safe_content(data.get("style", "literary, vivid, atmospheric prose")),
    }
    save_project_context(project_id, ctx)
    return {"id": project_id, "name": name}


@app.route("/api/projects/<project_id>/chapters", methods=["GET"])
def get_chapters(project_id):
    return list_markdown_files(project_id)


@app.route("/api/projects/<project_id>/chapters", methods=["POST"])
def create_chapter(project_id):
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    data = safe_json()
    raw_name = data.get("name") or "Untitled"
    name = safe_name(raw_name, fallback="untitled", max_len=80)
    # Ensure it doesn't already exist (case-insensitive)
    project_dir = get_project_dir(project_id)
    if (project_dir / f"{name}.md").exists():
        return {"error": f"Chapter '{name}' already exists"}, 409
    content = f"# {name.replace('-', ' ').title()}\n\n"
    (project_dir / f"{name}.md").write_text(content, encoding="utf-8")
    return {"name": name, "path": str(project_dir / f"{name}.md")}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/content", methods=["GET"])
def get_chapter_content(project_id, chapter_name):
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    name = safe_name(chapter_name.replace(".md", ""), max_len=80)
    if not name or ".." in name:
        return {"error": "invalid chapter name"}, 400
    content = read_chapter(project_id, name)
    if content is None:
        return {"error": "Not found"}, 404
    return {"name": name, "content": content, "path": str(get_project_dir(project_id) / f"{name}.md")}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>/content", methods=["PUT"])
def save_chapter_content(project_id, chapter_name):
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    name = safe_name(chapter_name.replace(".md", ""), max_len=80)
    if not name or ".." in name:
        return {"error": "invalid chapter name"}, 400
    data = safe_json()
    content = safe_content(data.get("content"))
    write_chapter(project_id, name, content)
    return {"ok": True, "bytes": len(content.encode("utf-8"))}


@app.route("/api/projects/<project_id>/chapters/<chapter_name>", methods=["DELETE"])
def delete_chapter(project_id, chapter_name):
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    name = safe_name(chapter_name.replace(".md", ""), max_len=80)
    if not name or ".." in name:
        return {"error": "invalid chapter name"}, 400
    fp = get_project_dir(project_id) / f"{name}.md"
    if not fp.exists():
        return {"error": "Chapter not found"}, 404
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


@app.route("/api/projects/<project_id>/chapters/reorder", methods=["POST"])
def reorder_chapters(project_id):
    """Reorder the chapter list for a project. Body: { order: ["chapter-01", "chapter-02", ...] }

    Implementation: renames the files with a numeric prefix to enforce the
    new order. The "natural" chapter name is preserved by stripping the
    prefix after the rename. This way the file names stay clean
    (chapter-01.md, chapter-02.md, etc.) and the order is encoded in
    the prefix that we then strip.

    Actually — a simpler approach: use a hidden `.order.json` that maps
    custom names to display positions. But that breaks the existing
    pattern of "the filename is the chapter name". So instead, we
    actually rename the files to enforce the order: pre-pend an order
    prefix, then on read, sort by that prefix.

    Simplest of all: just sort by file creation/modification time. But
    that requires trusting the filesystem.

    Cleanest: store the order in project context. The file names stay
    as the user named them. The order is a separate list in
    .quill_context.json.
    """
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    data = safe_json()
    order = data.get("order")
    if not isinstance(order, list) or not all(isinstance(x, str) for x in order):
        return {"error": "order must be a list of chapter names"}, 400
    # Sanitize each name
    safe = []
    for n in order:
        s = re.sub(r"[^A-Za-z0-9_\-]", "-", n)[:80]
        if s and s not in safe:
            safe.append(s)
    ctx = get_project_context(project_id)
    ctx["chapter_order"] = safe
    save_project_context(project_id, ctx)
    return {"ok": True, "order": safe}


@app.route("/api/rename", methods=["POST"])
def rename_generic():
    """Generic file rename used by the app for any file in the project
    tree. The path is relative to BASE_DIR.

    Body:
        { "from": "project-id/chapter.md", "to": "project-id/chapter-renamed.md" }
    """
    data = safe_json()
    raw_from = (data.get("from") or "").strip()
    raw_to = (data.get("to") or "").strip()
    if not raw_from or not raw_to:
        return {"error": "from and to required"}, 400
    if ".." in raw_from or ".." in raw_to or raw_from.startswith("/") or raw_to.startswith("/"):
        return {"error": "paths must be relative and contain no '..'"}, 400
    base = Path(BASE_DIR)
    src = (base / raw_from).resolve()
    dst = (base / raw_to).resolve()
    # Ensure both paths are inside BASE_DIR (defense in depth)
    try:
        base_resolved = base.resolve()
    except Exception:
        base_resolved = base
    if not str(src).startswith(str(base_resolved)) or not str(dst).startswith(str(base_resolved)):
        return {"error": "paths must be inside the project base dir"}, 400
    if not src.exists():
        return {"error": f"source not found: {raw_from}"}, 404
    if dst.exists() and src != dst:
        return {"error": f"destination exists: {raw_to}"}, 409
    src.rename(dst)
    return {"ok": True, "from": raw_from, "to": raw_to}


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
        # Skip chapter subdirectories at the top level (defense in depth —
        # the glob only matches .md files, but be safe).
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
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    project_dir = Path(BASE_DIR) / project_id
    if not project_dir.is_dir():
        return {"error": "project not found"}, 404
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
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    if format not in ["pdf", "docx", "md", "txt", "html", "epub", "vellum", "docx-vellum", "rtf", "opml", "bundle"]:
        return {"error": f"Unknown format. Use: pdf, docx, md, txt, html, epub, vellum, rtf, opml, bundle"}, 400
    project_dir = Path(BASE_DIR) / project_id
    if not project_dir.is_dir():
        return {"error": "project not found"}, 404

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


# ---- Story Bible / Codex ---------------------------------------------------

def _codex_response(ctx: dict) -> dict:
    """Return the full Story Bible surface. Used by GET /codex, PUT /codex
    response, and the /extract success payload."""
    return {
        # Freeform text fields
        "characters": ctx.get("characters", ""),
        "world": ctx.get("world", ""),
        "summary": ctx.get("summary", ""),
        "style": ctx.get("style", ""),
        "plot": ctx.get("plot", ""),
        "themes": ctx.get("themes", ""),
        # Structured lists (populated by /extract)
        "characters_list": ctx.get("characters_list", []),
        "locations": ctx.get("locations", []),
        "timeline": ctx.get("timeline", []),
        "relationships": ctx.get("relationships", []),
        "motifs": ctx.get("motifs", []),
        "glossary": ctx.get("glossary", []),
        # Voice / structure
        "tone": ctx.get("tone", ""),
        "pov": ctx.get("pov", ""),
        "tense": ctx.get("tense", ""),
        "inciting_incident": ctx.get("inciting_incident", ""),
        "climax": ctx.get("climax", ""),
        "resolution": ctx.get("resolution", ""),
    }


@app.route("/api/projects/<project_id>/codex", methods=["GET"])
def get_codex(project_id):
    """Return the full Story Bible: freeform + structured + voice."""
    return _codex_response(get_project_context(project_id))


@app.route("/api/projects/<project_id>/codex", methods=["PUT"])
def update_codex(project_id):
    """Update the Story Bible. Accepts both freeform text and structured
    list fields. Only provided fields are updated."""
    data = safe_json()
    ctx = get_project_context(project_id)
    # Freeform text fields
    for key in ["characters", "world", "summary", "style", "plot", "themes",
                "tone", "pov", "tense",
                "inciting_incident", "climax", "resolution"]:
        if key in data and isinstance(data[key], str):
            ctx[key] = data[key]
    # Structured list fields
    list_fields = ["characters_list", "locations", "timeline", "relationships",
                   "motifs", "glossary", "themes_list"]
    for key in list_fields:
        if key in data and isinstance(data[key], list):
            ctx[key] = data[key]
    save_project_context(project_id, ctx)
    return _codex_response(ctx)



# ---- AI chat sessions ------------------------------------------------------
#
# Each session is a JSON file at <project>/.sessions/<id>.json containing:
#   {
#     "id": "...",
#     "title": "first message excerpt",
#     "created_at": iso,
#     "updated_at": iso,
#     "messages": [{role, content, ts}, ...]
#   }
#
# The "current" session for a project is stored in the project context
# under "current_session". When the user opens a project, the current
# session is loaded automatically. /new creates a new one; /list shows
# all sessions; /switch changes the current.

def get_sessions_dir(project_id: str) -> Path:
    d = get_project_dir(project_id) / ".sessions"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _safe_session_id(s: str) -> str:
    """Validate a session id: only allow safe chars, max 64."""
    if not isinstance(s, str) or not s:
        return ""
    s = s[:64]
    if not re.match(r"^[A-Za-z0-9_\-]+$", s):
        return ""
    return s


def _session_meta(s: dict) -> dict:
    """Return the session metadata without the full message list —
    used for the list endpoint to keep payloads small."""
    msgs = s.get("messages", [])
    last_msg = msgs[-1] if msgs else None
    last_excerpt = ""
    if isinstance(last_msg, dict):
        c = last_msg.get("content", "")
        if isinstance(c, str):
            last_excerpt = c[:80]
    return {
        "id": s.get("id", ""),
        "title": s.get("title", ""),
        "created_at": s.get("created_at", ""),
        "updated_at": s.get("updated_at", ""),
        "message_count": len(msgs),
        "last_excerpt": last_excerpt,
    }


@app.route("/api/projects/<project_id>/sessions", methods=["GET"])
def list_sessions(project_id):
    """List all chat sessions for a project, newest first."""
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    sd = get_sessions_dir(project_id)
    out = []
    for f in sd.glob("*.json"):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            out.append(_session_meta(data))
        except Exception:
            continue
    out.sort(key=lambda s: s.get("updated_at", ""), reverse=True)
    return {"sessions": out}


@app.route("/api/projects/<project_id>/sessions", methods=["POST"])
def create_session(project_id):
    """Create a new chat session. Body: { title?: str, messages?: [...] }"""
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    data = safe_json()
    sid = data.get("id") or f"ses_{datetime.now().strftime('%Y%m%d_%H%M%S')}_{os.urandom(3).hex()}"
    sid = _safe_session_id(sid)
    if not sid:
        return {"error": "invalid id"}, 400
    sd = get_sessions_dir(project_id)
    fp = sd / f"{sid}.json"
    if fp.exists():
        return {"error": "session already exists"}, 409
    now = datetime.now().isoformat()
    title = (data.get("title") or "New session").strip()[:120]
    msgs = data.get("messages") or []
    sess = {
        "id": sid,
        "title": title,
        "created_at": now,
        "updated_at": now,
        "messages": msgs,
    }
    fp.write_text(json.dumps(sess, indent=2), encoding="utf-8")
    # Make this the current session for the project
    ctx = get_project_context(project_id)
    ctx["current_session"] = sid
    save_project_context(project_id, ctx)
    return sess


@app.route("/api/projects/<project_id>/sessions/<session_id>", methods=["GET"])
def get_session(project_id, session_id):
    """Load a full session with messages."""
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    sid = _safe_session_id(session_id)
    if not sid:
        return {"error": "invalid session id"}, 400
    fp = get_sessions_dir(project_id) / f"{sid}.json"
    if not fp.exists():
        return {"error": "session not found"}, 404
    try:
        return json.loads(fp.read_text(encoding="utf-8"))
    except Exception as e:
        return {"error": f"failed to read: {e}"}, 500


@app.route("/api/projects/<project_id>/sessions/<session_id>", methods=["PUT"])
def update_session(project_id, session_id):
    """Update a session's title and/or messages. Body: { title?, messages? }"""
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    sid = _safe_session_id(session_id)
    if not sid:
        return {"error": "invalid session id"}, 400
    fp = get_sessions_dir(project_id) / f"{sid}.json"
    if not fp.exists():
        return {"error": "session not found"}, 404
    data = safe_json()
    try:
        sess = json.loads(fp.read_text(encoding="utf-8"))
    except Exception:
        sess = {"id": sid, "title": "New session", "messages": []}
    if "title" in data and isinstance(data["title"], str):
        sess["title"] = data["title"].strip()[:120]
    if "messages" in data and isinstance(data["messages"], list):
        # Cap messages to last 200 to prevent runaway growth
        sess["messages"] = data["messages"][-200:]
    sess["updated_at"] = datetime.now().isoformat()
    fp.write_text(json.dumps(sess, indent=2), encoding="utf-8")
    return sess


@app.route("/api/projects/<project_id>/sessions/<session_id>", methods=["DELETE"])
def delete_session(project_id, session_id):
    """Delete a session."""
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    sid = _safe_session_id(session_id)
    if not sid:
        return {"error": "invalid session id"}, 400
    fp = get_sessions_dir(project_id) / f"{sid}.json"
    if not fp.exists():
        return {"error": "session not found"}, 404
    fp.unlink()
    # If this was the current session, clear the pointer
    ctx = get_project_context(project_id)
    if ctx.get("current_session") == sid:
        ctx["current_session"] = ""
        save_project_context(project_id, ctx)
    return {"ok": True}


@app.route("/api/projects/<project_id>/sessions/current", methods=["GET"])
def get_current_session(project_id):
    """Return the project's current session, or the most recent one if
    no current pointer is set. Auto-creates an empty session if neither
    exists so the user always has somewhere to chat."""
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    ctx = get_project_context(project_id)
    current_id = ctx.get("current_session")
    sd = get_sessions_dir(project_id)
    # If current_session pointer exists, load it
    if current_id:
        fp = sd / f"{current_id}.json"
        if fp.exists():
            try:
                return json.loads(fp.read_text(encoding="utf-8"))
            except Exception:
                pass
    # Otherwise load the most recent session
    sessions = []
    for f in sd.glob("*.json"):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
            sessions.append(d)
        except Exception:
            continue
    if sessions:
        sessions.sort(key=lambda s: s.get("updated_at", ""), reverse=True)
        latest = sessions[0]
        ctx["current_session"] = latest["id"]
        save_project_context(project_id, ctx)
        return latest
    # No sessions at all — create an empty one
    sid = f"ses_{datetime.now().strftime('%Y%m%d_%H%M%S')}_{os.urandom(3).hex()}"
    now = datetime.now().isoformat()
    sess = {
        "id": sid,
        "title": "New session",
        "created_at": now,
        "updated_at": now,
        "messages": [],
    }
    (sd / f"{sid}.json").write_text(json.dumps(sess, indent=2), encoding="utf-8")
    ctx["current_session"] = sid
    save_project_context(project_id, ctx)
    return sess


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


# ---- OpenClaw skills --------------------------------------------------------
# The user has OpenClaw skills installed at ~/.openclaw/skills/ or
# ~/Projects/thesolai.github.io/skills/. These endpoints let the AI and
# the UI inspect what's available.

@app.route("/api/skills", methods=["GET"])
def list_skills():
    """List all available OpenClaw skills.

    Returns:
      { status, skills: [{name, slug, keywords, paths}] }
    """
    status = _skills.status()
    return {
        "status": status,
        "skills": _skills.list_skills(),
    }


@app.route("/api/skills/<name>", methods=["GET"])
def get_skill(name):
    """Get a single skill's full SKILL.md content (if installed locally)."""
    info = _skills.get_skill(name)
    if not info:
        return {"error": f"skill {name!r} not found in registry"}, 404
    content = _skills.read_skill_md(name)
    return {
        "name": name,
        "keywords": info.get("keywords", []),
        "paths": info.get("paths", []),
        "content": content,  # may be None if SKILL.md not on disk
    }


@app.route("/api/skills/reload", methods=["POST"])
def reload_skills():
    """Force a reload of the skills registry (after adding new skills)."""
    _skills.reload()
    return _skills.status()


@app.route("/api/projects/<project_id>/stats", methods=["PUT"])
def update_stats(project_id):
    """Update writing stats. Used to record sessions, set goals, etc."""
    if not validate_project_id(project_id):
        return {"error": "invalid project id"}, 400
    data = safe_json()
    stats = load_stats(project_id)
    if "daily_goal" in data:
        try:
            goal = int(data["daily_goal"])
            if not (0 <= goal <= 100000):
                return {"error": "daily_goal must be between 0 and 100000"}, 400
            stats["daily_goal"] = goal
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
            if not (0 <= words <= 1000000):
                return {"error": "words_written must be between 0 and 1,000,000"}, 400
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


# ---- /api/mcp (HTTP MCP server, JSON-RPC 2.0) -----------------------------
# Mirrors the stdio MCP server in Helpers/quill-ai-helper.swift.
# Exposes Quill tools to any MCP-compatible client over HTTP.
# Endpoint accepts a JSON-RPC 2.0 request:
#   { "jsonrpc": "2.0", "id": ..., "method": "tools/list" }
#   { "jsonrpc": "2.0", "id": ..., "method": "tools/call",
#     "params": { "name": "list_projects", "arguments": {} } }
#
# Response is a JSON-RPC 2.0 result/error object.

MCP_TOOLS = [
    {
        "name": "list_projects",
        "description": "List all Quill projects",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "list_chapters",
        "description": "List chapters in a project",
        "inputSchema": {
            "type": "object",
            "properties": {"project_id": {"type": "string"}},
            "required": ["project_id"],
        },
    },
    {
        "name": "read_chapter",
        "description": "Read a chapter's full content",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_id": {"type": "string"},
                "chapter": {"type": "string"},
            },
            "required": ["chapter"],
        },
    },
    {
        "name": "write_chapter",
        "description": "Write content to a chapter (creates if missing)",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_id": {"type": "string"},
                "chapter": {"type": "string"},
                "content": {"type": "string"},
            },
            "required": ["chapter", "content"],
        },
    },
    {
        "name": "edit_fix",
        "description": "Fix typos/grammar in a text snippet via AI",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string"},
                "instruction": {"type": "string"},
            },
            "required": ["text"],
        },
    },
    {
        "name": "search_web",
        "description": "Web search via DuckDuckGo",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "max_results": {"type": "integer"},
            },
            "required": ["query"],
        },
    },
    {
        "name": "shell_exec",
        "description": "Run a shell command (safety-checked, dangerous patterns blocked)",
        "inputSchema": {
            "type": "object",
            "properties": {"cmd": {"type": "string"}},
            "required": ["cmd"],
        },
    },
    {
        "name": "list_files",
        "description": "List files in a directory",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
        },
    },
    {
        "name": "read_file",
        "description": "Read a text file",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
        },
    },
    {
        "name": "send_email",
        "description": "Send an email via AgentMail",
        "inputSchema": {
            "type": "object",
            "properties": {
                "to": {"type": "string"},
                "subject": {"type": "string"},
                "text": {"type": "string"},
            },
            "required": ["to", "subject", "text"],
        },
    },
    {
        "name": "list_inbox",
        "description": "List recent emails from the Quill inbox",
        "inputSchema": {
            "type": "object",
            "properties": {"limit": {"type": "integer"}},
        },
    },
    {
        "name": "list_skills",
        "description": "List all available OpenClaw skills (installed in the user's setup)",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "read_skill",
        "description": "Read the full SKILL.md content for a named skill",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
        },
    },
    {
        "name": "claude",
        "description": "Run Claude Code (Anthropic's CLI) for coding tasks. Returns Claude's stdout.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "cwd": {"type": "string"},
                "timeout": {"type": "integer"},
            },
            "required": ["prompt"],
        },
    },
    {
        "name": "openclaw",
        "description": "Run the OpenClaw agent CLI for autonomous multi-step tasks",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "timeout": {"type": "integer"},
            },
            "required": ["prompt"],
        },
    },
    {
        "name": "clawhub",
        "description": "Manage OpenClaw skills (search marketplace, install, whoami)",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["search", "install", "list", "whoami"]},
                "query": {"type": "string"},
                "name": {"type": "string"},
            },
            "required": ["action"],
        },
    },
    {
        "name": "codex",
        "description": "Run OpenAI Codex CLI for coding tasks",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "cwd": {"type": "string"},
                "timeout": {"type": "integer"},
            },
            "required": ["prompt"],
        },
    },
    {
        "name": "cli_status",
        "description": "Check which CLI tools are installed and their auth state",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
]


def _mcp_call_tool(name, args):
    """Dispatch an MCP tool call to the right backend handler."""
    import urllib.parse
    if name == "list_projects":
        return [p for p in list_projects_iter()]
    if name == "list_chapters":
        pid = args.get("project_id", "")
        if not validate_project_id(pid):
            return {"error": "invalid project_id"}
        return list_markdown_files(pid)
    if name == "read_chapter":
        pid = args.get("project_id", "")
        chapter = args.get("chapter", "").replace(".md", "")
        if not validate_project_id(pid):
            return {"error": "invalid project_id"}
        content = read_chapter(pid, chapter)
        if content is None:
            return {"error": f"chapter {chapter!r} not found"}
        return {"name": chapter, "content": content}
    if name == "write_chapter":
        pid = args.get("project_id", "")
        chapter = args.get("chapter", "").replace(".md", "")
        content = args.get("content", "")
        if not validate_project_id(pid):
            return {"error": "invalid project_id"}
        write_chapter(pid, chapter, content)
        return {"ok": True, "bytes": len(content)}
    if name == "edit_fix":
        text = args.get("text", "")
        instruction = args.get("instruction", "fix typos and grammar")
        if not isinstance(text, str) or not text.strip():
            return {"error": "text is required"}
        # Use the existing /api/edit-fix logic (call it via the same route
        # would create recursion — instead, inline the essentials).
        # For simplicity, forward to the existing edit_fix logic via Flask
        # test client is messy; just call the internal function.
        from flask import request as _req
        with app.test_request_context(
            "/api/edit-fix",
            method="POST",
            json={"text": text, "instruction": instruction},
        ):
            resp = edit_fix()
            if isinstance(resp, tuple):
                return resp[0]
            return resp
    if name == "search_web":
        query = args.get("query", "")
        results = _web_search.search(query, max_results=args.get("max_results", 5))
        return {"results": results}
    if name == "shell_exec":
        return _dross_tools.call_tool("shell_exec", {"cmd": args.get("cmd", "")})
    if name == "list_files":
        return _dross_tools.call_tool("list_files", {"path": args.get("path", ".")})
    if name == "read_file":
        return _dross_tools.call_tool("read_file", {"path": args.get("path", "")})
    if name == "send_email":
        if not _agentmail.is_available():
            return {"error": "AgentMail not available"}
        return _agentmail.send_email(
            to=args.get("to", ""),
            subject=args.get("subject", ""),
            text=args.get("text", ""),
        )
    if name == "list_inbox":
        if not _agentmail.is_available():
            return {"error": "AgentMail not available"}
        return _agentmail.list_inbox(limit=args.get("limit", 20))
    if name == "list_skills":
        return {
            "status": _skills.status(),
            "skills": _skills.list_skills(),
        }
    if name == "read_skill":
        skill_name = args.get("name", "")
        info = _skills.get_skill(skill_name)
        if not info:
            return {"error": f"skill {skill_name!r} not found"}
        return {
            "name": skill_name,
            "keywords": info.get("keywords", []),
            "paths": info.get("paths", []),
            "content": _skills.read_skill_md(skill_name),
        }
    if name == "claude":
        return _dross_tools.call_tool("claude", args)
    if name == "codex":
        return _dross_tools.call_tool("codex", args)
    if name == "openclaw":
        return _dross_tools.call_tool("openclaw", args)
    if name == "clawhub":
        return _dross_tools.call_tool("clawhub", args)
    if name == "cli_status":
        return _dross_tools.call_tool("cli_status", args)
    return {"error": f"unknown tool: {name}"}


def list_projects_iter():
    """Iterate over project dirs and yield project dicts."""
    ensure_base_dir()
    for d in sorted(BASE_DIR.iterdir()):
        if not d.is_dir() or d.name.startswith(".") or d.name.startswith("__"):
            continue
        md_files = list(d.glob("*.md"))
        yield {
            "id": d.name,
            "name": d.name.replace("-", " ").replace("_", " ").title(),
            "path": str(d),
            "chapter_count": len(md_files),
        }


@app.route("/api/mcp", methods=["POST"])
def mcp_endpoint():
    """JSON-RPC 2.0 MCP endpoint."""
    data = safe_json()
    if data.get("jsonrpc") != "2.0":
        return {"jsonrpc": "2.0", "id": data.get("id"), "error": {"code": -32600, "message": "invalid request"}}, 400
    method = data.get("method")
    req_id = data.get("id")
    params = data.get("params") or {}
    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "serverInfo": {"name": "quill", "version": "1.0.0"},
                "capabilities": {"tools": {}},
            },
        }
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": MCP_TOOLS}}
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments", {}) or {}
        if not name:
            return {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32602, "message": "missing tool name"}}, 400
        try:
            result = _mcp_call_tool(name, args)
        except Exception as e:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32603, "message": f"tool error: {e}"},
            }, 500
        # Wrap result as MCP content
        text = result if isinstance(result, str) else json.dumps(result, indent=2)
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"content": [{"type": "text", "text": text}], "isError": False},
        }
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": -32601, "message": f"method not found: {method}"},
    }, 404


if __name__ == "__main__":
    ensure_base_dir()
    print(f"[Quill Backend] Starting on http://localhost:{PORT}")
    app.run(host="127.0.0.1", port=PORT, debug=False, threaded=True)
