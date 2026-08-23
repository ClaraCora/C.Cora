#!/usr/bin/env bash
set -euo pipefail

readonly MODULE="github.com/metacubex/mihomo"
readonly EXPECTED_VERSION="v1.19.30"
readonly SING_MODULE="github.com/metacubex/sing"
readonly EXPECTED_SING_VERSION="v0.5.7"
readonly PATCHED_SING_DIR="${PATCHED_SING_DIR:?Run prepare-ios-sing.sh first and pass its output as PATCHED_SING_DIR}"
readonly SOURCE_REL="common/pool/alloc.go"
readonly TEST_REL="common/pool/oversize_pool_test.go"
readonly CONFIG_REL="config/config.go"
readonly HISTORY_REL="tunnel/statistic/manager.go"
readonly HISTORY_TEST_REL="tunnel/statistic/closed_snapshot_test.go"
readonly DIALER_OPTIONS_REL="component/dialer/options.go"
readonly DIALER_REL="component/dialer/dialer.go"
readonly SNELL_REL="adapter/outbound/snell.go"
readonly CELLULAR_TCP_REL="component/dialer/snell_cellular_tcp.go"
readonly CELLULAR_TCP_TEST_REL="component/dialer/snell_cellular_tcp_test.go"
readonly TUNNEL_REL="tunnel/tunnel.go"
readonly RESERVED_SYNTHETIC_IP_REL="tunnel/reserved_synthetic_ip.go"
readonly RESERVED_SYNTHETIC_IP_TEST_REL="tunnel/reserved_synthetic_ip_test.go"
readonly DNS_DIRECT_REL="adapter/outbound/direct.go"
readonly DNS_HOST_REL="component/resolver/host.go"
readonly DNS_RESOLVER_REL="component/resolver/resolver.go"
readonly DNS_RUNTIME_REL="component/resolver/runtime.go"
readonly DNS_RUNTIME_TEST_REL="component/resolver/runtime_test.go"
readonly DNS_SERVICE_REL="component/resolver/service.go"
readonly DNS_SERVER_REL="dns/server.go"
readonly DNS_EXECUTOR_REL="hub/executor/executor.go"
readonly DNS_ROUTE_REL="hub/route/dns.go"
readonly DOH_ROUTE_REL="hub/route/doh.go"
readonly EXPECTED_SOURCE_SHA="acfdffbbd6050aa0481fe4ea60f0f73a10bca6ed7a6cfbca108e2c1acb0a78f5"
readonly EXPECTED_PATCHED_SHA="743d8bd6d5990bffc6c4e3bcca85b076f57d5065032495d335d65f02d10fdb44"
readonly EXPECTED_TEST_SHA="89c8f16770938f8ee4f7503df39e6139620fdacfdcf9a52a5b7eef0977dcb0df"
readonly EXPECTED_CONFIG_SHA="dfa563b5706ca58ea04d40187fe0367e173dbba82c0d229c221a537531bc532b"
readonly EXPECTED_CONFIG_PATCHED_SHA="a41d06def9ac2d44acf86dec94f4bbbd26dffba3336dfba71f675d31499ad8a0"
readonly EXPECTED_HISTORY_SOURCE_SHA="508daa254d05b6414e899e4eb154cb3b83572d6223e5662da9463728cb588886"
readonly EXPECTED_HISTORY_PATCHED_SHA="179b38a46b37a6ce04dc28b7bff3a70443b2bc1e6f1d5a6a56a774c51ae8e8d5"
readonly EXPECTED_HISTORY_TEST_SHA="b27fab6962dbdad97ab7b8d24504e9a636e3e7813a0a5118f77eeed5f7c0522c"
readonly EXPECTED_DIALER_OPTIONS_SOURCE_SHA="6225560d4f010f5db68f88dc93f61df848c6d0d3258e3183a459c185678c4e07"
readonly EXPECTED_DIALER_OPTIONS_PATCHED_SHA="00330ab908367b4484b2d2ce28c73fd1b99aba2f1d312b5be553f371caeffa51"
readonly EXPECTED_DIALER_SOURCE_SHA="1cd130049e1c8aec826d8eb5a625f4e64d2eccf6f1091b0cca2d1540ec49a531"
readonly EXPECTED_DIALER_PATCHED_SHA="2531b3155a0e8b58a300e693cbf879104037b5164d7d105c2e9cfae7c73442fa"
readonly EXPECTED_SNELL_SOURCE_SHA="2fe5b01ee473842d383a2f80d89ba079992892cf344ddb9472a64c53590cbe43"
readonly EXPECTED_SNELL_PATCHED_SHA="3d9cd57b8d9b9eb4dbe23d8c7dce5758db22f5cbb9659563adb5b379f9719f83"
readonly EXPECTED_CELLULAR_TCP_SHA="d4590f8cf6ab975c6189af5fd060fc9107bd37a46a4ecfb4598e0bf684ae1676"
readonly EXPECTED_CELLULAR_TCP_TEST_SHA="c5889973a0a896bb13ddbb7f797b46ec1078aea78af623e8ba28069ab4489aff"
readonly EXPECTED_TUNNEL_SOURCE_SHA="bd0818dddd04779aad3f078819b3ca050bd8bdce29ba57e5a377770539278596"
readonly EXPECTED_TUNNEL_PATCHED_SHA="bb784c6ea2128ac7c4a598db7de787d447c7d130471b133ab53ca3b405999b52"
readonly EXPECTED_RESERVED_SYNTHETIC_IP_SHA="a404b8c5b0bb0d847e2ab8c33c5dedb49bce57e51f57af60ba717e4f66e9ac0f"
readonly EXPECTED_RESERVED_SYNTHETIC_IP_TEST_SHA="9fcd8925be7ec9170795878b7dbee9da9544d4f5e4370f5c63fd95e8b8ae1ec5"
readonly EXPECTED_DNS_DIRECT_SOURCE_SHA="ede6e101653d139750b23a8ed698be3c7791845eefccfbc93945f79830b770cb"
readonly EXPECTED_DNS_DIRECT_PATCHED_SHA="40bc56e6c2e3bb529b0a1688e8460f673569136c06682dc81034e465e260e080"
readonly EXPECTED_DNS_HOST_SOURCE_SHA="7beedff1bf770aa800e5026f5cd3cb9480378fa3a05c71519af1e638e2d565d8"
readonly EXPECTED_DNS_HOST_PATCHED_SHA="1a5193281a938ab159d4d7bc72c07978af97eeea78044c7e3b23f2beaab9d05f"
readonly EXPECTED_DNS_RESOLVER_SOURCE_SHA="b3c418fa65fce62a71a73bad7544831d0ca6b7b470a7b809825124a84f8bc9f3"
readonly EXPECTED_DNS_RESOLVER_PATCHED_SHA="8241160053cd1a0dcf8b602e4de099e70768bb3adc5c3b69e349dc6578b9c805"
readonly EXPECTED_DNS_RUNTIME_SHA="1f2383cf15534afe2296d3cc59c7519b27743fb91abfc889802df839a3da1d7d"
readonly EXPECTED_DNS_RUNTIME_TEST_SHA="4552642e7e7f419c17f3e779a12126d23019b5b8579205ddd5316df2714a948d"
readonly EXPECTED_DNS_SERVICE_SOURCE_SHA="bcaf54472255ad93db917aecb7a1cfc1c483430dc10a81ae9c9446b70de78272"
readonly EXPECTED_DNS_SERVICE_PATCHED_SHA="94fb9341a006ef2265b033d75324323427cb14caedc6a014cd397c5eba5caa43"
readonly EXPECTED_DNS_SERVER_SOURCE_SHA="a825b81da408052892bbc5333525e39a79eff5113895ae63cc0bcc60442d763b"
readonly EXPECTED_DNS_SERVER_PATCHED_SHA="0f0101feca9b82ca0898c1f9c160d5400f3964d026dbda18436d5e4944cfa11e"
readonly EXPECTED_DNS_EXECUTOR_SOURCE_SHA="183595fd58704d60d2137463e751938c1a02a23b57ef1d977b647e3640b64849"
readonly EXPECTED_DNS_EXECUTOR_PATCHED_SHA="d712b85c4867ec4a9b97ebf922f0f32a8c96b0a906616aaa6ffb6b2d4f1d04f2"
readonly EXPECTED_DNS_ROUTE_SOURCE_SHA="764f108e722683aa97af8e147f8847d6d4fe8147bfd8ea8c0d5bba1368f197c8"
readonly EXPECTED_DNS_ROUTE_PATCHED_SHA="3bc6213dfd04066f4f6542973989abb40a9a7776da9a0eac33b31698e29093e2"
readonly EXPECTED_DOH_ROUTE_SOURCE_SHA="f10191ed7fa4e7cb07e9ed771f015df69d49451317e959ee8be0a14af272a3ad"
readonly EXPECTED_DOH_ROUTE_PATCHED_SHA="24c775b534e1ecca13e6f0d82954f04cf1e2cc1bbf85227c6900298609a17ca7"
readonly PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.30-oversize-buffer-pool.patch"
readonly CONFIG_PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.30-progressive-config-parse.patch"
readonly HISTORY_PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.30-connection-close-queue.patch"
readonly HISTORY_TEST_PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.30-connection-close-queue-test.patch"
readonly CELLULAR_TCP_PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.30-snell-cellular-tcp.patch"
readonly RESERVED_SYNTHETIC_IP_PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.30-reserved-synthetic-ip-guard.patch"
readonly ATOMIC_DNS_RUNTIME_PATCH_FILE="${GITHUB_WORKSPACE:?}/MobileCore/dependency-patches/mihomo-v1.19.30-atomic-dns-runtime.patch"
readonly PATCHED_DIR="${RUNNER_TEMP:?}/mihomo-v1.19.30-ios-cora-v7"

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
check_sha256 "$EXPECTED_DIALER_OPTIONS_SOURCE_SHA" "$SOURCE_DIR/$DIALER_OPTIONS_REL"
check_sha256 "$EXPECTED_DIALER_SOURCE_SHA" "$SOURCE_DIR/$DIALER_REL"
check_sha256 "$EXPECTED_SNELL_SOURCE_SHA" "$SOURCE_DIR/$SNELL_REL"
check_sha256 "$EXPECTED_TUNNEL_SOURCE_SHA" "$SOURCE_DIR/$TUNNEL_REL"
check_sha256 "$EXPECTED_DNS_DIRECT_SOURCE_SHA" "$SOURCE_DIR/$DNS_DIRECT_REL"
check_sha256 "$EXPECTED_DNS_HOST_SOURCE_SHA" "$SOURCE_DIR/$DNS_HOST_REL"
check_sha256 "$EXPECTED_DNS_RESOLVER_SOURCE_SHA" "$SOURCE_DIR/$DNS_RESOLVER_REL"
check_sha256 "$EXPECTED_DNS_SERVICE_SOURCE_SHA" "$SOURCE_DIR/$DNS_SERVICE_REL"
check_sha256 "$EXPECTED_DNS_SERVER_SOURCE_SHA" "$SOURCE_DIR/$DNS_SERVER_REL"
check_sha256 "$EXPECTED_DNS_EXECUTOR_SOURCE_SHA" "$SOURCE_DIR/$DNS_EXECUTOR_REL"
check_sha256 "$EXPECTED_DNS_ROUTE_SOURCE_SHA" "$SOURCE_DIR/$DNS_ROUTE_REL"
check_sha256 "$EXPECTED_DOH_ROUTE_SOURCE_SHA" "$SOURCE_DIR/$DOH_ROUTE_REL"
for added_rel in "$CELLULAR_TCP_REL" "$CELLULAR_TCP_TEST_REL"; do
  if [[ -e "$SOURCE_DIR/$added_rel" ]]; then
    echo "Unexpected upstream Snell cellular TCP file: $SOURCE_DIR/$added_rel" >&2
    exit 1
  fi
done
for added_rel in "$RESERVED_SYNTHETIC_IP_REL" "$RESERVED_SYNTHETIC_IP_TEST_REL"; do
  if [[ -e "$SOURCE_DIR/$added_rel" ]]; then
    echo "Unexpected upstream reserved synthetic IP file: $SOURCE_DIR/$added_rel" >&2
    exit 1
  fi
done
for added_rel in "$DNS_RUNTIME_REL" "$DNS_RUNTIME_TEST_REL"; do
  if [[ -e "$SOURCE_DIR/$added_rel" ]]; then
    echo "Unexpected upstream atomic DNS runtime file: $SOURCE_DIR/$added_rel" >&2
    exit 1
  fi
done

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
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --check --whitespace=error-all "$CELLULAR_TCP_PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --whitespace=error-all "$CELLULAR_TCP_PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --check --whitespace=error-all "$RESERVED_SYNTHETIC_IP_PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --whitespace=error-all "$RESERVED_SYNTHETIC_IP_PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --check --whitespace=error-all "$ATOMIC_DNS_RUNTIME_PATCH_FILE"
git -c core.autocrlf=false -C "$PATCHED_DIR" \
  apply --whitespace=error-all "$ATOMIC_DNS_RUNTIME_PATCH_FILE"
check_sha256 "$EXPECTED_PATCHED_SHA" "$PATCHED_DIR/$SOURCE_REL"
check_sha256 "$EXPECTED_TEST_SHA" "$PATCHED_DIR/$TEST_REL"
check_sha256 "$EXPECTED_CONFIG_PATCHED_SHA" "$PATCHED_DIR/$CONFIG_REL"
check_sha256 "$EXPECTED_HISTORY_PATCHED_SHA" "$PATCHED_DIR/$HISTORY_REL"
check_sha256 "$EXPECTED_HISTORY_TEST_SHA" "$PATCHED_DIR/$HISTORY_TEST_REL"
check_sha256 "$EXPECTED_DIALER_OPTIONS_PATCHED_SHA" "$PATCHED_DIR/$DIALER_OPTIONS_REL"
check_sha256 "$EXPECTED_DIALER_PATCHED_SHA" "$PATCHED_DIR/$DIALER_REL"
check_sha256 "$EXPECTED_SNELL_PATCHED_SHA" "$PATCHED_DIR/$SNELL_REL"
check_sha256 "$EXPECTED_CELLULAR_TCP_SHA" "$PATCHED_DIR/$CELLULAR_TCP_REL"
check_sha256 "$EXPECTED_CELLULAR_TCP_TEST_SHA" "$PATCHED_DIR/$CELLULAR_TCP_TEST_REL"
check_sha256 "$EXPECTED_TUNNEL_PATCHED_SHA" "$PATCHED_DIR/$TUNNEL_REL"
check_sha256 "$EXPECTED_RESERVED_SYNTHETIC_IP_SHA" "$PATCHED_DIR/$RESERVED_SYNTHETIC_IP_REL"
check_sha256 "$EXPECTED_RESERVED_SYNTHETIC_IP_TEST_SHA" "$PATCHED_DIR/$RESERVED_SYNTHETIC_IP_TEST_REL"
check_sha256 "$EXPECTED_DNS_DIRECT_PATCHED_SHA" "$PATCHED_DIR/$DNS_DIRECT_REL"
check_sha256 "$EXPECTED_DNS_HOST_PATCHED_SHA" "$PATCHED_DIR/$DNS_HOST_REL"
check_sha256 "$EXPECTED_DNS_RESOLVER_PATCHED_SHA" "$PATCHED_DIR/$DNS_RESOLVER_REL"
check_sha256 "$EXPECTED_DNS_RUNTIME_SHA" "$PATCHED_DIR/$DNS_RUNTIME_REL"
check_sha256 "$EXPECTED_DNS_RUNTIME_TEST_SHA" "$PATCHED_DIR/$DNS_RUNTIME_TEST_REL"
check_sha256 "$EXPECTED_DNS_SERVICE_PATCHED_SHA" "$PATCHED_DIR/$DNS_SERVICE_REL"
check_sha256 "$EXPECTED_DNS_SERVER_PATCHED_SHA" "$PATCHED_DIR/$DNS_SERVER_REL"
check_sha256 "$EXPECTED_DNS_EXECUTOR_PATCHED_SHA" "$PATCHED_DIR/$DNS_EXECUTOR_REL"
check_sha256 "$EXPECTED_DNS_ROUTE_PATCHED_SHA" "$PATCHED_DIR/$DNS_ROUTE_REL"
check_sha256 "$EXPECTED_DOH_ROUTE_PATCHED_SHA" "$PATCHED_DIR/$DOH_ROUTE_REL"

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
