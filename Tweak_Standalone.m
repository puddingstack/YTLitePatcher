/*
 * YTLitePatcher — Minimal variant
 *
 * Alternative approach: Instead of hooking C functions,
 * this version focuses purely on ObjC runtime swizzling
 * which is more portable and doesn't require MSFindSymbol.
 *
 * Strategy:
 * 1. Swizzle DVNCell.setLocked: to always pass NO
 * 2. Swizzle any isAuthorized/isLoggedIn on DVNPatreonContext
 * 3. Block WelcomeVC from presenting
 * 4. Remove patreon section from settings
 *
 * This can be compiled as a standalone dylib and injected
 * into the YouTube IPA alongside YTLite using cyan/pyzule.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// ObjC runtime swizzle helper
// ============================================================
static void swizzleMethod(Class cls, SEL original, IMP replacement, IMP *store) {
    Method method = class_getInstanceMethod(cls, original);
    if (method) {
        *store = method_getImplementation(method);
        method_setImplementation(method, replacement);
    }
}

static void addOrReplaceMethod(Class cls, SEL sel, IMP imp, const char *types) {
    if (!class_addMethod(cls, sel, imp, types)) {
        Method m = class_getInstanceMethod(cls, sel);
        if (m) method_setImplementation(m, imp);
    }
}

// ============================================================
// Replacement implementations
// ============================================================

// DVNCell — setLocked: → always NO
static IMP orig_DVNCell_setLocked;
static void rep_DVNCell_setLocked(id self, SEL _cmd, BOOL locked) {
    ((void(*)(id, SEL, BOOL))orig_DVNCell_setLocked)(self, _cmd, NO);
}

// DVNCell — locked/isLocked → always NO
static BOOL rep_returnNO(id self, SEL _cmd) {
    return NO;
}

// DVNPatreonContext — isAuthorized/isLoggedIn → always YES
static BOOL rep_returnYES(id self, SEL _cmd) {
    return YES;
}

// WelcomeVC — viewDidLoad → dismiss immediately
static IMP orig_WelcomeVC_viewDidLoad;
static void rep_WelcomeVC_viewDidLoad(id self, SEL _cmd) {
    ((void(*)(id, SEL))orig_WelcomeVC_viewDidLoad)(self, _cmd);
    // Dismiss the welcome/login screen on next run loop
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = (UIViewController *)self;
        [vc dismissViewControllerAnimated:NO completion:nil];
    });
}

// YTPSettingsBuilder — patreonSection → nil
static id rep_returnNil(id self, SEL _cmd) {
    return nil;
}

// patreonButtonCellWithType:model: → nil
static id rep_returnNil2(id self, SEL _cmd, NSInteger type, id model) {
    return nil;
}

// DVNTableViewController — setLocked: → always NO
static IMP orig_DVNTVC_setLocked;
static void rep_DVNTVC_setLocked(id self, SEL _cmd, BOOL locked) {
    ((void(*)(id, SEL, BOOL))orig_DVNTVC_setLocked)(self, _cmd, NO);
}

// ============================================================
// Constructor — runs when dylib is loaded
// ============================================================
__attribute__((constructor))
static void patcher_init(void) {
    @autoreleasepool {
        // --- DVNCell ---
        Class dvnCell = objc_getClass("DVNCell");
        if (dvnCell) {
            swizzleMethod(dvnCell, @selector(setLocked:),
                          (IMP)rep_DVNCell_setLocked, &orig_DVNCell_setLocked);

            addOrReplaceMethod(dvnCell, @selector(isLocked),
                               (IMP)rep_returnNO, "B@:");
            addOrReplaceMethod(dvnCell, @selector(locked),
                               (IMP)rep_returnNO, "B@:");
        }

        // --- DVNPatreonContext ---
        Class patreonCtx = objc_getClass("DVNPatreonContext");
        if (patreonCtx) {
            // Try all common auth-check selector names
            SEL authSels[] = {
                @selector(isAuthorized),
                @selector(isAuthenticated),
                @selector(isLoggedIn),
                @selector(isActive),
                NSSelectorFromString(@"isPatron"),
                NSSelectorFromString(@"hasActiveSubscription"),
            };
            for (int i = 0; i < sizeof(authSels)/sizeof(authSels[0]); i++) {
                if (authSels[i] && class_getInstanceMethod(patreonCtx, authSels[i])) {
                    addOrReplaceMethod(patreonCtx, authSels[i],
                                       (IMP)rep_returnYES, "B@:");
                }
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
            if (m) method_setImplementation(m, (IMP)rep_returnNil);

            m = class_getInstanceMethod(settingsBuilder,
                    NSSelectorFromString(@"patreonButtonCellWithType:model:"));
            if (m) method_setImplementation(m, (IMP)rep_returnNil2);
        }

        // --- DVNTableViewController ---
        Class dvnTVC = objc_getClass("DVNTableViewController");
        if (dvnTVC) {
            Method m = class_getInstanceMethod(dvnTVC, @selector(setLocked:));
            if (m) {
                swizzleMethod(dvnTVC, @selector(setLocked:),
                              (IMP)rep_DVNTVC_setLocked, &orig_DVNTVC_setLocked);
            }
        }

        // --- Also try hooking the C functions via dlsym ---
        // _dvnCheck and _dvnLocked are exported symbols
        void *handle = dlopen(NULL, RTLD_NOW);
        if (handle) {
            // Try to find and override _dvnCheck
            BOOL (*dvnCheckPtr)(void) = (BOOL(*)(void))dlsym(handle, "_dvnCheck");
            if (dvnCheckPtr) {
                // Can't easily MSHookFunction without Substrate,
                // but we've already covered the ObjC side above.
                // If using Substrate, MSHookFunction would go here.
            }
            dlclose(handle);
        }
    }
}
