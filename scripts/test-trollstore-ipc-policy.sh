#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cora-trollstore-ipc-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$ROOT/CoraTunnel/TrollStoreIPCRequestPolicy.swift" \
  "$ROOT/Tests/TrollStoreIPCRequestPolicyTests.swift" \
  -o "$BUILD_DIR/trollstore-ipc-policy-tests"
"$BUILD_DIR/trollstore-ipc-policy-tests"

xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$ROOT/CoraTunnel/TrollStoreIPCRequestPolicy.swift" \
  "$ROOT/CoraTunnel/TrollStoreFileIPCServer.swift" \
  "$ROOT/Tests/TrollStoreFileIPCServerTests.swift" \
  -o "$BUILD_DIR/trollstore-file-ipc-tests"
"$BUILD_DIR/trollstore-file-ipc-tests"
