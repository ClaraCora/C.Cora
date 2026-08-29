#!/usr/bin/env bash
set -euo pipefail

readonly MODULE="github.com/metacubex/sing"
readonly EXPECTED_VERSION="v0.5.7"
readonly ALLOC_SOURCE_REL="common/buf/alloc.go"
readonly BUFFER_SOURCE_REL="common/buf/buffer.go"
readonly TEST_REL="common/buf/oversize_pool_test.go"
readonly EXPECTED_ALLOC_SOURCE_SHA="c8033e748f43cd1813cd56ef20fb9576f7c0c301f468046398fe8b92c196afbd"
readonly EXPECTED_BUFFER_SOURCE_SHA="52f5b5d03d238665a9013bc5c4ea26ec9ca575a8db0d70df76a1410f86bb24fa"
readonly EXPECTED_ALLOC_PATCHED_SHA="8ad6d58e0007d8a6db9ab6fcc37da00482e2e18e86dade8d0d1650ff837cbffa"
readonly EXPECTED_BUFFER_PATCHED_SHA="5c63a04120be7924e4a6277638e4e04609a0292536772f31cd3977fcbf773148"
readonly EXPECTED_TEST_SHA="fbf73ae2ae4e08b11451eb13dd9f1d4005f4ede94f7e4b5e067feb9fbb56226f"
readonly PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/sing-v0.5.7-oversize-buffer-pool.patch"
readonly PATCHED_DIR="${RUNNER_TEMP:?}/sing-v0.5.7-ios-oversize-pool-v1"

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
check_sha256 "$EXPECTED_ALLOC_SOURCE_SHA" "$SOURCE_DIR/$ALLOC_SOURCE_REL"
check_sha256 "$EXPECTED_BUFFER_SOURCE_SHA" "$SOURCE_DIR/$BUFFER_SOURCE_REL"

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
check_sha256 "$EXPECTED_ALLOC_PATCHED_SHA" "$PATCHED_DIR/$ALLOC_SOURCE_REL"
check_sha256 "$EXPECTED_BUFFER_PATCHED_SHA" "$PATCHED_DIR/$BUFFER_SOURCE_REL"
check_sha256 "$EXPECTED_TEST_SHA" "$PATCHED_DIR/$TEST_REL"

go mod edit -replace="$MODULE@$EXPECTED_VERSION=$PATCHED_DIR"
readonly RESOLUTION="$(go list -m -f '{{.Version}}|{{if .Replace}}{{.Replace.Dir}}{{end}}' "$MODULE")"
if [[ "$RESOLUTION" != "$EXPECTED_VERSION|$PATCHED_DIR" ]]; then
  echo "Unexpected patched module resolution: $RESOLUTION" >&2
  exit 1
fi

echo "Prepared $MODULE $EXPECTED_VERSION at $PATCHED_DIR" >&2
printf '%s\n' "$PATCHED_DIR"
