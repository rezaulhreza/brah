#!/usr/bin/env bash
# Build Brah.app into build/.
#
# macOS gives Screen Recording to a signed app, not to a bare binary. With an ad-hoc signature
# the grant is lost on every build, so set BRAH_SIGN_IDENTITY to a certificate you own, for
# example "Apple Development". BRAH_BUNDLE_ID changes the bundle identifier.
set -euo pipefail

cd "$(dirname "$0")/.."
config="${1:-release}"
identity="${BRAH_SIGN_IDENTITY:--}"
bundle_id="${BRAH_BUNDLE_ID:-local.brah.app}"

swift build -c "$config"
app="build/Brah.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$config/Brah" "$app/Contents/MacOS/Brah"
cp Resources/AppIcon.icns Resources/MenuIcon.png Resources/MenuIcon@2x.png "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Brah</string>
  <key>CFBundleDisplayName</key><string>Brah</string>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleExecutable</key><string>Brah</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>${bundle_id}</string>
    <key>CFBundleURLSchemes</key><array><string>brah</string></array>
  </dict></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Brah listens while you hold the hotkey, so you can ask by voice.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Brah writes down what you say when your agent has no voice of its own.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$identity" "$app"
echo "Built $app (signed with: $identity)"
