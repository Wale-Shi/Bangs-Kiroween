#!/bin/bash
# Builds "Bangs.app" (and a zip of it) into build/.
set -euo pipefail
cd "$(dirname "$0")/.."
# The contest snapshot is based on Bangs 0.12.1.
VERSION="${VERSION:-0.12.1}"
echo "Bangs ${VERSION}"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
APP="build/Bangs.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/Bangs" "$APP/Contents/MacOS/Bangs"
# SwiftPM records the deployment target as the SDK the app was built with, and macOS then draws its standard controls
# (the settings window's sidebar, buttons, switches, menus) as on macOS 14. Record the real SDK, so on macOS 26 and later
# they are Liquid Glass; the app still runs on 14.
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace -output "$APP/Contents/MacOS/Bangs" "$APP/Contents/MacOS/Bangs"
cp "$BIN/bangs-hook" "$APP/Contents/Helpers/bangs-hook"
cp "$BIN/bangs-charge" "$APP/Contents/Helpers/bangs-charge"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R apps/Bangs/Logos "$APP/Contents/Resources/Logos"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.wale-shi.bangs</string>
  <key>CFBundleName</key><string>Bangs</string>
  <key>CFBundleDisplayName</key><string>Bangs</string>
  <key>CFBundleExecutable</key><string>Bangs</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Bangs 列出今天的日程，并在开会前（默认 5 分钟）在刘海里提醒你。</string>
  <key>NSCalendarsUsageDescription</key><string>Bangs 列出今天的日程，并在开会前（默认 5 分钟）在刘海里提醒你。</string>
  <key>NSDesktopFolderUsageDescription</key><string>文件搜索为桌面上的文件建立文件名索引，只记名字，不读内容。</string>
  <key>NSDocumentsFolderUsageDescription</key><string>文件搜索为「文稿」里的文件建立文件名索引，只记名字，不读内容。</string>
  <key>NSDownloadsFolderUsageDescription</key><string>文件搜索为「下载」里的文件建立文件名索引，只记名字，不读内容。</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST
xattr -cr "$APP"
# Sign with a fixed identity when there is one, so macOS keeps Screen Recording and Accessibility across updates
# (an ad-hoc signature changes with every build, and macOS then sees a new app). SIGN_IDENTITY overrides; "-" is ad hoc.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"Bangs Local Signing"/ { print $2; exit }')"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "Signing with ${SIGN_IDENTITY}"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/bangs-hook"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/bangs-charge"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
(cd build && rm -f "Bangs-${VERSION}-arm64.zip" && ditto -c -k --norsrc --keepParent "Bangs.app" "Bangs-${VERSION}-arm64.zip")
echo "Built $APP"
