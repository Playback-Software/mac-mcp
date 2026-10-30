# Sourced by the build and test scripts: use full Xcode for swift, unless the caller already chose a toolchain.
# TestHost uses SwiftUI macros, which the Command Line Tools alone can't build.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Exits with a fix when full Xcode or Swift 6.1+ is missing. Call it after sourcing this file (name: the script).
require_toolchain() {
  local name=$1 out swift_version
  if ! out=$(xcodebuild -version 2>&1); then
    print -u2 "$name: full Xcode 26 or later is required (Swift 6.1+); the Command Line Tools alone can't build MacMCP."
    if [[ "$out" == *license* ]]; then
      print -u2 "  Accept Xcode's license once: sudo xcodebuild -license accept"
    else
      print -u2 "  Install Xcode from the App Store or developer.apple.com, open it once to finish setup, then either run"
      print -u2 "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
      print -u2 "  or set DEVELOPER_DIR to the Developer folder inside your Xcode.app."
    fi
    exit 1
  fi
  swift_version=$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1.\2/p' | head -n 1)
  autoload -Uz is-at-least
  if [[ -z "$swift_version" ]] || ! is-at-least 6.1 "$swift_version"; then
    print -u2 "$name: Swift 6.1 or later is required; found ${swift_version:-none} (${out%%$'\n'*})."
    print -u2 "  Update to Xcode 26 or later, or point DEVELOPER_DIR at it."
    exit 1
  fi
}
