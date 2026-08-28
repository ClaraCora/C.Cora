#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MOBILE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT="$(cd "$MOBILE_ROOT/.." && pwd)"
build_kind="standard"
if [[ "${1:-}" == "--legacy" ]]; then
  build_kind="legacy"
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--legacy]" >&2
  exit 2
fi

if [[ "$build_kind" == "legacy" ]]; then
  readonly IOS_VERSION="16.4"
  readonly OUTPUT="$REPO_ROOT/VendorLegacy/Mihomo.xcframework"
else
  readonly IOS_VERSION="17.0"
  readonly OUTPUT="$REPO_ROOT/Vendor/Mihomo.xcframework"
fi

for command_name in go gomobile plutil xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

case "$OUTPUT" in
  "$REPO_ROOT/Vendor/Mihomo.xcframework"|"$REPO_ROOT/VendorLegacy/Mihomo.xcframework") ;;
  *) echo "Refusing unexpected framework path: $OUTPUT" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$OUTPUT")"
rm -rf "$OUTPUT"

cd "$MOBILE_ROOT"
MIHOMO_VERSION="$(go list -m -f '{{.Version}}' github.com/metacubex/mihomo)"
echo "Building $build_kind Mihomo.xcframework (iOS $IOS_VERSION) with mihomo $MIHOMO_VERSION"

gomobile bind \
  -iosversion="$IOS_VERSION" \
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
