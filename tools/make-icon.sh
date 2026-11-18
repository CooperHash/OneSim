#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="$(mktemp -d)/SimLab.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

sips -s format png Resources/SimLabIcon.svg --out "$ICONSET/icon_512x512@2x.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    if [ "$size" -ne 512 ]; then
        doubled=$((size * 2))
        sips -z "$doubled" "$doubled" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    fi
done

iconutil -c icns "$ICONSET" -o Resources/SimLab.icns
cp "$ICONSET/icon_512x512.png" docs/simlab-icon.png
echo "Built Resources/SimLab.icns and docs/simlab-icon.png"
