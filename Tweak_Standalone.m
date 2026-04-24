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

// Keywords that indicate sponsored / ad content in a label string
static BOOL isSponsorKeyword(NSString *s) {
    if (!s || ![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    NSString *lower = [s lowercaseString];
    return ([lower containsString:@"sponsored"] ||
            [lower containsString:@"promoted"] ||
            [lower isEqualToString:@"ad"] ||
            [lower isEqualToString:@"ads"] ||
            [lower hasPrefix:@"ad "] ||
            [lower hasSuffix:@" ad"]);
}

// Extract a string out of a renderer-like object by trying common selectors
static NSString *extractLabelText(id obj) {
    if (!obj) return nil;
    static NSArray *textSels = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        textSels = @[@"label", @"text", @"accessibilityLabel",
                     @"simpleText", @"content", @"styleRunExtensionLabel"];
    });
    for (NSString *sn in textSels) {
        SEL s = NSSelectorFromString(sn);
        if ([obj respondsToSelector:s]) {
            id v = ((id(*)(id, SEL))objc_msgSend)(obj, s);
            if ([v isKindOfClass:[NSString class]]) return v;
            // YTIFormattedString-like: has -string
            SEL strSel = @selector(string);
            if (v && [v respondsToSelector:strSel]) {
                id s2 = ((id(*)(id, SEL))objc_msgSend)(v, strSel);
                if ([s2 isKindOfClass:[NSString class]]) return s2;
            }
        }
    }
    return nil;
}

// Walk an item's badges looking for a "Sponsored"/"Ad"/"Promoted" label
static BOOL hasSponsoredBadge(id item) {
    if (!item) return NO;
    static NSArray *badgeSels = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        badgeSels = @[@"badgesArray", @"badges", @"thumbnailOverlaysArray",
                      @"metadataBadgesArray", @"ownerBadgesArray"];
    });
    for (NSString *sn in badgeSels) {
        SEL s = NSSelectorFromString(sn);
        if (![item respondsToSelector:s]) continue;
        id arr = ((id(*)(id, SEL))objc_msgSend)(item, s);
        if (![arr isKindOfClass:[NSArray class]]) continue;
        for (id b in (NSArray *)arr) {
            // badge wrapper -> metadataBadgeRenderer -> label
            static NSArray *inner = nil;
            static dispatch_once_t o2;
            dispatch_once(&o2, ^{
                inner = @[@"metadataBadgeRenderer", @"thumbnailBadgeViewModel",
                          @"textBadgeRenderer", @"upgradedMetadataBadgeRenderer"];
            });
            // Check wrapper directly
            NSString *t = extractLabelText(b);
            if (isSponsorKeyword(t)) return YES;
            for (NSString *in in inner) {
                SEL is = NSSelectorFromString(in);
                if ([b respondsToSelector:is]) {
                    id r = ((id(*)(id, SEL))objc_msgSend)(b, is);
                    NSString *lt = extractLabelText(r);
                    if (isSponsorKeyword(lt)) return YES;
                }
            }
        }
    }
    return NO;
}

// Helper: recursively check an object and its children for ad indicators
static BOOL isAdRelated(id obj) {
    if (!obj) return NO;

    // Check promoted video renderer types
    static NSArray *adSelNames = nil;
    static dispatch_once_t onceToken1;
    dispatch_once(&onceToken1, ^{
        adSelNames = @[
            @"hasPromotedVideoRenderer",
            @"hasCompactPromotedVideoRenderer",
            @"hasPromotedVideoInlineMutedRenderer",
            @"hasAdLoggingData",
        ];
    });

    for (NSString *selName in adSelNames) {
        SEL sel = NSSelectorFromString(selName);
        if ([obj respondsToSelector:sel] &&
            ((BOOL(*)(id, SEL))objc_msgSend)(obj, sel)) {
            return YES;
        }
    }

    // Check compatibilityOptions → hasAdLoggingData
    SEL hasCompat = NSSelectorFromString(@"hasCompatibilityOptions");
    SEL compatOpts = NSSelectorFromString(@"compatibilityOptions");
    SEL hasAdLog = NSSelectorFromString(@"hasAdLoggingData");
    if ([obj respondsToSelector:hasCompat] &&
        ((BOOL(*)(id, SEL))objc_msgSend)(obj, hasCompat)) {
        id opts = ((id(*)(id, SEL))objc_msgSend)(obj, compatOpts);
        if (opts && [opts respondsToSelector:hasAdLog] &&
            ((BOOL(*)(id, SEL))objc_msgSend)(opts, hasAdLog)) {
            return YES;
        }
    }

    // Check elementRenderer if available
    SEL elemSel = NSSelectorFromString(@"elementRenderer");
    if ([obj respondsToSelector:elemSel]) {
        id elem = ((id(*)(id, SEL))objc_msgSend)(obj, elemSel);
        if (elem && isAdRelated(elem)) return YES;
    }

    // Walk to the actual video renderer inside common wrappers and check badges
    static NSArray *innerVideoSels = nil;
    static dispatch_once_t onceV;
    dispatch_once(&onceV, ^{
        innerVideoSels = @[@"videoRenderer", @"videoWithContextRenderer",
                           @"compactVideoRenderer", @"gridVideoRenderer",
                           @"richItemRenderer", @"content"];
    });
    for (NSString *sn in innerVideoSels) {
        SEL s = NSSelectorFromString(sn);
        if ([obj respondsToSelector:s]) {
            id inner = ((id(*)(id, SEL))objc_msgSend)(obj, s);
            if (inner && hasSponsoredBadge(inner)) return YES;
        }
    }
    // Direct badge check on the object itself
    if (hasSponsoredBadge(obj)) return YES;

    return NO;
}

// Helper: get contentsArray from any renderer type
static NSMutableArray *getContentsArray(id renderer) {
    if (!renderer) return nil;
    SEL sel = NSSelectorFromString(@"contentsArray");
    if ([renderer respondsToSelector:sel]) {
        id arr = ((id(*)(id, SEL))objc_msgSend)(renderer, sel);
        if ([arr isKindOfClass:[NSMutableArray class]]) return arr;
    }
    return nil;
}

// YTSectionListViewController -loadWithModel: → comprehensive ad filtering
static void hook_loadWithModel(id self, SEL _cmd, id model) {
    @try {
        NSMutableArray *contentsArray = getContentsArray(model);
        if (contentsArray && contentsArray.count > 0) {
            NSMutableIndexSet *removeIndexes = [NSMutableIndexSet indexSet];

            // Try MULTIPLE section renderer accessor paths
            // YouTube uses a protobuf "oneof" so each section can be a different type
            static NSArray *sectionAccessors = nil;
            static dispatch_once_t onceToken2;
            dispatch_once(&onceToken2, ^{
                sectionAccessors = @[
                    @"itemSectionRenderer",
                    @"richSectionRenderer",
                    @"shelfRenderer",
                    @"richGridRenderer",
                    @"horizontalListRenderer",
                    @"gridRenderer",
                    @"reelShelfRenderer",
                ];
            });

            // Ad description types for element matching
            static NSArray *adDescTypes = nil;
            static dispatch_once_t onceToken3;
            dispatch_once(&onceToken3, ^{
                adDescTypes = @[@"brand_promo", @"product_carousel", @"product_engagement_panel",
                                @"product_item", @"text_search_ad", @"text_image_button_layout",
                                @"carousel_headered_layout", @"carousel_footered_layout",
                                @"square_image_layout", @"landscape_image_wide_button_layout",
                                @"feed_ad_metadata", @"statement_banner"];
            });

            [contentsArray enumerateObjectsUsingBlock:^(id renderers, NSUInteger idx, BOOL *stop) {
                @try {
                    // Check ad indicators directly on the section wrapper
                    if (isAdRelated(renderers)) {
                        [removeIndexes addIndex:idx];
                        return;
                    }

                    // Try each section renderer accessor
                    for (NSString *accessorName in sectionAccessors) {
                        SEL accessor = NSSelectorFromString(accessorName);
                        if (![renderers respondsToSelector:accessor]) continue;
                        id sectionRenderer = ((id(*)(id, SEL))objc_msgSend)(renderers, accessor);
                        if (!sectionRenderer) continue;

                        // Check ad indicators on the section renderer itself
                        if (isAdRelated(sectionRenderer)) {
                            [removeIndexes addIndex:idx];
                            return;
                        }

                        // Get items inside this section
                        NSMutableArray *contents = getContentsArray(sectionRenderer);
                        if (!contents || contents.count == 0) continue;

                        // Check each item for ad indicators
                        BOOL sectionIsAd = NO;
                        NSMutableIndexSet *itemRemoveIndexes = [NSMutableIndexSet indexSet];

                        for (NSUInteger itemIdx = 0; itemIdx < contents.count; itemIdx++) {
                            id item = contents[itemIdx];

                            // Direct ad check on item
                            if (isAdRelated(item)) {
                                [itemRemoveIndexes addIndex:itemIdx];
                                continue;
                            }

                            // Check element renderer description
                            SEL elemSel = NSSelectorFromString(@"elementRenderer");
                            if ([item respondsToSelector:elemSel]) {
                                id elem = ((id(*)(id, SEL))objc_msgSend)(item, elemSel);
                                if (elem) {
                                    NSString *desc = [elem description];
                                    if (desc && [adDescTypes containsObject:desc]) {
                                        [itemRemoveIndexes addIndex:itemIdx];
                                        continue;
                                    }
                                }
                            }

                            // Also check first-level sub-items (for nested renderers)
                            NSMutableArray *subContents = getContentsArray(item);
                            if (subContents) {
                                for (id subItem in subContents) {
                                    if (isAdRelated(subItem)) {
                                        sectionIsAd = YES;
                                        break;
                                    }
                                }
                                if (sectionIsAd) break;
                            }
                        }

                        if (sectionIsAd) {
                            [removeIndexes addIndex:idx];
                            return;
                        }

                        // Remove individual ad items
                        if (itemRemoveIndexes.count > 0) {
                            [contents removeObjectsAtIndexes:itemRemoveIndexes];
                        }

                        // If section is now empty after removing ads, remove it
                        if (contents.count == 0) {
                            [removeIndexes addIndex:idx];
                            return;
                        }
                    }
                } @catch (NSException *e) {}
            }];

            if (removeIndexes.count > 0) {
                [contentsArray removeObjectsAtIndexes:removeIndexes];
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
// YTIElementRenderer -elementData : filter ads by description
// Returns empty NSData for known ad descriptions so YouTube renders
// nothing instead of the ad card.
// ============================================================
static IMP orig_elementData = NULL;
static NSData *hook_elementData(id self, SEL _cmd) {
    @try {
        // hasAdLoggingData via compatibilityOptions -> drop entirely
        SEL hasCompat = NSSelectorFromString(@"hasCompatibilityOptions");
        SEL compatOpts = NSSelectorFromString(@"compatibilityOptions");
        SEL hasAdLog = NSSelectorFromString(@"hasAdLoggingData");
        if ([self respondsToSelector:hasCompat] &&
            ((BOOL(*)(id, SEL))objc_msgSend)(self, hasCompat)) {
            id opts = ((id(*)(id, SEL))objc_msgSend)(self, compatOpts);
            if (opts && [opts respondsToSelector:hasAdLog] &&
                ((BOOL(*)(id, SEL))objc_msgSend)(opts, hasAdLog)) {
                return nil;
            }
        }
        NSString *desc = [self description];
        if (desc) {
            NSString *lower = [desc lowercaseString];
            // Empty NSData avoids blank-section layout issues
            if ([lower containsString:@"brand_promo"] ||
                [lower containsString:@"product_carousel"] ||
                [lower containsString:@"product_engagement_panel"] ||
                [lower containsString:@"product_item"] ||
                [lower containsString:@"text_search_ad"] ||
                [lower containsString:@"feed_ad_metadata"] ||
                [lower containsString:@"statement_banner"] ||
                [lower containsString:@"sponsor"] ||
                [lower containsString:@"promoted_sparkles"] ||
                [lower containsString:@"ad_slot"]) {
                return [NSData data];
            }
        }
    } @catch (NSException *e) {}
    if (orig_elementData)
        return ((NSData*(*)(id, SEL))orig_elementData)(self, _cmd);
    return nil;
}

// ============================================================
// Scorched earth: no-op promo/ad setter methods
// Prevents ad data from being stored so it can't render
// ============================================================
static void hook_noop_setter(id self, SEL _cmd, id arg) {}
static void hook_noop_setBool(id self, SEL _cmd, BOOL arg) {}
static id hook_return_nil(id self, SEL _cmd) { return nil; }
static BOOL hook_return_no(id self, SEL _cmd) { return NO; }

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

    // Element-level ad filtering (brand_promo, feed_ad_metadata, sponsored, ...)
    cls = objc_getClass("YTIElementRenderer");
    if (cls) orig_elementData = hookMethod(cls, @selector(elementData), (IMP)hook_elementData);

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

    // Re-install feed-ad hooks ON TOP of YTLite's. At this point YTLite
    // has already replaced our earlier hook; we overwrite again so OUR
    // filter runs first, then chains to YTLite's (now stored as orig).
    cls = objc_getClass("YTSectionListViewController");
    if (cls) {
        IMP newOrig = hookMethod(cls, @selector(loadWithModel:), (IMP)hook_loadWithModel);
        if (newOrig) orig_loadWithModel = newOrig;
    }
    cls = objc_getClass("YTIElementRenderer");
    if (cls) {
        IMP newOrig = hookMethod(cls, @selector(elementData), (IMP)hook_elementData);
        if (newOrig) orig_elementData = newOrig;
    }

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
