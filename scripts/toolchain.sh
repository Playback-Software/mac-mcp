# Sourced by the build and test scripts: use full Xcode for swift, unless the caller already chose a toolchain.
# TestHost uses SwiftUI macros, which the Command Line Tools alone can't build.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
