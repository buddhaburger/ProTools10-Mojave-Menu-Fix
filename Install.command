#!/bin/bash
# ============================================================
#  Pro Tools 10  —  Mojave Menu Fix
#  Easy Installer  (no Xcode, no building required)
# ============================================================
#  This installs the pre-built fix so Pro Tools 10's menus
#  work again on macOS 10.14 Mojave.
#
#  HOW TO RUN:
#    1. Double-click "Install.command"
#       (or in Terminal: ./Install.command)
#    2. Type your Mac password if asked (for copying the file).
#    3. Launch Pro Tools 10. Done.
# ============================================================

PT_APP="/Applications/Avid/Pro Tools/Pro Tools.app"
CFD_DIR="$PT_APP/Contents/Frameworks/CFD.framework/Versions/A"
HERE="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DYLIB="$HERE/prebuilt/CFD_release.dylib"
DEBUG_DYLIB="$HERE/prebuilt/CFD_debug.dylib"

# Re-arm executable bits in case the zip dropped them (so Uninstall and
# the build script also stay runnable after this installer launches once).
chmod +x "$HERE"/*.command "$HERE/source/build.sh" 2>/dev/null

echo ""
echo "  ============================================="
echo "    Pro Tools 10  —  Mojave Menu Fix"
echo "    Restores all blank / broken menus"
echo "  ============================================="
echo ""

# --- Check Pro Tools is installed ---
if [ ! -d "$PT_APP" ]; then
    echo "  [X] Pro Tools 10 was not found at:"
    echo "      $PT_APP"
    echo ""
    echo "      Make sure Pro Tools 10 is installed in the usual place,"
    echo "      then run this installer again."
    echo ""
    read -p "  Press Return to close." _
    exit 1
fi
echo "  [OK] Found Pro Tools 10"

# --- Check the fix files are present ---
if [ ! -f "$RELEASE_DYLIB" ]; then
    echo "  [X] Could not find the fix file:"
    echo "      $RELEASE_DYLIB"
    echo ""
    echo "      Please keep this installer inside the folder it came in"
    echo "      (it needs the 'prebuilt' folder next to it)."
    echo ""
    read -p "  Press Return to close." _
    exit 1
fi
echo "  [OK] Found the fix files"

# --- Friendly SIP check ---
if csrutil status 2>/dev/null | grep -q "disabled"; then
    echo "  [OK] System protection (SIP) is disabled"
else
    echo ""
    echo "  [!] IMPORTANT: System Integrity Protection (SIP) looks ENABLED."
    echo "      This fix cannot be installed until SIP is turned off."
    echo ""
    echo "      How to turn it off (one time):"
    echo "        1. Restart your Mac."
    echo "        2. Hold Command (⌘) + R during startup to enter Recovery."
    echo "        3. Menu bar → Utilities → Terminal."
    echo "        4. Type:   csrutil disable     then press Return."
    echo "        5. Restart normally and run this installer again."
    echo ""
    read -p "  Continue anyway? (y/n) " -n 1 -r; echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "  Installation cancelled. Nothing was changed."
        read -p "  Press Return to close." _
        exit 1
    fi
fi

# --- Choose version (default = Release) ---
echo ""
echo "  Which version would you like to install?"
echo ""
echo "    1) Recommended  — fast and quiet (most people pick this)"
echo "    2) Troubleshooting — same fix, but writes a detailed log"
echo "                         to /tmp/pt_fix.log (use only if asked)"
echo ""
read -p "  Enter 1 or 2 (or just press Return for Recommended): " CHOICE
echo ""

if [ "$CHOICE" = "2" ]; then
    if [ ! -f "$DEBUG_DYLIB" ]; then
        echo "  [X] Troubleshooting version not found in 'prebuilt'."
        read -p "  Press Return to close." _
        exit 1
    fi
    CHOSEN="$DEBUG_DYLIB"
    echo "  Installing the Troubleshooting version..."
else
    CHOSEN="$RELEASE_DYLIB"
    echo "  Installing the Recommended version..."
fi

# --- Back up the original (once) ---
if [ -f "$CFD_DIR/CFD_original" ]; then
    echo "  [OK] Your original file is already backed up (CFD_original)"
else
    echo "  Backing up your original Pro Tools file..."
    sudo cp "$CFD_DIR/CFD" "$CFD_DIR/CFD_original"
    if [ $? -ne 0 ]; then
        echo "  [X] Backup failed. This usually means SIP is still enabled."
        echo "      See the SIP instructions above."
        read -p "  Press Return to close." _
        exit 1
    fi
    echo "  [OK] Original safely backed up as CFD_original"
fi

# --- Install ---
sudo cp "$CHOSEN" "$CFD_DIR/CFD"
if [ $? -ne 0 ]; then
    echo "  [X] Could not copy the fix into place."
    echo "      Make sure SIP is disabled, then try again."
    read -p "  Press Return to close." _
    exit 1
fi

echo ""
echo "  ============================================="
echo "    SUCCESS!  The fix is installed."
echo "  ============================================="
echo ""
echo "    Just launch Pro Tools 10 normally."
echo "    Right-click menus, the plugin list, I/O routing,"
echo "    and the Bounce window all work now."
echo ""
echo "    To undo this later, run 'Uninstall.command'."
echo ""
read -p "  Press Return to close." _
