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

CHAPTER_SYSTEM = """You are Quill, a master fiction writer. Vivid sensory prose, strong
character interiority, immersive atmosphere. Literary but readable. Short punchy
sentences mixed with long flowing ones. No purple prose. No clichés."""

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
    for token in ollama_generate_streaming(
        args.writing_model, prompt, system=CHAPTER_SYSTEM,
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
    parser.add_argument("--research-model", default="qwen3:30b")
    parser.add_argument("--writing-model", default="gemma4:31b")
    parser.add_argument("--parallel", type=int, default=2,
                        help="How many chapters to write in parallel")
    parser.add_argument("--output-dir", default="~/Projects/Quill/output")
    parser.add_argument("--author", default="Quill AI")
    parser.add_argument("--word-target", type=int, default=1500,
                        help="Target words per chapter")
    args = parser.parse_args()

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
    research = ollama_generate(args.research_model,
        RESEARCH_PROMPT.format(subject=args.title, premise=args.premise, style=args.style),
        system="You are a research analyst for fiction. Output structured bullet notes, ~600 words. Be specific and vivid."
    )
    (out / f"{pid}_research.md").write_text(research)
    print(f"  ✓ {len(research)} chars research notes")

    # ---- Outline
    print(f"📋 Outline with {args.research_model}...")
    outline_text = ollama_generate(args.research_model,
        OUTLINE_PROMPT.format(chapters=args.chapters, premise=args.premise,
                              style=args.style, genre=args.genre, research=research[:4000]),
        system="You are a story architect. Output a numbered chapter outline with summaries."
    )
    (out / f"{pid}_outline.md").write_text(outline_text)

    # Parse outline
    chapters = []
    cur = {}
    for line in outline_text.split("\n"):
        line = line.strip()
        if line.upper().startswith("CHAPTER"):
            if cur:
                chapters.append(cur)
            parts = line.split(":", 1)
            num_str = parts[0].upper().replace("CHAPTER", "").strip()
            num = int(num_str) if num_str.isdigit() else len(chapters) + 1
            cur = {"num": num, "title": parts[1].strip() if len(parts) > 1 else f"Chapter {num}"}
        elif line.upper().startswith("SUMMARY") and cur:
            cur["summary"] = line.split(":", 1)[1].strip() if ":" in line else ""
        elif cur.get("summary") is not None and line and not line.upper().startswith("CHAPTER"):
            cur["summary"] = cur.get("summary", "") + " " + line
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
