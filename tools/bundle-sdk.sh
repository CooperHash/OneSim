#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <destination-sdk-root>" >&2
    exit 2
fi

SDK_SOURCE="${ANDROIDLAB_SDK_SOURCE:-$HOME/Library/Android/sdk}"
DESTINATION="$1"

source_directory() {
    local path="$1"
    if [ ! -d "$path" ]; then
        echo "Missing Android SDK directory: $path" >&2
        exit 1
    fi
    (cd "$path" && pwd -P)
}

copy_directory() {
    local source="$1"
    local destination="$2"
    mkdir -p "$(dirname "$destination")"
    # APFS clones keep the local app self-contained without immediately using
    # another 6 GB of physical disk space.
    cp -cR "$(source_directory "$source")" "$destination"
}

mkdir -p "$DESTINATION/cmdline-tools/latest/bin"
copy_directory "$SDK_SOURCE/emulator" "$DESTINATION/emulator"
copy_directory "$SDK_SOURCE/platform-tools" "$DESTINATION/platform-tools"
copy_directory "$SDK_SOURCE/system-images" "$DESTINATION/system-images"

CLI_SOURCE="$(source_directory "$SDK_SOURCE/cmdline-tools/latest")"
copy_directory "$CLI_SOURCE/lib" "$DESTINATION/cmdline-tools/latest/lib"
for file in "$CLI_SOURCE"/bin/*; do
    if [ -f "$file" ] && [ ! -L "$file" ]; then
        cp -cp "$file" "$DESTINATION/cmdline-tools/latest/bin/"
    fi
done
for file in NOTICE.txt source.properties package.xml; do
    if [ -f "$CLI_SOURCE/$file" ]; then
        cp -cp "$CLI_SOURCE/$file" "$DESTINATION/cmdline-tools/latest/"
    fi
done
if [ -d "$SDK_SOURCE/licenses" ]; then
    copy_directory "$SDK_SOURCE/licenses" "$DESTINATION/licenses"
fi

for tool in \
    emulator/emulator \
    platform-tools/adb \
    cmdline-tools/latest/bin/android \
    cmdline-tools/latest/bin/avdmanager \
    cmdline-tools/latest/bin/sdkmanager; do
    if [ ! -x "$DESTINATION/$tool" ]; then
        echo "Bundled SDK is missing executable: $tool" >&2
        exit 1
    fi
done
if find "$DESTINATION" -type l -print -quit | grep -q .; then
    echo "Bundled SDK contains a symlink; refusing a bundle that depends on external paths." >&2
    exit 1
fi

echo "Bundled Android SDK ($(du -sh "$DESTINATION" | awk '{print $1}'))"
