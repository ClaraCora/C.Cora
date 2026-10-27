#!/usr/bin/env bash
set -euo pipefail
APP="${1:?Usage: verify-meow-app.sh path/to/Cora.app}"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS required' >&2; exit 1; }
TUNNEL="$APP/PlugIns/CoraTunnel.appex"
for bundle in "$APP" "$TUNNEL" "$APP/PlugIns/CoraControl.appex"; do
  test -d "$bundle"
  minimum=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$bundle/Info.plist")
  [[ "$minimum" == 18.0 ]] || { echo "Unexpected deployment target: $bundle $minimum" >&2; exit 1; }
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")
  [[ "$(xcrun lipo -archs "$bundle/$executable")" == arm64 ]] || {
    echo "Unexpected executable architectures: $bundle" >&2; exit 1
  }
  if /usr/libexec/PlistBuddy -c 'Print :CoraTrollStoreBuild' "$bundle/Info.plist" >/dev/null 2>&1; then
    echo "Nonstandard build marker: $bundle" >&2; exit 1
  fi
  if xcrun otool -L "$bundle/$executable" | grep -Eiq 'Mihomo|gomobile|MobileCore\.framework'; then
    echo "Old Go framework linked: $bundle" >&2; exit 1
  fi
  # Inspect defined symbols too: a statically linked old core can satisfy its
  # own references and therefore escape an undefined-symbol-only check.
  symbols="$(xcrun nm -g "$bundle/$executable")"
  if grep -Eq 'Mihomo(Start|Set|Force|Runtime)|_crosscall2|_go_seq_|_runtime\.goexit' <<< "$symbols"; then
    echo "Old Go symbols: $bundle" >&2; exit 1
  fi
done
plugins=$(find "$APP/PlugIns" -mindepth 1 -maxdepth 1 -name '*.appex' | wc -l | tr -d ' ')
[[ "$plugins" == 2 ]] || { echo "Expected Tunnel and Control extensions only" >&2; exit 1; }
if find "$APP" -iname '*Mihomo*' -o -iname '*Legacy*' -o -iname '*TrollStore*' | grep -q .; then
  echo 'Unexpected old-core or nonstandard payload' >&2; exit 1
fi
binary="$TUNNEL/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TUNNEL/Info.plist")"
if ! xcrun otool -L "$binary" | grep -q '/libsqlite3'; then
  echo 'Packet Tunnel must use system SQLite for Rust logbook and history' >&2; exit 1
fi
bytes=$(stat -f '%z' "$binary")
# An on-disk code-size gate, not a resident-memory/phys_footprint claim.
[[ "$bytes" -le 52428800 ]] || { echo "Tunnel binary exceeds 50 MiB: $bytes" >&2; exit 1; }
echo "Standard iOS 18 payload verified; Packet Tunnel binary $bytes bytes"
