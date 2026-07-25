# Quill

**A native macOS writing studio for novelists.** Zed-style editor with a side panel for AI assistance, a bottom panel for terminal/inbox/logs, and a powerful backend that orchestrates local and cloud LLMs.

Quill is co-written with AI: the app itself is the AI writing partner, and the AI chat is the writer. You type, the AI suggests, you accept, autosave kicks in.

## Highlights

- **Native macOS app** (SwiftUI + AppKit) — no Electron, no browser
- **AI chat** with a writing partner persona (Quill), with OpenClaw skill injection
- **Zed-style Tab-to-fix** inline AI corrections (press Tab in the editor to fix typos/grammar on the current selection or sentence)
- **Bottom panel** with **terminal**, **inbox**, **logs** tabs (Cmd+J to toggle)
- **Right panel** with the AI assistant (or use the bottom Terminal tab — both work)
- **Autosave** (2s debounce) + explicit Save button + Cmd+S
- **Multi-model** support via "slots": Ollama (gemma4, qwen3, gpt-oss, llama3, qwen-coder, llama3-groq-tool-use), MLX, LM Studio, MiniMax cloud
- **55 OpenClaw skills** auto-injected into the AI's system prompt (summarize, github, weather, coding-agent, etc.)
- **MCP server** (HTTP `/api/mcp` and stdio `quill mcp serve`) — Claude Desktop, Cursor, etc. can drive Quill
- **Vellum-compatible DOCX export** + PDF / DOCX / MD / TXT / HTML / ePub / RTF / OPML / ZIP bundle
- **`quill` CLI** — full subcommand set (status, ask, chat, fix, slots, projects, chapters, scenes, search, email, mcp, skills) installed to `~/.local/bin/quill`

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Quill.app (SwiftUI + AppKit)                                    │
│  ┌─────────┬──────────────────────────┬──────────────────────┐│
│  │ Sidebar │ Editor (Zed-style,        │ AI Assistant          ││
│  │ (left)  │ MarkdownTextEditor with   │ (right side)         ││
│  │         │ Tab-to-fix inline AI)     │                      ││
│  │         ├──────────────────────────┤                      ││
│  │         │ Bottom Panel:             │                      ││
│  │         │  Terminal | Inbox | Logs  │                      ││
│  └─────────┴──────────────────────────┴──────────────────────┘│
└──────────────────────────────────────────────────────────────────┘
                       │ URLSession (10min/30min timeouts)
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│  Backend: Python Flask on http://127.0.0.1:5323                  │
│  - /api/projects, /api/chapters, /api/scenes                     │
│  - /api/chat (streaming SSE, slot routing, tool calls)            │
│  - /api/edit-fix (Zed-style inline fix)                           │
│  - /api/agentmail/* (Quill inbox via AgentMail)                   │
│  - /api/skills (OpenClaw skills registry)                         │
│  - /api/mcp (JSON-RPC 2.0, HTTP)                                 │
│  - /api/tools/call (web_search, email_send, shell_exec, etc.)    │
└──────────────────────────────────────────────────────────────────┘
                       │
                       ▼
        ┌──────────────┴──────────────┐
        ▼                             ▼
  ┌──────────┐                 ┌──────────┐
  │ Ollama   │                 │ MiniMax  │
  │ (local)  │                 │ (cloud)  │
  └──────────┘                 └──────────┘
```

## Setup

### Prerequisites

- macOS 15+ (Apple Silicon recommended)
- Xcode 15+
- Python 3.11+
- [Ollama](https://ollama.com) installed and running
- Pull the models you want to use:
  ```bash
  ollama pull gemma4:latest
  ollama pull gemma4:31b-mlx  # if you have Apple Silicon
  ollama pull qwen3:30b
  ollama pull llama3-groq-tool-use:8b
  # ...
  ```

### Install

```bash
git clone https://github.com/TheSolAI/quill.git
cd quill
# Backend deps
cd backend && pip install -r requirements.txt  # or: pip install flask flask-cors
cd ..

# Generate Xcode project (if needed)
cd frontend && xcodegen generate

# Build
xcodebuild -project Quill.xcodeproj -scheme Quill -configuration Debug build
```

### Run

```bash
# 1. Start the backend (auto-started by the app via ProcessManager too)
cd backend
python3 server.py
# -> "Quill Backend] Starting on http://localhost:5323"

# 2. Open the app
open frontend/Helpers/Quill.app
# or: open ~/Library/Developer/Xcode/DerivedData/Quill-*/Build/Products/Debug/Quill.app
```

### Install the `quill` CLI

```bash
ln -sf /path/to/quill/frontend/Helpers/quill-ai-helper ~/.local/bin/quill
# Now you can run `quill status`, `quill fix myfile.md`, etc. from anywhere
```

## Usage

### AI chat (right panel)
- Type anything; the AI responds as Quill, your writing partner
- **Long form mode** (default): "write chapter 3" or "make chapter 1" triggers the chapter-write path — prose is generated and saved directly to the chapter file
- **Short form mode**: pure chat for brainstorming, questions, feedback
- The AI knows about 55+ OpenClaw skills (summarize, github, weather, etc.) and the available tools (email, web search, shell)

### Tab-to-fix inline AI (editor)
- Press **Tab** in the editor to fix the current selection (or current sentence/paragraph) via `/api/edit-fix`
- Uses `groq-tool-use:8b` by default for fast precise fixes
- Accept with the replacement or undo with ⌘Z

### Bottom panel tabs
- **Terminal**: REPL shell. Each command is a one-shot Process. Arrow keys for history, Tab for path completion. Try `quill status`, `quill ask "..."`, `quill fix chapter.md`
- **Inbox**: Full email UI. Polls `/api/agentmail/inbox` every 30s. Compose, reply, view messages.
- **Logs**: Two streams — Action log (in-app actions) + Backend log (`/tmp/quill_backend.log`). Filter by level, search text.

### Save behavior
- **Autosave**: 2s debounce after every edit
- **Save button**: in the editor header — click to save immediately
- **Cmd+S**: menu bar File > Save
- Status indicator shows: `unsaved` → `saving…` → `✓ saved` → `saved`

### MCP server
Quill exposes its tools via MCP. Connect from Claude Desktop, Cursor, or any MCP client:

```json
{
  "mcpServers": {
    "quill": {
      "command": "quill",
      "args": ["mcp", "serve"]
    }
  }
}
```

Or HTTP: `http://127.0.0.1:5323/api/mcp` (JSON-RPC 2.0)

### `quill` CLI

```bash
quill status                              # show active model, project, etc.
quill slots                               # list AI slots
quill slots active gemma4-fast           # activate a slot
quill ask "what is 2+2?"                  # one-shot Q&A
quill chat                                # interactive chat
quill fix chapter.md                      # fix typos/grammar in place
quill expand chapter.md                   # add sensory detail
quill condense chapter.md                 # tighten prose
quill projects list                       # list projects
quill chapters ls                         # list chapters
quill search "Tolkien influences"          # web search
quill email list                          # list inbox
quill email send user@x.com "Hi" "..."    # send email
quill skills                              # list OpenClaw skills
quill mcp serve                           # start MCP server (stdio)
```

## Project layout

```
quill/
├── backend/                       # Python Flask server
│   ├── server.py                  # main API (2500+ lines, 60+ endpoints)
│   ├── skills.py                  # OpenClaw skills registry
│   ├── dross_tools.py             # web_search, email, shell_exec, file ops
│   ├── agentmail_service.py       # AgentMail API wrapper
│   ├── web_search.py              # DuckDuckGo HTML scraper
│   ├── vellum_docx.py             # Vellum-compatible DOCX builder
│   ├── book_writer.py             # multi-pass long-form generator (CLI)
│   ├── simulate.py                # end-to-end smoke test
│   └── tests/                     # 289 passing tests
├── models/                        # AI slot system
│   ├── slots.py                   # slot model + persistence
│   ├── slot_providers.py          # Ollama/MLX/MiniMax/LMStudio/Custom
│   ├── presets.py                 # default slot presets
│   └── ollama_writer.py           # legacy
├── frontend/
│   ├── Quill/                     # macOS app source
│   │   ├── AppDelegate.swift      # menu bar, window setup
│   │   ├── AppCommands.swift       # AppCommandsState (sheets, save doc)
│   │   ├── main.swift              # entry point
│   │   ├── Models/                 # data models
│   │   │   ├── Models.swift        # AppState (main state)
│   │   │   ├── PanelState.swift    # panel + tabs
│   │   │   ├── InboxMessage.swift
│   │   │   └── ToastCenter.swift   # notification system
│   │   ├── Services/               # backend + AI
│   │   │   ├── BackendService.swift  # URLSession actor
│   │   │   ├── LLMProvider.swift   # legacy LLMRegistry
│   │   │   ├── LLMSlotProvider.swift # slot-based AI
│   │   │   └── ProcessManager.swift # backend lifecycle
│   │   ├── Views/                  # SwiftUI views
│   │   │   ├── MainView.swift
│   │   │   ├── SidebarView.swift
│   │   │   ├── EditorView.swift
│   │   │   ├── MarkdownTextEditor.swift
│   │   │   ├── AIAssistantView.swift
│   │   │   ├── PanelContainer.swift
│   │   │   ├── TerminalTab.swift
│   │   │   ├── InboxTab.swift
│   │   │   ├── LogsTab.swift
│   │   │   ├── StoryBibleView.swift
│   │   │   ├── CorkboardView.swift
│   │   │   ├── SettingsView.swift
│   │   │   └── ExportView.swift
│   │   └── Utilities/Extensions.swift
│   ├── Helpers/
│   │   └── quill-ai-helper.swift   # the `quill` CLI
│   ├── project.yml                 # XcodeGen config
│   └── Quill.xcodeproj             # generated by xcodegen
└── README.md
```

## Tests

```bash
cd backend
python3 -m pytest tests/ -v
# 289 passed, 1 skipped
```

## License

MIT
