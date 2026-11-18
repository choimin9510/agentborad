#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/agentboard-package.json" ]]; then
    ROOT="$SCRIPT_DIR"
else
    ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
CONFIRM=0
CODEX_HOME_OVERRIDES=()
APP_DIR_OVERRIDE=""
BIN_DIR_OVERRIDE=""
STATE_DIR_OVERRIDE=""
FORCE_PREBUILT=0

while (($#)); do
    case "$1" in
        --yes) CONFIRM=1 ;;
        --prebuilt) FORCE_PREBUILT=1 ;;
        --codex-home|--app-dir|--bin-dir|--state-dir)
            FLAG="$1"
            shift
            [[ $# -gt 0 ]] || { echo "$FLAG 값이 필요합니다." >&2; exit 2; }
            case "$FLAG" in
                --codex-home) CODEX_HOME_OVERRIDES+=("$1") ;;
                --app-dir) APP_DIR_OVERRIDE="$1" ;;
                --bin-dir) BIN_DIR_OVERRIDE="$1" ;;
                --state-dir) STATE_DIR_OVERRIDE="$1" ;;
            esac
            ;;
        *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ "$CONFIRM" != "1" ]]; then
    echo "제거 계획을 확인한 뒤 --yes와 함께 다시 실행하세요."
    exit 0
fi

APP_DIR="${APP_DIR_OVERRIDE:-$HOME/Applications}"
BIN_DIR="${BIN_DIR_OVERRIDE:-$HOME/.local/bin}"
STATE_DIR="${STATE_DIR_OVERRIDE:-$HOME/.local/share/agentboard}"
MANIFEST="$STATE_DIR/install.json"
[[ -f "$MANIFEST" ]] || { echo "설치 manifest를 찾을 수 없습니다: $MANIFEST" >&2; exit 1; }

manifest_value() {
    plutil -extract "$1" raw -o - "$MANIFEST" 2>/dev/null || true
}

normalize_codex_home() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    if [[ "$path" != /* ]]; then
        path="$PWD/$path"
    fi
    if [[ -d "$path" ]]; then
        (cd "$path" && pwd -P)
    else
        while [[ "$path" != "/" && "$path" == */ ]]; do
            path="${path%/}"
        done
        printf '%s\n' "$path"
    fi
}

CODEX_HOMES=()
append_codex_home() {
    local normalized
    normalized="$(normalize_codex_home "$1")" || return 0
    local index
    for ((index=0; index<${#CODEX_HOMES[@]}; index++)); do
        [[ "${CODEX_HOMES[$index]}" == "$normalized" ]] && return 0
    done
    CODEX_HOMES+=("$normalized")
}

MANAGED_CODEX_HOMES=()
append_managed_codex_home() {
    local normalized
    normalized="$(normalize_codex_home "$1")" || return 0
    local index
    for ((index=0; index<${#MANAGED_CODEX_HOMES[@]}; index++)); do
        [[ "${MANAGED_CODEX_HOMES[$index]}" == "$normalized" ]] && return 0
    done
    MANAGED_CODEX_HOMES+=("$normalized")
}

MANIFEST_VERSION="$(manifest_value version)"
if [[ "$MANIFEST_VERSION" == "2"
    && "$(manifest_value codexHomeCount)" =~ ^[0-9]+$ ]]; then
    for ((i=0; i<$(manifest_value codexHomeCount); i++)); do
        append_managed_codex_home "$(manifest_value "codexHome${i}Path")"
    done
else
    prior_codex_home="$(manifest_value codexHome)"
    if [[ -n "$prior_codex_home" ]]; then
        append_managed_codex_home "$prior_codex_home"
    elif [[ -n "${CODEX_HOME:-}" ]]; then
        append_managed_codex_home "$CODEX_HOME"
    fi
fi

if ((${#CODEX_HOME_OVERRIDES[@]} > 0)); then
    for ((i=0; i<${#CODEX_HOME_OVERRIDES[@]}; i++)); do
        append_codex_home "${CODEX_HOME_OVERRIDES[$i]}"
    done
else
    for ((i=0; i<${#MANAGED_CODEX_HOMES[@]}; i++)); do
        append_codex_home "${MANAGED_CODEX_HOMES[$i]}"
    done
fi

agents_metadata_for_home() {
    local codex_home_path="$1"
    local key="$2"
    if [[ "$MANIFEST_VERSION" == "2" ]]; then
        local count="$(manifest_value codexHomeCount)"
        if [[ "$count" =~ ^[0-9]+$ ]]; then
            local index
            for ((index=0; index<count; index++)); do
                local path="$(manifest_value "codexHome${index}Path")"
                if [[ "$(normalize_codex_home "$path")" == "$codex_home_path" ]]; then
                    manifest_value "codexHome${index}${key}"
                    return 0
                fi
            done
        fi
    elif [[ "$(normalize_codex_home "$(manifest_value codexHome)")" == "$codex_home_path" ]]; then
        case "$key" in
            AgentsOwned) manifest_value agentsOwned ;;
            AgentsLeadingSeparator) manifest_value agentsLeadingSeparator ;;
        esac
    fi
}

requested_contains_home() {
    local codex_home_path="$1"
    local index
    for ((index=0; index<${#CODEX_HOMES[@]}; index++)); do
        [[ "${CODEX_HOMES[$index]}" == "$codex_home_path" ]] && return 0
    done
    return 1
}

if ((${#CODEX_HOME_OVERRIDES[@]} > 0)); then
    for ((i=0; i<${#MANAGED_CODEX_HOMES[@]}; i++)); do
        managed_home="${MANAGED_CODEX_HOMES[$i]}"
        owned="$(agents_metadata_for_home "$managed_home" AgentsOwned)"
        if [[ "${owned:-0}" == "1" ]] && ! requested_contains_home "$managed_home"; then
            echo "다른 Codex 홈에 AgentBoard AGENTS 블록이 남아 있어 제거를 중단합니다: $managed_home" >&2
            echo "모든 owned 홈을 --codex-home으로 지정하거나 옵션 없이 다시 실행하세요." >&2
            exit 1
        fi
    done
fi

if [[ -n "$APP_DIR_OVERRIDE" ]]; then
    APP_TARGET="$APP_DIR_OVERRIDE/AgentBoard.app"
else
    APP_TARGET="$(manifest_value appTarget)"
fi
if [[ -n "$BIN_DIR_OVERRIDE" ]]; then
    HELPER_TARGET="$BIN_DIR_OVERRIDE/agentboard"
else
    HELPER_TARGET="$(manifest_value helperTarget)"
fi
HELPER_HASH="$(manifest_value helperHash)"
HELPER_BACKUP="$(manifest_value helperBackup)"
APP_BACKUP="$(manifest_value appBackup)"
PACKAGE_MARKER="$ROOT/agentboard-package.json"
PREBUILT=0
if [[ "$FORCE_PREBUILT" == "1"
    || -f "$PACKAGE_MARKER"
    || -f "$ROOT/Install.command"
    || ! -f "$ROOT/scripts/build.sh" ]]; then
    PREBUILT=1
fi
if [[ "$PREBUILT" == "1" ]]; then
    [[ -f "$PACKAGE_MARKER" ]] || {
        echo "prebuilt package marker가 없습니다: $PACKAGE_MARKER" >&2
        exit 1
    }
    HELPER_BIN="$ROOT/agentboard"
else
    SOURCE_BUILD_DIR="${AGENTBOARD_BUILD_DIR:-$ROOT/.build}"
    HELPER_BIN="$SOURCE_BUILD_DIR/agentboard"
fi

[[ -n "$APP_TARGET" && -n "$HELPER_TARGET" ]] || {
    echo "manifest의 설치 경로가 올바르지 않습니다." >&2
    exit 1
}
APP_EXISTS=0
HELPER_EXISTS=0

if [[ -e "$APP_TARGET" ]]; then
    BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$BUNDLE_ID" == "app.agentboard.mac" ]] || {
        echo "대상 앱이 AgentBoard가 아니므로 제거하지 않습니다: $APP_TARGET ($BUNDLE_ID)" >&2
        exit 1
    }
    APP_EXISTS=1
fi

if [[ -e "$HELPER_TARGET" || -L "$HELPER_TARGET" ]]; then
    CURRENT_HASH="$(shasum -a 256 "$HELPER_TARGET" | awk '{print $1}')"
    [[ -n "$HELPER_HASH" && "$CURRENT_HASH" == "$HELPER_HASH" ]] || {
        echo "helper가 설치 후 변경되어 제거하지 않습니다." >&2
        exit 1
    }
    HELPER_EXISTS=1
fi

if [[ ! -x "$HELPER_BIN" && "$PREBUILT" == "0" ]]; then
    "$ROOT/scripts/build.sh"
fi
for ((i=0; i<${#CODEX_HOMES[@]}; i++)); do
    codex_home_path="${CODEX_HOMES[$i]}"
    owned="$(agents_metadata_for_home "$codex_home_path" AgentsOwned)"
    agents_file="$codex_home_path/AGENTS.md"
    if [[ "${owned:-0}" == "1" && -f "$agents_file" ]]; then
        [[ -x "$HELPER_BIN" ]] || {
            echo "AGENTS 제거에 필요한 helper가 누락되었습니다: $HELPER_BIN" >&2
            exit 1
        }
        "$HELPER_BIN" agents-validate --file "$agents_file"
    fi
done

for ((i=0; i<${#CODEX_HOMES[@]}; i++)); do
    codex_home_path="${CODEX_HOMES[$i]}"
    owned="$(agents_metadata_for_home "$codex_home_path" AgentsOwned)"
    separator="$(agents_metadata_for_home "$codex_home_path" AgentsLeadingSeparator)"
    agents_file="$codex_home_path/AGENTS.md"
    if [[ "${owned:-0}" == "1" && -f "$agents_file" ]]; then
        "$HELPER_BIN" agents-remove \
            --file "$agents_file" \
            --leading-separator "${separator:-0}"
    fi
done

if [[ "$APP_EXISTS" == "1" ]]; then
    rm -rf "$APP_TARGET"
fi
if [[ "$HELPER_EXISTS" == "1" ]]; then
    rm -f "$HELPER_TARGET"
fi

if [[ -n "$HELPER_BACKUP" && ( -e "$HELPER_BACKUP" || -L "$HELPER_BACKUP" ) ]]; then
    mkdir -p "$(dirname "$HELPER_TARGET")"
    mv "$HELPER_BACKUP" "$HELPER_TARGET"
fi
if [[ -n "$APP_BACKUP" && -e "$APP_BACKUP" ]]; then
    mkdir -p "$(dirname "$APP_TARGET")"
    mv "$APP_BACKUP" "$APP_TARGET"
fi

rm -f "$MANIFEST"
echo "AgentBoard 앱, helper, 전용 AGENTS 블록을 제거했습니다."
echo "Codex 세션 기록과 AgentBoard 데이터베이스는 삭제하지 않았습니다."
