# Seminarly — Project Guide

The open-source core of **Seminarly**, a local-first macOS app (Swift 6 / SwiftUI) that records meeting audio, transcribes it on-device with WhisperKit, identifies speakers with FluidAudio neural diarization, and generates structured notes via the user's chosen LLM provider (Claude, OpenAI, Gemini, and others). Licensed under **AGPL-3.0**.

This repository is the **source of truth** for the app, CLI, and skill — develop them here.

## Build & Run

```bash
xcodegen generate            # regenerate Seminarly.xcodeproj from project.yml
xcodebuild -project Seminarly.xcodeproj -scheme Seminarly -destination 'platform=macOS' build
open Seminarly.xcodeproj      # or open in Xcode
```

## Test (run before committing)

```bash
xcodegen generate && xcodebuild test -project Seminarly.xcodeproj -scheme SeminarlyTests -destination 'platform=macOS'
```

300+ unit tests live in `Tests/`. CI also runs on every push/PR.

## Conventions

- **Never edit `Seminarly.xcodeproj` directly** — edit `project.yml`, then run `xcodegen generate`.
- **Swift 6 strict concurrency** — use `@MainActor`, `Sendable`, and locks for `@unchecked Sendable`.
- Sources live in `Sources/`; CLI in `CLI/` + `Sources/CLI/`; tests in `Tests/`; the agent skill in `.agents/skills/`.
- The bundle identifier, logger subsystem, and Keychain service all use the `ai.seminarly` prefix — don't hardcode another.
- API keys are stored in the macOS Keychain — never in code or config files.

## Architecture (high level)

Audio capture (Core Audio taps + mic) → WhisperKit transcription (30s streaming chunks) → FluidAudio neural diarization → note structuring via a pluggable `LLMProvider` (Anthropic / OpenAI-compatible / Gemini) → SwiftData storage. See [`docs/`](docs/) for full architecture, setup, and testing notes.

## Scope — keep this repo a clean AGPL core

Do **not** add to this repository:

- secrets, API keys, or tokens of any kind;
- marketing-site, deployment, or back-office code;
- proprietary or closed-source features — this repo is AGPL-3.0.

Anything in those categories belongs outside this open-source repo.
