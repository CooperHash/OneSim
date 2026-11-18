#!/bin/bash
set -euo pipefail

# Optional self-contained build from an already installed Android SDK.
SDK_SOURCE="${ANDROIDLAB_SDK_SOURCE:-$HOME/Library/Android/sdk}"
DESTINATION="$1"
IMAGE=system-images/android-36/google_apis/arm64-v8a

test -x "$SDK_SOURCE/platform-tools/adb"
test -x "$SDK_SOURCE/emulator/emulator"
test -f "$SDK_SOURCE/$IMAGE/system.img"
mkdir -p "$DESTINATION/platform-tools" "$DESTINATION/system-images/android-36/google_apis"
cp -cp "$SDK_SOURCE/platform-tools/adb" "$DESTINATION/platform-tools/"
if [ -f "$SDK_SOURCE/platform-tools/NOTICE.txt" ]; then
    cp -p "$SDK_SOURCE/platform-tools/NOTICE.txt" "$DESTINATION/platform-tools/"
fi
cp -cR "$(cd "$SDK_SOURCE/emulator" && pwd -P)" "$DESTINATION/emulator"
cp -cR "$(cd "$SDK_SOURCE/$IMAGE" && pwd -P)" "$DESTINATION/$IMAGE"
# Keep the official ARM emulator's runtime libraries, assets and license.
for folder in qemu/darwin-x86_64 qemu/darwin-x64; do
    if [ -d "$DESTINATION/emulator/$folder" ]; then
        find "$DESTINATION/emulator/$folder" -depth -delete
    fi
done
echo "Bundled minimal Android SDK ($(du -sh "$DESTINATION" | awk '{print $1}'))"
