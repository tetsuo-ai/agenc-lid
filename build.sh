#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/agenc-lid.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/agenc-lid"
GENERATED_DIR="$BUILD_DIR/generated-assets"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$GENERATED_DIR"

rsvg-convert -w 256 -h 256 "$ROOT_DIR/Resources/BrandMark.svg" -o "$GENERATED_DIR/BrandMark.png"
rsvg-convert -w 44 -h 44 "$ROOT_DIR/Resources/MenuBarIconOff.svg" -o "$GENERATED_DIR/MenuBarIconOff.png"
rsvg-convert -w 44 -h 44 "$ROOT_DIR/Resources/MenuBarIconOn.svg" -o "$GENERATED_DIR/MenuBarIconOn.png"

ICONSET="$GENERATED_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
rsvg-convert -w 1024 -h 1024 "$ROOT_DIR/Resources/AppIcon.svg" -o "$GENERATED_DIR/AppIcon-1024.png"
sips -z 16 16 "$GENERATED_DIR/AppIcon-1024.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$GENERATED_DIR/AppIcon-1024.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$GENERATED_DIR/AppIcon-1024.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$GENERATED_DIR/AppIcon-1024.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$GENERATED_DIR/AppIcon-1024.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$GENERATED_DIR/AppIcon-1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$GENERATED_DIR/AppIcon-1024.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$GENERATED_DIR/AppIcon-1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$GENERATED_DIR/AppIcon-1024.png" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$GENERATED_DIR/AppIcon-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$GENERATED_DIR/AppIcon.icns"

swiftc \
  "$ROOT_DIR/Sources/agenc-lid/main.swift" \
  -o "$EXECUTABLE" \
  -framework AppKit \
  -framework Foundation \
  -framework QuartzCore

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$GENERATED_DIR/BrandMark.png" "$APP_DIR/Contents/Resources/BrandMark.png"
cp "$GENERATED_DIR/MenuBarIconOff.png" "$APP_DIR/Contents/Resources/MenuBarIconOff.png"
cp "$GENERATED_DIR/MenuBarIconOn.png" "$APP_DIR/Contents/Resources/MenuBarIconOn.png"
cp "$GENERATED_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
