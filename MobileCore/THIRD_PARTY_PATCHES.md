# Third-party patches

## ss2022-max-record-buffer-reuse

- Added: 2026-07-25
- Upstream module: `github.com/metacubex/sing-shadowsocks2 v0.2.7`
- Upstream commit: `7f844b0df8db54b1658884fb8c15cb7da5778f18`
- Upstream module sum: `h1:hSuuc0YpsfiqYqt1o+fP4m34BQz4e6wVj3PPBVhor3A=`
- Local source: `third_party/sing-shadowsocks2`
- Build tags under test: `with_low_memory` and `with_gvisor,with_low_memory`

### Reason

SS2022 permits a plaintext record of 65535 bytes. Adding the 16-byte AEAD tag
creates a 65551-byte ciphertext. In sing v0.5.7, `buf.NewSize` uses an unmanaged
allocation above 65535 bytes, so a peer sending maximum-size records caused a
new large allocation for every record. At high throughput and concurrency this
is a suspected contributor to allocation/GC pressure near the iOS Network
Extension memory budget.

### Local behavior

Only ciphertexts larger than the `buf.NewSize` managed-allocation boundary of
65535 bytes use the patched branch. On the first such record, that Reader
lazily allocates one 65551-byte buffer. It reads and decrypts in place, then
reuses the same backing buffer for later oversized records on that connection.
`Read` and `ReadBuffer` copy from it into the caller's existing destination;
`WaitReadBuffer` returns managed, MTU-sized chunks so it never needs a second
64 KiB plaintext buffer. Records at or below the allocator boundary keep the
old zero-copy path.

`Reader.Close` releases any cached managed buffer and removes the reference to
the reusable oversized buffer. The Shadowsocks connection already closes its
Reader, so early disconnects do not retain a partially consumed record until
the entire connection wrapper is garbage-collected.

The patch does not change:

- the SS2022 wire format;
- the current low-memory Writer record size;
- compliant classic Shadowsocks records, which remain below this boundary;
- `ReadWaiter`, UDP, UOT, plugin, or Mihomo adapter interfaces;
- the pinned Mihomo version.

The tradeoff matches the reusable Reader design in newer sing-shadowsocks: a
connection that receives an oversized record retains about 64 KiB until close,
and oversized `ReadWaitBuffer` delivery adds one memory copy plus smaller
managed output buffers. The local backport is lazy and only changes oversized
records, avoiding the fixed buffer and copy cost for ordinary records. It does
not claim to fix every possible SS2022 throughput or Network Extension memory
limit; device testing remains required.

### Files changed from upstream

- `internal/shadowio/reader.go`
- `internal/shadowio/reader_test.go` (MiClash regression tests)
- `UPSTREAM.md` (snapshot metadata)

### Verification

From `MobileCore`:

```sh
go list -m -f '{{.Version}}|{{if .Replace}}{{.Replace.Path}}{{end}}' github.com/metacubex/sing-shadowsocks2
go test github.com/metacubex/sing-shadowsocks2/internal/shadowio
go test -tags with_low_memory github.com/metacubex/sing-shadowsocks2/internal/shadowio
go test -tags with_gvisor,with_low_memory ./...
```

The first command must print:

```text
v0.2.7|./third_party/sing-shadowsocks2
```

Local verification on 2026-07-25 passed in default and low-memory modes,
including 65519/65520/65535-byte boundaries, deterministic backing-buffer
reuse, fragmented input, authentication errors, returned-buffer isolation,
early-close cleanup, `ReadWaiter` headroom/MTU handling, and 16 concurrent
readers. The benchmark covers 64 maximum-size records per Reader so regressions
in reuse are visible without presenting desktop throughput as an iOS claim. On
the local Windows run, the entire 64-record batch used about 78 KB and 68
allocations (roughly 1.2 KB allocated per record after amortizing the one large
Reader buffer), rather than one large allocation for every record.
The race detector was not available locally because the Windows host does not
have the C compiler required by `go test -race`.

### Rollback

The preferred rollback is to revert the single commit containing this patch.
For a manual rollback:

1. Remove the version-qualified `replace` directive from `go.mod`.
2. Remove the CI module assertion and the third-party regression-test command.
3. Remove `third_party/sing-shadowsocks2` and this patch record.
4. Run `go mod tidy` and rebuild. Mihomo will resolve the original upstream
   `sing-shadowsocks2 v0.2.7` again.

No configuration migration or user-data rollback is required.
