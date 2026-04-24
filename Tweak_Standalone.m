/*
 * YTLitePatcher v4
 *
 * Two-pronged approach:
 *
 * STATIC (in CI): The workflow uses LIEF to zero out _dvnCheck/_dvnLocked
 *   in YTLite.dylib BEFORE injecting into the IPA. This is the primary
 *   bypass — it modifies the __DATA segment directly in the binary file.
 *
 * RUNTIME (this file): Deferred ObjC hooks that apply AFTER YTLite's
 *   constructor has finished running. Fixes the settings UI (lock icons,
 *   patreon section, welcome screen). Also periodically re-zeroes
 *   _dvnCheck/_dvnLocked in case YTLite resets them at runtime.
 *
 * KEY FIX from v3: hooks are deferred by 1 second via dispatch_after
 *   so YTLite's %ctor completes first. Previously, _dyld_register_func_
 *   for_add_image fired BEFORE constructors, causing hooks to either
 *   find NULL classes or corrupt YTLite's initialization.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

// ============================================================
// Mach-O private symbol finder
// ============================================================
static void *findPrivateSymbol(const struct mach_header *header, intptr_t slide, const char *symbolName) {
    if (!header || !symbolName) return NULL;

    const struct mach_header_64 *h64 = (const struct mach_header_64 *)header;
    struct load_command *cmd = (struct load_command *)((uintptr_t)h64 + sizeof(struct mach_header_64));

    struct symtab_command *symtabCmd = NULL;
    uintptr_t linkeditBase = 0;

    for (uint32_t i = 0; i < h64->ncmds; i++) {
        if (cmd->cmd == LC_SYMTAB) {
            symtabCmd = (struct symtab_command *)cmd;
        } else if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkeditBase = (uintptr_t)(seg->vmaddr - seg->fileoff + slide);
            }
        }
        cmd = (struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }

    if (!symtabCmd || !linkeditBase) return NULL;

    struct nlist_64 *symtab = (struct nlist_64 *)(linkeditBase + symtabCmd->symoff);
    const char *strtab = (const char *)(linkeditBase + symtabCmd->stroff);

    for (uint32_t i = 0; i < symtabCmd->nsyms; i++) {
        const char *name = &strtab[symtab[i].n_un.n_strx];
        if (strcmp(name, symbolName) == 0) {
            uint64_t addr = symtab[i].n_value;
            if (addr == 0) continue;
            return (void *)(addr + slide);
        }
    }
    return NULL;
}

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
// Replacement functions
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
    id section = orig_patreonSection ? ((id(*)(id, SEL))orig_patreonSection)(self, _cmd) : nil;
    if (section) {
        SEL setCells = NSSelectorFromString(@"setCells:");
        if ([section respondsToSelector:setCells])
            ((void(*)(id, SEL, id))objc_msgSend)(section, setCells, @[]);
    }
    return section;
}

// ============================================================
// Stored symbol addresses for periodic re-patching
// ============================================================
static void *g_dvnCheckAddr = NULL;
static void *g_dvnLockedAddr = NULL;

static void zeroDvnFlags(void) {
    if (g_dvnCheckAddr)  *((uint32_t *)g_dvnCheckAddr) = 0;
    if (g_dvnLockedAddr) *((uint32_t *)g_dvnLockedAddr) = 0;
}

// ============================================================
// Main hook registration — called AFTER YTLite initializes
// ============================================================
static BOOL g_hooked = NO;

static void registerAllHooks(const struct mach_header *mh, intptr_t slide) {
    if (g_hooked) return;
    g_hooked = YES;

    // -- Find and zero _dvnCheck/_dvnLocked (runtime backup for static patch) --
    g_dvnCheckAddr = findPrivateSymbol(mh, slide, "_dvnCheck");
    g_dvnLockedAddr = findPrivateSymbol(mh, slide, "_dvnLocked");
    zeroDvnFlags();

    // -- DVNCell --
    Class dvnCell = objc_getClass("DVNCell");
    if (dvnCell) {
        swizzleMethod(dvnCell, @selector(setLocked:),
                      (IMP)rep_DVNCell_setLocked, &orig_DVNCell_setLocked);
        forceReturnNO(dvnCell, @selector(isLocked));
        forceReturnNO(dvnCell, @selector(locked));
    }

    // -- DVNTableViewController --
    Class dvnTVC = objc_getClass("DVNTableViewController");
    if (dvnTVC) {
        Method m = class_getInstanceMethod(dvnTVC, @selector(setLocked:));
        if (m) swizzleMethod(dvnTVC, @selector(setLocked:),
                             (IMP)rep_DVNTVC_setLocked, &orig_DVNTVC_setLocked);
        forceReturnNO(dvnTVC, @selector(locked));
        forceReturnNO(dvnTVC, @selector(isLocked));
    }

    // -- DVNPatreonContext --
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

    // -- WelcomeVC --
    Class welcomeVC = objc_getClass("WelcomeVC");
    if (welcomeVC) {
        swizzleMethod(welcomeVC, @selector(viewDidLoad),
                      (IMP)rep_WelcomeVC_viewDidLoad, &orig_WelcomeVC_viewDidLoad);
    }

    // -- YTPSettingsBuilder --
    Class settingsBuilder = objc_getClass("YTPSettingsBuilder");
    if (settingsBuilder) {
        Method m = class_getInstanceMethod(settingsBuilder,
                       NSSelectorFromString(@"patreonSection"));
        if (m) {
            orig_patreonSection = method_getImplementation(m);
            method_setImplementation(m, (IMP)rep_patreonSection);
        }
    }

    // -- Periodic re-zero of _dvnCheck/_dvnLocked --
    // YTLite may reset these during runtime (e.g. on settings change)
    if (g_dvnCheckAddr || g_dvnLockedAddr) {
        // Re-zero every 3 seconds for 60 seconds
        for (int i = 1; i <= 20; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * 3 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ zeroDvnFlags(); });
        }
    }
}

// ============================================================
// dyld callback — waits for YTLite.dylib, then DEFERS hooks
// ============================================================
static const struct mach_header *g_ytliteHeader = NULL;
static intptr_t g_ytliteSlide = 0;

static void dyld_image_added(const struct mach_header *mh, intptr_t slide) {
    if (g_hooked) return;

    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    if (strstr(info.dli_fname, "YTLite") == NULL) return;

    // Store for deferred use
    g_ytliteHeader = mh;
    g_ytliteSlide = slide;

    // DEFER: wait 1 second for YTLite's %ctor to complete
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        registerAllHooks(g_ytliteHeader, g_ytliteSlide);
    });
}

// ============================================================
// Constructor
// ============================================================
__attribute__((constructor))
static void patcher_init(void) {
    _dyld_register_func_for_add_image(dyld_image_added);
}
/*
 * YTLitePatcher v3
 *
 * KEY FIXES from v2:
 * 1. DEFERRED INIT — waits for YTLite.dylib to load via _dyld_register_func_for_add_image
 *    before hooking DVN classes. Load order was causing all hooks to silently fail.
 * 2. MACH-O SYMBOL TABLE PARSING — finds private symbols _dvnCheck/_dvnLocked
 *    by reading LC_SYMTAB at runtime (dlsym can't find private symbols).
 *    These are BOOL variables in __DATA (writable), not functions in __TEXT.
 * 3. REMOVED cellExistsInModel hook — it was a lookup validator, not a gate.
 *    Forcing YES caused crashes.
 * 4. REMOVED isCairo hooks — cairo is a graphics rendering flag, not auth.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

// ============================================================
// Mach-O private symbol finder
// Parses LC_SYMTAB to find symbols that dlsym() can't see.
// Returns the runtime address of a private symbol.
// ============================================================
static void *findPrivateSymbol(const struct mach_header *header, intptr_t slide, const char *symbolName) {
    if (!header || !symbolName) return NULL;

    const struct mach_header_64 *h64 = (const struct mach_header_64 *)header;
    struct load_command *cmd = (struct load_command *)((uintptr_t)h64 + sizeof(struct mach_header_64));

    struct symtab_command *symtabCmd = NULL;
    uintptr_t linkeditBase = 0;

    for (uint32_t i = 0; i < h64->ncmds; i++) {
        if (cmd->cmd == LC_SYMTAB) {
            symtabCmd = (struct symtab_command *)cmd;
        } else if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkeditBase = (uintptr_t)(seg->vmaddr - seg->fileoff + slide);
            }
        }
        cmd = (struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }

    if (!symtabCmd || !linkeditBase) return NULL;

    struct nlist_64 *symtab = (struct nlist_64 *)(linkeditBase + symtabCmd->symoff);
    const char *strtab = (const char *)(linkeditBase + symtabCmd->stroff);

    for (uint32_t i = 0; i < symtabCmd->nsyms; i++) {
        const char *name = &strtab[symtab[i].n_un.n_strx];
        if (strcmp(name, symbolName) == 0) {
            uint64_t addr = symtab[i].n_value;
            if (addr == 0) continue;
            return (void *)(addr + slide);
        }
    }
    return NULL;
}

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
// Replacement implementations
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
    id section = orig_patreonSection ? ((id(*)(id, SEL))orig_patreonSection)(self, _cmd) : nil;
    if (section) {
        SEL setCells = NSSelectorFromString(@"setCells:");
        if ([section respondsToSelector:setCells])
            ((void(*)(id, SEL, id))objc_msgSend)(section, setCells, @[]);
    }
    return section;
}

// ============================================================
// Flag: ensure we only register hooks once
// ============================================================
static BOOL g_hooked = NO;

static void registerAllHooks(const struct mach_header *ytliteHeader, intptr_t slide) {

    // ==========================================================
    // LEVEL 1: Find and patch _dvnCheck / _dvnLocked (BOOL vars in __DATA)
    // These are private symbols — dlsym can't find them.
    // They're writable because they're in __DATA, not __TEXT.
    // ==========================================================
    void *dvnCheckAddr = findPrivateSymbol(ytliteHeader, slide, "_dvnCheck");
    void *dvnLockedAddr = findPrivateSymbol(ytliteHeader, slide, "_dvnLocked");

    if (dvnCheckAddr) {
        *((BOOL *)dvnCheckAddr) = NO;  // unlocked
    }
    if (dvnLockedAddr) {
        *((BOOL *)dvnLockedAddr) = NO;  // unlocked
    }

    // ==========================================================
    // LEVEL 2: ObjC hooks for settings UI
    // ==========================================================

    // --- DVNCell ---
    Class dvnCell = objc_getClass("DVNCell");
    if (dvnCell) {
        swizzleMethod(dvnCell, @selector(setLocked:),
                      (IMP)rep_DVNCell_setLocked, &orig_DVNCell_setLocked);
        forceReturnNO(dvnCell, @selector(isLocked));
        forceReturnNO(dvnCell, @selector(locked));
    }

    // --- DVNTableViewController ---
    Class dvnTVC = objc_getClass("DVNTableViewController");
    if (dvnTVC) {
        Method m = class_getInstanceMethod(dvnTVC, @selector(setLocked:));
        if (m) swizzleMethod(dvnTVC, @selector(setLocked:),
                             (IMP)rep_DVNTVC_setLocked, &orig_DVNTVC_setLocked);
        forceReturnNO(dvnTVC, @selector(locked));
        forceReturnNO(dvnTVC, @selector(isLocked));
    }

    // --- DVNPatreonContext ---
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

    // --- WelcomeVC ---
    Class welcomeVC = objc_getClass("WelcomeVC");
    if (welcomeVC) {
        swizzleMethod(welcomeVC, @selector(viewDidLoad),
                      (IMP)rep_WelcomeVC_viewDidLoad, &orig_WelcomeVC_viewDidLoad);
    }

    // --- YTPSettingsBuilder ---
    Class settingsBuilder = objc_getClass("YTPSettingsBuilder");
    if (settingsBuilder) {
        Method m = class_getInstanceMethod(settingsBuilder,
                       NSSelectorFromString(@"patreonSection"));
        if (m) {
            orig_patreonSection = method_getImplementation(m);
            method_setImplementation(m, (IMP)rep_patreonSection);
        }
    }

    // ==========================================================
    // LEVEL 3: Periodic re-patch of _dvnCheck/_dvnLocked
    // In case YTLite resets these variables after init
    // ==========================================================
    if (dvnCheckAddr || dvnLockedAddr) {
        static void *s_dvnCheckAddr;
        static void *s_dvnLockedAddr;
        s_dvnCheckAddr = dvnCheckAddr;
        s_dvnLockedAddr = dvnLockedAddr;

        // Re-patch every 2 seconds for the first 30 seconds
        for (int i = 1; i <= 15; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * 2 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                if (s_dvnCheckAddr)  *((BOOL *)s_dvnCheckAddr) = NO;
                if (s_dvnLockedAddr) *((BOOL *)s_dvnLockedAddr) = NO;
            });
        }
    }
}

// ============================================================
// dyld callback — triggered when each image loads
// We wait for YTLite.dylib, then register all hooks
// ============================================================
static void dyld_image_added(const struct mach_header *mh, intptr_t slide) {
    if (g_hooked) return;

    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;

    // Check if this is YTLite.dylib loading
    if (strstr(info.dli_fname, "YTLite") == NULL) return;

    g_hooked = YES;
    registerAllHooks(mh, slide);
}

// ============================================================
// Constructor — registers dyld callback, does NOT hook immediately
// ============================================================
__attribute__((constructor))
static void patcher_init(void) {
    _dyld_register_func_for_add_image(dyld_image_added);
}
