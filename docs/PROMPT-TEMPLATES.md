# Prompt Template Design Guide

How Seminarly's prompt templates work, why they're designed this way, and how to modify them.

## Architecture

```
NoteTemplate.swift          → Section definitions (keys, titles, icons, hints)
PromptTemplates.swift       → System prompts + user prompts + rules
ClaudeAPIClient.swift       → Sends system prompt + user prompt to Claude Sonnet
NoteStructuringService.swift → Orchestrates the call, decodes JSON response
```

**Flow**: Template enum defines sections → `PromptTemplates` builds the JSON schema dynamically from those sections → Claude returns JSON matching the schema → `TemplatedNoteResponse` decodes it flexibly (dynamic keys) → only sections matching the template definition are materialized.

## Templates

| Template | Sections | Use Case |
|----------|----------|----------|
| **Lecture** | Key Concepts, Definitions, Examples, Connections & Applications, Key Takeaways, Review Questions | Academic lectures, educational content |
| **Study Guide** | Topics Covered, Key Points, Q&A Review, Practice Problems, Memory Aids, Further Study | Exam prep, revision material |
| **Meeting** | Discussion Points, Decisions, Action Items, Open Questions | Business meetings, standups, 1:1s |
| **Podcast** | Speaker Background, Themes, Key Insights, Notable Quotes, References, Takeaways | Podcasts, interviews, panels |
| **Custom** | User-defined | Anything else, with custom instructions |

## Design Principles

These principles are based on research into learning science, prompt engineering best practices, and analysis of commercial note-taking tools (Granola, Fireflies, Otter, Notion AI).

### 1. Rich Expert Personas (not generic roles)

**Before**: "You are a study assistant."
**After**: "You are an experienced teaching assistant who has helped hundreds of students ace their exams..."

**Why**: Research shows specific expert personas produce 15-20% better output quality. The persona gives Claude a frame of reference for what "good" looks like in context. A "senior executive assistant who has distilled thousands of meetings" writes differently than a generic "meeting notes assistant."

### 2. Positive Directives Over Negative Constraints

**Before**: "Don't use vague phrases"
**After**: "Every bullet point must contain at least one specific fact, name, or concrete detail"

**Why**: The "pink elephant paradox" — telling LLMs what NOT to do actually increases the probability of that behavior. Positive directives are more effective because they give the model a clear target to aim for.

### 3. Speaker Attribution from Diarization

The system prompt includes:
> When speakers are identified, attribute key statements, decisions, and commitments to specific speakers.

**Why**: Seminarly produces diarized transcripts with speaker labels. Without explicit instructions to use them, Claude often ignores speaker labels and writes generic summaries. With attribution, notes become immediately actionable ("Sarah owns the migration" vs "the team discussed migration").

### 4. Anti-AI-ism Directives

The system prompt includes tone rules:
- Use contractions (it's, they'll, we're)
- Vary sentence length
- Avoid filler phrases ("it's worth noting", "importantly", "in conclusion")

**Why**: Without these, AI-generated notes read robotically — medium-length monotonous sentences, overly formal, repetitive phrasing. These positive directives produce natural-sounding output without needing negative instructions.

### 5. Chain-of-Thought Before Structuring

The user prompt includes:
> First, mentally identify the major themes and topics in the transcript. Then, for each section below, extract the most relevant information.

**Why**: Single-shot generation on long transcripts loses nuance. Asking the model to analyze first (even silently) produces better section content because it identifies signal vs. noise before summarizing.

### 6. Substance Over Coverage

> Prioritize substance over coverage — fewer high-quality items beat many shallow ones.

**Why**: Without this, Claude tends to fill every section with as many items as possible, diluting quality. Explicit instruction to prefer fewer, richer items produces more useful notes.

### 7. Self-Contained Items

Each section's items should be understandable without the full transcript context:
> Each self-contained enough to understand without context

**Why**: Notes are a reference tool. When reviewing weeks later, items like "this was discussed" are useless. Items like "Gradient descent minimizes loss by iteratively adjusting weights in the direction of steepest descent" stand alone.

## Section Design Rationale

### Lecture Template

Based on the **Cornell Note-Taking Method** (proven ~17% score improvement) combined with modern learning science:

- **Key Concepts**: The "notes column" — core ideas as self-contained statements
- **Definitions**: Term-definition pairs for vocabulary building
- **Examples**: Concrete illustrations linked to concepts (dual coding theory)
- **Connections & Applications**: Links to related ideas and real-world use (elaborative interrogation)
- **Key Takeaways**: The "summary section" — most exam-worthy points
- **Review Questions**: The "cue column" — drives active recall during review

### Study Guide Template

Grounded in **active recall** (80% retention after 1 week vs 34% for re-reading) and **spaced repetition**:

- **Topics Covered**: Hierarchical overview for navigation (→ nesting syntax)
- **Key Points**: Concrete factual statements (specificity requirement)
- **Q&A Review**: Exam-style questions at varying difficulty (active recall)
- **Practice Problems**: Application-level exercises connecting multiple concepts
- **Memory Aids**: Mnemonics, acronyms, analogies (encoding strategies)
- **Further Study**: Gap identification with specific lookup suggestions

### Meeting Template

Modeled on **Granola/Fireflies** patterns and executive assistant best practices:

- **Discussion Points**: Attributed to speakers, captures debates and resolutions
- **Decisions**: Only explicitly agreed-upon decisions, with rationale
- **Action Items**: "Task — Owner (deadline)" format for immediate actionability
- **Open Questions**: Parking lot items and deferred topics

### Podcast Template

Based on **Snipd/Castmagic** show notes patterns and journalist summarization:

- **Speaker Background**: Context on who's talking (credibility/relevance)
- **Themes**: Topic sentences capturing arguments, not just labels
- **Key Insights**: Novel or counterintuitive points worth sharing
- **Notable Quotes**: Attributed close paraphrases
- **References**: Findable resources (full titles, authors)
- **Takeaways**: Actionable conclusions, not just descriptive summaries

## Enhancement Path (User Notes + Transcript)

Seminarly supports two distinct note generation paths:

### Path 1: Pure Structuring (no user notes)
`PromptTemplates.structureNotes()` → `ClaudeAPIClient.sendMessage()` → `NoteStructuringService.structureTranscript()`

The original path. Transcript goes in, structured notes come out. Items are plain strings.

### Path 2: Enhancement (user notes present)
`PromptTemplates.enhanceWithUserNotes()` → `ClaudeAPIClient.sendEnhancementMessage()` → `NoteStructuringService.enhanceNotes()`

When the user typed notes in the notepad during recording, this path is used instead. Key differences:

- **System prompt** (`enhanceSystemPrompt(for:)`) extends the base persona with user-note priority rules:
  - Every user note must appear in output, expanded with transcript context
  - User-highlighted topics get the most detailed treatment
  - Headings in user notes (`# ...`) become section signals
  - Typos/abbreviations fixed while preserving meaning
- **User prompt** includes both user notes and transcript as separate sections
- **Source attribution**: Each item in the JSON response is an object with `{text, source, transcriptRef}` instead of a plain string:
  - `source: "user"` — derived from or expanding on the user's notes
  - `source: "transcript"` — added purely from transcript analysis
  - `transcriptRef: "03:45-04:12"` — approximate transcript timestamp range (optional)
- **Backward compatibility**: `NoteItem` decodes both plain strings (legacy) and rich objects (new)

### Decision Logic (in RecordingView)
```swift
if !userNotesText.isEmpty {
    result = await noteService.enhanceNotes(userNotes:transcript:template:)
} else {
    result = await noteService.structureTranscript(transcript:template:)
}
```

## Modifying Templates

### Adding a New Section

1. Add a `SectionDefinition` to the template's `sectionDefinitions` array in `NoteTemplate.swift`
2. Add corresponding rules in `templateSpecificRules()` in `PromptTemplates.swift`
3. Update test expectations in `Tests/NoteTemplateTests.swift` and `Tests/PromptTemplatesTests.swift`
4. No model/storage changes needed — `TemplatedNoteResponse` handles dynamic keys

### Adding a New Template

1. Add a case to `NoteTemplate` enum
2. Implement all computed properties: `displayName`, `icon`, `description`, `sectionDefinitions`
3. Add persona in `templatePersona()`, rules in `templateSpecificRules()`
4. Add system prompt case in `systemPrompt()`
5. Add tests for section count and expected field keys

### Prompt Tuning Tips

- **Test with real transcripts** — synthetic test data won't reveal edge cases
- **Keep system prompts under ~500 tokens** — they're sent on every request
- **Rules in the user prompt > system prompt** — Claude prioritizes user-message instructions
- **Specific examples in rules beat abstract instructions** — "format as 'Task — Owner (deadline)'" beats "make action items specific"
- **Measure quality, not length** — good notes are scannable in 30 seconds

## Token Budget

The prompts are designed to stay within a reasonable token budget:

| Component | Approx. Tokens |
|-----------|---------------|
| System prompt (persona + tone + speaker rules) | ~200-250 |
| User prompt (instructions + JSON schema) | ~150-200 |
| Template-specific rules | ~150-200 |
| **Total prompt overhead** | **~500-650** |
| Transcript (30-min meeting) | ~3,000-5,000 |
| Response (structured JSON) | ~500-1,500 |
| **Total per request** | **~4,000-7,000** |

At Claude Sonnet pricing (~$3/MTok input, $15/MTok output), a typical meeting costs $0.02-0.04.
