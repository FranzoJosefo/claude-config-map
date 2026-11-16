#!/bin/bash
# Builds "Claude Config Map.app" into ./dist. Needs only Apple's Command Line Tools
# (run `xcode-select --install` once if `swiftc` is missing).
#
#   ./build.sh            build dist/Claude Config Map.app (universal: Apple Silicon + Intel)
#   ./build.sh --install  build, then copy it to /Applications
#   ./build.sh --zip      build, then make dist/Claude-Config-Map.zip for sharing
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Claude Config Map"
BUNDLE_ID="io.github.claude-config-map"
VERSION="$(cat VERSION 2>/dev/null || echo 1.0.0)"
DIST="dist"
APP="$DIST/$APP_NAME.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "› Compiling (arm64 + x86_64)…"
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -target "$arch-apple-macos12.0" Sources/main.swift -o "$TMP/ccm-$arch"
done

echo "› Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$TMP/ccm-arm64" "$TMP/ccm-x86_64" -output "$APP/Contents/MacOS/ClaudeConfigMap"
cp -R Resources/web "$APP/Contents/Resources/web"

echo "› Drawing icon…"
mkdir -p "$TMP/AppIcon.iconset"
swift tools/make-icon.swift "$TMP/icon-1024.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ClaudeConfigMap</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

echo "› Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # Quit a running copy so it can be replaced.
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/"
  echo "✓ Installed to /Applications/$APP_NAME.app"
fi
if [[ "${1:-}" == "--zip" ]]; then
  ditto -c -k --keepParent "$APP" "$DIST/Claude-Config-Map.zip"
  echo "✓ Zipped to $DIST/Claude-Config-Map.zip"
fi
