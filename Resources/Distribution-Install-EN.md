[English](Distribution-Install-EN.md) · [한국어](Distribution-Install-KO.md) · [简体中文](Distribution-Install-ZH-CN.md)

# Installing AgentBoard

Requires macOS 13 or later and local Codex CLI sessions. The universal package supports Apple Silicon and Intel Macs. The current app interface and installer messages are Korean.

## Install

1. Extract the entire release ZIP in Finder.
2. Double-click `Install.command`. The app opens after installation.
3. If macOS blocks a trusted item, use Open Anyway in System Settings → Privacy & Security for that specific item. See [Apple's instructions](https://support.apple.com/en-us/102445).

The app and helper are ad hoc signed, not Apple notarized. Check whether the blocked item is the app, helper or installer. Do not disable macOS security. If double-clicking is unavailable, type `bash` and a space in Terminal, drag `Install.command` into the window, then press Return.

No Xcode, Python or ripgrep is required for the prebuilt package.

- App: `~/Applications/AgentBoard.app`
- Helper: `~/.local/bin/agentboard`
- Installation manifest: `~/.local/share/agentboard/install.json`

## Sessions and reporting

The board monitors local `~/.codex` and `~/.codex-ds` sessions; there is no cross-device synchronization. It does not send messages or stop/resume agents.

Installation adds its reporting block to `~/.codex/AGENTS.md` and an existing `~/.codex-ds/AGENTS.md`, preserving other instructions. New sessions receive the guidance; existing conversations may show no plan until a new report arrives. If you create the separate DeepSeek home later, rerun the installer to add its guidance. Use `bash install.sh --prebuilt --yes --no-agents` to skip guidance changes.

Drag cards vertically to reorder and horizontally to hide. Manual order persists locally; the automatic-sort control restores automatic ordering.

## Uninstall

Quit AgentBoard, then run this from the extracted package folder:

```bash
bash uninstall.sh --yes
```

This removes the owned app, helper and reporting block. Codex sessions, authentication, other instructions and the AgentBoard database are preserved. Keep the entire extracted folder or ZIP, because uninstalling requires the helper and package marker alongside the script.
