#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo "This script requires macOS." >&2; exit 1; }
case "${1:-}" in ""|--rebuild-core) ;; *) echo "Usage: $0 [--rebuild-core]" >&2; exit 2;; esac
if [[ ! -d "$ROOT/Vendor/MeowCore.xcframework" || "${1:-}" == --rebuild-core ]]; then
  bash "$ROOT/MobileCoreRust/scripts/build-ios-xcframework.sh"
fi
cd "$ROOT"
xcodegen generate
echo "Select the same signing team for Cora, CoraTunnel and CoraControl in Xcode."
