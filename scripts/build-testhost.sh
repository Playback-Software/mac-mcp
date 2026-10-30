#!/bin/zsh
# Bundle the TestHost fixture app as ~/Applications/MacMCPTestHost.app (URL scheme macmcp-testhost://).
set -euo pipefail
cd "${0:A:h}/.."
source "${0:A:h}/toolchain.sh"
APP="$HOME/Applications/MacMCPTestHost.app"
swift build --product TestHost
# A TestHost still running from the old bundle would serve the tests its old fixtures; the next test relaunches it.
pkill -f "$APP/Contents/MacOS/TestHost" || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/TestHost "$APP/Contents/MacOS/TestHost"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.playbacksoftware.macmcp.testhost</string>
  <key>CFBundleName</key><string>MacMCPTestHost</string>
  <key>CFBundleExecutable</key><string>TestHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Playback Software, LLC</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.playbacksoftware.macmcp.testhost</string>
    <key>CFBundleURLSchemes</key><array><string>macmcp-testhost</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign --force -s - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "built $APP"
