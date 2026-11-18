#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/agentboard-package.json" ]]; then
    ROOT="$SCRIPT_DIR"
else
    ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
CONFIRM=0
INSTALL_AGENTS=1
CODEX_HOME_OVERRIDES=()
APP_DIR_OVERRIDE=""
BIN_DIR_OVERRIDE=""
STATE_DIR_OVERRIDE=""
FORCE_PREBUILT=0

while (($#)); do
    case "$1" in
        --yes) CONFIRM=1 ;;
        --no-agents) INSTALL_AGENTS=0 ;;
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

APP_DIR="${APP_DIR_OVERRIDE:-$HOME/Applications}"
BIN_DIR="${BIN_DIR_OVERRIDE:-$HOME/.local/bin}"
STATE_DIR="${STATE_DIR_OVERRIDE:-$HOME/.local/share/agentboard}"
APP_TARGET="$APP_DIR/AgentBoard.app"
HELPER_TARGET="$BIN_DIR/agentboard"
MANIFEST="$STATE_DIR/install.json"
PACKAGE_MARKER="$ROOT/agentboard-package.json"
PREBUILT=0
if [[ "$FORCE_PREBUILT" == "1"
    || -f "$PACKAGE_MARKER"
    || -f "$ROOT/Install.command"
    || ! -f "$ROOT/scripts/build.sh" ]]; then
    PREBUILT=1
fi
if [[ "$PREBUILT" == "1" ]]; then
    APP_SOURCE="$ROOT/AgentBoard.app"
    HELPER_SOURCE="$ROOT/agentboard"
    AGENTS_BLOCK_SOURCE="$ROOT/agents-block.txt"
    HELPER_BIN="$HELPER_SOURCE"
    UNINSTALL_SCRIPT="$ROOT/uninstall.sh"
    BUILD_SCRIPT=""
    if [[ ! -f "$PACKAGE_MARKER" ]]; then
        echo "prebuilt package marker가 없습니다: $PACKAGE_MARKER" >&2
        exit 1
    fi
    if [[ "$(plutil -extract format raw -o - "$PACKAGE_MARKER" 2>/dev/null || true)" != "prebuilt" ]]; then
        echo "지원하지 않는 package marker 형식입니다." >&2
        exit 1
    fi
else
    SOURCE_OUTPUT_DIR="${AGENTBOARD_OUTPUT_DIR:-$ROOT/build}"
    SOURCE_BUILD_DIR="${AGENTBOARD_BUILD_DIR:-$ROOT/.build}"
    APP_SOURCE="$SOURCE_OUTPUT_DIR/AgentBoard.app"
    HELPER_SOURCE="$SOURCE_BUILD_DIR/agentboard"
    AGENTS_BLOCK_SOURCE="$ROOT/Resources/agents-block.txt"
    HELPER_BIN="$HELPER_SOURCE"
    UNINSTALL_SCRIPT="$ROOT/scripts/uninstall.sh"
    BUILD_SCRIPT="$ROOT/scripts/build.sh"
fi

manifest_value() {
    local key="$1"
    [[ -f "$MANIFEST" ]] || return 0
    plutil -extract "$key" raw -o - "$MANIFEST" 2>/dev/null || true
}

PRIOR_APP_BACKUP="$(manifest_value appBackup)"
PRIOR_HELPER_BACKUP="$(manifest_value helperBackup)"
PRIOR_HELPER_HASH="$(manifest_value helperHash)"
MANIFEST_VERSION="$(manifest_value version)"
PRIOR_CODEX_HOME_SINGLE="$(manifest_value codexHome)"
PRIOR_CODEX_HOME_COUNT="$(manifest_value codexHomeCount)"

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
    local existing
    local existing_index
    for ((existing_index=0; existing_index<${#CODEX_HOMES[@]}; existing_index++)); do
        existing="${CODEX_HOMES[$existing_index]}"
        [[ "$existing" == "$normalized" ]] && return 0
    done
    CODEX_HOMES+=("$normalized")
}

PRIOR_V2_HOMES=()
if [[ "$PRIOR_CODEX_HOME_COUNT" =~ ^[0-9]+$ ]]; then
    for ((i=0; i<PRIOR_CODEX_HOME_COUNT; i++)); do
        PRIOR_V2_HOMES+=("$(manifest_value "codexHome${i}Path")")
    done
fi

if ((${#CODEX_HOME_OVERRIDES[@]} > 0)); then
    for ((i=0; i<${#CODEX_HOME_OVERRIDES[@]}; i++)); do
        append_codex_home "${CODEX_HOME_OVERRIDES[$i]}"
    done
else
    append_codex_home "$HOME/.codex"
    if [[ -d "$HOME/.codex-ds" ]]; then
        append_codex_home "$HOME/.codex-ds"
    fi
    if [[ -n "${CODEX_HOME:-}" ]]; then
        append_codex_home "$CODEX_HOME"
    fi
    if [[ -n "$PRIOR_CODEX_HOME_SINGLE" ]]; then
        append_codex_home "$PRIOR_CODEX_HOME_SINGLE"
    fi
    for ((i=0; i<${#PRIOR_V2_HOMES[@]}; i++)); do
        append_codex_home "${PRIOR_V2_HOMES[$i]}"
    done
fi
[[ ${#CODEX_HOMES[@]} -gt 0 ]] || {
    echo "관리할 Codex 홈이 없습니다." >&2
    exit 1
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
for ((i=0; i<${#CODEX_HOMES[@]}; i++)); do
    append_managed_codex_home "${CODEX_HOMES[$i]}"
done
if [[ -n "$PRIOR_CODEX_HOME_SINGLE" ]]; then
    append_managed_codex_home "$PRIOR_CODEX_HOME_SINGLE"
fi
for ((i=0; i<${#PRIOR_V2_HOMES[@]}; i++)); do
    append_managed_codex_home "${PRIOR_V2_HOMES[$i]}"
done

managed_index_for() {
    local codex_home_path="$1"
    local index
    for ((index=0; index<${#MANAGED_CODEX_HOMES[@]}; index++)); do
        if [[ "${MANAGED_CODEX_HOMES[$index]}" == "$codex_home_path" ]]; then
            printf '%s\n' "$index"
            return 0
        fi
    done
    return 1
}

prior_home_value() {
    local codex_home_path="$1"
    local key="$2"
    if [[ "$PRIOR_CODEX_HOME_COUNT" =~ ^[0-9]+$ ]]; then
        local index
        for ((index=0; index<PRIOR_CODEX_HOME_COUNT; index++)); do
            prior_path="$(manifest_value "codexHome${index}Path")"
            if [[ "$(normalize_codex_home "$prior_path")" == "$codex_home_path" ]]; then
                manifest_value "codexHome${index}${key}"
                return 0
            fi
        done
    fi
    if [[ "$(normalize_codex_home "$PRIOR_CODEX_HOME_SINGLE")" == "$codex_home_path" ]]; then
        case "$key" in
            AgentsOwned) manifest_value agentsOwned ;;
            AgentsLeadingSeparator) manifest_value agentsLeadingSeparator ;;
            AgentsBackup) manifest_value agentsBackup ;;
        esac
    fi
}

echo "AgentBoard 설치 계획"
echo "  앱: $APP_TARGET"
echo "  helper: $HELPER_TARGET"
echo "  manifest: $MANIFEST"
if [[ "$INSTALL_AGENTS" == "1" ]]; then
    for ((i=0; i<${#CODEX_HOMES[@]}; i++)); do
        echo "  AGENTS 통합: ${CODEX_HOMES[$i]}/AGENTS.md"
    done
else
    echo "  AGENTS 통합: 건너뜀"
fi

if [[ "$CONFIRM" != "1" ]]; then
    echo "실제 변경은 --yes를 붙여 다시 실행할 때만 수행합니다."
    exit 0
fi

if [[ "$PREBUILT" != "1"
    && "${AGENTBOARD_TEST_SKIP_BUILD:-0}" != "1" ]]; then
    "$BUILD_SCRIPT"
fi

for required in "$APP_SOURCE/Contents/Info.plist" "$HELPER_SOURCE" "$AGENTS_BLOCK_SOURCE"; do
    [[ -e "$required" ]] || {
        echo "설치 payload가 누락되었습니다: $required" >&2
        exit 1
    }
done
[[ -x "$HELPER_SOURCE" ]] || {
    echo "설치 helper가 실행 가능하지 않습니다: $HELPER_SOURCE" >&2
    exit 1
}
if [[ "$PREBUILT" == "1" ]]; then
    EXPECTED_APP_HASH="$(plutil -extract appExecutableSha256 raw -o - "$PACKAGE_MARKER" 2>/dev/null || true)"
    EXPECTED_HELPER_HASH="$(plutil -extract helperSha256 raw -o - "$PACKAGE_MARKER" 2>/dev/null || true)"
    ACTUAL_APP_HASH="$(shasum -a 256 "$APP_SOURCE/Contents/MacOS/AgentBoard" | awk '{print $1}')"
    ACTUAL_HELPER_HASH="$(shasum -a 256 "$HELPER_SOURCE" | awk '{print $1}')"
    [[ -n "$EXPECTED_APP_HASH" && "$ACTUAL_APP_HASH" == "$EXPECTED_APP_HASH" ]] || {
        echo "배포 앱 payload hash가 package marker와 다릅니다." >&2
        exit 1
    }
    [[ -n "$EXPECTED_HELPER_HASH" && "$ACTUAL_HELPER_HASH" == "$EXPECTED_HELPER_HASH" ]] || {
        echo "배포 helper hash가 package marker와 다릅니다." >&2
        exit 1
    }
    BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_SOURCE/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$BUNDLE_ID" == "app.agentboard.mac" ]] || {
        echo "배포 앱 bundle identifier가 올바르지 않습니다: $BUNDLE_ID" >&2
        exit 1
    }
    codesign --verify --deep --strict "$APP_SOURCE"
    codesign --verify --strict "$HELPER_SOURCE"
fi

validate_agents_target() {
    local codex_home_path="$1"
    local agents_file="$codex_home_path/AGENTS.md"

    if [[ -L "$codex_home_path" ]]; then
        echo "Codex 홈이 유효한 디렉터리로 해석되지 않습니다: $codex_home_path" >&2
        return 1
    fi
    if [[ -e "$codex_home_path" && ! -d "$codex_home_path" ]]; then
        echo "Codex 홈 경로가 디렉터리가 아닙니다: $codex_home_path" >&2
        return 1
    fi
    if [[ -L "$agents_file" ]]; then
        echo "AGENTS.md symlink는 링크 대상 보호를 위해 설치할 수 없습니다: $agents_file" >&2
        return 1
    fi
    if [[ -d "$agents_file" ]]; then
        echo "AGENTS.md 경로가 디렉터리입니다: $agents_file" >&2
        return 1
    fi
    if [[ -e "$agents_file" && ! -f "$agents_file" ]]; then
        echo "AGENTS.md 경로가 일반 파일이 아닙니다: $agents_file" >&2
        return 1
    fi
}

if [[ "$INSTALL_AGENTS" == "1" ]]; then
    for ((i=0; i<${#CODEX_HOMES[@]}; i++)); do
        validate_agents_target "${CODEX_HOMES[$i]}"
    done
fi

for ((i=0; i<${#CODEX_HOMES[@]}; i++)); do
    agents_file="${CODEX_HOMES[$i]}/AGENTS.md"
    if [[ -f "$agents_file" ]]; then
        "$HELPER_BIN" agents-validate --file "$agents_file"
    fi
done

mkdir -p "$APP_DIR" "$BIN_DIR" "$STATE_DIR"
chmod 700 "$STATE_DIR"

BACKUP_ROOT=""
make_backup_root() {
    if [[ -z "$BACKUP_ROOT" ]]; then
        mkdir -p "$STATE_DIR/backups"
        chmod 700 "$STATE_DIR/backups"
        BACKUP_ROOT="$(mktemp -d "$STATE_DIR/backups/install-XXXXXX")"
    fi
}

APP_BACKUP="$PRIOR_APP_BACKUP"
HELPER_BACKUP="$PRIOR_HELPER_BACKUP"
APP_REPLACED=0
HELPER_REPLACED=0
AGENTS_TOUCHED=()
AGENTS_ORIGINALLY_EXISTS=()
AGENTS_ATTEMPT_BACKUPS=()
AGENTS_PERMANENT_BACKUPS=()
AGENTS_OWNED_VALUES=()
AGENTS_SEPARATOR_VALUES=()
for ((i=0; i<${#MANAGED_CODEX_HOMES[@]}; i++)); do
    codex_home_path="${MANAGED_CODEX_HOMES[$i]}"
    AGENTS_TOUCHED+=(0)
    AGENTS_ORIGINALLY_EXISTS+=(0)
    AGENTS_ATTEMPT_BACKUPS+=("")
    AGENTS_PERMANENT_BACKUPS+=("$(prior_home_value "$codex_home_path" AgentsBackup)")
    AGENTS_OWNED_VALUES+=("$(prior_home_value "$codex_home_path" AgentsOwned)")
    separator="$(prior_home_value "$codex_home_path" AgentsLeadingSeparator)"
    AGENTS_SEPARATOR_VALUES+=("${separator:-0}")
done
MANIFEST_TOUCHED=0
MANIFEST_BACKUP=""
ATTEMPT_APP_BACKUP=""
ATTEMPT_HELPER_BACKUP=""
ATTEMPT_ROOT=""

restore_on_error() {
    status=$?
    [[ "$status" == "0" ]] && return
    local rollback_failed=0
    if [[ "$MANIFEST_TOUCHED" == "1" ]]; then
        if [[ ! -d "$MANIFEST" || -L "$MANIFEST" ]]; then
            rm -f "$MANIFEST" || {
                echo "manifest 제거 실패: $MANIFEST" >&2
                rollback_failed=1
            }
        else
            echo "manifest 경로가 디렉터리라 제거하지 않았습니다: $MANIFEST" >&2
            rollback_failed=1
        fi
        if [[ -n "$MANIFEST_BACKUP" && -f "$MANIFEST_BACKUP" ]]; then
            if [[ -d "$MANIFEST" && ! -L "$MANIFEST" ]]; then
                echo "manifest 경로 충돌로 이전 manifest를 복원하지 못했습니다: $MANIFEST" >&2
                rollback_failed=1
            elif ! mv "$MANIFEST_BACKUP" "$MANIFEST"; then
                echo "이전 manifest 복원 실패: $MANIFEST" >&2
                rollback_failed=1
            fi
        fi
    fi
    for ((i=0; i<${#MANAGED_CODEX_HOMES[@]}; i++)); do
        [[ "${AGENTS_TOUCHED[$i]}" == "1" ]] || continue
        agents_file="${MANAGED_CODEX_HOMES[$i]}/AGENTS.md"
        attempt_backup="${AGENTS_ATTEMPT_BACKUPS[$i]}"
        if [[ "${AGENTS_ORIGINALLY_EXISTS[$i]}" == "1"
            && -n "$attempt_backup" && -f "$attempt_backup" ]]; then
            if [[ "${AGENTBOARD_TEST_FORCE_AGENTS_RESTORE_FAILURE:-}" == "$i" ]]; then
                echo "AGENTS 복원 실패 주입: $agents_file" >&2
                rollback_failed=1
            elif [[ -L "$agents_file" || -d "$agents_file" ]]; then
                echo "AGENTS 경로 충돌로 기존 지침을 복원하지 못했습니다: $agents_file" >&2
                rollback_failed=1
            elif ! cp -p "$attempt_backup" "$agents_file"; then
                echo "기존 AGENTS 지침 복원 실패: $agents_file" >&2
                rollback_failed=1
            fi
        elif [[ "${AGENTS_ORIGINALLY_EXISTS[$i]}" == "0" ]]; then
            if [[ -L "$agents_file" || -d "$agents_file" ]]; then
                echo "설치 중 생긴 비정상 AGENTS 경로를 삭제하지 않았습니다: $agents_file" >&2
                rollback_failed=1
            elif [[ -e "$agents_file" ]] && ! rm -f "$agents_file"; then
                echo "새로 추가한 AGENTS 파일 제거 실패: $agents_file" >&2
                rollback_failed=1
            fi
        fi
    done
    if [[ "$APP_REPLACED" == "1" ]]; then
        rm -rf "$APP_TARGET" || {
            echo "새 앱 제거 실패: $APP_TARGET" >&2
            rollback_failed=1
        }
        if [[ -n "$ATTEMPT_APP_BACKUP" && -e "$ATTEMPT_APP_BACKUP" ]]; then
            if ! mv "$ATTEMPT_APP_BACKUP" "$APP_TARGET"; then
                echo "이전 앱 복원 실패: $APP_TARGET" >&2
                rollback_failed=1
            fi
        elif [[ -n "$APP_BACKUP" && -e "$APP_BACKUP" ]]; then
            if ! mv "$APP_BACKUP" "$APP_TARGET"; then
                echo "원래 앱 복원 실패: $APP_TARGET" >&2
                rollback_failed=1
            fi
        fi
    fi
    if [[ "$HELPER_REPLACED" == "1" ]]; then
        if [[ -d "$HELPER_TARGET" && ! -L "$HELPER_TARGET" ]]; then
            echo "helper 경로가 디렉터리라 제거하지 않았습니다: $HELPER_TARGET" >&2
            rollback_failed=1
        elif ! rm -f "$HELPER_TARGET"; then
            echo "새 helper 제거 실패: $HELPER_TARGET" >&2
            rollback_failed=1
        fi
        if [[ -n "$ATTEMPT_HELPER_BACKUP" && ( -e "$ATTEMPT_HELPER_BACKUP" || -L "$ATTEMPT_HELPER_BACKUP" ) ]]; then
            if ! mv "$ATTEMPT_HELPER_BACKUP" "$HELPER_TARGET"; then
                echo "이전 helper 복원 실패: $HELPER_TARGET" >&2
                rollback_failed=1
            fi
        elif [[ -n "$HELPER_BACKUP" && ( -e "$HELPER_BACKUP" || -L "$HELPER_BACKUP" ) ]]; then
            if ! mv "$HELPER_BACKUP" "$HELPER_TARGET"; then
                echo "원래 helper 복원 실패: $HELPER_TARGET" >&2
                rollback_failed=1
            fi
        fi
    fi
    if [[ "$rollback_failed" == "0" ]]; then
        echo "설치 실패: 이전 상태 복원을 완료했습니다." >&2
    else
        echo "설치 실패: 일부 항목은 복원하지 못했으며 위 오류를 확인해야 합니다." >&2
    fi
}
trap restore_on_error EXIT

ATTEMPT_ROOT="$(mktemp -d "$STATE_DIR/attempt-XXXXXX")"
if [[ -f "$MANIFEST" ]]; then
    MANIFEST_BACKUP="$ATTEMPT_ROOT/previous-install.json"
    cp -p "$MANIFEST" "$MANIFEST_BACKUP"
fi

APP_STAGE_ROOT="$(mktemp -d "$APP_DIR/.agentboard-app.XXXXXX")"
APP_STAGE="$APP_STAGE_ROOT/AgentBoard.app"
ditto "$APP_SOURCE" "$APP_STAGE"
HELPER_STAGE="$(mktemp "$BIN_DIR/.agentboard-helper.XXXXXX")"
cp "$HELPER_SOURCE" "$HELPER_STAGE"
chmod 755 "$HELPER_STAGE"

if [[ -e "$APP_TARGET" ]]; then
    EXISTING_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
    EXISTING_HELPER_HASH=""
    if [[ -e "$HELPER_TARGET" || -L "$HELPER_TARGET" ]]; then
        EXISTING_HELPER_HASH="$(shasum -a 256 "$HELPER_TARGET" | awk '{print $1}')"
    fi
    MANAGED_APP=0
    if [[ "$EXISTING_BUNDLE_ID" == "app.agentboard.mac"
        && -f "$MANIFEST" ]]; then
        MANAGED_APP=1
    fi
    if [[ "$MANAGED_APP" == "1" ]]; then
        ATTEMPT_APP_BACKUP="$ATTEMPT_ROOT/previous-AgentBoard.app"
        mv "$APP_TARGET" "$ATTEMPT_APP_BACKUP"
    else
        make_backup_root
        APP_BACKUP="$BACKUP_ROOT/AgentBoard.app"
        mv "$APP_TARGET" "$APP_BACKUP"
    fi
fi

APP_REPLACED=1
mv "$APP_STAGE" "$APP_TARGET"
rmdir "$APP_STAGE_ROOT"

if [[ -e "$HELPER_TARGET" || -L "$HELPER_TARGET" ]]; then
    if [[ ! -f "$MANIFEST" ]]; then
        make_backup_root
        HELPER_BACKUP="$BACKUP_ROOT/agentboard"
        mv "$HELPER_TARGET" "$HELPER_BACKUP"
    else
        ATTEMPT_HELPER_BACKUP="$ATTEMPT_ROOT/previous-agentboard"
        mv "$HELPER_TARGET" "$ATTEMPT_HELPER_BACKUP"
    fi
fi

HELPER_REPLACED=1
mv -f "$HELPER_STAGE" "$HELPER_TARGET"

if [[ "${AGENTBOARD_TEST_FAIL_INSTALL:-}" == "after-helper" ]]; then
    echo "injected install failure after helper" >&2
    exit 97
fi

if [[ "$INSTALL_AGENTS" == "1" ]]; then
    BLOCK_TEMP="$(mktemp "${TMPDIR:-/tmp}/agentboard-block.XXXXXX")"
    sed "s|{{HELPER_PATH}}|$(printf '%s' "$HELPER_TARGET" | sed 's/[\\&|]/\\&/g')|g" \
        "$AGENTS_BLOCK_SOURCE" > "$BLOCK_TEMP"
    for ((i=0; i<${#CODEX_HOMES[@]}; i++)); do
        codex_home_path="${CODEX_HOMES[$i]}"
        managed_index="$(managed_index_for "$codex_home_path")"
        agents_file="$codex_home_path/AGENTS.md"
        if [[ -f "$agents_file" ]]; then
            AGENTS_ORIGINALLY_EXISTS[$managed_index]=1
            attempt_backup="$ATTEMPT_ROOT/AGENTS-$managed_index.md"
            cp -p "$agents_file" "$attempt_backup"
            AGENTS_ATTEMPT_BACKUPS[$managed_index]="$attempt_backup"
            if [[ -z "${AGENTS_PERMANENT_BACKUPS[$managed_index]}" ]]; then
                make_backup_root
                permanent_backup="$BACKUP_ROOT/AGENTS-$managed_index.md"
                cp -p "$agents_file" "$permanent_backup"
                AGENTS_PERMANENT_BACKUPS[$managed_index]="$permanent_backup"
            fi
        fi
        mkdir -p "$codex_home_path"
        AGENTS_TOUCHED[$managed_index]=1
        agents_result="$("$HELPER_BIN" agents-install \
            --file "$agents_file" --block "$BLOCK_TEMP")"
        current_separator="${agents_result#separator=}"
        prior_separator="${AGENTS_SEPARATOR_VALUES[$managed_index]:-0}"
        if [[ -n "$prior_separator" && "$current_separator" == "0" ]]; then
            current_separator="$prior_separator"
        fi
        AGENTS_SEPARATOR_VALUES[$managed_index]="$current_separator"
        AGENTS_OWNED_VALUES[$managed_index]=1
    done
    rm -f "$BLOCK_TEMP"
fi

if [[ "${AGENTBOARD_TEST_FAIL_INSTALL:-}" == "after-agents" ]]; then
    echo "injected install failure after AGENTS" >&2
    exit 97
fi

HELPER_HASH="$(shasum -a 256 "$HELPER_TARGET" | awk '{print $1}')"
MANIFEST_TOUCHED=1
MANIFEST_XML="$(mktemp "$STATE_DIR/manifest.XXXXXX")"
plutil -create xml1 "$MANIFEST_XML"
plutil -insert version -integer 2 "$MANIFEST_XML"
plutil -insert appTarget -string "$APP_TARGET" "$MANIFEST_XML"
plutil -insert helperTarget -string "$HELPER_TARGET" "$MANIFEST_XML"
plutil -insert appBackup -string "$APP_BACKUP" "$MANIFEST_XML"
plutil -insert helperBackup -string "$HELPER_BACKUP" "$MANIFEST_XML"
plutil -insert helperHash -string "$HELPER_HASH" "$MANIFEST_XML"
plutil -insert codexHomeCount -integer "${#MANAGED_CODEX_HOMES[@]}" "$MANIFEST_XML"
for ((i=0; i<${#MANAGED_CODEX_HOMES[@]}; i++)); do
    plutil -insert "codexHome${i}Path" -string "${MANAGED_CODEX_HOMES[$i]}" "$MANIFEST_XML"
    plutil -insert "codexHome${i}AgentsLeadingSeparator" \
        -integer "${AGENTS_SEPARATOR_VALUES[$i]:-0}" "$MANIFEST_XML"
    plutil -insert "codexHome${i}AgentsOwned" \
        -integer "${AGENTS_OWNED_VALUES[$i]:-0}" "$MANIFEST_XML"
    plutil -insert "codexHome${i}AgentsBackup" \
        -string "${AGENTS_PERMANENT_BACKUPS[$i]}" "$MANIFEST_XML"
done
MANIFEST_JSON="$(mktemp "$STATE_DIR/manifest.XXXXXX.json")"
plutil -convert json -o "$MANIFEST_JSON" "$MANIFEST_XML"
chmod 600 "$MANIFEST_JSON"
mv "$MANIFEST_JSON" "$MANIFEST"
rm -f "$MANIFEST_XML"
rm -rf "$ATTEMPT_ROOT"

trap - EXIT
echo "설치 완료. 실행: open \"$APP_TARGET\""
echo "제거: \"$UNINSTALL_SCRIPT\" --yes"
