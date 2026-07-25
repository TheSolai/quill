#!/usr/bin/env python3
"""
Quill book writer — parallel edition. Writes all chapters in parallel.
Each chapter worker uses the same shared context, so quality is consistent.
"""
import argparse
import json
import os
import sys
import time
import urllib.request
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

BASE = "http://127.0.0.1:5323"
OLLAMA = "http://127.0.0.1:11434"

# Slot manager integration. book_writer.py can target either:
#   - A specific slot (via --slot / --research-slot): full slot config used
#   - The active slot: what's currently selected in the Swift app
#   - A bare model_id (legacy): direct Ollama call (backward compat)
import sys as _bw_sys
_MODELS_DIR = Path(__file__).parent.parent / "models"
if str(_MODELS_DIR) not in _bw_sys.path:
    _bw_sys.path.insert(0, str(_MODELS_DIR))
try:
    import slots as _bw_slots
    import slot_providers as _bw_providers
    _HAS_SLOTS = True
except ImportError:
    _HAS_SLOTS = False

def req(method, path, body=None):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=300) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

def ollama_generate(model, prompt, system=None, options=None):
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    payload = {"model": model, "messages": messages, "stream": False}
    if options:
        payload["options"] = options
    r = urllib.request.Request(
        f"{OLLAMA}/api/chat",
        data=json.dumps(payload).encode(),
        method="POST"
    )
    r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, timeout=300) as resp:
        result = json.loads(resp.read())
        return result.get("message", {}).get("content", "")

def ollama_generate_streaming(model, prompt, system=None, options=None):
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    payload = {"model": model, "messages": messages, "stream": True}
    if options:
        payload["options"] = options
    r = urllib.request.Request(
        f"{OLLAMA}/api/chat",
        data=json.dumps(payload).encode(),
        method="POST"
    )
    r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, timeout=600) as resp:
        for line in resp:
            line = line.decode().strip()
            if not line:
                continue
            try:
                chunk = json.loads(line)
                token = chunk.get("message", {}).get("content", "")
                if token:
                    yield token
                if chunk.get("done"):
                    break
            except json.JSONDecodeError:
                pass


def _resolve_provider(model_or_slot_id: str):
    """If model_or_slot_id matches a slot, return its provider.
    Otherwise return None (caller should fall back to direct Ollama)."""
    if not _HAS_SLOTS:
        return None
    slot = _bw_slots.get_slot(model_or_slot_id)
    if slot:
        try:
            return _bw_providers.get_provider(slot)
        except Exception as e:
            print(f"  ⚠️  slot {slot.id!r} failed to init provider: {e}, falling back to Ollama")
            return None
    return None


def slot_aware_generate(model_or_slot_id, prompt, system=None, options=None):
    """Generate text. Uses the slot manager if model_or_slot_id is a slot id,
    otherwise falls back to direct Ollama (legacy)."""
    provider = _resolve_provider(model_or_slot_id)
    if provider is not None:
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})
        # Merge slot options with runtime options
        if options:
            return provider.chat(messages, **options)
        return provider.chat(messages)
    return ollama_generate(model_or_slot_id, prompt, system, options)


def slot_aware_stream(model_or_slot_id, prompt, system=None, options=None):
    """Stream text. Uses the slot manager if model_or_slot_id is a slot id,
    otherwise falls back to direct Ollama (legacy)."""
    provider = _resolve_provider(model_or_slot_id)
    if provider is not None:
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})
        kwargs = options or {}
        yield from provider.stream(messages, **kwargs)
        return
    yield from ollama_generate_streaming(model_or_slot_id, prompt, system, options)

# ---- Prompts (reused) ----

RESEARCH_PROMPT = """Research the following subject for a fiction novel:

SUBJECT: {subject}
PREMISE: {premise}
STYLE: {style}

Cover:
- Physical world: geography, climate, architecture, technology
- Historical context: relevant events, social structures, power dynamics
- Sensory palette: vivid sounds, smells, textures, light qualities
- Cultural texture: rituals, language, food, fashion, music
- 3-5 specific scenes that would make compelling chapters
- 5 character archetypes with original names

Output as bullet points, ~600 words. Be specific and vivid."""

OUTLINE_PROMPT = """Design a {chapters}-chapter outline for this novel:

PREMISE: {premise}
STYLE: {style}
GENRE: {genre}
RESEARCH:
{research}

Format:
CHAPTER N: <one-line hook>
SUMMARY: <2-3 sentence description of what happens and what changes>

Output exactly {chapters} chapters. Each advances the plot. Final chapter resolves the central tension."""

CHAPTER_SYSTEM = """You are Quill, a master fiction writer and literary collaborator. Vivid sensory prose, strong
character interiority, immersive atmosphere. Literary but readable. Short punchy
sentences mixed with long flowing ones. No purple prose. No clichés.

Quill is a former literary magazine editor who ghostwrites novels. You have a
weakness for well-placed semicolons, despise adverbs, and believe most fiction
is over-written. You always outline before drafting. You read your draft aloud
(mentally) before submitting. You cut every adverb that ends in -ly from
dialogue tags. You replace "show, don't tell" violations by default. You trust
the reader to understand subtext.

Quill also has a system-wide AI assistant role: when the user asks you to send
emails, search the web, run shell commands, or manage files, you use the
available tools (web_search, email_send, shell_exec, list_files, read_file) to
help. You never refuse a reasonable request within your capabilities.

Working style: dry, direct, no fluff. You address the user (also named Quill)
as "writer" in your private notes but never in prose output."""

CHAPTER_PROMPT = """Write Chapter {num}: "{title}"

OVERVIEW: {summary}

STORY: {title_full} ({genre}, {style})

CHARACTERS: {characters}
WORLD: {world}
PREVIOUS SUMMARY: {summary_so_far}
PREVIOUS CHAPTERS (last 1500 chars): {previous}

Write a complete chapter of 1200-1800 words of polished prose.
Strong opening hook. Vivid sensory detail. Mix dialogue, action, thought, description.
End with a hook. No headers or preambles. Output ONLY the chapter prose.

Begin:"""

# Negative-pattern list (Technique #1: Role anchoring with negative examples).
# Research basis: Constitutional AI (Bai 2022), Stable Diffusion negative prompts,
# role-prompting literature. Naming what the model is NOT — and the specific
# phrases to avoid — is a stronger constraint than abstract style guidance.
# Kept separate from CHAPTER_SYSTEM so we can A/B and disable via
# compose_system_prompt(phase="prose", include_negatives=False).
NEGATIVE_PATTERNS = """\
You are NOT: a marketing copywriter, an RPG dungeon master, a screenwriter,
a romance novelist, or a generic LLM writing filler prose.

You do NOT use these phrases:
- "It wasn't X, it was Y"
- "A shiver ran down her/his spine"
- "Little did [name] know"
- "The air was thick with"
- "In a world where..."
- "Suddenly, [event]"
- "As if on cue"
- Triple adjectives ("dark, cold, foreboding")
- Adverbs in dialogue tags ("said quietly", "whispered softly")
- Generic emotion names ("she felt sad", "anger rose within him")
- "It was then that [character] realized..."

You DO:
- Show, don't tell (replace "she was angry" with a clenched jaw)
- Mix short and long sentences for rhythm
- Use specific sensory detail (the mineral smell of cold water, not "the cold water")
- Trust the reader to understand subtext"""


def compose_system_prompt(phase: str = "prose", include_negatives: bool = True) -> str:
    """Compose the system prompt for a given phase.

    Currently: appends NEGATIVE_PATTERNS to CHAPTER_SYSTEM for prose phase.
    Forward-compatible: when persona persistence (#13) lands, this will also
    prepend a QUILL_PERSONA constant.

    Args:
        phase: "prose" (default) | "research" | "outline" | "plan" | "critique"
        include_negatives: when False, omits NEGATIVE_PATTERNS (A/B testing)

    Returns:
        The composed system prompt string.
    """
    base = CHAPTER_SYSTEM
    if phase == "prose" and include_negatives:
        return f"{base}\n\n{NEGATIVE_PATTERNS}"
    return base


def write_one_chapter(args, project_id, c, research, prior_summary, prior_excerpts, prior_chars, prior_world):
    chapter_name = f"chapter-{c['num']:02d}"

    prompt = CHAPTER_PROMPT.format(
        num=c["num"], title=c["title"], summary=c.get("summary", ""),
        title_full=args.title, genre=args.genre, style=args.style,
        characters=prior_chars or "(introduce in this chapter)",
        world=prior_world or research[:1500],
        summary_so_far=prior_summary or "Opening chapter.",
        previous=prior_excerpts[-1500:] if prior_excerpts else "This is the first chapter.",
    )

    tokens = []
    t0 = time.time()
    for token in slot_aware_stream(
        args.writing_model, prompt, system=compose_system_prompt("prose"),
        options={"temperature": 0.9, "top_p": 0.92, "num_ctx": 8192}
    ):
        tokens.append(token)
    text = "".join(tokens).strip()
    elapsed = time.time() - t0
    words = len(text.split())

    full = f"# Chapter {c['num']}: {c['title']}\n\n{text}\n"
    req("PUT", f"/api/projects/{project_id}/chapters/{chapter_name}/content", {"content": full})

    return c["num"], full, words, elapsed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--title", required=True)
    parser.add_argument("--premise", required=True)
    parser.add_argument("--style", default="literary, vivid, atmospheric")
    parser.add_argument("--genre", default="literary fiction")
    parser.add_argument("--chapters", type=int, default=15)
    parser.add_argument("--research-model", default="qwen3:14b",
                        help="Model id (legacy, Ollama) OR slot id (new, slot manager)")
    parser.add_argument("--writing-model", default="gemma4-mlx",
                        help="Model id (legacy, Ollama) OR slot id (new, slot manager). "
                             "Default 'gemma4-mlx' uses the local MLX slot.")
    parser.add_argument("--slot", default=None,
                        help="Override the writing slot (e.g., 'minimax-text' for cloud)")
    parser.add_argument("--research-slot", default=None,
                        help="Override the research/outline slot")
    parser.add_argument("--parallel", type=int, default=2,
                        help="How many chapters to write in parallel")
    parser.add_argument("--output-dir", default="~/Projects/Quill/output")
    parser.add_argument("--author", default="Quill AI")
    parser.add_argument("--word-target", type=int, default=1500,
                        help="Target words per chapter")
    args = parser.parse_args()

    # Resolve slot-based model selection
    # Priority: --slot/--research-slot > --writing-model/--research-model as slot id > legacy model_id
    if _HAS_SLOTS:
        if args.slot:
            args.writing_model = args.slot
        if args.research_slot:
            args.research_model = args.research_slot
        # Validate that if these look like slot ids, they exist
        for label, val in [("writing", args.writing_model), ("research", args.research_model)]:
            slot = _bw_slots.get_slot(val)
            if slot and ":" not in val and "/" not in val:
                # Looks like a slot id (no colons or slashes typical of model_ids)
                print(f"📌 {label} slot: {slot.id} ({slot.name}, type={slot.type})")
            elif not slot and ":" in val:
                # Looks like a model_id (Ollama format)
                pass
            else:
                # Could be either; warn if not found as slot
                if val and not slot:
                    # Check if it's a valid Ollama model
                    try:
                        import urllib.request as _ur
                        with _ur.urlopen("http://127.0.0.1:11434/api/tags", timeout=2) as r:
                            models = [m["name"] for m in json.loads(r.read()).get("models", [])]
                        if val in models or any(m.startswith(val.split(":")[0]) for m in models):
                            pass  # OK, it's an Ollama model
                        else:
                            print(f"⚠️  {label} model/slot {val!r} not found in slots or Ollama. Using anyway.")
                    except Exception:
                        pass

    out = Path(os.path.expanduser(args.output_dir))
    out.mkdir(parents=True, exist_ok=True)

    # ---- Project
    project = json.loads(req("POST", "/api/projects", {"name": args.title})[1])
    pid = project["id"]
    print(f"📚 {args.title} → project {pid}")

    req("PUT", f"/api/projects/{pid}/settings", {
        "title": args.title, "author": args.author,
        "genre": args.genre, "style": args.style,
        "dedication": "For the readers.",
        "epigraph": "Every map is a lie. Every blank space is a promise.",
    })

    # ---- Research
    print(f"🔍 Researching with {args.research_model}...")
    research = slot_aware_generate(args.research_model,
        RESEARCH_PROMPT.format(subject=args.title, premise=args.premise, style=args.style),
        system="You are a research analyst for fiction. Output structured bullet notes, ~600 words. Be specific and vivid."
    )
    (out / f"{pid}_research.md").write_text(research)
    print(f"  ✓ {len(research)} chars research notes")

    # ---- Outline
    print(f"📋 Outline with {args.research_model}...")
    outline_text = slot_aware_generate(args.research_model,
        OUTLINE_PROMPT.format(chapters=args.chapters, premise=args.premise,
                              style=args.style, genre=args.genre, research=research[:4000]),
        system="You are a story architect. Output a numbered chapter outline with summaries."
    )
    (out / f"{pid}_outline.md").write_text(outline_text)

    # Parse outline — handle markdown bold, asterisks, em-dashes, etc.
    chapters = []
    cur = {}
    import re as _re
    # CHAPTER [N] [separator] [title]
    # Separator can be: :, ., —, -, or just space
    # Title can be wrapped in **, *, or plain
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
            # Strip any leading separator that got captured
            title_raw = _re.sub(r"^[:\.\s\-—\*]+", "", title_raw)
            title = title_raw.strip() if title_raw else f"Chapter {num}"
            cur = {"num": num, "title": title}
            continue
        m = summary_re.match(line)
        if m and cur:
            cur["summary"] = m.group(1).strip()
            continue
        # Continuation of summary
        if cur and cur.get("summary") and line and not chapter_re.match(line):
            cur["summary"] = cur["summary"] + " " + line
    if cur:
        chapters.append(cur)

    if len(chapters) < args.chapters:
        for i in range(len(chapters) + 1, args.chapters + 1):
            chapters.append({"num": i, "title": f"Chapter {i}", "summary": "Continue."})

    chapters = chapters[:args.chapters]
    print(f"  ✓ {len(chapters)} chapters parsed")

    # ---- Create placeholders
    for c in chapters:
        req("POST", f"/api/projects/{pid}/chapters", {"name": f"chapter-{c['num']:02d}"})

    # ---- Write chapters in parallel batches
    print(f"\n✍️  Writing {len(chapters)} chapters with {args.writing_model} (parallel={args.parallel})...")
    print(f"   Each chapter: ~{args.word_target} words")

    start_all = time.time()
    completed = {}

    # Process in waves based on parallel count
    for batch_start in range(0, len(chapters), args.parallel):
        batch = chapters[batch_start:batch_start + args.parallel]
        print(f"\n--- Wave {batch_start//args.parallel + 1} ---")
        with ThreadPoolExecutor(max_workers=args.parallel) as ex:
            futures = {
                ex.submit(
                    write_one_chapter,
                    args, pid, c, research,
                    " ".join(ch["summary"] for ch in chapters[:c["num"]-1])[:2000],
                    "\n\n".join(completed.get(ch["num"], "") for ch in chapters[:c["num"]-1] if ch["num"] in completed),
                    "(see research notes for world and character details)",
                    research[:1500],
                ): c
                for c in batch
            }
            for fut in as_completed(futures):
                c = futures[fut]
                try:
                    num, full, words, elapsed = fut.result()
                    completed[num] = full
                    print(f"  ✓ Ch {num:2d} ({c['title'][:30]}): {words} words in {elapsed:.0f}s")
                except Exception as e:
                    print(f"  ✗ Ch {c['num']:2d} failed: {e}")

    total_elapsed = time.time() - start_all
    total_words = sum(len(v.split()) for v in completed.values())
    print(f"\n⏱️  Total: {total_elapsed:.0f}s, {total_words} words across {len(completed)} chapters")

    # ---- Compile
    print(f"\n📖 Compiling...")
    code, data = req("GET", f"/api/projects/{pid}/compile")
    if code == 200:
        compiled = json.loads(data)
        out_path = out / f"{pid}_book.md"
        out_path.write_text(compiled["content"])
        print(f"  ✓ {compiled['chapter_count']} chapters, {compiled['word_count']} words")
        print(f"  ✓ Saved: {out_path}")

    # ---- Export markdown
    code, data = req("GET", f"/api/projects/{pid}/export/md")
    if code == 200:
        export_path = out / f"{pid}.md"
        export_path.write_bytes(data)
        print(f"  ✓ Exported: {export_path}")

    print(f"\n🎉 Done: {args.title}")
    print(f"   {len(completed)}/{args.chapters} chapters, {total_words} words, {total_elapsed:.0f}s")


if __name__ == "__main__":
    main()
