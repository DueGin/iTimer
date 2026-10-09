#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
ARCH="${2:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "不支持的架构：${ARCH}（请选择 arm64 或 x86_64）" >&2; exit 1 ;;
esac
swift build -c "$CONFIG" --arch "$ARCH"
BIN="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)/iTimer"
APP="dist/iTimer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iTimer"
cp Support/Info.plist "$APP/Contents/Info.plist"
[ -f Support/iTimer.icns ] && cp Support/iTimer.icns "$APP/Contents/Resources/iTimer.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
echo "built $APP"
