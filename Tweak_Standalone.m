/*
 * YTLitePatcher v5 — Safe baseline
 *
 * REMOVED all dangerous operations that caused crashes:
 * - NO Mach-O symbol table parsing (crashed on bad addresses)
 * - NO memory writes to C symbols (SIGBUS on __TEXT pages)
 * - NO static binary patching (corrupted dylib code section)
 * - FIXED dylib name matching ("YTLite.dylib" not just "YTLite")
 *
 * This version does ONLY safe ObjC runtime swizzling.
 * It hooks DVNPatreonContext auth methods, DVNCell lock state,
 * WelcomeVC, and patreonSection.
 *
 * Purpose: establish a non-crashing baseline to determine
 * if ObjC hooks alone can bypass the paywall.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

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
// Hook registration — called after YTLite init completes
// ============================================================
static BOOL g_hooked = NO;

static void registerAllHooks(void) {
    if (g_hooked) return;
    g_hooked = YES;

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
}

// ============================================================
// dyld callback — waits for YTLite.dylib specifically
// ============================================================
static void dyld_image_added(const struct mach_header *mh, intptr_t slide) {
    if (g_hooked) return;

    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;

    // Match YTLite.dylib EXACTLY — not "YTLitePatcher.dylib"
    const char *fname = strrchr(info.dli_fname, '/');
    fname = fname ? fname + 1 : info.dli_fname;
    if (strcmp(fname, "YTLite.dylib") != 0) return;

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
