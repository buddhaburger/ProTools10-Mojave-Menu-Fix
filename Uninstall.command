#!/bin/bash
# ============================================================
#  Pro Tools 10  —  Mojave Menu Fix
#  Uninstaller  —  restores Pro Tools to its original state
# ============================================================
#  Double-click "Uninstall.command" to run.
# ============================================================

PT_APP="/Applications/Avid/Pro Tools/Pro Tools.app"
CFD_DIR="$PT_APP/Contents/Frameworks/CFD.framework/Versions/A"

echo ""
echo "  ============================================="
echo "    Pro Tools 10  —  Remove Mojave Menu Fix"
echo "  ============================================="
echo ""

if [ ! -d "$PT_APP" ]; then
    echo "  [X] Pro Tools 10 was not found. Nothing to undo."
    read -p "  Press Return to close." _
    exit 1
fi

if [ ! -f "$CFD_DIR/CFD_original" ]; then
    echo "  [X] No backup (CFD_original) was found."
    echo "      This usually means the fix was never installed,"
    echo "      or the backup was removed. Nothing was changed."
    read -p "  Press Return to close." _
    exit 1
fi

echo "  Restoring your original Pro Tools file..."
sudo cp "$CFD_DIR/CFD_original" "$CFD_DIR/CFD"
if [ $? -ne 0 ]; then
    echo "  [X] Restore failed. Make sure SIP is disabled and try again."
    read -p "  Press Return to close." _
    exit 1
fi

echo ""
echo "  [OK] Done. Pro Tools 10 is back to its original state."
echo "       (Menus will be blank again on Mojave — that's expected"
echo "        without the fix.)"
echo ""
read -p "  Press Return to close." _
