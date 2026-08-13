#!/usr/bin/env bash
set -euo pipefail

readonly MODULE="github.com/metacubex/mihomo"
readonly EXPECTED_VERSION="v1.19.29"
readonly SING_MODULE="github.com/metacubex/sing"
readonly EXPECTED_SING_VERSION="v0.5.7"
readonly PATCHED_SING_DIR="${PATCHED_SING_DIR:?Run prepare-ios-sing.sh first and pass its output as PATCHED_SING_DIR}"
readonly SOURCE_REL="common/pool/alloc.go"
readonly TEST_REL="common/pool/oversize_pool_test.go"
readonly CONFIG_REL="config/config.go"
readonly HISTORY_REL="tunnel/statistic/manager.go"
readonly HISTORY_TEST_REL="tunnel/statistic/closed_snapshot_test.go"
readonly EXPECTED_SOURCE_SHA="acfdffbbd6050aa0481fe4ea60f0f73a10bca6ed7a6cfbca108e2c1acb0a78f5"
readonly EXPECTED_PATCHED_SHA="743d8bd6d5990bffc6c4e3bcca85b076f57d5065032495d335d65f02d10fdb44"
readonly EXPECTED_TEST_SHA="89c8f16770938f8ee4f7503df39e6139620fdacfdcf9a52a5b7eef0977dcb0df"
readonly EXPECTED_CONFIG_SHA="7f5d6202bc741985ba2c05d2dbafb3e284cb0e51960b9e407033bd9b2eb3207f"
readonly EXPECTED_CONFIG_PATCHED_SHA="be0c65c04f0a97e3efc57527b6c3e3affadd7dfc752587ac6b8f371caf0b6ae0"
readonly EXPECTED_HISTORY_SOURCE_SHA="508daa254d05b6414e899e4eb154cb3b83572d6223e5662da9463728cb588886"
readonly EXPECTED_HISTORY_PATCHED_SHA="179b38a46b37a6ce04dc28b7bff3a70443b2bc1e6f1d5a6a56a774c51ae8e8d5"
readonly EXPECTED_HISTORY_TEST_SHA="b27fab6962dbdad97ab7b8d24504e9a636e3e7813a0a5118f77eeed5f7c0522c"
readonly PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.29-oversize-buffer-pool.patch"
readonly CONFIG_PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.29-progressive-config-parse.patch"
readonly HISTORY_PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.29-connection-close-queue.patch"
readonly HISTORY_TEST_PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.29-connection-close-queue-test.patch"
readonly PATCHED_DIR="${RUNNER_TEMP:?}/mihomo-v1.19.29-ios-oversize-pool-v1"

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
check_sha256 "$EXPECTED_CONFIG_SHA" "$SOURCE_DIR/$CONFIG_REL"
check_sha256 "$EXPECTED_HISTORY_SOURCE_SHA" "$SOURCE_DIR/$HISTORY_REL"

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
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --check --whitespace=error-all "$CONFIG_PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --whitespace=error-all "$CONFIG_PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --check --whitespace=error-all "$HISTORY_PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --whitespace=error-all "$HISTORY_PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --check --whitespace=error-all "$HISTORY_TEST_PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --whitespace=error-all "$HISTORY_TEST_PATCH_FILE"
check_sha256 "$EXPECTED_PATCHED_SHA" "$PATCHED_DIR/$SOURCE_REL"
check_sha256 "$EXPECTED_TEST_SHA" "$PATCHED_DIR/$TEST_REL"
check_sha256 "$EXPECTED_CONFIG_PATCHED_SHA" "$PATCHED_DIR/$CONFIG_REL"
check_sha256 "$EXPECTED_HISTORY_PATCHED_SHA" "$PATCHED_DIR/$HISTORY_REL"
check_sha256 "$EXPECTED_HISTORY_TEST_SHA" "$PATCHED_DIR/$HISTORY_TEST_REL"

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
