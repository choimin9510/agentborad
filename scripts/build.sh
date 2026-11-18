#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${AGENTBOARD_BUILD_DIR:-$ROOT/.build}"
OUTPUT="${AGENTBOARD_OUTPUT_DIR:-$ROOT/build}"
APP="$OUTPUT/AgentBoard.app"
ARCH="${AGENTBOARD_ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "AGENTBOARD_ARCH는 arm64 또는 x86_64여야 합니다: $ARCH" >&2; exit 2 ;;
esac
TARGET="${ARCH}-apple-macosx13.0"
MODULE_CACHE="$BUILD/module-cache"
CORE="$BUILD/libAgentBoardCore.a"

mkdir -p "$BUILD" "$MODULE_CACHE" "$OUTPUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SWIFT_FLAGS=(
    -target "$TARGET"
    -module-cache-path "$MODULE_CACHE"
    -O
    -warnings-as-errors
)

xcrun swiftc "${SWIFT_FLAGS[@]}" \
    -emit-library -static -emit-module \
    -module-name AgentBoardCore \
    "$ROOT"/Sources/AgentBoardCore/*.swift \
    -o "$CORE" \
    -emit-module-path "$BUILD/AgentBoardCore.swiftmodule" \
    -lsqlite3 -framework CoreServices

xcrun swiftc "${SWIFT_FLAGS[@]}" \
    -I "$BUILD" \
    "$ROOT"/Sources/agentboard/main.swift "$CORE" \
    -o "$BUILD/agentboard" \
    -lsqlite3 -framework CoreServices

xcrun swiftc "${SWIFT_FLAGS[@]}" \
    -I "$BUILD" \
    "$ROOT"/Sources/AgentBoardApp/*.swift "$CORE" \
    -o "$APP/Contents/MacOS/AgentBoard" \
    -framework AppKit -framework SwiftUI \
    -framework CoreServices -lsqlite3

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP" >/dev/null

echo "app: $APP"
echo "helper: $BUILD/agentboard"
