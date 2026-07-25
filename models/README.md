# Quill — Model Layer

Multiple Ollama models + Python orchestrators for long-form book generation.

## Quick start

```bash
# List available presets
python3 models/presets.py presets

# Generate a 15-chapter book (parallel=2 writers)
python3 backend/book_writer.py \
  --title "The Last Cartographer" \
  --premise "..." \
  --chapters 15 \
  --parallel 2

# Use a preset directly
python3 backend/book_writer.py \
  --title "..." \
  --premise "..." \
  --chapters 15 \
  --research-model qwen3:14b \
  --writing-model gemma4:31b

# Single-prompt quick chat
python3 models/ollama_writer.py --model gemma4:latest -p "Write me a limerick"

# Interactive REPL
python3 models/ollama_writer.py --model qwen3:14b -i
```

## Presets

Three pipeline presets are defined in `llm-configs.yaml`:

| Preset | Research | Outline | Writing | Speed | Quality |
|--------|----------|---------|---------|-------|---------|
| `fast-novel` | qwen3:14b | qwen3:14b | gemma4:8b | ⚡⚡⚡ | high |
| `literary-novel` | qwen3:14b | qwen3:14b | gemma4:31b | ⚡ | very high |
| `epic-novel` | qwen3:30b | gpt-oss:20b | qwen3:30b | ⚡ | highest |

## Models available on this machine

| Model | VRAM | Best for |
|-------|------|----------|
| gemma4:31b | 24GB | long-form literary chapters |
| gemma4:latest (8B) | 8GB | fast bulk generation |
| qwen3:30b | 24GB | long coherent arcs |
| qwen3:14b | 12GB | research, outlines, fast |
| gpt-oss:20b | 16GB | thinking-heavy analysis |
| gpt-oss:120b | 80GB | epic review |
| llama3.3:70b | 48GB | highest quality prose |
| qwen3-coder:30b | 24GB | backend / Swift code |
| qwen2.5-coder:32b | 24GB | code review |

## Layout

```
models/
├── llm-configs.yaml     # Single source of truth for model presets
├── presets.py            # Loader + CLI: `python3 presets.py presets`
├── ollama_writer.py      # One-off writer / REPL
└── README.md
```
