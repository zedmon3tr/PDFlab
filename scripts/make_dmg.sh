#!/usr/bin/env bash
# 把 dist/PDFlab.app 打成 dist/PDFlab-<version>.dmg(含 Applications 快捷方式,拖入即安装)。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(bash "$ROOT/scripts/app_version.sh")"
APP="$ROOT/dist/PDFlab.app"
DMG="$ROOT/dist/PDFlab-$VERSION.dmg"

[ -d "$APP" ] || { echo "dist/PDFlab.app 不存在,先跑 make bundle" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "PDFlab" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "Built $DMG"
