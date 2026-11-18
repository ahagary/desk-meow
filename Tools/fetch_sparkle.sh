#!/bin/zsh
set -euo pipefail

# Pin both the official release and its SHA-256 for reproducible local/CI builds.
sparkle_version='2.10.1'
sparkle_sha256='1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'
cache_root="${ZHUOMI_DEPENDENCY_CACHE:-$HOME/.cache/zhuomi}"
destination="$cache_root/Sparkle-$sparkle_version"
if [[ -f "$destination/.verified-$sparkle_sha256" && -d "$destination/Sparkle.framework" ]]; then
  print "$destination"
  exit 0
fi
mkdir -p "$cache_root"
download_dir="$(mktemp -d "$cache_root/.sparkle-download.XXXXXX")"
trap 'rm -rf "$download_dir"' EXIT
archive="$download_dir/Sparkle.tar.xz"
curl --fail --location --retry 2 --connect-timeout 20 --max-time 180 \
  "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
  --output "$archive" >&2
actual_sha256="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
[[ "$actual_sha256" == "$sparkle_sha256" ]] || { print -u2 'Sparkle 下载校验失败'; exit 1; }
mkdir "$download_dir/extracted"
tar -xJf "$archive" -C "$download_dir/extracted"
[[ -d "$download_dir/extracted/Sparkle.framework" && -x "$download_dir/extracted/bin/generate_appcast" ]]
touch "$download_dir/extracted/.verified-$sparkle_sha256"
[[ ! -e "$destination" ]] || { print -u2 "依赖缓存需要检查：$destination"; exit 1; }
mv "$download_dir/extracted" "$destination"
print "$destination"
