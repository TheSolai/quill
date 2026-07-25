"""
Ollama writer — a small CLI for one-off long-form generation using any installed Ollama model.
Useful for testing models, quick drafts, and the `models/` workflows.

Usage:
    python3 ollama_writer.py --model gemma4:31b --prompt "Write me a..."
    python3 ollama_writer.py --interactive
    echo "prompt" | python3 ollama_writer.py --model qwen3:14b
"""
import argparse
import json
import sys
import urllib.request

OLLAMA = "http://127.0.0.1:11434"


def chat(model, messages, stream=True, options=None):
    payload = {"model": model, "messages": messages, "stream": stream}
    if options:
        payload["options"] = options
    r = urllib.request.Request(
        f"{OLLAMA}/api/chat",
        data=json.dumps(payload).encode(),
        method="POST"
    )
    r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, timeout=600) as resp:
        if stream:
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
        else:
            data = json.loads(resp.read())
            yield data.get("message", {}).get("content", "")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True, help="Ollama model name")
    p.add_argument("--system", default="You are a helpful writing assistant.")
    p.add_argument("--prompt", help="Single prompt (or read from stdin)")
    p.add_argument("--interactive", "-i", action="store_true", help="REPL mode")
    p.add_argument("--options", help="JSON string of Ollama options, e.g. '{\"temperature\":0.7}'")
    args = p.parse_args()

    options = json.loads(args.options) if args.options else None

    if args.interactive:
        print(f"💬 Interactive mode with {args.model} (Ctrl-D to exit)")
        history = [{"role": "system", "content": args.system}]
        while True:
            try:
                user_input = input("\n> ")
            except (EOFError, KeyboardInterrupt):
                print("\n👋 Bye")
                break
            if not user_input.strip():
                continue
            history.append({"role": "user", "content": user_input})
            print()
            full = ""
            for token in chat(args.model, history, options=options):
                print(token, end="", flush=True)
                full += token
            print()
            history.append({"role": "assistant", "content": full})
        return

    # Single prompt mode
    if args.prompt:
        prompt = args.prompt
    else:
        prompt = sys.stdin.read().strip()

    if not prompt:
        print("Error: no prompt provided. Use --prompt or pipe via stdin.")
        sys.exit(1)

    for token in chat(args.model, [{"role": "system", "content": args.system},
                                    {"role": "user", "content": prompt}], options=options):
        print(token, end="", flush=True)
    print()


if __name__ == "__main__":
    main()
