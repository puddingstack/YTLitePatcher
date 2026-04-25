/*
 * YTLitePatcher v13 - Home feed diagnostics + safer sponsored model filtering
 *
 * KEY INSIGHT: We hook YouTube classes in our constructor, BEFORE
 * YTLite.dylib loads. When YTLite's MSHookMessageEx runs later, it
 * saves OUR implementation as "original". When YTLite's _dvnCheck
 * gate fails and it calls %orig, it calls OUR hook - which blocks ads.
 *
 * Current focus:
 * - Keep the stable video ad blocking hooks.
 * - Force YTLite boolean feature toggles on through NSUserDefaults.
 * - Log Home feed renderer/object shapes to Documents/ytlpatcher.log.
 * - Observe YTIElementRenderer descriptions without returning nil/empty data,
 *   because filtering at elementData caused blank Home sections.
 * - Broaden loadWithModel filtering using live model introspection.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdarg.h>

// ============================================================
// Diagnostic logger - writes to Documents/ytlpatcher.log
// Pull from Files app: On My iPhone -> YouTube -> ytlpatcher.log
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
        [[NSFileManager defaultManager] removeItemAtPath:g_logPath error:nil];
    });
#endif
}

static void diag(NSString *fmt, ...) {
#if YTLP_DIAG
    if (!g_logPath || !g_logQ) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *stamped = [line stringByAppendingString:@"\n"];
    dispatch_async(g_logQ, ^{
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) {
            [stamped writeToFile:g_logPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
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
static IMP orig_elementData = NULL;
static IMP orig_UICollectionView_layoutSubviews = NULL;
static IMP orig_UITableView_layoutSubviews = NULL;

// ============================================================
// Ad blocking - these hook YouTube classes BEFORE YTLite loads
// ============================================================

// YTIPlayerResponse -isMonetized -> NO
static BOOL hook_isMonetized(id self, SEL _cmd) {
    return NO;
}

// YTDataUtils +spamSignalsDictionary -> nil
static id hook_spamSignals(id self, SEL _cmd) {
    return nil;
}

// YTAdsInnerTubeContextDecorator -decorateContext: -> skip
static void hook_decorateContext(id self, SEL _cmd, id ctx) {
    // Don't decorate with ad context
}

static NSString *shortDescription(id obj) {
    if (!obj) return @"<nil>";
    NSString *desc = nil;
    @try { desc = [obj description]; } @catch (NSException *e) { desc = @"<desc threw>"; }
    if (desc.length > 220) desc = [[desc substringToIndex:220] stringByAppendingString:@"..."];
    return desc ?: @"<nil desc>";
}

static BOOL stringLooksAdRelated(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return NO;
    NSString *lower = [value lowercaseString];
    static NSArray *markers = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = @[
            @"brand_promo", @"product_carousel", @"product_engagement_panel",
            @"product_item", @"text_search_ad", @"text_image_button_layout",
            @"carousel_headered_layout", @"carousel_footered_layout",
            @"square_image_layout", @"landscape_image_wide_button_layout",
            @"feed_ad_metadata", @"statement_banner", @"promoted",
            @"sponsored", @"sponsor", @"display_ad", @"ad_slot",
            @"shopping", @"merch", @"paid_content", @"sparkles"
        ];
    });
    for (NSString *marker in markers) {
        if ([lower containsString:marker]) return YES;
    }
    return [lower hasPrefix:@"ad_"] || [lower hasSuffix:@"_ad"] ||
           [lower containsString:@"_ad_"] || [lower hasSuffix:@".ad"];
}

static BOOL stringLooksAdDisclosure(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return NO;
    NSString *lower = [[value lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([lower isEqualToString:@"sponsored"] || [lower containsString:@"sponsored"]) return YES;
    if ([lower containsString:@"why this ad"] || [lower containsString:@"visit advertiser"]) return YES;
    if ([lower containsString:@"advertiser"] || [lower containsString:@"advertisement"]) return YES;
    if ([lower isEqualToString:@"ad"] || [lower hasPrefix:@"ad "] || [lower hasPrefix:@"ad ·"] || [lower hasPrefix:@"ad •"]) return YES;
    return NO;
}

static id safeObjectForSelector(id obj, NSString *selName) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return nil;
    @try { return ((id(*)(id, SEL))objc_msgSend)(obj, sel); }
    @catch (NSException *e) { return nil; }
}

static BOOL safeBoolForSelector(id obj, NSString *selName) {
    if (!obj) return NO;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return NO;
    @try { return ((BOOL(*)(id, SEL))objc_msgSend)(obj, sel); }
    @catch (NSException *e) { return NO; }
}

static long long safeIntegerForSelector(id obj, NSString *selName, BOOL *present) {
    if (present) *present = NO;
    if (!obj) return 0;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return 0;
    @try {
        if (present) *present = YES;
        return ((long long(*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (NSException *e) {
        if (present) *present = NO;
        return 0;
    }
}

static BOOL isAdRelatedDepth(id obj, NSUInteger depth);

// Helper: recursively check an object and its children for ad indicators
static BOOL isAdRelated(id obj) {
    return isAdRelatedDepth(obj, 0);
}

static BOOL isAdRelatedDepth(id obj, NSUInteger depth) {
    if (!obj) return NO;
    if (depth > 4) return NO;

    if (stringLooksAdRelated(shortDescription(obj))) return YES;

    // Check promoted video renderer types
    static NSArray *adSelNames = nil;
    static dispatch_once_t onceToken1;
    dispatch_once(&onceToken1, ^{
        adSelNames = @[
            @"hasPromotedVideoRenderer",
            @"hasCompactPromotedVideoRenderer",
            @"hasPromotedVideoInlineMutedRenderer",
            @"hasPromotedSparklesTextSearchAdRenderer",
            @"hasPromotedSparklesWebRenderer",
            @"hasBackgroundPromoRenderer",
            @"hasDisplayAdRenderer",
            @"hasBrandPromoRenderer",
            @"hasShoppingCarouselRenderer",
            @"hasProductCarouselRenderer",
            @"hasStatementBannerRenderer",
            @"hasCommandWrapperPromoRenderer",
            @"hasUpsellDialogRenderer",
            @"hasPromoCommand",
            @"hasPromoType",
            @"hasAdLoggingData",
        ];
    });

    for (NSString *selName in adSelNames) {
        if (safeBoolForSelector(obj, selName)) {
            return YES;
        }
    }

    // Check compatibilityOptions -> hasAdLoggingData
    SEL hasCompat = NSSelectorFromString(@"hasCompatibilityOptions");
    SEL compatOpts = NSSelectorFromString(@"compatibilityOptions");
    SEL hasAdLog = NSSelectorFromString(@"hasAdLoggingData");
    if ([obj respondsToSelector:hasCompat] && safeBoolForSelector(obj, @"hasCompatibilityOptions")) {
        id opts = safeObjectForSelector(obj, @"compatibilityOptions");
        if (opts && [opts respondsToSelector:hasAdLog] && safeBoolForSelector(opts, @"hasAdLoggingData")) {
            return YES;
        }
    }

    static NSArray *objectAccessors = nil;
    static dispatch_once_t onceToken2;
    dispatch_once(&onceToken2, ^{
        objectAccessors = @[
            @"elementRenderer", @"renderer", @"commandWrapperPromoRenderer",
            @"promoCommand", @"badgeRenderer", @"metadataBadgeRenderer",
            @"adBadgeRenderer", @"headerRenderer", @"contentRenderer",
            @"videoRenderer", @"compactVideoRenderer", @"gridVideoRenderer",
            @"richItemRenderer"
        ];
    });
    for (NSString *accessor in objectAccessors) {
        id child = safeObjectForSelector(obj, accessor);
        if (child && child != obj && isAdRelatedDepth(child, depth + 1)) return YES;
    }

    return NO;
}

static void diagObject(id obj, NSString *prefix, NSUInteger depth) {
#if YTLP_DIAG
    if (!obj || depth > 2) return;
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@ class=%@ desc=%@",
                             prefix, NSStringFromClass([obj class]), shortDescription(obj)];
    NSArray *bools = @[@"hasAdLoggingData", @"hasCompatibilityOptions",
                       @"hasPromotedVideoRenderer", @"hasCompactPromotedVideoRenderer",
                       @"hasPromotedVideoInlineMutedRenderer", @"hasCommandWrapperPromoRenderer",
                       @"hasPromoCommand", @"hasUpsellDialogRenderer"];
    for (NSString *selName in bools) {
        if ([obj respondsToSelector:NSSelectorFromString(selName)]) {
            [line appendFormat:@" %@=%d", selName, safeBoolForSelector(obj, selName)];
        }
    }
    BOOL hasOneOf = NO;
    long long oneOf = safeIntegerForSelector(obj, @"rendererOneOfCase", &hasOneOf);
    if (hasOneOf) [line appendFormat:@" rendererOneOfCase=%lld", oneOf];
    if (isAdRelated(obj)) [line appendString:@" ADLIKE=1"];
    diag(@"%@", line);

    NSArray *children = @[@"itemSectionRenderer", @"richSectionRenderer", @"shelfRenderer",
                          @"richGridRenderer", @"horizontalListRenderer", @"gridRenderer",
                          @"reelShelfRenderer", @"elementRenderer", @"renderer"];
    for (NSString *accessor in children) {
        id child = safeObjectForSelector(obj, accessor);
        if (child && child != obj) {
            diagObject(child, [prefix stringByAppendingFormat:@".%@", accessor], depth + 1);
        }
    }
#endif
}

static BOOL viewTreeContainsAdDisclosure(UIView *view, NSUInteger depth, NSMutableArray *hits) {
    if (!view || depth > 12) return NO;

    NSArray *values = @[
        view.accessibilityLabel ?: @"",
        view.accessibilityValue ?: @"",
        view.accessibilityHint ?: @""
    ];
    for (NSString *value in values) {
        if (stringLooksAdDisclosure(value)) {
            if (hits) [hits addObject:value];
            return YES;
        }
    }

    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = ((UILabel *)view).text;
        if (stringLooksAdDisclosure(text)) {
            if (hits) [hits addObject:text];
            return YES;
        }
    }

    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal] ?: button.titleLabel.text;
        if (stringLooksAdDisclosure(title)) {
            if (hits) [hits addObject:title];
            return YES;
        }
    }

    for (UIView *subview in view.subviews) {
        if (viewTreeContainsAdDisclosure(subview, depth + 1, hits)) return YES;
    }
    return NO;
}

static void hideRenderedAdCell(UIView *cell, NSString *source) {
    if (!cell || cell.hidden) return;
    NSMutableArray *hits = [NSMutableArray array];
    if (!viewTreeContainsAdDisclosure(cell, 0, hits)) return;
    diag(@"[ui-ad-hide] source=%@ cell=%@ frame=%@ hits=%@",
         source, NSStringFromClass([cell class]), NSStringFromCGRect(cell.frame), hits);
    cell.hidden = YES;
    cell.alpha = 0.0;
    cell.userInteractionEnabled = NO;
}

static void scanCollectionViewForRenderedAds(UICollectionView *collectionView) {
    @try {
        for (UICollectionViewCell *cell in [collectionView visibleCells]) {
            hideRenderedAdCell(cell, @"UICollectionView");
        }
    } @catch (NSException *e) {}
}

static void scanTableViewForRenderedAds(UITableView *tableView) {
    @try {
        for (UITableViewCell *cell in [tableView visibleCells]) {
            hideRenderedAdCell(cell, @"UITableView");
        }
    } @catch (NSException *e) {}
}

static void hook_UICollectionView_layoutSubviews(id self, SEL _cmd) {
    if (orig_UICollectionView_layoutSubviews) {
        ((void(*)(id, SEL))orig_UICollectionView_layoutSubviews)(self, _cmd);
    }
    if ([self isKindOfClass:[UICollectionView class]]) scanCollectionViewForRenderedAds((UICollectionView *)self);
}

static void hook_UITableView_layoutSubviews(id self, SEL _cmd) {
    if (orig_UITableView_layoutSubviews) {
        ((void(*)(id, SEL))orig_UITableView_layoutSubviews)(self, _cmd);
    }
    if ([self isKindOfClass:[UITableView class]]) scanTableViewForRenderedAds((UITableView *)self);
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

// YTSectionListViewController -loadWithModel: -> comprehensive ad filtering
static void hook_loadWithModel(id self, SEL _cmd, id model) {
    @try {
        NSMutableArray *contentsArray = getContentsArray(model);
        static int loggedCalls = 0;
        if (contentsArray && contentsArray.count > 0 && loggedCalls < 8) {
            loggedCalls++;
            diag(@"[loadWithModel #%d] vc=%@ model=%@ sections=%lu",
                 loggedCalls, NSStringFromClass([self class]), NSStringFromClass([model class]),
                 (unsigned long)contentsArray.count);
            NSUInteger maxSections = MIN((NSUInteger)24, contentsArray.count);
            for (NSUInteger i = 0; i < maxSections; i++) {
                diagObject(contentsArray[i], [NSString stringWithFormat:@"  sec[%lu]", (unsigned long)i], 0);
            }
        }
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
                                    if (desc && stringLooksAdRelated(desc)) {
                                        [itemRemoveIndexes addIndex:itemIdx];
                                        continue;
                                    }
                                }
                            }

                            if (stringLooksAdRelated(shortDescription(item))) {
                                [itemRemoveIndexes addIndex:itemIdx];
                                continue;
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

// Observe element renderer descriptions without filtering here. Returning nil
// or empty NSData from this hook removed content but left blank Home slots.
static NSData *hook_elementData_diagOnly(id self, SEL _cmd) {
    @try {
        static NSMutableSet *seen = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ seen = [NSMutableSet new]; });
        NSString *desc = shortDescription(self);
        BOOL adlike = isAdRelated(self) || stringLooksAdRelated(desc);
        @synchronized (seen) {
            if (seen.count < 300 && desc && ![seen containsObject:desc]) {
                [seen addObject:desc];
                diag(@"[elementData] class=%@ adlike=%d desc=%@",
                     NSStringFromClass([self class]), adlike, desc);
            }
        }
    } @catch (NSException *e) {}
    if (orig_elementData) return ((NSData *(*)(id, SEL))orig_elementData)(self, _cmd);
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
// gate fails -> calls %orig -> calls OUR hook -> ads blocked.
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

    cls = [UICollectionView class];
    if (cls) orig_UICollectionView_layoutSubviews = hookMethod(cls, @selector(layoutSubviews), (IMP)hook_UICollectionView_layoutSubviews);

    cls = [UITableView class];
    if (cls) orig_UITableView_layoutSubviews = hookMethod(cls, @selector(layoutSubviews), (IMP)hook_UITableView_layoutSubviews);

    // Diagnostic only. Do not hide from elementData; it creates blank slots.
    cls = objc_getClass("YTIElementRenderer");
    if (cls) orig_elementData = hookMethod(cls, @selector(elementData), (IMP)hook_elementData_diagOnly);

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

    // YTLite hooks some of these after us. Reinstall our wrappers on top so
    // diagnostics and model filtering still run, then chain to YTLite/original.
    cls = objc_getClass("YTSectionListViewController");
    if (cls) {
        IMP newOrig = hookMethod(cls, @selector(loadWithModel:), (IMP)hook_loadWithModel);
        if (newOrig && newOrig != (IMP)hook_loadWithModel) orig_loadWithModel = newOrig;
    }
    cls = objc_getClass("YTIElementRenderer");
    if (cls) {
        IMP newOrig = hookMethod(cls, @selector(elementData), (IMP)hook_elementData_diagOnly);
        if (newOrig && newOrig != (IMP)hook_elementData_diagOnly) orig_elementData = newOrig;
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
// dyld callback - for DVN classes only (need YTLite loaded)
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
// Force-on YTLite feature toggles through NSUserDefaults
// ============================================================
static IMP orig_NSUD_boolForKey = NULL;
static IMP orig_NSUD_objectForKey = NULL;

static NSSet *featureKeysSet(void) {
    static NSSet *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"noAds", @"hideAds", @"removeAds", @"adBlock", @"blockAds",
            @"hideFeedAds", @"hideHomeAds", @"hideSponsored",
            @"hideShorts", @"hideShortsTab", @"removeShorts",
            @"backgroundPlayback", @"backgroundAudio",
            @"noPromotionCards", @"hidePremium", @"noPremium",
            @"noCast", @"hideCast", @"noHUDMsgs", @"noWatermarks",
            @"disableAutoplay", @"noAutoplay", @"miniplayer"
        ]];
    });
    return keys;
}

static BOOL keyShouldBeOn(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    if ([featureKeysSet() containsObject:key]) return YES;
    NSCharacterSet *uppercase = [NSCharacterSet uppercaseLetterCharacterSet];
    if ([key hasPrefix:@"no"] && key.length > 2 && [uppercase characterIsMember:[key characterAtIndex:2]]) return YES;
    if ([key hasPrefix:@"hide"] && key.length > 4 && [uppercase characterIsMember:[key characterAtIndex:4]]) return YES;
    if ([key hasPrefix:@"remove"] && key.length > 6 && [uppercase characterIsMember:[key characterAtIndex:6]]) return YES;
    if ([key hasPrefix:@"disable"] && key.length > 7 && [uppercase characterIsMember:[key characterAtIndex:7]]) return YES;
    return NO;
}

static BOOL hook_NSUD_boolForKey(id self, SEL _cmd, NSString *key) {
    if (keyShouldBeOn(key)) {
        static NSMutableSet *loggedKeys = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ loggedKeys = [NSMutableSet new]; });
        @synchronized (loggedKeys) {
            if (![loggedKeys containsObject:key]) {
                [loggedKeys addObject:key];
                diag(@"[NSUserDefaults boolForKey] forcing %@=YES", key);
            }
        }
        return YES;
    }
    if (orig_NSUD_boolForKey) return ((BOOL(*)(id, SEL, NSString *))orig_NSUD_boolForKey)(self, _cmd, key);
    return NO;
}

static id hook_NSUD_objectForKey(id self, SEL _cmd, NSString *key) {
    if (keyShouldBeOn(key)) return @YES;
    if (orig_NSUD_objectForKey) return ((id(*)(id, SEL, NSString *))orig_NSUD_objectForKey)(self, _cmd, key);
    return nil;
}

static void hookNSUserDefaults(void) {
    Class cls = [NSUserDefaults class];
    orig_NSUD_boolForKey = hookMethod(cls, @selector(boolForKey:), (IMP)hook_NSUD_boolForKey);
    orig_NSUD_objectForKey = hookMethod(cls, @selector(objectForKey:), (IMP)hook_NSUD_objectForKey);
    diag(@"[ytlp] NSUserDefaults force-on hooks installed");
}

// ============================================================
// Constructor - runs BEFORE YTLite loads
// ============================================================
__attribute__((constructor))
static void patcher_init(void) {
    diagInit();
    diag(@"[ytlp] patcher_init v13");
    hookNSUserDefaults();

    // Phase 1: Hook YouTube classes immediately
    // YouTube.app is the host - its classes are already loaded
    hookYouTubeClasses();

    // Phase 2: Register callback for when YTLite.dylib loads
    _dyld_register_func_for_add_image(dyld_image_added);
}
