# Contributing to Seminarly

Thanks for your interest. Bug reports, feature requests, and pull requests are all welcome.

## Setup

```bash
git clone https://github.com/daniellee-ux/Seminarly-AI.git
cd Seminarly-AI
brew install xcodegen
xcodegen generate
open Seminarly.xcodeproj
```

Requires macOS 14.4+ and Xcode 16.3+. See [`README.md`](README.md) for the full requirements and first-launch steps (Whisper model download, API key, permissions).

## Running tests

Before sending a PR, run the test suite:

```bash
xcodegen generate
xcodebuild test \
  -project Seminarly.xcodeproj \
  -scheme SeminarlyTests \
  -destination 'platform=macOS'
```

CI runs the same commands on every push and pull request (see `.github/workflows/test.yml`).

## Branching and commits

- Branch off `master` with a descriptive name: `fix/issue-N-short-summary` or `feature/short-summary`.
- One concern per PR. Smaller PRs get reviewed faster.
- Reference the issue in the PR body (`Fixes #N` if it closes one).

## What needs help

Open issues are tagged in [the tracker](https://github.com/daniellee-ux/Seminarly-AI/issues). Beginner-friendly work is usually documentation, additional LLM providers in `Sources/NoteStructuring/Providers/`, or new note templates.

If you want to propose a larger change, open an issue first to discuss the approach before writing code.

## Code conventions

- Swift 6 strict concurrency — use `@MainActor`, `Sendable`, `@unchecked Sendable` with locks where needed.
- Never edit `Seminarly.xcodeproj` directly — edit `project.yml` and run `xcodegen generate`.
- Add tests for non-trivial changes. See `Tests/` for existing patterns.
- Keep API keys out of code and config — they live in macOS Keychain (one entry per provider).

## License

By contributing, you agree your contributions will be licensed under the [Apache 2.0 License](LICENSE).
