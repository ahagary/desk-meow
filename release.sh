#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
version="$(<"$project_dir/VERSION")"
app_dir="$project_dir/build/桌咪.app"
executable="$app_dir/Contents/MacOS/TabbyDesktopPet"
dist_dir="$project_dir/dist"
artifact_name="ZhuoMi-${version}-macOS-arm64"
identity="${CODESIGN_IDENTITY:--}"
notary_profile="${NOTARYTOOL_PROFILE:-}"
generate_update_feed="${GENERATE_UPDATE_FEED:-1}"
sparkle_dir="$("$project_dir/Tools/fetch_sparkle.sh")"
keychain_account='local.tabby.desktop.pet'
release_notes="$project_dir/ReleaseNotes/$version.md"
[[ -f "$release_notes" ]] || { print -u2 "缺少版本说明：$release_notes"; exit 1; }
if [[ "$generate_update_feed" == 1 && -z "${SPARKLE_PRIVATE_KEY:-}" && -z "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  "$sparkle_dir/bin/generate_keys" --account "$keychain_account" -p >/dev/null || {
    print -u2 '缺少更新签名密钥。请使用本机钥匙串，或设置 SPARKLE_PRIVATE_KEY_FILE；CI 使用 ZHUOMI_SPARKLE_PRIVATE_KEY secret。'
    exit 1
  }
fi

if [[ -n "$notary_profile" && "$identity" == '-' ]]; then
  print -u2 'Apple 公证需要 CODESIGN_IDENTITY 指定 Developer ID Application 证书。'
  exit 1
fi
if [[ "$identity" != '-' && -z "$notary_profile" ]]; then
  print -u2 'Developer ID 发布需要同时设置 NOTARYTOOL_PROFILE，以完成 Apple 公证。'
  exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
  print -u2 '请在 Apple Silicon Mac 上运行 release.sh，以执行 arm64 程序的发布前检查。'
  exit 1
fi

# Always rebuild from source; never repackage an old local executable.
APP_VERSION="$version" "$project_dir/build.sh"
[[ "$(lipo -archs "$executable")" == arm64 ]] || { print -u2 '构建产物不是 arm64'; exit 1; }
"$executable" --validate-resources
"$executable" --check-animation-flow
"$executable" --check-feeding
"$executable" --check-interaction
"$executable" --check-notes

mkdir -p "$dist_dir"
work_dir="$(mktemp -d "$project_dir/build/.release.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
signing_status='Ad-hoc 签名，未经过 Apple 公证；首次打开可能被 macOS 拦截。'
if [[ "$identity" != '-' ]]; then
  # Re-sign nested Sparkle code from the inside out with the application's Team ID.
  # Preserve the vendor's helper entitlements when applying Hardened Runtime.
  sparkle_framework="$app_dir/Contents/Frameworks/Sparkle.framework"
  for nested_code in \
    "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc" \
    "$sparkle_framework/Versions/B/XPCServices/Installer.xpc" \
    "$sparkle_framework/Versions/B/Autoupdate" \
    "$sparkle_framework/Versions/B/Updater.app" \
    "$sparkle_framework"; do
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
      --sign "$identity" "$nested_code"
  done
  codesign --force --options runtime --timestamp --sign "$identity" "$app_dir"
  codesign --verify --deep --strict --verbose=2 "$app_dir"
  ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$work_dir/notarization.zip"
  xcrun notarytool submit "$work_dir/notarization.zip" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$app_dir"
  xcrun stapler validate "$app_dir"
  spctl --assess --type execute --verbose=2 "$app_dir"
  signing_status='Developer ID 签名，已通过 Apple 公证。'
fi

mkdir -p "$work_dir/dmg"
ditto "$app_dir" "$work_dir/dmg/桌咪.app"
ln -s /Applications "$work_dir/dmg/Applications"
cat > "$work_dir/dmg/安装说明.txt" <<EOF
桌咪 $version

适用于 Apple Silicon（M1/M2/M3/M4 等），最低 macOS $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_dir/Contents/Info.plist")。
把「桌咪.app」拖入 Applications，再从“应用程序”打开。
点击猫咪打开待办和便签；从菜单栏退出。安装者不需要 Xcode 或 Python。

$signing_status
如果下载的是未公证版本，确认来源可信后，可在首次打开被阻止后前往
“系统设置 → 隐私与安全性 → 仍要打开”。不需要关闭系统安全机制。

个人数据保存在 ~/Library/Application Support/TabbyDesktopPet/data.json。
从 0.1.x 升级时先退出旧版本，再安装「桌咪.app」，移除原名称的应用，避免重复启动。
个人数据与设置继续保留。安装 0.2.0 后，后续版本可通过菜单中的「检查更新…」下载、安装并重启。
EOF
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$work_dir/$artifact_name.zip"
hdiutil create -volname "桌咪 $version" -srcfolder "$work_dir/dmg" \
  -format UDZO -ov "$work_dir/$artifact_name.dmg"
if [[ "$identity" != '-' ]]; then
  codesign --timestamp --sign "$identity" "$work_dir/$artifact_name.dmg"
  xcrun notarytool submit "$work_dir/$artifact_name.dmg" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$work_dir/$artifact_name.dmg"
  xcrun stapler validate "$work_dir/$artifact_name.dmg"
fi
hdiutil verify "$work_dir/$artifact_name.dmg"
cp "$release_notes" "$work_dir/release-notes.md"
print "\n签名状态：$signing_status" >> "$work_dir/release-notes.md"
if [[ "$generate_update_feed" == 1 ]]; then
  mkdir "$work_dir/feed"
  cp "$work_dir/$artifact_name.zip" "$work_dir/feed/"
  cp "$release_notes" "$work_dir/feed/$artifact_name.md"
  feed_args=(--download-url-prefix "https://github.com/ahagary/desk-meow/releases/download/v$version/"
             --link 'https://github.com/ahagary/desk-meow/releases'
             --embed-release-notes --maximum-deltas 0 --maximum-versions 1)
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_dir/bin/generate_appcast" \
      --ed-key-file - "${feed_args[@]}" "$work_dir/feed"
  elif [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    "$sparkle_dir/bin/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
      "${feed_args[@]}" "$work_dir/feed"
  else
    "$sparkle_dir/bin/generate_appcast" --account "$keychain_account" \
      "${feed_args[@]}" "$work_dir/feed"
  fi
  cp "$work_dir/feed/appcast.xml" "$work_dir/appcast.xml"
  # Verify artifacts against the public key embedded in the client, independent
  # of whichever private-key source was used above. Also check tamper rejection.
  local_tools="$HOME/.cache/tabby-build-tools/CommandLineTools"
  if [[ -z "${DEVELOPER_DIR:-}" && -x "$local_tools/usr/bin/swift" ]]; then
    DEVELOPER_DIR="$local_tools" xcrun swift "$project_dir/Tools/check_update_signatures.swift" \
      "$work_dir/appcast.xml" "$work_dir/$artifact_name.zip" "$project_dir/Configuration/updates.json"
  else
    xcrun swift "$project_dir/Tools/check_update_signatures.swift" \
      "$work_dir/appcast.xml" "$work_dir/$artifact_name.zip" "$project_dir/Configuration/updates.json"
  fi
fi
(
  cd "$work_dir"
  shasum -a 256 "$artifact_name.dmg" "$artifact_name.zip" > "$artifact_name.sha256"
  [[ ! -f appcast.xml ]] || shasum -a 256 appcast.xml >> "$artifact_name.sha256"
)
mv "$work_dir/$artifact_name.dmg" "$work_dir/$artifact_name.zip" \
  "$work_dir/$artifact_name.sha256" "$dist_dir/"
mv "$work_dir/release-notes.md" "$dist_dir/"
if [[ -f "$work_dir/appcast.xml" ]]; then mv "$work_dir/appcast.xml" "$dist_dir/"; fi
print "$signing_status"
print "发布文件：$dist_dir/$artifact_name.dmg"
print "发布文件：$dist_dir/$artifact_name.zip"
print "校验文件：$dist_dir/$artifact_name.sha256"
