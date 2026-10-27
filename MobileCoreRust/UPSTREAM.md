# Upstream provenance

- meow-ios FFI source: `meow-rs/meow-ios` commit `f8d7601924a7be339cf8544a51a101f6158fbf60`.
- meow-rs engine, lwIP and all engine crates: immutable commit `fa7a7d6dc94e886ae0bc43eeb0227082ae5bf2e6` (v0.26.1 plus iOS system SQLite linkage).
- Original MIT license is in `LICENSE.meow-ios`. Local changes live in `cora-*` modules and are reviewed with the rest of Cora.
- Both `Cargo.lock` files are supplied with the implementation and must be versioned with it. Build and test with `--locked`; do not run `cargo update` during CI.
- Only iOS arm64 device and arm64 simulator are packaged. No tvOS, Legacy or TrollStore artifacts.
