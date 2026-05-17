# Notepad Lifecycle — Granola Gap Closure Plan

> **Status:** Phase 1 shipped, Phase 2 in progress (2026-04-05). Builds on `NOTEPAD-FEATURE.md` (the initial notepad implementation, shipped 2026-03). This doc proposes the next evolution: **making the notepad a continuous surface across the full meeting lifecycle.**
>
> **Shipped:** P1 (commit `2575673`), P2+P3 (commit `2757d24`). **Remaining:** P4, P5, P6, P7.

## Problem

The initial notepad ships with the right data model (source-attributed items, transcript refs, color coding) but the **user experience still feels like three separate products**:

1. **Setup form** — wall of pickers (audio source, template, language). No notepad visible.
2. **Recording view** — notepad-dominant, live transcript.
3. **MeetingDetailView** — tabbed (Notes / Transcript), with user's raw notes in a collapsible "Your Notes" card stacked above the AI-generated structured sections.

Granola's magic is that **the notepad is one continuous document** across the entire meeting lifecycle. User types an agenda → recording begins → notes grow → user clicks Enhance → AI content fades in around their words. Nothing moves, nothing switches, nothing feels like a different screen. Our current implementation requires the user to mentally stitch together three different layouts.

## Current Gaps (prioritized 2 > 3 > 1 > 5 > 4)

| # | Gap | Current behavior | Granola behavior |
|---|---|---|---|
| **2** | User notes severed from enhanced notes | User's raw text sits in a collapsible "Your Notes" card; AI-generated sections render below as a separate document | One document: user's black text interleaved with AI's gray text |
| **3** | Enhance moment is invisible | Stop recording → spinner → auto-navigation to `MeetingDetailView` with a different layout | User clicks "Enhance Notes" → AI content fades into the same notepad |
| **1** | No pre-recording notepad | Setup form occupies full screen before recording | Blank notepad visible immediately; user types agenda before hitting Record |
| **5** | No template awareness during/after recording | Template locked at recording start; Regenerate menu buried in toolbar | Template chip visible throughout; one-click swap with in-place re-enhancement |
| **4** | Source reveal requires navigation | Clicking transcript-ref badge switches to Transcript tab and scrolls | Magnifying glass on AI bullet → inline popover with transcript chunk |

## Strengths to Preserve

- Local WhisperKit transcription (privacy)
- FluidAudio neural diarization
- Claude API with transparent cost (~$0.02-0.04/meeting)
- Markdown export
- CJK-safe editor with IME composition handling
- Tab/Shift-Tab list nesting with auto-renumbering (no Granola equivalent)
- Checkboxes with strikethrough

---

## Design Direction: Continuous Notepad

The notepad becomes **one view that persists through every lifecycle state**, with a phase-aware top toolbar that morphs to show the right controls.

### Lifecycle States

| State | Top toolbar | Notepad content |
|---|---|---|
| **Idle / Pre-recording** | Audio chip · Template chip · Language chip · red `● Record` button | User-typed agenda (optional) |
| **Recording** | Recording indicator · elapsed time · transcript toggle · pause/stop | User's typed notes (live) |
| **Stopped, pre-enhance** | Prominent "Enhance with Transcript" CTA · template chip | User's typed notes + transcript available |
| **Enhancing** | Loading state | User's notes + spinner overlay |
| **Enhanced** | Template chip · re-enhance · export · transcript toggle | User's notes with AI items woven in (gray) |

### Layout Sketch

```
┌─────────────────────────────────────────────────────┐
│ 🎙 Zoom ▾   📝 Lecture ▾   🌐 Auto ▾          ● Record │  ← idle
├─────────────────────────────────────────────────────┤
│  Jot down your agenda or pre-meeting thoughts...    │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ ● 12:34   📝 Lecture   [transcript] [pause] [stop]  │  ← recording
├─────────────────────────────────────────────────────┤
│  # Neural Networks                                  │
│  - backprop = chain rule                            │
│  - vanishing gradient                               │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ ✨ Lecture ▾   🔄 Re-enhance   📋 Export   📑 Transcript │  ← enhanced
├─────────────────────────────────────────────────────┤
│  # Neural Networks                                  │
│                                                     │
│  Key Concepts                                       │
│  • backprop = chain rule                    [user]  │
│    ↳ Chain rule applied to composed         [ai⏱]   │
│      functions across layers                        │
│  • vanishing gradient                       [user]  │
│  • ReLU prevents vanishing gradients        [ai⏱]   │
└─────────────────────────────────────────────────────┘
```

### Architecture Plan

**New shared component:** `NotepadSurface` — renders the notepad in any lifecycle state, accepting:
- `userNotesText: Binding<String>` — always editable
- `structuredNote: StructuredNote?` — when present, render template sections with user items first, then transcript items
- `state: NotepadState` — idle / recording / stopped / enhancing / enhanced
- callbacks: `onStart`, `onStop`, `onEnhance`, `onReEnhance`, `onTemplateChange`

**`RecordingView` keeps user through full lifecycle.** After `stopRecording()` finishes, the view stays — it doesn't auto-navigate to `MeetingDetailView`. The toolbar transforms to show the Enhance CTA. User clicks Enhance → AI content fades in. User clicks back / Done → navigates to MeetingDetailView for archival browsing.

**`MeetingDetailView` becomes a historical view** for completed meetings. It uses the same `NotepadSurface` component, so past meetings look identical to just-finished ones. The current tab split is replaced by a transcript side-panel toggle.

**Data flow:** unchanged. `StructuredNote.sections[].items` already carry `source` and `transcriptRef`. We just render them differently (interleaved instead of sectioned-separately-from-user-notes).

---

## Work Units

### Phase 1 — Continuous Notepad (sequential, ships as one PR)

**P1 — Unified notepad lifecycle** — ✅ Shipped (commit `2575673`)

Files:
- `Sources/Views/RecordingView.swift`
- `Sources/Views/MeetingDetailView.swift`
- new `Sources/Views/NotepadSurface.swift` (extracted shared component)
- minor: `Sources/Views/BulletPoint.swift` (extracted from MeetingDetailView if not already)

Changes:
1. Extract `NotepadSurface` that renders user notes + optional structured note inline. User items render first in each template section with primary styling; transcript items follow in secondary color.
2. Modify `RecordingView` to stay open after `stopRecording()` completes. Replace auto-navigation with a post-recording phase showing a prominent "Enhance with Transcript" CTA button.
3. Move enhancement trigger from `stopRecording()` into an explicit user action (Enhance button click). Keep existing `noteService.enhanceNotes()` / `structureTranscript()` calls intact.
4. Update `MeetingDetailView.structuredNotesTab` to use `NotepadSurface` with the meeting's saved `structuredNote` + `userNotesText`. Remove the separate collapsible "Your Notes" card.
5. Keep the Transcript tab/panel (possibly convert to togglable side panel in a later unit).

Why one PR: units 1, 2, 3, 4 are mutually dependent — each invalidates the next if done in isolation. Extracting `NotepadSurface` without using it anywhere would be dead code. Keeping the recording view alive without the new CTA would leave the user stranded. Updating `MeetingDetailView` to use `NotepadSurface` without the component existing is impossible.

### Phase 2 — Polish (parallelizable, after P1 merges)

**P2 — Compact recording setup bar** — ✅ Shipped (commit `2757d24`, combined with P3)

Files: `Sources/Views/RecordingView.swift`, new `Sources/Views/RecordingSetupBar.swift`

Replace the full-screen setup `ScrollView` form with a compact horizontal toolbar: Audio chip · Template chip · Language chip · `● Record` button. Each chip opens a menu/popover with the same options. Preserves all functionality (model loading state, error/retry, mic toggle, custom instructions, built-in speaker warning).

**P3 — Pre-recording notepad visibility + phase-aware placeholder** — ✅ Shipped (commit `2757d24`, combined with P2)

Files: `Sources/Views/RecordingView.swift`

- Make the notepad editor visible below the setup bar BEFORE recording starts (currently only in `activeRecordingView`).
- Preserve user's typed text when they hit Start Recording.
- Phase-aware placeholder:
  - Pre-recording (empty): "Jot down your agenda or questions before the meeting starts..."
  - During recording (empty): "Type notes as you listen. Use # for headings..."
  - Post-recording (empty, not enhanced): "Click Enhance to merge your notes with the transcript"

**P4 — Template chip in NotepadSurface toolbar**

Files: `Sources/Views/NotepadSurface.swift` (created in P1)

Replace the "Regenerate" menu with a visible `✨ <template name> ▾` chip in the notepad toolbar. Click opens template picker. Selecting a new template triggers in-place re-enhancement with a loading state on the chip. Also works pre-enhancement to select the template that will be used.

**P5 — Enhancement fade-in animation**

Files: `Sources/Views/NotepadSurface.swift`

When AI content arrives (enhancement completes), fade in the transcript-sourced bullets with a subtle `.easeIn` animation (~300ms). Small toast: "Added N points from transcript." Keeps the "magic moment" visible.

**P6 — Source reveal popover on AI bullets**

Files: `Sources/Views/BulletPoint.swift` (or wherever the bullet component lives post-P1)

On hover of a bullet with `transcriptRef`: show magnifying glass icon. Click → SwiftUI `.popover()` with:
- Timestamp range (from `transcriptRef`)
- Speaker label (looked up from transcript segments)
- Transcript text for that range + ~15s context
- "Open full transcript →" button (navigates to transcript view with the chunk highlighted)

Uses existing `transcript.segments` data. Parse `transcriptRef` string ("03:45-04:12") to seconds, match against segments.

**P7 — Attribution in Markdown export**

Files: `Sources/Views/MeetingDetailView.swift` (`generateMarkdown()`)

- User bullets: `- Key point`
- Transcript bullets: `- _Key point_ <sub>[03:45-04:12]</sub>`
- Add legend: "_Italicized items were extracted from the transcript._"

---

### Phase 3 — Feature Additions (deferred, after Phase 2 complete)

- **Expand template library** — add `oneOnOne`, `standup`, `salesCall`, `interview` presets (NoteTemplate.swift + PromptTemplates.swift)
- **Transcript interactions** — per-chunk context-menu copy + search-within-transcript
- **Mid-meeting chat (Cmd+J)** — quick Q&A over partial transcript
- **Chat with completed meeting** — post-meeting transcript Q&A, persisted history

---

## Dispatch Strategy

P1 is a genuine architectural change and should be reviewed end-to-end before Phase 2 begins. Recommended sequence:

1. **Dispatch P1 as a solo PR.** Review visually, merge.
2. **Dispatch P2-P7 as 6 parallel workers in worktrees.** They share `NotepadSurface.swift` (from P1) but their edits are in distinct regions / files.
3. **Phase 3 units** follow as a separate batch.

Alternative (more aggressive): dispatch P1 + P6 + P7 in parallel initially — P6 and P7 have minimal overlap with P1's files. Leave P2-P5 for after P1 merges.

## Verification

Seminarly is a native macOS SwiftUI app with 136 unit tests and no UI automation. **Per-unit verification:**

1. **Build:** `xcodegen generate && xcodebuild -project Seminarly.xcodeproj -scheme Seminarly -destination 'platform=macOS' build` — zero warnings
2. **Unit tests:** `xcodebuild test -project Seminarly.xcodeproj -scheme SeminarlyTests -destination 'platform=macOS'` — all pass
3. **Visual verification:** user runs the app manually post-merge

UI units (P1-P6) skip automated end-to-end testing. Units with isolated logic (P7 export, Phase 3 templates) should add targeted unit tests.

## Critical Files Reference

- `Sources/Views/RecordingView.swift` — setup + recording + notepad (L82-257)
- `Sources/Views/MeetingDetailView.swift` — post-recording view + BulletPoint (L149-192, L519-564)
- `Sources/Views/MarkdownNoteEditor.swift` — NSTextView editor (no changes needed)
- `Sources/NoteStructuring/NoteTemplate.swift` — templates + NoteItem/NoteSection
- `Sources/NoteStructuring/PromptTemplates.swift` — system + user prompts
- `Sources/NoteStructuring/NoteStructuringService.swift` — enhanceNotes(), structureTranscript()
- `Sources/Storage/MeetingModel.swift` — Meeting, Transcript, StructuredNote
- `Sources/Views/DesignSystem.swift` — colors, typography, spacing
