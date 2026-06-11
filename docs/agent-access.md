# Coding Agent Integration

How `seminarly-cli` and the bundled Agent Skill let coding agents (Claude Code, Codex CLI, Cursor, Gemini CLI, and any other tool that can shell out) read the user's Seminarly session data.

## Why a CLI + Skill, not an MCP server

MCP earns its complexity when there is a remote service, shared cross-call state, or many MCP-capable clients to support. None of those apply to Seminarly: data is local, every read is independent, and the consumers are coding agents that already have a Bash tool.

A small Swift CLI plus a Skill file is much simpler. It is read-only by construction, costs ~150ms per invocation (negligible for occasional queries), and stays portable — any agent that can run a shell command can use it.

## Architecture

```
Coding agent (Claude Code, Codex, Cursor, …)
    │
    │  reads SKILL.md to know when/how to invoke
    │
    ▼
./Tools/seminarly-cli   <subcommand>   <args>
    │
    │  opens SwiftData store read-only (allowsSave: false, cloudKitDatabase: .none)
    │
    ▼
~/Library/Application Support/Seminarly/default.store
```

The CLI uses the same `MeetingMarkdownRenderer` as the in-app Export → Markdown / Copy to Clipboard buttons, so output stays consistent across surfaces.

## Component layout

| Path | Purpose |
|---|---|
| `CLI/SeminarlyCLI.swift` | `@main` entry; declares subcommands. |
| `CLI/Commands/{List,Get,Search,Path}Command.swift` | ArgumentParser command structs. Thin wrappers over the logic in `Sources/CLI/`. |
| `Sources/CLI/SessionFormatter.swift` | JSON / table / search formatters. Lives in `Sources/` so SeminarlyTests can hit it via `@testable import Seminarly`. |
| `Sources/CLI/SessionLookup.swift` | Read-only `ModelContainer` open + short ID hash + by-id lookup. |
| `Sources/NoteStructuring/MeetingMarkdownRenderer.swift` | Markdown renderer — shared with the in-app export. |
| `Tools/seminarly-cli` | Built binary (gitignored). Produced by `scripts/build-cli.sh`. |
| `scripts/build-cli.sh` | Builds the binary and copies it into `Tools/`. |
| `.agents/skills/seminarly-cli/SKILL.md` | Canonical Agent Skill (open standard format). |
| `.claude/skills/seminarly-cli` | Symlink to the canonical location for tools that look here. |
| `Sources/Utilities/SeminarlyCLIInstaller.swift` | Bundle-aware install/uninstall (symlinks the embedded binary + skill; isolated PATH opt-in). Drives the Settings section + empty-state offer. |

## Cross-tool skill discovery

Different coding agents look in different directories for skills:

| Tool | Default skill path |
|---|---|
| Claude Code | `.claude/skills/<name>/SKILL.md` |
| Codex CLI, Gemini CLI, Junie, Goose, Cursor (skills mode) | `.agents/skills/<name>/SKILL.md` |

We canonicalize the file at `.agents/skills/seminarly-cli/SKILL.md` and ship a checked-in symlink at `.claude/skills/seminarly-cli`. One source of truth, two discoverable paths, no duplication.

The SKILL.md frontmatter only uses fields that are common to every tool (`name`, `description`) so the same file works without per-tool branching.

## Building the CLI

```bash
./scripts/build-cli.sh
```

This runs `xcodegen generate`, builds the `seminarly-cli` scheme in Release configuration, and copies the resulting binary to `Tools/seminarly-cli`. The script is idempotent.

The binary is excluded from version control via `.gitignore`. Contributors run the script after cloning.

## User-level install (use from any directory)

`scripts/install-global.sh` wires the CLI and the skill into a user's machine so coding agents pick them up outside the Seminarly repo:

- Symlinks `~/.agents/skills/seminarly-cli/` → `$REPO/.agents/skills/seminarly-cli/` — the canonical user-level skill path read by Codex CLI, Gemini CLI, Kiro, Antigravity, etc.
- Symlinks `~/.claude/skills/seminarly-cli` → `~/.agents/skills/seminarly-cli` for Claude Code (which still defaults to `~/.claude/skills/`). Skipped if Claude Code isn't installed.
- Symlinks `~/.local/bin/seminarly-cli` → `$REPO/Tools/seminarly-cli` so the bare `seminarly-cli` referenced by `SKILL.md` resolves via `$PATH`.
- Optionally appends `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` (skip with `--no-path-edit`).

Flags: `--uninstall`, `--no-path-edit`, `--dry-run`. Idempotent; no `sudo`.

## In-app install (for DMG users, no repo)

`install-global.sh` is the **from-source** path: it symlinks the repo's `Tools/seminarly-cli`. A user who installs the notarized DMG has no repo, so the app does the equivalent itself.

The app **bundles** the CLI and skill (see `project.yml`):

- `Seminarly.app/Contents/Helpers/seminarly-cli` — the same self-contained binary, code-signed + notarized as part of the app (it links only system frameworks + the Swift runtime, so it runs identically outside the bundle).
- `Seminarly.app/Contents/Resources/seminarly-cli/SKILL.md` — the embedded skill folder.

`Sources/Utilities/SeminarlyCLIInstaller.swift` is the bundle-aware port of `install-global.sh`. Install **symlinks** (never copies) the bundled binary onto the user's PATH-adjacent dirs, so the CLI auto-tracks every app update and always matches the SwiftData schema it reads:

- `~/.local/bin/seminarly-cli` → `…/Seminarly.app/Contents/Helpers/seminarly-cli`
- `~/.agents/skills/seminarly-cli` → `…/Seminarly.app/Contents/Resources/seminarly-cli`
- `~/.claude/skills/seminarly-cli` → `~/.agents/skills/seminarly-cli` (only if `~/.claude` exists)

Install state is just **installed / not-installed** — "installed" means our `~/.local/bin` symlink exists and resolves into an app bundle. No version compare.

**The PATH edit is kept separate.** Install only creates the clean, reversible symlinks; it never touches the shell. Adding `~/.local/bin` to `PATH` is a distinct opt-in surfaced only when needed (`addLocalBinToPath()` appends one idempotent line to `~/.zshrc`).

Two UI surfaces drive it:

- **Settings → Seminarly CLI and Skills** — the durable home: Install / Uninstall, a "what this touches" disclosure, and the isolated PATH opt-in.
- **Empty-state offer** (`ContentView`, under *Start Recording*) — a quiet secondary button shown only when the CLI isn't installed **and** a coding-agent dir (`~/.claude`, `~/.codex`, `~/.cursor`, `~/.gemini`, `~/.agents`) exists. One click installs; it self-hides once installed.

Logic is unit-tested in `Tests/SeminarlyCLIInstallerTests.swift` (injectable `home` / `fileManager` / `environment`).

## CLI surface

| Command | Default output | Notes |
|---|---|---|
| `list` | JSON array of `{id, title, date, duration_seconds, duration_formatted, app_source, has_user_notes, has_enhanced_notes, has_transcript}` | `--since`, `--until`, `--query`, `--limit`, `--table`. |
| `get <id\|latest>` | Markdown rendered with `MeetingMarkdownRenderer.agentDefault` | `--include user-notes,enhanced-notes,transcript` (any subset), `--no-source-tags`, `--format md\|json`. |
| `search <query>` | JSON array of `{id, title, date, location, snippet}` | `--in all\|title\|notes\|transcript`, `--limit`. |
| `path` | Plain text | Prints `DatabaseStore.storeURL.path`. |

### Stable JSON shapes

- Top-level keys are snake_case (`has_user_notes`, `duration_seconds`) so agents don't need to handle two casing conventions.
- Dates are ISO-8601 with `Z` (e.g. `2026-05-16T14:30:00Z`).
- IDs are 12 hex chars derived from `SHA256(date.timeIntervalSince1970 + "|" + title)`. Stable across CLI invocations as long as the user hasn't renamed the session.

## Data distinguishing strategy

Three data types share one rendered Markdown doc. They are distinguished at two levels:

**Section level** — separate `##` headings:
- `## User Notes` — verbatim text the user typed
- `## Summary` + `## <Section Name>` — AI-enhanced output
- `## Transcript` — raw diarized speech

**Item level** (only inside enhanced notes) — bullets carry `[user]` / `[transcript]` source tags so agents can tell which idea originated where:

```markdown
- [user] Schedule loop with candidate
- [transcript] Send offer letter by Friday (12:30)
```

Tags are on by default in CLI output (`MeetingMarkdownRenderer.Options.agentDefault`). The in-app Export button hides them (`.inAppExport`) to preserve the existing visual output.

## Extending the CLI

To add a new subcommand:

1. Drop a new `XxxCommand.swift` in `CLI/Commands/`.
2. Conform to `AsyncParsableCommand`. Reuse `SessionLookup.openReadOnlyContainer()` for store access.
3. If the command emits formatted output, add the format function to `Sources/CLI/SessionFormatter.swift` and unit-test it from `Tests/SessionFormatterTests.swift`.
4. Register the command in `SeminarlyCLI.configuration.subcommands` in `CLI/SeminarlyCLI.swift`.

Avoid pulling in WhisperKit / FluidAudio / SwiftUI — the CLI target's source list is intentionally minimal (model + persistence + renderer). Reach for `ModelContext` directly and keep dependencies tight.

## Tests

- `Tests/MeetingMarkdownRendererTests.swift` — renderer behavior (23 cases): user notes, source tags, nested children, transcript fallbacks, in-app vs agent default output.
- `Tests/SessionFormatterTests.swift` — CLI logic (20 cases): JSON shapes, ID stability, search across fields, read-only container open against a temp on-disk store.

CLI commands themselves are intentionally thin — the testable logic lives in `Sources/CLI/`. If you need to exercise a full command line, build the binary and shell out from a test.

## Read-only guarantee

Every commit must keep these invariants:

- `SessionLookup.openReadOnlyContainer()` always passes `allowsSave: false` and `cloudKitDatabase: .none`.
- Commands never call `ModelContext.save()` or assign to a `@Model` property.
- The CLI makes no network calls. There is no LLM / Anthropic / OpenAI integration in this target.

If a future change needs to write, it doesn't belong in `seminarly-cli` — open the store from the Seminarly app target instead.
