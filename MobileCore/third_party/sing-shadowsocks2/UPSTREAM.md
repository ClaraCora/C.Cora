# Upstream snapshot

- Module: `github.com/metacubex/sing-shadowsocks2`
- Version: `v0.2.7`
- Commit: `7f844b0df8db54b1658884fb8c15cb7da5778f18`
- Module sum: `h1:hSuuc0YpsfiqYqt1o+fP4m34BQz4e6wVj3PPBVhor3A=`
- License: GPL-3.0-or-later; see `LICENSE`

This directory is a source snapshot used by the version-qualified replacement
in `../../go.mod`. MiClash changes are documented in
`../../THIRD_PARTY_PATCHES.md`.

When updating the snapshot, first remove the local changes, replace all files
from the selected upstream tag, record its commit and module sum, then reapply
and rerun the MiClash regression tests. Do not change the version in `go.mod`
without reviewing the upstream Reader and buffer allocation behavior again.
