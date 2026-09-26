# Testing Guide

## Overview

- Test target: `SeminarlyTests` (XCTest)
- 136 unit tests across 13 test files in `Tests/`
- CI runs on GitHub Actions on every push/PR

## Test Files

| File | What It Covers |
|------|---------------|
| `AudioBufferAccumulatorTests.swift` | Thread-safe buffer, format conversion |
| `AudioFormatConverterTests.swift` | 48kHz/44.1kHz → 16kHz mono conversion |
| `RecordingSessionTests.swift` | Window-independent capture, close/reopen/minimize, elapsed time, explicit pause, startup/error cleanup, and saving without a view |
| `ClaudeAPIClientTests.swift` | Keychain save/load/delete |
| `CodableModelTests.swift` | Codable round-trips for storage models |
| `DiarizationEngineTests.swift` | MFCC-based speaker assignment |
| `LanguageAwareDiarizationTests.swift` | Chinese diarization, PLDA bypass |
| `SpeakerAttributionTests.swift` | Total speaker budget, confirmed You identity, source-aware assignment, legacy and Codable compatibility |
| `DiarizationAudioTests.swift` | Shared-microphone and hybrid routing, silent system audio, echo gating, raw-audio count limits and error propagation with injected embeddings |
| `MFCCExtractorTests.swift` | 34-dimensional feature extraction |
| `MeetingModelTests.swift` | SwiftData model properties, new fields (userNotesText, timestampedNotes, detectedLanguage) |
| `NoteStructuringParsingTests.swift` | JSON response parsing, NoteItem source attribution |
| `NoteTemplateTests.swift` | Section definitions per template |
| `PromptTemplatesTests.swift` | Structuring prompt + enhancement prompt (user notes + transcript) |
| `SpeakerClustererTests.swift` | Agglomerative clustering |
| `TranscriptTests.swift` | TranscriptSegment Codable, diarizedText formatting |

## Test Plan

### Unit Tests

**AudioFormatConverter**
- [ ] 48kHz stereo → 16kHz mono: output frame count = input * (16000/48000)
- [ ] 44.1kHz stereo → 16kHz mono: verify correct ratio
- [ ] Empty buffer input → returns nil
- [ ] `extractFloatSamples()` — output array length matches `frameLength`
- [ ] Verify output is mono (single channel)

**ClaudeAPIClient (Keychain)**
- [ ] `saveAPIKey("test-key")` → `loadAPIKey()` returns `"test-key"`
- [ ] `saveAPIKey` twice → second value overwrites first
- [ ] `deleteAPIKey()` → `loadAPIKey()` returns nil
- [ ] `loadAPIKey()` with no saved key → returns nil

**PromptTemplates**
- [x] `structureNotes(transcript:)` — output contains the transcript text
- [x] Output contains JSON field names: "title", "summary", and template section keys
- [x] `systemPrompt` is non-empty
- [x] `enhanceWithUserNotes()` — output contains both user notes and transcript
- [x] `enhanceSystemPrompt()` — includes user-note priority and source attribution instructions
- [x] Enhancement prompt requests `{text, source, transcriptRef}` objects

**NoteStructuringService (JSON parsing)**
- [x] Valid JSON → parses into correct `StructuredNote` fields
- [x] Empty arrays for sections → parses correctly
- [x] Malformed JSON → returns nil with error message
- [x] `NoteItem` plain string → decodes with `source: nil` (legacy compatibility)
- [x] `NoteItem` object `{text, source, transcriptRef}` → decodes all fields correctly

**MeetingModel (SwiftData)**
- [x] Create Meeting, insert, fetch — properties match
- [x] Meeting with Transcript relationship — cascade delete removes Transcript
- [x] Meeting with StructuredNote relationship — cascade delete removes StructuredNote
- [x] `formattedDuration` — 90 seconds → "1m 30s"
- [x] `formattedDate` — returns non-empty string
- [x] `isProcessed` — false when no StructuredNote, true when present
- [x] `userNotesText` — round-trip encode/decode
- [x] `timestampedNotes` — computed property encode/decode via `timestampedNotesData`
- [x] `detectedLanguage` — stores ISO language code

**TranscriptSegment (Codable)**
- [ ] Encode → decode round-trip preserves all fields
- [ ] `speaker` nil → encodes without speaker key
- [ ] Array of segments → encode/decode preserves order

**ActionItem (Codable)**
- [ ] Encode → decode round-trip preserves description, assignee, isCompleted
- [ ] Default `isCompleted` is false

**DiarizationEngine**
- [ ] Empty segments → returns empty array
- [ ] Single segment → labeled "Speaker 1"
- [ ] Two segments with > 1.5s gap → different speaker labels
- [ ] Two segments with < 1.5s gap, similar energy → same speaker label
- [ ] Segments with large energy ratio change → speaker switch

**Transcript**
- [ ] `diarizedText` with segments → formatted as `[MM:SS] Speaker: text`
- [ ] `diarizedText` with empty segments → returns `rawText`

### Integration Tests

**Audio Pipeline**
- [ ] `MicrophoneCaptureManager.start()` → callback fires with non-empty buffer
- [ ] Buffer format has valid sample rate and channel count
- [ ] `AudioFormatConverter` with live mic buffer → produces 16kHz output
- [ ] `MicrophoneCaptureManager.stop()` → no more callbacks fire
- Note: requires microphone permission, skip in CI

**WhisperKit**
- [ ] Load `tiny` model (fast, CI-friendly) → `isModelLoaded` becomes true
- [ ] Transcribe known audio file → output contains expected words
- [ ] Transcribe silence → output is empty or near-empty
- [ ] Segment timestamps are monotonically increasing

**Claude API**
- [ ] Send sample transcript → response is valid JSON
- [ ] Response contains all required fields (title, summary, etc.)
- [ ] Invalid API key → returns `.noAPIKey` or `.apiError(401, ...)`
- Note: costs ~$0.03 per call, use sparingly

**Full Pipeline**
- [ ] Audio file → TranscriptionEngine → DiarizationEngine → NoteStructuringService
- [ ] Output Meeting has non-empty Transcript and StructuredNote
- [ ] Structured note summary relates to transcript content

### Manual Tests

**Audio Capture**
- [ ] While recording, close the last window (red close button / Cmd+W), wait at least 2 minutes, then reopen from the menu bar or Dock — the same session, notes, timer, and transcript continue
- [ ] While recording, minimize the window (yellow button / Cmd+M) for at least 2 minutes — audio and transcription continue, and the timer reflects the full elapsed time on return
- [ ] With no open window, use menu-bar Pause / Resume / Stop — only these explicit controls change capture state, and Stop saves one session
- [ ] With no open window, Quit the app — wait for transcription and saving to finish, then verify the saved session after relaunch
- [ ] Pause explicitly, then close/reopen — the session stays paused and its duration excludes paused time
- [ ] Close the window during capture startup and during finalization — startup continues; finalization still saves exactly once
- [ ] In Activity Monitor, enable the App Nap column: active recording must remain out of App Nap while hidden; after pause/stop the recording activity assertion is released
- [ ] Select Zoom from process list → record 30s → audio is clean (no distortion)
- [ ] Select Google Meet → record → audio captures remote participants
- [ ] Mic-only mode (no system audio) → captures user voice
- [ ] Both sources simultaneously → both voices in transcript
- [ ] Process list refreshes when new audio app starts

**Audio Source Auto-Detection**
- [ ] Launch Zoom → `AudioDetectionBanner` appears within 3 seconds
- [ ] Click "Record" on banner → RecordingView opens with Zoom pre-selected
- [ ] Click dismiss (✕) → banner disappears, Zoom not suggested again this session
- [ ] Banner auto-dismisses after 20 seconds
- [ ] Disable auto-detect in Settings → no banners appear
- [ ] Banner suppressed while recording is active

**Notepad**
- [ ] Start recording → setup UI disappears, notepad fills screen
- [ ] Type shorthand notes → text persists and is editable
- [ ] Markdown styling: `# Heading` renders larger/bolder, `**bold**` renders bold, `- item` renders as bullet
- [ ] CJK input (Chinese, Japanese, Korean) → composition not destroyed mid-input
- [ ] Toggle transcript footer → live transcript shows/hides
- [ ] Stop recording with notes → "Enhancing your notes..." status appears → enhanced notes in detail view
- [ ] Stop recording without notes → "Generating structured notes..." status → structured notes (existing behavior)
- [ ] Notes saved to `meeting.userNotesText` and visible in MeetingDetailView

**Transcription Quality**
- [ ] 1-speaker clear audio → WER < 5%
- [ ] 2-speaker meeting → both voices transcribed
- [ ] Heavy background noise → degrades gracefully (no crash)
- [ ] Long meeting (30+ min) → all chunks processed, no memory issues

**Diarization**
- [ ] An older transcript with Speaker 1, Speaker 2, You → select 2 → at most two labels, including You; select 1 then 2 again → original local-turn evidence remains available
- [ ] Your voice → choose a speaker → only that identity is renamed You; select Not identified → return to neutral names without changing the count
- [ ] Change the count so confirmed identities merge → do not label other known speakers You; show a message when the identity cannot be matched confidently
- [ ] Rediarize remains available when the selected count equals the original count; Restore Original is a separate action
- [ ] Missing or invalid voice data → visible error and unchanged transcript; no overlapping evidence → unassigned turns, not a guessed Speaker 1
- [ ] Shared-microphone recording → multiple neutral speakers; no automatic You; re-clustering includes microphone embeddings
- [ ] Hybrid meeting and loudspeaker echo → verify source selection against listening, especially overlapping speech; energy gating is not full echo cancellation
- [ ] During rediarization, switch sessions or tabs → cancel publication of the old result and do not overwrite another session or a concurrent edit
- [ ] 2-speaker meeting → labels alternate correctly at speaker changes
- [ ] Single speaker → all segments labeled "Speaker 1"
- [ ] Rapid back-and-forth → some mislabeling acceptable

**Note Structuring**
- [ ] 5-min meeting → summary is 2-3 sentences
- [ ] Meeting with clear action items → action items populated
- [ ] Meeting with no decisions → decisions array empty
- [ ] Very short meeting (< 1 min) → still produces reasonable output

**Storage & UI**
- [ ] Meeting persists after app restart
- [ ] Delete meeting → removed from list and database
- [ ] Search by title → filters correctly
- [ ] Search by transcript content → finds matching meetings
- [ ] Edit meeting title (double-click) → saves on Enter

**Export**
- [ ] Export Markdown → valid .md file with all sections
- [ ] Copy to clipboard → pasteable into any text editor
- [ ] Markdown includes transcript when available

**Menu Bar**
- [ ] Menu bar icon visible
- [ ] "Open Seminarly" opens/focuses main window
- [ ] "Quit" terminates the app

**Settings**
- [ ] Save API key → persists across app restart
- [ ] Remove API key → cleared from Keychain
- [ ] Show/hide key toggle works

## Running Tests

```bash
# Unit + integration tests
xcodebuild test -project Seminarly.xcodeproj -scheme SeminarlyTests -destination 'platform=macOS'

# Build only (no tests)
xcodebuild -project Seminarly.xcodeproj -scheme Seminarly -destination 'platform=macOS' build
```

## CI Considerations

- WhisperKit model download: cache models in CI, or use `tiny` for speed
- Microphone tests: skip on CI (no audio device), gate with `XCTSkipIf`
- Claude API tests: require `ANTHROPIC_API_KEY` env var, skip if absent
- System audio capture: requires macOS 14.4+ runner with audio permissions
