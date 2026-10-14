#!/usr/bin/env bash
# Builds libgifski as a universal (arm64 + x86_64) static library for macOS 14+.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/gifski"
OUT="$ROOT/Vendor/lib"
export MACOSX_DEPLOYMENT_TARGET=14.0

if [ ! -f "$SRC/Cargo.toml" ]; then
  git -C "$ROOT" submodule update --init --recursive
fi

ARCHS=(${GIFSKI_ARCHS:-aarch64-apple-darwin x86_64-apple-darwin})
LIBS=()
for target in "${ARCHS[@]}"; do
  rustup target add "$target" >/dev/null 2>&1 || true
  cargo build --manifest-path "$SRC/Cargo.toml" --release --lib \
    --no-default-features --features gifsicle --target "$target"
  LIBS+=("$SRC/target/$target/release/libgifski.a")
done

mkdir -p "$OUT"
lipo -create "${LIBS[@]}" -output "$OUT/libgifski.a"
cp "$SRC/gifski.h" "$ROOT/Sources/CGifski/include/gifski.h"
echo "Built $OUT/libgifski.a ($(lipo -archs "$OUT/libgifski.a"))"
