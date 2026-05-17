# Plan: Language-Aware Diarization for Chinese Audio

**Issues:** [#12](https://github.com/daniellee-ux/Seminarly-AI/issues/12) (PLDA pipeline fails for non-English) | [#16](https://github.com/daniellee-ux/Seminarly-AI/issues/16) (evaluate callhome-zho model)

---

## Problem

FluidAudio's PLDA model was trained on English speakers (VoxCeleb). For Chinese/Mandarin audio:

1. **PLDA compression (256D → 128D) destroys speaker-discriminative dimensions** — the dimensions that distinguish Chinese voices are different from English (tonal features, different phoneme distributions)
2. **AHC clustering collapses to 1 cluster** regardless of threshold
3. **VBx refinement has no effect** since AHC already failed
4. The `minSpeakers=2` safety net triggers K-Means on **PLDA-compressed 128D** features — suboptimal but somewhat functional

**Key finding from issue #12:** K-Means on **raw 256D WeSpeaker embeddings** (before PLDA compression) correctly separates Chinese speakers with 20.5% and 27.8% minority ratios. The raw embeddings have the speaker information; PLDA just destroys it.

**Additional complication:** WhisperKit's large-v3 model sometimes transcribes Chinese speech as English text, so `result.language` from transcription may report `"en"` even for Chinese audio. We cannot rely on the transcription language tag alone.

## Why Not callhome-zho (Issue #16)?

The `speaker-segmentation-fine-tuned-callhome-zho` model provides **segmentation only** (frame-level speech activity detection). FluidAudio's segmentation already works correctly for Chinese — it finds speech regions just fine. Only the **PLDA → clustering** stage fails.

Implementing callhome-zho would require:
- PyTorch → ONNX → CoreML conversion pipeline (no existing CoreML version)
- Adding CoreML as a new framework dependency (not currently used)
- Building a custom segmentation inference pipeline
- Significant testing for numerical parity

**This is overkill when raw-embedding K-Means already solves the problem.**

This plan creates the language-detection infrastructure that a future callhome-zho integration could plug into if needed.

## Solution: Language-Aware K-Means Re-clustering

After FluidAudio runs its full pipeline, detect if the audio is Chinese. If so, **discard FluidAudio's PLDA-based cluster assignments** and re-cluster using K-Means cosine on the raw 256D embeddings that FluidAudio already extracted.

```
CURRENT (all languages):
  FluidAudio.process()
    → Segmentation → Embedding (256D) → PLDA (128D) → AHC → VBx → cluster assignments
    → assignSpeakers()

PROPOSED (Chinese detected):
  FluidAudio.process()
    → Segmentation → Embedding (256D) → [PLDA → AHC → VBx → IGNORED]
    → K-Means cosine on raw 256D embeddings → new cluster assignments
    → assignSpeakers()
```

FluidAudio still runs fully — we use its segmentation and embeddings, just not its clustering decisions.

---

## Implementation Details

### Step 1: Detect Language via `whisperKit.detectLanguage()` (Acoustic Detection)

**File:** `Sources/Transcription/TranscriptionEngine.swift`

Use WhisperKit's dedicated `detectLanguage(audioArray:)` method instead of relying on `result.language` from transcription. This analyzes the first 30 seconds of audio acoustics specifically for language identification — independent of what text the transcription produces. Even if the model transcribes Chinese speech as English text, `detectLanguage()` should correctly identify the spoken language as Chinese.

**Changes:**
- Add `@Published var detectedLanguage: String?` property
- Add `detectLanguage(_ audio: [Float])` method that calls `whisperKit.detectLanguage(audioArray:)` and stores the result with probabilities
- Call it on the first audio chunk in `appendAudio()` or `processAccumulatedAudio()`
- Also capture `result.language` from transcription as a secondary signal
- Reset in `reset()`

```swift
// New properties
@Published var detectedLanguage: String?
private var hasDetectedLanguage = false

// Dedicated language detection (runs once on first chunk)
func detectLanguage(_ audio: [Float]) async {
    guard !hasDetectedLanguage, let whisperKit else { return }
    hasDetectedLanguage = true
    do {
        let (language, probabilities) = try await whisperKit.detectLanguage(audioArray: audio)
        detectedLanguage = language
        // Log top 3 language probabilities for debugging
        let top3 = probabilities.sorted { $0.value > $1.value }.prefix(3)
        logger.info("Language detection: \(language) — \(top3.map { "\($0.key): \(String(format: "%.1f%%", $0.value * 100))" }.joined(separator: ", "))")
    } catch {
        logger.warning("Language detection failed: \(error)")
    }
}

// In reset():
detectedLanguage = nil
hasDetectedLanguage = false
```

**Why `detectLanguage()` over `result.language`:** The transcription model may misidentify Chinese as English when it produces English text output. `detectLanguage()` is a separate acoustic analysis that examines audio features, not text output.

### Step 2: Add Language-Aware Re-clustering to NeuralDiarizationEngine

**File:** `Sources/Diarization/NeuralDiarizationEngine.swift`

**Changes:**

**a) Add `detectedLanguage` parameter to `diarize()`:**
```swift
func diarize(
    segments: [TranscriptSegment],
    systemSamples: [Float],
    micSamples: [Float]?,
    sampleRate: Double = 16000,
    detectedLanguage: String? = nil  // NEW
) async -> (segments: [TranscriptSegment], speakerEmbeddings: [SpeakerEmbedding])
```

**b) After FluidAudio returns (after line 100), add re-clustering branch:**
```swift
let result = try await diarizer.process(audio: allSamples)
var speakerSegments = result.segments

// If Chinese detected, re-cluster on raw 256D embeddings (bypasses PLDA)
if Self.isCJKLanguage(detectedLanguage) {
    logger.info("Chinese detected — re-clustering on raw 256D embeddings (bypassing PLDA)")
    speakerSegments = reclusterForChinese(speakerSegments: speakerSegments)
}
```

**c) Add `reclusterForChinese()` private helper:**
- Extracts 256D embeddings from `speakerSegments` (via `seg.embedding`)
- Runs `SpeakerClusterer.kMeansCosine(embeddings:k:2)` — k=2 is the common case (2 speakers); user can adjust post-recording via existing rediarization UI
- Rebuilds `TimedSpeakerSegment` array with new cluster-based `speakerId` values
- Preserves all timing and embedding data

**d) Add `isCJKLanguage()` static helper:**
```swift
private static func isCJKLanguage(_ language: String?) -> Bool {
    guard let lang = language?.lowercased() else { return false }
    return lang.hasPrefix("zh") || lang == "yue"  // Mandarin + Cantonese
}
```

Starting with Chinese only. Japanese/Korean could be added later if PLDA underperforms for them too.

### Step 3: Thread Language Through RecordingView

**File:** `Sources/Views/RecordingView.swift`

**a) Trigger language detection on first audio chunk:**

In `stopRecording()` (or during recording when first chunk arrives), call `detectLanguage()` on system audio before diarization runs:

```swift
// Before diarization, ensure language is detected
if transcriptionEngine.detectedLanguage == nil {
    await transcriptionEngine.detectLanguage(Array(recording.systemSamples.prefix(16000 * 30)))
}
```

**b) Pass detected language to diarize():**
```swift
let diarizeResult = await diarizationEngine.diarize(
    segments: segments,
    systemSamples: recording.systemSamples,
    micSamples: recording.micSamples,
    detectedLanguage: transcriptionEngine.detectedLanguage
)
```

### Step 4: Persist Detected Language

**File:** `Sources/Storage/MeetingModel.swift`

- Add `var detectedLanguage: String?` to the `Meeting` model
- SwiftData handles this automatically as a lightweight migration (optional property with nil default)
- Enables: displaying a language badge in the UI, using language when rediarizing from saved embeddings

### Step 5: Add Tests

**File:** `Tests/NeuralDiarizationEngineTests.swift` (new) or existing test file

Tests for:
1. `isCJKLanguage()` — `"zh"` → true, `"zh-Hans"` → true, `"yue"` → true, `"en"` → false, `nil` → false
2. `reclusterForChinese()` with synthetic 256D embeddings (two distinct vector clusters) → verifies 2 speaker IDs in output
3. English language does NOT trigger re-clustering (standard pipeline used)

---

## Files Summary

| File | Type | What Changes |
|------|------|-------------|
| `Sources/Transcription/TranscriptionEngine.swift` | Modify | Add `detectLanguage()` using WhisperKit acoustic detection, add `detectedLanguage` property |
| `Sources/Diarization/NeuralDiarizationEngine.swift` | Modify | Add `detectedLanguage` param, `reclusterForChinese()`, `isCJKLanguage()` |
| `Sources/Views/RecordingView.swift` | Modify | Trigger `detectLanguage()`, pass result to `diarize()` |
| `Sources/Storage/MeetingModel.swift` | Modify | Add `detectedLanguage: String?` property |
| `Tests/` | Add/Modify | Language detection + re-clustering tests |

## Existing Code Reused (No Changes Needed)

| Code | Location | Purpose |
|------|----------|---------|
| `SpeakerClusterer.kMeansCosine()` | `SpeakerClusterer.swift:189` | K-Means clustering on arbitrary embeddings |
| `validateSpeakerSplit()` | `NeuralDiarizationEngine.swift:399` | 10% minority threshold, still runs after re-clustering |
| `assignSpeakers()` | `NeuralDiarizationEngine.swift:338` | Time-overlap speaker assignment, works with any segments |
| `rediarizeFromEmbeddings()` | `NeuralDiarizationEngine.swift:247` | Already uses K-Means on 256D — unaffected |

## No New Dependencies

- No new Swift packages
- No CoreML framework
- No `project.yml` changes
- No Python bridge

---

## Verification Plan

1. **Build:** `xcodegen generate && xcodebuild build`
2. **Tests:** `xcodebuild test -scheme SeminarlyTests`
3. **Manual — Chinese audio:**
   - Record a Chinese audio source (podcast, YouTube)
   - Check logs for `"Language detection: zh"` with probabilities
   - Check logs for `"Chinese detected — re-clustering on raw 256D embeddings"`
   - Verify 2+ speakers in output with reasonable minority ratios (>10%)
4. **Manual — Chinese transcribed as English:**
   - Record Chinese audio that WhisperKit transcribes as English
   - Verify `detectLanguage()` still reports `"zh"` (acoustic detection, not text-based)
   - Verify re-clustering still triggers
5. **Regression — English audio:**
   - Record an English source
   - Verify standard FluidAudio pipeline is used (no re-clustering log)
   - Verify speaker separation unchanged

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| `detectLanguage()` also misidentifies Chinese as English | Log probabilities; if zh probability is high but not top-1, consider a threshold (e.g. zh > 20%). Fallback: user can manually trigger rediarization |
| K-Means k=2 wrong for 3+ speaker Chinese meetings | User can adjust via existing rediarization picker in MeetingDetailView |
| `TimedSpeakerSegment` might not have public init for rebuilding | If struct is non-public, create wrapper or use the embedding-based path instead |
| SwiftData migration for new property | Optional `String?` with nil default — automatic lightweight migration |
| `detectLanguage()` adds latency to first chunk | Runs once on first 30s of audio (~100ms on Apple Silicon); negligible vs. transcription time |
