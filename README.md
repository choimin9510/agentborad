[English](README.md) · [한국어](README.ko.md) · [简体中文](README.zh-CN.md)

# AgentBoard

A floating macOS board for following your local Codex conversations, including OpenAI and DeepSeek sessions.

## Features

- One card per conversation, with task purpose, latest request, reported steps and summary.
- All, Running, Needs attention and Completed tabs.
- Unread completion badges, mark-all-read and completion sounds.
- Drag cards vertically to reorder, or horizontally to hide. Hidden cards return when work resumes.
- Rename cards from the ellipsis menu. Expand multiple cards independently.
- Resize and move the board, snap to nearby windows, and collapse it at a screen edge.

**Documentation is available in English, Korean and Simplified Chinese. The current app interface is Korean.**

## Install on another Mac

Requires **macOS 13 or later**, Apple Silicon or Intel, and local Codex CLI sessions.

1. Download the universal ZIP from [Releases](https://github.com/choimin9510/agentborad/releases).
2. Extract the complete folder and double-click `Install.command`.
3. AgentBoard opens after installation. No development tools are needed for the prebuilt package.

The app and helper are ad hoc signed, **not Apple notarized**. If macOS blocks an item you trust, follow the system's Open Anyway flow for that item. See the [installation guide](Resources/Distribution-Install-EN.md) for installation paths, security prompts and removal.

Each Mac reads its own local sessions; conversations are not synchronized between Macs.

## How it works

AgentBoard follows JSONL session logs in `~/.codex/sessions` and `~/.codex-ds/sessions`, plus a custom `CODEX_HOME` when present. File events and a five-second reconciliation pick up appended records. It works with sessions running inside terminals such as cmux and Herdr without reading their screen contents.

A conversation's normal response completion marks the card completed. This **does not mean its build, tests or requested business task succeeded**. Subagent threads and unsupported providers are excluded.

Task steps come from structured reports written by the agent through the installed `agentboard` helper. The app does not infer a plan from arbitrary prose. Without a report, the card shows “계획 미등록” (no registered plan). Installation adds reporting guidance to the supported Codex homes' `AGENTS.md`; newly started sessions receive it. Restarting the board alone does not add a plan to an existing conversation.

Completed cards are shown for 30 days by default. Unfinished cards without a progress report are shown for seven days; reported unfinished tasks have no view age cutoff. All history expands the view of available stored records. Hidden cards remain separate.

## Privacy and limitations

- Local monitoring only: AgentBoard does not send prompts, stop or resume agents, or call model APIs.
- Normalized task data and preferences are stored in `~/Library/Application Support/AgentBoard/agentboard.sqlite3`. Full raw conversations and credentials are not copied into that database.
- Codex session log formats can change. Missing or delayed events can affect status accuracy.
- New completion notifications reflect recorded response completion, not independent verification of the agent's work.
- Uninstall preserves the local database, Codex sessions and authentication.

## Build and verify

Use a Mac with Xcode Command Line Tools and the Swift compiler. The scripts build the SwiftUI/AppKit app, SQLite core and CLI helper. Packaging builds both arm64 and x86_64.

```bash
git clone https://github.com/choimin9510/agentborad.git
cd agentborad
./scripts/build.sh
./scripts/test.sh
./scripts/integration.sh
./scripts/test-install.sh
./scripts/package.sh
./scripts/test-package.sh
```

`build/`, `.build/` and `dist/` are generated and excluded from Git. Tests and integration fixtures use synthetic session data. `./scripts/install.sh` previews installation; add `--yes` to apply it, or `--no-agents` to omit reporting guidance.

## Project layout

- `Sources/AgentBoardApp`: floating board, card interactions and window behavior.
- `Sources/AgentBoardCore`: session ingestion, validation, state reduction and SQLite storage.
- `Sources/agentboard`: structured progress reporting helper.
- `Tests`, `fixtures`: regression checks and synthetic sessions.
- `scripts`, `Resources`: build, installation and distribution assets.

## Current validation status

This initial release is a preview. The core suite currently passes 393 of 395 checks; two checks for unread badges after normal response completion fail. `scripts/test.sh` stops at these failures, so later suites are not covered by that invocation. See release notes for package verification results.
