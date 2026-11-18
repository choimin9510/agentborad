#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${AGENTBOARD_DIST_DIR:-$ROOT/dist}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agentboard-package.XXXXXX")"
KEEP_PACKAGE_BUILD="${KEEP_PACKAGE_BUILD:-0}"

cleanup() {
    if [[ "$KEEP_PACKAGE_BUILD" == "1" ]]; then
        echo "package work: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
NAME="AgentBoard-$VERSION-universal"
STAGE="$WORK/$NAME"
ZIP="$DIST/$NAME.zip"

for arch in arm64 x86_64; do
    AGENTBOARD_ARCH="$arch" \
    AGENTBOARD_BUILD_DIR="$WORK/$arch/build" \
    AGENTBOARD_OUTPUT_DIR="$WORK/$arch/output" \
        "$ROOT/scripts/build.sh"
done

mkdir -p "$STAGE/AgentBoard.app/Contents/MacOS" "$DIST"
ditto "$WORK/arm64/output/AgentBoard.app" "$STAGE/AgentBoard.app"

lipo -create \
    "$WORK/arm64/output/AgentBoard.app/Contents/MacOS/AgentBoard" \
    "$WORK/x86_64/output/AgentBoard.app/Contents/MacOS/AgentBoard" \
    -output "$WORK/AgentBoard.universal"
mv "$WORK/AgentBoard.universal" "$STAGE/AgentBoard.app/Contents/MacOS/AgentBoard"
chmod 755 "$STAGE/AgentBoard.app/Contents/MacOS/AgentBoard"

lipo -create \
    "$WORK/arm64/build/agentboard" \
    "$WORK/x86_64/build/agentboard" \
    -output "$STAGE/agentboard"
chmod 755 "$STAGE/agentboard"

cp "$ROOT/scripts/install.sh" "$STAGE/install.sh"
cp "$ROOT/scripts/uninstall.sh" "$STAGE/uninstall.sh"
cp "$ROOT/scripts/Install.command" "$STAGE/Install.command"
cp "$ROOT/Resources/agents-block.txt" "$STAGE/agents-block.txt"
for lang in EN KO ZH-CN; do
    cp "$ROOT/Resources/Distribution-Install-$lang.md" "$STAGE/Distribution-Install-$lang.md"
done
cp "$ROOT/Resources/Distribution-Install-EN.md" "$STAGE/README.md"
cp "$ROOT/Resources/Distribution-Install-KO.md" "$STAGE/설치안내.md"
chmod 755 "$STAGE/install.sh" "$STAGE/uninstall.sh" "$STAGE/Install.command"

APP_ARCHS="$(lipo -archs "$STAGE/AgentBoard.app/Contents/MacOS/AgentBoard")"
HELPER_ARCHS="$(lipo -archs "$STAGE/agentboard")"
case " $APP_ARCHS " in *" arm64 "*) ;; *) echo "app arm64 slice missing" >&2; exit 1 ;; esac
case " $APP_ARCHS " in *" x86_64 "*) ;; *) echo "app x86_64 slice missing" >&2; exit 1 ;; esac
case " $HELPER_ARCHS " in *" arm64 "*) ;; *) echo "helper arm64 slice missing" >&2; exit 1 ;; esac
case " $HELPER_ARCHS " in *" x86_64 "*) ;; *) echo "helper x86_64 slice missing" >&2; exit 1 ;; esac

MIN_MACOS="$(plutil -extract LSMinimumSystemVersion raw -o - "$STAGE/AgentBoard.app/Contents/Info.plist")"
[[ "$MIN_MACOS" == "13.0" ]] || {
    echo "unexpected minimum macOS version: $MIN_MACOS" >&2
    exit 1
}

codesign --force --deep --sign - "$STAGE/AgentBoard.app" >/dev/null
codesign --force --sign - "$STAGE/agentboard" >/dev/null
codesign --verify --deep --strict "$STAGE/AgentBoard.app"
codesign --verify --strict "$STAGE/agentboard"

APP_HASH="$(shasum -a 256 "$STAGE/AgentBoard.app/Contents/MacOS/AgentBoard" | awk '{print $1}')"
HELPER_HASH="$(shasum -a 256 "$STAGE/agentboard" | awk '{print $1}')"
PACKAGE_MARKER="$STAGE/agentboard-package.json"
MARKER_XML="$WORK/agentboard-package.plist"
plutil -create xml1 "$MARKER_XML"
plutil -insert format -string prebuilt "$MARKER_XML"
plutil -insert version -string "$VERSION" "$MARKER_XML"
plutil -insert architectures -string "arm64 x86_64" "$MARKER_XML"
plutil -insert minimumMacOS -string "$MIN_MACOS" "$MARKER_XML"
plutil -insert appExecutableSha256 -string "$APP_HASH" "$MARKER_XML"
plutil -insert helperSha256 -string "$HELPER_HASH" "$MARKER_XML"
plutil -convert json -o "$PACKAGE_MARKER" "$MARKER_XML"
rm -f "$MARKER_XML"

for required in \
    AgentBoard.app/Contents/Info.plist \
    AgentBoard.app/Contents/MacOS/AgentBoard \
    agentboard install.sh uninstall.sh Install.command \
    agents-block.txt README.md Distribution-Install-EN.md Distribution-Install-KO.md Distribution-Install-ZH-CN.md 설치안내.md agentboard-package.json; do
    [[ -e "$STAGE/$required" ]] || {
        echo "package payload missing: $required" >&2
        exit 1
    }
done
PRIVATE_PAYLOAD="$(find "$STAGE" -type f \( \
    -name '*.sqlite3' -o -name '*.sqlite3-wal' -o -name '*.sqlite3-shm' \
    -o -name '*.jsonl' -o -name 'auth.json' \
\) -print -quit)"
[[ -z "$PRIVATE_PAYLOAD" ]] || {
    echo "private/local payload must not be packaged: $PRIVATE_PAYLOAD" >&2
    exit 1
}

rm -f "$ZIP"
ditto -c -k --keepParent --norsrc --noextattr "$STAGE" "$ZIP"

echo "package: $ZIP"
echo "app archs: $APP_ARCHS"
echo "helper archs: $HELPER_ARCHS"
