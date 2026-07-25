# Quill — Native macOS Writing Assistant

A **Zed-inspired** native macOS writing app powered by local AI. Three-panel layout: chapters on the left, markdown editor in the center, AI assistant on the right.

---

## Architecture

```
Quill.app (SwiftUI + AppKit)
    │
    ├── starts backend ──► http://localhost:5323
    │                         │
    │                         ├── Flask backend (server.py)
    │                         │     ├── File CRUD for .md chapters
    │                         │     ├── Compile & export (PDF, DOCX, MD, TXT)
    │                         │     └── Ollama API wrapper → gemma4
    │
    └── quill-ai-helper (bundled Swift CLI)
          └── bridges to Ollama or Apple Intelligence

user's ~/Projects/Quill/projects/...
```

---

## Setup

### 1. Install Ollama

```bash
brew install ollama
ollama pull gemma4
```

### 2. Install Python dependencies

```bash
cd ~/Projects/Quill/backend
pip install -r requirements.txt
```

### 3. Install Pandoc (for export)

```bash
brew install pandoc
```

### 4. Generate the Xcode project

```bash
cd ~/Projects/Quill/frontend
which xcodegen || brew install xcodegen
xcodegen generate
```

### 5. Open and build in Xcode

```bash
open ~/Projects/Quill/frontend/Quill.xcodeproj
```

- Select **Quill** target → **My Mac** → press **⌘R** to run

Or from the command line:

```bash
cd ~/Projects/Quill/frontend
xcodebuild -project Quill.xcodeproj -scheme Quill -configuration Debug build
```

---

## Features

### Three-Panel Layout
- **Left — Chapters sidebar**: project list, chapter list, word count
- **Center — Markdown editor**: write and edit chapters with auto-save
- **Right — AI Assistant**: chat, chapter generation, file operations

### AI Modes

Toggle between two modes in the AI panel:

| Mode | Description |
|------|-------------|
| **Short** | Chat, brainstorming, character questions, plot feedback |
| **Long** | Multi-pass chapter generation — scene write → sensory enhancement → character tracking → summary update |

### Natural Language File Operations

The AI assistant understands commands like:

```
create chapter 3
→ Creates chapter-3.md instantly

rename chapter 1 to chapter-one
→ Renames the file

delete chapter 2
→ Removes the file

write chapter 3
→ Detects the intent, creates the chapter, and streams content
```

### Compile & Export (`⌘E`)

Merge all chapters into a single manuscript with YAML front matter. Export to:

| Format | Notes |
|--------|-------|
| **PDF** | Print-ready via Pandoc + weasyprint |
| **DOCX** | Microsoft Word via Pandoc |
| **Markdown** | Raw merged `.md` with all chapters |
| **Plain Text** | Stripped markdown, no formatting |

### Project Settings (`⌘,`)

Configure per-project metadata that feeds into exports:

- **Title** — book title
- **Author** — your name
- **Genre** — fiction category
- **Dedication / Epigraph** — front matter
- **Style Notes** — narrative voice, tone, and preferences for AI generation

---

## Menu Bar

| Menu | Items |
|------|-------|
| **Quill** | About, Settings, Quit |
| **File** | New Project (`⌘N`), Export Book (`⌘E`), Compile Preview (`⌘⇧P`), Close (`⌘W`) |
| **Edit** | Undo, Redo, Cut, Copy, Paste, Select All |
| **View** | Toggle Sidebar (`⌘⌃S`), Toggle AI Panel (`⌘⌃A`), Full Screen |
| **Window** | Minimize, Zoom, Bring All to Front |
| **Help** | Quill Help |

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘N` | New project |
| `⌘E` | Export book |
| `⌘⇧P` | Compile preview |
| `⌘,` | Project settings |
| `⌘W` | Close window |
| `⌘Q` | Quit Quill |
| `⌘⌃S` | Toggle sidebar |
| `⌘⌃A` | Toggle AI panel |

---

## AI Providers

Three options in Settings. Choose whichever fits your setup:

| Provider | How it works |
|----------|-------------|
| **Ollama (Local)** | Direct HTTP to Flask backend → Ollama gemma4 |
| **Swift Helper (Local)** | Bundled Swift CLI bridge to Ollama — same models, native path |
| **Apple Intelligence** | On-device AI via Apple framework — requires macOS 26+ |

Both Ollama routes use your local `gemma4:latest` model. Apple Intelligence is a stub — swap in the real framework once it ships.

---

## Testing

```bash
cd ~/Projects/Quill/backend
./run_tests.sh
```

48 backend tests covering health, projects, chapters, context, settings, compile, export, and file-op parsing/execution.

---

## Customisation

**Change the AI model** — Edit `~/Projects/Quill/backend/server.py`:
```python
MODEL = "llama3.3:latest"   # change from gemma4:latest
```

**Change the project directory** — Edit `BASE_DIR` in `server.py`:
```python
BASE_DIR = Path.home() / "Projects" / "Quill" / "projects"
```

**Rebuild after changes:**
```bash
xcodegen generate  # after Swift changes
cd ~/Projects/Quill/backend && python3 server.py  # restart backend after Python changes
```

---

## Troubleshooting

**"Cannot connect to backend"**
→ The backend failed to start. Run manually:
```bash
cd ~/Projects/Quill/backend && python3 server.py
```

**Ollama not running**
→ Start it manually:
```bash
ollama serve
```

**gemma4 not found**
→ Pull it:
```bash
ollama pull gemma4
```

**PDF/DOCX export fails**
→ Install Pandoc:
```bash
brew install pandoc
```
For best PDF quality, also install weasyprint:
```bash
pip install weasyprint
```

**Apple Intelligence shows as unavailable**
→ That's expected on macOS versions below 26. Use Ollama instead — the feature is stubbed and ready to wire up when the framework ships.
