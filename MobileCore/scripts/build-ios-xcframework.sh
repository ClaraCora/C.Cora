#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MOBILE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT="$(cd "$MOBILE_ROOT/.." && pwd)"
readonly OUTPUT="$REPO_ROOT/Vendor/Mihomo.xcframework"

for command_name in go gomobile plutil xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

case "$OUTPUT" in
  "$REPO_ROOT/Vendor/Mihomo.xcframework") ;;
  *) echo "Refusing unexpected framework path: $OUTPUT" >&2; exit 1 ;;
esac

mkdir -p "$REPO_ROOT/Vendor"
rm -rf "$OUTPUT"

cd "$MOBILE_ROOT"
MIHOMO_VERSION="$(go list -m -f '{{.Version}}' github.com/metacubex/mihomo)"
echo "Building Mihomo.xcframework with mihomo $MIHOMO_VERSION"

gomobile bind \
  -iosversion=17.0 \
  -tags "with_gvisor,with_low_memory" \
  -ldflags="-X github.com/metacubex/mihomo/constant.Version=${MIHOMO_VERSION}" \
  -target=ios \
  -o "$OUTPUT" \
  .

readonly DEVICE_BINARY="$OUTPUT/ios-arm64/Mihomo.framework/Mihomo"
readonly SIMULATOR_BINARY="$OUTPUT/ios-arm64_x86_64-simulator/Mihomo.framework/Mihomo"

plutil -lint "$OUTPUT/Info.plist"
test "$(xcrun lipo -archs "$DEVICE_BINARY")" = "arm64"
xcrun lipo "$SIMULATOR_BINARY" -verify_arch arm64 x86_64

echo "Built $OUTPUT"
