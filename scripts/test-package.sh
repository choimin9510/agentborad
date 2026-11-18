#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
ZIP="${1:-$ROOT/dist/AgentBoard-$VERSION-universal.zip}"
[[ -f "$ZIP" ]] || { echo "package ZIP not found: $ZIP" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agentboard-package-test.XXXXXX")"
trap 'if [[ "${KEEP_PACKAGE_TEST_WORK:-0}" == "1" ]]; then echo "test work: $WORK"; else rm -rf "$WORK"; fi' EXIT
EXTRACT_ROOT="$WORK/압축 해제"
mkdir -p "$EXTRACT_ROOT"
ditto -x -k "$ZIP" "$EXTRACT_ROOT"
[[ "$(find "$EXTRACT_ROOT" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == "1" ]]
PACKAGE="$(find "$EXTRACT_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$PACKAGE" && -f "$PACKAGE/agentboard-package.json" ]]

for required in \
    AgentBoard.app/Contents/Info.plist \
    AgentBoard.app/Contents/MacOS/AgentBoard \
    agentboard install.sh uninstall.sh Install.command \
    agents-block.txt README.md Distribution-Install-EN.md Distribution-Install-KO.md Distribution-Install-ZH-CN.md 설치안내.md agentboard-package.json; do
    [[ -e "$PACKAGE/$required" ]] || {
        echo "missing package payload: $required" >&2
        exit 1
    }
done
[[ "$(plutil -extract format raw -o - "$PACKAGE/agentboard-package.json")" == "prebuilt" ]]
case " $(lipo -archs "$PACKAGE/AgentBoard.app/Contents/MacOS/AgentBoard") " in *" arm64 "*) ;; *) exit 1 ;; esac
case " $(lipo -archs "$PACKAGE/AgentBoard.app/Contents/MacOS/AgentBoard") " in *" x86_64 "*) ;; *) exit 1 ;; esac
case " $(lipo -archs "$PACKAGE/agentboard") " in *" arm64 "*) ;; *) exit 1 ;; esac
case " $(lipo -archs "$PACKAGE/agentboard") " in *" x86_64 "*) ;; *) exit 1 ;; esac
codesign --verify --deep --strict "$PACKAGE/AgentBoard.app"
codesign --verify --strict "$PACKAGE/agentboard"
[[ -x "$PACKAGE/Install.command" ]]
[[ -x "$PACKAGE/install.sh" ]]
[[ -x "$PACKAGE/uninstall.sh" ]]
[[ -x "$PACKAGE/agentboard" ]]
bash -n "$PACKAGE/install.sh"
bash -n "$PACKAGE/uninstall.sh"
bash -n "$PACKAGE/Install.command"

COMMAND_HOME="$WORK/Install command home 🌏"
STUB_DIR="$WORK/command stubs"
OPEN_LOG="$WORK/opened app path.txt"
mkdir -p "$COMMAND_HOME/.codex-ds" "$STUB_DIR"
printf '%s\n' \
    '#!/bin/bash' \
    'printf "%s\n" "$*" > "$OPEN_LOG_FILE"' \
    > "$STUB_DIR/open"
chmod 755 "$STUB_DIR/open"
env -i \
    HOME="$COMMAND_HOME" \
    PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    OPEN_LOG_FILE="$OPEN_LOG" \
    "$PACKAGE/Install.command"
[[ -d "$COMMAND_HOME/Applications/AgentBoard.app" ]]
[[ -x "$COMMAND_HOME/.local/bin/agentboard" ]]
[[ "$(grep -c 'AGENTBOARD:BEGIN v1' "$COMMAND_HOME/.codex/AGENTS.md")" == "1" ]]
[[ "$(grep -c 'AGENTBOARD:BEGIN v1' "$COMMAND_HOME/.codex-ds/AGENTS.md")" == "1" ]]
[[ -f "$OPEN_LOG" ]]
[[ "$(cat "$OPEN_LOG")" == "$COMMAND_HOME/Applications/AgentBoard.app" ]]
env -i \
    HOME="$COMMAND_HOME" \
    PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$PACKAGE/uninstall.sh" --prebuilt --yes
[[ ! -e "$COMMAND_HOME/Applications/AgentBoard.app" ]]
[[ ! -e "$COMMAND_HOME/.local/bin/agentboard" ]]
if [[ -f "$COMMAND_HOME/.codex/AGENTS.md" ]]; then
    ! grep -q 'AGENTBOARD:BEGIN v1' "$COMMAND_HOME/.codex/AGENTS.md"
fi
if [[ -f "$COMMAND_HOME/.codex-ds/AGENTS.md" ]]; then
    ! grep -q 'AGENTBOARD:BEGIN v1' "$COMMAND_HOME/.codex-ds/AGENTS.md"
fi

APP_DIR="$WORK/apps 경로"
BIN_DIR="$WORK/bin 경로"
STATE_DIR="$WORK/state 경로"
CODEX_HOME_VALUE="$WORK/codex home 원문"
APP_TARGET="$APP_DIR/AgentBoard.app"
HELPER_TARGET="$BIN_DIR/agentboard"
AGENTS_FILE="$CODEX_HOME_VALUE/AGENTS.md"
mkdir -p "$APP_TARGET/Contents" "$BIN_DIR" "$CODEX_HOME_VALUE"
plutil -create xml1 "$APP_TARGET/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "original.unrelated.app" "$APP_TARGET/Contents/Info.plist"

SENTINEL="$WORK/unrelated helper sentinel"
printf 'unrelated helper\n' > "$SENTINEL"
SENTINEL_HASH="$(shasum -a 256 "$SENTINEL" | awk '{print $1}')"
ln -s "$SENTINEL" "$HELPER_TARGET"
ORIGINAL_AGENTS="기존 사용자 지침 🌏 no final newline"
printf '%s' "$ORIGINAL_AGENTS" > "$AGENTS_FILE"
ORIGINAL_AGENTS_BYTES="$(wc -c < "$AGENTS_FILE" | tr -d ' ')"

COMMON=(
    --prebuilt
    --yes
    --app-dir "$APP_DIR"
    --bin-dir "$BIN_DIR"
    --state-dir "$STATE_DIR"
    --codex-home "$CODEX_HOME_VALUE"
)

"$PACKAGE/install.sh" "${COMMON[@]}"
[[ ! -L "$HELPER_TARGET" ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP_TARGET/Contents/Info.plist")" == "app.agentboard.mac" ]]
[[ "$(shasum -a 256 "$SENTINEL" | awk '{print $1}')" == "$SENTINEL_HASH" ]]
MANIFEST="$STATE_DIR/install.json"
[[ -f "$MANIFEST" ]]
[[ "$(stat -f '%Lp' "$MANIFEST")" == "600" ]]
[[ "$(grep -c 'AGENTBOARD:BEGIN v1' "$AGENTS_FILE")" == "1" ]]
[[ "$(grep -c 'AGENTBOARD:END v1' "$AGENTS_FILE")" == "1" ]]

APP_BACKUP_ONE="$(plutil -extract appBackup raw -o - "$MANIFEST")"
HELPER_BACKUP_ONE="$(plutil -extract helperBackup raw -o - "$MANIFEST")"
"$PACKAGE/install.sh" "${COMMON[@]}"
[[ "$(plutil -extract appBackup raw -o - "$MANIFEST")" == "$APP_BACKUP_ONE" ]]
[[ "$(plutil -extract helperBackup raw -o - "$MANIFEST")" == "$HELPER_BACKUP_ONE" ]]

MANIFEST_HASH_BEFORE="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
APP_HASH_BEFORE="$(shasum -a 256 "$APP_TARGET/Contents/MacOS/AgentBoard" | awk '{print $1}')"
HELPER_HASH_BEFORE="$(shasum -a 256 "$HELPER_TARGET" | awk '{print $1}')"
AGENTS_HASH_BEFORE="$(shasum -a 256 "$AGENTS_FILE" | awk '{print $1}')"
if AGENTBOARD_TEST_FAIL_INSTALL=after-agents \
    "$PACKAGE/install.sh" "${COMMON[@]}" >/dev/null 2>&1; then
    echo "injected package reinstall failure unexpectedly succeeded" >&2
    exit 1
fi
[[ "$(shasum -a 256 "$MANIFEST" | awk '{print $1}')" == "$MANIFEST_HASH_BEFORE" ]]
[[ "$(shasum -a 256 "$APP_TARGET/Contents/MacOS/AgentBoard" | awk '{print $1}')" == "$APP_HASH_BEFORE" ]]
[[ "$(shasum -a 256 "$HELPER_TARGET" | awk '{print $1}')" == "$HELPER_HASH_BEFORE" ]]
[[ "$(shasum -a 256 "$AGENTS_FILE" | awk '{print $1}')" == "$AGENTS_HASH_BEFORE" ]]

"$PACKAGE/uninstall.sh" "${COMMON[@]}"
[[ ! -e "$MANIFEST" ]]
[[ -L "$HELPER_TARGET" ]]
[[ "$(readlink "$HELPER_TARGET")" == "$SENTINEL" ]]
[[ "$(shasum -a 256 "$SENTINEL" | awk '{print $1}')" == "$SENTINEL_HASH" ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP_TARGET/Contents/Info.plist")" == "original.unrelated.app" ]]
[[ "$(cat "$AGENTS_FILE")" == "$ORIGINAL_AGENTS" ]]
[[ "$(wc -c < "$AGENTS_FILE" | tr -d ' ')" == "$ORIGINAL_AGENTS_BYTES" ]]

echo "prebuilt package structure, temporary install/reinstall/rollback/uninstall: PASS"
