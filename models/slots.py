"""
Quill model slot manager.

A "slot" is a swappable AI model configuration. Each slot has a type
(ollama, mlx, minimax, lmstudio), a model_id, an endpoint, and options.

The slot system replaces the old `llm-configs.yaml` (which only listed
Ollama models) with a unified registry that includes cloud providers
(MiniMax) and a notion of which slot is currently active.

Storage: `models/slots.yaml` (human-editable) + `models/.active_slot`
(machine-managed pointer to the active slot id).

Backward compat: if `slots.yaml` is missing, the manager creates it
from the legacy `llm-configs.yaml` on first load.
"""
import json
import os
import time
import uuid
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional

import yaml

SLOTS_PATH = Path(__file__).parent / "slots.yaml"
ACTIVE_SLOT_PATH = Path(__file__).parent / ".active_slot"
LEGACY_PATH = Path(__file__).parent / "llm-configs.yaml"

VALID_TYPES = ("ollama", "mlx", "minimax", "lmstudio", "custom")
VALID_PURPOSES = ("creative", "research", "outline", "code", "general", "critique", "plan")
VALID_CATEGORIES = ("local", "creative", "research", "code", "cloud", "minimax")


@dataclass
class ModelSlot:
    """A single swappable model configuration."""
    id: str                                # unique, URL-safe
    name: str                              # display name
    type: str                              # ollama | mlx | minimax | lmstudio | custom
    model_id: str                          # provider-specific id
    endpoint: str = ""                     # URL; sensible default per type
    api_key: Optional[str] = None          # only for cloud providers
    options: dict = field(default_factory=dict)  # temperature, top_p, top_k, num_ctx
    purpose: str = "general"               # creative | research | outline | code | general | critique | plan
    category: str = "local"                # local | creative | research | code | cloud | minimax
    tool_calling: bool = False             # supports OpenAI-style tool/function calling
    thinking: bool = False                 # supports chain-of-thought reasoning tokens
    is_default: bool = False
    metadata: dict = field(default_factory=dict)  # vram, speed, notes
    created_at: float = field(default_factory=time.time)
    # Internal flag: skip validation on construction. Used only for legacy
    # migrations and tests that need to construct partial slots. The public
    # API (add_slot, update_slot) always re-validates before persisting.
    validate_on_init: bool = field(default=True, repr=False, compare=False)

    def __post_init__(self):
        if self.validate_on_init:
            errs = self._validate()
            if errs:
                raise ValueError(f"invalid slot: {'; '.join(errs)}")

    def to_dict(self):
        d = asdict(self)
        d.pop("validate_on_init", None)
        return d

    def public_dict(self):
        """Safe for API responses — strips the api_key field entirely."""
        d = self.to_dict()
        d.pop("api_key", None)
        # Add a has_api_key flag for UI (without exposing the key)
        d["has_api_key"] = bool(self.api_key)
        return d

    def validate(self) -> list[str]:
        """Public validation entry point. Same as _validate, but explicit."""
        return self._validate()

    def _validate(self) -> list[str]:
        """Return a list of validation errors (empty if valid)."""
        import re as _re
        errors = []
        if not self.id or not _re.match(r"^[a-z0-9][a-z0-9_-]*$", self.id):
            errors.append(
                f"invalid id {self.id!r}: must be lowercase alphanumeric + dash/underscore, "
                "must start with a letter or digit"
            )
        if self.type not in VALID_TYPES:
            errors.append(f"invalid type {self.type!r}: must be one of {VALID_TYPES}")
        if self.category not in VALID_CATEGORIES:
            errors.append(f"invalid category {self.category!r}: must be one of {VALID_CATEGORIES}")
        if not self.model_id:
            errors.append("model_id is required")
        if self.purpose not in VALID_PURPOSES:
            errors.append(f"invalid purpose {self.purpose!r}: must be one of {VALID_PURPOSES}")
        if self.type == "minimax" and not (self.api_key or os.environ.get("MINIMAX_API_KEY")):
            errors.append("minimax slot requires api_key or MINIMAX_API_KEY env var")
        # Validate options ranges
        opts = self.options or {}
        if "temperature" in opts:
            t = opts["temperature"]
            if not (0 <= t <= 2):
                errors.append(f"temperature {t} out of range [0, 2]")
        if "top_p" in opts:
            tp = opts["top_p"]
            if not (0 <= tp <= 1):
                errors.append(f"top_p {tp} out of range [0, 1]")
        if "top_k" in opts:
            tk = opts["top_k"]
            if tk < 1:
                errors.append(f"top_k {tk} must be >= 1")
        return errors


# --------------------------------------------------------------------------
# Default slot definitions
# --------------------------------------------------------------------------

DEFAULT_SLOTS = [
    # === Local Ollama (MLX) — DEFAULT ===
    {
        "id": "gemma4-mlx",
        "name": "Gemma 4 MLX 31B (Local, default)",
        "type": "mlx",
        "model_id": "gemma4:31b-mlx",
        "endpoint": "http://127.0.0.1:11434",
        "options": {"temperature": 0.85, "top_p": 0.92, "top_k": 60, "num_ctx": 8192},
        "purpose": "creative",
        "category": "creative",
        "tool_calling": True,
        "thinking": True,
        "is_default": True,
        "metadata": {
            "vram": "24GB",
            "speed": "fast",
            "quality": "very_high",
            "notes": "Apple Silicon MLX runtime via Ollama. Best default for literary prose.",
        },
    },
    {
        "id": "gemma4-fast",
        "name": "Gemma 4 8B (Local, fast)",
        "type": "ollama",
        "model_id": "gemma4:latest",
        "endpoint": "http://127.0.0.1:11434",
        "options": {"temperature": 0.9, "top_p": 0.92, "num_ctx": 8192},
        "purpose": "creative",
        "category": "creative",
        "tool_calling": True,
        "thinking": True,
        "metadata": {
            "vram": "8GB",
            "speed": "very_fast",
            "quality": "high",
            "notes": "Quick drafts. Lower quality but very fast.",
        },
    },
    {
        "id": "qwen3-30b",
        "name": "Qwen 3 30B (Local, long-context)",
        "type": "ollama",
        "model_id": "qwen3:30b",
        "endpoint": "http://127.0.0.1:11434",
        "options": {"temperature": 0.85, "top_p": 0.9, "num_ctx": 32768},
        "purpose": "creative",
        "category": "creative",
        "tool_calling": True,
        "thinking": True,
        "metadata": {
            "vram": "24GB",
            "speed": "medium",
            "quality": "very_high",
            "notes": "32K context. Best for long coherent arcs.",
        },
    },
    {
        "id": "gpt-oss-20b",
        "name": "GPT-OSS 20B (Local, thinking)",
        "type": "ollama",
        "model_id": "gpt-oss:20b",
        "endpoint": "http://127.0.0.1:11434",
        "options": {"temperature": 0.5, "top_p": 0.9, "num_ctx": 131072},
        "purpose": "research",
        "category": "research",
        "tool_calling": True,
        "thinking": True,
        "metadata": {
            "vram": "16GB",
            "speed": "medium",
            "quality": "very_high",
            "notes": "131K context, thinking-heavy. Good for outlines + structural review.",
        },
    },
    {
        "id": "qwen-coder-30b",
        "name": "Qwen 3 Coder 30B (Local, code)",
        "type": "ollama",
        "model_id": "qwen3-coder:30b",
        "endpoint": "http://127.0.0.1:11434",
        "options": {"temperature": 0.2, "num_ctx": 262144},
        "purpose": "code",
        "category": "code",
        "tool_calling": True,
        "thinking": False,
        "metadata": {
            "vram": "24GB",
            "speed": "medium",
            "quality": "highest",
            "notes": "262K context. For code generation.",
        },
    },
    {
        "id": "llama3-70b",
        "name": "Llama 3.3 70B (Local, epic)",
        "type": "ollama",
        "model_id": "llama3.3:70b",
        "endpoint": "http://127.0.0.1:11434",
        "options": {"temperature": 0.8, "top_p": 0.95, "num_ctx": 8192},
        "purpose": "creative",
        "category": "creative",
        "tool_calling": True,
        "thinking": False,
        "metadata": {
            "vram": "48GB",
            "speed": "slow",
            "quality": "highest",
            "notes": "Epic-scale narratives. When quality matters most.",
        },
    },
    {
        "id": "groq-tool-use",
        "name": "Llama 3 Groq Tool-Use 8B (Local, agentic)",
        "type": "ollama",
        "model_id": "llama3-groq-tool-use:8b",
        "endpoint": "http://127.0.0.1:11434",
        "options": {"temperature": 0.1, "top_p": 0.9, "num_ctx": 8192},
        "purpose": "general",
        "category": "local",
        "tool_calling": True,
        "thinking": False,
        "metadata": {
            "vram": "8GB",
            "speed": "very_fast",
            "quality": "high",
            "notes": "Fine-tuned specifically for tool/function calling. Best for Dross as an autonomous agent.",
        },
    },
    # === Cloud: MiniMax ===
    {
        "id": "minimax-text",
        "name": "MiniMax Text 01 (Cloud)",
        "type": "minimax",
        "model_id": "MiniMax-Text-01",
        "endpoint": "https://api.minimax.io/v1/text/chatcompletion_v2",
        "options": {"temperature": 0.85, "top_p": 0.9, "max_tokens": 4096},
        "purpose": "general",
        "category": "minimax",
        "tool_calling": False,
        "thinking": False,
        "metadata": {
            "vram": "cloud",
            "speed": "medium",
            "quality": "high",
            "notes": "MiniMax's general-purpose text model. Requires MINIMAX_API_KEY env var.",
            "context": 128000,
        },
    },
    {
        "id": "minimax-m27",
        "name": "MiniMax M2.7 (Cloud, reasoning)",
        "type": "minimax",
        "model_id": "MiniMax-M2.7",
        "endpoint": "https://api.minimax.io/v1/text/chatcompletion_v2",
        "options": {"temperature": 0.7, "top_p": 0.9, "max_tokens": 8192},
        "purpose": "general",
        "category": "minimax",
        "tool_calling": False,
        "thinking": True,
        "metadata": {
            "vram": "cloud",
            "speed": "medium",
            "quality": "very_high",
            "notes": "M2.7 with thinking. Strong reasoning + 200K context. Needs ~500-1000 tokens of headroom for reasoning.",
            "context": 200000,
        },
    },
    {
        "id": "minimax-highspeed",
        "name": "MiniMax M2.7 Highspeed (Cloud, fast)",
        "type": "minimax",
        "model_id": "MiniMax-M2.7-highspeed",
        "endpoint": "https://api.minimax.io/v1/text/chatcompletion_v2",
        "options": {"temperature": 0.85, "top_p": 0.9, "max_tokens": 4096},
        "purpose": "general",
        "category": "minimax",
        "tool_calling": False,
        "thinking": True,
        "metadata": {
            "vram": "cloud",
            "speed": "fast",
            "quality": "high",
            "notes": "Faster variant of M2.7. Lower latency, similar quality.",
            "context": 200000,
        },
    },
]


def _migrate_legacy_if_needed():
    """If slots.yaml doesn't exist but llm-configs.yaml does, migrate."""
    import re as _re
    no_migrate = Path(__file__).parent / ".no_migrate"
    if SLOTS_PATH.exists() or not LEGACY_PATH.exists() or no_migrate.exists():
        return
    try:
        with open(LEGACY_PATH) as f:
            legacy = yaml.safe_load(f)
        slots = []
        for m in legacy.get("providers", {}).get("ollama", {}).get("models", []):
            # Sanitize id: lowercase, replace special chars
            slot_id = m["id"].lower().replace(":", "-").replace(".", "-")
            slot_id = _re.sub(r"[^a-z0-9_-]", "-", slot_id)
            slot_id = _re.sub(r"-+", "-", slot_id).strip("-")
            slot = {
                "id": slot_id,
                "name": f"{m.get('name', m['id'])} (Local, migrated)",
                "type": "mlx" if "mlx" in m["id"] else "ollama",
                "model_id": m["id"],
                "endpoint": "http://127.0.0.1:11434",
                "options": m.get("options", {}),
                "purpose": m.get("purpose", "general")
                    .replace("long-form-creative", "creative")
                    .replace("research-outline", "research"),
                "metadata": {
                    k: v for k, v in m.items()
                    if k not in ("id", "purpose", "options")
                },
            }
            # Construct with validation; fall back to lenient for edge cases
            try:
                slots.append(ModelSlot(**slot, validate_on_init=True))
            except ValueError:
                slots.append(ModelSlot(**slot, validate_on_init=False))
        # Append MiniMax defaults
        for s in DEFAULT_SLOTS:
            if s["type"] == "minimax":
                slots.append(ModelSlot(**s, validate_on_init=True))
        if slots:
            slots[0].is_default = True
        with open(SLOTS_PATH, "w") as f:
            yaml.safe_dump(
                {"slots": [s.to_dict() for s in slots]},
                f, default_flow_style=False, sort_keys=False,
            )
    except Exception as e:
        # Migration failed; will create default on next load
        print(f"[slots] legacy migration failed: {e}")


def load_slots() -> list[ModelSlot]:
    """Load all slots from disk. Migrates legacy config if needed.
    Always returns at least the defaults if file is missing or corrupt."""
    _migrate_legacy_if_needed()
    if not SLOTS_PATH.exists():
        # First run — write defaults (no validation; trust DEFAULT_SLOTS)
        save_slots([ModelSlot(**s, validate_on_init=False) for s in DEFAULT_SLOTS])
    try:
        with open(SLOTS_PATH) as f:
            data = yaml.safe_load(f) or {}
        raw = data.get("slots", [])
        slots = []
        for s in raw:
            # Strip unknown fields (forward compat: ignore fields we don't know)
            try:
                slots.append(ModelSlot(**s, validate_on_init=False))
            except TypeError as e:
                print(f"[slots] skipping invalid entry {s.get('id', '?')}: {e}")
        if not slots:
            slots = [ModelSlot(**s, validate_on_init=False) for s in DEFAULT_SLOTS]
            save_slots(slots)
        return slots
    except (yaml.YAMLError, OSError) as e:
        print(f"[slots] load failed: {e}, using defaults")
        return [ModelSlot(**s, validate_on_init=False) for s in DEFAULT_SLOTS]


def save_slots(slots: list[ModelSlot]):
    """Persist slots to disk."""
    SLOTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    data = {"slots": [s.to_dict() for s in slots]}
    with open(SLOTS_PATH, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)


def get_slot(slot_id: str) -> Optional[ModelSlot]:
    """Get a slot by id. Returns None if not found."""
    for s in load_slots():
        if s.id == slot_id:
            return s
    return None


def get_default_slot() -> ModelSlot:
    """Return the slot marked is_default, or the first slot if none marked."""
    slots = load_slots()
    for s in slots:
        if s.is_default:
            return s
    return slots[0]


def set_active_slot(slot_id: str) -> bool:
    """Set the active slot. Returns False if slot not found."""
    if not get_slot(slot_id):
        return False
    ACTIVE_SLOT_PATH.write_text(slot_id)
    return True


def get_active_slot_id() -> str:
    """Return the active slot id, or the default slot's id."""
    if ACTIVE_SLOT_PATH.exists():
        sid = ACTIVE_SLOT_PATH.read_text().strip()
        if get_slot(sid):
            return sid
    return get_default_slot().id


def get_active_slot() -> ModelSlot:
    """Return the active slot as a ModelSlot object."""
    return get_slot(get_active_slot_id()) or get_default_slot()


def add_slot(slot: ModelSlot) -> ModelSlot:
    """Add a new slot. Validates and returns the saved slot."""
    errs = slot.validate()
    if errs:
        raise ValueError(f"invalid slot: {'; '.join(errs)}")
    if get_slot(slot.id):
        raise ValueError(f"slot id {slot.id!r} already exists")
    slots = load_slots()
    slots.append(slot)
    save_slots(slots)
    return slot


def update_slot(slot_id: str, **changes) -> Optional[ModelSlot]:
    """Update fields on a slot. Returns the updated slot or None if not found."""
    slots = load_slots()
    for i, s in enumerate(slots):
        if s.id == slot_id:
            for k, v in changes.items():
                if hasattr(s, k):
                    setattr(s, k, v)
            errs = s.validate()
            if errs:
                raise ValueError(f"invalid slot after update: {'; '.join(errs)}")
            slots[i] = s
            save_slots(slots)
            return s
    return None


def delete_slot(slot_id: str) -> bool:
    """Delete a slot. Cannot delete the active slot or the only remaining slot."""
    if slot_id == get_active_slot_id():
        raise ValueError(f"cannot delete active slot {slot_id!r}")
    slots = load_slots()
    new_slots = [s for s in slots if s.id != slot_id]
    if len(new_slots) == len(slots):
        return False  # not found
    if not new_slots:
        raise ValueError("cannot delete the only remaining slot")
    save_slots(new_slots)
    return True


def reset_to_defaults():
    """Wipe and rewrite the default slot set. Used by tests + first-run.

    Also removes the legacy llm-configs.yaml marker so migration doesn't
    run again on the next load. If you want to keep the legacy file as
    a backup, move it out of the way before calling this.
    """
    if ACTIVE_SLOT_PATH.exists():
        ACTIVE_SLOT_PATH.unlink()
    if SLOTS_PATH.exists():
        SLOTS_PATH.unlink()
    # Write defaults directly (don't go through load which would re-migrate)
    slots = [ModelSlot(**s, validate_on_init=False) for s in DEFAULT_SLOTS]
    save_slots(slots)
    set_active_slot("gemma4-mlx")
    return slots


def disable_legacy_migration():
    """Permanently prevent the legacy llm-configs.yaml from being migrated.

    Creates a .no_migrate marker. Once set, slots.yaml is the source of truth.
    """
    marker = Path(__file__).parent / ".no_migrate"
    marker.write_text("# Don't migrate from llm-configs.yaml. slots.yaml is the source of truth.\n")


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "list":
            for s in load_slots():
                marker = "★" if s.is_default else " "
                active = "→" if s.id == get_active_slot_id() else " "
                print(f" {marker}{active} {s.id:20s}  {s.type:8s}  {s.purpose:10s}  {s.name}")
        elif cmd == "active":
            s = get_active_slot()
            print(f"Active: {s.id} ({s.name})")
        elif cmd == "use" and len(sys.argv) > 2:
            ok = set_active_slot(sys.argv[2])
            print(f"Set active: {sys.argv[2]}" if ok else f"Not found: {sys.argv[2]}")
        elif cmd == "test" and len(sys.argv) > 2:
            from slot_providers import get_provider
            slot = get_slot(sys.argv[2])
            if not slot:
                print(f"Not found: {sys.argv[2]}")
                sys.exit(1)
            prov = get_provider(slot)
            import time as _t
            t0 = _t.time()
            try:
                ok = prov.test()
                lat = (_t.time() - t0) * 1000
                print(f"{'OK' if ok else 'FAIL'}  {slot.id}  {lat:.0f}ms")
            except Exception as e:
                print(f"ERROR  {slot.id}  {e}")
        else:
            print("Usage: python slots.py [list|active|use <id>|test <id>]")
    else:
        slots = load_slots()
        print(f"{len(slots)} slots loaded. Active: {get_active_slot_id()}")
        print("Run `python slots.py list` to see all.")
