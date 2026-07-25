"""
Quill slot providers — backend implementations for each slot type.

Each provider knows how to talk to its backend (Ollama, MiniMax, etc.).
The LLMProvider protocol is the unified interface; concrete classes
implement it per backend.

Adding a new provider:
  1. Subclass LLMProvider
  2. Set `slot_type = "your_type"`
  3. Implement chat(), stream(), test()

The slot manager (slots.py) dispatches to the right provider via
get_provider(slot).
"""
import json
import os
import time
import urllib.request
import urllib.error
from typing import Iterator, Optional

from slots import ModelSlot


# --------------------------------------------------------------------------
# LLMProvider protocol (informal — Python doesn't have interfaces pre-3.8,
# and we want to support dataclass-slot interop)
# --------------------------------------------------------------------------

class LLMProvider:
    """Base class. Subclass and implement chat() + stream() + test()."""
    slot_type: str = "base"  # override in subclass

    def __init__(self, slot: ModelSlot):
        self.slot = slot
        # Resolve API key from slot, env, or both
        self._api_key = slot.api_key or self._env_key()

    def _env_key(self) -> Optional[str]:
        """Return env var name → value, or None. Override per provider."""
        return None

    def _resolve_endpoint(self) -> str:
        if self.slot.endpoint:
            return self.slot.endpoint
        return self.default_endpoint()

    def default_endpoint(self) -> str:
        return ""

    # --- Public API ---

    def chat(self, messages: list[dict], **overrides) -> str:
        """Send messages, return full response text."""
        opts = {**self.slot.options, **overrides}
        return self._chat(messages, opts)

    def stream(self, messages: list[dict], **overrides) -> Iterator[str]:
        """Send messages, yield response chunks as they arrive."""
        opts = {**self.slot.options, **overrides}
        yield from self._stream(messages, opts)

    def test(self) -> bool:
        """Quick connectivity check. Returns True if backend reachable + model valid."""
        try:
            response = self.chat(
                [{"role": "user", "content": "ping"}],
                max_tokens=10,
                temperature=0.0,
            )
            return bool(response and len(response) > 0)
        except Exception as e:
            print(f"[{self.slot_type}] test failed: {e}")
            return False

    # --- Subclass hooks ---

    def _chat(self, messages: list[dict], options: dict) -> str:
        raise NotImplementedError

    def _stream(self, messages: list[dict], options: dict) -> Iterator[str]:
        raise NotImplementedError


# --------------------------------------------------------------------------
# Ollama provider (also handles MLX — Ollama serves MLX models)
# --------------------------------------------------------------------------

class OllamaProvider(LLMProvider):
    """Talks to a local Ollama instance. Also covers MLX models served
    by Ollama (which is the case in this project — gemma4:31b-mlx is
    just an Ollama model name with MLX backend)."""
    slot_type = "ollama"

    def _env_key(self):
        return None  # Ollama is local, no key

    def default_endpoint(self):
        return "http://127.0.0.1:11434"

    def _build_payload(self, messages: list[dict], options: dict, stream: bool):
        # Merge slot defaults with runtime overrides (runtime wins)
        merged = {**(self.slot.options or {}), **options}
        opts = {
            "temperature": merged.get("temperature", 0.85),
            "top_p": merged.get("top_p", 0.9),
            "num_ctx": merged.get("num_ctx", 8192),
        }
        if "top_k" in merged:
            opts["top_k"] = merged["top_k"]
        if "max_tokens" in merged:
            opts["num_predict"] = merged["max_tokens"]
        if "stop" in merged:
            opts["stop"] = merged["stop"]
        return {
            "model": self.slot.model_id,
            "messages": messages,
            "stream": stream,
            "options": opts,
        }

    def _chat(self, messages, options):
        url = f"{self._resolve_endpoint()}/api/chat"
        payload = self._build_payload(messages, options, stream=False)
        data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=300) as resp:
            result = json.loads(resp.read())
        return result.get("message", {}).get("content", "")

    def _stream(self, messages, options):
        url = f"{self._resolve_endpoint()}/api/chat"
        payload = self._build_payload(messages, options, stream=True)
        data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=600) as resp:
            for line in resp:
                line = line.decode().strip()
                if not line:
                    continue
                try:
                    chunk = json.loads(line)
                except json.JSONDecodeError:
                    continue
                token = chunk.get("message", {}).get("content", "")
                if token:
                    yield token
                if chunk.get("done"):
                    break

    def test(self):
        """For Ollama, also check the model exists (not just the server)."""
        try:
            url = f"{self._resolve_endpoint()}/api/tags"
            with urllib.request.urlopen(url, timeout=10) as resp:
                data = json.loads(resp.read())
            models = [m.get("name", "") for m in data.get("models", [])]
            if self.slot.model_id not in models:
                # Try without tag
                base = self.slot.model_id.split(":")[0]
                if not any(m.startswith(base) for m in models):
                    print(f"[ollama] model {self.slot.model_id} not in {models[:3]}...")
                    return False
            return True
        except (urllib.error.URLError, OSError) as e:
            print(f"[ollama] test failed: {e}")
            return False


class MLXProvider(OllamaProvider):
    """MLX provider — same protocol as Ollama since MLX models are served
    via Ollama in this project. Kept as a distinct class so the slot
    type 'mlx' is explicit (Apple Silicon MLX runtime, not generic CPU)."""
    slot_type = "mlx"

    def test(self):
        """MLX test: same as Ollama but verify the model name ends in -mlx."""
        ok = super().test()
        if ok and "-mlx" not in self.slot.model_id and "mlx" not in self.slot.model_id.lower():
            print(f"[mlx] warning: model {self.slot.model_id!r} doesn't look like an MLX model")
        return ok


# --------------------------------------------------------------------------
# MiniMax provider (cloud, OpenAI-compatible)
# --------------------------------------------------------------------------

class MiniMaxProvider(LLMProvider):
    """MiniMax cloud API — OpenAI-compatible chat completions.

    Endpoint: https://api.minimax.io/v1/text/chatcompletion_v2
    Auth: Bearer $MINIMAX_API_KEY
    Models: MiniMax-Text-01, MiniMax-M2.7, MiniMax-M2.7-highspeed
    """
    slot_type = "minimax"

    def _env_key(self):
        return os.environ.get("MINIMAX_API_KEY")

    def default_endpoint(self):
        return "https://api.minimax.io/v1/text/chatcompletion_v2"

    def _build_payload(self, messages: list[dict], options: dict, stream: bool):
        payload = {
            "model": self.slot.model_id,
            "messages": messages,
            "stream": stream,
        }
        if "temperature" in options:
            payload["temperature"] = options["temperature"]
        if "top_p" in options:
            payload["top_p"] = options["top_p"]
        if "max_tokens" in options:
            payload["max_tokens"] = options["max_tokens"]
        return payload

    def _headers(self):
        if not self._api_key:
            raise RuntimeError(
                "MiniMax API key not set. Set MINIMAX_API_KEY env var or "
                "configure api_key in the slot."
            )
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self._api_key}",
        }

    def _chat(self, messages, options):
        url = self._resolve_endpoint()
        payload = self._build_payload(messages, options, stream=False)
        data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method="POST")
        for k, v in self._headers().items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=300) as resp:
            result = json.loads(resp.read())
        # MiniMax wraps choices[0].message.content
        choices = result.get("choices", [])
        if choices:
            return choices[0].get("message", {}).get("content", "")
        # Error path
        if "base_resp" in result:
            err = result["base_resp"].get("status_msg", "unknown error")
            raise RuntimeError(f"MiniMax error: {err}")
        return ""

    def _stream(self, messages, options):
        url = self._resolve_endpoint()
        payload = self._build_payload(messages, options, stream=True)
        data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method="POST")
        for k, v in self._headers().items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=600) as resp:
            for line in resp:
                line = line.decode().strip()
                if not line:
                    continue
                if line == "data: [DONE]" or line == "[DONE]":
                    break
                # Strip "data: " prefix if present (SSE format)
                if line.startswith("data: "):
                    line = line[6:]
                try:
                    chunk = json.loads(line)
                except json.JSONDecodeError:
                    continue
                choices = chunk.get("choices", [])
                if choices:
                    delta = choices[0].get("delta", {})
                    # MiniMax M2.7 puts the final answer in `content` and the
                    # chain-of-thought in `reasoning_content`. We yield the
                    # answer; reasoning is exposed via slot option if needed.
                    token = delta.get("content", "")
                    if not token and options.get("include_reasoning"):
                        token = delta.get("reasoning_content", "")
                    if token:
                        yield token
                    if choices[0].get("finish_reason"):
                        break

    def test(self):
        """MiniMax test: send a minimal request and verify response."""
        if not self._api_key:
            print("[minimax] no API key")
            return False
        try:
            # Use enough tokens to handle M2.7's reasoning overhead
            response = self._chat(
                [{"role": "user", "content": "Reply with just the word PONG"}],
                {"temperature": 0.0, "max_tokens": 100},
            )
            return bool(response)
        except Exception as e:
            print(f"[minimax] test failed: {e}")
            return False


# --------------------------------------------------------------------------
# LM Studio provider (local OpenAI-compatible server on port 1234)
# --------------------------------------------------------------------------

class LMStudioProvider(LLMProvider):
    """LM Studio local server. Uses the OpenAI-compatible endpoint at
    http://127.0.0.1:1234/v1/chat/completions. Same protocol as MiniMax
    but no auth required."""
    slot_type = "lmstudio"

    def _env_key(self):
        return "lm-studio"  # LM Studio accepts any string

    def default_endpoint(self):
        return "http://127.0.0.1:1234/v1/chat/completions"

    def _build_payload(self, messages, options, stream):
        payload = {
            "model": self.slot.model_id or "local-model",
            "messages": messages,
            "stream": stream,
        }
        if "temperature" in options:
            payload["temperature"] = options["temperature"]
        if "top_p" in options:
            payload["top_p"] = options["top_p"]
        if "max_tokens" in options:
            payload["max_tokens"] = options["max_tokens"]
        return payload

    def _headers(self):
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self._api_key or 'lm-studio'}",
        }

    def _chat(self, messages, options):
        url = self._resolve_endpoint()
        payload = self._build_payload(messages, options, stream=False)
        data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method="POST")
        for k, v in self._headers().items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=300) as resp:
            result = json.loads(resp.read())
        choices = result.get("choices", [])
        if choices:
            return choices[0].get("message", {}).get("content", "")
        return ""

    def _stream(self, messages, options):
        url = self._resolve_endpoint()
        payload = self._build_payload(messages, options, stream=True)
        data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method="POST")
        for k, v in self._headers().items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=600) as resp:
            for line in resp:
                line = line.decode().strip()
                if not line or line == "data: [DONE]":
                    continue
                if line.startswith("data: "):
                    line = line[6:]
                try:
                    chunk = json.loads(line)
                except json.JSONDecodeError:
                    continue
                choices = chunk.get("choices", [])
                if choices:
                    delta = choices[0].get("delta", {})
                    token = delta.get("content", "")
                    if token:
                        yield token

    def test(self):
        try:
            url = f"{self._resolve_endpoint().rsplit('/v1', 1)[0]}/v1/models"
            with urllib.request.urlopen(url, timeout=10) as resp:
                return resp.status == 200
        except Exception as e:
            print(f"[lmstudio] test failed: {e}")
            return False


# --------------------------------------------------------------------------
# Custom / generic OpenAI-compatible provider
# --------------------------------------------------------------------------

class CustomProvider(LLMProvider):
    """Generic OpenAI-compatible provider. Configure endpoint + model_id.
    Reads OPENAI_API_KEY env var by default."""
    slot_type = "custom"

    def _env_key(self):
        return os.environ.get("OPENAI_API_KEY") or os.environ.get("CUSTOM_LLM_KEY")

    def default_endpoint(self):
        return os.environ.get("CUSTOM_LLM_ENDPOINT", "http://127.0.0.1:8080/v1/chat/completions")

    def _build_payload(self, messages, options, stream):
        payload = {
            "model": self.slot.model_id,
            "messages": messages,
            "stream": stream,
        }
        if "temperature" in options:
            payload["temperature"] = options["temperature"]
        if "top_p" in options:
            payload["top_p"] = options["top_p"]
        if "max_tokens" in options:
            payload["max_tokens"] = options["max_tokens"]
        return payload

    def _headers(self):
        if not self._api_key:
            return {"Content-Type": "application/json"}
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self._api_key}",
        }

    def _chat(self, messages, options):
        url = self._resolve_endpoint()
        payload = self._build_payload(messages, options, stream=False)
        data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method="POST")
        for k, v in self._headers().items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=300) as resp:
            result = json.loads(resp.read())
        choices = result.get("choices", [])
        if choices:
            return choices[0].get("message", {}).get("content", "")
        return ""

    def _stream(self, messages, options):
        url = self._resolve_endpoint()
        payload = self._build_payload(messages, options, stream=True)
        data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method="POST")
        for k, v in self._headers().items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=600) as resp:
            for line in resp:
                line = line.decode().strip()
                if not line or line == "data: [DONE]":
                    continue
                if line.startswith("data: "):
                    line = line[6:]
                try:
                    chunk = json.loads(line)
                except json.JSONDecodeError:
                    continue
                choices = chunk.get("choices", [])
                if choices:
                    delta = choices[0].get("delta", {})
                    token = delta.get("content", "")
                    if token:
                        yield token


# --------------------------------------------------------------------------
# Provider registry / factory
# --------------------------------------------------------------------------

PROVIDERS = {
    "ollama": OllamaProvider,
    "mlx": MLXProvider,
    "minimax": MiniMaxProvider,
    "lmstudio": LMStudioProvider,
    "custom": CustomProvider,
}


def get_provider(slot: ModelSlot) -> LLMProvider:
    """Factory: return the right provider for a slot."""
    cls = PROVIDERS.get(slot.type)
    if not cls:
        raise ValueError(
            f"no provider for slot type {slot.type!r}. "
            f"Available: {list(PROVIDERS.keys())}"
        )
    return cls(slot)


def list_provider_types() -> list[str]:
    return list(PROVIDERS.keys())


if __name__ == "__main__":
    import sys
    sys.path.insert(0, str(__file__).rsplit("/", 1)[0])
    from slots import load_slots, get_active_slot

    if len(sys.argv) > 1 and sys.argv[1] == "test-all":
        print(f"Testing {len(load_slots())} slots...")
        for s in load_slots():
            t0 = time.time()
            try:
                p = get_provider(s)
                ok = p.test()
                lat = (time.time() - t0) * 1000
                status = "✓" if ok else "✗"
                print(f"  {status}  {s.id:20s}  {s.type:8s}  {lat:6.0f}ms  {s.name}")
            except Exception as e:
                print(f"  ✗  {s.id:20s}  ERROR: {e}")
    else:
        slot = get_active_slot()
        print(f"Active slot: {slot.id} ({slot.name})")
        try:
            prov = get_provider(slot)
            print(f"Provider: {type(prov).__name__}")
            print("Testing...")
            t0 = time.time()
            ok = prov.test()
            lat = (time.time() - t0) * 1000
            print(f"{'OK' if ok else 'FAIL'} in {lat:.0f}ms")
        except Exception as e:
            print(f"ERROR: {e}")
