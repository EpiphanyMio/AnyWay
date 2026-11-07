#!/usr/bin/env bash
set -euo pipefail

destination="EpiphanyMio/AnyWay"
source_repo="EpiphanyMio/WinLS"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

gh release edit v1.1.0 --repo "$destination" --title "AnyWay 1.1.0"

mkdir -p "$workspace/stable" "$workspace/beta"
gh release download v0.1.0 --repo "$source_repo" --dir "$workspace/stable"
(
  cd "$workspace/stable"
  printf '%s  %s\n' \
    '59cb09e51fca54f5cd0635261c91a8794bf25c2f74439bc960e9de3fa8c94473' 'WinLS-0.1.0-Android.apk' \
    'f105c238006eca9c5461b2fe610e6c451d5cbd5c00fd7f1b5103d9c0b57654d4' 'WinLS-0.1.0-Windows-Setup.exe' \
    | sha256sum --check
)
{
  printf '%s\n\n' 'Windows 0.1.0 历史安装包，从原 WinLS 仓库迁移。安装包仍使用原有 WinLS 文件名；源码已合并到 AnyWay 的 windows/ 目录。'
  gh release view v0.1.0 --repo "$source_repo" --json body --jq '.body'
} > "$workspace/stable-notes.md"
if gh release view v0.1.0 --repo "$destination" >/dev/null 2>&1; then
  gh release edit v0.1.0 --repo "$destination" --title "AnyWay 0.1.0" --notes-file "$workspace/stable-notes.md"
  gh release upload v0.1.0 "$workspace/stable"/* --repo "$destination" --clobber
else
  gh release create v0.1.0 "$workspace/stable"/* --repo "$destination" \
    --target "$GITHUB_SHA" --title "AnyWay 0.1.0" --notes-file "$workspace/stable-notes.md" \
    --latest=false
fi

gh release download v0.1.0-beta.1 --repo "$source_repo" --dir "$workspace/beta"
(
  cd "$workspace/beta"
  printf '%s  %s\n' \
    '5f5a9417520efe4e4d96368d50c20a8059ec35cafbd28bfd762e44a7ed4f8dce' 'WinLS-0.1.0-beta.1-Windows-Setup.exe' \
    | sha256sum --check
)
{
  printf '%s\n\n' 'Windows 0.1.0 beta.1 历史预发布安装包，从原 WinLS 仓库迁移。安装包保留原文件名。'
  gh release view v0.1.0-beta.1 --repo "$source_repo" --json body --jq '.body'
} > "$workspace/beta-notes.md"
if gh release view v0.1.0-beta.1 --repo "$destination" >/dev/null 2>&1; then
  gh release edit v0.1.0-beta.1 --repo "$destination" --title "AnyWay 0.1.0 beta.1" \
    --notes-file "$workspace/beta-notes.md" --prerelease
  gh release upload v0.1.0-beta.1 "$workspace/beta"/* --repo "$destination" --clobber
else
  gh release create v0.1.0-beta.1 "$workspace/beta"/* --repo "$destination" \
    --target "$GITHUB_SHA" --title "AnyWay 0.1.0 beta.1" \
    --notes-file "$workspace/beta-notes.md" --prerelease --latest=false
fi
