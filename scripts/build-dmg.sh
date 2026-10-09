#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "不支持的架构：${ARCH}（请选择 arm64 或 x86_64）" >&2; exit 1 ;;
esac

APP="dist/iTimer.app"
if [ ! -d "$APP" ]; then
  echo "请先运行 ./scripts/build-app.sh release $ARCH" >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "应用版本号必须为 x.y.z：$VERSION" >&2
  exit 1
fi
ACTUAL_ARCH="$(lipo -archs "$APP/Contents/MacOS/iTimer")"
if [ "$ACTUAL_ARCH" != "$ARCH" ]; then
  echo "应用架构是 ${ACTUAL_ARCH}，不能打包为 $ARCH" >&2
  exit 1
fi
codesign --verify --strict "$APP"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/itimer-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/iTimer.app"
ln -s /Applications "$STAGING/Applications"
DMG="dist/iTimer-${VERSION}-macos-${ARCH}.dmg"
hdiutil create -volname "iTimer ${VERSION} (${ARCH})" \
  -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
echo "built $DMG"
