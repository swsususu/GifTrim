#!/usr/bin/env bash
# Packages build/GifTrim.app into build/GifTrim-<version>.dmg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${VERSION:-0.1.1}}"
APP="$ROOT/build/GifTrim.app"
DMG="$ROOT/build/GifTrim_${VERSION}_universal.dmg"
[ -d "$APP" ] || "$ROOT/scripts/build-app.sh" "$VERSION"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "GifTrim" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
