"""
Quill AgentMail integration.

Dross is the AI persona for Quill. Its email account is thedross@agentmail.to.

API key is loaded from ~/.agentmail/agentmail.toml or the AGENTMAIL_API_KEY
environment variable.

This module wraps the AgentMail Python SDK with a small, Quill-friendly
interface. We deliberately don't expose every SDK method — only the
operations Quill needs (send, list inbox, get message, reply).
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

# Load API key from ~/.agentmail/agentmail.toml if not in env
def _load_api_key() -> str:
    env_key = os.environ.get("AGENTMAIL_API_KEY")
    if env_key:
        return env_key
    cfg_path = Path.home() / ".agentmail" / "agentmail.toml"
    if cfg_path.exists():
        try:
            import tomllib
            data = tomllib.loads(cfg_path.read_text())
            return data.get("api_key", "")
        except ImportError:
            try:
                import tomli
                data = tomli.loads(cfg_path.read_text())
                return data.get("api_key", "")
            except ImportError:
                m = re.search(r'api_key\s*=\s*"([^"]+)"', cfg_path.read_text())
                if m:
                    return m.group(1)
    return ""


# Default inbox for Dross
DROSS_INBOX = "thedross@agentmail.to"

# Lazy-load the SDK to keep startup fast
_client = None
_client_error: Optional[str] = None


def get_client():
    """Return a singleton AgentMail client. Returns None if SDK not installed."""
    global _client, _client_error
    if _client is not None:
        return _client
    api_key = _load_api_key()
    if not api_key:
        _client_error = "AGENTMAIL_API_KEY not set and ~/.agentmail/agentmail.toml missing"
        return None
    try:
        from agentmail import AgentMail
        _client = AgentMail(api_key=api_key)
        return _client
    except ImportError as e:
        _client_error = f"agentmail SDK not installed: {e}"
        return None
    except Exception as e:
        _client_error = f"failed to init AgentMail: {e}"
        return None


def last_error() -> Optional[str]:
    return _client_error


def is_available() -> bool:
    """True if the AgentMail client is usable. Doesn't hit the network."""
    return get_client() is not None


def list_inbox(limit: int = 20, label: Optional[str] = None) -> list[dict]:
    """List recent messages in the default inbox. Returns lightweight dicts."""
    client = get_client()
    if not client:
        return []
    try:
        result = client.inboxes.messages.list(inbox_id=DROSS_INBOX, limit=limit)
        msgs = []
        items = (getattr(result, "inboxes", None)
                 or getattr(result, "messages", None)
                 or getattr(result, "items", None)
                 or [])
        for m in items:
            d = {
                "id": getattr(m, "id", getattr(m, "message_id", "")),
                "from": str(getattr(m, "from_", "")),
                "to": str(getattr(m, "to", "")),
                "subject": getattr(m, "subject", ""),
                "preview": getattr(m, "preview", ""),
                "created_at": str(getattr(m, "created_at", "")),
                "labels": list(getattr(m, "labels", []) or []),
            }
            if label and label not in d["labels"]:
                continue
            msgs.append(d)
        return msgs
    except Exception as e:
        return [{"error": str(e)}]


def get_message(message_id: str) -> Optional[dict]:
    """Get a single message including body."""
    client = get_client()
    if not client:
        return None
    try:
        m = client.inboxes.messages.get(inbox_id=DROSS_INBOX, message_id=message_id)
        return {
            "id": getattr(m, "id", ""),
            "from": str(getattr(m, "from_", "")),
            "to": str(getattr(m, "to", "")),
            "subject": getattr(m, "subject", ""),
            "text": getattr(m, "text", ""),
            "html": getattr(m, "html", ""),
            "created_at": str(getattr(m, "created_at", "")),
            "labels": list(getattr(m, "labels", []) or []),
        }
    except Exception as e:
        return {"error": str(e)}


def send_email(
    to,
    subject: str,
    text: str = "",
    html: str = "",
    attachments=None,
    labels=None,
) -> dict:
    """Send an email from thedross@agentmail.to.

    Uses direct HTTP (the SDK has a retry-with-backoff that hangs when rate-limited).
    to: str or list of str
    attachments: list of {"filename": str, "content": bytes (or base64 str)}
    """
    api_key = _load_api_key()
    if not api_key:
        return {"ok": False, "error": "AgentMail API key not set"}
    if isinstance(to, str):
        to = [to]
    url = f"https://api.agentmail.to/v0/inboxes/{DROSS_INBOX}/messages/send"
    payload = {
        "to": to,
        "subject": subject,
    }
    if text:
        payload["text"] = text
    if html:
        payload["html"] = html
    if labels:
        payload["labels"] = labels
    if attachments:
        from agentmail import Attachment
        atts = []
        for a in attachments:
            content = a.get("content")
            if isinstance(content, str):
                import base64
                content = base64.b64decode(content)
            atts.append(Attachment(filename=a["filename"], content=content))
        payload["attachments"] = atts

    try:
        import urllib.request
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            method="POST",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
        msg_id = result.get("message_id") or result.get("id", "")
        return {"ok": True, "message_id": msg_id, "to": to, "subject": subject}
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read())
        except Exception:
            body = {}
        err = body.get("message", str(e))
        if e.code == 429:
            err = f"Rate limited: {err}"
        return {"ok": False, "error": err, "status": e.code, "rate_limited": e.code == 429}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def reply_email(message_id: str, text: str = "", html: str = "") -> dict:
    """Reply to a message in the inbox."""
    client = get_client()
    if not client:
        return {"ok": False, "error": _client_error or "AgentMail unavailable"}
    try:
        kwargs = {
            "inbox_id": DROSS_INBOX,
            "message_id": message_id,
        }
        if text:
            kwargs["text"] = text
        if html:
            kwargs["html"] = html
        result = client.inboxes.messages.reply(**kwargs)
        return {"ok": True, "message_id": getattr(result, "id", "")}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def create_draft(to, subject: str, text: str = "", html: str = "") -> dict:
    """Create a draft (for human review before sending)."""
    client = get_client()
    if not client:
        return {"ok": False, "error": _client_error or "AgentMail unavailable"}
    if isinstance(to, str):
        to = [to]
    try:
        kwargs = {
            "inbox_id": DROSS_INBOX,
            "to": to,
            "subject": subject,
        }
        if text:
            kwargs["text"] = text
        if html:
            kwargs["html"] = html
        result = client.inboxes.drafts.create(**kwargs)
        return {"ok": True, "draft_id": getattr(result, "id", "")}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# --------------------------------------------------------------------------
# Natural language intent parser
# --------------------------------------------------------------------------

EMAIL_INTENT_RE = re.compile(
    r"\b(email|send|mail|email\sthe\s(book|chapter|manuscript|draft|current)|send\s+(?:the\s+)?(book|chapter|manuscript|draft|current|it)\s+to)\b",
    re.IGNORECASE,
)
TO_RE = re.compile(
    r"(?:to|→)\s+([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})",
    re.IGNORECASE,
)


def parse_email_intent(text: str) -> Optional[dict]:
    """Try to extract an email command from natural language.

    Returns: {"to": str, "what": "book"|"chapter"|"current", "subject": str|None} or None.
    """
    if not EMAIL_INTENT_RE.search(text):
        return None
    m_to = TO_RE.search(text)
    if not m_to:
        return None
    to = m_to.group(1)
    what = "current"
    lower = text.lower()
    for keyword in ("book", "manuscript", "draft"):
        if keyword in lower:
            what = "book"
            break
    if "chapter" in lower:
        what = "chapter"
    subject = None
    subj_m = re.search(r"subject[:\s]+([^\n,.]+)", text, re.IGNORECASE)
    if subj_m:
        subject = subj_m.group(1).strip().strip('"\'')
    return {"to": to, "what": what, "subject": subject}


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "test":
        print(f"Available: {is_available()}")
        if not is_available():
            print(f"Error: {last_error()}")
            sys.exit(1)
        print(f"Inbox: {DROSS_INBOX}")
        msgs = list_inbox(limit=5)
        print(f"Recent messages: {len(msgs)}")
        for m in msgs[:5]:
            print(f"  {m.get('from', '?')[:40]} | {m.get('subject', '')[:60]}")
    elif len(sys.argv) > 1 and sys.argv[1] == "send":
        to = sys.argv[2] if len(sys.argv) > 2 else "test@example.com"
        subject = sys.argv[3] if len(sys.argv) > 3 else "Quill test"
        text = sys.argv[4] if len(sys.argv) > 4 else "Hello from Dross via Quill."
        result = send_email(to=to, subject=subject, text=text)
        print(result)
    else:
        print("Usage: python agentmail_service.py [test|send <to> <subject> <text>]")
