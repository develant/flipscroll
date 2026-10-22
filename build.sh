#!/bin/zsh
# Builds FlipScroll.app into ./build.
#   ./build.sh            build (signed with Developer ID if present, else ad hoc)
#   ./build.sh --install  build and copy into /Applications
#   ./build.sh --release  build, sign with Developer ID, notarize, staple, zip to dist/FlipScroll.zip
set -euo pipefail
cd "$(dirname "$0")"

TEAM_ID=9HGNHGJ5DR
APP=build/FlipScroll.app
MODE="${1:-}"

IDENTITY=$(security find-identity -v -p codesigning | grep -o "\"Developer ID Application: .*($TEAM_ID)\"" | head -1 | tr -d '"' || true)
if [[ -z "$IDENTITY" ]]; then
    if [[ "$MODE" == "--release" ]]; then
        echo "No 'Developer ID Application' certificate for team $TEAM_ID in the keychain." >&2
        echo "Create one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application." >&2
        exit 1
    fi
    IDENTITY="-"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

swiftc -O -swift-version 5 -target arm64-apple-macos13 -o build/FlipScroll-arm64 Sources/main.swift
swiftc -O -swift-version 5 -target x86_64-apple-macos13 -o build/FlipScroll-x86_64 Sources/main.swift
lipo -create build/FlipScroll-arm64 build/FlipScroll-x86_64 -output "$APP/Contents/MacOS/FlipScroll"
rm build/FlipScroll-arm64 build/FlipScroll-x86_64

if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP (signed: $IDENTITY)"

if [[ "$MODE" == "--install" ]]; then
    pkill -x FlipScroll || true
    rm -rf /Applications/FlipScroll.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/FlipScroll.app"
fi

if [[ "$MODE" == "--release" ]]; then
    # Notarization uses the App Store Connect API key, read from .env.release (gitignored).
    [[ -f .env.release ]] || { echo "Missing .env.release (see .env.release.example)" >&2; exit 1; }
    source .env.release
    mkdir -p dist
    ZIP=dist/FlipScroll.zip
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP"
    echo "Release ready: $ZIP"
fi
