#!/usr/bin/env bash
# Prints an SDK path that can compile SwiftUI with the active toolchain.
# Command Line Tools may ship SDKs whose SwiftUI declares @State as a macro without shipping
# the SwiftUIMacros plugin; pick the newest SDK that doesn't need it. Full Xcode needs nothing.
set -euo pipefail
if [ -n "${SDKROOT:-}" ]; then echo "$SDKROOT"; exit 0; fi
DEV="$(xcode-select -p)"
if [ -d "$DEV/Platforms" ] || [ -e "$DEV/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
  xcrun --sdk macosx --show-sdk-path
  exit 0
fi
for sdk in $(ls -d "$DEV"/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
  iface=$(ls "$sdk"/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/*-apple-macos.swiftinterface 2>/dev/null | head -1 || true)
  if [ -z "$iface" ] || ! grep -q "StateMacro" "$iface"; then echo "$sdk"; exit 0; fi
done
echo "error: no usable macOS SDK found (install Xcode, or Command Line Tools with a macOS 26 SDK)" >&2
exit 1
