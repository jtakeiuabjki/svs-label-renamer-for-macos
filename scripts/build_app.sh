#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SVS Label Renamer for macOS"
ARCHIVE_NAME="SVSLabelRenamer-for-macOS.zip"
APP="$ROOT/dist/$APP_NAME.app"
QUICKLOOK_NAME="SVSQuickLook"
QUICKLOOK="$APP/Contents/PlugIns/$QUICKLOOK_NAME.appex"
QUICKLOOK_BUILD="$ROOT/.build-quicklook"
IDENTITY="${CODESIGN_IDENTITY:--}"

"$ROOT/scripts/fetch_openslide.sh"

cd "$ROOT"
swift build --disable-sandbox -c release --arch arm64 --scratch-path "$ROOT/.build-arm64"
swift build --disable-sandbox -c release --arch x86_64 --scratch-path "$ROOT/.build-x86_64"
ARM_BINARY="$ROOT/.build-arm64/arm64-apple-macosx/release/SVSLabelRenamer"
INTEL_BINARY="$ROOT/.build-x86_64/x86_64-apple-macosx/release/SVSLabelRenamer"
if [[ ! -x "$ARM_BINARY" || ! -x "$INTEL_BINARY" ]]; then
    echo "Architecture-specific release binary not found" >&2
    exit 1
fi

rm -rf "$QUICKLOOK_BUILD"
mkdir -p "$QUICKLOOK_BUILD/arm64" "$QUICKLOOK_BUILD/x86_64"
QUICKLOOK_SOURCES=(
    "$ROOT/Sources/SVSQuickLookCore/OpenSlideRenderer.swift"
    "$ROOT/Sources/SVSQuickLookExtension/PreviewProvider.swift"
)
for ARCH in arm64 x86_64; do
    swiftc \
        -target "$ARCH-apple-macosx14.0" \
        -O -whole-module-optimization \
        -parse-as-library -application-extension \
        -module-name "$QUICKLOOK_NAME" \
        -module-cache-path "$QUICKLOOK_BUILD/$ARCH/module-cache" \
        -Xlinker -e -Xlinker _NSExtensionMain \
        "${QUICKLOOK_SOURCES[@]}" \
        -o "$QUICKLOOK_BUILD/$ARCH/$QUICKLOOK_NAME"
done

rm -rf "$ROOT/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" \
    "$APP/Contents/Frameworks" "$APP/Contents/Resources/OpenSlide/licenses" \
    "$QUICKLOOK/Contents/MacOS" "$QUICKLOOK/Contents/Frameworks"
lipo -create "$ARM_BINARY" "$INTEL_BINARY" \
    -output "$APP/Contents/MacOS/SVSLabelRenamer"
lipo -create \
    "$QUICKLOOK_BUILD/arm64/$QUICKLOOK_NAME" \
    "$QUICKLOOK_BUILD/x86_64/$QUICKLOOK_NAME" \
    -output "$QUICKLOOK/Contents/MacOS/$QUICKLOOK_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/SVSQuickLook-Info.plist" \
    "$QUICKLOOK/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/.vendor/openslide/bin/slidetool" "$APP/Contents/Helpers/"
cp "$ROOT/.vendor/openslide/lib/libopenslide.1.dylib" "$APP/Contents/Frameworks/"
cp "$ROOT/.vendor/openslide/lib/libopenslide.1.dylib" \
    "$QUICKLOOK/Contents/Frameworks/"
cp -R "$ROOT/.vendor/openslide/licenses/." "$APP/Contents/Resources/OpenSlide/licenses/"
cp "$ROOT/.vendor/openslide/README.md" "$APP/Contents/Resources/OpenSlide/"
cp "$ROOT/.vendor/openslide/VERSIONS.md" "$APP/Contents/Resources/OpenSlide/"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

install_name_tool \
    -rpath '@loader_path/../lib' \
    '@loader_path/../Frameworks' \
    "$APP/Contents/Helpers/slidetool"

if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP/Contents/Frameworks/libopenslide.1.dylib"
    codesign --force --sign - "$APP/Contents/Helpers/slidetool"
    codesign --force --sign - \
        "$QUICKLOOK/Contents/Frameworks/libopenslide.1.dylib"
    codesign --force --sign - \
        --entitlements "$ROOT/Resources/SVSQuickLook.entitlements" \
        "$QUICKLOOK"
    codesign --force --sign - "$APP"
else
    codesign --force --timestamp --options runtime --sign "$IDENTITY" \
        "$APP/Contents/Frameworks/libopenslide.1.dylib"
    codesign --force --timestamp --options runtime --sign "$IDENTITY" \
        "$APP/Contents/Helpers/slidetool"
    codesign --force --timestamp --options runtime --sign "$IDENTITY" \
        "$QUICKLOOK/Contents/Frameworks/libopenslide.1.dylib"
    codesign --force --timestamp --options runtime --sign "$IDENTITY" \
        --entitlements "$ROOT/Resources/SVSQuickLook.entitlements" \
        "$QUICKLOOK"
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" \
    "$ROOT/dist/$ARCHIVE_NAME"
echo "Built: $APP"
echo "Archive: $ROOT/dist/$ARCHIVE_NAME"
