#!/usr/bin/env bash
# Build Bruh.app into build/.
#
# macOS gives Screen Recording to a signed app, not to a bare binary. With an ad-hoc signature
# the grant is lost on every build, so set BRUH_SIGN_IDENTITY to a certificate you own, for
# example "Apple Development". BRUH_BUNDLE_ID changes the bundle identifier.
set -euo pipefail

cd "$(dirname "$0")/.."
config="${1:-release}"
identity="${BRUH_SIGN_IDENTITY:--}"
bundle_id="${BRUH_BUNDLE_ID:-local.bruh.app}"

swift build -c "$config"
app="build/Bruh.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/$config/Bruh" "$app/Contents/MacOS/Bruh"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Bruh</string>
  <key>CFBundleDisplayName</key><string>Bruh</string>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleExecutable</key><string>Bruh</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "$identity" "$app"
echo "Built $app (signed with: $identity)"
