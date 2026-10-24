#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cora-chain-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$ROOT/Shared/RuntimeConfigurationSnapshot.swift" \
  "$ROOT/Cora/Core/ProxyChainConfiguration.swift" \
  "$ROOT/Tests/ProxyChainConfigurationTests.swift" \
  -o "$TEST_DIR/chain-tests"
"$TEST_DIR/chain-tests"
