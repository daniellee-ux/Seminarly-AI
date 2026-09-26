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
