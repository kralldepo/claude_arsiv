#!/bin/zsh
# Builds "Sohbet Temizleyici.app" into ./build as one universal binary (Apple Silicon + Intel).
#   ./build.sh         app only
#   ./build.sh --dmg   app plus build/Sohbet-Temizleyici-<version>.dmg
# Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Sohbet Temizleyici"
EXEC_NAME="SohbetTemizleyici"
APP="build/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Resources/Info.plist)"

make_icon() {
  local tmp iconset
  tmp="$(mktemp -d)"
  iconset="$tmp/AppIcon.iconset"
  mkdir -p "$iconset"
  swift Tools/make-icon.swift "$tmp/icon.png" || return 1
  for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/icon.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null || return 1
    sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null || return 1
  done
  iconutil -c icns "$iconset" -o Resources/AppIcon.icns || return 1
  rm -rf "$tmp"
}

# Disk image with the app and an Applications shortcut to drag it onto.
make_dmg() {
  local dmg="build/Sohbet-Temizleyici-${VERSION}.dmg" tmp
  tmp="$(mktemp -d)"
  mkdir "$tmp/stage" "$tmp/mnt"
  ditto "$APP" "$tmp/stage/${APP_NAME}.app"
  ln -s /Applications "$tmp/stage/Applications"
  cp Resources/AppIcon.icns "$tmp/stage/.VolumeIcon.icns"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$tmp/stage" -fs HFS+ -format UDRW -ov "$tmp/rw.dmg"
  hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$tmp/mnt" "$tmp/rw.dmg"
  xcrun SetFile -a C "$tmp/mnt" 2>/dev/null || echo "Uyarı: disk simgesi ayarlanamadı."
  hdiutil detach -quiet "$tmp/mnt"
  rm -f "$dmg"
  hdiutil convert -quiet "$tmp/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg"
  rm -rf "$tmp"
  echo "DMG: $PWD/$dmg"
}

# One build per architecture. Newer SwiftPM versions share one output folder across
# triples, so each slice is copied out before the next build overwrites it.
slices="$(mktemp -d)"
for arch in arm64 x86_64; do
  triple="${arch}-apple-macosx${MIN_MACOS}"
  swift build -c release --triple "$triple"
  cp "$(swift build -c release --triple "$triple" --show-bin-path)/$EXEC_NAME" "$slices/$arch"
done

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "İkon oluşturuluyor…"
  make_icon || echo "Uyarı: ikon oluşturulamadı, varsayılan ikonla devam ediliyor."
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/$EXEC_NAME" "$slices"/*
rm -rf "$slices"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp -R Resources/*.lproj "$APP/Contents/Resources/"  # English and Turkish text
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "Uyarı: imzalanamadı (uygulama yine de çalışır)."
echo "Hazır: $PWD/$APP (sürüm $VERSION, $(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME"), macOS $MIN_MACOS+)"

if [[ "${1:-}" == "--dmg" ]]; then
  make_dmg
fi
