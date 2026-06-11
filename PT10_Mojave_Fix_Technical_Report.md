# Pro Tools 10 on macOS Mojave — Technical Report

## Restoring Context Menus in a 32-bit Carbon Application on macOS 10.14

**Version**: 1.0
**Target**: Pro Tools 10.3.10 (32-bit, i386, Carbon/QuickDraw)
**Platform**: macOS 10.14.6 Mojave (final 32-bit-capable macOS); tested on builds 18G103 and 18G9323
**Result**: Full restoration of all popup/context menus, the plugin browser, I/O routing, and the Bounce to Disk dialog — validated across multiple machine configurations.


## 1. Background

Pro Tools 10.3.10 is a 32-bit Carbon application released in 2012. It relies on
legacy Mac OS frameworks including QuickDraw, the Carbon Event Manager, and
HIToolbox's "Satin" menu rendering system. When Apple released macOS 10.14
Mojave in 2018, these legacy subsystems were deprecated or broken, causing Pro
Tools 10's context menus to render as blank rectangles. Clicks produced no
response. The application was otherwise functional — audio playback, recording,
editing, and mixing all worked — but without context menus, users could not load
plugins, assign I/O routing, access dozens of essential editing functions, or
bounce a finished mix to disk.

This report documents the reverse engineering and runtime patching required to
restore full menu functionality by replacing the broken Carbon menu rendering
with native Cocoa NSMenu popups — and the one special case (the Bounce Source
selector) where delegating back to the original Carbon code proved to be the
correct, most robust solution.


## 2. Architecture Overview

Pro Tools 10 uses a custom UI framework called **DFW** (Digidesign Framework)
that implements its own widget hierarchy on top of Carbon. The relevant class
hierarchy for menus is:

    CTBPopupMenu        — Popup menu controller (shows menu, returns selection)
      ├── TMenu          — Menu data model (tree of items)
      │     └── TMenuItem — Individual menu item (label, shortcut, state)
      └── BuildMenu()    — Virtual method that populates items before display

    TApplication         — Application singleton
      └── MenuEvent()    — Dispatches a selected TMenuItem to the correct handler

All popup/context menus flow through `CTBPopupMenu::DoIt()`, which calls
`BuildMenu()` to populate items, renders them using Carbon's Satin menu system,
runs a modal event loop, and returns the user's selection.

### 2.1 Framework Layout

Pro Tools loads several private frameworks at fixed addresses (32-bit, no ASLR
for system frameworks):

| Framework | Role |
|-----------|------|
| DFW.framework | UI framework — menus, views, events |
| Pro Tools.framework | Application logic |
| CFD.framework | Compositing/display (our injection point) |
| HIToolbox (system) | Carbon event handling, menu rendering |
| CoreText (system) | Font services |


## 3. The Patches

The fix consists of two source files compiled into a replacement
CFD.framework binary:

- **cfd_wrapper.m** (199 lines) — Framework entry point, low-level system
  patches, hook installation
- **pt_menu_bridge.mm** (564 lines) — NSMenu replacement, submenu detection,
  Bounce Source delegation

Two binaries are produced from the same wrapper plus one of two bridge
sources (see §9):

- **RELEASE** — quiet, fast; this is what end users install
- **DEBUG** — identical logic plus verbose `/tmp/pt_fix.log` diagnostics

### 3.1 CFD Framework Replacement (cfd_wrapper.m)

The original CFD.framework is renamed to `CFD_original`. Our replacement dylib
is installed in its place with matching version numbers and install name. A
`__attribute__((constructor))` function runs at load time before Pro Tools
reaches `main()`. A compile-time `PT_BUILD_TAG` define ("RELEASE" or "DEBUG")
is printed in the log banner so any captured log identifies the exact binary
that produced it.

#### 3.1.1 CFD Passthrough

The replacement loads `CFD_original` via `dlopen` and forwards its two public
symbols (`Cfd_Interface::GetViewServer()` and `Cfd_Interface::Init()`) to the
original implementation. This ensures Pro Tools' compositing pipeline continues
to function.

    cfd_handle = dlopen(".../CFD_original", RTLD_NOW|RTLD_GLOBAL);
    real_GVS  = dlsym(cfd_handle, "_ZN13Cfd_Interface13GetViewServerEv");
    real_Init = dlsym(cfd_handle, "_ZN13Cfd_Interface4InitEv");

#### 3.1.2 HIToolbox Legacy Text Stub (stub_hltb)

**Problem**: HIToolbox contains a legacy text rendering function at offset
`0x5131f` from its base (`0x92de0000`) that crashes when called on Mojave
because it attempts to use removed QuickDraw text APIs.

**Fix**: The function is overwritten with `mov eax, 1; ret` (return true,
indicating success, without executing any QuickDraw calls).

    Address:  HITOOLBOX_BASE + 0x5131f = 0x9303131f
    Patch:    B8 01 00 00 00 C3  (mov eax,1; ret)

This is applied via `vm_protect` to make the code page writable, patching 6
bytes, then restoring read-execute permissions.

#### 3.1.3 GWorld State Fix (fix_gworld)

**Problem**: Pro Tools checks a global QuickDraw GWorld state variable to
determine if the graphics system is initialized. On Mojave, this variable is
never set, causing Pro Tools to skip rendering operations.

**Fix**: The variable at address `0x931894a4` (HIToolbox data segment) is
forced to value `2` (initialized state).

    Address:  HITOOLBOX_BASE + 0x3a94a4 = 0x931894a4
    Patch:    *sState = 2

This requires `vm_protect` with `VM_PROT_COPY` (maximum protection override)
because the page is in a read-only shared mapping.

#### 3.1.4 QuickDraw Font Replacement (patch_CTFontCreateWithQuickdrawInstance)

**Problem**: Pro Tools calls `CTFontCreateWithQuickdrawInstance()` to create
fonts using QuickDraw font names and sizes. This function is deprecated and
returns NULL or crashes on Mojave.

**Fix**: The lazy symbol pointer for this function in HIToolbox's GOT is
overwritten to point to a replacement function that creates a standard
system menu font via `CTFontCreateUIFontForLanguage()`.

    Lazy symbol pointer: 0x93164898
    Replacement: Returns CTFontCreateUIFontForLanguage(kCTFontUIFontMenuItem, pointSize, NULL)

Point size is sanitized (clamped to 0–256, default 13.0) to handle garbage
values from the QuickDraw-era caller.

#### 3.1.5 NSScreen Update Stubs

**Problem**: Pro Tools calls `NSDisableScreenUpdates()` and
`NSEnableScreenUpdates()`, which are removed in Mojave.

**Fix**: `NSDisableScreenUpdates` is stubbed as a no-op.
`NSEnableScreenUpdates` calls `[CATransaction flush]` to ensure any pending
Core Animation work is committed.

#### 3.1.6 Scroll Redraw Fix (poll_swizzle)

**Problem**: Pro Tools' custom NSView subclasses (`DFW_NSView`,
`DFW_NSContainer`) don't properly invalidate their display on Mojave, causing
stale rendering during scrolling.

**Fix**: A background thread polls for the existence of the `DFW_NSView` class
(which is loaded lazily). Once found, it swizzles `setNeedsDisplay:` to always
pass `YES` and `setNeedsDisplayInRect:` to always pass `[self bounds]`,
ensuring full-view redraw on every invalidation.

#### 3.1.7 CTBPopupMenu::DoIt Hook

The DoIt hook is the primary patch. It redirects all popup menu display from
Carbon to our NSMenu replacement. The hook is installed via a 5-byte `JMP rel32`
instruction overwriting the first 5 bytes of `DoIt` (prologue: `55 89 E5 57 56`
= `push ebp; mov ebp,esp; push edi; push esi`). A trampoline page preserves
the original 5 bytes followed by a `JMP` back to `DoIt+5`. Preserving a working
trampoline turned out to be essential: the Bounce Source fix (§3.3) calls the
original `DoIt` through it.


### 3.2 NSMenu Bridge (pt_menu_bridge.mm)

This file implements the menu replacement system.

#### 3.2.1 DFW Symbol Resolution

At initialization, the following symbols are resolved from DFW.framework via
`dlsym`:

| Symbol | Purpose |
|--------|---------|
| `CTBPopupMenu::GetNumItems(TMenu*)` | Count items in a menu |
| `CTBPopupMenu::GetTheItemString(TMenu*, short, string&)` | Get item label |
| `CTBPopupMenu::ItemIsChecked(TMenu*, short)` | Get checkmark state |
| `CTBPopupMenu::GetBaseMenu()` | Get root TMenu* from popup |
| `CTBPopupMenu::DoIt(_CPoint&, long)` | The hook target |
| `CTBPopupMenu::AddSubMenu(TMenu*, short, TMenu*, string&)` | Submenu registration |
| `TMenu::GetNumberOfItems()` | Item count on a TMenu directly |
| `TMenuItem::GetIndex()` | Get item's index |
| `TMenu vtable` | Computed at DFW base + 0x2cdbe0 + 8 |

The DFW base address is computed by subtracting the known file offset of
`GetNumItems` (0x79e00) from its runtime address.

#### 3.2.2 AddSubMenu Hook — Capturing Hierarchical Menus

**Problem**: Pro Tools builds hierarchical menus (plugin browser, I/O routing)
by calling `CTBPopupMenu::AddSubMenu(parent, index, child, label)` during
`BuildMenu()`. The submenu associations are stored internally in a format that
varies by menu type and is not exposed via any public API.

**Solution**: `AddSubMenu` is hooked with a JMP trampoline. Every call records
a `(parent TMenu*, index, child TMenu*, label)` entry in a static lookup table.
Entries accumulate across menu builds (the table is not cleared each time)
because some menus are cached and do not re-issue `AddSubMenu` on every open;
lookups search newest-first so the most recent registration wins.

**Prologue handling**: Unlike `DoIt` which has a 5-byte prologue (`55 89 E5 57
56`), `AddSubMenu` has a 6-byte prologue (`55 89 E5 83 EC 48` = `push ebp;
mov ebp,esp; sub esp,0x48`). The `sub esp` instruction spans bytes 4-6; a
naive 5-byte copy splits this instruction, causing the trampoline to execute
corrupt code. The hook installer detects the `0x83` opcode at byte 3 and
copies 6 bytes instead of 5.

    Prologue patterns handled:
      55 89 E5 5X 5X          → 5 bytes  (push; mov; push; push)
      55 89 E5 83 EC XX       → 6 bytes  (push; mov; sub esp, imm8)
      55 89 E5 81 EC XX XX XX XX → 9 bytes  (push; mov; sub esp, imm32)

#### 3.2.3 DoIt Hook — The Menu Replacement

When `CTBPopupMenu::DoIt()` is called, the hook:

1. **Checks for the Bounce Source special case** (§3.3). If matched, it
   delegates to the original Carbon `DoIt` and returns.
2. **Calls BuildMenu** via the vtable (`vtable[2]`), which populates the
   TMenu tree and triggers AddSubMenu hooks for hierarchical items.
3. **Reads the base TMenu** via `GetBaseMenu()`.
4. **Builds an NSMenu recursively** from the TMenu tree.
5. **Shows the NSMenu** via `popUpMenuPositioningItem:atLocation:inView:`.
6. **Returns the selected TMenuItem*** cast to `long`.

#### 3.2.4 NSMenu Construction (buildNSMenuFromTMenu)

For each item in a TMenu:

1. **Validate the TMenu pointer.** Before any field access, the menu pointer
   is range-checked (`0x10000–0xF0000000`) and the `GetNumItems` call is
   wrapped in `try/catch`. Some menus — notably the toolbar options dropdowns
   (Show Transport, Synchronization, etc.) — can hand back a null or invalid
   child menu; without this guard, `GetNumItems` dereferences it and crashes
   at a tiny address. A bad menu now logs and returns empty instead of
   crashing. This single chokepoint protects every menu and submenu, since
   all recursion flows through this one function.

2. **Get label** via `GetTheItemString(tmenu, index)`. Index 0 is included
   (Pro Tools stores "no insert"/"no input"/"no output" at index 0, outside
   the range reported by `GetNumItems`). If index 0 throws, it is silently
   skipped.

3. **Detect separators**: Items with label `"-"` become `[NSMenuItem separatorItem]`.

4. **Resolve TMenuItem***: Called via `TMenu`'s vtable slot `0x64/4`, stored
   as the NSMenuItem's `representedObject`.

5. **Submenu detection**:
   - **Primary**: Look up `(tmenu, index)` in the AddSubMenu hook table.
     If found, recursively build the child TMenu into an NSMenu submenu.
   - **Functional fallback (routing parents only)**: For items labelled
     `bus`/`output`/`physical output`/`no output`/`track`, scan the
     TMenuItem's fields for a child menu and validate each candidate
     *functionally* — drive it with `GetNumItems`/`GetTheItemString` and
     score its contents for routing-like strings ("(Stereo)", "(Mono)",
     "->"). A candidate that throws, returns junk, or scores as non-routing
     is rejected. This replaced an earlier raw vtable-only memory scan that
     produced false positives (e.g. attaching submenus to "QuickTime",
     "96 kHz", "Interleaved") and crashed. The gate to these specific labels
     guarantees leaf items can never gain spurious submenus.

6. **Cycle protection**: A `std::set<void*>` of visited TMenu pointers prevents
   infinite recursion. Maximum recursion depth is 5.

7. **Checkmarks**: `ItemIsChecked(tmenu, index)` sets `NSControlStateValueOn`.

#### 3.2.5 Return Value — TMenuItem* Not an Index

**Critical discovery**: `CTBPopupMenu::DoIt()` returns a `TMenuItem*` pointer
cast to `long`, NOT a 1-based integer index. The calling code dereferences
this return value as a pointer to dispatch the selected action.

Evidence: Returning the integer index `8` caused a crash at
`KERN_INVALID_ADDRESS 0x00000008` — the caller dereferenced `0x8` as a
pointer. The correct return is:

    return (long)(uintptr_t)selectedItem;  // TMenuItem* or NULL

#### 3.2.6 Coordinate System Conversion

Pro Tools passes click coordinates in **QuickDraw screen coordinates** (origin
top-left, Y down). NSMenu expects **Cocoa screen coordinates** (origin
bottom-left, Y up):

    NSPoint nsLoc = NSMakePoint((CGFloat)point->h, screenHeight - (CGFloat)point->v);

#### 3.2.7 Exception-Based Iteration Termination

Pro Tools' `GetTheItemString` throws `Cmn_AssertException` when called with an
index beyond the valid range — the framework uses C++ exceptions as flow
control. The builder wraps each call in `try/catch` and stops iteration on the
first exception (for indices > 0). Index 0 exceptions are caught and skipped.


### 3.3 The Bounce Source Special Case

The Bounce to Disk dialog's **Bounce Source** selector was the single hardest
problem in the project and is solved differently from every other menu.

**Problem**: Unlike the Mix/Edit window I/O selectors, the Bounce Source popup
never builds its child submenus on our NSMenu path. Instrumenting the
AddSubMenu hook showed that `AddSubMenu` is **never called** for this popup's
`bus`/`output`/`physical output` items — their child routing lists are built
lazily by the original Carbon `DoIt`'s hover loop, which our hook bypasses.
Every attempt to locate or synthesise the children failed or was unstable:

- Memory scans found no child `TMenu*` in the item fields at snapshot time.
- `TMenuItem::Force_ReCreate()` rebuilt the item's appearance but did not
  populate or register a child submenu.
- Reusing the *identical* child menus registered by the Mix/Edit I/O selector
  crashed: a child `TMenu*` from one `CTBPopupMenu` instance cannot be safely
  driven by a different instance's `self`.

**Solution**: Detect the Bounce Source popup and delegate it — and only it —
to the original Carbon `DoIt` via the preserved trampoline. The original code
builds and shows the bus/output children correctly. On the modern macOS menu
path these render in the native light appearance, which is fully functional.

**Detection by shape, not exact contents**: The Bounce Source layout varies by
machine, session, and hardware. One rig showed three items
(`bus`/`output`/`physical output`); another showed only two
(`output`/`physical output`, no `bus`). An exact-list match is therefore too
brittle. The shipped check matches by *shape*: a small menu (2–3 items) in
which **every** item is one of `bus`/`output`/`physical output`. This is
specific enough that no other menu collides with it — the I/O selectors carry
5–7 items including non-routing labels like "no output" and "track" — yet
flexible across configurations. The selector also reflects live I/O state: a
track reassigned to a bus in the I/O setup appears in the Bounce Source list on
the next open, because the delegated Carbon code reads current state.


## 4. Memory Safety

All reads of unknown pointers use `mach_vm_read_overwrite()` rather than direct
dereference, returning `KERN_INVALID_ADDRESS` for unmapped memory instead of
raising SIGSEGV. `safe_read_u32()` also validates address range
(`0x10000–0xF0000000`) and alignment before reading. Every call into Pro Tools'
menu functions on an untrusted pointer is wrapped in `try/catch`, and the menu
builder validates each `TMenu*` at the single recursive chokepoint (§3.2.4).


## 5. Diagnostics

The DEBUG build logs all operations to `/tmp/pt_fix.log` with timestamps:
framework init and symbol resolution, every menu build (item count, labels,
submenu detection, Bounce Source delegation), AddSubMenu captures, user
selections, and any guarded errors. The log banner records the build tag
(`[RELEASE]`/`[DEBUG]`) so a captured log identifies the exact binary. The
RELEASE build keeps only minimal logging for speed.


## 6. Limitations

- **macOS 10.14.6 only**: Hardcoded addresses (HIToolbox base, GWorld location,
  CTFont lazy pointer) are specific to the Mojave 10.14.6 shared cache. In
  practice these offsets proved **stable across the full 10.14.6 build range**:
  the binary built on 18G103 (the App Store baseline) runs unmodified on
  18G9323 (the final July 2021 security update), so the supplemental and
  security updates within 10.14.6 do not move the targeted HIToolbox code.
  Other macOS versions (10.14.5 and earlier, or 10.15+) are out of scope and
  would require recalculated addresses.
- **Pro Tools 10.3.10 only**: DFW symbol offsets are version-specific.
- **32-bit only**: The patch operates entirely in the i386 address space.
- **SIP must be disabled**: Runtime code patching via `vm_protect` with
  `VM_PROT_EXECUTE` requires System Integrity Protection to be off.
- **Menu styling**: Menus use the native macOS light appearance rather than Pro
  Tools' original "Satin" dark theme. Dark menus are not available because the
  10.13 SDK used to build the i386 binary predates `NSAppearanceNameDarkAqua`.
- **No in-use destination indicator**: Pro Tools natively colours an I/O
  destination's text yellow when it is already assigned elsewhere. This cue is
  not reproduced; routing and bouncing are unaffected. (Candidate for v1.1.)


## 7. Summary of All Patches

| # | Patch | Location | Method | Purpose |
|---|-------|----------|--------|---------|
| 1 | HLTB stub | HIToolbox+0x5131f | Code overwrite | Prevent QuickDraw text crash |
| 2 | GWorld state | HIToolbox+0x3a94a4 | Data write | Force graphics initialized |
| 3 | CTFont replacement | HIToolbox GOT 0x93164898 | Lazy pointer redirect | Replace QD fonts with system fonts |
| 4 | Screen update stubs | Exported symbols | Symbol override | Replace removed NSDisable/EnableScreenUpdates |
| 5 | Scroll redraw | DFW_NSView class | ObjC swizzle | Force full-view redraw on scroll |
| 6 | DoIt hook | DFW CTBPopupMenu::DoIt | 5-byte JMP | Replace Carbon menus with NSMenu |
| 7 | AddSubMenu hook | DFW CTBPopupMenu::AddSubMenu | 6-byte JMP | Capture hierarchical menu structure |
| 8 | Bounce Source delegation | DoIt hook (shape match) | Original DoIt via trampoline | Render the one menu that won't build children on the NSMenu path |
| 9 | Null-menu guard | buildNSMenuFromTMenu entry | Range check + try/catch | Prevent crashes on null/invalid child menus (toolbar dropdowns) |
| 10 | CFD passthrough | CFD.framework | dlopen/dlsym | Preserve original compositing |


## 8. Validation

v1.0 was tested on two physically distinct machines with different Pro Tools
configurations, including a clean-install "naked" test rig with no developer
tooling, installed via the end-user installer exactly as a downloader would.
It was also tested across the 10.14.6 build range — the binary built on 18G103
runs unmodified on 18G9323 (the final Mojave security update) — confirming the
hardcoded HIToolbox offsets are stable within 10.14.6. All context menus, the
plugin browser, Mix/Edit I/O routing, the Clip List menus, the full Bounce to
Disk dialog (including the dynamic Bounce Source selector), and the toolbar
option dropdowns were exercised without crashes.


## 9. Files

| File | Language | Lines | Description |
|------|----------|-------|-------------|
| cfd_wrapper.m | Objective-C | 199 | Framework wrapper, system patches, hook installation, build tag |
| pt_menu_bridge.mm | Objective-C++ | 564 | NSMenu builder, AddSubMenu hook, functional submenu finder, Bounce Source delegation, null-menu guard (RELEASE) |
| pt_menu_bridge_debug.mm | Objective-C++ | — | Identical logic plus verbose diagnostics (DEBUG) |
| build.sh | Bash | — | Builds both RELEASE and DEBUG binaries |
| package.sh | Bash | — | Builds, sets permissions, and produces the release zip |
| Install.command | Bash | — | End-user installer (pre-built, no Xcode) |
| Uninstall.command | Bash | — | Restores the original CFD |
