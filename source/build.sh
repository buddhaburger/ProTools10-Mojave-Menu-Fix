#!/bin/bash
# ============================================================
# Pro Tools 10 Mojave Menu Fix — Build From Source
# ============================================================
# Builds BOTH binaries:
#   CFD_release.dylib  — quiet, fast (ship this to users)
#   CFD_debug.dylib    — verbose /tmp/pt_fix.log (for troubleshooting)
#
# Requirements:
#   - macOS 10.14.6 Mojave
#   - Xcode with the macOS 10.13 SDK
#
# Usage:  chmod +x build.sh && ./build.sh
# Output: ../prebuilt/CFD_release.dylib and ../prebuilt/CFD_debug.dylib
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../prebuilt"
SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.13.sdk"

mkdir -p "$OUT_DIR"

if [ ! -d "$SDK" ]; then
    echo "ERROR: macOS 10.13 SDK not found at:"
    echo "  $SDK"
    echo ""
    echo "You need Xcode with the 10.13 SDK. Tip: download Xcode 10.1 and copy"
    echo "MacOSX10.13.sdk into the SDKs folder of your current Xcode."
    exit 1
fi

# Shared compiler flags
COMMON_FLAGS=(
  -dynamiclib
  -fexceptions -fobjc-arc-exceptions
  -framework Cocoa -framework AppKit -framework Foundation
  -framework QuartzCore -framework Carbon -framework CoreText
  -stdlib=libstdc++
  -arch i386 -mmacosx-version-min=10.13
  -isysroot "$SDK"
  -install_name "@executable_path/../Frameworks/CFD.framework/Versions/A/CFD"
  -compatibility_version 10.3.10 -current_version 10.3.10
  -Wall
)

echo "Building RELEASE (quiet, fast)..."
clang++ "${COMMON_FLAGS[@]}" \
  -DPT_BUILD_TAG='"RELEASE"' \
  -o "$OUT_DIR/CFD_release.dylib" \
  -x objective-c    "$SCRIPT_DIR/cfd_wrapper.m" \
  -x objective-c++  "$SCRIPT_DIR/pt_menu_bridge.mm" 2>&1
echo "  -> $OUT_DIR/CFD_release.dylib"

echo "Building DEBUG (verbose logging)..."
clang++ "${COMMON_FLAGS[@]}" \
  -DPT_BUILD_TAG='"DEBUG"' \
  -o "$OUT_DIR/CFD_debug.dylib" \
  -x objective-c    "$SCRIPT_DIR/cfd_wrapper.m" \
  -x objective-c++  "$SCRIPT_DIR/pt_menu_bridge_debug.mm" 2>&1
echo "  -> $OUT_DIR/CFD_debug.dylib"

echo ""
echo "Done. Both binaries are in: $OUT_DIR"
echo "Install one with the installer in the package root, or copy manually to:"
echo "  /Applications/Avid/Pro Tools/Pro Tools.app/Contents/Frameworks/CFD.framework/Versions/A/CFD"
