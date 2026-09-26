# Rediarize speaker-count investigation

- Date: 2026-09-26
- Branch: `codex/investigate-rediarize-speaker-count`
- Source baseline: `f478401`

Scope: investigation, implementation, and regression tests. The findings and line references below describe the original `f478401` baseline; implementation status is recorded here separately.

## Implemented correction

- Both embedding and raw-audio rediarization now apply one **total** speaker budget. Selecting 1 explicitly merges to one identity; missing or malformed evidence otherwise produces an error instead of silently returning the old transcript.
- New recordings diarize microphone and system audio separately, save source-tagged embeddings for both, and support multiple people on one microphone. Microphone audio never automatically names someone You.
- `MeetingSpeakerControls` offers an explicit **Your voice** choice. It renames one identity, without increasing the count. Confirmation is stored separately on transcript turns and survives count changes. When a merged group contains confirmed other speakers, the app does not call the whole group You.
- **Rediarize** remains available even when the selected count matches the original count. **Restore Original** is an independent action. All mutation controls are disabled during processing; cancelled or concurrently edited transcripts cannot be overwritten by a stale result.
- Original evidence is reused when changing counts, including 2 → 1 → 2. Clustering seeds and overlap tie-breaking are deterministic. Text and timestamps remain unchanged.
- For **legacy system-only embeddings**, existing You turns retain a reserved place within the total, rather than appearing on top of it. This is a compatibility fallback for missing evidence, not proof that every local person was correctly identified. The UI explains the limitation and allows the user to confirm or clear the name.
- Source metadata, identity IDs, and explicit user confirmation are optional fields inside the existing Codable blobs. Old data remains decodable, and the SwiftData schema is unchanged.

Primary implementation files: `Sources/Diarization/SpeakerAttribution.swift`, `Sources/Diarization/DiarizationAudio.swift`, `Sources/Diarization/NeuralDiarizationEngine.swift`, and `Sources/Views/MeetingSpeakerControls.swift`.

The two original expected-failure tests are now ordinary passing regressions. The first focused run passed **82 tests**. After adding raw-audio and brief-speech edge cases, the final full suite passed **494 tests**, with **0 expected failures, 0 unexpected failures, and 0 skips** on macOS 15.5 / arm64. The result bundle is `build/rediarize-full-tests-v2.xcresult`. The bundled CLI's `--help` smoke check and `git diff --check` also passed.

Final validation used `xcodebuild test -project Seminarly.xcodeproj -scheme SeminarlyTests -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY='-'`, with derived data in `build/rediarize-investigation`, the existing package cache, automatic package resolution disabled, and package updates skipped. No dependency versions changed.

### Remaining acoustic limits

Source-energy gating prefers the clean system track when the microphone appears to contain attenuated loudspeaker echo. It is a heuristic, not full acoustic echo cancellation, and overlapping speech still needs listening-based validation. Processing both active sources takes two neural passes. Tests inject embeddings to exercise routing, assignment, count limits, and failures without downloading models; they do not measure real-world speaker accuracy or processing latency.

Old recordings without microphone embeddings or retained audio cannot recover microphone voice distinctions that were never saved. Their original transcript is preserved. This change has not reprocessed or modified the reported meeting.

## Finding

Selecting **2** constrains the number of system-audio clusters, while the UI presents a total speaker count. The engine subsequently preserves or adds **You**, without reserving a place for that person. The result can therefore contain **Speaker 1, Speaker 2, You**, exactly as in the reported screenshot.

This is a count-contract mismatch in the application. Reproducing it does not require a FluidAudio model, Chinese audio, or a transcription failure. It also does not establish which real person, if any, was split into multiple labels in the reported recording.

## Code path

| Stage | Current behavior | Source |
| --- | --- | --- |
| Picker and initial value | Counts all transcript speaker labels, including You; minimum initial selection is 2 | `Sources/Views/MeetingDetailView.swift:257` |
| Request | Passes the selected number unchanged to the engine | `Sources/Views/MeetingDetailView.swift:382` |
| Embedding clustering | Passes `numSpeakers` directly as k | `Sources/Diarization/NeuralDiarizationEngine.swift:482` |
| Local speaker | Restores every existing You label after assigning cluster labels | `Sources/Diarization/NeuralDiarizationEngine.swift:520` |
| Display | Lists every distinct label in the resulting transcript, including You | `Sources/Views/MeetingDetailView.swift:327` |
| Original result | Saves the total label count, including You | `Sources/Audio/RecordingSession.swift:326` |

The selected value remains at 2 after processing; no final total-count validation runs. The displayed third label comes from the stored transcript, rather than a separate cached speaker list.

The legacy raw-audio route has the same mismatch: `rediarize()` sets `config.clustering.numSpeakers` to the full requested number, processes system audio, and then calls `labelMicSpeaker()`. See `Sources/Diarization/NeuralDiarizationEngine.swift:396`. This route was inspected in code; the model-backed pipeline was not rerun on the user's recording.

## Why it happens only sometimes

- Without a You label, the embedding path produces at most the requested number of cluster labels.
- With You and transcript turns remaining in every requested cluster, the output can contain the requested number **plus one**.
- If a cluster's only transcript turns are replaced by You, that cluster label disappears and the total may happen to match the requested number.
- Clustering can also produce fewer represented labels when evidence is limited; requesting a count does not guarantee that every cluster appears in the transcript.

The existing `testReclusterPreservesYouLabels` only checks that one label stays You. Its two-turn fixture replaces one entire cluster with You, so it does not expose the extra-label case. The existing two-speaker count test has no You turn.

## Can the same local person become both You and Speaker 1?

Yes, that is possible under the current assignment rules, but the screenshot alone cannot prove that it happened in this session. Speaker 1 and Speaker 2 could instead be a split of the remote person.

The app keeps separate system and microphone buffers, but transcribes their mix (`Sources/Audio/AudioCaptureManager.swift:123`, `Sources/Audio/RecordingSession.swift:121`). Speaker embeddings are extracted from system audio only (`Sources/Diarization/NeuralDiarizationEngine.swift:212`). A transcript segment does not persist its audio-source identity; `TranscriptSegment` stores times, text, a label, and confidence.

`labelMicSpeaker()` does not recognize the local person's voice. It assigns You only when the whole segment's microphone RMS is more than twice the system RMS and **both RMS values are positive** (`Sources/Diarization/NeuralDiarizationEngine.swift:634`). Consequently:

- A local turn mixed with a remote interruption can fail the segment-wide ratio check and keep its assigned system speaker.
- If the system buffer is present but silent for a local turn, `sysEnergy == 0` makes the condition false, even with clear microphone speech.
- Segments beyond the available system buffer are skipped. Fully microphone-only input also exits `diarize()` before microphone assignment because the system sample array is empty (`Sources/Diarization/NeuralDiarizationEngine.swift:207`).
- A segment with no overlapping system embedding defaults to Speaker 1 (`Sources/Diarization/NeuralDiarizationEngine.swift:514`). Only an existing You label overrides this fallback during embedding rediarization.

An already assigned You segment remains You in embedding rediarization. The problem is that not every local turn necessarily received that assignment, and rediarization cannot rediscover missed local turns from system embeddings alone. New recordings persist system embeddings and the original transcript, but the current save pipeline does not save microphone audio or per-turn source evidence (`Sources/Audio/RecordingSession.swift:324`).

Microphone capture by itself is not proof that every sound is the local person's voice: it can also contain loudspeaker echo or another person in the room. A reliable fix needs source and speech evidence, rather than labeling everything audible on the microphone as You.

## Meeting scenarios clarified during the investigation

The user also records in-person meetings with several people sharing one microphone. A general rule mapping microphone audio to You would merge those people and is unsuitable for this product.

| Scenario | Required interpretation |
| --- | --- |
| Online meeting with one confirmed local participant | Microphone speech can support identifying that participant as You, with echo handling; system audio can contain several other participants. |
| In-person meeting with a shared microphone | Diarize the microphone track into multiple speaker identities. Use neutral labels until the user or reliable identity evidence identifies which speaker is You. |
| Hybrid meeting with several people in the room and remote participants | Both microphone and system tracks may contain multiple speakers. Preserve source information and handle echo without assuming one person per track. |

An audio source and a person must be represented separately. You should be the display name of one identified speaker, counted within the requested total. Renaming a speaker to You must not create another identity. Microphone availability, headphone use, or an old heuristic You label alone does not establish that the microphone contains exactly one person.

## Original reproductions and baseline validation

Two tests in `Tests/LanguageAwareDiarizationTests.swift` were added to express the intended **total-count** contract:

- `testRequestedTwoSpeakersIncludesPreservedYou`: a microphone-only You turn plus four system turns from two orthogonal embedding groups; requesting 2 originally yielded 3 labels.
- `testRequestedOneSpeakerDoesNotAddYouOnTop`: the same fixture requested as 1 originally yielded Speaker 1 and You.

Both count assertions initially used strict `XCTExpectFailure` markers. Those markers were removed with the correction. The first test also checks that You is preserved; both check that transcript text remains intact.

Focused test command:

```sh
xcodegen generate
xcodebuild test -project Seminarly.xcodeproj -scheme SeminarlyTests \
  -destination 'platform=macOS' \
  -only-testing:SeminarlyTests/LanguageAwareDiarizationTests \
  -only-testing:SeminarlyTests/SpeakerClustererTests \
  CODE_SIGN_IDENTITY='-'
```

Baseline validation result: **30 tests executed: 28 passed, 2 expected failures, 0 unexpected failures, 0 skipped** on macOS 15.5 / arm64. Both new total-count assertions reproduced the defect before the correction.

The run used the existing package cache, disabled automatic package resolution and updates, and wrote derived data to `build/rediarize-investigation`. Its result bundle is `build/rediarize-investigation-tests.xcresult`. `xcodegen generate` produced no project-file changes, and `git diff --check` passed.

The microphone-assignment findings above come from source inspection. The reported recording's original audio has not been replayed, and no meeting data was rediarized as part of this investigation.

## Recommended correction

1. Define the picker consistently as **total speakers, including You**. Use the same definition for initialization, processing, current labels, and Restore Original.
2. Keep speaker identity separate from source and display name. Only a confirmed single local identity can reserve one slot of the requested total; microphone availability or an existing heuristic You label is insufficient. In-person and hybrid meetings require microphone speaker clustering as well. Apply the total-count policy to both embedding and raw-audio routes.
3. Handle a request for 1 explicitly as one identity. Preserve source evidence separately so a later request can recover local/remote distinctions instead of depending on the last visible label.
4. Improve local-turn assignment independently: account for silent system audio and microphone-only sessions, use speech activity and echo handling, and avoid assigning an entire mixed-speaker transcript segment to one person solely from average energy. Keep neutral labels when identity is unknown and allow a speaker to be identified as You without changing the total count.
5. Persist source-specific speaker evidence, timestamps, confidence, and any confirmed identity mapping for future rediarization, including microphone embeddings for shared-microphone recordings. Existing system-only embeddings cannot conclusively recover missed microphone turns in old recordings.
6. Validate the final labels against the total-count contract. When evidence is missing or processing fails, surface a clear result instead of silently presenting an unchanged transcript as a successful adjustment.

The last point also covers two secondary paths found during inspection: an empty decoded embedding array returns the old segments immediately, and raw-audio rediarization catches errors and returns the old segments. The view currently saves those returned segments without showing an error. Neither path is needed to reproduce the screenshot's 2-plus-You result.
