#!/usr/bin/env bash
set -euo pipefail

readonly MODULE="github.com/metacubex/sing-tun"
readonly EXPECTED_VERSION="v0.4.22"
readonly PROCESSOR_SOURCE_REL="internal/fdbased_darwin/processors.go"
readonly DARWIN_STACK_SOURCE_REL="tun_darwin_gvisor.go"
readonly DARWIN_STACK_TEST_REL="tun_darwin_gvisor_test.go"
readonly EXPECTED_PROCESSOR_SOURCE_SHA="64c92b86efd20d4bc9eebd32acefd77051ceb84ab2879e701c2241a181970088"
readonly EXPECTED_DARWIN_STACK_SOURCE_SHA="232842a816568665b6739b4b9165aecea229c2d7549c8f584f8de8adc8a274a1"
readonly EXPECTED_PROCESSOR_PATCHED_SHA="ef063b883d4fff7c146044b5db31f73b74e497664645b4a786d326505b047051"
readonly EXPECTED_DARWIN_STACK_PATCHED_SHA="3d4bc2e32d4eeb99298b62310b0f126da1ce8ead3ef757a03bfc17cad426cf52"
readonly EXPECTED_DARWIN_STACK_TEST_SHA="6d7a62d602fedd3aba86093dbdbfcb4e102d515908c4b10fb10ade3153dbe910"
readonly PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/sing-tun-v0.4.22-darwin-queue.patch"
readonly PATCHED_DIR="${RUNNER_TEMP:?}/sing-tun-v0.4.22-ios-memory-v2"

check_sha256() {
  local expected="$1"
  local file="$2"
  local actual
  actual="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "SHA-256 mismatch: $file" >&2
    echo "expected=$expected actual=$actual" >&2
    exit 1
  fi
}

if [[ "$(go env GOHOSTOS)" != "darwin" ]]; then
  echo "This patch must be prepared on a macOS runner" >&2
  exit 1
fi

readonly RESOLVED_VERSION="$(go list -m -f '{{.Version}}' "$MODULE")"
readonly SOURCE_DIR="$(go list -m -f '{{.Dir}}' "$MODULE")"
if [[ "$RESOLVED_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "This patch requires $MODULE $EXPECTED_VERSION; found $RESOLVED_VERSION" >&2
  exit 1
fi
if [[ -z "$SOURCE_DIR" || ! -d "$SOURCE_DIR" ]]; then
  echo "Unable to resolve source directory for $MODULE" >&2
  exit 1
fi
check_sha256 "$EXPECTED_PROCESSOR_SOURCE_SHA" "$SOURCE_DIR/$PROCESSOR_SOURCE_REL"
check_sha256 "$EXPECTED_DARWIN_STACK_SOURCE_SHA" "$SOURCE_DIR/$DARWIN_STACK_SOURCE_REL"

case "$PATCHED_DIR" in
  "$RUNNER_TEMP"/*) ;;
  *) echo "Refusing unexpected patch destination: $PATCHED_DIR" >&2; exit 1 ;;
esac
if [[ -e "$PATCHED_DIR" ]]; then
  echo "Patched module directory already exists: $PATCHED_DIR" >&2
  exit 1
fi

/usr/bin/ditto "$SOURCE_DIR" "$PATCHED_DIR"
/bin/chmod -R u+w "$PATCHED_DIR"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --check --whitespace=error-all "$PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --whitespace=error-all "$PATCH_FILE"
check_sha256 "$EXPECTED_PROCESSOR_PATCHED_SHA" "$PATCHED_DIR/$PROCESSOR_SOURCE_REL"
check_sha256 "$EXPECTED_DARWIN_STACK_PATCHED_SHA" "$PATCHED_DIR/$DARWIN_STACK_SOURCE_REL"
check_sha256 "$EXPECTED_DARWIN_STACK_TEST_SHA" "$PATCHED_DIR/$DARWIN_STACK_TEST_REL"

go mod edit -replace="$MODULE@$EXPECTED_VERSION=$PATCHED_DIR"
readonly RESOLUTION="$(go list -m -f '{{.Version}}|{{if .Replace}}{{.Replace.Dir}}{{end}}' "$MODULE")"
if [[ "$RESOLUTION" != "$EXPECTED_VERSION|$PATCHED_DIR" ]]; then
  echo "Unexpected patched module resolution: $RESOLUTION" >&2
  exit 1
fi

echo "Prepared $MODULE $EXPECTED_VERSION at $PATCHED_DIR" >&2
printf '%s\n' "$PATCHED_DIR"
