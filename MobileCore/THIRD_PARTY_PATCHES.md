# Third-party patches

## sing-tun-v0.4.21-darwin-processor-queue

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/sing-tun v0.4.21`
- Patched file: `internal/fdbased_darwin/processors.go`
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
calculated from the configured TUN MTU. Because packet-pool allocations round
up and the cap is per processor, real retained memory is higher: at MTU 1500,
each processor can retain about 700 KiB of packet backing plus metadata.
Packets arriving while that queue is full are not retained. TCP recovers
through its normal retransmission and congestion-control behavior; UDP can lose
a datagram during sustained overload. The patch keeps the existing
multi-processor receive path and does not reduce TCP window sizes.

The CI preparation script verifies the exact module version and SHA-256 of the
upstream source, copies the module to the runner's temporary directory, applies
the patch there, and adds a version-qualified temporary `replace` directive.
An unexpected dependency upgrade or source change fails the build instead of
silently applying an outdated patch.

On initial startup, MiClash also calls `debug.FreeOSMemory()` after Mihomo
applies the configuration. This returns parser and GEO-loading scratch pages;
live configuration reloads deliberately skip the extra full GC.

### Verification

CI runs the queue-boundary regression tests from the patched module and compiles
MobileCore with `with_gvisor,with_low_memory` before `gomobile bind`.

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
