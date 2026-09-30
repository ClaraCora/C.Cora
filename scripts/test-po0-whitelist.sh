#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cora-po0-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$ROOT/Shared/PO0Whitelist.swift" \
  "$ROOT/Cora/Core/PO0WhitelistStore.swift" \
  "$ROOT/Tests/PO0WhitelistTests.swift" \
  -o "$TEST_DIR/po0-tests"
"$TEST_DIR/po0-tests"
