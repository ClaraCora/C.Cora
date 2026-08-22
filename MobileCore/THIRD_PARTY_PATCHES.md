# Third-party patches

## mihomo-v1.19.30-snell-adaptive-tfo

- Added: 2026-08-22
- Upstream module: `github.com/metacubex/mihomo v1.19.30`
- Patched files: `component/dialer/tfo.go`, `component/dialer/options.go`,
  `component/dialer/dialer.go`, `adapter/outbound/snell.go`; added a Snell
  Ping/Pong transport helper and regression tests under `transport/snell`,
  `component/dialer`, and `adapter/outbound`
- Build tags: default and `with_low_memory`

### Reason

On Darwin, Mihomo's `tfo-go` dependency forces TCP Fast Open on and bypasses
the operating system's native TFO backoff. Some cellular routes silently drop
the SYN payload even though `connectx` reports success and ordinary TCP to the
same IPv4 endpoint works. Treating that local connect result as proof of TFO
therefore misses the failure: the timeout is only visible after a complete
Snell record has been sent. A process-wide `DisableTFO` workaround restored
those routes, but unnecessarily disabled TFO for working Snell entrances,
including entrances that work on the same cellular interface.

Snell TCP tunnel replies are intentionally lazy: after `Connect` or
`ConnectV2`, a v4/v5 server can wait for destination traffic and combine
`CommandTunnel` with the first upstream payload. Waiting for `CommandTunnel`
inside `DialContext` therefore deadlocks URL tests, because their HTTP request
is written only after `DialContext` returns. Applying the same wait to the
ordinary-TCP fallback made a healthy fallback appear to time out.

### Local behavior

The persisted Cora setting formerly named `cellularSnellCompatibility` is shown
as `Snell 自适应 TFO`. It opts only Snell dialers with node-level TFO enabled
into adaptive handling. Other protocols, IPv6, Wi-Fi, and Snell nodes without
TFO keep upstream behavior. Cora never writes Mihomo's process-wide
`DisableTFO` variable.

On a `pdp_ip*` interface, the first logical probe for each resolved IPv4
`address:port` uses disposable Snell sessions to send `[Version, CommandPing]`
and wait for the immediate `CommandPong`. The first TFO Ping can warm Darwin's
Fast Open cookie cache; a second fresh TFO Ping is therefore required to prove
that subsequent SYN data survives the route. Each TFO stage is limited to one
second. If either stage has no Pong, its socket is closed before a fresh
ordinary TCP session performs the same check using the caller's remaining
budget, capped at five seconds. Every stage rebuilds active wrappers and the
Snell cipher; raw encrypted bytes are never replayed across sockets.

After the result is cached, the disposable probe is closed and a separate real
connection is opened with the selected transport. TCP `Connect`/`ConnectV2`
returns immediately after writing its target header, allowing URL tests and
normal traffic to send their request before the server's lazy tunnel reply.
Snell v4 UDP retains its required immediate reply handling. The same preflight
path covers v1-v4 transport (configured v5 maps to v4), active wrappers, and
`reuse=true`. If both Ping/Pong methods fail, the route is left unclassified
and the current attempt returns both errors without entering a retry loop.

`蜂窝期间保持普通 TCP` defaults on. Within the current VPN runtime, once an
entrance is confirmed incompatible, all `pdp_ip*` indices in that continuous
cellular session share the result and keep that entrance on ordinary TCP until
Cora observes a real cellular/non-cellular transition. Reconnecting the VPN or
restarting its Network Extension starts a fresh observation session; the cache
is deliberately not persisted. This avoids making a new connection absorb a
periodic failed probe without retaining stale network conclusions on disk. A
cellular address or `pdp_ip` refresh still clears successful and in-flight
observations so working entrances are revalidated, but preserves verified
ordinary-TCP fallbacks. When the option is off, the entrance is eligible for a
new TFO probe after ten minutes and ordinary network-path resets retain their
previous behavior. Neither policy interrupts an existing connection merely to
probe TFO.

The state cache retains no sockets, payloads, DNS answers, timers, or
goroutines. It is limited to 128 entries with least-recently-used eviction of
safe observations. In-flight probes, held fallbacks, and fallbacks whose
ten-minute cooldown has not expired are never evicted; if all 128 slots are
protected, additional entrances temporarily use ordinary TCP until a slot is
available. Only one initial or cooldown probe runs per entrance, and concurrent
requests use ordinary TCP while that probe is pending. Snell's reuse pool now
receives the caller context via `GetContext`, and the lazy TFO connection derives
its timeout from that caller instead of `context.Background`. Caller cancellation
abandons a new probe without claiming ordinary TCP failed; a canceled retry for
an already incompatible entrance remains safely on ordinary TCP. Logs cover
probe start, protocol confirmation, ordinary TCP verification, fallback policy,
recovery, cancellation, and unclassified double failure.
Lazy TFO connection state is synchronized so cancellation cannot race a late
`connectx` return and leave an untracked socket alive in the Network Extension.

### Verification

The preparation script verifies exact SHA-256 values for every upstream,
patched, and added file. CI runs the dialer, Snell transport, and outbound tests
in default and low-memory builds. Tests cover Ping/Pong across Snell v1-v4,
cookie warm-up plus a second disposable TFO verification, fresh ordinary TCP
verification with a longer caller budget, late-dial cancellation, TCP lazy
tunnel replies, v5-to-v4 mapping, reuse, cached and held fallback, cooldown
recovery, path reset, dual failure, caller cancellation, single-probe
coordination, non-eviction of active or protected fallback entries, the
128-entry bound, and Snell v4 UDP immediate replies.

### Rollback

Revert the commit that added this section and remove:

- `dependency-patches/mihomo-v1.19.30-snell-adaptive-tfo.patch`;
- its preparation-script SHA and apply wiring;
- `SetAdaptiveTFOEnabled`, `SetAdaptiveTFOHoldUntilNetworkChange`, and
  `ResetAdaptiveTFO` calls in MobileCore;
- the `Snell 自适应 TFO` and `蜂窝期间保持普通 TCP` setting rows, or restore
  the former diagnostic behavior.

Both UserDefaults keys can remain. Older builds continue to understand the
original Boolean and ignore the new hold-policy key, so no migration is needed.

## mihomo-v1.19.30-connection-close-queue

- Added: 2026-08-13
- Upstream module: `github.com/metacubex/mihomo v1.19.30`
- Patched file: `tunnel/statistic/manager.go`
- Build tags: default and `with_low_memory`

### Reason

The iOS App can be terminated while its Packet Tunnel keeps forwarding traffic.
Keeping every finished connection in Mihomo, Swift, or the extension process
would make a busy browsing session grow without a hard memory bound and risks
Jetsam terminating the Network Extension. The App still needs enough final
connection information to persist a durable, bounded history in its App Group.

### Local behavior

`statistic.Manager` copies a completed tracker into a fixed 512-item ring when
it leaves the live manager. Each copy owns its counter data and retains only
bounded routing and metadata text, so the released tracker cannot mutate
history. The ring does not reallocate while it is full. `ClosedSince` exposes
incremental batches behind a cursor and reports when an old cursor fell behind
the FIFO.
The Packet Tunnel drains this queue every two seconds into its SQLite history;
SQLite retains at most seven days, 20,000 rows, or 50 MiB, removing only the
oldest completed rows. Live packets never wait for this database work.

At more than roughly 256 short-lived connections per second for a sustained
two-second interval, the FIFO can overflow. Some finished detail rows can then
be absent, and the extension writes a diagnostic log entry, but packet
forwarding, active connections, and the extension memory limit are unaffected.

### Verification

The Mihomo preparation script verifies the exact upstream source and patched
SHA-256 hashes. CI runs `./tunnel/statistic` together with the existing pool
and config checks in both default and `with_low_memory` modes. The patch suite
checks an empty cursor response and confirms copied tracker counters are no
longer aliased to the live tracker.

### Rollback

Revert the commit that added this section and remove:

- `dependency-patches/mihomo-v1.19.30-connection-close-queue.patch`;
- `dependency-patches/mihomo-v1.19.30-connection-close-queue-test.patch`;
- the history patch preparation and verification wiring;
- `ClosedConnectionsSnapshot` and the Packet Tunnel history recorder.

Existing App Group history can simply be left in place; it is not read by
earlier versions.

## sing-and-mihomo-ss-record-oversize-buffer-pool

- Added: 2026-07-25
- Upstream modules: `github.com/metacubex/sing v0.5.7`,
  `github.com/metacubex/mihomo v1.19.30`
- Patched files: sing `common/buf/alloc.go`, `common/buf/buffer.go`;
  Mihomo `common/pool/alloc.go`
- Build tags: default and `with_low_memory`

### Reason

An SS AEAD record can contain 65535 bytes of plaintext. Its 16-byte AEAD tag
makes the receive buffer 65551 bytes. In sing v0.5.7, `buf.NewSize` manages only
sizes up to 65535 bytes, so every protocol-maximum SS record allocates a fresh
65551-byte backing array and `Release` leaves it to the garbage collector.
Parallel SS2022 streams can therefore allocate at nearly payload rate and
outrun the iOS Packet Tunnel memory limit even though the released buffers are
no longer live.

Mihomo replaces `sing`'s `buf.DefaultAllocator` with its own allocator during
package initialization. Updating only sing's allocator therefore passes
standalone dependency tests but has no effect in the real app; both the sing
buffer boundary and Mihomo's installed allocator must support this size.

### Local behavior

The sing fallback allocator and Mihomo's installed allocator each have one
dedicated, exact 65552-byte `sync.Pool` bucket. Sizes from 65536 through 65552
are managed: 65536 keeps using the existing 64 KiB bucket, while 65537 through
65552 use the new bucket. Sizes below 65536 and above 65552 retain their
upstream behavior. In particular, this does not add a generic 128 KiB bucket,
change cipher framing, retain a record buffer on each connection, or copy
plaintext on the relay path.

During contention the pool can retain multiple 65552-byte backing arrays, so
memory after a traffic burst can remain higher than immediate live demand.
Retention follows concurrent demand and Go's scheduler/pool behavior rather
than a hard item limit. Released arrays are reusable, and Go may discard pooled
items during garbage collection; this replaces per-record backing allocation
with shared capacity without adding per-connection retention.

### Verification

The preparation scripts lock both module versions and verify SHA-256 hashes
before and after applying each patch. CI runs both allocator boundary suites in
default and low-memory modes. Mihomo's test imports sing, verifies that its
allocator replacement is installed, and asserts that `buf.NewSize(65551)` uses
the exact bucket. The patched SS2 module is also forced to resolve this exact
patched sing directory before its Reader tests run, preventing a standalone
dependency test from silently selecting sing v0.5.4.

On Windows amd64, with the SS2 Reader patch held constant and only the sing
allocator switched, the low-memory `WaitReadBuffer` benchmark for 64
consecutive 65535-byte records dropped from about 4,724,144 B/op and 133
allocs/op to about 8,086 B/op and 69 allocs/op. The 32734-byte standard-frame
case remained at 6,721 B/op and 69 allocs/op with either allocator. These
desktop figures validate allocation shape rather than iOS throughput or
peak-memory behavior.

### Rollback

Revert the commit that added this patch. For a manual rollback, remove:

- `dependency-patches/sing-v0.5.7-oversize-buffer-pool.patch`;
- `dependency-patches/mihomo-v1.19.30-oversize-buffer-pool.patch`;
- `scripts/prepare-ios-sing.sh` and its CI invocation;
- `scripts/prepare-ios-mihomo.sh` and its CI invocation;
- the `PATCHED_SING_DIR` wiring in `prepare-ios-sing-shadowsocks2.sh`;
- this section of the patch record.

No configuration or user-data migration is involved.

## sing-shadowsocks2-v0.2.7-reusable-length-buffer

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/sing-shadowsocks2 v0.2.7`
- Patched file: `internal/shadowio/reader.go`
- Build tags: default and `with_low_memory`

### Reason

The v0.2.7 AEAD reader allocates a managed 18-byte buffer object for every
received record solely to decrypt its two-byte length. Multi-stream downloads
repeat this pool get/put and object allocation at record rate even though the
length chunk has a fixed wire size.

An attempted all-record ciphertext scratch was rejected after benchmarking the
actual low-memory `WaitReadBuffer` path. Although it improved ordinary `Read`,
it forced an additional output-buffer allocation and plaintext copy in the
Mihomo relay path, increased retained per-connection memory, and performed
worse than upstream there.

### Local behavior

Each AEAD Reader now embeds one fixed 18-byte length chunk. Ciphertext data
keeps the upstream behavior: it is decrypted in a managed buffer and, when no
headroom is required, returned directly by `WaitReadBuffer`. The patch adds no
per-connection record high-water buffer and no data-path copy. It also makes a
zero-length `Read` return immediately, rejects a full destination buffer with
`io.ErrShortBuffer`, and implements `Close` so a partially consumed cache is
released promptly.

On a Windows amd64 comparison using 64 consecutive 32734-byte records (the
standard build's maximum data frame) and the `with_low_memory` no-headroom
`WaitReadBuffer` path, upstream measured about 9.6 KiB/op and 132 allocs/op;
the patch measured about 5.6 KiB/op and 69 allocs/op. Five runs showed no
meaningful throughput regression within normal benchmark noise. These desktop
numbers validate allocation shape only and are not an iOS throughput claim.

### Verification

CI verifies the exact module version and source SHA-256, applies the patch to a
temporary module copy, verifies the patched source and test hashes, and runs the
Reader tests in default and low-memory modes. Tests cover mixed record sizes up
to the 65535-byte protocol boundary, all three read APIs, direct no-headroom
delivery, MTU/headroom handling, authentication and truncation errors,
zero-length reads, short buffers, and close cleanup.

### Rollback

Revert the commit that added this patch. For a manual rollback, remove:

- `dependency-patches/sing-shadowsocks2-v0.2.7-length-buffer.patch`;
- `scripts/prepare-ios-sing-shadowsocks2.sh` and its CI invocation;
- this section of the patch record.

No configuration or user-data migration is involved.

## sing-tun-v0.4.22-darwin-queue-bounds

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/sing-tun v0.4.22`
- Patched files: `internal/fdbased_darwin/processors.go`,
  `tun_darwin_gvisor.go`
- Build tags: `with_gvisor,with_low_memory`

### Reason

The Darwin fd endpoint receives up to roughly 512 KiB of packets per syscall
and distributes them to per-processor asynchronous queues. In v0.4.22 those
queues have no length or byte limit. A burst can therefore retain packet views
faster than gVisor consumes them, which is fatal under the iOS Packet Tunnel
memory budget. High-throughput multi-stream traffic makes this substantially
more likely than a single stream.

### Local behavior

Each Darwin processor queue is capped at one nominal 512 KiB receive batch,
calculated from the configured TUN MTU. Darwin gVisor endpoints now use one
receive processor per TUN channel instead of deriving the count from
`GOMAXPROCS`, so the nominal cap is no longer multiplied by the device CPU
count. Because packet-pool allocations round up, real retained memory is
higher: at MTU 1500, the single processor can retain about 700 KiB of packet
backing plus metadata.

The Darwin gVisor-to-utun FIFO is reduced from 1000 packets to 128 packets.
Packets arriving while either queue is full are not retained. TCP recovers
through its normal retransmission and congestion-control behavior; UDP can lose
a datagram during sustained overload. Using one receive processor and a shorter
output FIFO can reduce peak packet-per-second throughput, increase drops during
bursts, and make TCP congestion control back off sooner. These limits affect
only the Darwin/iOS gVisor endpoint; other platform stacks and TCP window sizes
are unchanged.

The CI preparation script verifies the exact module version and SHA-256 of the
upstream source, copies the module to the runner's temporary directory, applies
the patch there, and adds a version-qualified temporary `replace` directive.
An unexpected dependency upgrade or source change fails the build instead of
silently applying an outdated patch.

On initial startup, Cora also calls `debug.FreeOSMemory()` after Mihomo
applies the configuration. This returns parser and GEO-loading scratch pages.
Live reloads first drain active connections and force a collection before
parsing the replacement, then defer the post-apply collection until traffic is
running again.

### Verification

CI runs the processor queue regression tests and Darwin endpoint limit tests
from the patched module, then compiles MobileCore with
`with_gvisor,with_low_memory` before `gomobile bind`.

### Rollback

Revert the commit that added this patch. For a manual rollback, remove:

- `dependency-patches/sing-tun-v0.4.22-darwin-queue.patch`;
- `scripts/prepare-ios-sing-tun.sh` and its CI invocation;
- the post-`ApplyConfig` `debug.FreeOSMemory()` call;
- this section of the patch record.

No configuration or user-data migration is involved.

## gvisor-3cc44cf9ac22-tcp-pure-ack-queue

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/gvisor v0.0.0-20260810011720-3cc44cf9ac22`
- Patched file: `pkg/tcpip/transport/tcp/segment_queue.go`

### Reason

gVisor normally bounds an endpoint's inbound TCP segment queue using receive
memory accounting, but zero-payload TCP segments bypass that bound. Every ACK
cloned from the iOS TUN path still retains its packet-buffer backing. During a
multi-stream high-throughput download, pure ACKs can therefore accumulate
faster than the TCP processor drains them and grow without a hard limit.

### Local behavior

Each TCP endpoint retains at most 64 zero-payload segments that carry ACK,
including SACK, ECN, CWR, and window-update variants. Once full, later ACKs are
rejected through gVisor's existing segment-drop path and counters. Cumulative
ACKs and TCP retransmission recover from overload. SYN, FIN, and RST keep the
upstream behavior and are not subject to this new limit.

The threshold is below gVisor's 100-segment processing quantum. Under overload,
the queue keeps the earliest 64 ACKs and drops newer ones until the worker
releases a slot; this deliberately applies TCP backpressure and can reduce
throughput before allowing memory to grow without a bound. The patch does not
alter cipher code, TCP windows, send/receive buffer sizes, or wire protocols.

### Verification

CI tests the exact patched gVisor module before compiling MobileCore. Regression
tests cover the 64-segment boundary, SACK/ECN/CWR variants, state-counter
reconstruction, control-segment exemptions, frozen queues, queue draining, and
receive-memory reference accounting.

### Rollback

Revert the commit that added this patch. For a manual rollback, remove:

- `dependency-patches/gvisor-3cc44cf9ac22-tcp-ack-queue.patch`;
- `scripts/prepare-ios-gvisor.sh` and its CI invocation;
- this section of the patch record.

No configuration or user-data migration is involved.
