#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_GO_VERSION="go1.25.4"
readonly EXPECTED_OTHER_BEFORE="676c4b37840f9f4b842d0a1e4f433de27ae80545a9537c139ff1d74183554d10"
readonly EXPECTED_OTHER_AFTER="8fda268f0e83143428b3694a41c3af08940b695dc61745774147c171ef1ecc46"
readonly EXPECTED_IOS_AFTER="c0c35beff7780293bbdb2fd212ed0598a628735276f2cbd9202e64472b3c3186"

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

if [[ "$(go env GOVERSION)" != "$EXPECTED_GO_VERSION" ]]; then
  echo "This patch requires $EXPECTED_GO_VERSION; found $(go env GOVERSION)" >&2
  exit 1
fi
if [[ "$(go env GOHOSTOS)" != "darwin" ]]; then
  echo "This patch must be prepared on a macOS runner" >&2
  exit 1
fi

readonly BASE_GOROOT="$(go env GOROOT)"
readonly OTHER_REL="src/internal/cpu/cpu_arm64_other.go"
readonly IOS_REL="src/internal/cpu/cpu_arm64_ios.go"
readonly PATCHED_GOROOT="${RUNNER_TEMP:?}/go1.25.4-ios-crypto-v1"
readonly PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/toolchain-patches/go1.25.4-ios-arm64-crypto.patch"

check_sha256 "$EXPECTED_OTHER_BEFORE" "$BASE_GOROOT/$OTHER_REL"
if [[ -e "$BASE_GOROOT/$IOS_REL" ]]; then
  echo "Unexpected source file already exists: $BASE_GOROOT/$IOS_REL" >&2
  exit 1
fi
if [[ -e "$PATCHED_GOROOT" ]]; then
  echo "Patched GOROOT already exists: $PATCHED_GOROOT" >&2
  exit 1
fi

/usr/bin/ditto "$BASE_GOROOT" "$PATCHED_GOROOT"
git -c core.autocrlf=false -C "$PATCHED_GOROOT" \
  apply --check --unidiff-zero --whitespace=error-all "$PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_GOROOT" \
  apply --unidiff-zero --whitespace=error-all "$PATCH_FILE"

check_sha256 "$EXPECTED_OTHER_AFTER" "$PATCHED_GOROOT/$OTHER_REL"
check_sha256 "$EXPECTED_IOS_AFTER" "$PATCHED_GOROOT/$IOS_REL"

export GOROOT="$PATCHED_GOROOT"
export PATH="$GOROOT/bin:$PATH"
export GOTOOLCHAIN=local
export GOCACHE="$RUNNER_TEMP/go-build-go1.25.4-ios-crypto-v1"

IOS_CPU_FILES="$(GOOS=ios GOARCH=arm64 CGO_ENABLED=0 \
  go list -f '{{range .GoFiles}}{{println .}}{{end}}' internal/cpu)"
grep -qx 'cpu_arm64_ios.go' <<<"$IOS_CPU_FILES"
if grep -qx 'cpu_arm64_other.go' <<<"$IOS_CPU_FILES"; then
  echo "The generic ARM64 CPU initializer is still selected for iOS" >&2
  exit 1
fi

GOOS=ios GOARCH=arm64 CGO_ENABLED=0 \
  go list -export crypto/aes crypto/cipher >/dev/null

echo "GOROOT=$GOROOT" >> "$GITHUB_ENV"
echo "GOTOOLCHAIN=$GOTOOLCHAIN" >> "$GITHUB_ENV"
echo "GOCACHE=$GOCACHE" >> "$GITHUB_ENV"
echo "$GOROOT/bin" >> "$GITHUB_PATH"
