#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
app_parent=${QUILL_APP_PARENT:-"$HOME/Applications"}
app_path="$app_parent/Quill.app"
backup_dir=${QUILL_BACKUP_DIR:-"$app_parent/.quill-backups"}
scratch_path=${QUILL_BUILD_PATH:-/tmp/quill-app-build}
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/quill-app.XXXXXX")
stage_app="$stage_root/Quill.app"

cleanup() {
  rm -rf "$stage_root"
}
trap cleanup EXIT

cd "$repo_root"
swift build -c release --scratch-path "$scratch_path"

mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$scratch_path/release/quill" "$stage_app/Contents/MacOS/quill"
cp "$repo_root/Sources/quill/Info.plist" "$stage_app/Contents/Info.plist"

icon_png="$stage_root/AppIcon-1024.png"
iconset="$stage_root/AppIcon.iconset"
swift "$repo_root/scripts/make-app-icon.swift" "$icon_png"
mkdir -p "$iconset"
for entry in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  pixels=${entry%% *}
  filename=${entry#* }
  /usr/bin/sips -z "$pixels" "$pixels" "$icon_png" --out "$iconset/$filename" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$stage_app/Contents/Resources/AppIcon.icns"

/usr/bin/codesign --force --deep --sign - "$stage_app"
/usr/bin/codesign --verify --deep --strict "$stage_app"

mkdir -p "$app_parent"
if [[ -e "$app_path" ]]; then
  mkdir -p "$backup_dir"
  backup_path="$backup_dir/Quill-$(date +%Y%m%d-%H%M%S).zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$backup_path"
  /usr/bin/unzip -tq "$backup_path"
  mv "$app_path" "$stage_root/PreviousQuill.app"
  echo "Previous app archived at $backup_path"
fi
mv "$stage_app" "$app_path"

"$app_path/Contents/MacOS/quill" install --launch-at-login
/usr/bin/mdimport "$app_path" >/dev/null 2>&1 || true

echo "✓ Quill installed at $app_path"
echo "  Search Spotlight for: Quill"
