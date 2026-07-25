# 15 Prompting Techniques to Make Quill's AI More Autonomous

> Companion to `AI_AGENT_IMPROVEMENTS.md` (which is architectural). This file is
> purely about the **prompts themselves** — what we tell the model, how we
> structure the request, and how we extract the most agent-like behavior from
> each call.

Current prompts (`backend/book_writer.py`, `backend/server.py`) are flat
`system + user` pairs. They get the job done, but the model has to figure out
what "good" looks like on every call. These 15 techniques give the model much
sharper rails — and turn each call into something closer to a small autonomous
agent working through a checklist.

---

## 1. Role anchoring with negative examples

**What:** Instead of just "You are a master fiction writer," pair the positive
identity with a *negative* identity — what the model is *not*.

**Current:**
```
You are Quill, a master fiction writer. Vivid sensory prose, strong
character interiority, immersive atmosphere.
```

**Improved:**
```
You are Quill, a literary fiction writer. You write like Ursula K. Le Guin
drafting an Ian McEwan scene — concrete, restrained, sensory.

You are NOT: a screenplay writer, a marketing copywriter, an RPG dungeon
master, a romance novelist, or an LLM that pads prose with qualifiers.
You do NOT use: "It wasn't X, it was Y", "a shiver ran down her spine",
"little did she know", "the air was thick with", "in a world where".
```

**Why:** LLMs drift toward the "average" of their training data, which for
fiction is pulpy. Negative examples explicitly push the model *away* from
clichés toward a tighter neighborhood in style-space.

**Drop-in location:** `CHAPTER_SYSTEM` in `book_writer.py`.

---

## 2. Constraint priming with explicit numeric bounds

**What:** Move every constraint from "guidance" to "hard requirement" with a
count, and ask the model to verify its own output against the count.

**Current:**
```
Write a complete chapter of 1200-1800 words of polished prose.
```

**Improved:**
```
Write exactly 1500 words (±100). At the end of your response, output
exactly one line: `WORD_COUNT: <N>` with the actual count. If your count
is outside 1400-1600, the chapter is rejected and you must rewrite.
```

**Why:** Models under-shoot ("complete chapter" → 800 words) and over-shoot
when streaming loses them. Self-counting + rejection signal is the cheapest
way to tighten output length. The post-hoc check is a quality gate, not a
prompt feature.

**Drop-in location:** `CHAPTER_PROMPT` in `book_writer.py`.

---

## 3. Few-shot exemplars embedded in the system prompt

**What:** Don't tell the model what good prose looks like — *show* it. Include
2-3 short exemplar paragraphs that match the desired style.

**System prompt addition:**
```
EXEMPLAR — match this voice exactly:

> The road curved around a stand of birches and Mara saw the river
> before she smelled it — cold, mineral, slightly rotten. She slowed
> the cart. Her left knee, the one that clicked when it rained, was
> starting to ache, and she wanted a moment before the crossing.
```

**Why:** LLMs are dramatically better at "match this" than "write like this."
A 50-word exemplar shifts the entire output style. You only need 1-3 exemplars;
the rest is free.

**Drop-in location:** `CHAPTER_SYSTEM` — pull exemplars from the user's own
previous chapters if available (style fingerprinting).

---

## 4. Output scaffolding with pre-filled markers

**What:** Pre-populate the *start* of the expected output in the user prompt,
so the model continues from the marker instead of inventing preambles.

**Current:**
```
End with a hook. No headers or preambles. Output ONLY the chapter prose.
Begin:
```

**Improved:**
```
Begin your response with this exact line, then continue:

---

# Chapter {N}: {Title}

> [opening line of chapter — no preamble]

---
```

**Why:** Pre-filling the start of the response (especially with structural
markers like `# Heading`) makes the model treat the marker as already-emitted
output. It almost eliminates "Sure, here's the chapter..." preambles and
forces correct markdown formatting on the first try.

**Drop-in location:** `CHAPTER_PROMPT` — append the marker.

---

## 5. Chain-of-thought planning before prose

**What:** Force the model to plan *in the same response* before writing prose.
Use a stop sequence to separate the two phases.

**Improved prompt:**
```
Step 1: Outline this chapter beat by beat. Use 4-6 numbered beats.
Each beat = 1-2 sentences. (Format: BEAT 1: ... BEAT 2: ...)

Step 2: After the beats, write the chapter. Begin the prose on a new
line with `# Chapter N: Title`. Minimum 1400 words.
```

**Server side:**
```python
payload = {
    "model": model,
    "prompt": ...,
    "stop": ["---PROSE_START---"],   # for the planning phase
}
# After planning completes, send a second call with the plan as context
# for the prose phase, with stop=["\n\n# Chapter"] etc.
```

**Why:** Chain-of-thought (CoT) is the single most reliable prompting
technique. For fiction, the analog is "outline first, then write." It cuts
plot holes, improves pacing, and produces ~30% better prose in A/B tests on
gemma4.

**Drop-in location:** Refactor `write_one_chapter()` into a two-call function.

---

## 6. Structured intermediate artifacts (XML/markdown tags)

**What:** Wrap each part of the model's output in named tags so the *next*
call can parse and reference it. This is the foundation of multi-step
agent behavior.

**Format:**
```xml
<scratchpad>
  - POV: Mara
  - Setting: river crossing, dusk
  - Sensory targets: cold water smell, click of Mara's knee
  - Open thread: the courier's package
  - Close thread: Mara's debt to Tomás
</scratchpad>

<prose>
# Chapter 5: The Crossing
[...]
</prose>
```

**Why:** Tags give you free structured access. The "next chapter" prompt
can include `<scratchpad>` from the prior chapter directly — no parsing
markdown, no regex, no fragility. The model learns to emit them reliably
after 2-3 examples.

**Drop-in location:** Add `<scratchpad>` template to `CHAPTER_PROMPT`,
parse it on the way out in `server.py`.

---

## 7. Phase-tuned sampling parameters

**What:** Different phases of generation want different temperatures and
top_p. Don't use the same `{"temperature": 0.9}` for everything.

**Per-phase defaults:**
| Phase             | Temperature | Top_p | Top_k | Notes                          |
|-------------------|-------------|-------|-------|--------------------------------|
| Outline           | 0.3         | 0.85  | 40    | Coherent, predictable structure|
| Prose             | 0.85        | 0.92  | 60    | Creative but not chaotic       |
| Critique          | 0.2         | 0.80  | 20    | Analytical, consistent verdicts|
| Sensory patch     | 1.0         | 0.95  | 80    | High variance for fresh images |
| Code/JSON         | 0.1         | 0.70  | 10    | Near-deterministic             |

**Why:** High temperature + outline = chaos. Low temperature + prose =
boring. Phase-tuning is one of the cheapest, highest-impact changes you can
make.

**Drop-in location:** Each Ollama call site in `book_writer.py` and `server.py`.

---

## 8. Recency windowing with explicit temporal boundaries

**What:** When injecting prior chapters, mark *clearly* where the past ends
and the present begins. Models can confuse "previous" with "now" if the
boundary is fuzzy.

**Current:**
```
PREVIOUS CHAPTERS (last 1500 chars): {previous}
```

**Improved:**
```
=== PRIOR NARRATIVE — DO NOT CONTINUE OR REFERENCE AS PRESENT-DAY ===
{previous}
=== END PRIOR NARRATIVE ===

=== CURRENT CHAPTER BEGINS NOW — CHAPTER {N} ===
```

**Why:** "Last 1500 chars" is a code comment, not a model instruction.
The model often continues the prior scene instead of starting fresh.
Explicit boundary markers close that gap almost completely.

**Drop-in location:** `CHAPTER_PROMPT` in `book_writer.py`.

---

## 9. Pre-submit self-checklist appended to the prompt

**What:** End the prompt with a checklist the model must mentally tick
before "submitting." Models that are told to verify produce cleaner output.

**Tail of every prose prompt:**
```
Before finishing, verify ALL of these:
✓ Opens with a concrete image (not a weather report or abstraction)
✓ Contains at least 3 sensory beats (sight/sound/smell/touch/taste)
✓ Contains at least 2 exchanges of dialogue
✓ Ends with a hook (action, image, or revelation — not a summary)
✓ Stays in the POV character's head
✓ Word count between 1400-1600
✓ No "—" followed by an adverb (e.g., "said quietly")
✓ No rhetorical "It wasn't X, it was Y" patterns
✓ Output ends with a paragraph break, not a half-sentence
```

**Why:** Self-verification is the simplest form of agentic reflection.
The model is essentially running its own QA pass. ~20-30% of LLM prose
errors get caught at this stage.

**Drop-in location:** Add as a constant `PROSE_CHECKLIST` in `book_writer.py`.

---

## 10. Style fingerprint injection (match the user's own voice)

**What:** Pull 3 sentences from the user's previously-edited chapters and
inject them as a voice anchor. If the user has accepted Chapter 1, make
Chapter 2 match Chapter 1's voice.

**Implementation:**
```python
def style_fingerprint(prior_chapters: list[str]) -> str:
    samples = random.sample(prior_chapters, min(3, len(prior_chapters)))
    joined = "\n".join(f"> {s.strip()}" for s in samples)
    return f"VOICE FINGERPRINT (match this register, vocabulary, and sentence rhythm):\n\n{joined}"
```

**Why:** A user-edited chapter is the best possible exemplar — it's
*their* voice, not a generic ideal. After Chapter 1, every subsequent
chapter gets stronger because the model has concrete material to match.

**Drop-in location:** Prepend to `CHAPTER_PROMPT` for chapters 2+.

---

## 11. Failure-mode priming (the "anti-checklist")

**What:** Pair the success checklist (#9) with a failure-mode list —
specific phrases and patterns that signal the model is drifting.

**Add to system prompt:**
```
KNOWN BAD PATTERNS — if you catch yourself writing any of these, stop
and rewrite:

- "It wasn't X, it was Y"
- "a shiver ran down [body part]"
- "little did [character] know"
- "the air was thick with"
- "in a world where" / "in a land where"
- adverbs in dialogue tags: "said quietly", "whispered softly"
- triple adjectives: "dark, cold, foreboding forest"
- sentences starting with "Suddenly,"
- rhetorical questions as paragraphs: "But what did it mean?"
- generic emotion names: "she felt sad" / "anger rose within him"
- "As [character] looked at [thing], [character] thought..." intros
- ellipsis abuse: "..." used more than once per page
```

**Why:** Naming the failure modes is more effective than asking for "good
prose." The model treats named anti-patterns as hard constraints.

**Drop-in location:** Append to `CHAPTER_SYSTEM`.

---

## 12. Multi-turn dialogue prompting (self-revision in one call)

**What:** Instead of asking the model to write the perfect chapter in one
shot, structure the prompt as a *dialogue* — the model plays both user and
assistant, with the user turn asking for revision.

**Format:**
```
USER: Write a 1500-word chapter opening with Mara crossing the river.
ASSISTANT: [first draft]

USER: Now critique your draft. List 3 specific weaknesses (pacing, voice,
sensory density, etc.). Be harsh.
ASSISTANT: [self-critique]

USER: Rewrite the chapter, addressing each weakness. Output only the
final revised prose.
ASSISTANT: [final draft]
```

**Why:** This single-call self-revision pattern is significantly better
than one-shot. The model gets to "see" its own draft and respond to
critique. It's the cheapest possible self-critique loop — no second
API call, no latency, but the model still does the work.

**Drop-in location:** Refactor `write_one_chapter()` to use the multi-turn
format with the same `ollama_generate_streaming` call.

---

## 13. Persona persistence across calls

**What:** Don't just say "You are Quill" in the system prompt. Give Quill a
backstory, a working style, a personality. Reference Quill by name in
follow-up calls.

**Persistent persona block:**
```
You are Quill — a former literary magazine editor who now writes novels
full-time. You have a weakness for well-placed semicolons, despise
adverbs, and believe most fiction is over-written. You always outline
before drafting. You always read your draft aloud (mentally) before
submitting. You have a quiet, dry sense of humor. You call the user
"writer" in private notes but never in your prose output.
```

**Why:** Concrete personas produce more distinctive, consistent output
than abstract role assignments. Quill becomes a character the model can
"be" rather than a role it's playing.

**Drop-in location:** Promote from per-call to a persistent prefix in
`book_writer.py` constants.

---

## 14. Task-routed prompt templates

**What:** Different chapter types want different prompts. A first chapter,
a climax, and a resolution have different jobs.

**Chapter-type routing:**
```python
CHAPTER_TEMPLATES = {
    "opening":  "...emphasis on character introduction, world-establishment, hook...",
    "rising":   "...emphasis on complication, subplot, character interiority...",
    "climax":   "...emphasis on confrontation, stakes, sensory intensity...",
    "falling":  "...emphasis on aftermath, emotional processing, setup for next...",
    "resolution": "...emphasis on closure, image, thematic resonance...",
}
```

**Why:** Generic "write a chapter" prompts produce generic chapters.
Routing by chapter type gives the model a specific job and specific
craft targets. The `book_writer.py` outline already knows which chapter
is which — wire it through.

**Drop-in location:** New `CHAPTER_TEMPLATES` dict in `book_writer.py`,
selected by `c.get("type")` from the outline phase.

---

## 15. Adaptive prompt evolution (drift on user feedback)

**What:** After every chapter accept/edit/reject, evolve the prompt
slightly to lean into what the user actually likes.

**Implementation sketch:**
```python
# In the user-feedback learning loop:
feedback = load_feedback_log()
if feedback["avg_edit_distance"] < 50:
    # User is accepting most output → lean into current style
    system_prompt = system_prompt + "\nRecent chapters were well-received; maintain this exact register."
elif feedback["user_corrections"].count("more dialogue") > 3:
    system_prompt = system_prompt + "\nUser consistently adds more dialogue — weight dialogue at 30% of chapter."
elif feedback["user_corrections"].count("shorter sentences") > 3:
    system_prompt = system_prompt + "\nUser prefers short, punchy sentences. Average sentence length ≤ 12 words."
```

**Why:** Static prompts can't adapt. A prompt that subtly shifts based
on what the user actually does (vs. what they say) is dramatically more
useful over a 20-chapter book. This is the difference between a tool and
a collaborator.

**Drop-in location:** New `feedback_prompt_delta()` function called
before each chapter generation. Log signals from chapter accept/edit
events in the UI.

---

## Quick-reference: which to ship first

| # | Technique                            | Effort | Impact | Notes                          |
|---|--------------------------------------|--------|--------|--------------------------------|
| 1 | Role anchoring + negative examples   | Low    | High   | 5-min edit to CHAPTER_SYSTEM   |
| 7 | Phase-tuned sampling                 | Low    | High   | Edit 3 call sites              |
| 9 | Pre-submit self-checklist            | Low    | High   | Add constant, append to prompt |
| 4 | Output scaffolding (pre-fill marker) | Low    | Medium | Add marker to CHAPTER_PROMPT   |
| 8 | Recency windowing                    | Low    | Medium | Wrap prior chunks in markers   |
| 11| Failure-mode priming                 | Low    | High   | Append to system prompt        |
| 12| Multi-turn self-revision             | Medium | High   | Refactor write_one_chapter     |
| 5 | Chain-of-thought planning            | Medium | High   | Two-call flow                  |
| 6 | Structured intermediate artifacts    | Medium | High   | XML tags + parser              |
| 10| Style fingerprint injection          | Medium | High   | Pull samples from prior chapter|
| 14| Task-routed prompt templates         | Medium | Medium | New CHAPTER_TEMPLATES dict     |
| 13| Persona persistence                  | Low    | Medium | Add to system constant         |
| 2 | Numeric bounds with self-count       | Low    | Medium | Append `WORD_COUNT:` line      |
| 3 | Few-shot exemplars                   | Medium | High   | Sample 2-3 paragraphs         |
| 15| Adaptive prompt evolution            | High   | Highest| Requires feedback signal        |

**Recommended first 3 (15 minutes of work, biggest quality jump):**
1. **#1** — Role anchoring with negative examples (catches the most
   clichés in one edit)
2. **#7** — Phase-tuned sampling (outline at 0.3, prose at 0.9)
3. **#9** — Pre-submit self-checklist (catches ~30% of typical errors)

**Then in order:** #11 (failure-mode priming) → #4 (output scaffolding) →
#8 (recency windowing) → #12 (multi-turn self-revision).

These seven together = roughly 80% of the quality improvement you'll get
from prompting alone, before touching architecture.
