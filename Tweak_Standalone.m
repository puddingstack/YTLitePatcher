/*
 * YTLitePatcher v12 — Force YTLite features ON + diagnostic logging
 *
 * KEY ADDITIONS over v11:
 * - Hook NSUserDefaults -boolForKey:/-objectForKey: to return YES
 *   for known YTLite feature toggles (noAds, hideShorts, etc.) and
 *   for any key matching no*/hide*/disable*/remove*/enable* patterns.
 *   This makes YTLite's OWN paywall-gated features fire because
 *   their `if (ytlBool(@"<key>"))` checks now all see YES — no
 *   matter what suite name they read from.
 * - Diagnostic logger writes /Documents/ytlpatcher.log so we can
 *   see (a) what model classes/sections show up in the home feed
 *   and (b) what unique elementData descriptions are observed.
 *   Pull via the Files app (On My iPhone -> YouTube). Toggle off
 *   by setting YTLP_DIAG = 0.
 * - Force `has*PromotedRenderer`-style probes to NO on common
 *   item-wrapper classes so any code that special-cases promo
 *   content treats it as ordinary (then loadWithModel drops it).
 * - elementData filter description list expanded with promoted/
 *   merch/shopping/_ad_/ad_*/.ad suffixes.
 *
 * Carried from v11:
 * - 2-phase init (constructor + dyld add_image callback for YTLite)
 * - Comprehensive loadWithModel section/item filtering
 * - Sponsored-badge detection on inner video renderers
 * - Re-hook loadWithModel and elementData AFTER YTLite loads so our
 *   filter wraps YTLite's chain.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

// ============================================================
// Diagnostic logger — writes to Documents/ytlpatcher.log
// User can pull via the Files app (On My iPhone -> YouTube).
// Toggle off by setting YTLP_DIAG = 0.
// ============================================================
#define YTLP_DIAG 1

static NSString *g_logPath = nil;
static dispatch_queue_t g_logQ = nil;

static void diagInit(void) {
#if YTLP_DIAG
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject;
        if (!docs) return;
        g_logPath = [[docs stringByAppendingPathComponent:@"ytlpatcher.log"] copy];
        g_logQ = dispatch_queue_create("ytlp.log", DISPATCH_QUEUE_SERIAL);
        // Truncate at start of each launch
        [[NSFileManager defaultManager] removeItemAtPath:g_logPath error:nil];
    });
#endif
}

static void diag(NSString *fmt, ...) {
#if YTLP_DIAG
    if (!g_logPath || !g_logQ) return;
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *stamped = [NSString stringWithFormat:@"%@\n", line];
    dispatch_async(g_logQ, ^{
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) {
            [stamped writeToFile:g_logPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    });
#endif
}

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
#if YTLP_DIAG
        // Log first few model loads to see what we're filtering
        static int loggedCalls = 0;
        if (loggedCalls < 5 && contentsArray.count > 0) {
            loggedCalls++;
            diag(@"[loadWithModel #%d] model=%@ sections=%lu",
                 loggedCalls, NSStringFromClass([model class]),
                 (unsigned long)contentsArray.count);
            NSUInteger maxLog = MIN((NSUInteger)20, contentsArray.count);
            for (NSUInteger i = 0; i < maxLog; i++) {
                id section = contentsArray[i];
                NSMutableString *info = [NSMutableString stringWithFormat:
                    @"  [sec %lu] %@", (unsigned long)i, NSStringFromClass([section class])];
                // Try to identify which oneof field is set
                static NSArray *probeAcc = nil;
                static dispatch_once_t o;
                dispatch_once(&o, ^{
                    probeAcc = @[@"hasItemSectionRenderer", @"hasRichSectionRenderer",
                                 @"hasShelfRenderer", @"hasRichGridRenderer",
                                 @"hasHorizontalListRenderer", @"hasReelShelfRenderer",
                                 @"hasGridRenderer"];
                });
                for (NSString *p in probeAcc) {
                    SEL s = NSSelectorFromString(p);
                    if ([section respondsToSelector:s] &&
                        ((BOOL(*)(id, SEL))objc_msgSend)(section, s)) {
                        [info appendFormat:@" %@", p];
                    }
                }
                diag(@"%@", info);
            }
        }
#endif
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
// nothing instead of the ad card.  Also samples descriptions to the
// diagnostic log so we can see what's actually being rendered.
// ============================================================
static IMP orig_elementData = NULL;
static NSData *hook_elementData(id self, SEL _cmd) {
    @try {
        NSString *desc = [self description];
#if YTLP_DIAG
        static NSMutableSet *seen = nil;
        static dispatch_once_t o;
        dispatch_once(&o, ^{ seen = [NSMutableSet new]; });
        @synchronized (seen) {
            if (desc && seen.count < 200 && ![seen containsObject:desc]) {
                [seen addObject:desc];
                diag(@"[elementData] desc=%@", desc);
            }
        }
#endif
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
        if (desc) {
            NSString *lower = [desc lowercaseString];
            if ([lower containsString:@"brand_promo"] ||
                [lower containsString:@"product_carousel"] ||
                [lower containsString:@"product_engagement_panel"] ||
                [lower containsString:@"product_item"] ||
                [lower containsString:@"text_search_ad"] ||
                [lower containsString:@"feed_ad_metadata"] ||
                [lower containsString:@"statement_banner"] ||
                [lower containsString:@"sponsor"] ||
                [lower containsString:@"promoted"] ||
                [lower containsString:@"promo_"] ||
                [lower containsString:@"display_ad"] ||
                [lower containsString:@"merch"] ||
                [lower containsString:@"shopping"] ||
                [lower containsString:@"ad_slot"] ||
                [lower containsString:@"_ad_"] ||
                [lower hasPrefix:@"ad_"] ||
                [lower hasSuffix:@"_ad"] ||
                [lower hasSuffix:@".ad"]) {
                return [NSData data];
            }
        }
    } @catch (NSException *e) {}
    if (orig_elementData)
        return ((NSData*(*)(id, SEL))orig_elementData)(self, _cmd);
    return nil;
}

// ============================================================
// Promoted-renderer "has*" probes — force NO so anything that
// gates on these flags treats the item as non-promo. Counterpart
// is loadWithModel which already drops these from the feed.
// ============================================================
static BOOL hook_returnNO(id self, SEL _cmd) { return NO; }

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

    // Force "is/has promoted" probes to NO on common item wrappers so any
    // downstream code that special-cases promo content treats them as normal
    // (then loadWithModel drops them entirely).
    {
        NSArray *promoCarriers = @[
            @"YTISectionListSupportedRenderers",
            @"YTIItemSectionSupportedRenderers",
            @"YTIRichItemRenderer",
            @"YTIShelfRenderer",
        ];
        NSArray *promoProbes = @[
            @"hasPromotedVideoRenderer",
            @"hasCompactPromotedVideoRenderer",
            @"hasPromotedVideoInlineMutedRenderer",
            @"hasPromotedSparklesTextSearchAdRenderer",
            @"hasPromotedSparklesWebRenderer",
            @"hasBackgroundPromoRenderer",
            @"hasDisplayAdRenderer",
            @"hasBrandPromoRenderer",
            @"hasStatementBannerRenderer",
            @"hasShoppingCarouselRenderer",
            @"hasProductCarouselRenderer",
        ];
        for (NSString *cn in promoCarriers) {
            Class c = objc_getClass([cn UTF8String]);
            if (!c) continue;
            for (NSString *sn in promoProbes) {
                SEL s = NSSelectorFromString(sn);
                Method m = class_getInstanceMethod(c, s);
                if (m) method_setImplementation(m, (IMP)hook_returnNO);
            }
        }
    }
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
        if (newOrig && newOrig != (IMP)hook_loadWithModel) orig_loadWithModel = newOrig;
    }
    cls = objc_getClass("YTIElementRenderer");
    if (cls) {
        IMP newOrig = hookMethod(cls, @selector(elementData), (IMP)hook_elementData);
        if (newOrig && newOrig != (IMP)hook_elementData) orig_elementData = newOrig;
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
// Force-on YTLite feature toggles by hooking NSUserDefaults
// ------------------------------------------------------------
// YTLite's hooks gate every feature behind:
//   if (ytlBool(@"<key>")) { ... do the thing ... }
// `ytlBool` reads from a private NSUserDefaults suite (the suite
// name is XOR-encrypted in the binary). We can't easily set the
// suite directly, but we can intercept -boolForKey: on the class
// and return YES for any key in our allow-list.  This makes ALL
// of YTLite's paywall-gated features (including ones we don't
// hook ourselves) come online — without bypassing the gate.
// ============================================================
static IMP orig_NSUD_boolForKey = NULL;
static IMP orig_NSUD_objectForKey = NULL;

static NSSet *featureKeysSet(void) {
    static NSSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            // Ad blocking
            @"noAds", @"hideAds", @"removeAds", @"adBlock", @"blockAds",
            @"hideFeedAds", @"hideHomeAds", @"hideSponsored", @"hideShorts",
            @"hideShortsTab", @"removeShorts",
            // Player / video features
            @"backgroundPlayback", @"backgroundAudio",
            @"hd720", @"hd1080", @"hd4k", @"forceHD", @"forceHighestQuality",
            @"playbackSpeed", @"speedControl", @"customSpeed",
            @"persistPlaybackSpeed", @"persistVideoQuality",
            @"autoFullscreen", @"portraitFullscreen", @"forceFullscreen",
            @"hideAutoplaySwitch", @"disableAutoplay", @"noAutoplay",
            @"hideCaptions", @"hideSubtitles",
            @"miniplayerLikeDislike", @"miniplayer",
            @"stickyPlaybackSpeed", @"stickyQuality",
            @"hideHUDMessages", @"noHUD",
            // UI
            @"hideCast", @"noCast",
            @"hidePremium", @"noPremium",
            @"hideVoiceSearch", @"noVoiceSearch",
            @"hideShareButton",
            @"hideTrendingTab", @"hideSubscriptionsTab",
            @"hideShortsButton", @"hideShortsRow",
            @"hideRelatedVideos", @"hideComments",
            @"hideStoreButton",
            @"premiumYTLogo", @"premiumLogo",
            @"appTheme", @"oledDarkMode",
            // Downloads / sharing
            @"YTUHD", @"showYTUHD",
            @"downloadVideo", @"enableDownloads",
            @"yt3rd",
            // Privacy
            @"disableHints", @"noHints",
            @"replacePiPButton",
            // Catch-alls for anything starting with "no"/"hide"/"disable"/"remove"
            // are handled by the prefix check below.
        ]];
    });
    return s;
}

static BOOL keyShouldBeOn(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    if ([featureKeysSet() containsObject:key]) return YES;
    // Heuristic prefixes that indicate a feature toggle
    if ([key hasPrefix:@"no"] && key.length > 2 && [[NSCharacterSet uppercaseLetterCharacterSet]
            characterIsMember:[key characterAtIndex:2]]) return YES;
    if ([key hasPrefix:@"hide"] && key.length > 4 && [[NSCharacterSet uppercaseLetterCharacterSet]
            characterIsMember:[key characterAtIndex:4]]) return YES;
    if ([key hasPrefix:@"disable"] && key.length > 7 && [[NSCharacterSet uppercaseLetterCharacterSet]
            characterIsMember:[key characterAtIndex:7]]) return YES;
    if ([key hasPrefix:@"remove"] && key.length > 6 && [[NSCharacterSet uppercaseLetterCharacterSet]
            characterIsMember:[key characterAtIndex:6]]) return YES;
    if ([key hasPrefix:@"enable"] && key.length > 6 && [[NSCharacterSet uppercaseLetterCharacterSet]
            characterIsMember:[key characterAtIndex:6]]) return YES;
    return NO;
}

static BOOL hook_NSUD_boolForKey(id self, SEL _cmd, NSString *key) {
    if (keyShouldBeOn(key)) return YES;
    if (orig_NSUD_boolForKey)
        return ((BOOL(*)(id, SEL, NSString *))orig_NSUD_boolForKey)(self, _cmd, key);
    return NO;
}

static id hook_NSUD_objectForKey(id self, SEL _cmd, NSString *key) {
    if (keyShouldBeOn(key)) return @YES;
    if (orig_NSUD_objectForKey)
        return ((id(*)(id, SEL, NSString *))orig_NSUD_objectForKey)(self, _cmd, key);
    return nil;
}

static void hookNSUserDefaults(void) {
    Class cls = [NSUserDefaults class];
    orig_NSUD_boolForKey   = hookMethod(cls, @selector(boolForKey:),   (IMP)hook_NSUD_boolForKey);
    orig_NSUD_objectForKey = hookMethod(cls, @selector(objectForKey:), (IMP)hook_NSUD_objectForKey);
    diag(@"[ytlp] NSUserDefaults force-on hooks installed");
}

// ============================================================
// Constructor — runs BEFORE YTLite loads
// ============================================================
__attribute__((constructor))
static void patcher_init(void) {
    diagInit();
    diag(@"[ytlp] patcher_init");

    // Phase 0: Force feature toggles ON via NSUserDefaults
    hookNSUserDefaults();

    // Phase 1: Hook YouTube classes immediately
    // YouTube.app is the host — its classes are already loaded
    hookYouTubeClasses();

    // Phase 2: Register callback for when YTLite.dylib loads
    _dyld_register_func_for_add_image(dyld_image_added);
}
