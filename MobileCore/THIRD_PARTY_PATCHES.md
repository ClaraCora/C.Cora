# Third-party patches

## sing-and-mihomo-ss-record-oversize-buffer-pool

- Added: 2026-07-25
- Upstream modules: `github.com/metacubex/sing v0.5.7`,
  `github.com/metacubex/mihomo v1.19.29`
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
- `dependency-patches/mihomo-v1.19.29-oversize-buffer-pool.patch`;
- `scripts/prepare-ios-sing.sh` and its CI invocation;
- `scripts/prepare-ios-mihomo.sh` and its CI invocation;
- the `PATCHED_SING_DIR` wiring in `prepare-ios-sing-shadowsocks2.sh`;
- this section of the patch record.

No configuration or user-data migration is involved.

## mihomo-ss2022-tcp-connection-limit-and-pressure-trim

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/mihomo v1.19.29`
- Patched file: `adapter/outbound/shadowsocks.go`
- App files: `mihomo.go`, `MiClashTunnel/MemoryDiagnostics.swift`
- Build tags: default and `with_low_memory`

### Reason

SS2022 must authenticate a complete encrypted record before exposing its
plaintext. A single stream is stable at high throughput, but parallel download
workers multiply live cipher records, relay buffers, TCP state, and queued Go
work inside the iOS Network Extension. The process can cross the platform's
memory limit before garbage collection returns idle pages, even after removing
the known per-record allocations and bounding the gVisor queues.

### Local behavior

Each Shadowsocks proxy whose cipher name starts with `2022-` permits at most
four active TCP connections. A fifth dial waits for a connection to close and
honors its `context.Context`, so canceled requests do not remain stuck. The
permit wraps Mihomo's final `C.Conn` and is released exactly once; this preserves
the extended Reader/Writer interfaces and the reusable SS Reader used by the
single-stream fast path. Legacy Shadowsocks ciphers, every other proxy type,
and native Shadowsocks UDP are unchanged.

Four is an iOS memory-safety ceiling, not a Speedtest-specific thread count.
Sites opening more than four simultaneous TCP connections through the same
SS2022 node may queue briefly, and a many-stream benchmark can report lower
peak throughput. Existing connections are never terminated by the limiter.

When iOS reports warning or critical memory pressure, the tunnel records a
before sample, calls the exported `TrimMemory` bridge (`debug.FreeOSMemory()`),
and records an after sample. This can introduce a short full-GC pause only under
actual memory pressure; startup retains its existing one-time reclamation.

Before Mihomo loads its configuration, MobileCore also sets `GOGC=25` and a
36 MiB Go soft memory limit. This reduces the heap-growth headroom that the
default `GOGC=100` would permit and reserves process memory for Swift, system
libraries, and short non-Go peaks. The Go limit is soft: live data can exceed
it, and aggressive collection can consume more CPU during high throughput.

### Verification

The Mihomo preparation script verifies the upstream and patched SHA-256 hashes
for the allocator and Shadowsocks sources plus both regression tests. CI runs
`common/pool` and `adapter/outbound` in default and low-memory modes. Limiter
tests cover cipher scoping, the four-connection boundary, context cancellation,
and exactly-once permit release. MobileCore tests verify that `TrimMemory`
increments Go's forced-GC counter and that the proactive runtime policy is set.

### Rollback

Revert the commit that added this section. For a targeted manual rollback,
remove the SS2022 limiter and its test from the Mihomo dependency patch, remove
the SS source/test hashes from `prepare-ios-mihomo.sh`, restore the allocator-only
CI command, remove exported `TrimMemory`, and restore the pressure handler to a
single diagnostic sample. Remove `configureRuntimeMemoryPolicy` and its call
from `Setup` to restore Go's default GC policy. No configuration or user-data
migration is involved.

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

## sing-tun-v0.4.21-darwin-queue-bounds

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/sing-tun v0.4.21`
- Patched files: `internal/fdbased_darwin/processors.go`,
  `tun_darwin_gvisor.go`
- Build tags: `with_gvisor,with_low_memory`

### Reason

The Darwin fd endpoint receives up to roughly 512 KiB of packets per syscall
and distributes them to per-processor asynchronous queues. In v0.4.21 those
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

On initial startup, MiClash also calls `debug.FreeOSMemory()` after Mihomo
applies the configuration. This returns parser and GEO-loading scratch pages;
live configuration reloads deliberately skip the extra full GC.

### Verification

CI runs the processor queue regression tests and Darwin endpoint limit tests
from the patched module, then compiles MobileCore with
`with_gvisor,with_low_memory` before `gomobile bind`.

### Rollback

Revert the commit that added this patch. For a manual rollback, remove:

- `dependency-patches/sing-tun-v0.4.21-darwin-queue.patch`;
- `scripts/prepare-ios-sing-tun.sh` and its CI invocation;
- the post-`ApplyConfig` `debug.FreeOSMemory()` call;
- this section of the patch record.

No configuration or user-data migration is involved.

## gvisor-261ec1326fe8-tcp-pure-ack-queue

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/gvisor v0.0.0-20251227095601-261ec1326fe8`
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

- `dependency-patches/gvisor-261ec1326fe8-tcp-ack-queue.patch`;
- `scripts/prepare-ios-gvisor.sh` and its CI invocation;
- this section of the patch record.

No configuration or user-data migration is involved.
