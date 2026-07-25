"""
Quill model presets — load from llm-configs.yaml and apply to book_writer.py.
Each preset is a complete pipeline of (research, outline, writing) model choices.
"""
import yaml
from pathlib import Path

CONFIG_PATH = Path(__file__).parent / "llm-configs.yaml"


def load_config():
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def get_preset(name):
    """Return a preset by name. Available: fast-novel, literary-novel, epic-novel."""
    cfg = load_config()
    return cfg["providers"]["presets"][name]


def list_presets():
    return list(load_config()["providers"]["presets"].keys())


def get_model_info(model_id):
    """Return metadata for a specific model."""
    cfg = load_config()
    for m in cfg["providers"]["ollama"]["models"]:
        if m["id"] == model_id:
            return m
    return None


def list_models_by_purpose(purpose):
    """Return all models for a given purpose (e.g. 'long-form-creative')."""
    cfg = load_config()
    return [m for m in cfg["providers"]["ollama"]["models"]
            if m.get("purpose") == purpose]


if __name__ == "__main__":
    import sys
    cfg = load_config()
    if len(sys.argv) > 1 and sys.argv[1] == "presets":
        print("Available presets:")
        for p in list_presets():
            print(f"  - {p}")
            preset = get_preset(p)
            for k, v in preset.items():
                print(f"      {k}: {v}")
    else:
        print(f"Loaded {len(cfg['providers']['ollama']['models'])} models from {CONFIG_PATH}")
        print(f"Presets: {', '.join(list_presets())}")
