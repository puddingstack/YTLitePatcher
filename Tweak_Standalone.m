/*
 * YTLitePatcher v7 — Direct Feature Implementation
 *
 * NEW APPROACH: Instead of trying to bypass _dvnCheck (which is
 * obfuscated and can't be hooked on non-jailbroken iOS), we
 * RE-IMPLEMENT the features ourselves by hooking the same YouTube
 * classes that YTLite hooks.
 *
 * Our hooks apply AFTER YTLite's (1-second delay via dyld callback),
 * so they OVERRIDE YTLite's gated implementations with ungated ones.
 *
 * Based on the open-source YTLite.x code — we implement the same
 * hooks but without any patron check.
 *
 * Features implemented:
 *   - Ad removal (isMonetized, spamSignals, decorateContext, etc.)
 *   - Background playback
 *   - Premium popup removal
 *   - Settings UI cleanup (patreon section, lock icons)
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

// ============================================================
// Helpers
// ============================================================
static IMP hookMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) m = class_getClassMethod(cls, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return orig;
}

static IMP hookClassMethod(Class cls, SEL sel, IMP newImp) {
    // Class methods are on the metaclass
    Class meta = object_getClass(cls);
    Method m = class_getInstanceMethod(meta, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return orig;
}

// ============================================================
// Stored original IMPs (for hooks that need %orig)
// ============================================================
static IMP orig_loadWithModel = NULL;

// ============================================================
// Ad blocking hooks
// ============================================================

// YTIPlayerResponse -isMonetized → always NO
static BOOL hook_isMonetized(id self, SEL _cmd) {
    return NO;
}

// YTDataUtils +spamSignalsDictionary → nil
static id hook_spamSignals(id self, SEL _cmd) {
    return nil;
}

// YTAdsInnerTubeContextDecorator -decorateContext: → no-op
static void hook_decorateContext(id self, SEL _cmd, id context) {
    // Skip ad context decoration entirely
}

// YTSectionListViewController -loadWithModel: → remove promoted/sponsored content
static void hook_loadWithModel(id self, SEL _cmd, id model) {
    @try {
        SEL contentsArraySel = NSSelectorFromString(@"contentsArray");
        if (model && [model respondsToSelector:contentsArraySel]) {
            NSMutableArray *contentsArray = ((id(*)(id, SEL))objc_msgSend)(model, contentsArraySel);
            if ([contentsArray isKindOfClass:[NSMutableArray class]] && contentsArray.count > 0) {
                NSMutableIndexSet *removeIndexes = [NSMutableIndexSet indexSet];
                [contentsArray enumerateObjectsUsingBlock:^(id renderers, NSUInteger idx, BOOL *stop) {
                    // Check for promoted video renderers
                    SEL itemSec = NSSelectorFromString(@"itemSectionRenderer");
                    if (![renderers respondsToSelector:itemSec]) return;
                    id sectionRenderer = ((id(*)(id, SEL))objc_msgSend)(renderers, itemSec);
                    if (!sectionRenderer) return;
                    
                    SEL contentsSel = NSSelectorFromString(@"contentsArray");
                    if (![sectionRenderer respondsToSelector:contentsSel]) return;
                    NSArray *contents = ((id(*)(id, SEL))objc_msgSend)(sectionRenderer, contentsSel);
                    if (!contents || contents.count == 0) return;
                    id firstObject = [contents firstObject];
                    if (!firstObject) return;
                    
                    // Check all known promoted renderer types
                    NSArray *promoSelectors = @[
                        @"hasPromotedVideoRenderer",
                        @"hasCompactPromotedVideoRenderer",
                        @"hasPromotedVideoInlineMutedRenderer",
                        @"hasAdSlotRenderer",
                        @"hasStatementBannerRenderer",
                        @"hasBrandVideoShelfRenderer",
                        @"hasBrandVideoSingletonRenderer",
                    ];
                    
                    for (NSString *selName in promoSelectors) {
                        SEL sel = NSSelectorFromString(selName);
                        if ([firstObject respondsToSelector:sel] &&
                            ((BOOL(*)(id,SEL))objc_msgSend)(firstObject, sel)) {
                            [removeIndexes addIndex:idx];
                            return;
                        }
                    }
                    
                    // Also check for ad logging data on section renderer
                    SEL hasAdLog = NSSelectorFromString(@"hasAdLoggingData");
                    if ([sectionRenderer respondsToSelector:hasAdLog] &&
                        ((BOOL(*)(id,SEL))objc_msgSend)(sectionRenderer, hasAdLog)) {
                        [removeIndexes addIndex:idx];
                        return;
                    }
                }];
                if (removeIndexes.count > 0) {
                    [contentsArray removeObjectsAtIndexes:removeIndexes];
                }
            }
        }
    } @catch (NSException *e) {
        // Don't crash the feed
    }
    
    if (orig_loadWithModel) {
        ((void(*)(id, SEL, id))orig_loadWithModel)(self, _cmd, model);
    }
}

// ============================================================
// Background playback hooks
// ============================================================

// YTIPlayabilityStatus -isPlayableInBackground → YES
static BOOL hook_isPlayableInBackground(id self, SEL _cmd) {
    return YES;
}

// MLVideo -playableInBackground → YES
static BOOL hook_playableInBackground(id self, SEL _cmd) {
    return YES;
}

// ============================================================
// Premium popup removal hooks
// ============================================================

// Various handlers -addEventHandlers → no-op
static void hook_addEventHandlers(id self, SEL _cmd) {
    // Block premium/promo event handlers
}

// YTPromoThrottleController -canShowThrottledPromo* → NO
static BOOL hook_canShowThrottledPromo(id self, SEL _cmd) {
    return NO;
}

static BOOL hook_canShowThrottledPromoWithArg(id self, SEL _cmd, id arg) {
    return NO;
}

// YTIShowFullscreenInterstitialCommand -shouldThrottleInterstitial → YES
static BOOL hook_shouldThrottleInterstitial(id self, SEL _cmd) {
    return YES;
}

// ============================================================
// Settings UI hooks (keep from v6)
// ============================================================
static IMP orig_DVNCell_setLocked;
static void hook_DVNCell_setLocked(id self, SEL _cmd, BOOL locked) {
    if (orig_DVNCell_setLocked)
        ((void(*)(id, SEL, BOOL))orig_DVNCell_setLocked)(self, _cmd, NO);
}

static IMP orig_DVNTVC_setLocked;
static void hook_DVNTVC_setLocked(id self, SEL _cmd, BOOL locked) {
    if (orig_DVNTVC_setLocked)
        ((void(*)(id, SEL, BOOL))orig_DVNTVC_setLocked)(self, _cmd, NO);
}

static IMP orig_WelcomeVC_viewDidLoad;
static void hook_WelcomeVC_viewDidLoad(id self, SEL _cmd) {
    if (orig_WelcomeVC_viewDidLoad)
        ((void(*)(id, SEL))orig_WelcomeVC_viewDidLoad)(self, _cmd);
    dispatch_async(dispatch_get_main_queue(), ^{
        [(UIViewController *)self dismissViewControllerAnimated:NO completion:nil];
    });
}

static IMP orig_patreonSection;
static id hook_patreonSection(id self, SEL _cmd) {
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
// Registration
// ============================================================
static BOOL g_hooked = NO;

static void registerAllHooks(void) {
    if (g_hooked) return;
    g_hooked = YES;

    // ══════════════════════════════════════════════════════
    // AD BLOCKING — hook YouTube classes directly
    // These override YTLite's gated implementations
    // ══════════════════════════════════════════════════════

    // YTIPlayerResponse -isMonetized
    Class cls = objc_getClass("YTIPlayerResponse");
    if (cls) hookMethod(cls, @selector(isMonetized), (IMP)hook_isMonetized);

    // YTDataUtils +spamSignalsDictionary / +spamSignalsDictionaryWithoutIDFA
    cls = objc_getClass("YTDataUtils");
    if (cls) {
        hookClassMethod(cls, @selector(spamSignalsDictionary), (IMP)hook_spamSignals);
        hookClassMethod(cls, NSSelectorFromString(@"spamSignalsDictionaryWithoutIDFA"), (IMP)hook_spamSignals);
    }

    // YTAdsInnerTubeContextDecorator -decorateContext:
    cls = objc_getClass("YTAdsInnerTubeContextDecorator");
    if (cls) hookMethod(cls, @selector(decorateContext:), (IMP)hook_decorateContext);

    // YTAccountScopedAdsInnerTubeContextDecorator -decorateContext:
    cls = objc_getClass("YTAccountScopedAdsInnerTubeContextDecorator");
    if (cls) hookMethod(cls, @selector(decorateContext:), (IMP)hook_decorateContext);

    // YTSectionListViewController -loadWithModel:
    cls = objc_getClass("YTSectionListViewController");
    if (cls) orig_loadWithModel = hookMethod(cls, @selector(loadWithModel:), (IMP)hook_loadWithModel);

    // ══════════════════════════════════════════════════════
    // BACKGROUND PLAYBACK
    // ══════════════════════════════════════════════════════

    cls = objc_getClass("YTIPlayabilityStatus");
    if (cls) hookMethod(cls, @selector(isPlayableInBackground), (IMP)hook_isPlayableInBackground);

    cls = objc_getClass("MLVideo");
    if (cls) hookMethod(cls, @selector(playableInBackground), (IMP)hook_playableInBackground);

    // ══════════════════════════════════════════════════════
    // PREMIUM POPUP REMOVAL
    // ══════════════════════════════════════════════════════

    cls = objc_getClass("YTCommerceEventGroupHandler");
    if (cls) hookMethod(cls, @selector(addEventHandlers), (IMP)hook_addEventHandlers);

    cls = objc_getClass("YTInterstitialPromoEventGroupHandler");
    if (cls) hookMethod(cls, @selector(addEventHandlers), (IMP)hook_addEventHandlers);

    cls = objc_getClass("YTPromosheetEventGroupHandler");
    if (cls) hookMethod(cls, @selector(addEventHandlers), (IMP)hook_addEventHandlers);

    cls = objc_getClass("YTPromoThrottleController");
    if (cls) {
        hookMethod(cls, NSSelectorFromString(@"canShowThrottledPromo"), (IMP)hook_canShowThrottledPromo);
        hookMethod(cls, NSSelectorFromString(@"canShowThrottledPromoWithFrequencyCap:"), (IMP)hook_canShowThrottledPromoWithArg);
        hookMethod(cls, NSSelectorFromString(@"canShowThrottledPromoWithFrequencyCaps:"), (IMP)hook_canShowThrottledPromoWithArg);
    }

    cls = objc_getClass("YTIShowFullscreenInterstitialCommand");
    if (cls) hookMethod(cls, NSSelectorFromString(@"shouldThrottleInterstitial"), (IMP)hook_shouldThrottleInterstitial);

    // YTSettingsSectionItemManager -updatePremiumEarlyAccessSectionWithEntry: → no-op
    cls = objc_getClass("YTSettingsSectionItemManager");
    if (cls) {
        SEL sel = NSSelectorFromString(@"updatePremiumEarlyAccessSectionWithEntry:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) method_setImplementation(m, imp_implementationWithBlock(^(id s, id e){}));
    }

    // ══════════════════════════════════════════════════════
    // SETTINGS UI — unlock cells, dismiss welcome, empty patreon
    // ══════════════════════════════════════════════════════

    cls = objc_getClass("DVNCell");
    if (cls) {
        orig_DVNCell_setLocked = hookMethod(cls, @selector(setLocked:), (IMP)hook_DVNCell_setLocked);
        Method m = class_getInstanceMethod(cls, @selector(isLocked));
        if (m) method_setImplementation(m, imp_implementationWithBlock(^BOOL(id s){ return NO; }));
        m = class_getInstanceMethod(cls, @selector(locked));
        if (m) method_setImplementation(m, imp_implementationWithBlock(^BOOL(id s){ return NO; }));
    }

    cls = objc_getClass("DVNTableViewController");
    if (cls) {
        Method m = class_getInstanceMethod(cls, @selector(setLocked:));
        if (m) orig_DVNTVC_setLocked = hookMethod(cls, @selector(setLocked:), (IMP)hook_DVNTVC_setLocked);
        m = class_getInstanceMethod(cls, @selector(locked));
        if (m) method_setImplementation(m, imp_implementationWithBlock(^BOOL(id s){ return NO; }));
    }

    cls = objc_getClass("DVNPatreonContext");
    if (cls) {
        SEL authSels[] = {
            @selector(isAuthorized), @selector(isAuthenticated),
            @selector(isLoggedIn), @selector(isActive),
            NSSelectorFromString(@"isPatron"),
            NSSelectorFromString(@"hasActiveSubscription"),
        };
        for (int i = 0; i < sizeof(authSels)/sizeof(authSels[0]); i++) {
            if (!authSels[i]) continue;
            Method m = class_getInstanceMethod(cls, authSels[i]);
            if (m) method_setImplementation(m, imp_implementationWithBlock(^BOOL(id s){ return YES; }));
        }
    }

    cls = objc_getClass("WelcomeVC");
    if (cls) orig_WelcomeVC_viewDidLoad = hookMethod(cls, @selector(viewDidLoad), (IMP)hook_WelcomeVC_viewDidLoad);

    cls = objc_getClass("YTPSettingsBuilder");
    if (cls) {
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(@"patreonSection"));
        if (m) {
            orig_patreonSection = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_patreonSection);
        }
    }
}

// ============================================================
// dyld callback — waits for YTLite.dylib, then defers hooks
// ============================================================
static void dyld_image_added(const struct mach_header *mh, intptr_t slide) {
    if (g_hooked) return;

    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;

    const char *fname = strrchr(info.dli_fname, '/');
    fname = fname ? fname + 1 : info.dli_fname;
    if (strcmp(fname, "YTLite.dylib") != 0) return;

    // Defer 2 seconds — YTLite needs to finish its constructor
    // AND register all its hooks before we override them
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
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
