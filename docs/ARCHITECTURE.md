# Architecture

## Overview

Seminarly is a native macOS app built with Swift 6 and SwiftUI. It follows a pipeline architecture where audio flows through capture → transcription → diarization → structuring → storage. It supports multiple note templates (lecture, study guide, meeting, podcast, custom) for different use cases.

## Module Breakdown

### Audio (`Sources/Audio/`)

- `CoreAudioUtils`
  - Static helpers wrapping `AudioObjectGetPropertyData`
  - `getProcessList()` — queries `kAudioHardwarePropertyProcessObjectList` for all audio-registered processes
  - `getProcessPID()` / `getProcessBundleID()` / `isProcessRunningOutput()` — read per-process properties
  - `translatePIDToProcessObject()` — converts `pid_t` → `AudioObjectID` (required by `CATapDescription`)
  - `listAudioProcesses()` — returns `[AudioProcess]` with name, PID, bundle ID, active status
  - `getDefaultOutputDeviceID()` / `getDeviceUID()` — needed for aggregate device creation
- `ProcessTapManager`
  - Creates `CATapDescription(stereoMixdownOfProcesses:)` targeting a single process
  - Calls `AudioHardwareCreateProcessTap` → gets tap `AudioObjectID`
  - Reads tap format via `kAudioTapPropertyFormat` → `AudioStreamBasicDescription`
  - Creates aggregate device with `kAudioAggregateDeviceTapListKey` pointing to the tap UUID
  - Attaches `AudioDeviceCreateIOProcIDWithBlock` on a `.userInteractive` dispatch queue
  - IO callback converts `AudioBufferList` → `AVAudioPCMBuffer` and forwards to `audioBufferCallback`
  - Cleanup order: stop device → destroy IO proc → destroy aggregate → destroy tap
- `AudioBufferAccumulator`
  - Standalone `@unchecked Sendable` class (not `@MainActor`)
  - Thread safety via `NSLock` — safe to call from real-time audio threads
  - Owns `systemConverter` and `micConverter` (`AudioFormatConverter` instances)
  - Lazy-initializes converters on first buffer (format isn't known until audio starts)
  - Exposes `onAudioSamples` callback for streaming to transcription engine
- `AudioFormatConverter`
  - Wraps `AVAudioConverter` from source format → 16kHz mono Float32
  - Source format typically 44.1kHz or 48kHz stereo Float32 (system audio)
  - Uses `convert(to:error:inputBlock:)` with single-shot input provider
  - `extractFloatSamples()` — copies `floatChannelData[0]` into `[Float]` array
- `MicrophoneCaptureManager`
  - `AVAudioEngine` with `installTap(onBus:bufferSize:format:)` on input node
  - Buffer size: 4096 frames
  - Format: whatever the input device provides (converted later)
- `AudioCaptureManager`
  - `@MainActor` `ObservableObject` — the public API for views
  - Owns `ProcessTapManager`, `MicrophoneCaptureManager`, `AudioBufferAccumulator`
  - `startRecording()` — wires callbacks, starts tap + mic, starts refresh timer
  - `stopRecording()` → returns `[Float]` accumulated samples
  - Refresh timer polls `listAudioProcesses()` every 5 seconds during recording
- `AudioSourceMonitor`
  - `@MainActor` `ObservableObject` — publishes `detectedProcess`, `isEnabled`
  - Polls `CoreAudioUtils.listAudioProcesses()` every 3 seconds via `Timer`
  - Tracks `knownActiveObjectIDs` to detect transitions from silent → active
  - Prioritizes meeting apps (Zoom, Teams, Meet, Webex, Discord, browsers) via `meetingBundleIDs` set
  - Ignores system processes and own app via `ignoredBundleIDs`
  - Dismissed bundle IDs tracked per monitoring session (won't re-suggest)
  - Auto-dismisses banner after 20 seconds via `bannerDismissTask`
  - Suppresses detection while `isRecordingActive` is true
  - Persists enabled state to `UserDefaults` (key: `autoDetectAudioSources`), defaults to enabled

### Transcription (`Sources/Transcription/`)

- `TranscriptionEngine`
  - `@MainActor` `ObservableObject` — publishes `liveText`, `segments`, loading state
  - `loadModel()` — async, calls `WhisperKit(model:)` which downloads + loads model
  - `appendAudio()` — accumulates samples, triggers transcription at 30-second threshold
  - `processAccumulatedAudio()` — swaps buffer and spawns `Task` to transcribe
  - `transcribe()` — calls `whisperKit.transcribe(audioArray:)`, maps `TranscriptionSegment` → `TranscriptSegment`
  - `finalizeTranscription()` — cancels pending task, processes remaining audio, returns all segments
  - Timestamps: tracks `totalTranscribedDuration()` as offset for each chunk's segment times
  - Model options: `tiny`, `base`, `small`, `medium`, `large-v3`

### Diarization (`Sources/Diarization/`)

Two engines are available: the neural engine (primary) and the MFCC-based engine (legacy fallback).

- `NeuralDiarizationEngine` (primary)
  - `@MainActor` `ObservableObject` — publishes `isModelReady`, `modelStatus`, `isDiarizing`
  - Uses **FluidAudio** library (`OfflineDiarizerManager`) for neural speaker embeddings
  - `prepareModels()` — downloads and caches neural diarization models (one-time, async)
  - `diarize(segments:systemSamples:micSamples:sampleRate:)` — main entry point
  - **Speaker assignment algorithm**:
    - Runs `diarizer.process(audio:)` on mixed system+mic audio
    - FluidAudio returns `[TimedSpeakerSegment]` with `speakerId`, `startTimeSeconds`, `endTimeSeconds`, `qualityScore`
    - Maps neural segments onto transcript segments using **time-overlap weighting** (most overlapping speaker wins)
    - Builds consistent `speakerId` → "Speaker N" label mapping
    - Confidence = overlap fraction of the dominant speaker
  - **Mic speaker detection**: if mic samples provided, segments where mic RMS energy > 2x system energy are relabeled as "You"
  - Performance: ~15 seconds for a full meeting (vs ~5 minutes with old approach)
  - Supports N speakers (not limited to 2)

- `DiarizationEngine` (legacy fallback)
  - `@MainActor` `ObservableObject`
  - MFCC + pitch-based windowed analysis with agglomerative clustering
  - Uses `MFCCExtractor` for 34-dimensional speaker embeddings and `SpeakerClusterer` for batch clustering
  - Runs diarization off main actor for performance

- `MFCCExtractor`
  - Extracts 34-dimensional speaker embeddings using Accelerate/vDSP:
    - MFCC stddev (13): voice variability
    - Delta MFCC means (13): temporal dynamics / pitch contour
    - Pitch features (4): median F0, F0 stddev, F0 range, voiced frame ratio (autocorrelation-based, CMNDF algorithm)
    - Spectral features (4): centroid + spread (bright/dark voice, vocal resonance)
  - Cached FFT setup and mel filterbank for efficiency

- `SpeakerClusterer`
  - Batch agglomerative clustering with average linkage and cosine distance
  - Precomputes pairwise distance matrix, merges closest clusters until threshold or elbow detected (2x jump)
  - Stops at `maxSpeakers` (default 6)
  - Also supports online/streaming mode with centroid tracking

### Note Structuring (`Sources/NoteStructuring/`)

- `NoteTemplate` (enum, 5 cases)
  - `lecture` — Key Concepts, Definitions, Examples, Key Takeaways, Questions Raised
  - `studyGuide` — Topics Covered, Key Points, Q&A Review, Practice Problems, Further Study
  - `meeting` — Discussion Points, Decisions, Action Items, Follow-up Questions
  - `podcast` — Themes, Key Insights, Notable Quotes, References, Takeaways
  - `custom` — User-defined instructions, no fixed sections
  - Each template defines `sectionDefinitions: [SectionDefinition]` (key, title, icon, promptHint)
- `NoteItem` (Codable struct, replaces plain `String` items)
  - `text: String` — the note content
  - `source: Source?` — `.user` (from user's manual notes) or `.transcript` (from transcript only). Nil for legacy/non-enhanced notes
  - `transcriptRef: String?` — approximate timestamp range, e.g. "03:45-04:12" (v2 feature for clickable links)
  - Custom `Decodable`: accepts both plain strings (backward compatible) and `{text, source, transcriptRef}` objects
- `TemplateSettings`
  - `@MainActor` singleton (`TemplateSettings.shared`)
  - Persists default template + custom instructions to `UserDefaults`
- `PromptTemplates`
  - **Structuring path** (transcript only):
    - `systemPrompt(for:)` — generates role-based system instructions per template
    - `structureNotes(transcript:template:customInstructions:)` — builds dynamic JSON schema from template's section definitions + template-specific rules
  - **Enhancement path** (user notes + transcript):
    - `enhanceSystemPrompt(for:)` — extends base system prompt with user-note priority rules and source attribution instructions
    - `enhanceWithUserNotes(userNotes:transcript:template:customInstructions:)` — builds prompt with both user notes and transcript, requests `{text, source, transcriptRef}` objects
  - Output format: raw JSON (no markdown fences)
- `ClaudeAPIClient`
  - `Sendable` class, stateless (creates URLSession in init)
  - API: `POST https://api.anthropic.com/v1/messages`
  - Headers: `x-api-key`, `anthropic-version: 2023-06-01`
  - Model: `claude-sonnet-4-20250514`
  - Max tokens: 4096, timeout: 120 seconds
  - Keychain: `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`
    - Service: `ai.seminarly.Seminarly`, account: `anthropic-api-key`
  - Error handling: decodes `ClaudeErrorResponse` on non-200 status
- `NoteStructuringService`
  - `@MainActor` `ObservableObject` — publishes `isProcessing`, `errorMessage`
  - `structureTranscript(text:template:customInstructions:)` — sends diarized text → parses JSON → returns `(title, StructuredNote)`
  - `enhanceNotes(userNotes:transcript:template:customInstructions:)` — sends user notes + transcript via enhancement prompt → parses JSON with source attribution → returns `(title, StructuredNote)`
  - Uses `TemplatedNoteResponse` with `DynamicCodingKey` to parse any template's JSON output (handles both plain strings and `NoteItem` objects)
  - `hasAPIKey` — checks Keychain for existence
  - Cost: ~$0.02-0.04 per 30-min meeting

### Storage (`Sources/Storage/`)

- `Meeting` (`@Model`)
  - Properties: title, date, duration, appSource, appBundleID
  - Notepad: `userNotesText: String?` (raw notepad text), `timestampedNotesData: Data?` (JSON-encoded `[TimestampedNote]`), computed `timestampedNotes`
  - Audio: `systemAudioPath`, `micAudioPath`, `speakerEmbeddingsData`, `originalSpeakerCount`, `originalSegmentsData`
  - Language: `detectedLanguage: String?` (e.g. "zh", "en" from WhisperKit acoustic analysis)
  - Relationships: `transcript` (1:1, cascade), `structuredNote` (1:1, cascade)
  - Computed: `isProcessed`, `formattedDuration`, `formattedDate`, `hasRediarizationData`
- `Transcript` (`@Model`)
  - Properties: `rawText` (full text), `segmentsData: Data` (JSON-encoded)
  - Computed: `segments` — decode/encode `[TranscriptSegment]` from `segmentsData`
  - Computed: `diarizedText` — formats segments as `[HH:MM] Speaker: text`
  - Inverse: `meeting: Meeting?`
- `TranscriptSegment` (Codable, Sendable struct)
  - Properties: startTime, endTime, text, speaker (optional), speakerConfidence (optional)
  - Stored as JSON array inside `Transcript.segmentsData`
- `StructuredNote` (`@Model`)
  - Properties: `summary`, `templateType: String` (e.g. "lecture"), `sectionsData: Data` (JSON-encoded), `generatedAt`
  - Computed: `sections` — decode/encode `[NoteSection]` from `sectionsData`
  - Computed: `resolvedTemplate` — converts `templateType` string back to `NoteTemplate` enum
  - Inverse: `meeting: Meeting?`
- `NoteSection` (Codable, Sendable struct)
  - Properties: key, title, icon, items: [NoteItem]
- ModelContainer configured in `SeminarlyApp.init()` with `Meeting` as root schema

### Views (`Sources/Views/`)

- `ContentView`
  - `NavigationSplitView`: sidebar (meeting list) + detail (meeting or empty state)
  - `@Query` fetches meetings sorted by date descending
  - Search: filters by title, transcript text, or note summary
  - Toolbar: record button (opens sheet), settings button (opens sheet)
  - Swipe-to-delete with confirmation dialog on meeting rows
- `RecordingView`
  - Sheet modal, 700x600, three-phase layout:
  - **Phase 1 (Setup)**: compact top toolbar with chip-backed menus (Audio / Template / Language) + Record button; notepad visible below toolbar for pre-recording agenda; model loading / error banners shown conditionally
  - **Phase 2 (Recording)**: thin recording toolbar (red dot + timer + pause/stop), `NotepadSurface` fills most space, collapsible live transcript footer (~120px)
  - **Phase 3 (Post-recording)**: toolbar with "Recording saved" indicator + "Enhance with Transcript" CTA + Done button; `NotepadSurface` rendering either raw notes (pre-enhance) or structured note (post-enhance, read-only) with loading overlay during enhancement
  - Template selection: Menu-backed chip in setup toolbar; custom instructions shown inline when `.custom` selected
  - Uses `NeuralDiarizationEngine` — calls `prepareModels()` on appear
  - Pipeline on stop: finalize transcription → neural diarize → save Meeting + Transcript to SwiftData (WITHOUT enhancement) → transition to post-recording phase. User explicitly triggers enhancement via CTA → `runEnhancement()` calls `enhanceNotes()` (if user notes present) or `structureTranscript()` → updates `meeting.structuredNote`
  - Timer: 1-second interval updating elapsed time display
- `MarkdownNoteEditor`
  - NSTextView-backed editor (`NSViewRepresentable`) — not SwiftUI TextEditor
  - Live markdown styling: headings (`# `, `## `), bold (`**text**`), bullets (`- `)
  - CJK input method composition safety: checks `hasMarkedText()` before applying styles
  - Auto-focus option: editor becomes first responder on appear when enabled
  - `onLineCompleted` callback for timestamped notes feature (fires on Return key)
- `AudioDetectionBanner`
  - Shows app icon (via `NSRunningApplication`) or speaker wave system icon
  - App name + "is producing audio" text
  - Record button (primary, `.borderedProminent`) + Dismiss button (x icon)
  - Styled with `.seminarlyCard()` + drop shadow
- `MeetingDetailView`
  - Header: editable title (double-click), date, duration, source; shows Enhance CTA button when transcript exists but no structured note; "Regenerate" menu (all templates) when structured note exists; Export menu (Markdown file, clipboard)
  - TabView: "Notes" tab + "Transcript" tab (segment rows)
  - Notes tab: uses `NotepadSurface` which renders either the markdown editor (pre-enhance) or summary + template badge + template sections with user-sourced items first (post-enhance); **dynamically renders sections** from `note.sections` (no hardcoded section names)
  - User notes editing: `NotepadSurface` binds to `editableUserNotes` state, which syncs to `meeting.userNotesText` on change (with change-guard to skip no-op saves)
  - `generateMarkdown()` — produces full Markdown document from meeting data
- `NotepadSurface`
  - Shared component used by `RecordingView` (setup, recording, post-recording) and `MeetingDetailView`
  - Two modes: editor mode (`MarkdownNoteEditor` bound to `userNotesText`) when `structuredNote` is nil; enhanced mode (summary + template badge + sections) when provided
  - Enhanced mode renders items with `.user`-sourced first (including legacy nil), `.transcript`-sourced after, within each section
  - Phase-aware placeholder text supplied by caller via `placeholderTitle` / `placeholderSubtitle` params
- `SettingsView`
  - API key: SecureField with show/hide toggle, save/remove buttons
  - Model picker: dropdown for Whisper model selection
  - Auto-detect audio sources: toggle for `AudioSourceMonitor.isEnabled`
  - About section: version, cost estimate
- `MenuBarView`
  - `MenuBarExtra` with waveform icon
  - "Open Seminarly" button with Cmd+O shortcut
  - "Quit" button with Cmd+Q shortcut

## Concurrency Model

- **Main actor**: all `ObservableObject` classes (`AudioCaptureManager`, `TranscriptionEngine`, `NeuralDiarizationEngine`, `NoteStructuringService`), all SwiftUI views
- **Real-time audio thread**: `AudioDeviceIOBlock` callback in `ProcessTapManager`, `AVAudioEngine` tap callback in `MicrophoneCaptureManager`
- **Bridge**: `AudioBufferAccumulator` (`NSLock`) sits between audio threads and main actor
- **Background tasks**: `TranscriptionEngine.transcriptionTask` (async WhisperKit calls), `NeuralDiarizationEngine` FluidAudio processing
- **Network**: `ClaudeAPIClient` is `Sendable`, `URLSession.data(for:)` runs on cooperative pool
- **Key rule**: audio callbacks never touch `@MainActor` state directly — they go through the lock-based accumulator

## Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ Real-time audio thread                                          │
│                                                                 │
│  ProcessTapManager ──► AVAudioPCMBuffer ──┐                     │
│  (IO proc callback)    (48kHz stereo)     │                     │
│                                           ▼                     │
│                                   AudioBufferAccumulator        │
│                                   (NSLock, off main actor)      │
│                                           │                     │
│  MicrophoneCaptureManager ──► AVAudioPCMBuffer ──┘              │
│  (AVAudioEngine tap)          (device rate)                     │
│                                                                 │
│  Inside accumulator:                                            │
│    AudioFormatConverter: source → 16kHz mono Float32            │
│    Appends to [Float] buffer                                    │
│    Calls onAudioSamples callback                                │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼ (callback, dispatched to main)
┌─────────────────────────────────────────────────────────────────┐
│ @MainActor                                                      │
│                                                                 │
│  TranscriptionEngine                                            │
│    appendAudio() ── accumulates until 30s ──► processAudio()    │
│    Task { whisperKit.transcribe(audioArray:) }                  │
│    Output: [TranscriptSegment] with timestamps                  │
│                                                                 │
│  NeuralDiarizationEngine (FluidAudio)                           │
│    diarize(segments:, systemSamples:, micSamples:)              │
│    Neural speaker embeddings + time-overlap assignment          │
│    Mic energy ratio → "You" labeling                            │
│    Output: [TranscriptSegment] with speaker labels + confidence │
│                                                                 │
│  NoteStructuringService                                         │
│    Path A: structureTranscript(text, template)                  │
│      PromptTemplates.structureNotes() → JSON schema per template│
│    Path B: enhanceNotes(userNotes, transcript, template)        │
│      PromptTemplates.enhanceWithUserNotes() → source-attributed │
│    ClaudeAPIClient.sendMessage/sendEnhancementMessage()         │
│    DynamicCodingKey JSON decode → StructuredNote                │
│                                                                 │
│  SwiftData ModelContext                                          │
│    Insert Meeting + Transcript + StructuredNote                 │
│    modelContext.save()                                           │
└─────────────────────────────────────────────────────────────────┘
```

## Buffer Sizes & Timing

- Audio IO callback: ~512-1024 frames per call (~10-20ms at 48kHz)
- Format conversion: per-callback, produces ~170-340 samples at 16kHz
- Transcription chunk: 30 seconds = 480,000 samples at 16kHz
- WhisperKit large-v3 inference: ~5-15 seconds per 30-second chunk on M1/M2
- Neural diarization (FluidAudio): ~15 seconds per full meeting
- Claude API call: ~3-10 seconds per meeting transcript
