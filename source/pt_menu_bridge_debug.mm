// pt_menu_bridge.mm — v12
// NSMenu replacement for CTBPopupMenu::DoIt
// Submenus captured via AddSubMenu hook

#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <string>
#include <set>
#include <vector>
#include <stdio.h>
#include <stdarg.h>
#include <exception>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>

static bool safe_read_u32(uintptr_t addr, uint32_t* out) {
    if (addr < 0x10000 || addr > 0xF0000000) return false;
    if (addr & 3) return false;
    vm_size_t got = 0;
    mach_vm_size_t want = 4;
    kern_return_t kr = mach_vm_read_overwrite(
        mach_task_self(), (mach_vm_address_t)addr, want,
        (mach_vm_address_t)out, (mach_vm_size_t*)&got);
    return (kr == KERN_SUCCESS && got == 4);
}

extern "C" void pt_log_c(const char* msg);

// ============================================================
// JMP hook with auto-detected prologue length.
// Handles 5-byte (push/push/push), 6-byte (sub esp,imm8),
// and 9-byte (sub esp,imm32) prologues.
// ============================================================
static void patch_jmp(uint8_t* target, void* hookFn, void** origOut, const char* name) {
    char bytebuf[128];
    snprintf(bytebuf, sizeof(bytebuf),
        "%s bytes: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
        name, target[0], target[1], target[2], target[3], target[4],
        target[5], target[6], target[7], target[8], target[9]);
    pt_log_c(bytebuf);

    // Determine how many bytes to copy so we land on an instruction boundary.
    // Standard prologues:
    //   55 89 e5 5X 5X       → 5 bytes (push ebp; mov ebp,esp; push; push)
    //   55 89 e5 83 ec XX    → 6 bytes (push ebp; mov ebp,esp; sub esp,imm8)
    //   55 89 e5 81 ec XX XX XX XX → 9 bytes (sub esp,imm32)
    int copyLen = 5; // default
    if (target[0] == 0x55 && target[1] == 0x89 && target[2] == 0xe5) {
        if (target[3] == 0x83) copyLen = 6;       // sub esp, imm8
        else if (target[3] == 0x81) copyLen = 9;   // sub esp, imm32
    }

    snprintf(bytebuf, sizeof(bytebuf), "  %s copyLen=%d", name, copyLen);
    pt_log_c(bytebuf);

    uint8_t* page = (uint8_t*)mmap(NULL, 0x1000,
        PROT_READ|PROT_WRITE|PROT_EXEC,
        MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) { pt_log_c("  mmap failed"); return; }
    memset(page, 0x90, 0x1000);

    // Trampoline: original bytes + JMP back to target+copyLen
    memcpy(page, target, copyLen);
    page[copyLen]     = 0xFF;
    page[copyLen + 1] = 0x25;
    uint32_t* retSlot = (uint32_t*)(page + 0x100);       // safe fixed slot
    *(uint32_t*)(page + copyLen + 2) = (uint32_t)(uintptr_t)retSlot;
    *retSlot = (uint32_t)(uintptr_t)(target + copyLen);
    if (origOut) *origOut = page;

    // Patch target with 5-byte JMP rel32
    vm_address_t tpage = (vm_address_t)target & ~(vm_page_size - 1);
    if (vm_protect(mach_task_self(), tpage, vm_page_size, FALSE,
                   VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE) != 0) {
        pt_log_c("  vm_protect failed"); return;
    }
    int32_t rel = (int32_t)((uint8_t*)hookFn - (target + 5));
    target[0] = 0xE9; memcpy(target + 1, &rel, 4);
    vm_protect(mach_task_self(), tpage, vm_page_size, FALSE,
               VM_PROT_READ|VM_PROT_EXECUTE);

    snprintf(bytebuf, sizeof(bytebuf), "  hooked %s at %p, trampoline=%p",
             name, target, page);
    pt_log_c(bytebuf);
}

// ============================================================
// DFW types
// ============================================================
typedef int   (*GetNumItems_f)     (void* self, void* tmenu);
typedef void  (*GetTheItemString_f)(void* self, void* tmenu, short index, std::string& out);
typedef bool  (*ItemIsChecked_f)   (void* self, void* tmenu, short index);
typedef void* (*GetBaseMenu_f)     (void* self);
typedef long  (*DoIt_f)            (void* self, void* cpoint, long flags);
typedef long  (*TMenu_GetNumberOfItems_f)(void* tmenu);
typedef void* (*TMenu_GetItemByIdentifier_f)(void* tmenu, long id);
typedef short (*TMenuItem_GetIndex_f)   (void* item);
typedef bool  (*TMenuItem_IsSeparator_f)(void* item);
typedef bool  (*TMenuItem_IsEnabled_f)  (void* item);
typedef bool  (*TMenuItem_IsChecked_f)  (void* item);
typedef void  (*TApplication_MenuEvent_f)(void* self, void* item);
typedef long  (*TMenuManager_CommandFromMenuItem_f)(void* self, void* item);
typedef void  (*AddSubMenu_f)(void* self, void* parent, short index, void* child, const std::string& label);
typedef void  (*FlushAllItems_f)(void* self, void* tmenu);
typedef void* (*TMenuItem_GetParent_f)(void* item);
typedef void  (*TMenuItem_ForceReCreate_f)(void* item);

// ============================================================
// Globals
// ============================================================
static GetNumItems_f       g_GetNumItems       = NULL;
static GetTheItemString_f  g_GetTheItemString  = NULL;
static ItemIsChecked_f     g_ItemIsChecked     = NULL;
static GetBaseMenu_f       g_GetBaseMenu       = NULL;
static DoIt_f              g_orig_DoIt         = NULL;
static TMenu_GetNumberOfItems_f    g_GetNumberOfItems   = NULL;
static TMenu_GetItemByIdentifier_f g_GetItemByIdentifier= NULL;
static TMenuItem_GetIndex_f    g_GetIndex     = NULL;
static TMenuItem_IsSeparator_f g_IsSeparator  = NULL;
static TMenuItem_IsEnabled_f   g_IsEnabled    = NULL;
static TMenuItem_IsChecked_f   g_IsChecked    = NULL;
static TApplication_MenuEvent_f         g_MenuEvent        = NULL;
static TMenuManager_CommandFromMenuItem_f g_CommandFromItem = NULL;
static void**  g_gApplication_ptr = NULL;
static uintptr_t g_TMenuVtableAddr = 0;
static uintptr_t g_DFW_base = 0;  // DFW framework base address
static AddSubMenu_f g_orig_AddSubMenu = NULL;
static FlushAllItems_f g_FlushAllItems = NULL;
static TMenuItem_GetParent_f g_GetParent = NULL;
static TMenuItem_ForceReCreate_f g_ForceReCreate = NULL;

// Check if a pointer looks like a TMenu (exact vtable match only).
static bool is_tmenu_like(uintptr_t p) {
    if (p < 0x10000 || p > 0xF0000000) return false;
    uint32_t vt = 0;
    if (!safe_read_u32(p, &vt)) return false;
    return (g_TMenuVtableAddr && (uintptr_t)vt == g_TMenuVtableAddr);
}

// ============================================================
// AddSubMenu hook — records (parent, index) → child
// ============================================================
struct SubmenuEntry { void* parent; short index; void* child; char label[32]; };
#define MAX_SUBMENUS 4096
static SubmenuEntry g_submenus[MAX_SUBMENUS];
static int g_submenuCount = 0;

extern "C" __attribute__((visibility("default")))
void hook_AddSubMenu(void* self, void* parent, short index, void* child, const std::string& label) {
    if (g_submenuCount < MAX_SUBMENUS) {
        g_submenus[g_submenuCount].parent = parent;
        g_submenus[g_submenuCount].index  = index;
        g_submenus[g_submenuCount].child  = child;
        strncpy(g_submenus[g_submenuCount].label, label.c_str(), 31);
        g_submenus[g_submenuCount].label[31] = 0;
        g_submenuCount++;
    }

    // Log registrations for the routing labels so we can see WHO registers
    // bus/output children and for which parent TMenu.
    const char* L = label.c_str();
    if (L && (strcmp(L, "bus") == 0 || strcmp(L, "output") == 0 ||
              strcmp(L, "physical output") == 0)) {
        char d[160];
        snprintf(d, sizeof(d), "ASM: parent=%p idx=%d child=%p label='%s'",
                 parent, (int)index, child, L);
        pt_log_c(d);
    }

    if (g_orig_AddSubMenu)
        g_orig_AddSubMenu(self, parent, index, child, label);
}

// Functional test: is `cand` a real child TMenu* that `self` can drive?
// A real menu returns a sane count AND its first item has a readable name.
// This is far more reliable than a vtable-only check (no false positives
// that crash, because we actually exercise the data path).
// Read up to `maxItems` item strings from a candidate menu into `out`.
// Returns the count actually read, or -1 on failure.
static int read_menu_items(void* self, void* cand, std::vector<std::string>& out, int maxItems) {
    int got = 0;
    try {
        int n = g_GetNumItems(self, cand);
        if (n <= 0 || n >= 500) return -1;
        for (short k = 1; k <= (short)n && got < maxItems; k++) {
            std::string s;
            try { g_GetTheItemString(self, cand, k, s); } catch (...) { break; }
            out.push_back(s);
            got++;
        }
    } catch (...) { return -1; }
    return got;
}

// Score how "routing-like" a candidate menu's contents are.  Routing menus
// contain entries like "main (Stereo)", "drums.L (Mono)", "A 1-2", etc.
// A wrong menu (e.g. automation "Set all to / Add / Subtract") scores ~0.
static int score_routing_menu(const std::vector<std::string>& items) {
    int score = 0;
    for (const std::string& s : items) {
        if (s.find("(Stereo)") != std::string::npos) score += 3;
        if (s.find("(Mono)")   != std::string::npos) score += 3;
        if (s.find("(Mono/")   != std::string::npos) score += 2;
        // Bus/path style names
        if (s.find(" L") != std::string::npos || s.find(" R") != std::string::npos) score += 0;
        if (s.find("->") != std::string::npos) score += 2;
    }
    return score;
}

static bool probe_child_menu(void* self, void* cand, void* parentTMenu, std::set<void*>& visited) {
    if (!cand || cand == parentTMenu) return false;
    uintptr_t p = (uintptr_t)cand;
    if (p < 0x10000 || p > 0xF0000000) return false;
    if (visited.count(cand)) return false;
    if (!is_tmenu_like(p)) return false;       // cheap reject first
    bool good = false;
    try {
        int n = g_GetNumItems(self, cand);
        if (n > 0 && n < 500) {
            std::string s;
            g_GetTheItemString(self, cand, 1, s);   // first real item
            if (!s.empty() && s[0] != 0) good = true;
        }
    } catch (...) { good = false; }
    return good;
}

// Search an item's DIRECT fields for a real child menu, then pick the
// candidate whose contents are most routing-like.  Level-1 only — the
// previous Level-2 indirection scan found unrelated menus (e.g. the
// automation "Set all to" menu), causing the wrong-entries bug.
static void* findChildMenuFunctional(void* self, void* tmenuItem,
                                      void* parentTMenu, std::set<void*>& visited) {
    if (!tmenuItem) return NULL;
    uintptr_t base = (uintptr_t)tmenuItem;
    void* best = NULL;
    int bestScore = -1;
    int candCount = 0;
    char d[160];
    for (int off = 0x4; off <= 0x80; off += 4) {
        uint32_t c = 0;
        if (!safe_read_u32(base + off, &c)) continue;
        void* cand = (void*)(uintptr_t)c;
        if (!probe_child_menu(self, cand, parentTMenu, visited)) continue;
        std::vector<std::string> items;
        int ni = read_menu_items(self, cand, items, 12);
        if (ni <= 0) continue;
        int sc = score_routing_menu(items);
        candCount++;
        snprintf(d, sizeof(d), "    cand off=0x%02x ptr=%p items=%d score=%d first='%s'",
                 off, cand, ni, sc, items.empty() ? "" : items[0].c_str());
        pt_log_c(d);
        if (sc > bestScore) { bestScore = sc; best = cand; }
    }
    snprintf(d, sizeof(d), "    findChild: %d candidate(s), bestScore=%d", candCount, bestScore);
    pt_log_c(d);
    // Accept the best candidate if it has readable items (score may be 0 for
    // some routing lists); scoring only breaks ties toward routing-like menus.
    if (best) return best;
    return NULL;
}

static void* findSubmenu(void* parent, short index, const char* name = NULL) {
    // Exact (parent, index) match from AddSubMenu hook.
    for (int i = g_submenuCount - 1; i >= 0; i--)
        if (g_submenus[i].parent == parent && g_submenus[i].index == index)
            return g_submenus[i].child;
    return NULL;
}

// ============================================================
struct CPoint { short v; short h; };

@interface PTMenuTarget : NSObject { @public void* selectedItem; }
- (void)menuItemPicked:(id)sender;
@end
@implementation PTMenuTarget
- (id)init { self = [super init]; if (self) selectedItem = NULL; return self; }
- (void)menuItemPicked:(id)sender {
    NSMenuItem* mi = (NSMenuItem*)sender;
    selectedItem = (void*)[[mi representedObject] pointerValue];
    char buf[128];
    snprintf(buf, sizeof(buf), "menuItemPicked: TMenuItem*=%p '%s'",
             selectedItem, [[mi title] UTF8String] ?: "?");
    pt_log_c(buf);
}
@end

// Forward decl
static NSMenu* buildNSMenuFromTMenu(void* self, void* tmenu, PTMenuTarget* target,
                                     int depth, std::set<void*>& visited);

static NSMenu* buildNSMenu(void* self, long flags, PTMenuTarget* target) {
    // Don't clear — accumulate entries so cached BuildMenu calls don't lose
    // triangles.  Wrap around if table is full.
    if (g_submenuCount >= MAX_SUBMENUS) g_submenuCount = 0;

    void** vtable = *(void***)self;
    if (vtable) {
        typedef long (*BuildMenu_f)(void* self, long flags);
        ((BuildMenu_f)vtable[2])(self, flags);
    }

    char buf[64];
    snprintf(buf, sizeof(buf), "buildNSMenu: %d submenu(s)", g_submenuCount);
    pt_log_c(buf);

    void* tmenu = g_GetBaseMenu(self);
    if (!tmenu) { pt_log_c("buildNSMenu: tmenu NULL"); return [[NSMenu alloc] initWithTitle:@""]; }

    std::set<void*> visited;
    return buildNSMenuFromTMenu(self, tmenu, target, 0, visited);
}

static NSMenu* buildNSMenuFromTMenu(void* self, void* tmenu, PTMenuTarget* target,
                                     int depth, std::set<void*>& visited) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    [menu setAutoenablesItems:NO];
    if (depth > 5) { pt_log_c("max depth"); return menu; }
    // Guard against a null or obviously-invalid TMenu* before we touch it.
    // Some menus (e.g. the toolbar options menu) can hand us a null child,
    // and GetNumItems would dereference it and crash at a tiny address.
    if ((uintptr_t)tmenu < 0x10000 || (uintptr_t)tmenu > 0xF0000000) {
        pt_log_c("buildNSMenu: invalid tmenu, skipping");
        return menu;
    }
    if (visited.count(tmenu)) { pt_log_c("cycle"); return menu; }
    visited.insert(tmenu);

    int count = 0;
    try {
        count = g_GetNumItems(self, tmenu);
    } catch (...) {
        pt_log_c("buildNSMenu: GetNumItems threw, skipping");
        return menu;
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "buildNSMenu[d=%d]: %d items tmenu=%p", depth, count, tmenu);
    pt_log_c(buf);
    if (count <= 0 || count > 500) return menu;

    // Start at 0: PT stores "no insert"/"no input"/"no output" at index 0,
    // which GetNumItems doesn't count.  If index 0 throws, just skip it.
    for (short i = 0; i <= (short)count; i++) {
        char dbg[256];
        std::string title;
        bool ok = true;
        try { g_GetTheItemString(self, tmenu, i, title); }
        catch (...) {
            if (i == 0) continue;  // index 0 may not exist in some menus
            snprintf(dbg, sizeof(dbg), "  item[%d] threw, stopping", i);
            pt_log_c(dbg); ok = false;
        }
        if (!ok) break;
        const char* cstr = title.c_str();
        // Only log item names at top level (depth 0) to avoid 385+ plugin log entries
        if (depth == 0) {
            snprintf(dbg, sizeof(dbg), "  item[%d] = '%s'", i, cstr ?: "(null)");
            pt_log_c(dbg);
        }

        if (cstr && cstr[0] == '-' && cstr[1] == 0) {
            [menu addItem:[NSMenuItem separatorItem]];
            continue;
        }

        NSString* nsTitle = [NSString stringWithUTF8String:(cstr ?: "")];
        if (!nsTitle) nsTitle = @"";

        NSMenuItem* mi = [[NSMenuItem alloc]
            initWithTitle:nsTitle action:@selector(menuItemPicked:) keyEquivalent:@""];
        [mi setTarget:target];
        [mi setTag:(NSInteger)i];

        void* tmenuItem = NULL;
        try {
            void** tv = *(void***)tmenu;
            if (tv) {
                typedef void* (*GIA_f)(void*, short);
                tmenuItem = ((GIA_f)tv[0x64/4])(tmenu, i);
            }
        } catch (...) { tmenuItem = NULL; }
        [mi setRepresentedObject:[NSValue valueWithPointer:tmenuItem]];

        // --- SUBMENU: AddSubMenu hook map (primary) ---
        void* childTMenu = findSubmenu(tmenu, i, cstr);
        if (childTMenu && !visited.count(childTMenu)) {
            snprintf(dbg, sizeof(dbg),
                "  item[%d] '%s' SUBMENU via hook: child=%p", i, cstr, childTMenu);
            pt_log_c(dbg);
            NSMenu* sub = buildNSMenuFromTMenu(self, childTMenu, target, depth+1, visited);
            if (sub && [sub numberOfItems] > 0)
                [mi setSubmenu:sub];
        }

        // --- Fallback: functional child-menu finder ---
        // Only attempt when the hook didn't already provide a child AND the
        // item is a routing-style parent that genuinely has submenus.  This
        // gate prevents false submenus on items like 'QuickTime', '96 kHz',
        // 'Interleaved', 'Tweak Head' which must stay leaf items.
        bool routingParent =
            cstr && (strcmp(cstr, "bus") == 0 ||
                     strcmp(cstr, "output") == 0 ||
                     strcmp(cstr, "physical output") == 0 ||
                     strcmp(cstr, "no output") == 0 ||
                     strcmp(cstr, "track") == 0);
        if (!childTMenu && tmenuItem && routingParent) {
            void* found = findChildMenuFunctional(self, tmenuItem, tmenu, visited);
            if (found && !visited.count(found)) {
                snprintf(dbg, sizeof(dbg),
                    "  item[%d] '%s' SUBMENU functional: child=%p", i, cstr, found);
                pt_log_c(dbg);
                NSMenu* sub = buildNSMenuFromTMenu(self, found, target, depth+1, visited);
                if (sub && [sub numberOfItems] > 0)
                    [mi setSubmenu:sub];
            }
        }

        if (g_ItemIsChecked && g_ItemIsChecked(self, tmenu, i))
            [mi setState:NSControlStateValueOn];
        [mi setEnabled:YES];
        [menu addItem:mi];
    }
    pt_log_c("buildNSMenu: done iterating");
    return menu;
}

// ============================================================
// DoIt hook
// Detect the Bounce Source popup.  Its top items are some combination of
// "bus" / "output" / "physical output" (the exact set varies by machine,
// session, and hardware — some rigs show all three, some only two).  This
// menu never builds its own child submenus under our NSMenu path, so we
// delegate it to the original Carbon DoIt which renders children correctly.
//
// We match by SHAPE, not an exact list: a small menu (2-3 items) whose
// every item is one of those routing labels.  This is specific enough that
// no normal menu collides with it, but flexible across configurations.
static bool isBounceSourceMenu(void* self) {
    void* tmenu = NULL;
    try { tmenu = g_GetBaseMenu(self); } catch (...) { return false; }
    if ((uintptr_t)tmenu < 0x10000 || (uintptr_t)tmenu > 0xF0000000) return false;
    int count = 0;
    try { count = g_GetNumItems(self, tmenu); } catch (...) { return false; }
    if (count < 2 || count > 3) return false;
    int routingHits = 0;
    for (short i = 0; i < (short)count; i++) {
        std::string s;
        try { g_GetTheItemString(self, tmenu, i, s); }
        catch (...) { return false; }
        if (s == "bus" || s == "output" || s == "physical output")
            routingHits++;
        else
            return false;   // any non-routing item disqualifies it
    }
    return routingHits == count;
}

// ============================================================
extern "C" __attribute__((visibility("default")))
long hook_CTBPopupMenu_DoIt(void* self, CPoint* point, long flags) {
    char buf[256];
    snprintf(buf, sizeof(buf), "hook_DoIt: self=%p point=(%d,%d) flags=%ld",
             self, point ? point->h : -1, point ? point->v : -1, flags);
    pt_log_c(buf);

    if (!self || !point || !g_GetNumItems || !g_GetTheItemString || !g_GetBaseMenu) {
        pt_log_c("hook_DoIt: missing prereqs"); return 0;
    }

    // Bounce Source: this popup never builds child submenus under our NSMenu
    // path (AddSubMenu never fires for it).  Delegate to the original Carbon
    // DoIt, which builds and shows the bus/output/physical-output children
    // correctly.  All other menus continue to use our NSMenu replacement.
    if (g_orig_DoIt && isBounceSourceMenu(self)) {
        pt_log_c("hook_DoIt: Bounce Source -> original Carbon DoIt");
        long r = 0;
        try { r = g_orig_DoIt(self, point, flags); } catch (...) { r = 0; }
        snprintf(buf, sizeof(buf), "hook_DoIt: original DoIt returned %ld", r);
        pt_log_c(buf);
        return r;
    }

    NSScreen* main = [NSScreen mainScreen];
    CGFloat screenH = main ? main.frame.size.height : 900.0f;
    NSPoint nsLoc = NSMakePoint((CGFloat)point->h, screenH - (CGFloat)point->v);

    __block void* selectedItem = NULL;
    __block long retIndex = 0;

    dispatch_block_t block = ^{
        PTMenuTarget* target = [[PTMenuTarget alloc] init];
        NSMenu* menu = buildNSMenu(self, flags, target);
        if ([menu numberOfItems] == 0) {
            pt_log_c("hook_DoIt: empty menu"); return;
        }
        pt_log_c("hook_DoIt: showing NSMenu");

        BOOL ok = [menu popUpMenuPositioningItem:nil atLocation:nsLoc inView:nil];
        char d[64]; snprintf(d, sizeof(d), "hook_DoIt: popup ok=%d", (int)ok);
        pt_log_c(d);

        selectedItem = target->selectedItem;
        if (selectedItem && g_GetIndex)
            retIndex = (long)g_GetIndex(selectedItem);
    };

    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);

    snprintf(buf, sizeof(buf), "hook_DoIt: selected=%p idx=%ld", selectedItem, retIndex);
    pt_log_c(buf);

    return (long)(uintptr_t)selectedItem;
}

// ============================================================
// Init
// ============================================================
extern "C" int pt_menu_bridge_init(void** outDoItAddr) {
    void* h = dlopen("/Applications/Avid/Pro Tools/Pro Tools.app/Contents/Frameworks/DFW.framework/Versions/A/DFW",
                     RTLD_NOLOAD | RTLD_NOW);
    if (!h) h = dlopen("/Applications/Avid/Pro Tools/Pro Tools.app/Contents/Frameworks/DFW.framework/Versions/A/DFW",
                       RTLD_NOW);
    if (!h) { pt_log_c("DFW dlopen failed"); return -1; }

    g_GetNumItems        = (GetNumItems_f)       dlsym(h, "_ZNK12CTBPopupMenu11GetNumItemsEP5TMenu");
    g_GetTheItemString   = (GetTheItemString_f)  dlsym(h, "_ZN12CTBPopupMenu16GetTheItemStringEP5TMenusRSs");
    g_ItemIsChecked      = (ItemIsChecked_f)     dlsym(h, "_ZN12CTBPopupMenu13ItemIsCheckedEP5TMenus");
    g_GetBaseMenu        = (GetBaseMenu_f)       dlsym(h, "_ZN12CTBPopupMenu11GetBaseMenuEv");
    g_FlushAllItems      = (FlushAllItems_f)     dlsym(h, "_ZN12CTBPopupMenu13FlushAllItemsEP5TMenu");
    g_GetNumberOfItems    = (TMenu_GetNumberOfItems_f)   dlsym(h, "_ZN5TMenu16GetNumberOfItemsEv");
    g_GetItemByIdentifier = (TMenu_GetItemByIdentifier_f)dlsym(h, "_ZN5TMenu19GetItemByIdentifierEl");
    g_GetIndex     = (TMenuItem_GetIndex_f)    dlsym(h, "_ZN9TMenuItem8GetIndexEv");
    g_GetParent    = (TMenuItem_GetParent_f)   dlsym(h, "_ZNK9TMenuItem9GetParentEv");
    g_ForceReCreate= (TMenuItem_ForceReCreate_f)dlsym(h, "_ZN9TMenuItem14Force_ReCreateEv");
    g_IsSeparator  = (TMenuItem_IsSeparator_f) dlsym(h, "_ZN9TMenuItem11IsSeparatorEv");
    g_IsEnabled    = (TMenuItem_IsEnabled_f)   dlsym(h, "_ZN9TMenuItem9IsEnabledEv");
    g_IsChecked    = (TMenuItem_IsChecked_f)   dlsym(h, "_ZN9TMenuItem9IsCheckedEv");
    g_MenuEvent       = (TApplication_MenuEvent_f)         dlsym(h, "_ZN12TApplication9MenuEventEP9TMenuItem");
    g_CommandFromItem = (TMenuManager_CommandFromMenuItem_f)dlsym(h, "_ZN12TMenuManager19CommandFromMenuItemEP9TMenuItem");
    g_gApplication_ptr = (void**) dlsym(h, "_gApplication");
    if (!g_gApplication_ptr) g_gApplication_ptr = (void**) dlsym(h, "gApplication");

    {
        char r[96];
        snprintf(r, sizeof(r), "symbols: GetParent=%p Force_ReCreate=%p",
                 (void*)g_GetParent, (void*)g_ForceReCreate);
        pt_log_c(r);
    }

    if (g_GetNumItems) {
        uintptr_t base = (uintptr_t)g_GetNumItems - 0x79e00;
        g_DFW_base = base;
        if (!g_gApplication_ptr) {
            g_gApplication_ptr = (void**)(base + 0x2d1434);
            pt_log_c("computed gApplication via DFW base + offset");
        }
        g_TMenuVtableAddr = base + 0x2cdbe0 + 8;
        char t[128]; snprintf(t, sizeof(t), "TMenu vtable = 0x%lx", (unsigned long)g_TMenuVtableAddr);
        pt_log_c(t);
    }

    // Hook AddSubMenu (6-byte prologue: 55 89 e5 83 ec 48)
    void* asmAddr = dlsym(h, "_ZN12CTBPopupMenu10AddSubMenuEP5TMenusS1_RKSs");
    if (asmAddr) {
        void* origASM = NULL;
        patch_jmp((uint8_t*)asmAddr, (void*)hook_AddSubMenu, &origASM, "AddSubMenu");
        g_orig_AddSubMenu = (AddSubMenu_f)origASM;
    } else {
        pt_log_c("WARNING: AddSubMenu not found");
    }

    void* doIt = dlsym(h, "_ZN12CTBPopupMenu4DoItER7_CPointl");

    char buf[512];
    snprintf(buf, sizeof(buf), "bridge: GNI=%p GIS=%p GBM=%p DoIt=%p GetIdx=%p ASM=%p",
        g_GetNumItems, g_GetTheItemString, g_GetBaseMenu, doIt, g_GetIndex, asmAddr);
    pt_log_c(buf);

    if (!g_GetNumItems || !g_GetTheItemString || !g_GetBaseMenu || !doIt) return -2;
    if (outDoItAddr) *outDoItAddr = doIt;
    return 0;
}

extern "C" void pt_menu_bridge_set_orig_DoIt(void* addr) {
    g_orig_DoIt = (DoIt_f)addr;
}
