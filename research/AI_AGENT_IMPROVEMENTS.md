# 15 Improvements to Make Quill's AI More Autonomous

Current state: the AI is a **prompt → response** tool. Each generation is one-shot, with context injected from the codex and previous chapters. The user has to drive every step.

Goal: turn it into an **autonomous writing agent** that plans, drafts, critiques, revises, and remembers.

---

## Tier 1 — Highest impact, easiest to implement

### 1. Self-critique loop (writer + critic in dialogue)

**What:** After generating a chapter, run a second model call with a "literary editor" system prompt. The editor returns structured feedback (pacing, voice, sensory density, contradictions). Then the writer revises based on that feedback.

**Why this works:** Most LLM-generated prose is "okay" on first draft. A two-pass loop (write → critique → rewrite) consistently produces output that's noticeably better than a single pass. The same model can be used with different system prompts.

**Implementation:**
```python
def write_with_critique(model, prompt, max_passes=2):
    text = generate(model, prompt, system=WRITER_PROMPT)
    for i in range(max_passes):
        critique = generate(model, text, system=EDITOR_PROMPT)
        if "LGTM" in critique:
            break
        text = generate(model, prompt + "\n\nREVISE BASED ON:\n" + critique, system=WRITER_PROMPT)
    return text
```

**Editor prompt:** "You are a literary editor. Critique this passage for: (1) show-don't-tell violations, (2) sensory density, (3) dialogue naturalness, (4) pacing, (5) any contradictions with the established world. Output numbered issues, or 'LGTM' if no changes needed."

---

### 2. Continuity-aware context injection

**What:** Before generating chapter N, scan all previous chapters and extract: character names + brief descriptions, established locations, key plot points, recurring objects. Inject only the relevant slice into the prompt, not the last 3000 characters.

**Why this works:** Currently the prompt gets `previous[:2000]` which is just the tail. A real novel agent should know that "Mara appeared in chapter 3 as a courier with a limp" even when chapter 15 is being written.

**Implementation:** Run an extraction pass that produces a structured outline (JSON or markdown) of all previous chapters' key facts. Send that as the "previous chapters" context.

---

### 3. Self-evaluation against explicit quality criteria

**What:** After writing, the model rates its own output on a rubric (1-5) for: sensory density, voice consistency, dialogue quality, pacing, character interiority. If any score is below threshold, automatically request a revision focused on the weak dimension.

**Why this works:** Concrete rubrics give the LLM a much sharper target than vague "make it better." Specificity produces specific improvements.

**Implementation:** Define rubric in the system prompt, request the LLM to return JSON with scores + reasoning, parse the scores, loop if needed.

---

## Tier 2 — High impact, moderate effort

### 4. Per-character voice fingerprints

**What:** When the codex defines a character, also generate a "voice fingerprint" — a short paragraph showing how they speak. Inject that into every chapter prompt that includes them.

**Why this works:** Without voice fingerprints, every character sounds like the same generic narrator. With them, the writer has concrete samples to match.

**Example voice fingerprint:**
> Mara speaks in clipped sentences, rarely using adjectives. She uses "Right" and "Fine" as full responses. She never swears but quotes other people who do. Her humor is dry and self-deprecating.

---

### 5. Sensory budget enforcement

**What:** Each chapter is required to include at least N sensory beats (sights, sounds, smells, touches, tastes, temperature). The agent tracks the running total per chapter and, if under budget, generates a "sensory patch" — extra sentences that ground the scene.

**Why this works:** Most LLM prose is visually-only (things look like things). Real literary fiction hits all five senses. A budget forces the model to engage with smell, sound, and texture.

**Implementation:** Count sensory word patterns in the draft. If < threshold, run a follow-up prompt: "Add 5 more sensory details to this passage — currently it has 3, target is 8."

---

### 6. Active plot thread tracking

**What:** Maintain a structured list of plot threads (Fray-style: introduced, escalated, resolved). The agent checks before each chapter that at least one thread is being advanced, and surfaces any threads that have been dormant for N chapters.

**Why this works:** Long-form fiction suffers from "stalled" plot threads. A real writing partner would say "you haven't touched the antagonist in 4 chapters — maybe address them here."

**Implementation:** Store threads in the codex or a separate file. Update after each chapter. Inject into the prompt for the next chapter.

---

### 7. Outline refinement loop

**What:** Before writing chapters, the agent generates a first-draft outline, then critiques it for: weak conflict, missing escalation, character motivations, pacing. Refines until the outline is "solid" before any prose is generated.

**Why this works:** Most AI-generated novels have great prose but limp plots. Spending more time on the outline produces dramatically better results downstream.

**Implementation:** 2-3 iterations of outline generation with self-critique before any chapter writing.

---

### 8. Scene-level craft passes

**What:** After the first draft of a chapter, run a sequence of focused passes:
- **Sensory pass** — add smells, sounds, touch
- **Dialogue pass** — tighten speech tags, vary sentence length in dialogue
- **Interiority pass** — strengthen character thoughts/feelings
- **Cut pass** — remove redundancies and adverbs

**Why this works:** Single prompts trying to do everything produce mediocre everything. Specialized passes produce excellent results in each dimension.

---

## Tier 3 — Architectural improvements (autonomous agent territory)

### 9. Tool use via function calling

**What:** Let the AI call tools during generation: `search_codex(field)`, `get_chapter_summary(n)`, `list_open_threads()`, `count_words_in_chapter()`. This makes the AI an *agent* that can inspect its own state, not a chatbot that just consumes injected context.

**Why this works:** This is the single biggest difference between "AI that writes" and "AI that authors." A real author goes back and re-reads, checks their notes, cross-references. Agents that can do this are dramatically more accurate.

**Implementation:** Ollama supports function calling. Define a set of tools, give them to the model, parse the responses, loop until done.

---

### 10. Long-term memory across sessions

**What:** Store not just the codex, but a structured "author's notebook" — patterns the user likes, edits they made, feedback they gave. Surface relevant memories in each new prompt.

**Why this works:** Every author has a personal style they want preserved across projects. Memory makes the AI feel like a collaborator, not a stranger.

**Implementation:** Store in `.quill_memory.json` per project (or globally). Index by tags (character names, themes, style). Retrieve top-N relevant memories per prompt.

---

### 11. Pre-flight planning phase

**What:** Before writing a chapter, the agent first produces:
1. A 1-paragraph scene synopsis
2. The POV character's emotional state entering and leaving
3. A list of which threads advance
4. The opening image
5. The closing image
6. Target word count

Only after the plan is generated does prose generation begin.

**Why this works:** Planners consistently outperform improvisers. This is one of the strongest findings from agent research.

---

### 12. Failure detection and self-correction

**What:** The agent monitors its own output for known failure modes:
- Repetitive sentence structures
- Telling instead of showing
- Dialogue that all sounds the same
- Plot holes
- Word count way off target
- Untranslated markdown
- Characters with inconsistent voice

When detected, automatically re-generate with a specific fix instruction.

**Why this works:** LLMs make predictable mistakes. A failure-detection layer catches them and corrects.

**Implementation:** A set of regex/heuristic checks + a critic model that returns `{issues: [...], fix_suggestions: [...]}`. Loop on detection.

---

## Tier 4 — Polish and personality

### 13. Persona-based role-play for the AI

**What:** Give the AI a stable persona — not just "you are Quill" but a backstory, motivation, working style. E.g., "You are a former literary magazine editor who ghostwrites novels. You believe in showing not telling, despise adverbs, and have a weakness for well-placed semicolons."

**Why this works:** Concrete personas produce more consistent, distinctive output than abstract instructions. The persona also becomes part of the brand.

---

### 14. Anti-cliché filter

**What:** Run a final pass that scans for known LLM-tells:
- "It wasn't X, it was Y" rhetorical patterns
- "A shiver ran down her spine"
- "Little did she know"
- "The air was thick with"
- Overuse of "suddenly," "just," "really"

Replace flagged phrases with something fresher.

**Why this works:** These patterns are fingerprints of LLM prose. Removing them dramatically improves perceived quality.

**Implementation:** Regex list + a critic pass. The critic returns: `[{"phrase": "...", "fix": "..."}]`.

---

### 15. User-feedback learning loop

**What:** When the user accepts, edits, or rejects a chapter, learn from that signal. Over time, the agent's style drifts toward what the user actually publishes.

**Why this works:** This is the difference between a tool and a collaborator. A real writing partner absorbs your preferences; a tool doesn't.

**Implementation:** After every chapter accept/edit, store a delta record: `{chapter_id, action: "accepted"|"edited"|"rejected", edit_distance: N, user_prefs_learned: [...]}`. Feed the top relevant prefs into future prompts.

---

## Bonus: Implementation priorities

| # | Improvement | Effort | Impact | Autonomous? |
|---|-------------|--------|--------|-------------|
| 1 | Self-critique loop | Low | High | ✓ |
| 2 | Continuity context | Medium | High | ✓ |
| 5 | Sensory budget | Low | High | ✓ |
| 11 | Pre-flight planning | Medium | High | ✓ |
| 9 | Tool use | High | Highest | ✓✓ |
| 10 | Long-term memory | Medium | High | ✓ |
| 3 | Self-evaluation rubric | Low | Medium | ✓ |
| 7 | Outline refinement | Low | High | ✓ |
| 8 | Scene craft passes | Medium | High | ✓ |
| 14 | Anti-cliché filter | Low | High | ✗ (post-process) |
| 6 | Plot thread tracking | Medium | Medium | ✓ |
| 12 | Failure detection | Medium | High | ✓ |
| 4 | Voice fingerprints | Medium | High | ✗ (setup) |
| 15 | Feedback loop | High | Highest | ✓ |
| 13 | Persona | Low | Medium | ✗ (style) |

**Recommended first 5 to ship:**
1. Self-critique loop (1)
2. Continuity-aware context (2)
3. Sensory budget (5)
4. Pre-flight planning (11)
5. Anti-cliché filter (14)

These are all incremental changes to `book_writer.py` and `stream_long_form` in `server.py`. None require new infrastructure.

**The big leap:** adding tool use (#9) turns Quill from a writing tool into a writing *agent*. The agent can then drive its own quality loop without user intervention. This is the future-proof direction.
