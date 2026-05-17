# Notepad Feature — Design & Implementation Plan

> **Status: Fully Implemented** (2026-03). All steps below are complete. This document is preserved as a design reference. For current architecture details see `docs/ARCHITECTURE.md`. For the next evolution of the notepad (unifying it into one continuous surface across the full lifecycle), see `docs/NOTEPAD-LIFECYCLE-PLAN.md` and the accompanying research in `docs/notepad-granola-research-2026.md`.

A Granola-style "jot and enhance" notepad that becomes Seminarly's primary recording interface.

## Problem

Seminarly currently has no text input during recording. Users can't signal what matters to them in a specific meeting. The AI processes the full transcript blindly, treating everything as equally important. This is the biggest UX gap between Seminarly and Granola ($18/month).

## How Granola's Notepad Works

Research across Granola docs, TechCrunch, Zapier, tl;dv, BlueDot reviews, and the reverse-engineered API (getprobo/reverse-engineering-granola-api on GitHub).

### Core UX Flow
1. Meeting starts (detected via calendar integration)
2. App transforms into a **blank notepad** — looks like Apple Notes, zero chrome
3. Audio transcription runs silently in the background (Deepgram, no bot joins)
4. User types freely: shorthand, abbreviations, typos, markdown headings, or nothing at all
5. Meeting ends → user clicks **"Enhance notes"**
6. AI merges user notes with transcript: expands shorthand, adds context, fills gaps
7. Enhanced output shows **black text** (user's original) and **gray text** (AI additions)
8. Gray text carries **clickable hyperlinks** to transcript timestamps for fact-checking

### Key Design Decisions
- **Notepad is the primary surface** — not a sidebar, not a panel, THE view
- **Transcript is secondary** — toggleable side panel, hidden by default
- **User notes = priority signals** — they tell the AI what matters most
- **Headings as structural directives** — typing `# Action Items` tells the AI to create that section
- **In-place augmentation** — not side-by-side. AI fills around user notes in a single document
- **No bot visibility** — other participants never know you're using it

### What Users Love
- The "jot and enhance" workflow (type 10 words, get 200 words back)
- No bot joining the call
- Black/gray visual distinction with transcript citation links
- Speed and clean UI
- Back-to-back meeting support

### What Users Complain About
- No speaker memory across meetings
- Transcript is read-only (can't fix errors)
- Was Mac-only for a long time
- Limited integrations initially
- Weaker non-English support

### Competitor Comparison
No competitor (Otter, Fireflies, Fellow, tl;dv) offers a notepad where users type during the meeting and AI expands those notes. They either auto-summarize everything (passive) or require full manual note-taking. Granola uniquely occupies the middle ground.

---

## Seminarly's Current State

### Recording Flow
```
RecordingView (sheet modal)
├── Model loading (WhisperKit + FluidAudio)
├── Audio source selection (app picker + mic toggle)
├── Template selection (5 templates + custom instructions)
├── Recording controls (start/pause/stop)
├── Live transcript (real-time WhisperKit output)
└── Processing status (finalize → diarize → structure)
```

No text input exists during recording. The only user input is `customInstructions` (global, Custom template only, stored in UserDefaults).

### Note Generation Pipeline
```
Transcript.diarizedText → PromptTemplates.structureNotes() → ClaudeAPIClient → JSON → StructuredNote
```

Single injection point for user content: `customInstructions` appended as `"- Additional instructions: {custom}"` in the rules section.

### Key Constraint
RecordingView is a **sheet modal** (550-650px). We work within this constraint rather than fighting it.

---

## Design: Two-Phase RecordingView

The fundamental UX shift: RecordingView has two distinct modes.

### Phase 1 — Setup (before recording)
The current UI, unchanged:
```
+-----------------------------------------------+
| Recording                          05:32   ✕  |
+-----------------------------------------------+
| Models                                         |
|   ⟳ Loading transcription model...            |
|   ⟳ Loading speaker models...                 |
+-----------------------------------------------+
| Audio Source                                   |
|   App to capture: [Zoom ▾]  🔄               |
|   ☑ Also capture microphone                   |
+-----------------------------------------------+
| Note Template                                  |
|   Template: [Meeting Notes ▾]                  |
|   Capture decisions, action items, and...      |
+-----------------------------------------------+
|          [ ● Start Recording ]                 |
+-----------------------------------------------+
| Live Transcript                                |
|   Waiting for audio...                         |
+-----------------------------------------------+
```

### Phase 2 — Notepad (during recording)
When "Start Recording" is tapped, the entire view transforms:
```
+------------------------------------------------------+
| ● 05:32                          ⏸ Pause  ⏹ Stop    |
+------------------------------------------------------+
|                                                        |
|                                                        |
|   Type your notes here...                              |
|   Use # headings to define sections                    |
|                                                        |
|                                                        |
|                                                        |
|                                                        |
|                                                        |
|                                                        |
|                                                        |
|                                                        |
|                                                        |
|                                                        |
+------------------------------------------------------+
| ▸ Live Transcript                              Hide ▾ |
| [00:32] Speaker 1: We should discuss the Q2 budget... |
| [01:15] Speaker 2: I think we can allocate...         |
+------------------------------------------------------+
```

### Design Principles
- **Notepad fills ~70-80% of the window** — it IS the recording experience
- **Recording controls compressed into a thin top bar** — red dot + timer + pause/stop, no cards
- **Live transcript is a collapsible footer** — toggleable, defaults to ~100px, can be hidden
- **No source/template/model sections visible** — already locked in, no reason to show them
- **Clean, minimal aesthetic** — like Apple Notes. Background color, font, and spacing feel like writing, not configuring
- **Placeholder text fades** on first keystroke

### Phase 3 — Processing (after stop)
Same as current — processing status while transcription finalizes, diarization runs, and notes enhance.

---

## Implementation Steps

### Step 1: Data Model

**File:** `Sources/Storage/MeetingModel.swift`

Add one optional property to the `Meeting` model:
```swift
var userNotesText: String?    // Raw text user typed during recording
```

SwiftData handles this as an automatic lightweight migration — no schema version change, no migration plan update. Existing meetings get `nil` (the "no notepad" state).

### Step 2: RecordingView — Two-Phase Layout

**File:** `Sources/Views/RecordingView.swift`

New state variables:
```swift
@State private var userNotesText = ""
@State private var showTranscript = true
```

The `body` switches between phases:
```swift
var body: some View {
    VStack(spacing: 0) {
        if isRecording || isPaused || isProcessingNotes {
            activeRecordingView    // Phase 2: notepad-dominant
        } else {
            setupView              // Phase 1: current UI
        }
    }
}
```

New computed views:
- **`activeRecordingView`** — VStack of `recordingToolbar` + `notepadEditor` + optional `liveTranscriptFooter` + optional `processingSection`
- **`recordingToolbar`** — Thin HStack: recording dot + timer, spacer, transcript toggle button, pause button, stop button
- **`notepadEditor`** — TextEditor with generous padding (Spacing.lg), 14pt font, `.scrollContentBackground(.hidden)`, fills all available space with `maxWidth/maxHeight: .infinity`, placeholder overlay
- **`liveTranscriptFooter`** — Collapsible VStack with caption-sized text, surfaceElevated background, max 120px height
- **`setupView`** — Extracts the existing body content (model loading, source, template, controls, live transcript)

Window frame widens slightly: `idealWidth: 700` (from 650).

### Step 3: Prompt Engineering — Enhancement Path

**File:** `Sources/NoteStructuring/PromptTemplates.swift`

New method alongside existing `structureNotes()`:
```swift
static func enhanceWithUserNotes(
    userNotes: String,
    transcript: String,
    template: NoteTemplate,
    customInstructions: String? = nil
) -> String
```

**System prompt addition** (appended when user notes present):
```
The user took handwritten notes during this session. These notes are their
personal signal of what matters most. Treat them as the backbone of your output:
- Every user note must appear in your response, expanded with transcript context
- Topics the user highlighted should receive the most detailed treatment
- Fix typos and complete abbreviations, but preserve the user's meaning
- If the user wrote headings (lines starting with #), use them as section signals
- Also include important points from the transcript that the user didn't note
```

**User prompt structure:**
```
Here are the user's notes taken during the session:
---
{userNotes}
---

Here is the full transcript:
---
{transcript}
---

Produce structured {template} that preserves and enriches the user's notes
with details from the transcript. Add important points the user didn't write about.

{JSON schema — same as existing}
{Template-specific rules — same as existing}
```

The existing `structureNotes()` stays unchanged for the no-notes path.

### Step 4: Service Layer — Enhancement Method

**File:** `Sources/NoteStructuring/NoteStructuringService.swift`

New method mirroring `structureTranscript()`:
```swift
func enhanceNotes(
    userNotes: String,
    transcript: String,
    template: NoteTemplate,
    customInstructions: String? = nil
) async -> (title: String, note: StructuredNote)?
```

Same decode flow — Claude still returns `{title, summary, sections...}` as plain JSON. Only the prompt differs.

**File:** `Sources/NoteStructuring/ClaudeAPIClient.swift`

Parameterize `sendMessage()` to accept optional `userNotes: String?`, or add `sendEnhancementMessage()`.

### Step 5: Wire Up stopRecording()

**File:** `Sources/Views/RecordingView.swift`

At the note generation step (~line 440), branch based on whether user typed notes:
```swift
if noteService.hasAPIKey && !transcript.rawText.isEmpty {
    let trimmedNotes = userNotesText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedNotes.isEmpty {
        processingStatus = "Enhancing your notes with transcript..."
        result = await noteService.enhanceNotes(
            userNotes: trimmedNotes,
            transcript: transcript.diarizedText,
            template: selectedTemplate
        )
    } else {
        processingStatus = "Generating structured notes with Claude..."
        result = await noteService.structureTranscript(...)  // existing path
    }
}
meeting.userNotesText = trimmedNotes.isEmpty ? nil : trimmedNotes
```

### Step 6: MeetingDetailView — Post-Recording Notes + Enhance

**File:** `Sources/Views/MeetingDetailView.swift`

In `structuredNotesTab`, add a user notes section above the summary:
```
+----------------------------------------------+
| Your Notes                         [Enhance ✨]|
| +------------------------------------------+ |
| | TextEditor (editable, ~100px)            | |
| +------------------------------------------+ |
|                                              |
| Summary                                      |
| ...existing sections with bullet points...   |
+----------------------------------------------+
```

- `meeting.userNotesText` non-nil → editable TextEditor + "Enhance" button (sparkles icon)
- `meeting.userNotesText` nil → subtle prompt: "Add notes and click Enhance to merge with transcript"
- "Enhance" calls `noteService.enhanceNotes()`, replaces StructuredNote
- Existing "Regenerate" menu stays for pure transcript-to-notes

### Step 7: Tests

- Test `enhanceWithUserNotes()` prompt contains both user notes and transcript
- Test `enhanceWithUserNotes()` includes priority instructions in system prompt
- Test existing `structureNotes()` unchanged (no regression)
- Test enhancement response parsing (same JSON format, same decoder)

---

## Files Modified

| File | Change |
|------|--------|
| `Sources/Storage/MeetingModel.swift` | Add `userNotesText: String?` to Meeting |
| `Sources/Views/RecordingView.swift` | Two-phase layout: setup → notepad-dominant recording |
| `Sources/Views/MeetingDetailView.swift` | User notes editor + Enhance button in notes tab |
| `Sources/NoteStructuring/PromptTemplates.swift` | Add `enhanceWithUserNotes()` method |
| `Sources/NoteStructuring/NoteStructuringService.swift` | Add `enhanceNotes()` method |
| `Sources/NoteStructuring/ClaudeAPIClient.swift` | Support user notes in API call |
| `Tests/PromptTemplatesTests.swift` | Enhancement prompt tests |
| `Tests/NoteStructuringParsingTests.swift` | Enhancement response parsing test |

---

## v2 Roadmap (Partially Shipped)

| Feature | Status | Description |
|---------|--------|-------------|
| **Source attribution data model** | ✅ Shipped | `NoteItem` with `.user / .transcript` source enum + `transcriptRef` field |
| **Markdown live styling** | ✅ Shipped | `MarkdownNoteEditor` renders `# headings`, `**bold**`, `- bullets` in real-time |
| **Timestamped note entries** | ✅ Shipped (data model) | `Meeting.timestampedNotesData` stores per-line timestamps; UI not yet wired |
| **Black/gray attribution display** | ✅ Shipped | `BulletPoint` color-codes by `NoteItem.source` — accent+primary for user, secondary+gray for transcript |
| **Transcript timestamp links** | ✅ Shipped (tab switch) | `transcriptRef` badge is clickable, switches to Transcript tab. Inline popover + scroll-to-position deferred to `NOTEPAD-LIFECYCLE-PLAN.md` (P6) |
| **Unified notepad across lifecycle** | ✅ Shipped | `NotepadSurface` component — notepad stays continuous from setup → recording → post-stop → enhancement. See `NOTEPAD-LIFECYCLE-PLAN.md` (P1) |
| **Pre-recording notepad** | ✅ Shipped | Notepad visible under compact setup toolbar; user can type agenda before hitting Record. See `NOTEPAD-LIFECYCLE-PLAN.md` (P2+P3) |
| **Compact setup toolbar** | ✅ Shipped | Audio / Template / Language chips + Record button replace the full-screen setup form. See `NOTEPAD-LIFECYCLE-PLAN.md` (P2) |
| **Phase-aware placeholder** | ✅ Shipped | Placeholder adapts per lifecycle state ("Jot down your agenda…" → "Type notes as you listen…" → "Click Enhance…"). See `NOTEPAD-LIFECYCLE-PLAN.md` (P3) |
| **Explicit Enhance action** | ✅ Shipped | Enhancement is no longer auto-triggered on Stop — user clicks "Enhance with Transcript" CTA. See `NOTEPAD-LIFECYCLE-PLAN.md` (P1) |
| **Template chip in post-recording toolbar** | Planned | See `NOTEPAD-LIFECYCLE-PLAN.md` (P4) — visible template switcher with in-place re-enhancement after recording |
| **Floating panel** | Deferred | Separate macOS window for notepad alongside the meeting app |
| **Enhancement history** | Deferred | Store previous enhancement results, enable undo |
| **Recipes** | Deferred | Saved reusable prompts (like Granola's `/` command system) |

---

## Research Sources

### Granola Documentation & Reviews
- [Granola Official Site](https://www.granola.ai/)
- [AI-enhanced notes — Granola Docs](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes)
- [Writing your own notes — Granola Docs](https://docs.granola.ai/help-center/taking-notes/taking-notes-in-granola)
- [Customize notes with templates — Granola Docs](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates)
- [Granola debuts an AI notepad for meetings — TechCrunch](https://techcrunch.com/2024/05/22/granola-debuts-an-ai-notepad-for-meetings/)
- [How to Get the Best Out of Granola — Granola Blog](https://www.granola.ai/blog/get-the-best-from-granola)
- [Honest Granola AI Review: 20+ Meetings — tl;dv](https://tldv.io/blog/granola-review/)
- [In-Depth Granola Review 2026 — BlueDot](https://www.bluedothq.com/blog/granola-review)
- [What is Granola? — Zapier](https://zapier.com/blog/granola-ai/)
- [Granola AI Review 2026 — Feisworld](https://www.feisworld.com/blog/granola-ai-review)
- [Introducing Recipes — Granola Blog](https://www.granola.ai/blog/say-hello-to-recipes)
- [Granola's Revolutionary AI Strategy — Michael Goitein](https://michaelgoitein.substack.com/p/granolas-revolutionary-ai-strategy)
- [Granola Reviews — G2](https://www.g2.com/products/granola/reviews)
- [Reverse-engineered Granola API — GitHub](https://github.com/getprobo/reverse-engineering-granola-api)
- [Granola AI Review — Zack Proser](https://zackproser.com/blog/granola-ai-review)
- [Granola AI Review — Krisp](https://krisp.ai/blog/granola-ai-review-alternatives/)
- [Granola vs Otter — Alfred](https://get-alfred.ai/blog/granola-vs-otter)
- [Granola vs Fireflies — Efficient App](https://efficient.app/compare/granola-vs-fireflies)

### Competitor Analysis
- [Otter.ai vs Fireflies comparison](https://otter.ai/blog/otter-vs-fireflies-which-ai-meeting-tool-is-better)
- [Notion AI Meeting Notes Help](https://www.notion.com/help/ai-meeting-notes)
- [Fellow meeting management](https://fellow.app)
- [tl;dv video meeting recorder](https://tldv.io)

---

## Verification Plan

1. **Build**: `xcodegen generate && xcodebuild build`
2. **Tests**: `xcodebuild test -scheme SeminarlyTests` — all 117+ tests pass
3. **Recording with notes**: Start recording → verify setup UI disappears and notepad fills screen → type shorthand → toggle transcript → stop → verify "Enhancing your notes..." → verify enhanced notes in detail view
4. **Recording without notes**: Start recording → don't type → stop → verify existing behavior unchanged
5. **Old meetings**: Open pre-existing meeting → verify normal display, empty notes prompt shown
6. **Re-enhance**: Open meeting with notes → edit notes in detail view → click Enhance → verify regenerated
7. **Cost**: Enhancement prompt is similar size to existing (~500-650 token overhead). No cost increase.
