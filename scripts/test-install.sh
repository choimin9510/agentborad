#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agentboard install;quoted.XXXXXX")"
trap 'if [[ "${KEEP_INSTALL_TEST_WORK:-0}" == "1" ]]; then echo "test work: $WORK"; else rm -rf "$WORK"; fi' EXIT

export AGENTBOARD_BUILD_DIR="$WORK/isolated build"
export AGENTBOARD_OUTPUT_DIR="$WORK/isolated output"
"$ROOT/scripts/build.sh" >/dev/null
export AGENTBOARD_TEST_SKIP_BUILD=1

APP_DIR="$WORK/apps dir"
BIN_DIR="$WORK/bin dir"
STATE_DIR="$WORK/state dir"
CODEX_HOME_VALUE="$WORK/codex home"
APP_TARGET="$APP_DIR/AgentBoard.app"
HELPER_TARGET="$BIN_DIR/agentboard"
AGENTS_FILE="$CODEX_HOME_VALUE/AGENTS.md"
mkdir -p "$APP_TARGET/Contents" "$BIN_DIR" "$CODEX_HOME_VALUE"

plutil -create xml1 "$APP_TARGET/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "original.helper.app" "$APP_TARGET/Contents/Info.plist"
SENTINEL="$WORK/sentinel helper"
printf 'unrelated sentinel\n' > "$SENTINEL"
SENTINEL_HASH="$(shasum -a 256 "$SENTINEL" | awk '{print $1}')"
ln -s "$SENTINEL" "$HELPER_TARGET"
ORIGINAL_AGENTS="기존 Unicode 지침 🌏 no final newline"
printf '%s' "$ORIGINAL_AGENTS" > "$AGENTS_FILE"
ORIGINAL_BYTES="$(wc -c < "$AGENTS_FILE" | tr -d ' ')"

COMMON=(
    --yes
    --app-dir "$APP_DIR"
    --bin-dir "$BIN_DIR"
    --state-dir "$STATE_DIR"
    --codex-home "$CODEX_HOME_VALUE"
)

"$ROOT/scripts/install.sh" "${COMMON[@]}"
[[ -L "$HELPER_TARGET" ]] && { echo "helper is still a symlink after install" >&2; exit 1; }
[[ "$(shasum -a 256 "$SENTINEL" | awk '{print $1}')" == "$SENTINEL_HASH" ]]

APP_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_TARGET/Contents/Info.plist")"
[[ "$APP_ID" == "app.agentboard.mac" ]]
MANIFEST="$STATE_DIR/install.json"
[[ -f "$MANIFEST" ]]
[[ "$(stat -f '%Lp' "$MANIFEST")" == "600" ]]
BEGIN_COUNT="$(rg -c 'AGENTBOARD:BEGIN v1' "$AGENTS_FILE")"
END_COUNT="$(rg -c 'AGENTBOARD:END v1' "$AGENTS_FILE")"
[[ "$BEGIN_COUNT" == "1" && "$END_COUNT" == "1" ]]
APP_BACKUP_ONE="$(plutil -extract appBackup raw -o - "$MANIFEST")"
HELPER_BACKUP_ONE="$(plutil -extract helperBackup raw -o - "$MANIFEST")"

"$ROOT/scripts/install.sh" "${COMMON[@]}"
SECOND_APP_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_TARGET/Contents/Info.plist")"
[[ "$SECOND_APP_ID" == "app.agentboard.mac" ]] || {
    echo "app ownership changed after second install: $SECOND_APP_ID" >&2
    exit 1
}
APP_BACKUP_TWO="$(plutil -extract appBackup raw -o - "$MANIFEST")"
HELPER_BACKUP_TWO="$(plutil -extract helperBackup raw -o - "$MANIFEST")"
[[ "$APP_BACKUP_ONE" == "$APP_BACKUP_TWO" ]]
[[ "$HELPER_BACKUP_ONE" == "$HELPER_BACKUP_TWO" ]]

MANIFEST_HASH_BEFORE="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
APP_EXEC_HASH_BEFORE="$(shasum -a 256 "$APP_TARGET/Contents/MacOS/AgentBoard" | awk '{print $1}')"
HELPER_HASH_BEFORE="$(shasum -a 256 "$HELPER_TARGET" | awk '{print $1}')"
AGENTS_HASH_BEFORE="$(shasum -a 256 "$AGENTS_FILE" | awk '{print $1}')"
if AGENTBOARD_TEST_FAIL_INSTALL=after-agents \
    "$ROOT/scripts/install.sh" "${COMMON[@]}" >/dev/null 2>&1; then
    echo "injected reinstall failure unexpectedly succeeded" >&2
    exit 1
fi
[[ "$(shasum -a 256 "$MANIFEST" | awk '{print $1}')" == "$MANIFEST_HASH_BEFORE" ]]
[[ "$(shasum -a 256 "$APP_TARGET/Contents/MacOS/AgentBoard" | awk '{print $1}')" == "$APP_EXEC_HASH_BEFORE" ]]
[[ "$(shasum -a 256 "$HELPER_TARGET" | awk '{print $1}')" == "$HELPER_HASH_BEFORE" ]]
[[ "$(shasum -a 256 "$AGENTS_FILE" | awk '{print $1}')" == "$AGENTS_HASH_BEFORE" ]]

"$ROOT/scripts/uninstall.sh" "${COMMON[@]}"
[[ ! -e "$MANIFEST" ]]
[[ -L "$HELPER_TARGET" ]]
[[ "$(readlink "$HELPER_TARGET")" == "$SENTINEL" ]]
[[ "$(shasum -a 256 "$SENTINEL" | awk '{print $1}')" == "$SENTINEL_HASH" ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP_TARGET/Contents/Info.plist")" == "original.helper.app" ]]
[[ "$(cat "$AGENTS_FILE")" == "$ORIGINAL_AGENTS" ]]
[[ "$(wc -c < "$AGENTS_FILE" | tr -d ' ')" == "$ORIGINAL_BYTES" ]]

MALFORMED_HOME="$WORK/malformed home"
mkdir -p "$MALFORMED_HOME"
printf 'before\n<!-- AGENTBOARD:BEGIN v1 -->\nunterminated' > "$MALFORMED_HOME/AGENTS.md"
if "$ROOT/scripts/install.sh" --yes \
    --app-dir "$WORK/malformed apps" \
    --bin-dir "$WORK/malformed bin" \
    --state-dir "$WORK/malformed state" \
    --codex-home "$MALFORMED_HOME" >/dev/null 2>&1; then
    echo "malformed AGENTS delimiters were accepted" >&2
    exit 1
fi
[[ ! -e "$WORK/malformed apps/AgentBoard.app" ]]
[[ ! -e "$MALFORMED_HOME/AGENTS.md.agentboard" ]]

expect_agents_preflight_failure() {
    local case_name="$1"
    local codex_home_path="$2"
    local install_root="$3"
    if "$ROOT/scripts/install.sh" --yes \
        --app-dir "$install_root/apps" \
        --bin-dir "$install_root/bin" \
        --state-dir "$install_root/state" \
        --codex-home "$codex_home_path" >/dev/null 2>&1; then
        echo "$case_name AGENTS 경로가 설치 전에 거부되지 않았습니다" >&2
        exit 1
    fi
    [[ ! -e "$install_root/apps/AgentBoard.app" ]]
    [[ ! -e "$install_root/bin/agentboard" ]]
    [[ ! -e "$install_root/state/install.json" ]]
}

SAFE_PREFLIGHT_HOME="$WORK/safe preflight home"
DIRECTORY_AGENTS_HOME="$WORK/directory AGENTS home"
BROKEN_AGENTS_HOME="$WORK/broken AGENTS home"
LINKED_AGENTS_HOME="$WORK/linked AGENTS home"
LINKED_AGENTS_TARGET="$WORK/shared user instructions.md"
mkdir -p \
    "$SAFE_PREFLIGHT_HOME" \
    "$DIRECTORY_AGENTS_HOME/AGENTS.md" \
    "$BROKEN_AGENTS_HOME" \
    "$LINKED_AGENTS_HOME"
printf '%s' 'safe original rules' > "$SAFE_PREFLIGHT_HOME/AGENTS.md"
printf '%s' 'do not delete directory' > \
    "$DIRECTORY_AGENTS_HOME/AGENTS.md/keep"
ln -s "$BROKEN_AGENTS_HOME/missing target" \
    "$BROKEN_AGENTS_HOME/AGENTS.md"
printf '%s' 'shared link target rules' > "$LINKED_AGENTS_TARGET"
ln -s "$LINKED_AGENTS_TARGET" "$LINKED_AGENTS_HOME/AGENTS.md"

# The safe home is first so the second invalid home must be rejected before
# its instructions are touched.
if "$ROOT/scripts/install.sh" --yes \
    --app-dir "$WORK/directory preflight/apps" \
    --bin-dir "$WORK/directory preflight/bin" \
    --state-dir "$WORK/directory preflight/state" \
    --codex-home "$SAFE_PREFLIGHT_HOME" \
    --codex-home "$DIRECTORY_AGENTS_HOME" >/dev/null 2>&1; then
    echo "directory AGENTS path in a later home was accepted" >&2
    exit 1
fi
[[ "$(cat "$SAFE_PREFLIGHT_HOME/AGENTS.md")" == "safe original rules" ]]
[[ -f "$DIRECTORY_AGENTS_HOME/AGENTS.md/keep" ]]
[[ ! -e "$WORK/directory preflight/apps/AgentBoard.app" ]]
[[ ! -e "$WORK/directory preflight/bin/agentboard" ]]
[[ ! -e "$WORK/directory preflight/state/install.json" ]]

expect_agents_preflight_failure \
    "broken symlink" "$BROKEN_AGENTS_HOME" "$WORK/broken link preflight"
[[ -L "$BROKEN_AGENTS_HOME/AGENTS.md" ]]
[[ ! -e "$BROKEN_AGENTS_HOME/missing target" ]]

expect_agents_preflight_failure \
    "symlink" "$LINKED_AGENTS_HOME" "$WORK/link preflight"
[[ -L "$LINKED_AGENTS_HOME/AGENTS.md" ]]
[[ "$(cat "$LINKED_AGENTS_TARGET")" == "shared link target rules" ]]

CHANGED_ROOT="$WORK/changed helper"
CHANGED_CODEX="$WORK/changed codex"
mkdir -p "$CHANGED_CODEX"
printf 'existing codex rules\n' > "$CHANGED_CODEX/AGENTS.md"
"$ROOT/scripts/install.sh" --yes \
    --app-dir "$CHANGED_ROOT/apps" \
    --bin-dir "$CHANGED_ROOT/bin" \
    --state-dir "$CHANGED_ROOT/state" \
    --codex-home "$CHANGED_CODEX" >/dev/null
printf '\nlocal modification\n' >> "$CHANGED_ROOT/bin/agentboard"
if "$ROOT/scripts/uninstall.sh" --yes \
    --app-dir "$CHANGED_ROOT/apps" \
    --bin-dir "$CHANGED_ROOT/bin" \
    --state-dir "$CHANGED_ROOT/state" \
    --codex-home "$CHANGED_CODEX" >/dev/null 2>&1; then
    echo "changed helper was removed without preflight failure" >&2
    exit 1
fi
[[ -e "$CHANGED_ROOT/apps/AgentBoard.app" ]]
rg -q 'AGENTBOARD:BEGIN v1' "$CHANGED_CODEX/AGENTS.md"

FAIL_HOME="$WORK/fail new agents"
FAIL_ROOT="$WORK/fail install"
mkdir -p "$FAIL_HOME"
if AGENTBOARD_TEST_FAIL_INSTALL=after-agents \
    "$ROOT/scripts/install.sh" --yes \
    --app-dir "$FAIL_ROOT/apps" \
    --bin-dir "$FAIL_ROOT/bin" \
    --state-dir "$FAIL_ROOT/state" \
    --codex-home "$FAIL_HOME" >/dev/null 2>&1; then
    echo "failure-injection install unexpectedly succeeded" >&2
    exit 1
fi
[[ ! -e "$FAIL_ROOT/apps/AgentBoard.app" ]]
[[ ! -e "$FAIL_ROOT/bin/agentboard" ]]
[[ ! -e "$FAIL_HOME/AGENTS.md" ]]
[[ ! -e "$FAIL_ROOT/state/install.json" ]]

ROLLBACK_HOME="$WORK/rollback continuation home"
ROLLBACK_ROOT="$WORK/rollback continuation install"
mkdir -p "$ROLLBACK_HOME"
printf '%s' 'rollback original rules' > "$ROLLBACK_HOME/AGENTS.md"
"$ROOT/scripts/install.sh" --yes \
    --app-dir "$ROLLBACK_ROOT/apps" \
    --bin-dir "$ROLLBACK_ROOT/bin" \
    --state-dir "$ROLLBACK_ROOT/state" \
    --codex-home "$ROLLBACK_HOME" >/dev/null
ROLLBACK_MANIFEST="$ROLLBACK_ROOT/state/install.json"
ROLLBACK_APP_HASH="$(shasum -a 256 "$ROLLBACK_ROOT/apps/AgentBoard.app/Contents/MacOS/AgentBoard" | awk '{print $1}')"
ROLLBACK_HELPER_HASH="$(shasum -a 256 "$ROLLBACK_ROOT/bin/agentboard" | awk '{print $1}')"
ROLLBACK_MANIFEST_HASH="$(shasum -a 256 "$ROLLBACK_MANIFEST" | awk '{print $1}')"
if AGENTBOARD_TEST_FAIL_INSTALL=after-agents \
    AGENTBOARD_TEST_FORCE_AGENTS_RESTORE_FAILURE=0 \
    "$ROOT/scripts/install.sh" --yes \
    --app-dir "$ROLLBACK_ROOT/apps" \
    --bin-dir "$ROLLBACK_ROOT/bin" \
    --state-dir "$ROLLBACK_ROOT/state" \
    --codex-home "$ROLLBACK_HOME" >/dev/null 2>&1; then
    echo "forced AGENTS-restore failure install unexpectedly succeeded" >&2
    exit 1
fi
[[ "$(shasum -a 256 "$ROLLBACK_ROOT/apps/AgentBoard.app/Contents/MacOS/AgentBoard" | awk '{print $1}')" == "$ROLLBACK_APP_HASH" ]]
[[ "$(shasum -a 256 "$ROLLBACK_ROOT/bin/agentboard" | awk '{print $1}')" == "$ROLLBACK_HELPER_HASH" ]]
[[ "$(shasum -a 256 "$ROLLBACK_MANIFEST" | awk '{print $1}')" == "$ROLLBACK_MANIFEST_HASH" ]]

UNOWNED_CODEX="$WORK/unowned codex"
UNOWNED_ROOT="$WORK/unowned install"
mkdir -p "$UNOWNED_CODEX"
printf '%s\nmanaged-by-someone-else\n%s\n' \
    '<!-- AGENTBOARD:BEGIN v1 -->' \
    '<!-- AGENTBOARD:END v1 -->' > "$UNOWNED_CODEX/AGENTS.md"
UNOWNED_HASH="$(shasum -a 256 "$UNOWNED_CODEX/AGENTS.md" | awk '{print $1}')"
"$ROOT/scripts/install.sh" --yes --no-agents \
    --app-dir "$UNOWNED_ROOT/apps" \
    --bin-dir "$UNOWNED_ROOT/bin" \
    --state-dir "$UNOWNED_ROOT/state" \
    --codex-home "$UNOWNED_CODEX" >/dev/null
"$ROOT/scripts/uninstall.sh" --yes \
    --app-dir "$UNOWNED_ROOT/apps" \
    --bin-dir "$UNOWNED_ROOT/bin" \
    --state-dir "$UNOWNED_ROOT/state" \
    --codex-home "$UNOWNED_CODEX" >/dev/null
[[ "$(shasum -a 256 "$UNOWNED_CODEX/AGENTS.md" | awk '{print $1}')" == "$UNOWNED_HASH" ]]

MULTI_HOME_A="$WORK/multi codex 🅰️"
MULTI_HOME_B="$WORK/multi codex 🇧🇷"
MULTI_ROOT="$WORK/multi install"
mkdir -p "$MULTI_HOME_A" "$MULTI_HOME_B"
MULTI_ORIGINAL_A="A home Unicode 지침 🌏 no final newline"
MULTI_ORIGINAL_B="B home 공백 지침 no final newline"
printf '%s' "$MULTI_ORIGINAL_A" > "$MULTI_HOME_A/AGENTS.md"
printf '%s' "$MULTI_ORIGINAL_B" > "$MULTI_HOME_B/AGENTS.md"
MULTI_COMMON=(
    --yes
    --app-dir "$MULTI_ROOT/apps"
    --bin-dir "$MULTI_ROOT/bin"
    --state-dir "$MULTI_ROOT/state"
    --codex-home "$MULTI_HOME_A"
    --codex-home "$MULTI_HOME_B"
)
"$ROOT/scripts/install.sh" "${MULTI_COMMON[@]}" >/dev/null
MULTI_MANIFEST="$MULTI_ROOT/state/install.json"
[[ "$(plutil -extract version raw -o - "$MULTI_MANIFEST")" == "2" ]]
[[ "$(plutil -extract codexHomeCount raw -o - "$MULTI_MANIFEST")" == "2" ]]
[[ "$(rg -c 'AGENTBOARD:BEGIN v1' "$MULTI_HOME_A/AGENTS.md")" == "1" ]]
[[ "$(rg -c 'AGENTBOARD:BEGIN v1' "$MULTI_HOME_B/AGENTS.md")" == "1" ]]
MULTI_BACKUP_A_ONE="$(plutil -extract codexHome0AgentsBackup raw -o - "$MULTI_MANIFEST")"
MULTI_BACKUP_B_ONE="$(plutil -extract codexHome1AgentsBackup raw -o - "$MULTI_MANIFEST")"
"$ROOT/scripts/install.sh" "${MULTI_COMMON[@]}" >/dev/null
[[ "$(plutil -extract codexHome0AgentsBackup raw -o - "$MULTI_MANIFEST")" == "$MULTI_BACKUP_A_ONE" ]]
[[ "$(plutil -extract codexHome1AgentsBackup raw -o - "$MULTI_MANIFEST")" == "$MULTI_BACKUP_B_ONE" ]]

"$ROOT/scripts/install.sh" --yes \
    --app-dir "$MULTI_ROOT/apps" \
    --bin-dir "$MULTI_ROOT/bin" \
    --state-dir "$MULTI_ROOT/state" \
    --codex-home "$MULTI_HOME_A" >/dev/null
[[ "$(plutil -extract codexHomeCount raw -o - "$MULTI_MANIFEST")" == "2" ]]
[[ "$(plutil -extract codexHome1AgentsOwned raw -o - "$MULTI_MANIFEST")" == "1" ]]
[[ "$(rg -c 'AGENTBOARD:BEGIN v1' "$MULTI_HOME_B/AGENTS.md")" == "1" ]]

"$ROOT/scripts/install.sh" --yes --no-agents \
    --app-dir "$MULTI_ROOT/apps" \
    --bin-dir "$MULTI_ROOT/bin" \
    --state-dir "$MULTI_ROOT/state" \
    --codex-home "$MULTI_HOME_A" >/dev/null
[[ "$(plutil -extract codexHomeCount raw -o - "$MULTI_MANIFEST")" == "2" ]]
[[ "$(plutil -extract codexHome0AgentsOwned raw -o - "$MULTI_MANIFEST")" == "1" ]]
[[ "$(plutil -extract codexHome1AgentsOwned raw -o - "$MULTI_MANIFEST")" == "1" ]]

MULTI_HASH_A="$(shasum -a 256 "$MULTI_HOME_A/AGENTS.md" | awk '{print $1}')"
MULTI_HASH_B="$(shasum -a 256 "$MULTI_HOME_B/AGENTS.md" | awk '{print $1}')"
MULTI_APP_HASH="$(shasum -a 256 "$MULTI_ROOT/apps/AgentBoard.app/Contents/MacOS/AgentBoard" | awk '{print $1}')"
MULTI_HELPER_HASH="$(shasum -a 256 "$MULTI_ROOT/bin/agentboard" | awk '{print $1}')"
MULTI_MANIFEST_HASH="$(shasum -a 256 "$MULTI_MANIFEST" | awk '{print $1}')"
if AGENTBOARD_TEST_FAIL_INSTALL=after-agents \
    "$ROOT/scripts/install.sh" "${MULTI_COMMON[@]}" >/dev/null 2>&1; then
    echo "multi-home failure injection unexpectedly succeeded" >&2
    exit 1
fi
[[ "$(shasum -a 256 "$MULTI_HOME_A/AGENTS.md" | awk '{print $1}')" == "$MULTI_HASH_A" ]]
[[ "$(shasum -a 256 "$MULTI_HOME_B/AGENTS.md" | awk '{print $1}')" == "$MULTI_HASH_B" ]]
[[ "$(shasum -a 256 "$MULTI_ROOT/apps/AgentBoard.app/Contents/MacOS/AgentBoard" | awk '{print $1}')" == "$MULTI_APP_HASH" ]]
[[ "$(shasum -a 256 "$MULTI_ROOT/bin/agentboard" | awk '{print $1}')" == "$MULTI_HELPER_HASH" ]]
[[ "$(shasum -a 256 "$MULTI_MANIFEST" | awk '{print $1}')" == "$MULTI_MANIFEST_HASH" ]]

if "$ROOT/scripts/uninstall.sh" --yes \
    --app-dir "$MULTI_ROOT/apps" \
    --bin-dir "$MULTI_ROOT/bin" \
    --state-dir "$MULTI_ROOT/state" \
    --codex-home "$MULTI_HOME_A" >/dev/null 2>&1; then
    echo "subset uninstall unexpectedly removed app with another owned home remaining" >&2
    exit 1
fi
[[ -e "$MULTI_ROOT/apps/AgentBoard.app" ]]
[[ -e "$MULTI_ROOT/bin/agentboard" ]]
[[ -f "$MULTI_MANIFEST" ]]
[[ "$(rg -c 'AGENTBOARD:BEGIN v1' "$MULTI_HOME_B/AGENTS.md")" == "1" ]]

"$ROOT/scripts/uninstall.sh" \
    --yes \
    --app-dir "$MULTI_ROOT/apps" \
    --bin-dir "$MULTI_ROOT/bin" \
    --state-dir "$MULTI_ROOT/state" \
    --codex-home "$MULTI_HOME_A" \
    --codex-home "$MULTI_HOME_B" >/dev/null
[[ "$(cat "$MULTI_HOME_A/AGENTS.md")" == "$MULTI_ORIGINAL_A" ]]
[[ "$(cat "$MULTI_HOME_B/AGENTS.md")" == "$MULTI_ORIGINAL_B" ]]

AUTO_HOME_ROOT="$WORK/auto home root"
AUTO_USER_HOME="$WORK/auto user home"
AUTO_DS_HOME="$AUTO_USER_HOME/.codex-ds"
mkdir -p "$AUTO_DS_HOME"
env -i \
    HOME="$AUTO_USER_HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    AGENTBOARD_BUILD_DIR="$AGENTBOARD_BUILD_DIR" \
    AGENTBOARD_OUTPUT_DIR="$AGENTBOARD_OUTPUT_DIR" \
    AGENTBOARD_TEST_SKIP_BUILD=1 \
    "$ROOT/scripts/install.sh" --yes \
    --app-dir "$AUTO_HOME_ROOT/apps" \
    --bin-dir "$AUTO_HOME_ROOT/bin" \
    --state-dir "$AUTO_HOME_ROOT/state" >/dev/null
AUTO_MANIFEST="$AUTO_HOME_ROOT/state/install.json"
[[ "$(plutil -extract codexHomeCount raw -o - "$AUTO_MANIFEST")" == "2" ]]
[[ "$(rg -c 'AGENTBOARD:BEGIN v1' "$AUTO_USER_HOME/.codex/AGENTS.md")" == "1" ]]
[[ "$(rg -c 'AGENTBOARD:BEGIN v1' "$AUTO_DS_HOME/AGENTS.md")" == "1" ]]
env -i \
    HOME="$AUTO_USER_HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    AGENTBOARD_BUILD_DIR="$AGENTBOARD_BUILD_DIR" \
    AGENTBOARD_OUTPUT_DIR="$AGENTBOARD_OUTPUT_DIR" \
    AGENTBOARD_TEST_SKIP_BUILD=1 \
    "$ROOT/scripts/uninstall.sh" --yes \
    --app-dir "$AUTO_HOME_ROOT/apps" \
    --bin-dir "$AUTO_HOME_ROOT/bin" \
    --state-dir "$AUTO_HOME_ROOT/state" >/dev/null

UPGRADE_USER_HOME="$WORK/upgrade user home"
UPGRADE_CUSTOM_HOME="$WORK/upgrade custom codex"
UPGRADE_ROOT="$WORK/upgrade install"
mkdir -p "$UPGRADE_USER_HOME" "$UPGRADE_CUSTOM_HOME"
UPGRADE_ORIGINAL="v1 original 지침 🌏 no final newline"
printf '%s' "$UPGRADE_ORIGINAL" > "$UPGRADE_CUSTOM_HOME/AGENTS.md"
"$ROOT/scripts/install.sh" --yes \
    --app-dir "$UPGRADE_ROOT/apps" \
    --bin-dir "$UPGRADE_ROOT/bin" \
    --state-dir "$UPGRADE_ROOT/state" \
    --codex-home "$UPGRADE_CUSTOM_HOME" >/dev/null
UPGRADE_MANIFEST="$UPGRADE_ROOT/state/install.json"
UPGRADE_BACKUP="$(plutil -extract codexHome0AgentsBackup raw -o - "$UPGRADE_MANIFEST")"
UPGRADE_SEPARATOR="$(plutil -extract codexHome0AgentsLeadingSeparator raw -o - "$UPGRADE_MANIFEST")"
plutil -replace version -integer 1 "$UPGRADE_MANIFEST"
plutil -insert codexHome -string "$UPGRADE_CUSTOM_HOME" "$UPGRADE_MANIFEST"
plutil -insert agentsLeadingSeparator -integer "$UPGRADE_SEPARATOR" "$UPGRADE_MANIFEST"
plutil -insert agentsOwned -integer 1 "$UPGRADE_MANIFEST"
plutil -insert agentsBackup -string "$UPGRADE_BACKUP" "$UPGRADE_MANIFEST"
plutil -remove codexHomeCount "$UPGRADE_MANIFEST"
plutil -remove codexHome0Path "$UPGRADE_MANIFEST"
plutil -remove codexHome0AgentsLeadingSeparator "$UPGRADE_MANIFEST"
plutil -remove codexHome0AgentsOwned "$UPGRADE_MANIFEST"
plutil -remove codexHome0AgentsBackup "$UPGRADE_MANIFEST"
env -i \
    HOME="$UPGRADE_USER_HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    AGENTBOARD_BUILD_DIR="$AGENTBOARD_BUILD_DIR" \
    AGENTBOARD_OUTPUT_DIR="$AGENTBOARD_OUTPUT_DIR" \
    AGENTBOARD_TEST_SKIP_BUILD=1 \
    "$ROOT/scripts/install.sh" --yes \
    --app-dir "$UPGRADE_ROOT/apps" \
    --bin-dir "$UPGRADE_ROOT/bin" \
    --state-dir "$UPGRADE_ROOT/state" >/dev/null
[[ "$(plutil -extract version raw -o - "$UPGRADE_MANIFEST")" == "2" ]]
[[ "$(plutil -extract codexHomeCount raw -o - "$UPGRADE_MANIFEST")" == "2" ]]
[[ "$(rg -c 'AGENTBOARD:BEGIN v1' "$UPGRADE_CUSTOM_HOME/AGENTS.md")" == "1" ]]
[[ "$(rg -c 'AGENTBOARD:BEGIN v1' "$UPGRADE_USER_HOME/.codex/AGENTS.md")" == "1" ]]
[[ "$(plutil -extract codexHome1AgentsBackup raw -o - "$UPGRADE_MANIFEST")" == "$UPGRADE_BACKUP" ]]
env -i \
    HOME="$UPGRADE_USER_HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    AGENTBOARD_BUILD_DIR="$AGENTBOARD_BUILD_DIR" \
    AGENTBOARD_OUTPUT_DIR="$AGENTBOARD_OUTPUT_DIR" \
    AGENTBOARD_TEST_SKIP_BUILD=1 \
    "$ROOT/scripts/uninstall.sh" --yes \
    --app-dir "$UPGRADE_ROOT/apps" \
    --bin-dir "$UPGRADE_ROOT/bin" \
    --state-dir "$UPGRADE_ROOT/state" >/dev/null
[[ "$(cat "$UPGRADE_CUSTOM_HOME/AGENTS.md")" == "$UPGRADE_ORIGINAL" ]]

echo "installer temp-override, symlink, idempotence, Unicode and preflight tests: PASS"
