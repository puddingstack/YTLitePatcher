/*
 * YTLitePatcher v2
 *
 * Patches YTLite's Patreon paywall on non-jailbroken (sideloaded) iOS.
 *
 * Key findings from reverse engineering:
 * - _dvnCheck/_dvnLocked are PRIVATE symbols (dlsym can't find them)
 * - vm_protect on __TEXT pages FAILS on non-jailbroken iOS (code signing)
 * - The gate is multi-layered: C functions + ObjC properties + isCairo flag
 * - "cairo" is an obfuscated BOOL property (getter=isCairo) adjacent to
 *   "locked" — it's the actual "is patron active" flag
 *
 * Strategy (all ObjC runtime — works without jailbreak):
 * 1. Force isCairo=YES and locked=NO on all DVN classes
 * 2. Force locked=NO on DVNCell
 * 3. Force all DVNPatreonContext auth checks to return YES
 * 4. Suppress WelcomeVC login screen
 * 5. Empty the patreonSection cells
 * 6. Hook cellExistsInModel:target: to always return YES
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// Helpers
// ============================================================
static void swizzleMethod(Class cls, SEL original, IMP replacement, IMP *store) {
    Method method = class_getInstanceMethod(cls, original);
    if (method) {
        *store = method_getImplementation(method);
        method_setImplementation(method, replacement);
    }
}

static void forceMethodToReturnYES(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        method_setImplementation(m,
            imp_implementationWithBlock(^BOOL(id self) { return YES; }));
    }
}

static void forceMethodToReturnNO(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        method_setImplementation(m,
            imp_implementationWithBlock(^BOOL(id self) { return NO; }));
    }
}

// ============================================================
// Replacement functions
// ============================================================

// setLocked: → always store NO
static IMP orig_DVNCell_setLocked;
static void rep_DVNCell_setLocked(id self, SEL _cmd, BOOL locked) {
    if (orig_DVNCell_setLocked) {
        ((void(*)(id, SEL, BOOL))orig_DVNCell_setLocked)(self, _cmd, NO);
    }
}

// setCairo: → always store YES
static IMP orig_setCairo;
static void rep_setCairo(id self, SEL _cmd, BOOL cairo) {
    if (orig_setCairo) {
        ((void(*)(id, SEL, BOOL))orig_setCairo)(self, _cmd, YES);
    }
}

// WelcomeVC viewDidLoad → auto-dismiss
static IMP orig_WelcomeVC_viewDidLoad;
static void rep_WelcomeVC_viewDidLoad(id self, SEL _cmd) {
    if (orig_WelcomeVC_viewDidLoad) {
        ((void(*)(id, SEL))orig_WelcomeVC_viewDidLoad)(self, _cmd);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [(UIViewController *)self dismissViewControllerAnimated:NO completion:nil];
    });
}

// patreonSection → empty its cells (returning nil crashes)
static IMP orig_patreonSection;
static id rep_patreonSection(id self, SEL _cmd) {
    id section = nil;
    if (orig_patreonSection) {
        section = ((id(*)(id, SEL))orig_patreonSection)(self, _cmd);
    }
    if (section) {
        SEL setCells = NSSelectorFromString(@"setCells:");
        if ([section respondsToSelector:setCells]) {
            ((void(*)(id, SEL, id))objc_msgSend)(section, setCells, @[]);
        }
    }
    return section;
}

// ============================================================
// Constructor
// ============================================================
__attribute__((constructor))
static void patcher_init(void) {
    @autoreleasepool {

        // ==========================================================
        // 1. DVNCell — force all cells unlocked
        // ==========================================================
        Class dvnCell = objc_getClass("DVNCell");
        if (dvnCell) {
            swizzleMethod(dvnCell, @selector(setLocked:),
                          (IMP)rep_DVNCell_setLocked, &orig_DVNCell_setLocked);
            forceMethodToReturnNO(dvnCell, @selector(isLocked));
            forceMethodToReturnNO(dvnCell, @selector(locked));
        }

        // ==========================================================
        // 2. DVNPatreonContext — all auth checks → YES
        // ==========================================================
        Class patreonCtx = objc_getClass("DVNPatreonContext");
        if (patreonCtx) {
            SEL authSels[] = {
                @selector(isAuthorized),
                @selector(isAuthenticated),
                @selector(isLoggedIn),
                @selector(isActive),
                NSSelectorFromString(@"isPatron"),
                NSSelectorFromString(@"hasActiveSubscription"),
                NSSelectorFromString(@"isCairo"),
            };
            for (int i = 0; i < sizeof(authSels)/sizeof(authSels[0]); i++) {
                if (authSels[i]) forceMethodToReturnYES(patreonCtx, authSels[i]);
            }
        }

        // ==========================================================
        // 3. WelcomeVC — auto-dismiss
        // ==========================================================
        Class welcomeVC = objc_getClass("WelcomeVC");
        if (welcomeVC) {
            swizzleMethod(welcomeVC, @selector(viewDidLoad),
                          (IMP)rep_WelcomeVC_viewDidLoad, &orig_WelcomeVC_viewDidLoad);
        }

        // ==========================================================
        // 4. YTPSettingsBuilder — empty patreon section
        // ==========================================================
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
        // 5. DVNTableModel — cellExistsInModel:target: → always YES
        //    Key gating point controlling whether feature cells render
        // ==========================================================
        Class dvnModel = objc_getClass("DVNTableModel");
        if (dvnModel) {
            SEL cellExists = NSSelectorFromString(@"cellExistsInModel:target:");
            Method m = class_getInstanceMethod(dvnModel, cellExists);
            if (m) {
                method_setImplementation(m,
                    imp_implementationWithBlock(^BOOL(id s, id model, id target){
                        return YES;
                    }));
            }
        }

        // ==========================================================
        // 6. Shotgun: force isCairo=YES, locked=NO on ALL known classes
        //    "cairo" is the obfuscated "is patron active" boolean,
        //    found adjacent to "locked" in the binary's property metadata
        // ==========================================================
        SEL isCairoSel = NSSelectorFromString(@"isCairo");
        SEL setCairoSel = NSSelectorFromString(@"setCairo:");

        const char *classNames[] = {
            "DVNTableViewController", "DVNCell", "DVNTableModel",
            "DVNSection", "DVNSupportersVC", "DVNSheetPresenter",
            "YTPSettingsBuilder", "TabbarVC", "YTLHelper",
            "InitWorkaround", "Dvbug", "YTPPlayerHelper",
            "YTPDownloader", "SBManager",
            NULL
        };

        for (int i = 0; classNames[i] != NULL; i++) {
            Class cls = objc_getClass(classNames[i]);
            if (!cls) continue;

            // isCairo → YES (force patron active)
            forceMethodToReturnYES(cls, isCairoSel);

            // setCairo: → always store YES
            Method m = class_getInstanceMethod(cls, setCairoSel);
            if (m) {
                orig_setCairo = method_getImplementation(m);
                method_setImplementation(m, (IMP)rep_setCairo);
            }

            // locked/isLocked → NO
            forceMethodToReturnNO(cls, @selector(locked));
            forceMethodToReturnNO(cls, @selector(isLocked));

            // setLocked: → always NO (just call orig with NO)
            m = class_getInstanceMethod(cls, @selector(setLocked:));
            if (m) {
                method_setImplementation(m,
                    imp_implementationWithBlock(^(id s, BOOL v){
                        // Getter already returns NO, so just do nothing
                    }));
            }
        }
    }
}
