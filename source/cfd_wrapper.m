#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <pthread.h>
#include <Carbon/Carbon.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <time.h>

// Build identity. Override at compile time with:
//   -DPT_BUILD_TAG='"DEBUG"'   (verbose logging build)
//   -DPT_BUILD_TAG='"RELEASE"' (quiet build; this is the default)
#ifndef PT_BUILD_TAG
#define PT_BUILD_TAG "RELEASE"
#endif

// File logger
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static void pt_log(const char* fmt, ...) __attribute__((format(printf,1,2)));
static void pt_log(const char* fmt, ...) {
    pthread_mutex_lock(&gLogLock);
    FILE* f = fopen("/tmp/pt_fix.log", "a");
    if (f) {
        time_t t = time(NULL);
        struct tm* tm = localtime(&t);
        fprintf(f, "%02d:%02d:%02d ", tm->tm_hour, tm->tm_min, tm->tm_sec);
        va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
        fprintf(f, "\n");
        fclose(f);
    }
    pthread_mutex_unlock(&gLogLock);
}

// C-callable logger used by pt_menu_bridge.mm
void pt_log_c(const char* msg) { pt_log("%s", msg); }

// Bridge symbols (defined in pt_menu_bridge.mm)
extern int  pt_menu_bridge_init(void** outDoItAddr);
extern void pt_menu_bridge_set_orig_DoIt(void* addr);
extern long hook_CTBPopupMenu_DoIt(void* self, void* point, long flags);

#define HITOOLBOX_BASE  0x92de0000UL
#define HLTB_VMADDR     0x0005131fUL
#define GWORLD_ABS      (HITOOLBOX_BASE + 0x003a94a4UL)
#define OFF_ISLAND      0x000
#define OFF_RET_SLOT    0x010
#define OFF_HOOK        0x100

static uint8_t* gDoItPage = NULL;

// Install a 5-byte JMP hook at target -> hookFn. orig copy goes through trampoline.
static void install_simple_hook(uint8_t* target, void* hookFn, void** origOut, const char* name) {
    pt_log("%s bytes: %02x %02x %02x %02x %02x",
           name, target[0], target[1], target[2], target[3], target[4]);
    uint8_t* page = (uint8_t*)mmap(NULL, 0x1000, PROT_READ|PROT_WRITE|PROT_EXEC,
                                   MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) { pt_log("%s mmap failed", name); return; }
    memset(page, 0x90, 0x1000);
    uint8_t* island = page + OFF_ISLAND;
    uint32_t* ret_slot = (uint32_t*)(page + OFF_RET_SLOT);
    memcpy(island, target, 5);
    island[5] = 0xFF; island[6] = 0x25;
    *(uint32_t*)(island + 7) = (uint32_t)(uintptr_t)ret_slot;
    *ret_slot = (uint32_t)(uintptr_t)(target + 5);
    if (origOut) *origOut = island;
    vm_address_t tpage = (vm_address_t)target & ~(vm_page_size - 1);
    if (vm_protect(mach_task_self(), tpage, vm_page_size, FALSE,
                   VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE) != 0) {
        pt_log("%s vm_protect failed", name); return;
    }
    int32_t rel = (int32_t)((uint8_t*)hookFn - (target + 5));
    target[0] = 0xE9; memcpy(target + 1, &rel, 4);
    vm_protect(mach_task_self(), tpage, vm_page_size, FALSE,
               VM_PROT_READ|VM_PROT_EXECUTE);
    pt_log("%s hooked target=%p hookFn=%p", name, target, hookFn);
}

static void stub_hltb(void) {
    uint8_t* t = (uint8_t*)(HITOOLBOX_BASE + HLTB_VMADDR);
    vm_address_t pg = (vm_address_t)t & ~(vm_page_size-1);
    vm_protect(mach_task_self(), pg, vm_page_size, FALSE, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
    t[0]=0xB8; t[1]=0x01; t[2]=0x00; t[3]=0x00; t[4]=0x00; t[5]=0xC3;
    vm_protect(mach_task_self(), pg, vm_page_size, FALSE, VM_PROT_READ|VM_PROT_EXECUTE);
    pt_log("HLTB stubbed");
}

static void fix_gworld(void) {
    vm_address_t pg = GWORLD_ABS & ~(vm_page_size-1);
    vm_protect(mach_task_self(), pg, vm_page_size, TRUE,  VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
    vm_protect(mach_task_self(), pg, vm_page_size, FALSE, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
    volatile uint32_t* p = (volatile uint32_t*)GWORLD_ABS;
    uint32_t v = *p; *p = v; *p = 2;
    pt_log("sState=2 (was %u)", v);
}

static CTFontRef my_CTFontCreateWithQuickdrawInstance(
    const unsigned char *name, int16_t size, uint8_t style, CGFloat pointSize) {
    if (pointSize <= 0.0f || pointSize > 256.0f) pointSize = 13.0f;
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontMenuItem, pointSize, NULL);
    if (!font) font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, pointSize, NULL);
    return font;
}
static void patch_CTFontCreateWithQuickdrawInstance(void) {
    uint32_t* lazy = (uint32_t*)0x93164898UL;
    vm_address_t pg = (vm_address_t)lazy & ~(vm_page_size-1);
    if (vm_protect(mach_task_self(), pg, vm_page_size, FALSE, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE) != KERN_SUCCESS) return;
    *lazy = (uint32_t)(uintptr_t)my_CTFontCreateWithQuickdrawInstance;
    vm_protect(mach_task_self(), pg, vm_page_size, FALSE, VM_PROT_READ|VM_PROT_EXECUTE);
    pt_log("CTFont patched");
}

// Scroll fix swizzles (kept from original)
static IMP o_sND=NULL,o_sNDR=NULL,o_sND_c=NULL,o_sNDR_c=NULL;
static void s_sND  (id s,SEL c,BOOL f){ if(o_sND)  ((void(*)(id,SEL,BOOL))o_sND)(s,c,YES); }
static void s_sNDR (id s,SEL c,NSRect r){ if(o_sNDR) ((void(*)(id,SEL,NSRect))o_sNDR)(s,c,[s bounds]); }
static void s_sND_c (id s,SEL c,BOOL f){ if(o_sND_c) ((void(*)(id,SEL,BOOL))o_sND_c)(s,c,YES); }
static void s_sNDR_c(id s,SEL c,NSRect r){ if(o_sNDR_c)((void(*)(id,SEL,NSRect))o_sNDR_c)(s,c,[s bounds]); }
static void sw(Class c,SEL sel,IMP*o,IMP r,const char*t){
    if(!c) return; Method m=class_getInstanceMethod(c,sel);
    if(m){ if(o) *o=method_getImplementation(m); method_setImplementation(m,r); }
    else class_addMethod(c,sel,r,t);
    pt_log("Swizzled %s", sel_getName(sel));
}
static void* poll_swizzle(void *arg){
    for(int i=0;i<600;i++){
        usleep(100000);
        if(objc_getClass("DFW_NSView")){
            dispatch_async(dispatch_get_main_queue(), ^{
                Class v=objc_getClass("DFW_NSView");
                sw(v,@selector(setNeedsDisplay:),&o_sND,(IMP)s_sND,"v@:c");
                sw(v,@selector(setNeedsDisplayInRect:),&o_sNDR,(IMP)s_sNDR,"v@:{NSRect={NSPoint=ff}{NSSize=ff}}");
                Class c=objc_getClass("DFW_NSContainer");
                sw(c,@selector(setNeedsDisplay:),&o_sND_c,(IMP)s_sND_c,"v@:c");
                sw(c,@selector(setNeedsDisplayInRect:),&o_sNDR_c,(IMP)s_sNDR_c,"v@:{NSRect={NSPoint=ff}{NSSize=ff}}");
                pt_log("Scroll fix installed");
            });
            return NULL;
        }
    }
    return NULL;
}

// CFD passthrough
static void* cfd_handle = NULL;
static void* real_GVS = NULL;
static void* real_Init = NULL;
void* _ZN13Cfd_Interface13GetViewServerEv(void){ return real_GVS  ? ((void*(*)(void))real_GVS )() : NULL; }
void* _ZN13Cfd_Interface4InitEv(void)        {
    pt_log("CFD Init called");
    return real_Init ? ((void*(*)(void))real_Init)() : NULL;
}
void NSDisableScreenUpdates(void){}
void NSEnableScreenUpdates(void){ [CATransaction flush]; }

__attribute__((constructor))
static void init(void) {
    pt_log("=== CFD wrapper [" PT_BUILD_TAG "] session 10 (NSMenu approach) START ===");
    stub_hltb();
    fix_gworld();
    patch_CTFontCreateWithQuickdrawInstance();

    // Initialize the menu bridge -- resolves DFW symbols
    void* doItAddr = NULL;
    int rc = pt_menu_bridge_init(&doItAddr);
    pt_log("pt_menu_bridge_init rc=%d doItAddr=%p", rc, doItAddr);

    if (rc == 0 && doItAddr) {
        // Hook CTBPopupMenu::DoIt
        void* orig = NULL;
        install_simple_hook((uint8_t*)doItAddr, (void*)hook_CTBPopupMenu_DoIt,
                            &orig, "CTBPopupMenu::DoIt");
        pt_menu_bridge_set_orig_DoIt(orig);
    } else {
        pt_log("Menu bridge init failed, NOT hooking DoIt");
    }

    // CFD passthrough (so PT can still call into the real CFD)
    cfd_handle = dlopen(
        "/Applications/Avid/Pro Tools/Pro Tools.app/Contents/Frameworks/CFD.framework/Versions/A/CFD_original",
        RTLD_NOW|RTLD_GLOBAL);
    if (cfd_handle) {
        real_GVS  = dlsym(cfd_handle, "_ZN13Cfd_Interface13GetViewServerEv");
        real_Init = dlsym(cfd_handle, "_ZN13Cfd_Interface4InitEv");
        pt_log("CFD passthrough loaded GVS=%p Init=%p", real_GVS, real_Init);
    } else {
        pt_log("CFD_original dlopen FAILED: %s", dlerror());
    }

    // Scroll fix swizzles (background thread, waits for DFW_NSView to load)
    pthread_t sw2;
    pthread_create(&sw2, NULL, poll_swizzle, NULL);
    pthread_detach(sw2);

    pt_log("=== CFD wrapper [" PT_BUILD_TAG "] session 10 DONE ===");
}
