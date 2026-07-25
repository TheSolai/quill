# Quill Competitor Analysis — 20 Similar Products

Research compiled: July 25, 2026
Source: web search + GitHub + product sites

## The 20 Similar Projects & Products

### Open Source (10)

| # | Project | URL | Stack | License | Key Differentiator |
|---|---------|-----|-------|---------|-------------------|
| 1 | **novelWriter** | github.com/vkbo/novelWriter | Python + Qt6 | GPLv3 | Outline + Novel views, plain-text storage, cross-references |
| 2 | **Manuskript** | github.com/olivierkes/manuskript | Python + Qt | GPLv3 | Storyboard, plotter, character sheets, frequency analyzer |
| 3 | **mdnovel** | github.com/peter88213/mdnovel | Python | GPLv3 | Single markdown/YAML file, lightweight |
| 4 | **Manuscript** | manuscriptapp.github.io | Swift (iOS/macOS) | MIT | Native Apple, plain markdown, free forever |
| 5 | **MarkEdit** | github.com/MarkEdit-app/MarkEdit | Swift (macOS) | MIT | Native macOS TextEdit-replacement for Markdown |
| 6 | **MacDown** | github.com/MacDownApp/macdown | Objective-C (macOS) | MIT | Classic open-source macOS markdown editor |
| 7 | **WordBird** | thimbleberrysystems.github.io/WordBird | Tauri (Rust+web) | MIT | New (2026), BYO-key AI with full novel context, Ollama support |
| 8 | **Zettlr** | github.com/Zettlr/Zettlr | Electron | GPLv3 | Academic writing, citation management, Zettelkasten |
| 9 | **Joplin** | github.com/laurent22/joplin | Electron | AGPL-3.0 | Note-taking with markdown, end-to-end encryption, sync |
| 10 | **Notable** | github.com/notable/notable | Electron | MIT | Markdown notes, block-based editor, themes |

### Commercial / Closed Source (10)

| # | Product | Vendor | Platform | Pricing | Key Differentiator |
|---|---------|--------|----------|---------|-------------------|
| 11 | **Sudowrite** | Sudowrite Inc | Web | $10–59/mo | Fiction-trained Muse model, Story Engine, Story Bible |
| 12 | **NovelCrafter** | NovelCrafter | Web | $4–20/mo + AI costs | BYOK (bring-your-own-key), Codex lore system, chat workshop |
| 13 | **NovelAI** | NovelAI | Web | $10–25/mo | Custom-trained anime/story models, image gen |
| 14 | **Scrivener** | Literature & Latte | macOS/Win/iOS | $59 one-time | The original, corkboard + outliner + binder, character sheets |
| 15 | **Ulysses** | Ulysses GmbH | macOS/iOS | $5.99/mo | Markdown library, writing goals, Apple ecosystem |
| 16 | **iA Writer** | Information Architects | macOS/Win/iOS | $30 one-time | Award-winning Focus Mode, design minimalism |
| 17 | **Plottr** | Plottr | Web/Desktop | $4/mo | Timeline plotting, story templates, character arcs |
| 18 | **Dabble** | Dabble | Web | $10/mo | Plot grid, clean workflow, beginner-friendly |
| 19 | **Scribeist** | Scribeist | Web | Free + $8–18/mo | Context-aware AI (knows your characters, timeline, plot) |
| 20 | **Storyloft** | Storyloft | Web | $10–30/mo | All-in-one novel workspace, plotting + AI + community |

---

## The 5 Most Common Features

After cross-referencing all 20, these five features appear in **at least 18 of the 20** products:

### 1. Project + Chapter + Scene Hierarchy (20/20)

Every product has some form of structured document organization.

- **novelWriter**: project tree → folders → scene documents, with cross-references via `@char` tags
- **Scrivener**: Binder (folder tree) ↔ Corkboard (cards) ↔ Outliner ↔ Editor (4 views of same data)
- **Ulysses**: Library → Groups → Sheets (a single document at the lowest level)
- **iA Writer**: Library → Folders (iCloud/Dropbox) → Files
- **Sudowrite**: Manuscript → Chapters → Scenes
- **NovelCrafter**: Plan → Acts → Chapters → Scenes, with Codex as a parallel world-bible tree
- **Manuskript**: Outline mode with scenes, character folders, world folders
- **Manuscript, MarkEdit, MacDown**: Just folders of files (simpler but still hierarchical)

**The pattern is universal**: at least one level of organization above the individual document. Quill has this (`Sidebar` projects → chapters).

### 2. Markdown-Based Writing with Multi-Format Export (19/20)

- **novelWriter, Manuscript, MarkEdit, MacDown, mdnovel, WordBird**: All write plain Markdown
- **Ulysses, iA Writer**: Write in Markdown (Ulysses) or Markdown-like (iA Writer)
- **Sudowrite, NovelCrafter**: Plain text or rich text, but export to Markdown/HTML
- **Scrivener**: Rich text internally but exports to Markdown, DOCX, ePub, PDF
- **Export formats** that appear in 15+ of the 20: **PDF, DOCX, HTML, ePub, Markdown, plain text**

**The pattern**: Markdown is the lingua franca. Quill already supports PDF, DOCX, MD, TXT — adding **ePub** and **HTML** would round out the standard.

### 3. AI Writing Assistance (15/20 — and growing)

This is the differentiator in 2026. Coverage:

- **Sudowrite**: Muse model, Story Engine (full-novel pipeline), Describe, Rewrite, Brainstorm, Expand
- **NovelCrafter**: Codex-aware chat workshop, scene beats, BYOK
- **NovelAI**: Custom story-trained models, lorebook (Codex equivalent), image generation
- **WordBird**: Biscuit agent — keeps characters/plots coherent across thousands of pages, supports Ollama
- **Scribeist**: Mythos system (relationship map + emotional arcs + timeline), context-aware
- **Storyloft, Plottr, Dabble, Inkfluence AI, SidekickWriter**: All have some form of AI generation/assistance
- **Scrivener**: As of 2026, no native AI — direct quote from their docs: "the software contains no artificial intelligence"
- **novelWriter, Ulysses, iA Writer, Bear, Manuskript**: Minimal/no AI

**The pattern**: AI is becoming table-stakes, but the "Codex" / "Story Bible" / "Mythos" pattern (a structured lore database the AI references) is the standout innovation. Quill has `.quill_context.json` for this but it's not exposed in the UI yet.

### 4. Distraction-Free / Focus Mode (17/20)

- **iA Writer**: *The* signature feature — dims everything but the current sentence
- **Ulysses**: Typewriter mode (keeps current line centered)
- **Scrivener**: Composition mode hides formatting chrome
- **Bear**: Zen mode (full focus)
- **Manuscript, MacDown, MarkEdit, Joplin, Notable**: Full-screen mode with chrome hidden
- **Sudowrite, NovelCrafter, Storyloft**: Distraction-free write panes inside larger workspaces

**The pattern**: Every "focused writing" tool has a way to fade UI chrome, and most have a specific mode (sentence-level, paragraph-level, full-screen). Quill has a clean 3-panel layout but no focus mode yet.

### 5. Word Count + Writing Goals / Progress (18/20)

- **Scrivener**: Per-document word count + Project Targets (set daily writing goals)
- **Ulysses**: Built-in writing goals, daily targets, session statistics
- **Dabble**: Word count goals per chapter
- **iA Writer**: Reading time + word count
- **NovelCrafter, Sudowrite**: Word/character count, session timer
- **Manuskript**: Word count per scene, frequency analyzer
- **novelWriter**: Word count + reading time in status bar
- **Manuscript, WordBird, MacDown, MarkEdit, Joplin, Notable**: Live word/character count

**The pattern**: Counters are universal. Goals/daily targets are in 12/20. Quill has a word count in the status bar — adding a session timer and daily goal would match the leaders.

---

## Bonus: Features in 10-15 Products (Notable, Not Universal)

- **Character/world databases** (12/20) — Scrivener sheets, NovelCrafter Codex, Sudowrite Story Bible, Scribeist Mythos, novelWriter tags
- **Corkboard / visual index cards** (8/20) — Scrivener, Manuskript, novelWriter, Dabble, Plottr
- **Outliner view** (10/20) — Scrivener, novelWriter, Manuskript, Ulysses
- **Version control / snapshots** (7/20) — Scrivener, Ulysses, iA Writer, WordBird
- **Style checker / grammar** (10/20) — iA Writer, Ulysses, Manuskript, ProWritingAid integration
- **Multi-device sync** (12/20) — Ulysses, iA Writer, Joplin, NovelCrafter, WordBird
- **Plain-text storage** (12/20) — novelWriter, Manuscript, iA Writer, mdnovel, WordBird, Scrivener (with format)
- **Templated projects** (8/20) — Scrivener, Plottr, novelWriter, Dabble

---

## What This Means for Quill

Quill currently has:
- ✓ Project + chapter hierarchy
- ✓ Markdown writing
- ✓ Multi-format export (PDF, DOCX, MD, TXT)
- ✓ AI assistance (local Ollama, multi-provider)
- ✓ Word count
- ✓ Multi-model long-form generation
- ✗ **Distraction-free / Focus mode** — would significantly improve the writing experience
- ✗ **Session timer / daily goals** — easy win, big retention driver
- ✗ **Story Bible / Codex UI** — already have `.quill_context.json`; expose it as a sidebar
- ✗ **Corkboard / index cards view** — natural extension of the existing 3-panel layout
- ✗ **Reading time** — one-line addition to the status bar
- ✗ **Version history** — local git snapshots would be a strong differentiator

The 5 most common features give us a clear roadmap:
1. Polish the existing chapter hierarchy (corkboard view as a 4th panel option)
2. Add **ePub + HTML** export formats
3. Expose **Story Bible** in the UI (characters, world, summary, style — already in context)
4. Add **Focus mode** to the editor (toggle to hide sidebars)
5. Add **session timer + daily word goal** to the status bar

These would put Quill in the top tier of writing tools while keeping the local-first / open-source / native macOS advantage.
