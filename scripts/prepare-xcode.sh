#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly MOBILE_ROOT="$REPO_ROOT/MobileCore"
readonly STANDARD_FRAMEWORK="$REPO_ROOT/Vendor/Mihomo.xcframework"
readonly LEGACY_FRAMEWORK="$REPO_ROOT/VendorLegacy/Mihomo.xcframework"
readonly MOBILE_VERSION="v0.0.0-20260611195102-4dd8f1dbf5d2"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

rebuild_core=false
case "${1:-}" in
  "") ;;
  --rebuild-core) rebuild_core=true ;;
  *)
    echo "Usage: bash scripts/prepare-xcode.sh [--rebuild-core]" >&2
    exit 2
    ;;
esac

for command_name in xcodebuild xcodegen; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

build_core=false
if [[ ! -d "$STANDARD_FRAMEWORK" || ! -d "$LEGACY_FRAMEWORK" || "$rebuild_core" == "true" ]]; then
  build_core=true
fi

if [[ "$build_core" == "true" ]]; then
  for command_name in go git; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Missing required command: $command_name" >&2
      exit 1
    fi
  done

  readonly TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cora-xcode.XXXXXX")"
  readonly GO_MOD_BACKUP="$TEMP_ROOT/go.mod"
  readonly GO_SUM_BACKUP="$TEMP_ROOT/go.sum"

  cp "$MOBILE_ROOT/go.mod" "$GO_MOD_BACKUP"
  cp "$MOBILE_ROOT/go.sum" "$GO_SUM_BACKUP"

  cleanup() {
    cp "$GO_MOD_BACKUP" "$MOBILE_ROOT/go.mod"
    cp "$GO_SUM_BACKUP" "$MOBILE_ROOT/go.sum"
    case "$TEMP_ROOT" in
      "${TMPDIR:-/tmp}"/cora-xcode.*) rm -rf "$TEMP_ROOT" ;;
      *) echo "Refusing unexpected temporary path: $TEMP_ROOT" >&2 ;;
    esac
  }
  trap cleanup EXIT

  export RUNNER_TEMP="$TEMP_ROOT"
  export GITHUB_WORKSPACE="$REPO_ROOT"
  export GITHUB_ENV="$TEMP_ROOT/github-env"
  export GITHUB_PATH="$TEMP_ROOT/github-path"
  touch "$GITHUB_ENV" "$GITHUB_PATH"

  echo "Installing pinned gomobile tools"
  go install "golang.org/x/mobile/cmd/gomobile@$MOBILE_VERSION"
  go install "golang.org/x/mobile/cmd/gobind@$MOBILE_VERSION"
  export PATH="$(go env GOPATH)/bin:$PATH"

  cd "$MOBILE_ROOT"
  # This script exports the patched Go toolchain into the current shell.
  source scripts/prepare-ios-go-toolchain.sh

  PATCHED_SING="$(bash scripts/prepare-ios-sing.sh)"
  PATCHED_MIHOMO="$(PATCHED_SING_DIR="$PATCHED_SING" bash scripts/prepare-ios-mihomo.sh)"
  PATCHED_GVISOR="$(bash scripts/prepare-ios-gvisor.sh)"
  PATCHED_SING_TUN="$(bash scripts/prepare-ios-sing-tun.sh)"
  PATCHED_SS2="$(PATCHED_SING_DIR="$PATCHED_SING" bash scripts/prepare-ios-sing-shadowsocks2.sh)"
  export PATCHED_SING PATCHED_MIHOMO PATCHED_GVISOR PATCHED_SING_TUN PATCHED_SS2

  bash scripts/build-ios-xcframework.sh
  bash scripts/build-ios-xcframework.sh --legacy
else
  echo "Reusing $STANDARD_FRAMEWORK and $LEGACY_FRAMEWORK"
  echo "Use --rebuild-core after MobileCore or dependency changes."
fi

cd "$REPO_ROOT"
xcodegen generate

echo
echo "Xcode project is ready: $REPO_ROOT/Cora.xcodeproj"
echo "Open it and select the same development team for Cora, CoraTunnel, CoraControl, CoraLegacy, and CoraTunnelLegacy."
