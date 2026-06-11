# Pro Tools 10 — Mojave Menu Fix

**Restores the broken right-click menus, plugin list, I/O routing, and Bounce window in Pro Tools 10.3.10 on macOS 10.14 Mojave.**

On Mojave, Pro Tools 10's pop-up menus show up as blank rectangles, which makes the program nearly unusable. This fix rebuilds those menus using the modern macOS menu system so everything works again — including bouncing your mix to disk.

It is **free and open source**. There is **no Avid code** inside it.

---

## Just want it working? (no tech skills needed)

**You need:**
- macOS 10.14.6 Mojave — ideally fully updated. Tested on build **18G103**
  (the version the App Store installs) and **18G9323** (the final Mojave
  security update). If unsure, just run Software Update until there's nothing
  left; the fix works on both.
- Pro Tools 10.3.10 already installed
- System Integrity Protection (SIP) turned off — see below if you're not sure

**Steps:**
1. Download this package and unzip it (double-click the .zip).
2. Open the folder and **double-click `Install.command`**.
   - If macOS says it "can't be opened because it is from an unidentified developer," right-click it → **Open** → **Open**.
3. When it asks which version, just press **Return** for the Recommended one.
4. Type your Mac password if prompted (this is only to copy the file into place).
5. Launch Pro Tools 10. That's it — your menus are back.

**Changed your mind?** Double-click `Uninstall.command` to put everything back exactly as it was.

### What's "SIP" and how do I turn it off?

System Integrity Protection is a macOS security feature. This fix replaces a file *inside* the Pro Tools app, which SIP normally blocks. Turning it off is a one-time thing:

1. Restart your Mac.
2. Hold **Command (⌘) + R** during startup until you see the Recovery screen.
3. In the menu bar: **Utilities → Terminal**.
4. Type this and press Return:
   ```
   csrutil disable
   ```
5. Restart normally, then run `Install.command`.

(You can re-enable it later with `csrutil enable` from Recovery, but the fix will stop working until you disable it again.)

---

## Two versions — which do I pick?

The installer offers two. **Pick Recommended unless someone asks you not to.**

| Version | What it's for |
|---|---|
| **Recommended (Release)** | Fast and quiet. This is what everyone should use. |
| **Troubleshooting (Debug)** | Exactly the same fix, but it writes a detailed log to `/tmp/pt_fix.log`. Only useful if you're reporting a bug and the developer asks for that log. |

---

## What works

- Right-click (context) menus everywhere
- Plug-in browser — full category list, loads plug-ins
- Input / Output / Bus / Send routing on the Mix and Edit windows
- Clip List menus (clear, rename, sort, export)
- The **Bounce to Disk** window — including the Bounce Source list, so you can finally get your mix out
- Mix window column selector with checkmarks

## Known limitations

- Menus appear in **light mode** only (the older macOS 10.13 SDK used to build this doesn't support dark menus).
- A few plug-in category triangles may occasionally need a second click to appear. Everything is still reachable.
- **10.14.6 only.** This fix is built for macOS 10.14.6 specifically and uses
  addresses tied to that release. It is not expected to work on 10.14.5 or
  earlier, or on Catalina (10.15) and later. Tested on builds 18G103 and 18G9323.

---

## Is this safe? Will it mess up Pro Tools?

The installer **backs up your original file** before changing anything (it's saved right next to it as `CFD_original`). The uninstaller restores that backup. Nothing else in Pro Tools is touched, and your sessions are never modified.

As with anything that modifies an app, use it at your own risk — but it's designed to be fully reversible.

---

## For developers

Want to read the code, improve it, or build it yourself? Everything is in `source/`.

### Maintainer quick-start (cutting a new release)

Future-you, on a Mac with Xcode + the 10.13 SDK, from the package root:

```bash
# 1. Make the scripts runnable (only needed if git/zip dropped the bits)
chmod +x package.sh Install.command Uninstall.command source/build.sh

# 2. Build both binaries, set permissions, and produce the upload-ready zip
./package.sh

# 3. Test the OUTPUT zip as if you were a brand-new user:
#    - unzip it somewhere fresh
#    - right-click Install.command > Open > Open  (no chmod should be needed)
#    - confirm it installs and Pro Tools menus work
#    Then upload ../PT10_Mojave_Menu_Fix.zip to GitHub Releases.
```

That's the whole flow. `package.sh` is the single source of truth for producing a release — never hand-zip, or the executable bits get lost and users hit "could not be executed."

### Layout

```
PT10_Mojave_Menu_Fix/
├── Install.command          ← user installer (pre-built)
├── Uninstall.command        ← user uninstaller
├── package.sh               ← maintainers: build + set perms + zip, one command
├── prebuilt/
│   ├── CFD_release.dylib     ← quiet/fast build
│   └── CFD_debug.dylib       ← verbose-logging build
└── source/
    ├── cfd_wrapper.m            ← framework wrapper, hook installation, system patches
    ├── pt_menu_bridge.mm        ← RELEASE bridge (NSMenu builder, quiet)
    ├── pt_menu_bridge_debug.mm  ← DEBUG bridge (same logic + diagnostics)
    └── build.sh                 ← builds BOTH binaries
```

### Building

You need **Xcode with the macOS 10.13 SDK** (Pro Tools 10 is a 32-bit / i386 Carbon app, so it must be built against 10.13). Tip: download Xcode 10.1 and copy `MacOSX10.13.sdk` into your current Xcode's SDKs folder.

```bash
cd source
chmod +x build.sh
./build.sh
```

This produces `CFD_release.dylib` and `CFD_debug.dylib` in `prebuilt/`. The only difference between them is the bridge source used and a `-DPT_BUILD_TAG` define; the build tag is printed in the log banner so you can tell which binary produced a given `/tmp/pt_fix.log`.

### Making a release zip (maintainers)

To produce the exact zip that ships on GitHub — built binaries included, executable bits set so end users never see a "could not be executed" error — run the one-shot packager from the package root **on a Mac**:

```bash
chmod +x package.sh
./package.sh
```

It builds both binaries, sets the executable bit on the `.command` files and scripts, and zips with macOS's own `zip` (which preserves those bits). The result is `PT10_Mojave_Menu_Fix.zip` next to the folder, ready to upload.

### How it works (short version)

Pro Tools draws its pop-up menus with a legacy Carbon path that renders as blank rectangles on Mojave. The fix intercepts `CTBPopupMenu::DoIt` and rebuilds the menu as a native `NSMenu`, reading the menu contents through the original Pro Tools menu functions (resolved by symbol from `DFW.framework`). Submenus are captured by hooking `CTBPopupMenu::AddSubMenu`. The Bounce Source pop-up is a special case — it never builds its child submenus on our path — so for that one menu we delegate to the original Carbon `DoIt`, which builds the bus/output lists correctly.

Full details are in `PT10_Mojave_Fix_Technical_Report.md` (included in the repo).

---

## Credits & license

Made by the Pro Tools community, for the Pro Tools community. Free to use, modify, and share. No warranty. Pro Tools and Avid are trademarks of their respective owners; this project is not affiliated with or endorsed by Avid.
