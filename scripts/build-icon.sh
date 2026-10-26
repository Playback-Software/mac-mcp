#!/bin/zsh
# Regenerate the macOS icon bundle from the selected Soft Depth artwork.
#   scripts/build-icon.sh [output.icns]
set -euo pipefail
cd "${0:A:h}/.."

SOURCE=assets/branding/macmcp-icon.png
OUTPUT="${1:-assets/branding/MacMCP.icns}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mac-mcp-icon.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/MacMCP.iconset"
mkdir -p "$ICONSET" "${OUTPUT:h}"

# Each size comes straight from the master PNG; alpha and the selected artwork are preserved.
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUTPUT"
print "built $OUTPUT"
