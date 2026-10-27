#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cora-core-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Cora/Shared/CoreIPCCompatibility.swift" \
  "$ROOT/Cora/Core/MemoryDiagnosticAnalyzer.swift" \
  "$ROOT/Cora/Core/LogFileTailer.swift" \
  "$ROOT/Tests/CoreCompatibilityTests.swift" -o "$WORK/compatibility-tests"
"$WORK/compatibility-tests"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Cora/Core/MemoryDiagnosticAnalyzer.swift" \
  "$ROOT/Tests/MemoryDiagnosticAnalyzerTests.swift" -o "$WORK/diagnostic-tests"
"$WORK/diagnostic-tests"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Cora/Shared/CoreAtomicFile.swift" \
  "$ROOT/CoraTunnel/CoreSessionSnapshot.swift" \
  "$ROOT/Tests/CorePersistenceTests.swift" -o "$WORK/persistence-tests"
"$WORK/persistence-tests"
