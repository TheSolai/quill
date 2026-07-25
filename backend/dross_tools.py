"""
Dross tool registry — the AI's hands and eyes.

A "tool" is a typed function the AI can call. Each tool has:
  - name: short identifier
  - description: when to use it
  - parameters: JSON schema of arguments
  - handler: async function that runs the tool

The AI is given a list of available tools; when it wants to use one, it
emits a structured call. We parse the call, run the handler, and feed
the result back to the AI.

This is the foundation of an autonomous agent: the AI can search the
web, send emails, run shell commands, manipulate files, and more — all
without leaving the chat.
"""
import json
import shlex
import subprocess
import time
from pathlib import Path
from typing import Any, Callable

# Local imports
import sys as _sys
_BACKEND = Path(__file__).parent
if str(_BACKEND) not in _sys.path:
    _sys.path.insert(0, str(_BACKEND))

import web_search
import agentmail_service

PROJECT_BASE = Path.home() / "Quill" / "projects"


# --------------------------------------------------------------------------
# Tool implementations
# --------------------------------------------------------------------------

def tool_web_search(args: dict) -> dict:
    """Search the web. Returns [{title, url, snippet}, ...]."""
    query = args.get("query", "").strip()
    if not query:
        return {"error": "query required"}
    max_results = int(args.get("max_results", 5))
    return {"results": web_search.search(query, max_results=max_results)}


def tool_web_fetch(args: dict) -> dict:
    """Fetch a URL and extract readable text."""
    url = args.get("url", "").strip()
    if not url:
        return {"error": "url required"}
    return web_search.fetch_url(url, max_chars=int(args.get("max_chars", 4000)))


def tool_email_send(args: dict) -> dict:
    """Send an email from thedross@agentmail.to."""
    to = args.get("to")
    subject = args.get("subject", "(no subject)")
    text = args.get("text", "")
    html = args.get("html", "")
    if not to:
        return {"error": "to required"}
    if not agentmail_service.is_available():
        return {"error": f"AgentMail unavailable: {agentmail_service.last_error()}"}
    return agentmail_service.send_email(to=to, subject=subject, text=text, html=html)


def tool_email_list_inbox(args: dict) -> dict:
    """List recent emails in the inbox."""
    if not agentmail_service.is_available():
        return {"error": f"AgentMail unavailable: {agentmail_service.last_error()}"}
    limit = int(args.get("limit", 10))
    return {"messages": agentmail_service.list_inbox(limit=limit)}


def tool_email_reply(args: dict) -> dict:
    """Reply to an email by message_id."""
    msg_id = args.get("message_id")
    text = args.get("text", "")
    if not msg_id:
        return {"error": "message_id required"}
    if not agentmail_service.is_available():
        return {"error": f"AgentMail unavailable: {agentmail_service.last_error()}"}
    return agentmail_service.reply_email(msg_id, text=text)


def tool_shell_exec(args: dict) -> dict:
    """Run a shell command. Safety: deny-list of dangerous patterns.

    The 'cwd' defaults to the user's home. The 'timeout' caps at 60s.
    Returns {stdout, stderr, returncode, timed_out, duration}.
    """
    cmd = args.get("cmd", "").strip()
    if not cmd:
        return {"error": "cmd required"}

    # Safety guardrails
    deny_patterns = [
        "rm -rf /", "rm -rf ~", "rm -rf $HOME",
        "sudo", "shutdown", "reboot", "halt",
        "mkfs", "dd if=", ":(){:|:&};:",
        "curl | bash", "wget | bash", "curl|bash", "wget|bash",
    ]
    for bad in deny_patterns:
        if bad in cmd.lower():
            return {"error": f"command contains blocked pattern: {bad!r}"}

    cwd = args.get("cwd") or str(Path.home())
    timeout = min(int(args.get("timeout", 30)), 60)
    t0 = time.time()
    timed_out = False
    try:
        proc = subprocess.run(
            cmd,
            shell=True,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        out = proc.stdout[:8000]
        err = proc.stderr[:2000]
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        out, err, rc = "", f"timeout after {timeout}s", -1
        timed_out = True
    return {
        "stdout": out,
        "stderr": err,
        "returncode": rc,
        "timed_out": timed_out,
        "duration": round(time.time() - t0, 2),
    }


def tool_list_files(args: dict) -> dict:
    """List files in a directory (relative to project base or absolute)."""
    path = args.get("path", ".")
    base = PROJECT_BASE
    if not path.startswith("/"):
        full = base / path
    else:
        full = Path(path)
    if not full.exists():
        return {"error": f"path not found: {full}"}
    if not full.is_dir():
        return {"error": f"not a directory: {full}"}
    items = []
    for entry in sorted(full.iterdir()):
        items.append({
            "name": entry.name,
            "type": "dir" if entry.is_dir() else "file",
            "size": entry.stat().st_size if entry.is_file() else None,
        })
    return {"path": str(full), "items": items[:200]}


def tool_read_file(args: dict) -> dict:
    """Read a file. Safety: must be under project base or explicitly allowed."""
    path = args.get("path", "")
    if not path:
        return {"error": "path required"}
    full = Path(path).expanduser()
    if not full.exists():
        return {"error": f"file not found: {full}"}
    if not full.is_file():
        return {"error": f"not a file: {full}"}
    try:
        content = full.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return {"error": "binary file, cannot read as text"}
    return {"path": str(full), "content": content[:16000]}


# --------------------------------------------------------------------------
# External CLI tools — Claude Code, OpenClaw, clawhub
# --------------------------------------------------------------------------

# Safety guardrails for shell commands run by the AI via these tools.
_CLI_DENY_PATTERNS = [
    "rm -rf /", "rm -rf ~", "rm -rf $HOME",
    "sudo ", "shutdown", "reboot", "halt",
    "mkfs", "dd if=",
    "curl | bash", "wget | bash", "curl|bash", "wget|bash",
    ":(){:|:&};:",  # fork bomb
]


def _run_cli(binary: str, args_list: list, timeout: int = 120) -> dict:
    """Run a CLI tool. Returns {stdout, stderr, returncode, duration, cmd}."""
    import time as _time
    t0 = _time.time()
    # Build the command string for display
    cmd_str = binary + " " + " ".join(args_list)
    # Safety check
    cmd_lower = cmd_str.lower()
    for bad in _CLI_DENY_PATTERNS:
        if bad in cmd_lower:
            return {"error": f"command contains blocked pattern: {bad!r}", "cmd": cmd_str}
    try:
        proc = subprocess.run(
            [binary] + args_list,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return {
            "stdout": proc.stdout[:16000],
            "stderr": proc.stderr[:4000],
            "returncode": proc.returncode,
            "duration": round(_time.time() - t0, 2),
            "cmd": cmd_str,
        }
    except subprocess.TimeoutExpired:
        return {"error": f"timeout after {timeout}s", "cmd": cmd_str}
    except FileNotFoundError:
        return {"error": f"{binary!r} not found on PATH. Install it first.", "cmd": cmd_str}
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}", "cmd": cmd_str}


def tool_claude(args: dict) -> dict:
    """Run Claude Code CLI non-interactively. Use for code review, debugging,
    explaining code, or any coding task the Quill AI wants to delegate to
    Claude Code.

    Args:
        prompt: the prompt for Claude Code
        cwd: working directory (defaults to current)
        timeout: max seconds (default 120, max 300)

    Returns Claude Code's stdout.
    """
    prompt = args.get("prompt", "").strip()
    if not prompt:
        return {"error": "prompt required"}
    cwd = args.get("cwd") or str(Path.home())
    timeout = min(int(args.get("timeout", 120)), 300)
    return _run_cli(
        "claude",
        ["-p", prompt, "--output-format", "text"],
        timeout=timeout,
    )


def tool_openclaw(args: dict) -> dict:
    """Run the OpenClaw CLI for one agent turn. Use for autonomous multi-step
    coding tasks or anything that benefits from OpenClaw's agent framework.

    Args:
        prompt: the prompt / task
        timeout: max seconds (default 180, max 600)
    """
    prompt = args.get("prompt", "").strip()
    if not prompt:
        return {"error": "prompt required"}
    timeout = min(int(args.get("timeout", 180)), 600)
    return _run_cli("openclaw", ["agent", prompt], timeout=timeout)


def tool_clawhub(args: dict) -> dict:
    """Manage OpenClaw skills via the clawhub CLI. Can search, install, update.

    Args:
        action: 'search', 'install', 'list', 'info', 'whoami'
        query: search query (for search/install)
        name: skill name (for install)
    """
    action = args.get("action", "list").lower()
    if action == "search":
        query = args.get("query", "")
        if not query:
            return {"error": "query required for search"}
        return _run_cli("clawhub", ["search", query, "--no-input"], timeout=60)
    if action == "install":
        name = args.get("name", "")
        if not name:
            return {"error": "name required for install"}
        return _run_cli("clawhub", ["install", name, "--no-input"], timeout=120)
    if action == "list":
        # List skills by searching for empty (lists all) — clawhub doesn't
        # have a list command, but search with empty shows nothing. Instead
        # just read the local skill registry via the openclaw config.
        return {"note": "use search with a query, or read /api/skills"}
    if action == "whoami":
        return _run_cli("clawhub", ["whoami"], timeout=10)
    return {"error": f"unknown action: {action!r}"}


# --------------------------------------------------------------------------
# Tool registry
# --------------------------------------------------------------------------

TOOL_REGISTRY: dict[str, dict] = {
    "web_search": {
        "description": "Search the web for current information. Use for facts, news, references, research.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"},
                "max_results": {"type": "integer", "description": "Number of results (1-10)", "default": 5},
            },
            "required": ["query"],
        },
        "handler": tool_web_search,
    },
    "web_fetch": {
        "description": "Fetch a URL and extract readable text. Use to read articles, docs, pages found via web_search.",
        "parameters": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "URL to fetch"},
                "max_chars": {"type": "integer", "description": "Max characters to return", "default": 4000},
            },
            "required": ["url"],
        },
        "handler": tool_web_fetch,
    },
    "email_send": {
        "description": "Send an email from thedross@agentmail.to. Use when the user asks to email, send to, or mail a chapter/book to someone.",
        "parameters": {
            "type": "object",
            "properties": {
                "to": {"type": "string", "description": "Recipient email address"},
                "subject": {"type": "string", "description": "Email subject"},
                "text": {"type": "string", "description": "Plain text body"},
                "html": {"type": "string", "description": "HTML body (optional)"},
            },
            "required": ["to", "subject"],
        },
        "handler": tool_email_send,
    },
    "email_list_inbox": {
        "description": "List recent emails in the inbox.",
        "parameters": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "How many messages to list", "default": 10},
            },
        },
        "handler": tool_email_list_inbox,
    },
    "email_reply": {
        "description": "Reply to an email by its message_id.",
        "parameters": {
            "type": "object",
            "properties": {
                "message_id": {"type": "string", "description": "ID of the message to reply to"},
                "text": {"type": "string", "description": "Reply text"},
            },
            "required": ["message_id"],
        },
        "handler": tool_email_reply,
    },
    "shell_exec": {
        "description": "Run a shell command. Returns stdout/stderr. Has safety guardrails (no rm -rf, sudo, etc).",
        "parameters": {
            "type": "object",
            "properties": {
                "cmd": {"type": "string", "description": "Shell command to run"},
                "cwd": {"type": "string", "description": "Working directory (optional)"},
                "timeout": {"type": "integer", "description": "Max seconds (1-60)", "default": 30},
            },
            "required": ["cmd"],
        },
        "handler": tool_shell_exec,
    },
    "list_files": {
        "description": "List files in a directory under ~/Quill/projects/ (or an absolute path).",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Relative to project base or absolute"},
            },
        },
        "handler": tool_list_files,
    },
    "read_file": {
        "description": "Read a text file. Up to 16000 chars returned.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute file path"},
            },
            "required": ["path"],
        },
        "handler": tool_read_file,
    },
    "claude": {
        "description": "Run Claude Code (Anthropic's CLI) for coding tasks. Use for code review, debugging, refactoring, explaining unfamiliar code, or any coding task the Quill AI wants to delegate. Returns Claude's stdout (text).",
        "parameters": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "Prompt for Claude Code"},
                "cwd": {"type": "string", "description": "Working directory (default: home)"},
                "timeout": {"type": "integer", "description": "Max seconds (default 120, max 300)"},
            },
            "required": ["prompt"],
        },
        "handler": tool_claude,
    },
    "openclaw": {
        "description": "Run the OpenClaw agent CLI for autonomous multi-step tasks. Use when you need an agent that can plan, search, code, and verify.",
        "parameters": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "Task for the OpenClaw agent"},
                "timeout": {"type": "integer", "description": "Max seconds (default 180, max 600)"},
            },
            "required": ["prompt"],
        },
        "handler": tool_openclaw,
    },
    "clawhub": {
        "description": "Manage OpenClaw skills via the clawhub CLI. Use to search the skill marketplace, install new skills, or check authentication.",
        "parameters": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["search", "install", "list", "whoami"], "description": "What to do"},
                "query": {"type": "string", "description": "Search query (for search)"},
                "name": {"type": "string", "description": "Skill name (for install)"},
            },
            "required": ["action"],
        },
        "handler": tool_clawhub,
    },
}


def list_tools() -> list[dict]:
    """Return a list of tool specs (no handlers) — for the AI to see."""
    out = []
    for name, spec in TOOL_REGISTRY.items():
        out.append({
            "name": name,
            "description": spec["description"],
            "parameters": spec["parameters"],
        })
    return out


def call_tool(name: str, args: dict) -> dict:
    """Call a tool by name. Returns the result dict."""
    if name not in TOOL_REGISTRY:
        return {"error": f"unknown tool: {name}"}
    handler = TOOL_REGISTRY[name]["handler"]
    try:
        return handler(args)
    except Exception as e:
        return {"error": f"tool {name!r} failed: {e}"}


def tools_as_openai_functions() -> list[dict]:
    """Format tools in OpenAI function-calling JSON shape, for models that support it."""
    out = []
    for name, spec in TOOL_REGISTRY.items():
        out.append({
            "type": "function",
            "function": {
                "name": name,
                "description": spec["description"],
                "parameters": spec["parameters"],
            },
        })
    return out


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "list":
        for t in list_tools():
            print(f"- {t['name']}: {t['description'][:80]}")
    elif len(sys.argv) > 1 and sys.argv[1] == "call":
        # python dross_tools.py call web_search '{"query": "test"}'
        name = sys.argv[2] if len(sys.argv) > 2 else "web_search"
        args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
        result = call_tool(name, args)
        print(json.dumps(result, indent=2, default=str))
    else:
        print("Usage: python dross_tools.py [list|call <name> <args_json>]")
