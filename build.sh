#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/SimLab.app"
STAGING="build/.SimLab.staging.app"

cleanup_staging() {
    if [ -d "$STAGING/Contents/Resources/AndroidSDK" ]; then
        chmod -R u+w "$STAGING/Contents/Resources/AndroidSDK"
    fi
    rm -rf "$STAGING"
}

for pid in $(pgrep -x SimLab || true); do
    if [ "$(ps -p "$pid" -o comm=)" = "$PWD/$APP/Contents/MacOS/SimLab" ]; then
        echo "Quit the copy of SimLab in build/ before rebuilding it." >&2
        exit 1
    fi
done

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product SimLab

BIN=".build/$CONFIG/SimLab"
cleanup_staging
trap cleanup_staging EXIT
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"

cp "$BIN" "$STAGING/Contents/MacOS/SimLab"
cp Resources/SimLab.icns "$STAGING/Contents/Resources/SimLab.icns"
cp -R Resources/Web "$STAGING/Contents/Resources/Web"
mkdir -p "$STAGING/Contents/Resources/HingeControl"
cp Resources/HingeControl/hinge Resources/HingeControl/hinge_helper.m Resources/HingeControl/LICENSE \
    "$STAGING/Contents/Resources/HingeControl/"
mkdir -p "$STAGING/Contents/Resources/Licenses/SimKit"
cp Vendor/SimKit/LICENSE Vendor/SimKit/NOTICE "$STAGING/Contents/Resources/Licenses/SimKit/"
cp Vendor/SimKit/HIDBridge/LICENSE "$STAGING/Contents/Resources/Licenses/SimKit/DTUHID-MIT-LICENSE"
mkdir -p "$STAGING/Contents/Resources/SimSlim" "$STAGING/Contents/Resources/Licenses/SimSlim"
cp Vendor/SimSlim/bin/simslim Resources/SimSlim/SimLabBalanced.json "$STAGING/Contents/Resources/SimSlim/"
cp Vendor/SimSlim/LICENSE "$STAGING/Contents/Resources/Licenses/SimSlim/LICENSE"
xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -O2 -fobjc-arc \
    Resources/HingeControl/hinge_helper.m -o "$STAGING/Contents/Resources/HingeControl/hinge_helper" \
    -framework IOKit -framework CoreFoundation -framework Foundation -framework CoreMotion
codesign --force --sign - "$STAGING/Contents/Resources/HingeControl/hinge_helper"

# Only embed Apple model art in a local build on request. The default app
# reads the same resources directly from the installed Xcode and DeviceKit.
if [ "${SIMLAB_EMBED_LOCAL_CHROME:-0}" = "1" ]; then
    chrome="$STAGING/Contents/Resources/DeviceChrome"
    mkdir -p "$chrome"
    xcode_contents="$(xcode-select -p)/.."
    cp "$xcode_contents/SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/V68.usdz" "$chrome/"
    for id in 12 14 15; do
        cp "/Library/Developer/DeviceKit/Chrome/phone${id}.devicechrome/Contents/Resources/PhoneComposite.pdf" "$chrome/phone${id}.pdf"
    done
    web_assets="$STAGING/Contents/Resources/Web/assets"
    mkdir -p "$web_assets"
    swift tools/render-web-chrome.swift "$chrome" "$web_assets/chrome"
    model_cache="build/web-assets/v68.glb"
    if [ -n "${SIMLAB_BLENDER_PYTHON:-}" ] &&
        { [ ! -f "$model_cache" ] || [ tools/prepare-duo-model.py -nt "$model_cache" ] ||
          ! cmp -s "$chrome/V68.usdz" build/web-assets/source.usdz; }; then
        mkdir -p build/web-assets
        "$SIMLAB_BLENDER_PYTHON" tools/prepare-duo-model.py "$chrome/V68.usdz" build/web-assets/v68.raw.glb
        "${SIMLAB_GLTFPACK:-gltfpack}" -i build/web-assets/v68.raw.glb -o "$model_cache.tmp.glb" -cc -kn -km
        mv "$model_cache.tmp.glb" "$model_cache"
        cp "$chrome/V68.usdz" build/web-assets/source.usdz
        rm build/web-assets/v68.raw.glb
    fi
    if [ -f "$model_cache" ]; then
        cp "$model_cache" "$web_assets/v68.glb"
    fi
fi
if [ "${SIMLAB_BUNDLE_ANDROID_SDK:-0}" = "1" ]; then
    tools/bundle-sdk.sh "$STAGING/Contents/Resources/AndroidSDK"
fi

# Include the tunnel helper and its license in portable builds when installed.
for prefix in /opt/homebrew/opt/cloudflared /usr/local/opt/cloudflared; do
    if [ -x "$prefix/bin/cloudflared" ] && [ -f "$prefix/LICENSE" ]; then
        mkdir -p "$STAGING/Contents/Helpers" "$STAGING/Contents/Resources/Licenses/cloudflared"
        cp "$prefix/bin/cloudflared" "$STAGING/Contents/Helpers/cloudflared"
        cp "$prefix/LICENSE" "$STAGING/Contents/Resources/Licenses/cloudflared/"
        break
    fi
done

cat > "$STAGING/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SimLab</string>
    <key>CFBundleIdentifier</key>
    <string>com.simlab.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SimLab</string>
    <key>CFBundleDisplayName</key>
    <string>SimLab</string>
    <key>CFBundleIconFile</key>
    <string>SimLab.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$STAGING"
if [ -d "$STAGING/Contents/Resources/AndroidSDK" ]; then
    chmod -R a-w "$STAGING/Contents/Resources/AndroidSDK"
fi
codesign --verify --deep --strict "$STAGING"
if [ -d "$APP/Contents/Resources/AndroidSDK" ]; then
    chmod -R u+w "$APP/Contents/Resources/AndroidSDK"
fi
rm -rf "$APP"
mv "$STAGING" "$APP"
echo "Built $APP"
