#!/usr/bin/env bash
set -euo pipefail

readonly MODULE="github.com/metacubex/mihomo"
readonly EXPECTED_VERSION="v1.19.29"
readonly SING_MODULE="github.com/metacubex/sing"
readonly EXPECTED_SING_VERSION="v0.5.7"
readonly PATCHED_SING_DIR="${PATCHED_SING_DIR:?Run prepare-ios-sing.sh first and pass its output as PATCHED_SING_DIR}"
readonly POOL_SOURCE_REL="common/pool/alloc.go"
readonly POOL_TEST_REL="common/pool/oversize_pool_test.go"
readonly EXPECTED_POOL_SOURCE_SHA="acfdffbbd6050aa0481fe4ea60f0f73a10bca6ed7a6cfbca108e2c1acb0a78f5"
readonly EXPECTED_POOL_PATCHED_SHA="743d8bd6d5990bffc6c4e3bcca85b076f57d5065032495d335d65f02d10fdb44"
readonly EXPECTED_POOL_TEST_SHA="89c8f16770938f8ee4f7503df39e6139620fdacfdcf9a52a5b7eef0977dcb0df"
readonly SS_SOURCE_REL="adapter/outbound/shadowsocks.go"
readonly SS_TEST_REL="adapter/outbound/shadowsocks_memory_test.go"
readonly EXPECTED_SS_SOURCE_SHA="a1e1242e754c16aec96b08178bbef1f25d92c3fe8da03486aff11ba4e95d6d54"
readonly EXPECTED_SS_PATCHED_SHA="c9db8b7f6386ccff8e1a9332693de83b25710e9be80e22ae103a8fe7f1366ddd"
readonly EXPECTED_SS_TEST_SHA="f0b6d6ce22ec6c1c004f73c949d8647f8757662a6074876bd14b0ba367f276d8"
readonly PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.29-oversize-buffer-pool.patch"
readonly PATCHED_DIR="${RUNNER_TEMP:?}/mihomo-v1.19.29-ios-memory-v2"

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
check_sha256 "$EXPECTED_POOL_SOURCE_SHA" "$SOURCE_DIR/$POOL_SOURCE_REL"
check_sha256 "$EXPECTED_SS_SOURCE_SHA" "$SOURCE_DIR/$SS_SOURCE_REL"

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
check_sha256 "$EXPECTED_POOL_PATCHED_SHA" "$PATCHED_DIR/$POOL_SOURCE_REL"
check_sha256 "$EXPECTED_POOL_TEST_SHA" "$PATCHED_DIR/$POOL_TEST_REL"
check_sha256 "$EXPECTED_SS_PATCHED_SHA" "$PATCHED_DIR/$SS_SOURCE_REL"
check_sha256 "$EXPECTED_SS_TEST_SHA" "$PATCHED_DIR/$SS_TEST_REL"

go -C "$PATCHED_DIR" mod edit -require="$SING_MODULE@$EXPECTED_SING_VERSION"
go -C "$PATCHED_DIR" mod edit -replace="$SING_MODULE@$EXPECTED_SING_VERSION=$PATCHED_SING_DIR"
readonly MIHOMO_SING_RESOLUTION="$(go -C "$PATCHED_DIR" list -m -f '{{.Version}}|{{if .Replace}}{{.Replace.Dir}}{{end}}' "$SING_MODULE")"
if [[ "$MIHOMO_SING_RESOLUTION" != "$EXPECTED_SING_VERSION|$PATCHED_SING_DIR" ]]; then
  echo "Unexpected sing resolution inside patched Mihomo: $MIHOMO_SING_RESOLUTION" >&2
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
