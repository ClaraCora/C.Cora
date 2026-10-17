#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cora-ios-update-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$ROOT/Shared/IOSUpdateBlock.swift" \
  "$ROOT/Cora/Core/IOSUpdateBlockStore.swift" \
  "$ROOT/CoraTunnel/IOSUpdateBlockTunnelState.swift" \
  "$ROOT/Tests/IOSUpdateBlockTests.swift" \
  -o "$TEST_DIR/ios-update-tests"
"$TEST_DIR/ios-update-tests"
