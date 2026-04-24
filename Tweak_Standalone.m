/*
 * YTLitePatcher v8 — Hook BEFORE YTLite
 *
 * KEY INSIGHT: We hook YouTube classes in our constructor, BEFORE
 * YTLite.dylib loads. When YTLite's MSHookMessageEx runs later, it
 * saves OUR implementation as "original". When YTLite's _dvnCheck
 * gate fails and it calls %orig, it calls OUR hook — which blocks ads.
 *
 * Changes from v7:
 * - Hooks installed in constructor (IMMEDIATELY, not deferred)
 * - Removed elementData hook (caused blank sections)
 * - DVN/settings hooks still deferred (need YTLite classes to exist)
 * - No timing dependency for ad blocking
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
    Class meta = object_getClass(cls);
    Method m = class_getInstanceMethod(meta, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return orig;
}

// ============================================================
// Stored originals
// ============================================================
static IMP orig_loadWithModel = NULL;

// ============================================================
// Ad blocking — these hook YouTube classes BEFORE YTLite loads
// ============================================================

// YTIPlayerResponse -isMonetized → NO
static BOOL hook_isMonetized(id self, SEL _cmd) {
    return NO;
}

// YTDataUtils +spamSignalsDictionary → nil
static id hook_spamSignals(id self, SEL _cmd) {
    return nil;
}

// YTAdsInnerTubeContextDecorator -decorateContext: → skip
static void hook_decorateContext(id self, SEL _cmd, id ctx) {
    // Don't decorate with ad context
}

// YTSectionListViewController -loadWithModel: → filter promoted sections AND individual ad items
static void hook_loadWithModel(id self, SEL _cmd, id model) {
    @try {
        SEL contentsArraySel = NSSelectorFromString(@"contentsArray");
        if (model && [model respondsToSelector:contentsArraySel]) {
            NSMutableArray *contentsArray = ((id(*)(id, SEL))objc_msgSend)(model, contentsArraySel);
            if ([contentsArray isKindOfClass:[NSMutableArray class]] && contentsArray.count > 0) {
                NSMutableIndexSet *removeIndexes = [NSMutableIndexSet indexSet];

                // Selectors for ad detection
                NSArray *adChecks = @[
                    @"hasPromotedVideoRenderer",
                    @"hasCompactPromotedVideoRenderer",
                    @"hasPromotedVideoInlineMutedRenderer",
                ];
                SEL hasCompat = NSSelectorFromString(@"hasCompatibilityOptions");
                SEL compatOpts = NSSelectorFromString(@"compatibilityOptions");
                SEL hasAdLog = NSSelectorFromString(@"hasAdLoggingData");
                SEL elemRendererSel = NSSelectorFromString(@"elementRenderer");
                SEL elemDataSel = NSSelectorFromString(@"elementData");

                // Ad type strings for element description matching
                static NSArray *adDescTypes = nil;
                static dispatch_once_t onceToken;
                dispatch_once(&onceToken, ^{
                    adDescTypes = @[@"brand_promo", @"product_carousel", @"product_engagement_panel",
                                    @"product_item", @"text_search_ad", @"text_image_button_layout",
                                    @"carousel_headered_layout", @"carousel_footered_layout",
                                    @"square_image_layout", @"landscape_image_wide_button_layout",
                                    @"feed_ad_metadata"];
                });

                [contentsArray enumerateObjectsUsingBlock:^(id renderers, NSUInteger idx, BOOL *stop) {
                    @try {
                        SEL itemSec = NSSelectorFromString(@"itemSectionRenderer");
                        if (![renderers respondsToSelector:itemSec]) return;
                        id sectionRenderer = ((id(*)(id, SEL))objc_msgSend)(renderers, itemSec);
                        if (!sectionRenderer) return;

                        SEL contentsSel = NSSelectorFromString(@"contentsArray");
                        if (![sectionRenderer respondsToSelector:contentsSel]) return;
                        NSMutableArray *contents = ((id(*)(id, SEL))objc_msgSend)(sectionRenderer, contentsSel);
                        if (!contents || contents.count == 0) return;

                        // PASS 1: Check if entire section should be removed
                        // (any item has promoted video renderer)
                        for (id item in contents) {
                            for (NSString *check in adChecks) {
                                SEL sel = NSSelectorFromString(check);
                                if ([item respondsToSelector:sel] &&
                                    ((BOOL(*)(id, SEL))objc_msgSend)(item, sel)) {
                                    [removeIndexes addIndex:idx];
                                    return;
                                }
                            }
                        }

                        // PASS 2: Remove individual ad items from within the section
                        // This catches sponsored items that aren't "promoted videos"
                        if ([contents isKindOfClass:[NSMutableArray class]]) {
                            NSMutableIndexSet *itemRemoveIndexes = [NSMutableIndexSet indexSet];
                            [contents enumerateObjectsUsingBlock:^(id item, NSUInteger itemIdx, BOOL *itemStop) {
                                @try {
                                    // Check via elementRenderer accessor if available
                                    id elemRenderer = nil;
                                    if ([item respondsToSelector:elemRendererSel]) {
                                        elemRenderer = ((id(*)(id, SEL))objc_msgSend)(item, elemRendererSel);
                                    }

                                    // Check ad logging data on the element renderer
                                    id checkTarget = elemRenderer ?: item;
                                    if ([checkTarget respondsToSelector:hasCompat] &&
                                        ((BOOL(*)(id, SEL))objc_msgSend)(checkTarget, hasCompat)) {
                                        id opts = ((id(*)(id, SEL))objc_msgSend)(checkTarget, compatOpts);
                                        if (opts && [opts respondsToSelector:hasAdLog] &&
                                            ((BOOL(*)(id, SEL))objc_msgSend)(opts, hasAdLog)) {
                                            [itemRemoveIndexes addIndex:itemIdx];
                                            return;
                                        }
                                    }

                                    // Check element renderer description for ad types
                                    if (elemRenderer) {
                                        NSString *desc = [elemRenderer description];
                                        if (desc && [adDescTypes containsObject:desc]) {
                                            [itemRemoveIndexes addIndex:itemIdx];
                                            return;
                                        }
                                    }
                                } @catch (NSException *e) {}
                            }];
                            if (itemRemoveIndexes.count > 0) {
                                [contents removeObjectsAtIndexes:itemRemoveIndexes];
                            }
                        }
                    } @catch (NSException *e) {}
                }];
                if (removeIndexes.count > 0) {
                    [contentsArray removeObjectsAtIndexes:removeIndexes];
                }
            }
        }
    } @catch (NSException *e) {}

    if (orig_loadWithModel) {
        ((void(*)(id, SEL, id))orig_loadWithModel)(self, _cmd, model);
    }
}

// Empty ad slot arrays
static id hook_emptyArray(id self, SEL _cmd) {
    return @[];
}

// ============================================================
// Background playback
// ============================================================
static BOOL hook_isPlayableInBackground(id self, SEL _cmd) { return YES; }
static BOOL hook_playableInBackground(id self, SEL _cmd) { return YES; }

// ============================================================
// Premium popup removal
// ============================================================
static void hook_addEventHandlers(id self, SEL _cmd) {}
static BOOL hook_canShowThrottledPromo(id self, SEL _cmd) { return NO; }
static BOOL hook_canShowThrottledPromoWithArg(id self, SEL _cmd, id arg) { return NO; }
static BOOL hook_shouldThrottleInterstitial(id self, SEL _cmd) { return YES; }

// ============================================================
// Settings UI hooks (applied after YTLite loads)
// ============================================================
static IMP orig_DVNCell_setLocked;
static void hook_DVNCell_setLocked(id self, SEL _cmd, BOOL locked) {
    if (orig_DVNCell_setLocked)
        ((void(*)(id, SEL, BOOL))orig_DVNCell_setLocked)(self, _cmd, NO);
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
// Phase 1: Hook YouTube classes IMMEDIATELY (before YTLite loads)
// When YTLite later hooks these same methods, MSHookMessageEx
// saves OUR implementations as "original". YTLite's _dvnCheck
// gate fails → calls %orig → calls OUR hook → ads blocked.
// ============================================================
static void hookYouTubeClasses(void) {
    Class cls;

    // Ad blocking
    cls = objc_getClass("YTIPlayerResponse");
    if (cls) hookMethod(cls, @selector(isMonetized), (IMP)hook_isMonetized);

    cls = objc_getClass("YTDataUtils");
    if (cls) {
        hookClassMethod(cls, @selector(spamSignalsDictionary), (IMP)hook_spamSignals);
        hookClassMethod(cls, NSSelectorFromString(@"spamSignalsDictionaryWithoutIDFA"), (IMP)hook_spamSignals);
    }

    cls = objc_getClass("YTAdsInnerTubeContextDecorator");
    if (cls) hookMethod(cls, @selector(decorateContext:), (IMP)hook_decorateContext);

    cls = objc_getClass("YTAccountScopedAdsInnerTubeContextDecorator");
    if (cls) hookMethod(cls, @selector(decorateContext:), (IMP)hook_decorateContext);

    // Section list filtering (removes promoted sections from feed)
    cls = objc_getClass("YTSectionListViewController");
    if (cls) orig_loadWithModel = hookMethod(cls, @selector(loadWithModel:), (IMP)hook_loadWithModel);

    // Background playback
    cls = objc_getClass("YTIPlayabilityStatus");
    if (cls) hookMethod(cls, @selector(isPlayableInBackground), (IMP)hook_isPlayableInBackground);

    cls = objc_getClass("MLVideo");
    if (cls) hookMethod(cls, @selector(playableInBackground), (IMP)hook_playableInBackground);

    // Premium popup removal
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

    cls = objc_getClass("YTSettingsSectionItemManager");
    if (cls) {
        SEL sel = NSSelectorFromString(@"updatePremiumEarlyAccessSectionWithEntry:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) method_setImplementation(m, imp_implementationWithBlock(^(id s, id e){}));
    }

    // Empty ad slot arrays on player response
    cls = objc_getClass("YTIPlayerResponse");
    if (cls) {
        hookMethod(cls, NSSelectorFromString(@"adSlotsArray"), (IMP)hook_emptyArray);
        hookMethod(cls, NSSelectorFromString(@"playerAdsArray"), (IMP)hook_emptyArray);
    }
}

// ============================================================
// Phase 2: Hook DVN/YTLite classes AFTER YTLite loads
// These classes don't exist until YTLite.dylib is loaded.
// ============================================================
static BOOL g_dvnHooked = NO;

static void hookDVNClasses(void) {
    if (g_dvnHooked) return;
    g_dvnHooked = YES;

    Class cls;

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
        if (m) method_setImplementation(m, imp_implementationWithBlock(^(id s, BOOL v){}));
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
// dyld callback — for DVN classes only (need YTLite loaded)
// ============================================================
static void dyld_image_added(const struct mach_header *mh, intptr_t slide) {
    if (g_dvnHooked) return;

    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;

    const char *fname = strrchr(info.dli_fname, '/');
    fname = fname ? fname + 1 : info.dli_fname;
    if (strcmp(fname, "YTLite.dylib") != 0) return;

    // Defer slightly for YTLite constructor to create DVN classes
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        hookDVNClasses();
    });
}

// ============================================================
// Constructor — runs BEFORE YTLite loads
// ============================================================
__attribute__((constructor))
static void patcher_init(void) {
    // Phase 1: Hook YouTube classes immediately
    // YouTube.app is the host — its classes are already loaded
    hookYouTubeClasses();

    // Phase 2: Register callback for when YTLite.dylib loads
    _dyld_register_func_for_add_image(dyld_image_added);
}
