#!/usr/bin/env bash
# Builds GifTrim.app (universal, ad-hoc signed, hardened runtime) into build/.
# Usage: scripts/build-app.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-${VERSION:-0.1.0}}"
BUILD_NUM="${BUILD_NUM:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS=(${APP_ARCHS:-arm64 x86_64})
OUT="$ROOT/build"
APP="$OUT/GifTrim.app"

[ -f Vendor/lib/libgifski.a ] || scripts/build-gifski.sh

SDKROOT="$(scripts/sdk.sh)"
export SDKROOT
echo "SDK: $SDKROOT"

BINS=()
CLIS=()
for arch in "${ARCHS[@]}"; do
  for product in GifTrim giftrim-cli; do
    swift build -c release --product "$product" --triple "$arch-apple-macosx14.0" \
      --scratch-path "$OUT/.swiftpm-$arch"
  done
  BIN_DIR="$(swift build -c release --product GifTrim --triple "$arch-apple-macosx14.0" \
    --scratch-path "$OUT/.swiftpm-$arch" --show-bin-path)"
  BINS+=("$BIN_DIR/GifTrim")
  CLIS+=("$BIN_DIR/giftrim-cli")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/GifTrim"
# Command-line tool + MCP server, shipped inside the app (see README "For AI agents").
lipo -create "${CLIS[@]}" -output "$APP/Contents/Helpers/giftrim"
lipo -create "${CLIS[@]}" -output "$OUT/giftrim"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" \
  Sources/GifTrim/Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET="$OUT/AppIcon.iconset"
if [ ! -f "$OUT/AppIcon.icns" ]; then
  rm -rf "$ICONSET"
  swift scripts/make-icon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"
  rm -rf "$ICONSET"
fi
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/" 2>/dev/null || true

# Sign nested code first, then the bundle.
codesign --force --options runtime --timestamp=none --identifier com.swsususu.giftrim.cli \
  --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/Helpers/giftrim"
codesign --force --options runtime --timestamp=none --identifier com.swsususu.giftrim.cli \
  --sign "${CODESIGN_IDENTITY:--}" "$OUT/giftrim"
codesign --force --options runtime --timestamp=none \
  --entitlements Sources/GifTrim/Resources/GifTrim.entitlements \
  --sign "${CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/GifTrim"))"
