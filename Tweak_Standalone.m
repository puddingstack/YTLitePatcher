/*
 * YTLitePatcher v6
 *
 * FINDINGS from LIEF binary analysis:
 * - _dvnLocked() reads a BOOL at 0x11524e1 in __DATA.__data (WRITABLE!)
 * - Current value = 1 (locked). Setting to 0 = unlocked.
 * - _dvnCheck() calls an internal function then objc_msgSend (checks auth)
 * - 4 functions READ this variable, 1 function WRITES it
 * - The variable is at offset 23937 (0x5D81) into __DATA.__data section
 *
 * Strategy:
 * 1. Find YTLite.dylib's __DATA.__data section at runtime
 * 2. Zero the lock variable (safe — __DATA is writable)
 * 3. ObjC hooks for settings UI
 * 4. Periodically re-zero in case YTLite resets it
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

// ============================================================
// ObjC helpers
// ============================================================
static void swizzleMethod(Class cls, SEL original, IMP replacement, IMP *store) {
    Method method = class_getInstanceMethod(cls, original);
    if (method) {
        *store = method_getImplementation(method);
        method_setImplementation(method, replacement);
    }
}

static void forceReturnYES(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) method_setImplementation(m, imp_implementationWithBlock(^BOOL(id s){ return YES; }));
}

static void forceReturnNO(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) method_setImplementation(m, imp_implementationWithBlock(^BOOL(id s){ return NO; }));
}

// ============================================================
// Replacements
// ============================================================
static IMP orig_DVNCell_setLocked;
static void rep_DVNCell_setLocked(id self, SEL _cmd, BOOL locked) {
    if (orig_DVNCell_setLocked)
        ((void(*)(id, SEL, BOOL))orig_DVNCell_setLocked)(self, _cmd, NO);
}

static IMP orig_DVNTVC_setLocked;
static void rep_DVNTVC_setLocked(id self, SEL _cmd, BOOL locked) {
    if (orig_DVNTVC_setLocked)
        ((void(*)(id, SEL, BOOL))orig_DVNTVC_setLocked)(self, _cmd, NO);
}

static IMP orig_WelcomeVC_viewDidLoad;
static void rep_WelcomeVC_viewDidLoad(id self, SEL _cmd) {
    if (orig_WelcomeVC_viewDidLoad)
        ((void(*)(id, SEL))orig_WelcomeVC_viewDidLoad)(self, _cmd);
    dispatch_async(dispatch_get_main_queue(), ^{
        [(UIViewController *)self dismissViewControllerAnimated:NO completion:nil];
    });
}

static IMP orig_patreonSection;
static id rep_patreonSection(id self, SEL _cmd) {
    id section = orig_patreonSection
        ? ((id(*)(id, SEL))orig_patreonSection)(self, _cmd) : nil;
    if (section) {
        SEL setCells = NSSelectorFromString(@"setCells:");
        if ([section respondsToSelector:setCells])
            ((void(*)(id, SEL, id))objc_msgSend)(section, setCells, @[]);
    }
    return section;
}

// ============================================================
// __DATA variable finder — safe, only touches writable memory
// Finds __DATA.__data section and zeros the lock variable.
// ============================================================
static uint8_t *g_lockVarAddr = NULL;

static void findAndZeroLockVar(const struct mach_header *mh, intptr_t slide) {
    if (!mh) return;

    const struct mach_header_64 *h64 = (const struct mach_header_64 *)mh;
    struct load_command *cmd = (struct load_command *)((uintptr_t)h64 + sizeof(struct mach_header_64));

    for (uint32_t i = 0; i < h64->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, "__DATA") == 0) {
                struct section_64 *sections = (struct section_64 *)((uintptr_t)seg + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    if (strcmp(sections[j].sectname, "__data") == 0) {
                        // Found __DATA.__data
                        uintptr_t sec_addr = sections[j].addr + slide;
                        uint64_t sec_size = sections[j].size;

                        // The lock variable is at offset 0x5D81 into __DATA.__data
                        // (address 0x11524e1, section base 0x114c760, offset = 0x5D81)
                        uint64_t lock_offset = 0x5D81;

                        if (lock_offset + 2 <= sec_size) {
                            g_lockVarAddr = (uint8_t *)(sec_addr + lock_offset);
                            // Zero both the variable AND the adjacent byte
                            // (surrounding bytes showed 00 00 00 01 01 00 00 00)
                            g_lockVarAddr[0] = 0;  // main lock flag
                            g_lockVarAddr[1] = 0;  // adjacent flag
                        }
                        return;
                    }
                }
            }
        }
        cmd = (struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }
}

static void reZeroLockVar(void) {
    if (g_lockVarAddr) {
        g_lockVarAddr[0] = 0;
        g_lockVarAddr[1] = 0;
    }
}

// ============================================================
// Hook registration — called after YTLite init completes
// ============================================================
static BOOL g_hooked = NO;

static void registerAllHooks(const struct mach_header *mh, intptr_t slide) {
    if (g_hooked) return;
    g_hooked = YES;

    // ── LEVEL 1: Zero the lock variable in __DATA (safe, writable) ──
    findAndZeroLockVar(mh, slide);

    // ── LEVEL 2: ObjC hooks ──

    // -- DVNCell: unlock all cells --
    Class dvnCell = objc_getClass("DVNCell");
    if (dvnCell) {
        swizzleMethod(dvnCell, @selector(setLocked:),
                      (IMP)rep_DVNCell_setLocked, &orig_DVNCell_setLocked);
        forceReturnNO(dvnCell, @selector(isLocked));
        forceReturnNO(dvnCell, @selector(locked));
    }

    // -- DVNTableViewController: unlock --
    Class dvnTVC = objc_getClass("DVNTableViewController");
    if (dvnTVC) {
        Method m = class_getInstanceMethod(dvnTVC, @selector(setLocked:));
        if (m) swizzleMethod(dvnTVC, @selector(setLocked:),
                             (IMP)rep_DVNTVC_setLocked, &orig_DVNTVC_setLocked);
        forceReturnNO(dvnTVC, @selector(locked));
        forceReturnNO(dvnTVC, @selector(isLocked));
    }

    // -- DVNPatreonContext: force all auth checks to YES --
    Class patreonCtx = objc_getClass("DVNPatreonContext");
    if (patreonCtx) {
        SEL authSels[] = {
            @selector(isAuthorized), @selector(isAuthenticated),
            @selector(isLoggedIn), @selector(isActive),
            NSSelectorFromString(@"isPatron"),
            NSSelectorFromString(@"hasActiveSubscription"),
        };
        for (int i = 0; i < sizeof(authSels)/sizeof(authSels[0]); i++) {
            if (authSels[i]) forceReturnYES(patreonCtx, authSels[i]);
        }
    }

    // -- WelcomeVC: auto-dismiss login screen --
    Class welcomeVC = objc_getClass("WelcomeVC");
    if (welcomeVC) {
        swizzleMethod(welcomeVC, @selector(viewDidLoad),
                      (IMP)rep_WelcomeVC_viewDidLoad, &orig_WelcomeVC_viewDidLoad);
    }

    // -- YTPSettingsBuilder: empty patreon section --
    Class settingsBuilder = objc_getClass("YTPSettingsBuilder");
    if (settingsBuilder) {
        Method m = class_getInstanceMethod(settingsBuilder,
                       NSSelectorFromString(@"patreonSection"));
        if (m) {
            orig_patreonSection = method_getImplementation(m);
            method_setImplementation(m, (IMP)rep_patreonSection);
        }
    }

    // ── LEVEL 3: Periodic re-zero of lock variable ──
    if (g_lockVarAddr) {
        for (int i = 1; i <= 20; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * 3 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ reZeroLockVar(); });
        }
    }
}

// ============================================================
// dyld callback — waits for YTLite.dylib specifically
// ============================================================
static const struct mach_header *g_ytlHeader = NULL;
static intptr_t g_ytlSlide = 0;

static void dyld_image_added(const struct mach_header *mh, intptr_t slide) {
    if (g_hooked) return;

    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;

    // Match YTLite.dylib EXACTLY — not "YTLitePatcher.dylib"
    const char *fname = strrchr(info.dli_fname, '/');
    fname = fname ? fname + 1 : info.dli_fname;
    if (strcmp(fname, "YTLite.dylib") != 0) return;

    g_ytlHeader = mh;
    g_ytlSlide = slide;

    // Defer 1 second so YTLite's constructor completes first
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        registerAllHooks(g_ytlHeader, g_ytlSlide);
    });
}

    // Defer 1 second so YTLite's constructor completes first
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        registerAllHooks();
    });
}

// ============================================================
// Constructor
// ============================================================
__attribute__((constructor))
static void patcher_init(void) {
    _dyld_register_func_for_add_image(dyld_image_added);
}
