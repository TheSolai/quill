"""
Quill skills — loads OpenClaw skills from the user's local installation.

The user's local OpenClaw setup at ~/.openclaw/skills/skill-resolver/config.json
defines a registry of skills. Each skill has:
  - name (e.g. "summarize")
  - keywords (e.g. ["summarize", "summary", "tldr"])
  - paths (list of SKILL.md locations, may be empty)

This module:
  - Loads the registry
  - Provides functions to inject skills into the AI's system prompt
  - Provides a /api/skills endpoint payload

The Quill AI uses these skills to know what it can do — when the user asks
"can you summarize this URL", Quill knows there's a `summarize` skill and
can either run it directly (via shell_exec) or guide the user.
"""

import json
import os
import re
from pathlib import Path
from typing import Optional


# --------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------

# OpenClaw skills config (the user's local installation)
# Search in multiple locations. clawhub installs to ~/.openclaw/workspace/skills/,
# but the user's repo is at ~/Projects/thesolai.github.io/skills/.
# We try the repo first (most curated), then the OpenClaw workspace.
_SKILLS_CONFIG_CANDIDATES = [
    Path.home() / "Projects" / "thesolai.github.io" / "skills" / "skill-resolver" / "config.json",
    Path.home() / ".openclaw" / "workspace" / "skills" / "skill-resolver" / "config.json",
    Path.home() / ".openclaw" / "skills" / "skill-resolver" / "config.json",
    Path("/Users/amre/Projects/thesolai.github.io/skills/skill-resolver/config.json"),
]

# Standard skill directories (for SKILL.md content lookups). When a
# skill is referenced in the registry, we look for SKILL.md in all of
# these places.
_SKILL_DIR_CANDIDATES = [
    Path.home() / "Projects" / "thesolai.github.io" / "skills",
    Path.home() / ".openclaw" / "workspace" / "skills",
    Path.home() / ".openclaw" / "skills",
]


def _find_all_skill_dirs() -> list[Path]:
    """Return all locations that may contain SKILL.md files."""
    out = []
    for c in _SKILL_DIR_CANDIDATES:
        if c.is_dir() and c not in out:
            out.append(c)
    return out


def find_skill_md(name: str) -> Optional[Path]:
    """Search all skill directories for a SKILL.md matching the skill name."""
    for d in _find_all_skill_dirs():
        candidate = d / name / "SKILL.md"
        if candidate.exists():
            return candidate
        # Also try with -1-0-0 etc. variants
        for sub in d.iterdir():
            if sub.is_dir() and sub.name.startswith(name):
                skill = sub / "SKILL.md"
                if skill.exists():
                    return skill
    return None


def _find_skills_config() -> Optional[Path]:
    for candidate in _SKILLS_CONFIG_CANDIDATES:
        if candidate.exists():
            return candidate
    return None


def _find_skill_dir() -> Optional[Path]:
    for candidate in _SKILL_DIR_CANDIDATES:
        if candidate.is_dir():
            return candidate
    return None


# --------------------------------------------------------------------------
# Load + cache
# --------------------------------------------------------------------------

_CACHE: Optional[dict] = None


def _load_registry() -> dict:
    """Load the OpenClaw skills registry. Cached on first load."""
    global _CACHE
    if _CACHE is not None:
        return _CACHE
    config_path = _find_skills_config()
    if not config_path:
        _CACHE = {"_config_path": None, "_skill_dir": None, "skills": {}}
        return _CACHE
    try:
        with open(config_path) as f:
            data = json.load(f)
    except Exception:
        _CACHE = {"_config_path": None, "_skill_dir": None, "skills": {}}
        return _CACHE
    skill_dir = _find_skill_dir()
    _CACHE = {
        "_config_path": str(config_path),
        "_skill_dir": str(skill_dir) if skill_dir else None,
        "skills": data.get("skills", {}),
    }
    return _CACHE


def reload() -> dict:
    """Force a reload of the skills registry."""
    global _CACHE
    _CACHE = None
    return _load_registry()


# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

def list_skills() -> list:
    """List all available skills as a list of dicts."""
    registry = _load_registry()
    skills = registry.get("skills", {})
    out = []
    for name, info in skills.items():
        out.append({
            "name": name,
            "keywords": info.get("keywords", []),
            "slug": info.get("slug", name),
            "paths": info.get("paths", []),
        })
    return out


def get_skill(name: str) -> Optional[dict]:
    """Get a single skill by name."""
    registry = _load_registry()
    skills = registry.get("skills", {})
    return skills.get(name)


def find_skill_by_keyword(text: str) -> Optional[dict]:
    """Find a skill whose keywords match the given text. Returns the
    highest-priority match (most keyword hits, then first in registry)."""
    if not text:
        return None
    text_lower = text.lower()
    registry = _load_registry()
    skills = registry.get("skills", {})
    best = None
    best_score = 0
    for name, info in skills.items():
        keywords = info.get("keywords", [])
        score = sum(1 for k in keywords if k.lower() in text_lower)
        if score > best_score:
            best = {"name": name, **info, "score": score}
            best_score = score
    return best if best_score > 0 else None


def skills_for_prompt(max_skills: int = 25) -> str:
    """Build a compact skills list for injection into the AI's system prompt.

    Lists the most useful skills (up to max_skills) with their keywords so
    the AI can recognize when one applies. We don't dump the full SKILL.md
    content (too much context) — just the trigger keywords.

    A short priority list comes first so the AI sees the most useful skills
    even when the rest is truncated.
    """
    skills = list_skills()
    if not skills:
        return ""
    # Priority skills that the AI is most likely to need first
    priority = [
        "summarize", "coding-agent", "github", "weather", "sqlite",
        "pdf", "docx", "xlsx", "pptx", "notion",
        "blog-reflections", "devto-tutorials", "devto-trending",
        "skill-creator", "prompt-master", "token-optimizer", "model-usage",
        "image-generate", "video-generate", "music-generate",
        "diagram-maker", "theme-factory",
        "apple-notes", "apple-reminders", "things-mac", "obsidian",
        "tmux", "node-inspect-debugger", "python-debugpy",
    ]
    # Order: priority skills first, then the rest in alphabetical order
    by_name = {s["name"]: s for s in skills}
    seen = set()
    ordered = []
    for name in priority:
        if name in by_name:
            ordered.append(by_name[name])
            seen.add(name)
    # Add remaining skills alphabetically
    for s in sorted(skills, key=lambda s: s["name"]):
        if s["name"] not in seen:
            ordered.append(s)
    if len(ordered) > max_skills:
        ordered = ordered[:max_skills]
    lines = ["You have access to the following OpenClaw skills. Recognize when the user asks for something these cover and use them:"]
    for s in ordered:
        keywords = ", ".join(s["keywords"][:4]) if s["keywords"] else "(no keywords)"
        lines.append(f"- `{s['name']}` — triggers: {keywords}")
    lines.append("")
    lines.append("To use a skill that involves a tool, emit a `tool_call` JSON block like `{\"name\": \"shell_exec\", \"args\": {\"cmd\": \"summarize <url>\"}}`. For skills that need to read a SKILL.md, use `read_file` to load the skill instructions first. For conversational skills, just respond in persona.")
    return "\n".join(lines)


def read_skill_md(name: str) -> Optional[str]:
    """Read the SKILL.md content for a named skill, if it exists locally.

    Searches in the registry's declared paths first, then falls back to
    scanning all known skill directories.
    """
    info = get_skill(name)
    paths = info.get("paths", []) if info else []
    # Expand ~ and check each path
    for p in paths:
        path = Path(os.path.expanduser(p))
        if path.exists():
            try:
                return path.read_text(encoding="utf-8")
            except Exception:
                continue
    # Search all known skill directories
    found = find_skill_md(name)
    if found:
        try:
            return found.read_text(encoding="utf-8")
        except Exception:
            pass
    return None


def status() -> dict:
    """Status of the skills system (for /api/skills and diagnostics)."""
    registry = _load_registry()
    skills = registry.get("skills", {})
    return {
        "available": bool(skills),
        "config_path": registry.get("_config_path"),
        "skill_dir": registry.get("_skill_dir"),
        "skill_count": len(skills),
    }
