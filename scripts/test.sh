#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${AGENTBOARD_BUILD_DIR:-$ROOT/.build}"
MODULE_CACHE="$BUILD/module-cache"
CORE="$BUILD/libAgentBoardCore.a"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx13.0"

mkdir -p "$BUILD" "$MODULE_CACHE"

xcrun swiftc -target "$TARGET" -module-cache-path "$MODULE_CACHE" \
    -emit-library -static -emit-module -module-name AgentBoardCore \
    "$ROOT"/Sources/AgentBoardCore/*.swift \
    -o "$CORE" \
    -emit-module-path "$BUILD/AgentBoardCore.swiftmodule" \
    -lsqlite3 -framework CoreServices

xcrun swiftc -target "$TARGET" -module-cache-path "$MODULE_CACHE" \
    -I "$BUILD" \
    "$ROOT/Tests/AgentBoardCoreTests/TestMain.swift" "$CORE" \
    -o "$BUILD/AgentBoardTests" \
    -lsqlite3 -framework CoreServices

"$BUILD/AgentBoardTests"

xcrun swiftc -target "$TARGET" -module-cache-path "$MODULE_CACHE" \
    -I "$BUILD" \
    "$ROOT/Sources/AgentBoardApp/LaunchOptions.swift" \
    "$ROOT/Sources/AgentBoardApp/BoardViewModel.swift" \
    "$ROOT/Tests/AgentBoardAppTests/main.swift" "$CORE" \
    -o "$BUILD/AgentBoardAppTests" \
    -lsqlite3 -framework CoreServices

"$BUILD/AgentBoardAppTests"

xcrun swiftc -target "$TARGET" -module-cache-path "$MODULE_CACHE" \
    -I "$BUILD" \
    "$ROOT/Sources/AgentBoardApp/LaunchOptions.swift" \
    "$ROOT/Sources/AgentBoardApp/BoardViewModel.swift" \
    "$ROOT/Sources/AgentBoardApp/BoardView.swift" \
    "$ROOT/Sources/AgentBoardApp/PanelController.swift" \
    "$ROOT/Sources/AgentBoardApp/RenameTitleCoordinator.swift" \
    "$ROOT/Sources/AgentBoardApp/ConversationNavigator.swift" \
    "$ROOT/Tests/AgentBoardHitTestTests/main.swift" "$CORE" \
    -o "$BUILD/AgentBoardHitTests" \
    -framework AppKit -framework SwiftUI \
    -lsqlite3 -framework CoreServices

"$BUILD/AgentBoardHitTests"

xcrun swiftc -target "$TARGET" -module-cache-path "$MODULE_CACHE" \
    -I "$BUILD" \
    "$ROOT/Sources/agentboard/main.swift" "$CORE" \
    -o "$BUILD/agentboard" \
    -lsqlite3 -framework CoreServices

CLI_PREFIX="$(CODEX_THREAD_ID=11111111-1111-4111-8111-111111111111 \
    CMUX_WINDOW_ID=10000000-0000-4000-8000-000000000001 \
    CMUX_WORKSPACE_ID=20000000-0000-4000-8000-000000000002 \
    CMUX_SURFACE_ID=30000000-0000-4000-8000-000000000003 \
    CMUX_SOCKET_PATH=/tmp/agentboard-test.sock \
    "$BUILD/agentboard" report --json \
    '{"title":"테스트","state":"running","steps":[{"id":"one","title":"작업","status":"inProgress"}],"summary":"진행 중"}')"

case "$CLI_PREFIX" in
    AGENTBOARD_EVENT_V1\ *) ;;
    *) echo "report CLI did not emit the expected marker" >&2; exit 1 ;;
esac

if [[ "$CLI_PREFIX" != *'"origin"'*'"windowId":"10000000-0000-4000-8000-000000000001"'* \
    || "$CLI_PREFIX" != *'"workspaceId":"20000000-0000-4000-8000-000000000002"'* \
    || "$CLI_PREFIX" != *'"surfaceId":"30000000-0000-4000-8000-000000000003"'* ]]; then
    echo "report CLI did not emit validated cmux origin metadata" >&2
    exit 1
fi

HERDR_CLI_PREFIX="$(CODEX_THREAD_ID=11111111-1111-4111-8111-111111111111 \
    HERDR_ENV=1 \
    HERDR_WORKSPACE_ID=w1 \
    HERDR_TAB_ID=w1:t1 \
    HERDR_PANE_ID=w1:p1 \
    HERDR_SESSION=agentboard-test \
    HERDR_SOCKET_PATH=/tmp/agentboard-herdr.sock \
    "$BUILD/agentboard" report --json \
    '{"title":"테스트","state":"running","steps":[],"summary":"진행 중"}')"

if [[ "$HERDR_CLI_PREFIX" != *'"kind":"herdr"'* \
    || "$HERDR_CLI_PREFIX" != *'"paneId":"w1:p1"'* \
    || "$HERDR_CLI_PREFIX" != *'"sessionName":"agentboard-test"'* \
    || "$HERDR_CLI_PREFIX" != *'"socketPath":"/tmp/agentboard-herdr.sock"'* ]]; then
    echo "report CLI did not preserve validated Herdr origin metadata" >&2
    exit 1
fi

if CODEX_THREAD_ID=11111111-1111-4111-8111-111111111111 \
    "$BUILD/agentboard" report --json \
    '{"title":"잘못된 완료","state":"completed","steps":[{"id":"one","title":"미완료","status":"pending"}],"summary":"끝"}' \
    >/dev/null 2>&1; then
    echo "completed report with unfinished steps was accepted" >&2
    exit 1
fi

echo "CLI validation: PASS"
