#!/usr/bin/env bash
set -euo pipefail

# All inputs come from this successful Actions build, never from user IPA files.
: "${GH_TOKEN:?GitHub token is required}"
: "${GITHUB_REPOSITORY:?Repository is required}"
: "${GITHUB_SHA:?Build commit is required}"
: "${GITHUB_RUN_ID:?Run ID is required}"
: "${GITHUB_RUN_NUMBER:?Build number is required}"
: "${GITHUB_RUN_ATTEMPT:?Run attempt is required}"
: "${RUNNER_TEMP:?Runner temporary directory is required}"
: "${APP_VERSION:?App version is required}"

files=(Cora-unsigned.ipa Cora-TrollStore.ipa CoraLegacy-unsigned.ipa CoraLegacy-TrollStore.ipa)
for file in "${files[@]}"; do
  if [[ ! -s "$file" ]]; then
    echo "Missing or empty IPA: $file" >&2
    exit 1
  fi
done

release_tag="build-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
release_title="Cora ${APP_VERSION} · Build ${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}"
server="${GITHUB_SERVER_URL:-https://github.com}"
release_url="$server/$GITHUB_REPOSITORY/releases/tag/$release_tag"
release_dir="$(mktemp -d "$RUNNER_TEMP/cora-release.XXXXXX")"
checksums="$release_dir/SHA256SUMS.txt"
notes_file="$release_dir/notes.md"
# Only these two files are created here; no recursive cleanup is necessary.
trap 'rm -f -- "$checksums" "$notes_file"; rmdir -- "$release_dir"' EXIT

shasum -a 256 --binary "${files[@]}" > "$checksums"
{
  printf 'Cora %s，构建 %s.%s。\n\n' "$APP_VERSION" "$GITHUB_RUN_NUMBER" "$GITHUB_RUN_ATTEMPT"
  printf '提交：%s\n\n' "$GITHUB_SHA"
  cat <<'NOTES'
| 文件 | 适用版本与安装方式 |
| --- | --- |
| `Cora-unsigned.ipa` | 标准版，iOS 17+，使用自己的证书签名 |
| `Cora-TrollStore.ipa` | 标准版 TrollStore 包，需设备与系统支持 TrollStore |
| `CoraLegacy-unsigned.ipa` | Legacy，iOS 16.4+，使用自己的证书签名 |
| `CoraLegacy-TrollStore.ipa` | Legacy TrollStore 包，需设备与系统支持 TrollStore |

标准版与 Legacy 共用 Bundle ID，为替换安装关系。TrollStore 包不含控制中心磁贴。
附带 `SHA256SUMS.txt`，可用于核对下载完整性。本构建尚未经过真机验收。
NOTES
  printf '\n[构建日志](%s/%s/actions/runs/%s)\n' "$server" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
} > "$notes_file"

# Keep incomplete uploads private as a draft. Publish only after all four IPAs
# and their checksums are uploaded; each run/attempt gets its own immutable tag.
gh release create "$release_tag" --repo "$GITHUB_REPOSITORY" \
  --target "$GITHUB_SHA" --title "$release_title" --notes-file "$notes_file" \
  --draft --prerelease
gh release upload "$release_tag" --repo "$GITHUB_REPOSITORY" \
  "${files[@]}" "$checksums"
gh release edit "$release_tag" --repo "$GITHUB_REPOSITORY" \
  --draft=false --prerelease --latest=false

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '### IPA 下载\n\n[打开 GitHub Release](%s)\n\n包含标准版、Legacy 的普通与 TrollStore IPA，以及 SHA-256 校验文件。\n' \
    "$release_url" >> "$GITHUB_STEP_SUMMARY"
fi
echo "IPA release published: $release_url"
