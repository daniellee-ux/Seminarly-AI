# Notepad Research — Granola vs. Seminarly (April 2026)

Research compiled to inform `NOTEPAD-LIFECYCLE-PLAN.md`. Parallel investigation across Granola documentation, demos, reviews, and a direct code audit of Seminarly's notepad implementation. Captures the state of both products as of April 2026.

---

## Executive Summary

Seminarly's notepad ships with the right **data model** (source-attributed `NoteItem`, transcript refs, color-coded bullets) and editor (CJK-safe NSTextView with list nesting, checkboxes, Tab/Shift-Tab renumbering). The **user flow**, however, splits the notepad across three structurally different views (setup form → recording view → `MeetingDetailView`), where Granola's central insight is that the notepad is **one continuous surface** across the meeting lifecycle. Closing that gap is a layout/lifecycle problem, not a data model or feature-parity problem. Granola's other differentiators (magnifying-glass source reveal, 29-template library, mid-meeting chat) are additive but secondary.

---

## 1. Granola's Notepad — How It Actually Works

### Design Philosophy
**"Steering wheel for LLMs."** User types the outline in black text; AI fills in the expansion in gray text. The user guides the AI, not the other way around. Minimal UI during the meeting — no live AI suggestions, no sidebars, just a notepad + an optional transcript pane.

### End-to-End Flow
1. **Pre-meeting** — user opens Granola, sees a blank notepad immediately. Can "jot down pre-meeting thoughts" or an agenda BEFORE recording starts. Calendar integration pre-fills meeting title + attendees.
2. **Start recording** — just a button. Green dancing bars appear at bottom signaling active capture.
3. **During** — user types in the notepad. Transcript pane is togglable, shows chat-style bubbles (grey = others, green = you). Mid-meeting chat available via Cmd+J for quick "what decisions so far?" queries. No AI intrusion in the notepad itself.
4. **Stop** — user clicks "Enhance Notes" button. AI reads user notes + transcript + calendar event. Produces enhanced notes in the SAME document: user's black text preserved, gray AI content interleaved around it.
5. **Source reveal** — magnifying glass icon next to every AI bullet. Click → shows the exact transcript moment that generated the bullet (speaker, timestamp, ~30s context).
6. **Edit / regenerate** — user can edit anywhere, or click "✨ Auto" to re-enhance with a different template. Also available: per-meeting and cross-meeting chat (Granola Chat), Recipes (reusable prompts via `/` command).

### Key UI Elements
- **Black (user) vs gray (AI) text** — zero ambiguity about source.
- **Magnifying glass** — inline source attribution, one click away from verification.
- **Templates as chips** — 29 pre-built (Sales Call, 1:1, Standup, Customer Discovery, Investor Update, Sprint Planning, Interview, etc.) + custom. Applied post-enhancement, not pre-recording. Smart suggestions based on meeting title/attendees.
- **Single notepad view** — the notepad is the only first-class surface. Transcript and chat are secondary panes, not separate tabs.
- **Recipes** — saved prompts accessed via `/` in the chat bar (e.g. "/action-items", "/standup-summary").
- **Spaces** — team workspaces with folders + access controls for collaboration.

### What Granola Intentionally Lacks
- **No export** (copy-paste only) — deliberate ecosystem lock-in. No Markdown, PDF, DOCX.
- **No real-time co-editing**.
- **No live AI suggestions** during meeting (by design).
- **No slash commands in the notepad** (only in chat).
- **Limited checklist / task-tracking**.
- **Recent visual rebrand** (2025–2026) addressed complaints that the original UI was "gray on gray" / "Windows 95."

### Pricing (2026)
Free tier (few meetings). Granola Business: **$14/user/month** for unlimited meetings + team features.

---

## 2. Seminarly Notepad — Current State (Code Audit)

### Views & Flow

```
ContentView
├── Sidebar: meeting list grouped by date
├── RecordingView (sheet / overlay)
│   ├── Phase 1: setupView (full-screen ScrollView form)
│   │   ├── Model loading progress
│   │   ├── Audio source picker (app list + mic toggle)
│   │   ├── Template picker (5 templates + custom instructions)
│   │   ├── Language picker
│   │   └── ● Start Recording button
│   └── Phase 2: activeRecordingView (notepad-dominant)
│       ├── recordingToolbar (pulsing dot + timer + transcript toggle + pause/stop)
│       ├── notepadEditor (MarkdownNoteEditor, auto-focus)
│       ├── processingSection (spinner + status)
│       └── liveTranscriptFooter (togglable, 120pt)
└── MeetingDetailView (post-recording)
    ├── meetingHeader (title, date, duration, Regenerate menu, Export menu)
    ├── Tab bar: Notes / Transcript
    ├── structuredNotesTab
    │   ├── userNotesSection (collapsible card with Enhance button)
    │   ├── summary
    │   ├── template badge
    │   └── sections with BulletPoint rows
    └── transcriptTab
        └── diarized segments with speaker labels + rediarize controls
```

### Editor Capabilities (`MarkdownNoteEditor.swift`)
NSTextView-backed (for CJK safety). Supports:
- Headers `# H1`, `## H2` — enlarged + bold, dimmed marker
- Bold `**text**`, Italic `*text*` — with toggle on Cmd+B / Cmd+I
- Lists: unordered (`-`, `*`), numbered (`1.`, `2.`), checkboxes (`- [ ]`, `- [x]`)
- Tab / Shift-Tab: list nesting with auto-renumbering (single-line + multi-line selection)
- Enter: smart list continuation (auto-increment numbered, exit on empty line)
- Click checkbox: toggles `[x]` ↔ `[ ]`
- Checked items: strikethrough + dimmed
- Hanging indent for wrapped lines
- IME composition detection (`hasMarkedText()`) to defer to system on Chinese/Japanese input

### Data Model (`MeetingModel.swift`, `NoteTemplate.swift`)

```swift
Meeting
├── title, date, duration, appSource, appBundleID
├── transcript: Transcript? (cascade)
├── structuredNote: StructuredNote? (cascade)
├── userNotesText: String?          // raw user text
├── timestampedNotesData: Data?     // [TimestampedNote]
├── speakerEmbeddings: Data?
└── detectedLanguage: String?

NoteItem
├── text: String
├── source: Source?                 // .user | .transcript | nil (legacy)
└── transcriptRef: String?          // e.g. "03:45-04:12"

NoteSection { key, title, icon, items: [NoteItem] }

StructuredNote
├── summary, templateType, generatedAt
└── sectionsData: Data               // JSON-encoded [NoteSection]
```

### Templates (5 + custom)
`lecture`, `studyGuide`, `meeting`, `podcast`, `custom`. Each defines hardcoded `sectionDefinitions` (e.g. Lecture: Key Concepts, Definitions, Examples, Connections, Key Takeaways, Questions Raised). Custom template uses user-provided free-text instructions.

### Claude API Prompts (`PromptTemplates.swift`)
Two paths:
- **`structureNotes()`** — pure transcript → structured notes. Each item is a plain string.
- **`enhanceWithUserNotes()`** — user notes + transcript → merged output. Each item is an object `{text, source, transcriptRef}`. System prompt instructs honest attribution:
  > "If an item directly corresponds to or expands on something the user wrote, mark it 'user'. If it's something the user didn't note at all that you found in the transcript, mark it 'transcript'."

Model: `claude-sonnet-4-20250514`, max 4096 tokens, 120s timeout.

### Rendering (`MeetingDetailView.BulletPoint`)
- User items: accent-color bullet (40% opacity), `textPrimary` body text
- Transcript items: `textSecondary` bullet (40% opacity), `textSecondary` body text
- `transcriptRef` badge: clock icon + timestamp range, clickable → switches to Transcript tab

### Cost
~$0.02-0.04 per meeting (Claude Sonnet).

---

## 3. Side-by-Side Comparison

| Dimension | Seminarly | Granola |
|---|---|---|
| Transcription | 100% local (WhisperKit large-v3) | Cloud (Deepgram) |
| Diarization | FluidAudio neural + MFCC fallback | Cloud |
| AI enhancement | Claude API (user-paid, ~$0.03/mtg) | Proprietary, included in subscription |
| Pricing | One-time key + pay-per-use | $14/user/month |
| Export | Markdown | None (copy-paste only) |
| Templates | 5 + custom | 29 + custom |
| Source attribution data | ✅ `NoteItem.source` + `transcriptRef` | ✅ (presumably similar model) |
| Black/gray visual distinction | ✅ `BulletPoint` color-codes | ✅ |
| Source reveal mechanism | Click ref badge → switch to Transcript tab | Hover AI bullet → inline popover |
| Notepad editor | Markdown (headers, lists, checkboxes, nesting, CJK) | Markdown (headers, lists, bold, italic) |
| List nesting (Tab/Shift-Tab) | ✅ with auto-renumbering | Unknown / not documented |
| Checkboxes | ✅ | Not documented |
| CJK editor safety | ✅ IME-aware | Unknown |
| Pre-recording notepad | ❌ setup form blocks view | ✅ blank notepad visible immediately |
| Notes-visible continuously | ❌ RecordingView → MeetingDetailView = different layouts | ✅ one continuous surface |
| Enhance trigger | Auto on stop | Manual "Enhance Notes" button |
| Enhance animation | View switch (no transition) | AI content fades in around user notes |
| Template switch from notepad | ❌ (buried in header Regenerate menu) | ✅ ✨ Auto chip |
| Mid-meeting chat | ❌ | ✅ Cmd+J |
| Post-meeting chat | ❌ | ✅ per-meeting + cross-meeting |
| Recipes (saved prompts) | ❌ | ✅ `/` command |
| Per-chunk transcript copy | ❌ (selectable only) | ✅ right-click chunk |
| In-transcript search | ❌ | ✅ |
| Team spaces | ❌ | ✅ |
| Share / sync integrations | ❌ (Markdown export only) | Slack, Notion, HubSpot, Affinity, Attio |

### Gaps Identified (priority 2 > 3 > 1 > 5 > 4)
2. User notes severed from enhanced notes (biggest structural gap)
3. Enhance moment is invisible
1. No pre-recording notepad
5. No template awareness during/after recording
4. Source reveal requires navigation

See `NOTEPAD-LIFECYCLE-PLAN.md` for the remediation plan.

---

## 4. What NOT to Copy

Granola's export limitation is a deliberate lock-in that hurts users. Seminarly's Markdown export is a genuine differentiator. Other things worth keeping distinct:
- Local-first transcription (Granola went cloud for better ASR quality, but that's a privacy/cost tradeoff we reject)
- Pay-per-use cost model (Granola's $14/month is uneconomic for low-volume users)
- CJK editor safety (Granola's support is weaker per user reports)

---

## Sources

### Granola Primary Sources
- [Granola Official Site](https://www.granola.ai/)
- [Granola 101](https://docs.granola.ai/article/granola-101)
- [AI-enhanced notes](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes)
- [Taking notes in Granola](https://docs.granola.ai/help-center/taking-notes/taking-notes-in-granola)
- [Customize notes with templates](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates)
- [Transcription](https://docs.granola.ai/article/transcription)
- [Recipes](https://docs.granola.ai/help-center/getting-more-from-your-notes/recipes)
- [Chat with meetings](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings)
- [Upgraded meeting templates — Granola Blog](https://www.granola.ai/blog/upgraded-meeting-note-templates)
- [Granola integrations guide](https://www.granola.ai/blog/granola-integrations-complete-guide-connecting-meeting-tools)

### Reviews & Third-Party Analysis
- [TechCrunch: Granola debuts AI notepad](https://techcrunch.com/2024/05/22/granola-debuts-an-ai-notepad-for-meetings/)
- [TechCrunch: Granola Series C $125M](https://techcrunch.com/2026/03/25/granola-raises-125m-hits-1-5b-valuation-as-it-expands-from-meeting-notetaker-to-enterprise-ai-app/)
- [Meeting Notes: Granola.ai Teardown](https://meetingnotes.com/blog/granola-ai-teardown)
- [Wonder Tools: Granola Guide](https://wondertools.substack.com/p/granolaguide)
- [Zack Proser: Granola AI Review](https://zackproser.com/blog/granola-ai-review)
- [Zapier: What is Granola?](https://zapier.com/blog/granola-ai/)
- [Granola Product Hunt](https://www.producthunt.com/products/granola)
- [AFFiNE: Granola Review](https://affine.pro/blog/granola-note-taking)
- [Create With: Granola Spaces](https://www.createwith.com/tool/granola/updates/granola-introduces-spaces-for-team-wide-meeting-intelligence)

### Seminarly Code Audited
- `Sources/Views/RecordingView.swift`
- `Sources/Views/MeetingDetailView.swift`
- `Sources/Views/MarkdownNoteEditor.swift`
- `Sources/Views/ContentView.swift`
- `Sources/Views/DesignSystem.swift`
- `Sources/NoteStructuring/NoteTemplate.swift`
- `Sources/NoteStructuring/PromptTemplates.swift`
- `Sources/NoteStructuring/NoteStructuringService.swift`
- `Sources/NoteStructuring/ClaudeAPIClient.swift`
- `Sources/Storage/MeetingModel.swift`
