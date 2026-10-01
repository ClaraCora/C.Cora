# Third-party patches

## v1.19.31 migration (2026-09-30)

The active build uses Mihomo v1.19.31, sing-tun v0.4.24,
sing-shadowsocks2 v0.2.8, and gVisor 79317d808312. Preparation scripts pin
these versions and verify pristine and patched source hashes. All seven
Mihomo patches, the sing allocator patch, and the Shadowsocks/gVisor patches
are retained. The sing-tun endpoint hunk was adapted to the new upstream
processor option while preserving the existing receive/send queue bounds.

Benchmark and fuzz results in the individual patch sections were recorded
before this migration, on Mihomo v1.19.30 and its then-current dependencies;
they have not been relabeled as measurements of v1.19.31. Current regression
coverage and the remaining macOS/device checks are recorded in
[the upgrade verification record](../docs/ne-memory-optimization-v1.19.31.md).

## mihomo-v1.19.31-bounded-mrs-decode

- Added: 2026-09-30
- Upstream module: `github.com/metacubex/mihomo v1.19.31`
- Patched file: `rules/provider/mrs_reader.go`; added
  `rules/provider/mrs_decoder.go` and its regression tests
- Build tags: default and `with_low_memory`

### Reason

The upstream MRS reader feeds a `bytes.Reader` into the streaming decoder in
`github.com/klauspost/compress/zstd v1.17.9`. An MRS frame can advertise an
8 MiB history window even when its decoded rule data occupies less than 1 MiB.
Streaming decoding reserves that window plus scratch space. Provider loading
and refresh can therefore create substantial temporary allocation pressure in
the Network Extension. Decoder low-memory mode is already enabled upstream;
enabling it again, or only reducing decoder concurrency, does not remove that
window allocation.

### Local behavior

A small, allocation-free frame probe determines a conservative decoded output
bound before selecting a decoder. It uses the frame content size when present,
or walks block headers when the streaming encoder omitted it. Compressed blocks
are bounded by `min(window size, 128 KiB)`; raw and RLE blocks state their output
size. Only a complete, single frame whose bound is at most 2 MiB takes the new
path. Zstandard remains responsible for validating compressed data and checksums.

That path uses `DecodeAll` with an explicitly sized output buffer and
`WithDecodeAllCapLimit(true)`. The output doubles as decompression history, and
the decoder is closed before rule parsing. There is no persistent decoder pool
or retained decompressed-file cache. One decoder handles each one-shot call;
this does not serialize providers or change network connection concurrency.

Large, concatenated, skippable, or unrecognized frames use the original streaming
decoder immediately, without a speculative output allocation or a second decode.
The 2 MiB threshold is an optimization boundary, not a new MRS file-size limit
or a bound on total NE memory. Domain/IP rule structures and matching are
unchanged. Reserved MRS extension data is discarded through a bounded copy
instead of allocating its entire declared length. Eligible frames are fully
decoded and checksum-validated before parsing, so a corrupt checksum cannot be
missed when the rule parser stops reading at the end of its own data.

### Verification

- All existing patches plus this patch apply to a clean v1.19.30 module.
  Preparation checks all touched source and output hashes and refuses unexpected
  upstream files with the new names.
- `go test` and `go vet ./rules/provider` pass with default and `with_low_memory`
  builds. CI now includes this package in both test/vet lists.
- Tests cover domain/IP round trips and matching, known/unknown content size,
  small/large windows, the exact buffer boundary and streaming fallback, raw/RLE
  blocks, concatenated/skippable frames, truncated input, corrupt checksums,
  invalid MRS fields, and oversized reserved-data declarations.
- A 30-second `FuzzMrsDecodedCapacity` run completed 1,237,273 inputs without a
  failure. The fuzz oracle independently checks the inferred capacity against
  a bounded reference decode.
- All 51 public MRS resources referenced by the test configuration produce
  byte-identical decoded payloads and serialized rule sets, with identical
  counts. All 51 use the bounded path. Private subscription content is not
  included in the patch or tests.
- `GOOS=ios GOARCH=arm64 CGO_ENABLED=0 go build -tags with_low_memory
  ./rules/provider` passes. This verifies the Go package, not the complete
  gomobile/Xcode build or behavior on an iPhone.

Full rule-parse benchmark on Windows/amd64, Go 1.25.4, GOMAXPROCS=4,
`with_low_memory`, default Go GC settings, three 500 ms runs (medians):

| Public rule set | Before MiB/op | After MiB/op | Before ms/op | After ms/op |
| --- | ---: | ---: | ---: | ---: |
| proxy_domain | 10.62 | 1.19 | 1.37 | 1.16 |
| kelee_ChinaMax_domain | 12.91 | 2.73 | 3.21 | 3.64 |
| kelee_Global_domain | 11.15 | 1.48 | 1.71 | 1.47 |
| kelee_SpeedtestInternational_domain | 10.88 | 1.20 | 1.40 | 1.15 |
| kelee_ChinaMax_ipcidr | 10.67 | 1.28 | 2.41 | 1.81 |
| All 51, one sequential load | 57.52 | 9.19 | 11.49 | 10.69 |

MiB/op means cumulative bytes allocated during each complete parse, including
rule construction. It is neither simultaneous live memory nor measured iOS
physical footprint. The batch allocates about 84% less and finishes about 7%
faster in this experiment. The largest domain set takes about 0.43 ms longer;
the change does not promise faster loading for every file. Network forwarding
is outside this code path. Device measurements and termination logs are still
needed to assess the reported iOS VPN exits.

The committed synthetic decoder benchmark is reproducible with
`go test ./rules/provider -run '^$' -bench BenchmarkMrsLargeWindow -benchmem`.
It compares the original streaming reader with the bounded decoder; its numbers
are decoder-only and should not be substituted for the full-parse table above.

### Rollback

Remove the bounded MRS patch, its preparation-script paths/hashes/apply wiring,
and `./rules/provider` from the Mihomo CI test/vet lists as one change. No rule
file conversion, configuration change, or stored-data migration is involved.

## mihomo-v1.19.31-atomic-dns-runtime

- Added: 2026-08-23
- Upstream module: `github.com/metacubex/mihomo v1.19.31`
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

- `dependency-patches/mihomo-v1.19.31-atomic-dns-runtime.patch`;
- its preparation-script paths, hashes, and apply wiring;
- `./component/resolver`, `./dns`, `./hub/executor`, and `./hub/route` from the
  Mihomo CI test and vet package lists; and
- the MobileCore `CurrentDNSRuntime` / `PublishDNSRuntime` calls.

Restore the original direct assignments only as one rollback unit. Removing
just the patch while leaving MobileCore's snapshot API calls will intentionally
fail compilation. No stored configuration or user-data migration is involved.

## mihomo-v1.19.31-reserved-synthetic-ip-guard

- Added: 2026-08-23
- Upstream module: `github.com/metacubex/mihomo v1.19.31`
- Patched file: `tunnel/tunnel.go`; added
  `tunnel/reserved_synthetic_ip.go` and its regression tests
- Build tags: default and `with_low_memory`

### Reason

Cora's TUN and Fake-IP pool use `198.18.0.0/16`, which belongs to RFC 2544's
full `198.18.0.0/15` benchmarking range. During a live DNS transition, or when
another DNS server returns an address from that reserved range, Mihomo can
receive a connection whose destination remains synthetic after DNS
preprocessing. Without a guard, the address can match a `private_ip` rule and
be sent to DIRECT. Dialing it then times out and repeated failures can make the
device appear offline.

This protection is independent of the configured DNS enhanced mode. It is
needed even with `redir-host`, because stale DNS answers can survive a mode or
network transition and an upstream Wi-Fi DNS server can return its own
synthetic address.

### Local behavior

MobileCore registers the complete RFC 2544 range through
`tunnel.SetReservedSyntheticIPPrefixes`. The tunnel first performs Mihomo's
normal reverse lookup. A current Fake-IP mapping is consumed by Mihomo and
clears the destination IP, so it continues normally. A `redir-host` mapping
does not clear the destination IP; if that IP remains in the protected range,
the tunnel rejects it before rule matching rather than allowing `private_ip` to
send it to DIRECT. This also rejects stale or otherwise unrecognised addresses
from the other half of the RFC 2544 range.

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
isolation, current Fake-IP mapping preservation, `redir-host` protection,
unregistered addresses, TCP sniff recovery, UDP mapping-eviction handling,
and power-of-two diagnostics.

### Rollback

Revert the commit that added this section and remove:

- `dependency-patches/mihomo-v1.19.31-reserved-synthetic-ip-guard.patch`;
- its preparation-script SHA and apply wiring;
- `./tunnel` from the Mihomo CI test and vet package lists; and
- the MobileCore calls to `tunnel.SetReservedSyntheticIPPrefixes`.

No stored configuration or user-data migration is involved.

## mihomo-v1.19.31-connection-close-queue

- Added: 2026-08-13
- Upstream module: `github.com/metacubex/mihomo v1.19.31`
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
the FIFO. After the caller advances its cursor, the next read clears consumed
`TrackerInfo` references and keeps only cursor numbers for overflow detection;
`ClosedPending` exposes the remaining in-flight count for diagnostics.
The Packet Tunnel parses each close-queue payload once, reusing the parsed cursor
and overflow flag alongside its records. Its history writer finalizes each
per-row SQLite update before preparing the next one, so a full batch does not
hold hundreds of native statements until the transaction ends.
At the stop boundary, after closing tracked connections, Cora calls
`DiscardClosed` because the recorder has already stopped and no final rows can
be persisted; this releases the ring immediately and resets its session cursor.
The Packet Tunnel drains this queue every two seconds into its SQLite history;
the active-connection snapshot is sampled separately every eight seconds.
SQLite retains at most seven days, 20,000 rows, or 50 MiB, with retention/WAL
maintenance performed once per minute. Live packets never wait for this work.

At more than roughly 256 short-lived connections per second for a sustained
two-second interval, the FIFO can overflow. Some finished detail rows can then
be absent, and the extension writes a diagnostic log entry, but packet
forwarding, active connections, and the extension memory limit are unaffected.

### Verification

The Mihomo preparation script verifies the exact upstream source and patched
SHA-256 hashes. CI runs `./tunnel/statistic` together with the existing pool
and config checks in both default and `with_low_memory` modes. The patch suite
checks an empty cursor response, confirms copied tracker counters are no longer
aliased to the live tracker, verifies that closed snapshots do not retain the
runtime-only provider-name chain, and confirms `DiscardClosed` releases the
entire ring at shutdown.

### Rollback

Revert the commit that added this section and remove:

- `dependency-patches/mihomo-v1.19.31-connection-close-queue.patch`;
- `dependency-patches/mihomo-v1.19.31-connection-close-queue-test.patch`;
- the history patch preparation and verification wiring;
- `ClosedConnectionsSnapshot` and the Packet Tunnel history recorder.

Existing App Group history can simply be left in place; it is not read by
earlier versions.

## sing-and-mihomo-ss-record-oversize-buffer-pool

- Added: 2026-07-25
- Upstream modules: `github.com/metacubex/sing v0.5.7`,
  `github.com/metacubex/mihomo v1.19.31`
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
dedicated, exact 65552-byte bounded channel. Sizes from 65536 through 65552 are
managed: 65536 keeps using the existing 64 KiB bucket, while 65537 through
65552 use the new bucket. Sizes below 65536 and above 65552 retain their
upstream behavior. In particular, this does not add a generic 128 KiB bucket,
change cipher framing, retain a record buffer on each connection, or copy
plaintext on the relay path.

During contention each allocator now retains at most eight 65552-byte backing
arrays (about 512 KiB per allocator, 16 arrays and about 1 MiB combined across
sing and Mihomo). The dedicated channel has an exact capacity, so garbage
collection cannot desynchronize a separate counter and disable reuse; normal
power-of-two buckets keep their upstream `sync.Pool` behavior. This replaces
per-record backing allocation without adding per-connection retention.

### Verification

The preparation scripts lock both module versions and verify SHA-256 hashes
before and after applying each patch. CI runs both allocator boundary suites in
default and low-memory modes. Mihomo's test imports sing, verifies that its
allocator replacement is installed, and asserts that `buf.NewSize(65551)` uses
the exact bucket and that the bounded oversize channel never exceeds its eight
buffer limit. The patched SS2 module is also forced to resolve this exact
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
- `dependency-patches/mihomo-v1.19.31-oversize-buffer-pool.patch`;
- `scripts/prepare-ios-sing.sh` and its CI invocation;
- `scripts/prepare-ios-mihomo.sh` and its CI invocation;
- the `PATCHED_SING_DIR` wiring in `prepare-ios-sing-shadowsocks2.sh`;
- this section of the patch record.

No configuration or user-data migration is involved.

## steady-memory-diagnostics-and-idle-buffer-trim

- Added: 2026-10-02
- Upstream modules: Mihomo v1.19.31, sing v0.5.7, sing-tun v0.4.24,
  gVisor v0.0.0-20260826100401-79317d808312
- Diagnostic patches: `mihomo-v1.19.31-memory-diagnostics.patch`,
  `sing-v0.5.7-memory-diagnostics.patch`,
  `sing-tun-v0.4.24-memory-diagnostics.patch`, and
  `gvisor-79317d808312-memory-diagnostics.patch`
- Preparation: applied after functional patches and their source-hash checks.
  The patched sing-tun and Mihomo modules use the same patched gVisor/sing-tun
  dependencies as MobileCore, including standalone dependency tests.

### Behavior and accounting limits

Both oversize pools expose `GetOversizePoolStats()` and `TrimIdle()`. Each
retains at most eight 65552-byte buffers; the combined upper bound is 1048832
bytes (about 1 MiB). A trim drains at most the initial idle count and does not
modify in-flight buffers or future returns. Normal Get/Put reuse, pool limits,
and power-of-two `sync.Pool` buckets remain unchanged. No lock or per-packet
counter is added to buffer allocation or packet processing.

MobileCore trims before the existing `debug.FreeOSMemory()` operation. A shared
20-second cooldown covers manual release and both existing pressure listeners.
Suppressed calls neither trim again nor force another GC. Normal GOGC,
GOMEMLIMIT, gVisor, DNS/cache limits, concurrency and IPC budgets are unchanged.

`RuntimeStats()` additionally queries retained DNS/mapping entries, in-memory
Fake-IP mappings, proxy/rule provider counts, true policy-group counts, GEO
mode/loader/matcher and optional disk asset sizes. DNS caches shared by roles
are counted once; reads do not perform lookups, refresh TTLs or evict entries.
Persistent Fake-IP databases are not scanned; their entry count is omitted.
Rule providers publish one atomic count at load/update time, so diagnostics
do not race against strategy replacement.

Darwin TUN queues expose optional waiting packet counts and summed packet
lengths under existing locks. These exclude dispatch batches, GRO, socket
buffers and backing allocation capacity. Unsupported targets/stacks omit the
fields. NativeTun owns and clears its diagnostic sources at close; no global
registry retains an old endpoint. Listener snapshots serialize with TUN
replacement and cleanup.

Collection is on demand or uses the existing developer-mode sampler; no new
background task runs in normal use. Pool/queue bytes overlap Go heap metrics,
provider and DNS counts are not byte estimates, and GEO disk sizes are not
resident memory. These values must not be summed into a physical footprint.
Swift stores the latest release pair in the bounded summary, handles omitted
optional metrics and old NE responses, and never pairs separate VPN sessions.

### Verification and rollback

Default and low-memory Go tests cover pool reuse/trim/concurrency, DNS cache
deduplication, Fake-IP, provider publication and runtime accounting. Queue
wraparound/concurrent snapshots pass on Windows; Darwin queue tests and the
MobileCore binding package cross-compile for arm64. All four diagnostic patches
apply to clean functional-patch baselines with strict whitespace checks and
produce byte-identical Go sources; previous functional-patch SHA checks pass.
Go vet passes for MobileCore and the affected Mihomo packages. CI includes
macOS race checks, Darwin tests and standalone Swift analyzer regressions.
Swift/Xcode builds, race execution and 48-hour device verification have not
been run locally. See [the device verification guide](../docs/ne-steady-memory-diagnostics.md).

Rollback MobileCore's new pool/attribution API calls together with the four
diagnostic patches, preparation wiring and added CI checks. Keep the earlier
functional allocator, queue, DNS, MRS and Shadowsocks patches. The Swift fields
are optional and can remain compatible with an older NE. No configuration or
stored-data migration is required.

## sing-shadowsocks2-v0.2.8-reusable-length-buffer

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/sing-shadowsocks2 v0.2.8`
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

- `dependency-patches/sing-shadowsocks2-v0.2.8-length-buffer.patch`;
- `scripts/prepare-ios-sing-shadowsocks2.sh` and its CI invocation;
- this section of the patch record.

No configuration or user-data migration is involved.

## sing-tun-v0.4.24-darwin-queue-bounds

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/sing-tun v0.4.24`
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
calculated from the configured TUN MTU. Upstream v0.4.24 defaults to one receive
processor and exposes a processor option. Cora keeps one processor per Darwin
TUN channel so its queue cap cannot be multiplied by the device CPU count or
that experimental option. Because packet-pool allocations round up, real retained memory is
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

- `dependency-patches/sing-tun-v0.4.24-darwin-queue.patch`;
- `scripts/prepare-ios-sing-tun.sh` and its CI invocation;
- the post-`ApplyConfig` `debug.FreeOSMemory()` call;
- this section of the patch record.

No configuration or user-data migration is involved.

## gvisor-79317d808312-tcp-pure-ack-queue

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/gvisor v0.0.0-20260826100401-79317d808312`
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

- `dependency-patches/gvisor-79317d808312-tcp-ack-queue.patch`;
- `scripts/prepare-ios-gvisor.sh` and its CI invocation;
- this section of the patch record.

No configuration or user-data migration is involved.
