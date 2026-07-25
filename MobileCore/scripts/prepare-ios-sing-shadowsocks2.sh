#!/usr/bin/env bash
set -euo pipefail

readonly MODULE="github.com/metacubex/sing-shadowsocks2"
readonly EXPECTED_VERSION="v0.2.7"
readonly SING_MODULE="github.com/metacubex/sing"
readonly EXPECTED_SING_VERSION="v0.5.7"
readonly PATCHED_SING_DIR="${PATCHED_SING_DIR:?Run prepare-ios-sing.sh first and pass its output as PATCHED_SING_DIR}"
readonly SOURCE_REL="internal/shadowio/reader.go"
readonly TEST_REL="internal/shadowio/reader_reuse_test.go"
readonly EXPECTED_SOURCE_SHA="3611b8ea3960d70c2aecbf6ddf2be0dbac2358720f973429d0f36dade35f4a1d"
readonly EXPECTED_PATCHED_SHA="aa2018624b29e7f004451bc763e17cd86cd36388333f32b414a3f446844f232e"
readonly EXPECTED_TEST_SHA="ecadb6f5ffa69d5e8510ca4c4e185b23520e3033b3c223efc6cca638e6f26cc4"
readonly PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/sing-shadowsocks2-v0.2.7-length-buffer.patch"
readonly PATCHED_DIR="${RUNNER_TEMP:?}/sing-shadowsocks2-v0.2.7-ios-memory-v2"

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

case "$PATCHED_SING_DIR" in
  "$RUNNER_TEMP"/*) ;;
  *) echo "Refusing unexpected patched sing directory: $PATCHED_SING_DIR" >&2; exit 1 ;;
esac
if [[ ! -d "$PATCHED_SING_DIR" ]]; then
  echo "Patched sing directory does not exist: $PATCHED_SING_DIR" >&2
  exit 1
fi
readonly PATCHED_SING_MODULE="$(go -C "$PATCHED_SING_DIR" list -m -f '{{.Path}}')"
if [[ "$PATCHED_SING_MODULE" != "$SING_MODULE" ]]; then
  echo "Unexpected patched sing module: $PATCHED_SING_MODULE" >&2
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
check_sha256 "$EXPECTED_SOURCE_SHA" "$SOURCE_DIR/$SOURCE_REL"

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
check_sha256 "$EXPECTED_PATCHED_SHA" "$PATCHED_DIR/$SOURCE_REL"
check_sha256 "$EXPECTED_TEST_SHA" "$PATCHED_DIR/$TEST_REL"

go -C "$PATCHED_DIR" mod edit -require="$SING_MODULE@$EXPECTED_SING_VERSION"
go -C "$PATCHED_DIR" mod edit -replace="$SING_MODULE@$EXPECTED_SING_VERSION=$PATCHED_SING_DIR"
readonly SS2_SING_RESOLUTION="$(go -C "$PATCHED_DIR" list -m -f '{{.Version}}|{{if .Replace}}{{.Replace.Dir}}{{end}}' "$SING_MODULE")"
if [[ "$SS2_SING_RESOLUTION" != "$EXPECTED_SING_VERSION|$PATCHED_SING_DIR" ]]; then
  echo "Unexpected sing resolution inside patched SS2: $SS2_SING_RESOLUTION" >&2
  exit 1
fi

go mod edit -replace="$MODULE@$EXPECTED_VERSION=$PATCHED_DIR"
readonly RESOLUTION="$(go list -m -f '{{.Version}}|{{if .Replace}}{{.Replace.Dir}}{{end}}' "$MODULE")"
if [[ "$RESOLUTION" != "$EXPECTED_VERSION|$PATCHED_DIR" ]]; then
  echo "Unexpected patched module resolution: $RESOLUTION" >&2
  exit 1
fi

echo "Prepared $MODULE $EXPECTED_VERSION at $PATCHED_DIR" >&2
printf '%s\n' "$PATCHED_DIR"
