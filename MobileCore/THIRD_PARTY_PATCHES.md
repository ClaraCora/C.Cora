# Third-party patches

## mihomo-v1.19.30-atomic-dns-runtime

- Added: 2026-08-23
- Upstream module: `github.com/metacubex/mihomo v1.19.30`
- Patched files: `component/resolver`, `dns/server.go`,
  `hub/executor/executor.go`, `adapter/outbound/direct.go`, and the DNS
  controller routes
- Build tags: default and `with_low_memory`

### Reason

Mihomo v1.19.30 publishes `DefaultResolver`, the proxy/direct host resolvers,
`DefaultService`, and `UseSystemHosts` as separate package globals. Cora can
rebuild DNS while the packet tunnel is carrying traffic, so assigning those
globals one after another creates both data races and a window in which a
request sees fields from different DNS generations. Cora's configuration lock
serializes writers but cannot protect Mihomo's concurrent data-plane readers.

### Local behavior

The five runtime values now live in one immutable `DNSRuntimeSnapshot`,
published with a single `atomic.Pointer` store. Readers either retain one
snapshot for a multi-field operation or use stable compatibility proxies that
load the current snapshot before dispatching. `use-system-hosts`, controller
DNS queries, and the direct resolver identity check also read the snapshot.
Mihomo's normal configuration executor builds all values before publishing
them, and Cora's scoped system-DNS refresh follows the same path.
The UDP/TCP DNS listener is installed once with the stable Service proxy. A
same-address refresh no longer rewrites `Server.service` while `ServeDNS` may
be reading it; each query reaches the newly published Service through the
snapshot instead.

Each publication allocates one small snapshot. DNS requests perform one atomic
load and do not allocate a snapshot, acquire a mutex, retain request history,
or start a goroutine. Cora publishes the new generation before releasing the
old resolver transport, while a failed candidate build leaves the old snapshot
untouched. The existing `ResolverEnhancer` remains shared across Cora's
system-DNS-only refresh, preserving redir-host/Fake-IP reverse mappings.

### Verification

The preparation script verifies every touched upstream and resulting file
hash, refuses pre-existing added runtime files, and applies the patch with
strict whitespace checks. CI tests and vets `component/resolver`, `dns`, and
the patched hub packages in default and low-memory builds. Regression tests
exercise caller-copy isolation,
concurrent alternating publications without mixed fields, stable proxy
dispatch, and zero-allocation snapshot reads.

### Rollback

Revert the commit that added this section and remove:

- `dependency-patches/mihomo-v1.19.30-atomic-dns-runtime.patch`;
- its preparation-script paths, hashes, and apply wiring;
- `./component/resolver`, `./dns`, `./hub/executor`, and `./hub/route` from the
  Mihomo CI test and vet package lists; and
- the MobileCore `CurrentDNSRuntime` / `PublishDNSRuntime` calls.

Restore the original direct assignments only as one rollback unit. Removing
just the patch while leaving MobileCore's snapshot API calls will intentionally
fail compilation. No stored configuration or user-data migration is involved.

## mihomo-v1.19.30-reserved-synthetic-ip-guard

- Added: 2026-08-23
- Upstream module: `github.com/metacubex/mihomo v1.19.30`
- Patched file: `tunnel/tunnel.go`; added
  `tunnel/reserved_synthetic_ip.go` and its regression tests
- Build tags: default and `with_low_memory`

### Reason

Cora's TUN and optional Fake-IP pool use `198.18.0.0/16`. During a live DNS
transition, or when another DNS server returns an address from that synthetic
range, Mihomo can receive a connection whose reverse domain mapping is absent.
Without a guard, the address is treated as an ordinary private IP, can match a
`private_ip` rule, and can be sent to DIRECT. Dialing the synthetic address
then times out and repeated failures can make the device appear offline.

This protection is independent of the configured DNS enhanced mode. It is
needed even with `redir-host`, because stale DNS answers can survive a mode or
network transition and an upstream Wi-Fi DNS server can return its own
synthetic address.

### Local behavior

MobileCore registers Cora's exact synthetic range through
`tunnel.SetReservedSyntheticIPPrefixes`. The tunnel first performs Mihomo's
normal reverse lookup. A mapped address therefore keeps the upstream behavior.
Only an address inside a registered range that still has neither a host nor a
reverse mapping is rejected before rule matching.

TCP retains Mihomo's existing pre-handle failure path and gets one opportunity
to recover the domain through the configured TLS/HTTP sniffer. If the sniffer
reports a domain without replacing the destination, the guard promotes that
domain and removes the synthetic IP before routing. If recovery fails, the
connection is closed. UDP checks the metadata both before creating its NAT
sender and again after asynchronous sniffing. The second check is authoritative,
so a reverse mapping evicted between those stages aborts the dial instead of
letting a stale synthetic address reach routing.

The prefix snapshot is immutable, atomically replaced, and limited to 16
entries. The hot path performs a bounded prefix scan and allocates no address
history, cache, timer, or goroutine. A single atomic counter records blocked
events. Diagnostics are emitted only at totals 1, 2, 4, 8, and subsequent
powers of two, so a failure remains visible without flooding Network Extension
logs.

### Verification

The preparation script verifies the exact upstream `tunnel.go` hash, refuses
unexpected pre-existing added files, applies the patch with strict whitespace
checks, and verifies all three resulting file hashes. CI runs the full tunnel
tests and `vet` in default and low-memory builds. Regression tests cover
prefix normalization, duplicate removal, the 16-prefix bound, caller-slice
isolation, mapped-address preservation, protection with mapping disabled,
unregistered addresses, TCP sniff recovery, UDP mapping-eviction handling,
and power-of-two diagnostics.

### Rollback

Revert the commit that added this section and remove:

- `dependency-patches/mihomo-v1.19.30-reserved-synthetic-ip-guard.patch`;
- its preparation-script SHA and apply wiring;
- `./tunnel` from the Mihomo CI test and vet package lists; and
- the MobileCore calls to `tunnel.SetReservedSyntheticIPPrefixes`.

No stored configuration or user-data migration is involved.

## mihomo-v1.19.30-snell-cellular-tcp

- Added: 2026-08-23
- Upstream module: `github.com/metacubex/mihomo v1.19.30`
- Patched files: `component/dialer/options.go`,
  `component/dialer/dialer.go`, `adapter/outbound/snell.go`; added
  `component/dialer/snell_cellular_tcp.go` and its regression tests
- Build tags: default and `with_low_memory`

### Reason

On Darwin, Mihomo's `tfo-go` dependency forces TCP Fast Open on and bypasses
the operating system's native TFO backoff. Some cellular entrances silently
drop the SYN payload even though `connectx` reports success, while the same
Snell endpoint works over ordinary TCP. A process-wide `DisableTFO` workaround
restores those entrances but unnecessarily disables TFO for working nodes.

The previous adaptive implementation tried to classify an entrance by opening
disposable Snell sessions and waiting for a standalone protocol Ping/Pong.
That is not equivalent to the successful single-node URL test, which opens an
ordinary TCP Snell tunnel and then sends real destination traffic. On the
affected entrance, both disposable TFO and ordinary-TCP Ping/Pong timed out
even though ordinary TCP with real traffic worked. The probe therefore could
not reliably distinguish a TFO SYN-data black hole from a server or path that
does not answer that synthetic transaction. It also put an avoidable failed
probe on the user's connection path.

### Local behavior

Cora stores an explicit list of exact Snell proxy names that require ordinary
TCP on cellular networks. `adapter/outbound/snell.go` passes each Snell proxy's
name into its dialer. After Mihomo resolves the active interface, but before it
opens the socket, the dialer skips TFO only when both conditions are true:

- the interface name starts with `pdp_ip` (case-insensitive); and
- the exact Snell proxy name is present in Cora's configured list.

Selected nodes keep their configured TFO behavior on Wi-Fi. Unselected Snell
nodes, every other protocol, and Mihomo's process-wide `DisableTFO` behavior
remain unchanged. Node names are matched exactly so similarly named entrances
cannot inherit the workaround accidentally.

The selected-name snapshot is immutable, replaced atomically, and bounded to
4,096 names. The hot dial path performs one map lookup and adds no probes,
retries, sockets, timers, caches, payload retention, or background goroutines.
The list is applied when the VPN starts and cleared when the core stops, so
changing it requires a VPN reconnect. This deliberately trades automatic
inference for a predictable, user-controlled transport decision with no
ten-minute retry interruption.

### Verification

The preparation script verifies exact SHA-256 values for every upstream,
patched, and added file. CI runs the dialer and Snell outbound tests and `vet`
in default and low-memory builds. Regression tests cover exact-name matching,
atomic list replacement, case-insensitive `pdp_ip*` recognition, unselected
nodes, and preservation of TFO on Wi-Fi.

### Rollback

Revert the commit that added this section and remove:

- `dependency-patches/mihomo-v1.19.30-snell-cellular-tcp.patch`;
- its preparation-script SHA and apply wiring;
- `SetSnellCellularTCPNodes` calls and related logging in MobileCore; and
- the `Snell 蜂窝普通 TCP` settings page and its stored node-name list.

The UserDefaults array can remain because older builds ignore unknown keys.

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
