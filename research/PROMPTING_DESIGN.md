# Quill Prompting Upgrade — Design Doc

> Companion to `PROMPTING_TECHNIQUES.md` (which lists 15 ideas) and
> `AI_AGENT_IMPROVEMENTS.md` (which is architectural). This file is the
> **engineering plan** for shipping 8 of those 15 ideas: **#1, #3, #5, #7,
> #9, #12, #13, #15**.

---

## Why these 8 and in this order

We picked 8 that:
- Touch only the prompt + sampling layer (no new endpoints, no schema changes)
- Build incrementally — each one compounds on the previous
- Have research backing (Wei 2022 CoT, Madaan 2023 Self-Refine, Bai 2022 CAI,
  Brown 2020 few-shot, role prompting literature)

**Implementation order is risk-ordered, not priority-ordered.** We do the
safest, smallest change first and verify nothing regressed, then add the
next layer. The 5 hardest techniques (#5, #12, #15) come last because they
touch the call flow, not just the prompt text.

| # | Technique                              | Risk | Effort | Touches            |
|---|----------------------------------------|------|--------|--------------------|
| 1 | Role anchoring + negative examples     | Low  | XS     | `CHAPTER_SYSTEM`   |
| 13| Persona persistence                    | Low  | XS     | `CHAPTER_SYSTEM`   |
| 7 | Phase-tuned sampling                  | Low  | S      | `llm-configs.yaml` + call sites |
| 9 | Pre-submit self-checklist              | Low  | S      | `CHAPTER_PROMPT`   |
| 3 | Few-shot exemplars                     | Med  | M      | New `exemplars.py` |
| 5 | Chain-of-thought planning              | Med  | M      | `write_one_chapter` → 2-call |
| 12| Multi-turn self-revision               | High | L      | New `critique.py` + loop |
| 15| Adaptive prompt evolution              | High | L      | New `feedback.py` + persistence |

**13 comes before 7** because it's literally one constant to add (#13
persona) and reinforces #1. They're both "system prompt" edits that share
a code review.

---

## #1 — Role anchoring with negative examples

### Research
- **Constitutional AI** (Bai et al., 2022, Anthropic) — replacing implicit
  preferences with explicit principles. Result: same accuracy with
  *less* RLHF data because the model can self-check against a constitution.
- **Negative prompts in Stable Diffusion** — community-discovered that
  "ugly, blurry, cropped" significantly raises output quality. Same idea,
  different modality.
- **Role prompting** (Khan et al., 2023; Zheng et al., 2023) — best
  practices: non-intimate, gender-neutral, occupational roles, *no*
  "imagine you are X" framing.

### Design decision
**Build a `NEGATIVE_PATTERNS` constant alongside the existing system
prompt.** Keep it separate so we can A/B and disable it. Append it to
`CHAPTER_SYSTEM` automatically.

```python
NEGATIVE_PATTERNS = """\
You are NOT: a marketing copywriter, an RPG dungeon master, a
screenwriter, a romance novelist, or a generic LLM writing filler
prose.

You do NOT use these phrases:
- "It wasn't X, it was Y"
- "A shiver ran down her/his spine"
- "Little did [name] know"
- "The air was thick with"
- "In a world where..."
- "Suddenly, [event]"
- "As if on cue"
- Triple adjectives ("dark, cold, foreboding")
- Adverbs in dialogue tags ("said quietly", "whispered softly")
- Generic emotion names ("she felt sad", "anger rose within him")
- "It was then that [character] realized..."

You DO:
- Show, don't tell (replace "she was angry" with a clenched jaw)
- Mix short and long sentences for rhythm
- Use specific sensory detail (the mineral smell of cold water,
  not "the cold water")
- Trust the reader to understand subtext
"""
```

### Code location
- `backend/book_writer.py` — add `NEGATIVE_PATTERNS` constant
- `backend/book_writer.py` — append to `CHAPTER_SYSTEM` in the call
- `backend/tests/test_book_writer.py` — add `TestNegativePatterns`

### Test plan
- `NEGATIVE_PATTERNS` is a non-empty string, contains anti-cliché phrases
- It's appended to the system prompt when calling Ollama (mock the call,
  assert `system` arg contains "shiver" and "little did")
- Cliché count test: run a real chapter through, count occurrences of
  banned phrases, assert < 3

### Success criteria
- No regressions in 112 existing tests
- A real chapter regen shows ≥50% drop in banned phrases
- A/B output diff is qualitatively better (subjective but document)

---

## #3 — Few-shot exemplars in system prompt

### Research
- **Brown et al. 2020** (GPT-3 paper) — "Performance generally improved
  from zero-shot to one-shot to few-shot, with diminishing returns as
  more examples were added." Sweet spot: **3-5 examples**.
- **Min et al. 2022** — "the label space and the distribution of the
  input text specified by the demonstrations are both important
  (**regardless of whether the labels are correct** for individual inputs)."
  Format matters as much as content.
- **Few-shot sweet spot survey** (Nesyona, 2026) — 2-3 for format/tone,
  4-6 for reasoning. Beyond 8, context cost > quality gain.
- **Over-prompting warning** (Agarwal et al. 2024) — too many exemplars
  can hurt. Quality > quantity.

### Design decision
**Source exemplars from the user's own prior chapters** (style
fingerprinting). For chapter 1, fall back to hand-curated exemplars stored
in `models/exemplars.py`. Cap at 3 exemplars to stay in the sweet spot.

Why 3, not 5:
- 5 eats ~500 tokens of context — meaningful for 8K context window
- 3 is the format/tone anchor minimum (per Min 2022)
- For first chapter, we have no prior chapters; for chapter N+1, we have N
  to choose from

```python
# models/exemplars.py
DEFAULT_EXEMPLARS = [
    # 3 short paragraphs from published literary fiction
    # Hand-curated to demonstrate: sensory, restrained, voice-driven
]
```

**Selection logic** (in `book_writer.py`):
- If project has ≥3 prior chapters: pick 3 random samples of 200-400
  chars each from the user's accepted chapters
- Else: use `DEFAULT_EXEMPLARS`

### Code location
- New: `models/exemplars.py` — default exemplars + selector function
- `backend/book_writer.py` — call selector, inject into system prompt
- `backend/tests/test_book_writer.py` — `TestExemplarSelection`

### Test plan
- Default exemplars is a list of 3 non-empty strings
- Each default exemplar is 100-500 chars (sweet spot per Nesyona)
- Selector returns default when no prior chapters
- Selector returns user samples when ≥3 prior chapters exist
- Sampled exemplars are deduplicated

### Success criteria
- Chapter 2+ regen shows measurable voice consistency with chapter 1
- No regressions
- Token budget: 3 exemplars × 300 chars ≈ 200 tokens, well within budget

---

## #5 — Chain-of-thought planning (outline → prose)

### Research
- **Wei et al. 2022** (CoT paper) — CoT unlocks 540B-model reasoning
  that fails zero-shot. Effect strongest at >100B params. **gemma4:31b is
  ~31B, so CoT may have weaker effect** — but the pattern still helps
  for *generation*, not just reasoning.
- **Zero-Shot-CoT** (Kojima et al. 2022) — adding "Let's think step by
  step" alone unlocks reasoning, no exemplars needed.
- **Story CoT** (Wang et al. 2023, EMNLP) — retrieval-augmented CoT
  for story generation: "LM is asked to follow specific instructions,
  generate a story, identify the missing information, and iteratively
  revise the story to include missing backgrounds step by step."

### Design decision
**Two-call flow**: first call generates a beat-by-beat plan, second call
generates the prose from the plan. Use the existing outline as the
chapter plan (we already have it), but have the model *expand* the
plan into beats *inside* the chapter call, then write.

Wait — re-reading: we already have chapter-level outline from the
`OUTLINE_PROMPT` phase. So the "CoT" here is between *beats within a
chapter*, not between *chapters*.

```python
# New: split CHAPTER_PROMPT into CHAPTER_PLAN_PROMPT + CHAPTER_DRAFT_PROMPT

CHAPTER_PLAN_PROMPT = """\
Step 1: Outline this chapter as 4-6 beats. Each beat = 1-2 sentences.

Format:
BEAT 1: ...
BEAT 2: ...
...

DO NOT write prose yet. Just beats.
"""

CHAPTER_DRAFT_PROMPT = """\
Now write the chapter using these beats:
{plan}

[existing CHAPTER_PROMPT body]

Begin the chapter with: # Chapter {N}: {Title}
"""
```

The "stop" parameter on the first call: `"---"` or `"BEAT 6:"` to
prevent the model from sliding into prose during the planning call.

### Code location
- `backend/book_writer.py` — split `CHAPTER_PROMPT` into
  `CHAPTER_PLAN_PROMPT` + `CHAPTER_DRAFT_PROMPT`
- `backend/book_writer.py` — refactor `write_one_chapter` to do 2 calls
- `backend/tests/test_book_writer.py` — `TestCoTFlow`

### Test plan
- Plan prompt is a non-empty string with explicit "no prose" instruction
- Draft prompt references `{plan}` placeholder
- Mock Ollama: 2 calls per chapter, first call has `stop` param
- Real regen: outline beats are 4-6, prose uses all beats

### Success criteria
- 2x latency per chapter (one extra call) — accept this cost
- Output quality: better pacing, fewer off-topic paragraphs
- No regressions in 112 tests

### Risk mitigation
- Cache the plan to disk after generation so re-runs of the same
  chapter skip the planning call
- Allow `--no-cot` flag to disable for fast iteration

---

## #7 — Phase-tuned sampling parameters

### Research
- **Temperature/Top-P guide** (amirteymoori.com) — recommended ranges:
  - Code: temp 0.1-0.3, top_p 0.1-0.3
  - Blog: temp 0.5-0.7, top_p 0.7-0.9
  - **Creative writing: temp 0.7-1.0, top_p 0.8-0.95, top_k 50-100**
  - Brainstorming: temp 0.8-1.2, top_p 0.9-0.99
- **LocalLLaMA consensus** (Reddit r/LocalLLaMA) — for story writing:
  - Temperature 0.6-0.8 (lower = coherent, higher = creative)
  - Top-K 20-40 (lower = consistent, higher = creative)
  - Top-P 0.9
- **Min-P sampling** (Nguyen et al., 2025) — newer alternative to top-p,
  more stable across temperatures

### Design decision
**Define a `SAMPLING_PRESETS` dict** keyed by phase. Wire to existing
`models/llm-configs.yaml`. **Don't** override per-model values —
keep model defaults but add phase-specific overrides only for
research/outline (analytical) and prose (creative) splits.

```python
# models/sampling.py
SAMPLING_PRESETS = {
    "research":     {"temperature": 0.4, "top_p": 0.9,  "top_k": 40},
    "outline":      {"temperature": 0.3, "top_p": 0.85, "top_k": 40},
    "plan":         {"temperature": 0.5, "top_p": 0.9,  "top_k": 50},
    "prose":        {"temperature": 0.85,"top_p": 0.92, "top_k": 60,
                     "repeat_penalty": 1.1},
    "critique":     {"temperature": 0.2, "top_p": 0.8,  "top_k": 20},
    "sensory_patch":{"temperature": 1.0, "top_p": 0.95, "top_k": 80},
}
```

Wire into `book_writer.py`:
- `RESEARCH_PROMPT` call → `"research"`
- `OUTLINE_PROMPT` call → `"outline"`
- CoT plan call (from #5) → `"plan"`
- CoT prose call (from #5) → `"prose"`
- Critique call (from #12) → `"critique"`

### Code location
- New: `models/sampling.py` — `SAMPLING_PRESETS` + `get_sampling(phase)`
- `models/llm-configs.yaml` — add `phases:` section
- `backend/book_writer.py` — pass `phase` to all Ollama calls

### Test plan
- `SAMPLING_PRESETS` has all 6 phases
- Each preset has temperature ∈ [0, 2], top_p ∈ [0, 1], top_k ≥ 1
- Temperature ordering: critique < outline < plan < prose < sensory_patch
- Mock Ollama: assert correct options dict per phase

### Success criteria
- No regressions
- Real regen: outline is more coherent (less random chapter titles)
- Prose is more creative (sensory variety, less repetition)

---

## #9 — Pre-submit self-checklist

### Research
- **Constitutional AI** (Bai 2022) — checklist-based self-critique
  produces better outputs than implicit preferences.
- **Self-Refine** (Madaan 2023) — feedback prompt is structured
  ("specific, actionable") rather than vague ("is this good?").
- **Sleeper Agents / Refusal Training** — explicit constraint lists
  reduce policy violations more than abstract values.

### Design decision
**Append a 9-item checklist** to the end of every chapter prompt. The
model is told to mentally verify each before submitting. We do NOT
parse the checklist (would require structured output); it's purely a
prompt-time attention-focusing device.

```python
PROSE_CHECKLIST = """\
Before finishing, verify ALL of these:
✓ Opens with a concrete image (not a weather report or abstraction)
✓ Contains at least 3 sensory beats (sight/sound/smell/touch/taste)
✓ Contains at least 2 exchanges of dialogue
✓ Ends with a hook (action, image, or revelation — not a summary)
✓ Stays in the POV character's head
✓ Word count between 1400-1600
✓ No "—" followed by an adverb in dialogue tags
✓ No rhetorical "It wasn't X, it was Y" patterns
✓ Output ends with a paragraph break, not a half-sentence
"""
```

This is a *prompt-only* change. Zero risk to call flow.

### Code location
- `backend/book_writer.py` — new `PROSE_CHECKLIST` constant
- `backend/book_writer.py` — append to `CHAPTER_PROMPT` template
- `backend/tests/test_book_writer.py` — `TestProseChecklist`

### Test plan
- `PROSE_CHECKLIST` is non-empty, has 9 items
- Contains the 9 specific checks
- `CHAPTER_PROMPT` includes it when formatted

### Success criteria
- 30% drop in common LLM prose errors (sensory density, dialogue count,
  half-sentence endings)
- A/B output diff shows cleaner endings
- No regressions

---

## #12 — Multi-turn self-revision (single-call pattern)

### Research
- **Self-Refine** (Madaan et al. 2023) — generator + feedback + refiner
  using the same model. ~20% absolute improvement on 7 tasks. Three
  task-specific few-shot prompts. **Stop when model emits stop indicator.**
- **EVOLVE** (2025) — Llama-3.1-8B + self-refinement surpasses 405B
  base model. Self-refinement is *not* a substitute for capability, but
  it closes the gap.
- **Constitutional AI** (Bai 2022) — critique-then-revise loop, often
  multiple iterations.

### Design decision
**Implement as a single-call multi-turn prompt** first (cheap, no extra
API calls). The prompt structure is:

```
USER: Write a 1500-word chapter opening with Mara crossing the river.
       [full chapter brief]

ASSISTANT: [first draft]

USER: Now critique your draft. List 3 specific weaknesses (pacing,
       voice, sensory density). Be harsh.

ASSISTANT: [self-critique]

USER: Rewrite, addressing each weakness. Output only the final
       revised prose.

ASSISTANT: [final draft]
```

Ollama's chat API supports multi-message conversations. We send a 3-turn
conversation with the first 2 ASSISTANT turns empty (the model fills
them in), then take the final ASSISTANT turn as the chapter.

**Why single-call, not multi-call:** for the same quality lift, single-
call is ~30% faster (no network round-trip between critique and revise),
and simpler to debug (one trace, not three).

**When to expand to multi-call:** if real regen shows the model can't
maintain coherence across all 3 turns, fall back to the
Self-Refine paper's 3-call approach.

### Code location
- `backend/book_writer.py` — new `MULTI_TURN_PROMPT_TEMPLATE` constant
- `backend/book_writer.py` — `write_one_chapter` uses the template
- New: `backend/tests/test_book_writer.py` — `TestMultiTurnRevision`

### Test plan
- Multi-turn template has 3 user/assistant pairs
- Last assistant turn is the "final" slot
- Mock Ollama: assert the messages list has 6 messages (3 user, 3 assistant)
- Real regen: revised chapter is measurably better than v1

### Success criteria
- Quality lift similar to or better than Self-Refine paper's ~20%
- Latency ≤ 2x single-call (target: 1.5x)
- Stop condition works: model emits "LGTM" or "<final>" tag to skip revise

### Risk mitigation
- `--no-multiturn` flag to disable
- Token budget check: 3 turns × 1500 words = 4500 words, well within 8K ctx

---

## #13 — Persona persistence

### Research
- **Role prompting** — "Put critical rules in the 'system' message
  (or equivalent highest-priority channel). If your platform allows,
  use a system message to establish the role and guardrails."
- **Personas in System Prompts Do Not Improve Performance** (Zheng
  et al. 2023, arXiv:2311.10054) — **caveat**: on *factual questions*,
  personas don't help (and can hurt). But for *creative writing*, the
  literature consistently shows persona helps with style consistency.
- **Best practices** — gender-neutral, non-intimate, occupational.
  Avoid "imagine you are X" — just declare the role.

### Design decision
**Build a `QUILL_PERSONA` constant** and prepend to every system
prompt. This is *not* the same as #1 (which is what Quill is NOT); this
is what Quill IS as a character.

```python
QUILL_PERSONA = """\
You are Quill, a former literary magazine editor who now writes novels
full-time. You have a weakness for well-placed semicolons, despise
adverbs, and believe most fiction is over-written.

Working style:
- You always outline before drafting (beats, scenes, emotional arc)
- You read your draft aloud (mentally) before submitting
- You cut every adverb that ends in -ly from dialogue tags
- You replace "show, don't tell" violations by default
- You trust the reader to understand subtext

You never:
- Use rhetorical "It wasn't X, it was Y" patterns
- Pad prose with qualifiers ("very", "really", "quite")
- Begin a chapter with weather or waking up
- End a chapter with a summary of what just happened
"""
```

Note: #1 and #13 together compose. The combined system prompt becomes:
```
QUILL_PERSONA + "\n\n" + CHAPTER_SYSTEM + "\n\n" + NEGATIVE_PATTERNS
```

Order matters: persona first (who), then current role (what), then
anti-patterns (what not to do).

### Code location
- `backend/book_writer.py` — new `QUILL_PERSONA` constant
- `backend/book_writer.py` — `compose_system_prompt(phase)` helper
- `backend/tests/test_book_writer.py` — `TestQuillPersona`

### Test plan
- `QUILL_PERSONA` is non-empty, has working-style bullet list
- `compose_system_prompt("prose")` returns persona + system + negatives
- Persona appears in mocked Ollama call's `system` arg

### Success criteria
- No regressions
- Output voice is more consistent across multiple chapter calls
- Output includes fewer "show don't tell" violations

---

## #15 — Adaptive prompt evolution

### Research
- **Online vs Offline RLHF** — "online algorithms tend to obtain
  generally better results than offline algorithms" (Tang 2024, Wang
  2024). Same KL budget → better performance. The lesson: prefer
  *online* learning from preference signals.
- **DPO** (Rafailov 2023) — offline preference learning. We don't
  have weight access, so we can't DPO. But we can do the *prompt*
  equivalent: a learned prompt that biases future generations.
- **Constitutional AI feedback** — AI evaluates which of two
  generations is better, then we update. The prompt-version of this
  is: track signals, derive a delta, inject into future system prompts.
- **Constitutional AI RL phase** — uses AI-labeled preferences to
  train a reward model. Prompt-version: use a critic call to evaluate
  the user's accept/edit/reject and learn from it.

### Design decision
**Don't try to do online RL in the prompt layer.** That's intractable.
Instead, build a **simple signal tracker** that:
1. Records user actions: `accept` (no edit), `edit` (with diff size),
   `reject` (delete + rewrite)
2. Aggregates signals per project: edit distance, common edits
3. Adjusts the next chapter's system prompt with a small "drift
   delta" — 1-3 lines of plain English the model can act on

```python
# backend/feedback.py
def compute_drift_delta(project_id: str) -> str:
    """Look at recent chapter feedback and return a prompt delta."""
    log = load_feedback_log(project_id)
    recent = log[-10:]  # last 10 chapters
    avg_edit = mean(c.get("edit_distance", 0) for c in recent)
    if avg_edit > 200:
        # User is editing a lot — they want changes
        return "\n\nNote: recent chapters were heavily edited. "\
               "Lean further toward vivid sensory detail and "\
               "denser dialogue. Trust the user wants polish, "\
               "not safe defaults."
    elif avg_edit < 50:
        # User is accepting — current style is working
        return "\n\nNote: recent chapters were well-received. "\
               "Maintain this exact register and pacing."
    # Mid range — neutral
    return ""
```

Then prepend `compute_drift_delta(project_id)` to the system prompt
for chapter N+1.

**What's the signal source?** The Mac app sends a `chapter_feedback`
event to the backend whenever the user accepts/edits/rejects. This
event has:
- chapter_id
- action: "accept" | "edit" | "reject"
- edit_distance: int (chars different)
- timestamp

For the book_writer CLI, we don't have user feedback — every chapter
is "accepted" by default. So in CLI mode, the drift is conservative
(just tracks "user wrote X chapters without feedback" → "user trusts
default style").

### Code location
- New: `backend/feedback.py` — `record_feedback`, `load_feedback_log`,
  `compute_drift_delta`
- `backend/server.py` — new `/api/projects/<id>/feedback` endpoint
- `backend/book_writer.py` — call `compute_drift_delta` per chapter

### Test plan
- Empty log → empty delta
- High edit log → "lean further toward polish" delta
- Low edit log → "maintain register" delta
- Delta is appended to system prompt, ≤ 100 words
- Persistence: log survives restart, loaded correctly

### Success criteria
- After 5+ chapters with feedback, drift delta is non-empty
- No regressions in 112 tests
- Manual A/B: chapters 1-3 vs 6-8 should show measurable drift

### Risk mitigation
- Drift delta is a *suggestion*, never an override — model can ignore
- Cap delta size: max 100 words, max 3 sentences
- Per-project only — never cross-project

---

## Phased implementation plan

### Phase A — Foundation (techniques 1, 13, 7, 9)
All are prompt-text-only changes. Each is independent. Can be done in
any order. Total: ~2 hours of work, ~150 lines of code, ~30 lines of
tests.

**Acceptance gate for Phase A:** all 112 existing tests pass + 4 new
test classes. Run a real chapter regen on "The Last Cartographer"
chapter 1 and eyeball the diff vs the existing chapter.

### Phase B — Style grounding (techniques 3)
Slight risk because exemplars shift the model's style. Need a good
default fallback (otherwise first-chapter generation breaks).

**Acceptance gate for Phase B:** Phase A still green. Generate chapter
1 with 3 user exemplars pulled from existing chapters 2-4 of
"The Last Cartographer." Diff vs original. Should sound more
internally consistent.

### Phase C — Structural (technique 5)
Refactor `write_one_chapter` to 2 calls. New latencies. New failure
modes (planning call can fail).

**Acceptance gate for Phase C:** all prior tests pass. Manual run of
3 chapters shows beats are 4-6, prose uses all beats.

### Phase D — Self-revision (technique 12)
Single-call multi-turn. Highest chance of breaking. Need
`--no-multiturn` escape hatch from day 1.

**Acceptance gate for Phase D:** quality lift measurable. Latency
≤ 2x baseline. No new test failures.

### Phase E — Adaptation (technique 15)
Requires UI integration (feedback event from the Mac app). Backend
can be done standalone; UI hookup is a separate task.

**Acceptance gate for Phase E:** standalone backend works with
synthetic feedback log. Mac app hookup is a follow-up task, not
gating the backend.

---

## Testing strategy

**Existing:** 112 tests in `tests/test_server.py` and
`tests/test_book_writer.py` cover the call flow. These MUST stay
green throughout.

**New test classes per technique:**
- `TestNegativePatterns` (#1)
- `TestQuillPersona` (#13)
- `TestSamplingPresets` (#7)
- `TestProseChecklist` (#9)
- `TestExemplarSelection` (#3)
- `TestCoTFlow` (#5)
- `TestMultiTurnRevision` (#12)
- `TestFeedbackDrift` (#15)

**A/B testing:** for each technique, generate the same chapter
with/without the technique enabled. Capture diffs. Keep before/after
samples in `tests/fixtures/ab_*.md` for visual review.

**Real-book validation:** after all 8 techniques land, regenerate
"The Last Cartographer" from scratch and diff against the existing
19,788-word version. Expected: same length, but banned-phrase count
drops 50%+, sensory beat count up 30%+, dialogue count up 20%+.

---

## Order of operations for this implementation pass

Per the user's "do one at a time" instruction, we ship in this order,
verifying after each:

1. **#1 Role anchoring** ← *this turn*
2. #13 Persona persistence
3. #7 Phase-tuned sampling
4. #9 Pre-submit self-checklist
5. #3 Few-shot exemplars
6. #5 Chain-of-thought planning
7. #12 Multi-turn self-revision
8. #15 Adaptive prompt evolution

We pause after each technique and confirm with the user before moving
on. This lets us catch regressions early and adjust the plan.
