#!/bin/bash
# ============================================================
#  Pro Tools 10 Mojave Menu Fix  —  Package For Release
# ============================================================
#  Run this ON YOUR MAC to produce the final, ready-to-upload zip.
#  It does everything in one shot:
#    1. Builds both binaries (Release + Debug) from source
#    2. Sets the executable bit on all .command files and scripts
#    3. Zips the package so those bits SURVIVE download + unzip
#       (this is what stops end users hitting the "could not be
#        executed / no access privileges" error)
#
#  Usage:
#    chmod +x package.sh
#    ./package.sh
#
#  Result:  PT10_Mojave_Menu_Fix.zip  (next to this script)
# ============================================================

set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG_NAME="PT10_Mojave_Menu_Fix"

echo ""
echo "  === Packaging $PKG_NAME for release ==="
echo ""

# --- 1. Build both binaries -------------------------------------------------
echo "  [1/3] Building binaries from source..."
if [ ! -f "$HERE/source/build.sh" ]; then
    echo "  [X] source/build.sh not found. Run this from the package root."
    exit 1
fi
chmod +x "$HERE/source/build.sh"
( cd "$HERE/source" && ./build.sh )

if [ ! -f "$HERE/prebuilt/CFD_release.dylib" ] || [ ! -f "$HERE/prebuilt/CFD_debug.dylib" ]; then
    echo "  [X] Build did not produce both binaries in prebuilt/."
    echo "      Check the build output above (usually a missing 10.13 SDK)."
    exit 1
fi
echo "      OK — CFD_release.dylib and CFD_debug.dylib are in prebuilt/"

# --- 2. Set executable bits -------------------------------------------------
echo "  [2/3] Setting executable permissions..."
chmod +x "$HERE/Install.command" "$HERE/Uninstall.command" "$HERE/source/build.sh"
echo "      OK"

# --- 3. Zip with permissions preserved --------------------------------------
echo "  [3/3] Creating the release zip..."
PARENT="$(dirname "$HERE")"
FOLDER="$(basename "$HERE")"
OUT="$PARENT/$PKG_NAME.zip"
rm -f "$OUT"
# Zip from the parent so the folder is included; -X drops Finder metadata;
# macOS 'zip' preserves the +x bits we just set.
( cd "$PARENT" && zip -r -X "$PKG_NAME.zip" "$FOLDER" \
    -x "*.DS_Store" -x "__MACOSX/*" >/dev/null )

echo ""
echo "  === Done ==="
echo "  Upload this file to GitHub Releases:"
echo "    $OUT"
echo ""
echo "  Sanity check: after a fresh download + unzip, Install.command"
echo "  should run via right-click > Open without any chmod step."
echo ""
