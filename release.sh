#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
version="$(<"$project_dir/VERSION")"
app_dir="$project_dir/build/狸花猫桌面宠物.app"
executable="$app_dir/Contents/MacOS/TabbyDesktopPet"
dist_dir="$project_dir/dist"
artifact_name="TabbyDesktopPet-${version}-macOS-arm64"
identity="${CODESIGN_IDENTITY:--}"
notary_profile="${NOTARYTOOL_PROFILE:-}"

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

mkdir -p "$dist_dir"
work_dir="$(mktemp -d "$project_dir/build/.release.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
signing_status='Ad-hoc 签名，未经过 Apple 公证；首次打开可能被 macOS 拦截。'
if [[ "$identity" != '-' ]]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$app_dir"
  codesign --verify --strict --verbose=2 "$app_dir"
  ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$work_dir/notarization.zip"
  xcrun notarytool submit "$work_dir/notarization.zip" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$app_dir"
  xcrun stapler validate "$app_dir"
  spctl --assess --type execute --verbose=2 "$app_dir"
  signing_status='Developer ID 签名，已通过 Apple 公证。'
fi

mkdir -p "$work_dir/dmg"
ditto "$app_dir" "$work_dir/dmg/狸花猫桌面宠物.app"
ln -s /Applications "$work_dir/dmg/Applications"
cat > "$work_dir/dmg/安装说明.txt" <<EOF
狸花猫桌面宠物 $version

适用于 Apple Silicon（M1/M2/M3/M4 等），最低 macOS $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_dir/Contents/Info.plist")。
把「狸花猫桌面宠物.app」拖入 Applications，再从“应用程序”打开。
点击猫咪打开待办和便签；从菜单栏退出。安装者不需要 Xcode 或 Python。

$signing_status
如果下载的是未公证版本，确认来源可信后，可在首次打开被阻止后前往
“系统设置 → 隐私与安全性 → 仍要打开”。不需要关闭系统安全机制。

个人数据保存在 ~/Library/Application Support/TabbyDesktopPet/data.json。
更新时先从菜单栏退出旧版本，再替换应用；替换应用不会删除个人数据。
EOF
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$work_dir/$artifact_name.zip"
hdiutil create -volname "TabbyDesktopPet $version" -srcfolder "$work_dir/dmg" \
  -format UDZO -ov "$work_dir/$artifact_name.dmg"
if [[ "$identity" != '-' ]]; then
  codesign --timestamp --sign "$identity" "$work_dir/$artifact_name.dmg"
  xcrun notarytool submit "$work_dir/$artifact_name.dmg" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$work_dir/$artifact_name.dmg"
  xcrun stapler validate "$work_dir/$artifact_name.dmg"
fi
hdiutil verify "$work_dir/$artifact_name.dmg"
(
  cd "$work_dir"
  shasum -a 256 "$artifact_name.dmg" "$artifact_name.zip" > "$artifact_name.sha256"
)
mv "$work_dir/$artifact_name.dmg" "$work_dir/$artifact_name.zip" \
  "$work_dir/$artifact_name.sha256" "$dist_dir/"
print "$signing_status"
print "发布文件：$dist_dir/$artifact_name.dmg"
print "发布文件：$dist_dir/$artifact_name.zip"
print "校验文件：$dist_dir/$artifact_name.sha256"
