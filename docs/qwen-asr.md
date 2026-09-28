# Qwen 0.6B mixed-quantization experiment

Select **Settings → Transcription Model → Qwen 0.6B** on Apple Silicon.
Whisper remains the default and existing preferences are preserved. Both engines
share capture, model-switch lifecycle, transcript storage, and FluidAudio speaker
attribution. Changes requested during a recording wait until saving completes;
a failed switch restores the previous working model.

The optional model is `moona3k/mlx-qwen3-asr-0.6b-4bit`, pinned to revision
`4c59c533f95c84afb796655e814709034f826f04`. It uses a 4-bit text decoder,
8-bit audio encoder, group size 64, and FP16 floating tensors. Its six required
files total 542,094,393 bytes (~542 MB decimal), including tokenizer inputs. Loading also generates a ~4.7 MB tokenizer cache.
They are downloaded on selection, never bundled. File lengths and SHA-256
hashes are checked before use. A complete cached installation loads without a
network request. Cache location:

`~/Library/Application Support/ai.seminarly/Models/Qwen3-ASR-0.6B/<revision>/`

`Packages/QwenASR` contains a small MIT-licensed upstream model/DSP subset and
our mixed-precision loader. It uses pinned MLX Swift dependencies and the same
Swift tokenizer package already used by WhisperKit. It does not bundle Python,
a server, other ASR models, TTS, or a forced aligner. See that package's README
for provenance and local adaptations. All MLX model access is serialized in an
actor, with cancellation checks between generation steps.

## Current limitations

- Qwen requires Apple Silicon; Whisper remains available on Intel.
- Qwen has no native word timestamps. This experiment transcribes contiguous
  audio intervals up to eight seconds, preferring a low-energy boundary in the
  last two seconds. Segment times are approximate audio bounds. Speaker
  attribution still works on these bounds, but multiple speakers inside one
  interval can receive a single label. This is not yet a replacement for
  Whisper's finer segment alignment in rapid conversation.
- No extra forced-aligner model is downloaded. Accurate alignment or
  retranscription on diarized turns should be evaluated before making Qwen the
  default for multi-speaker meetings.
- Auto-detect is recommended for code-switching. Norwegian requires Whisper.
- A model switch temporarily retains the previous model to allow rollback;
  only the selected backend remains owned after a successful switch.
- Public English smoke tests establish that the model runs, not multilingual
  meeting accuracy. Evaluate Mandarin, Cantonese, English, code-switching,
  proper nouns, silence, and overlapping speech before changing the default.

## Validation

Build with `./script/build_and_run.sh --build-only`. Run the regular test suite:

```sh
xcodegen generate
xcodebuild test -project Seminarly.xcodeproj -scheme SeminarlyTests \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/DerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates
```

The opt-in real inference test requires already downloaded, pinned model files
and a local audio fixture. It never downloads models by itself:

```sh
TEST_RUNNER_SEMINARLY_QWEN_SMOKE_MODEL=/absolute/path/to/model \
TEST_RUNNER_SEMINARLY_QWEN_SMOKE_AUDIO=/absolute/path/to/audio.wav \
xcodebuild test -project Seminarly.xcodeproj -scheme SeminarlyTests \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/DerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:SeminarlyTests/QwenASRTests/testLocalMixedQuantizationInference
```

The test prints `QWEN_SMOKE` lines with load/decode durations and transcript.
For the engine-level silence/timeline test, also set
`TEST_RUNNER_SEMINARLY_QWEN_SMOKE_ENGINE=1` and install the pinned model files
in the app cache first. That test verifies the entire load/transcribe/finalize
path and checks that 30 seconds of silence remain in the audio timeline.

Missing fixture variables produce an explicit skip, never a claimed inference pass.

## Initial local results (2026-09-26)

Debug build, Apple Silicon, unmeasured background system load. Public fixtures
only; these are functional checks, not WER/CER benchmarks or release performance:

| Fixture | Audio | Decode | Output language |
| --- | ---: | ---: | --- |
| mlx-audio-swift conversational_a.wav | 13.26 s | 4.75 s (cold Metal compilation) | English |
| mlx-audio-swift conversational_fr.wav | 6.95 s | 0.96 s | French |
| QwenLM/Qwen3-ASR official asr_zh.wav | 4.20 s | 0.38 s | Chinese |

Mandarin output: `甚至出现交易几乎停滞的情况。`
The same Mandarin fixture through TranscriptionEngine after 30 seconds of
silence starts at 30.0 s, with language code `zh`.

Sources: [Swift fixtures](https://github.com/Blaizzy/mlx-audio-swift/tree/01dec7c9bdce3088a6b6b7ab9f2e403458195efb/Tests/media),
[official Mandarin fixture](https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-ASR-Repo/asr_zh.wav).


Validation: 501 XCTest cases passed with both opt-in Mandarin checks enabled.
Apple Silicon and Intel debug builds succeeded; Intel execution was not tested
on physical Intel hardware. The Qwen option is disabled in Intel builds.

## Local test app

Run `./scripts/package-qwen-test.sh` on Apple Silicon to create a release-optimized,
ad-hoc-signed **Seminarly Qwen Test.app** and DMG under `build/qwen-test.*/`.
This is a local test package, not a notarized public release. The local ad-hoc
configuration disables hardened runtime because it has no signing Team ID for
framework validation; the production Release configuration retains it.

The `QwenTest` configuration has its own bundle ID (`ai.seminarly.Seminarly.QwenTest`),
preferences, database, backups and recordings in
`~/Library/Application Support/Seminarly Qwen Test/`. It does not import the legacy
production database or install production updates. Its embedded CLI uses that same
test database. Qwen is selected by default; Whisper is still selectable in Settings.
Downloaded model weights and existing AI account credentials/runtime are shared
with the regular app, so models do not need to be downloaded twice.

The optimized `QwenTest` configuration passed 502 tests on 2026-09-26, including
profile isolation, real Mandarin inference and the engine silence/timeline test.
The 4.20-second Mandarin fixture decoded in 0.24 seconds in this local run.

## Retain audio for repeatable comparisons

Enable **Save audio locally** before starting a recording (also available in
Settings → Local Audio). The preference is off by default and is captured at
recording start; changing it during capture affects the next session.

Stopping the recording writes its exact ASR input as a 16 kHz mono Float32 WAV,
using macOS AVFoundation with no new dependency. This is the capture mix, so it
includes the microphone when enabled. It costs about 230 MB/hour (173 MB for
45 minutes). Only one mixed track is retained; speaker embeddings remain the
basis for re-clustering. This is save-on-stop, not continuous crash recovery.

Click **Saved Audio** after recording to reveal the WAV, or open the saved session
and choose **Export → Export Audio (WAV)… / Show Audio in Finder**. Audio stays
in the app's existing `Audio` directory. Deleting the session or its voice data
also removes the internal WAV; separately exported copies are independent.
Previous sessions without saved audio cannot be recovered from their transcripts.
An audio write failure is surfaced and does not abort transcription saving.

`RecordingAudioStoreTests` verifies lossless sample round-tripping across write
boundaries, WAV format, failed/empty writes, persistent references and migration
of a supplied old-store copy. `RecordingSessionTests` covers retention policy and
save failures. Test hosts use a temporary database profile rather than the
installed app's recordings.

Validation on 2026-09-28: all 523 tests passed in the optimized QwenTest
configuration, including real Qwen inference and migration of a copy of the
previous test app database. The branch includes upstream v0.1.15 (`543a62b`).


## Same-audio diagnosis (2026-09-28)

A Mandarin podcast with embedded English names exposed two porting errors:

- The frontend retained the final centered STFT frame (3001 rather than 3000
  frames for 30 seconds). It is now removed before normalization.
- MLX `/` promoted integer frame counts to floating point. The valid encoder
  length now uses integer floor division, preventing padded tail tokens from
  entering the prompt and encoder output.

Hann and Slaney coefficients now match the reference's Float64 construction
followed by a Float32 cast. Synthetic reference fixtures cover frame boundaries,
valid token counts, coefficient values and log-mel values without downloading
weights or including podcast audio in the repository.

Comparison used the same pinned mixed weights, exact audio samples and chunk
boundaries, greedy decoding, no language/context hints, and `mlx-qwen3-asr 0.4.3`.
The Swift package version is 0.31.3 but its bundled C++ MLX version is **0.31.1**;
Python must use MLX 0.31.1 for this comparison. Of 20 selected groups (10 windows
in each chunking mode), 18 matched verbatim, or 56 of 58 individual segments.
The remaining differences were punctuation and the number of repeated words
in one short segment. All 10 long-window outputs matched. Evernote substitution
and the observed long-window repetition were corrected; the short-window
repetition also occurs in Python on MLX 0.31.1. Founder and Bending Spoons errors
remain in both runtimes. This is implementation comparison, not WER/CER accuracy.

The same investigation corrected WhisperKit 0.18.0 options: nil language now
explicitly enables language detection, and the precomputed prompt cache is
disabled. Normal autoregressive KV caching and confidence/silence thresholds
remain enabled. All 12 selected Whisper windows produced text after correction,
including the five previously empty windows. The complete 90-window corpus has
not been rerun with the final changes, and this does not guarantee completeness
or eliminate all silence-related hallucinations.

These fixes do not change the eight-second Qwen chunk limit, download size,
or dependencies. Short ambiguous speech, English proper nouns and speaker
alignment still need evaluation before changing the default engine.

Final regression: optimized QwenTest suite completed 528 cases with 0 failures.
Two opt-in inference cases and one old-database migration case were skipped
because their fixture environment variables were unset. The separate podcast replay above used
real local model weights. The installed test app was not repackaged in this run.
