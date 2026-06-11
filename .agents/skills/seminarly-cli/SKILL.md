---
name: seminarly-cli
description: Read the user's Seminarly sessions (user notes, AI-enhanced notes, transcripts) by shelling out to a local read-only CLI. Use when the user asks about past sessions, recordings, meetings, transcripts, or "what did I discuss/say in <session>".
---

# Seminarly CLI

Seminarly is a local macOS app that records sessions (audio + user notes) and generates AI-enhanced notes. The user's data lives in a single SwiftData SQLite store on their machine. This skill exposes a small read-only CLI — `seminarly-cli` — that prints session data as Markdown or JSON.

## When to use

Invoke this CLI whenever the user references past Seminarly sessions: "what did I talk about with Alice?", "summarize yesterday's lecture", "find any session where we discussed Q3 OKRs", "show me my notes from <topic>". You do **not** need to ask permission — the CLI is read-only by construction.

Do not use this skill for:

- Editing or generating new sessions (CLI is read-only)
- App code questions about Seminarly itself (use file reading instead)
- Anything that isn't reading the user's session data

## Quick start

```
seminarly-cli list                              # JSON, newest first
seminarly-cli list --table --limit 5            # human-readable
seminarly-cli get latest                        # Markdown for most recent session
seminarly-cli get <id>                          # Markdown for specific session
seminarly-cli get <id> --format json            # JSON envelope { id, title, date, markdown, ... }
seminarly-cli search "OKR"                      # JSON matches with snippets
seminarly-cli path                              # store location (debug)
```

If `seminarly-cli` is not on `$PATH`:

- **If the user has the Seminarly app** (the common case — this skill ships inside it): tell them to open **Seminarly → Settings → Seminarly CLI and Skills**, where **Install** sets up the command + skill and the **Add to PATH** option exposes it. The bundled binary already lives at `Seminarly.app/Contents/Helpers/seminarly-cli`, so a full path works immediately too.
- **If the user has the source repo**: `./scripts/install-global.sh` (builds the binary, sets up the skill, adds `~/.local/bin` to PATH), or `./scripts/build-cli.sh && ./Tools/seminarly-cli ...` for a one-off in-repo run.

## Three data types

Each session carries three distinct pieces of content. Markdown output flags them so you can tell them apart:

| Type | Where it lives | Source |
|---|---|---|
| **User notes** | `## User Notes` section | What the user typed during recording (verbatim). |
| **Enhanced notes** | `## Summary` + `## <Section>` sections | AI-generated from transcript + user notes. Items are tagged `[user]` or `[transcript]` so you can see what came from where. |
| **Transcript** | `## Transcript` section | Raw timestamped diarized speech (`[mm:ss] Speaker N: ...`). |

The `## Summary` heading sits at the same level as user-typed sections — it is **AI-generated**, not user-typed. Lines under `## User Notes` are the only thing the user explicitly wrote.

## Picking flags

| User intent | Command |
|---|---|
| "What was discussed?" / quick recap | `get <id>` (default — all three types, with source tags) |
| Just the user's own notes | `get <id> --include user-notes` |
| Just the AI summary, no transcript | `get <id> --include enhanced-notes` |
| Read transcript verbatim | `get <id> --include transcript` |
| Find sessions mentioning a topic | `search "<query>"` |
| Filter by date | `list --since 2026-05-01 --until 2026-05-15` |
| Strip `[user]`/`[transcript]` tags | add `--no-source-tags` |

## Typical workflow

1. Run `list` (or `list --query "alice"`) to get the candidate IDs.
2. Run `get <id>` on the relevant session.
3. Read the Markdown and answer the user's question.

Don't dump raw transcripts unless asked — prefer the enhanced notes or summarize yourself.

## Guarantees

- **Read-only.** The CLI opens the store with `allowsSave: false` and never mutates.
- **Works whether the Seminarly app is open or not.** SQLite WAL allows concurrent readers.
- **No network.** All data is local; the CLI never makes outbound calls.
- **Stable across CLI invocations.** IDs are 12-hex-char hashes of `date + title` — re-run `list` if you suspect a session was renamed since the last call.

## If something goes wrong

- `No session with id '<x>'`: the user probably renamed a session since you last called `list`. Re-run `list` and try again.
- `No sessions found`: the store is empty. Confirm with `seminarly-cli path` that the path exists.
- Binary missing / not found: with the app, **Seminarly → Settings → Seminarly CLI and Skills → Install** (re)creates the link; with the repo, `./scripts/install-global.sh` (one-time setup, requires XcodeGen) or `./scripts/build-cli.sh` for an in-repo-only build.
