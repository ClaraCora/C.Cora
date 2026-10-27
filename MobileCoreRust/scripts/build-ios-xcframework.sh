#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE="$ROOT/MobileCoreRust/meow-ios-ffi"
OUTPUT="$ROOT/Vendor/MeowCore.xcframework"
[[ "$(uname -s)" == Darwin ]] || { echo "macOS and Xcode are required" >&2; exit 1; }
for tool in cargo rustup xcrun xcodebuild cmake; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
cd "$ROOT/MobileCoreRust"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/cora-meow.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/headers" "$(dirname "$OUTPUT")"
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target add "$target"
  IPHONEOS_DEPLOYMENT_TARGET=18.0 cargo build --manifest-path "$CRATE/Cargo.toml" --release --locked --target "$target"
done
cp "$CRATE/include/meow_core.h" "$STAGE/headers/meow_core.h"
cat > "$STAGE/headers/module.modulemap" <<'MODULE'
module MeowCore { header "meow_core.h" export * }
MODULE
# Reject a stale checked-in ABI header instead of silently shipping a different one.
cmp "$CRATE/include/meow_core.h" "$ROOT/MobileCoreRust/include/meow_core.h"
rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
  -library "$CRATE/target/aarch64-apple-ios/release/libmeow_ios_ffi.a" -headers "$STAGE/headers" \
  -library "$CRATE/target/aarch64-apple-ios-sim/release/libmeow_ios_ffi.a" -headers "$STAGE/headers" \
  -output "$OUTPUT"
plutil -lint "$OUTPUT/Info.plist"
echo "Built $OUTPUT (iOS 18 device + arm64 simulator)"
