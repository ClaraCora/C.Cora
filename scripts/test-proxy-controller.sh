#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cora-proxy-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$ROOT/Cora/Core/ProxyController.swift" \
  "$ROOT/Shared/ProxyDelayStore.swift" \
  "$ROOT/Tests/ProxyControllerTests.swift" \
  -o "$TEST_DIR/proxy-tests"
"$TEST_DIR/proxy-tests"
