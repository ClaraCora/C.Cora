# iOS ARM64 AES-GCM acceleration

MiClash uses Shadowsocks 2022 with ciphers such as
`2022-blake3-aes-256-gcm`. Go 1.25.4 does not probe ARM64 CPU features on
iOS, so its standard-library AES-GCM implementation otherwise falls back to
generic AES and GHASH code.

The CI build copies the Go installation into the runner's temporary directory
and applies `toolchain-patches/go1.25.4-ios-arm64-crypto.patch` to that copy.
The patch enables only the AES and PMULL flags for `ios && arm64`. The original
`actions/setup-go` installation is never modified.

## Safety checks

- The workflow is pinned to Go 1.25.4 and iOS 18.0.
- The unmodified and patched Go source files are verified by SHA-256.
- CI verifies that the iOS-specific initializer is selected and compiles the
  standard-library AES packages before running `gomobile bind`.
- CI verifies the device and simulator architectures in the produced
  XCFramework.

ARM crypto extensions cannot be probed by this Go version on iOS. The patch
therefore relies on the project's iOS 18 iPhone hardware floor. Before a
release, test the oldest supported device for `EXC_BAD_INSTRUCTION` and compare
SS2022 throughput and memory with 1, 4, and 8 concurrent streams.

## A/B test and rollback

Commit `be9e7b8` is the unmodified Go 1.25.4 baseline. Compare its artifact
against an artifact containing this patch with the same configuration and
test server.

To roll back, remove the toolchain preparation step from CI together with this
document, the preparation script, and the toolchain patch. No application data
or Shadowsocks dependency migration is involved.
