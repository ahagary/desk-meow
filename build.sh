#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/build/狸花猫桌面宠物.app"
version="${APP_VERSION:-$(<"$project_dir/VERSION")}"
build_number="${BUILD_NUMBER:-1}"
minimum_macos="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
python="${PYTHON:-python3}"

# Use the locally validated Apple toolchain when present. DEVELOPER_DIR still
# lets callers explicitly choose a different Xcode or Command Line Tools SDK.
local_tools="$HOME/.cache/tabby-build-tools/CommandLineTools"
if [[ -z "${DEVELOPER_DIR:-}" && -x "$local_tools/usr/bin/swiftc" ]]; then
  export DEVELOPER_DIR="$local_tools"
fi
if ! xcode-select -p >/dev/null 2>&1; then
  print -u2 '缺少 Xcode 命令行工具。请先运行 xcode-select --install，完成安装后重试。'
  exit 1
fi
compiler="$(xcrun --find swiftc)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$project_dir/build"
work_dir="$(mktemp -d "$project_dir/build/.app-build.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
staged_app="$work_dir/狸花猫桌面宠物.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"

"$compiler" -O -swift-version 5 -sdk "$sdk" \
  -target "arm64-apple-macosx${minimum_macos}" \
  -framework AppKit -framework SwiftUI \
  "$project_dir/Sources/main.swift" "$project_dir/Sources/PetAnimation.swift" \
  "$project_dir/Sources/FeedingEffects.swift" "$project_dir/Sources/FeedingChecks.swift" \
  "$project_dir/Sources/PetInteraction.swift" "$project_dir/Sources/InteractionChecks.swift" \
  -o "$staged_app/Contents/MacOS/TabbyDesktopPet"

"$python" - "$project_dir/Assets" "$staged_app" "$version" "$build_number" "$minimum_macos" <<'PY'
import json
import plistlib
import re
import shutil
import sys
from pathlib import Path

assets, app = map(Path, sys.argv[1:3])
version, build_number, minimum_macos = sys.argv[3:]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("APP_VERSION / VERSION 必须为三段数字，例如 0.1.0")
if not re.fullmatch(r"[1-9][0-9]*", build_number):
    raise SystemExit("BUILD_NUMBER 必须为正整数")
if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", minimum_macos):
    raise SystemExit("MACOSX_DEPLOYMENT_TARGET 格式无效")
resources = app / "Contents/Resources"
manifest_path = assets / "pet-animations.json"
manifest = json.loads(manifest_path.read_text())
files = {frame["file"] for clip in manifest["clips"].values() for frame in clip["frames"]}
for name in sorted(files):
    source = (assets / name).resolve()
    if Path(name).is_absolute() or ".." in Path(name).parts or not source.is_relative_to(assets.resolve()):
        raise SystemExit(f"素材路径超出 Assets: {name}")
    destination = resources / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
shutil.copyfile(manifest_path, resources / manifest_path.name)
info = {
    "CFBundleName": "狸花猫桌面宠物",
    "CFBundleDisplayName": "狸花猫桌面宠物",
    "CFBundleIdentifier": "local.tabby.desktop.pet",
    "CFBundleVersion": build_number,
    "CFBundleShortVersionString": version,
    "CFBundleExecutable": "TabbyDesktopPet",
    "CFBundlePackageType": "APPL",
    "CFBundleSupportedPlatforms": ["MacOSX"],
    "LSMinimumSystemVersion": minimum_macos,
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
}
with (app / "Contents/Info.plist").open("wb") as handle:
    plistlib.dump(info, handle)
PY

# Ad-hoc signing allows local Apple Silicon execution; it is not Developer ID signing.
xattr -cr "$staged_app"
codesign --force --sign - --timestamp=none "$staged_app"
codesign --verify --strict "$staged_app"
plutil -lint "$staged_app/Contents/Info.plist"
rm -rf "$app_dir"
mv "$staged_app" "$app_dir"
print "$app_dir"
