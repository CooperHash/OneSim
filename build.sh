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

if pgrep -x SimLab >/dev/null 2>&1; then
    echo "Quit SimLab before rebuilding its app bundle." >&2
    exit 1
fi

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product SimLab

BIN=".build/$CONFIG/SimLab"
cleanup_staging
trap cleanup_staging EXIT
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"

cp "$BIN" "$STAGING/Contents/MacOS/SimLab"
cp Resources/SimLab.icns "$STAGING/Contents/Resources/SimLab.icns"
mkdir -p "$STAGING/Contents/Resources/HingeControl"
cp Resources/HingeControl/hinge Resources/HingeControl/hinge_helper.m Resources/HingeControl/LICENSE \
    "$STAGING/Contents/Resources/HingeControl/"
mkdir -p "$STAGING/Contents/Resources/Licenses/SimKit"
cp Vendor/SimKit/LICENSE Vendor/SimKit/NOTICE "$STAGING/Contents/Resources/Licenses/SimKit/"
cp Vendor/SimKit/HIDBridge/LICENSE "$STAGING/Contents/Resources/Licenses/SimKit/DTUHID-MIT-LICENSE"
mkdir -p "$STAGING/Contents/Resources/SimSlim" "$STAGING/Contents/Resources/Licenses/SimSlim"
cp Vendor/SimSlim/bin/simslim Resources/SimSlim/SimLabBalanced.json "$STAGING/Contents/Resources/SimSlim/"
cp Vendor/SimSlim/LICENSE "$STAGING/Contents/Resources/Licenses/SimSlim/LICENSE"
tools/bundle-sdk.sh "$STAGING/Contents/Resources/AndroidSDK"

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
chmod -R a-w "$STAGING/Contents/Resources/AndroidSDK"
codesign --verify --deep --strict "$STAGING"
if [ -d "$APP/Contents/Resources/AndroidSDK" ]; then
    chmod -R u+w "$APP/Contents/Resources/AndroidSDK"
fi
rm -rf "$APP"
mv "$STAGING" "$APP"
echo "Built $APP"
