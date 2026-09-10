/*
 * Hider.m
 * aspauldingcode
 * implementation of Hider Dock tweak.
 * Uses native Objective-C runtime for swizzling to minimize dependencies.
 */

#import "tweak.h"
#import "Hider.h"
#import "HiderActions.h"
#import "HiderCustomAppDockHider.h"
#import "Hooks.h"

@interface HiderDockActions (Private)
+ (void)hideIndicatorLayersNearRect:(CGRect)targetRect
                            inLayer:(CALayer *)container
                       excludingTree:(CALayer *)excluded;
@end
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>

#pragma mark - Utils Prototypes

// Logging
void Hider_LogToFile(const char *func, int line, NSString *format, ...);

// Suppress GNU extension warning for token pasting
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu-zero-variadic-macro-arguments"
#define LOG_TO_FILE(fmt, ...)                                                  \
  do {                                                                         \
    NSString *_fmt = [NSString stringWithUTF8String:fmt];                      \
    Hider_LogToFile(__FUNCTION__, __LINE__, _fmt, ##__VA_ARGS__);              \
  } while (0)
#pragma clang diagnostic pop

// Config state: these are the only named hide/show config booleans.
static BOOL finderHidden = NO;
static BOOL trashHidden = NO;

// Runtime-only tweak state. Keep private to this file.
static BOOL coreDockLoaded = NO;
static void *coreDockHandle = NULL;
static CALayer *modernFloorLayer = nil;
static CALayer *legacyFloorLayer = nil;
static __weak id finderTileObject = nil;
static __weak id trashTileObject = nil;
static NSMutableArray *separatorTileObjects = nil;
static BOOL prevFinderHidden = NO;
static BOOL prevTrashHidden = NO;
static BOOL separatorHiddenUntilRestart = NO;
static NSSet *hiddenAppBundleIDs = nil;
static NSSet *prevHiddenAppBundleIDs = nil;
static NSMapTable *customAppTileObjects = nil;

// Global re-entrancy guard for swizzles and heavy enforcement.
static __thread BOOL g_inHiderAction = NO;
#define HIDER_LOCK()   BOOL _prevLock = g_inHiderAction; g_inHiderAction = YES
#define HIDER_UNLOCK() g_inHiderAction = _prevLock
#define IF_HIDER_LOCKED() if (g_inHiderAction)

extern void HiderInstallHooks(void);

// g_... aliases for older code compatibility
#define g_coreDockLoaded coreDockLoaded
#define g_coreDockHandle coreDockHandle
#define g_modernFloorLayer modernFloorLayer
#define g_legacyFloorLayer legacyFloorLayer
#define g_finderTileObject finderTileObject
#define g_trashTileObject trashTileObject
#define g_separatorTileObjects separatorTileObjects
#define g_prevFinderHidden prevFinderHidden
#define g_prevTrashHidden prevTrashHidden
#define g_hiddenAppBundleIDs hiddenAppBundleIDs
#define g_prevHiddenAppBundleIDs prevHiddenAppBundleIDs
#define g_customAppTileObjects customAppTileObjects

// Key used by Hider_RunOnce to mark that doCommand:1004 was sent for a tile.
static const char kHiderCustomAppRemoveKey = '\0';
static const char kHiderTileRemoveCommandKey = '\0';

// Associated-object keys for tagging individual tile/layer objects with
// durable per-object state that survives across swizzle hops.
// - kHiderBundleIDTag: attached to tile-model objects → their normalized
//   bundle ID. Used by layer hooks for reverse-lookup when Hider_GetBundleID
//   cannot resolve the bundle ID from the layer directly.
// - kHiderSlotSuppressed: attached to slot-container CALayers → @YES when
//   the slot is actively suppressed. Enforced in setHidden:/setOpacity:
//   swizzles so the Dock cannot restore visibility.
static const char kHiderBundleIDTag;
static const char kHiderSlotSuppressed;
static const char kHiderForcedHiddenCache;
static const char kHiderTileDemotedKey;

// Helper functions
NSString *Hider_GetBundleID(id obj);
BOOL Hider_IsFinder(NSString *bundleID);
BOOL Hider_IsTrash(NSString *bundleID);
BOOL Hider_IsCustomHiddenApp(NSString *bundleID);
BOOL Hider_IsSeparatorTileLayer(id obj);
typedef void (*HiderVoidIMP)(id, SEL);
typedef id (*HiderObjectIMP)(id, SEL);
typedef void (*HiderBoolIMP)(id, SEL, BOOL);
typedef void (*HiderFloatIMP)(id, SEL, float);
typedef void (*HiderCGContextIMP)(id, SEL, CGContextRef);
typedef void (*HiderCAAnimationIMP)(id, SEL, CAAnimation *, NSString *);
typedef void (*HiderCALayerIMP)(id, SEL, CALayer *);
typedef void (*HiderCALayerIndexIMP)(id, SEL, CALayer *, unsigned int);
typedef void (*HiderCALayerSiblingIMP)(id, SEL, CALayer *, CALayer *);
typedef void (*HiderNSArrayIMP)(id, SEL, NSArray *);
typedef void (*HiderNSRectIMP)(id, SEL, NSRect);
typedef void (*HiderCGFloatIMP)(id, SEL, CGFloat);
typedef void (*HiderDockBarInsertIMP)(id, SEL, id, long long, id);

static BOOL HiderInstallConcreteDockHook(Class cls, SEL sel, IMP replacement);
static IMP HiderDockOriginalIMP(id object, SEL sel);
static void HiderRuntimeSwizzleBoolSelectorsForConfiguredTileSuppression(
    Class cls, NSArray<NSString *> *selectorNames);
static void HiderRuntimeSwizzleVoidSelectorsForConfiguredTileSuppression(
    Class cls, NSArray<NSString *> *selectorNames);
static void Hider_LoadCustomAppsFromPrefs(void);
static void Hider_LoadCustomAppsFromCache(void);
static void Hider_LoadSettingsFromCache(void);
static void Hider_LoadVisibilityFlags(BOOL synchronizePrefs);

// Bundle-ID normalization: lowercase + trim whitespace.
static NSString *Hider_NormalizeBundleID(NSString *bid);
static NSString *Hider_BundleIDFromDockPersistentItem(id item);
static NSString *Hider_ResolveTileBundleID(id tile);
static void Hider_TrackResolvedTile(id tile, NSString *bundleID);
static void Hider_ApplyHiddenTilePipeline(id tile, NSString * _Nullable bundleID,
                                          BOOL requestRemoval __unused);
static void Hider_DeferForceRemoveHiddenTile(id tile, NSString *bundleID,
                                             int64_t delayMs);
static void Hider_DemoteTileModelForHiddenApp(id tile, NSString *bundleID);
static BOOL Hider_InvokeBoolSetter(id target, SEL selector, BOOL value);
static BOOL Hider_InvokeVoidNoArg(id target, SEL selector);
static BOOL Hider_InvokeIntCommand(id target, SEL selector, NSInteger value);

// Tile registry: tag tile-model objects with their resolved bundle ID and
// populate g_customAppTileObjects for both forward and reverse lookup.
static void Hider_RegisterTile(id tile, NSString *bid);

// Resolve the bundle ID for a DOCKTileLayer, trying Hider_GetBundleID first,
// then the associated-object tag on the delegate, then g_customAppTileObjects
// pointer-comparison fallback.
static NSString *Hider_ResolveBundleIDForLayer(CALayer *layer);

// Resolve hidden-app bundle ID from tile delegate's PID (fallback).
static NSString *Hider_ResolveBundleIDByPID(id delegate);

// Single-point query: should this DOCKTileLayer be force-hidden?
static BOOL Hider_ShouldForceHideLayer(CALayer *layer);
static void Hider_InvalidateLayerCaches(void);
static NSArray<CALayer *> *Hider_CopySublayersSnapshot(CALayer *layer);

// Slot-container suppression: tag a slot layer and hide it and all siblings.
static void Hider_SuppressSlot(CALayer *tileLayer);
static void Hider_UnsuppressSlot(CALayer *slot);
static BOOL Hider_IsSlotSuppressed(CALayer *layer);
static BOOL Hider_IsInSuppressedSlot(CALayer *layer);

// Unified enforcement: discover tiles, suppress, remove across all windows.
static void Hider_EnforceHiddenApps(NSString * _Nullable singleBID, pid_t pid);
static void Hider_ScheduleTrackedHiddenTileRemovals(NSString *source);
// Hotload hidden-app list changes immediately.
static void Hider_HotloadHiddenAppsNow(void);

// Execution guard
void Hider_RunOnce(id object, const void *key, void (^block)(void));

// Layout helpers
static void Hider_ApplyEdgeTileVisibility(CALayer *parent);
void Hider_ForceLayoutRecursive(CALayer *layer);
static void Hider_HideFloorSeparators(CALayer *layer);
static void Hider_SuppressTileRender(id tile);
static void Hider_TriggerLayoutOnTrackedLayers(void);
static void Hider_ForceHideRunningApp(NSString * _Nullable bid, pid_t pid, BOOL enforce);
static void Hider_ForceHideRunningAppNow(NSString * _Nullable bid, pid_t pid);
static void Hider_ForceHotloadHiddenTilesNow(void);

// Suppress a tile-model's visual output if it belongs to a hidden custom app.
static void Hider_SuppressIfHidden(id tile);
static void Hider_SuppressConfiguredTileIfHidden(id tile);
// Remove a hidden tile immediately with retries.
static void Hider_RequestTileRemoval(id tile);
static void Hider_HideTileDecorations(id tile);
static void Hider_HideRootLayerTile(NSString *bundleID);
static void Hider_HideAllRootLayerHiddenTiles(void);
static void Hider_HookRootLayerIfNeeded(void);
static BOOL Hider_ShouldBlockTileLayer(CALayer *layer);
static BOOL Hider_ShouldBlockIndicatorLayerForHiddenTiles(
    CALayer *indicatorLayer, NSArray<NSValue *> *blockedTileRects);
static NSString *Hider_BundleIDFromTileLayer(CALayer *tileLayer);
static CALayer *Hider_FindTileLayerInIvars(id obj);
static BOOL Hider_ObjectHasIvarPointingTo(id obj, id target, Class stopClass);
static void Hider_SendDockTileCommand(id tile, int command);
static void Hider_PostDockPrefsChangedNotification(void);
static void Hider_CoreDockSetHiddenBundle(NSString *bundleID, BOOL hidden);
static void Hider_CoreDockRefreshBundle(NSString *bundleID);
static BOOL Hider_ApplyModelHiddenForBundle(NSString *bundleID,
                                            NSString *source);
static void Hider_ApplyAuthoritativeHiddenAppsModelState(NSString *source);
static void Hider_ApplyCoreDockHiddenState(void);
static void refresh_dock(void);
static void Hider_RunAndScheduleMainQueuePasses(dispatch_block_t block,
                                                BOOL runImmediately,
                                                const int64_t *delays,
                                                NSUInteger count);
static void Hider_ScheduleHotloadPasses(BOOL runImmediately,
                                        const int64_t *delays,
                                        NSUInteger count);
static void Hider_ScheduleAppEnforcementPasses(NSString * _Nullable bid,
                                               pid_t pid,
                                               BOOL runImmediately,
                                               BOOL requestRemoval,
                                               const int64_t *delays,
                                               NSUInteger count);
void HiderBridgeRefreshDock(void);
NSString *HiderBridgeResolveTileBundleID(id tile);

void swizzleCALayer(void);
void swizzleNSView(void);
void swizzleDockCoreClasses(void);

// PID-based tile discovery (fallback for when Hider_GetBundleID fails)
// Layer Dumper
void Hider_DumpLayer(CALayer *layer, int depth, NSMutableString *output);
void Hider_DumpDockHierarchy(void);
void Hider_DumpDockClasses(void);

#pragma mark - Utils Implementation

static BOOL Hider_ShouldWriteLogLine(NSString *logMsg,
                                     NSString **summaryLineOut) {
  static uint64_t s_windowStartMs = 0;
  static NSUInteger s_windowCount = 0;
  static NSUInteger s_suppressedCount = 0;
  static NSMutableDictionary<NSString *, NSNumber *> *s_lastMessageTimes = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    s_lastMessageTimes = [NSMutableDictionary dictionary];
  });

  if (summaryLineOut) *summaryLineOut = nil;

  uint64_t nowMs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
  @synchronized([NSProcessInfo processInfo]) {
    if (s_windowStartMs == 0 || nowMs - s_windowStartMs >= 5000) {
      if (summaryLineOut && s_suppressedCount > 0) {
        *summaryLineOut = [NSString
            stringWithFormat:@"%llu.000 [Hider_LogToFile:0] log throttle suppressed %lu line(s) in previous window",
                             (unsigned long long)(nowMs / 1000ULL),
                             (unsigned long)s_suppressedCount];
      }
      s_windowStartMs = nowMs;
      s_windowCount = 0;
      s_suppressedCount = 0;
    }

    // Global rate limit: enough for startup diagnostics, but far below the
    // volume that previously drove Dock into multi-GB disk writes.
    if (s_windowCount >= 40) {
      s_suppressedCount++;
      return NO;
    }

    // Collapse identical noisy messages to one write every 1200 ms.
    if (logMsg.length > 0) {
      NSNumber *lastTime = s_lastMessageTimes[logMsg];
      if (lastTime && nowMs - lastTime.unsignedLongLongValue < 1200) {
        s_suppressedCount++;
        return NO;
      }
      s_lastMessageTimes[logMsg] = @(nowMs);
    }

    s_windowCount++;
    return YES;
  }
}

void Hider_LogToFile(const char *func, int line, NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *logMsg = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  NSString *summaryLine = nil;
  if (!Hider_ShouldWriteLogLine(logMsg, &summaryLine)) return;

  FILE *logFile = fopen("/tmp/hider.log", "a");
  if (!logFile) return;

  // Timestamp prefix for easy correlation with LLDB output.
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  long ms = ts.tv_nsec / 1000000L;
  NSString *fullMsg = [NSString stringWithFormat:@"%ld.%03ld [%s:%d] %@",
                       (long)ts.tv_sec, ms, func, line, logMsg];
  if (summaryLine.length > 0) {
    fprintf(logFile, "%s\n", summaryLine.UTF8String);
  }
  fprintf(logFile, "%s\n", fullMsg.UTF8String);
  fflush(logFile);
  fclose(logFile);
}

// ---------------------------------------------------------------------------
// Signal trap — writes a crash header to /tmp/hider.log immediately when
// Dock receives a fatal signal (SIGSEGV, SIGBUS, SIGABRT, SIGILL).
// This captures "last known state" log lines that were written just before
// the crash, making it easy to correlate with the LLDB backtrace.
// ---------------------------------------------------------------------------
static struct sigaction Hider_prevSIGSEGV, Hider_prevSIGBUS,
                        Hider_prevSIGABRT, Hider_prevSIGILL;

static void Hider_SignalTrap(int sig, siginfo_t *info, void *ctx __unused) {
  // Use only async-signal-safe calls.
  const char *sigName = (sig == SIGSEGV) ? "SIGSEGV" :
                        (sig == SIGBUS)  ? "SIGBUS"  :
                        (sig == SIGABRT) ? "SIGABRT" :
                        (sig == SIGILL)  ? "SIGILL"  : "SIG???";

  // Capture a raw backtrace (async-signal-safe).
  void *frames[32];
  int count = backtrace(frames, 32);

  // Write crash banner to log (open/write/close are signal-safe).
  FILE *f = fopen("/tmp/hider.log", "a");
  if (f) {
    fprintf(f, "\n");
    fprintf(f, "====================================================\n");
    fprintf(f, "HIDER SIGNAL TRAP: %s (signal %d)\n", sigName, sig);
    if (info) {
      fprintf(f, "  fault address: %p\n", info->si_addr);
      fprintf(f, "  sender pid:    %d\n", info->si_pid);
    }
    fprintf(f, "  raw backtrace (%d frames):\n", count);
    // backtrace_symbols_fd is async-signal-safe.
    backtrace_symbols_fd(frames, count, fileno(f));
    fprintf(f, "====================================================\n\n");
    fflush(f);
    fclose(f);
  }

  // Re-raise to the original handler so the OS can produce a crash report.
  struct sigaction *prev = (sig == SIGSEGV) ? &Hider_prevSIGSEGV :
                           (sig == SIGBUS)  ? &Hider_prevSIGBUS  :
                           (sig == SIGABRT) ? &Hider_prevSIGABRT :
                                              &Hider_prevSIGILL;
  sigaction(sig, prev, NULL);
  raise(sig);
}

static void Hider_InstallSignalTrap(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = Hider_SignalTrap;
  sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
  sigemptyset(&sa.sa_mask);

  sigaction(SIGSEGV, &sa, &Hider_prevSIGSEGV);
  sigaction(SIGBUS,  &sa, &Hider_prevSIGBUS);
  sigaction(SIGABRT, &sa, &Hider_prevSIGABRT);
  sigaction(SIGILL,  &sa, &Hider_prevSIGILL);
}

static NSMutableDictionary<NSString *, NSNumber *> *g_hiderDockOriginalIMPs = nil;
static CFMutableSetRef g_hiderSeparatorTileClasses = NULL;

static NSString *HiderDockHookKey(Class cls, SEL sel) {
  if (!cls || !sel) return nil;
  return [NSString stringWithFormat:@"%@/%@", NSStringFromClass(cls),
                                    NSStringFromSelector(sel)];
}

static void HiderRememberDockOriginalIMP(Class cls, SEL sel, IMP imp) {
  NSString *key = HiderDockHookKey(cls, sel);
  if (!key || !imp) return;
  if (!g_hiderDockOriginalIMPs) {
    g_hiderDockOriginalIMPs = [NSMutableDictionary dictionary];
  }
  g_hiderDockOriginalIMPs[key] = @((uintptr_t)imp);
}

static IMP HiderDockOriginalIMP(id object, SEL sel) {
  if (!object || !sel || !g_hiderDockOriginalIMPs) return NULL;

  Class cls = object_getClass(object);
  while (cls) {
    NSNumber *boxed = g_hiderDockOriginalIMPs[HiderDockHookKey(cls, sel)];
    if (boxed) return (IMP)(uintptr_t)boxed.unsignedLongLongValue;
    cls = class_getSuperclass(cls);
  }
  return NULL;
}

static BOOL HiderInstallConcreteDockHook(Class cls, SEL sel, IMP replacement) {
  if (!cls || !sel || !replacement) return NO;

  Method method = class_getInstanceMethod(cls, sel);
  if (!method) return NO;

  const char *types = method_getTypeEncoding(method);
  IMP inheritedIMP = method_getImplementation(method);
  if (class_addMethod(cls, sel, inheritedIMP, types)) {
    method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
  }

  IMP originalIMP = method_setImplementation(method, replacement);
  HiderRememberDockOriginalIMP(cls, sel, originalIMP);
  return YES;
}

static void HiderRegisterSeparatorTileClass(Class cls) {
  if (!cls) return;
  if (!g_hiderSeparatorTileClasses) {
    g_hiderSeparatorTileClasses = CFSetCreateMutable(NULL, 0, NULL);
  }
  if (!g_hiderSeparatorTileClasses) return;
  CFSetAddValue(g_hiderSeparatorTileClasses, (__bridge const void *)cls);
}

static BOOL HiderClassIsSeparatorTileClass(Class cls) {
  if (!cls || !g_hiderSeparatorTileClasses) return NO;
  return (BOOL)CFSetContainsValue(g_hiderSeparatorTileClasses,
                                  (__bridge const void *)cls);
}

__attribute__((unused))
static void HiderRootLayerAddSublayerHook(CALayer *self, SEL _cmd,
                                          CALayer *sub) {
  HiderCALayerIMP originalIMP = (HiderCALayerIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;
  if (Hider_ShouldBlockTileLayer(sub)) return;
  originalIMP(self, _cmd, sub);
}

__attribute__((unused))
static void HiderRootLayerInsertSublayerAtIndexHook(CALayer *self, SEL _cmd,
                                                    CALayer *sub,
                                                    unsigned int idx) {
  HiderCALayerIndexIMP originalIMP =
      (HiderCALayerIndexIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;
  if (Hider_ShouldBlockTileLayer(sub)) return;
  originalIMP(self, _cmd, sub, idx);
}

__attribute__((unused))
static void HiderRootLayerInsertSublayerBelowHook(CALayer *self, SEL _cmd,
                                                  CALayer *sub, CALayer *sib) {
  HiderCALayerSiblingIMP originalIMP =
      (HiderCALayerSiblingIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;
  if (Hider_ShouldBlockTileLayer(sub)) return;
  originalIMP(self, _cmd, sub, sib);
}

__attribute__((unused))
static void HiderRootLayerInsertSublayerAboveHook(CALayer *self, SEL _cmd,
                                                  CALayer *sub, CALayer *sib) {
  HiderCALayerSiblingIMP originalIMP =
      (HiderCALayerSiblingIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;
  if (Hider_ShouldBlockTileLayer(sub)) return;
  originalIMP(self, _cmd, sub, sib);
}

__attribute__((unused))
static void HiderRootLayerSetSublayersHook(CALayer *self, SEL _cmd,
                                           NSArray<CALayer *> *subs) {
  HiderNSArrayIMP originalIMP = (HiderNSArrayIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  if (g_hiddenAppBundleIDs.count == 0 || !subs.count) {
    originalIMP(self, _cmd, subs);
    return;
  }

  NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:subs.count];
  NSMutableArray<NSValue *> *blockedTileRects = [NSMutableArray array];
  for (CALayer *sub in subs) {
    if (Hider_ShouldBlockTileLayer(sub)) {
      [blockedTileRects addObject:[NSValue valueWithRect:sub.frame]];
      continue;
    }
    if (Hider_ShouldBlockIndicatorLayerForHiddenTiles(sub, blockedTileRects))
      continue;
    [filtered addObject:sub];
  }
  originalIMP(self, _cmd, filtered);
}

static void HiderConfiguredTileBoolPostHook(id self, SEL _cmd, BOOL value) {
  HiderBoolIMP originalIMP = (HiderBoolIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;
  originalIMP(self, _cmd, value);
  Hider_SuppressConfiguredTileIfHidden(self);
}

static void HiderConfiguredTileVoidPostHook(id self, SEL _cmd) {
  HiderVoidIMP originalIMP = (HiderVoidIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;
  originalIMP(self, _cmd);
  Hider_SuppressConfiguredTileIfHidden(self);
}

static void HiderRuntimeSwizzleBoolSelectorsForConfiguredTileSuppression(
    Class cls, NSArray<NSString *> *selectorNames) {
  for (NSString *selName in selectorNames) {
    SEL sel = NSSelectorFromString(selName);
    (void)HiderInstallConcreteDockHook(cls, sel,
                                       (IMP)HiderConfiguredTileBoolPostHook);
  }
}

static void HiderRuntimeSwizzleVoidSelectorsForConfiguredTileSuppression(
    Class cls, NSArray<NSString *> *selectorNames) {
  for (NSString *selName in selectorNames) {
    SEL sel = NSSelectorFromString(selName);
    (void)HiderInstallConcreteDockHook(cls, sel,
                                       (IMP)HiderConfiguredTileVoidPostHook);
  }
}

BOOL Hider_IsFinder(NSString *bundleID) {
  return bundleID && [bundleID isEqualToString:@"com.apple.finder"];
}

BOOL Hider_IsTrash(NSString *bundleID) {
  // Use the constant defined in tweak.h for consistency with CoreDock calls.
  return bundleID && [bundleID isEqualToString:(__bridge NSString *)kCoreDockTrashBundleID];
}


static NSString *Hider_NormalizeBundleID(NSString *bid) {
  if (!bid) return nil;
  
  // Fast path: check if already normalized (no uppercase, no whitespace).
  // This avoids redundant string allocations in high-frequency hooks.
  const char *str = [bid UTF8String];
  if (str) {
      BOOL alreadyNormalized = YES;
      for (const char *p = str; *p; p++) {
          if ((*p >= 'A' && *p <= 'Z') || isspace(*p)) {
              alreadyNormalized = NO;
              break;
          }
      }
      if (alreadyNormalized) return bid;
  }

  NSString *trimmed = [bid stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [trimmed lowercaseString];
}

static NSString *Hider_BundleIDFromDockPersistentItem(id item) {
  if (![item isKindOfClass:[NSDictionary class]]) return nil;
  NSDictionary *entry = (NSDictionary *)item;
  NSDictionary *tileData = [entry[@"tile-data"] isKindOfClass:[NSDictionary class]]
                               ? entry[@"tile-data"]
                               : nil;
  if (!tileData) return nil;

  id rawBidObj = tileData[@"bundle-identifier"];
  if ([rawBidObj isKindOfClass:[NSString class]]) {
    NSString *rawBid = (NSString *)rawBidObj;
    if (rawBid.length > 0) return Hider_NormalizeBundleID(rawBid);
  }

  NSDictionary *fileData = [tileData[@"file-data"] isKindOfClass:[NSDictionary class]]
                               ? tileData[@"file-data"]
                               : nil;
  id urlStringObj = fileData[@"_CFURLString"];
  if ([urlStringObj isKindOfClass:[NSString class]]) {
    NSString *urlString = (NSString *)urlStringObj;
    if (urlString.length == 0) return nil;
    NSURL *u = [NSURL URLWithString:urlString];
    if (u && u.isFileURL) {
      NSBundle *b = [NSBundle bundleWithURL:u];
      if (b.bundleIdentifier.length > 0) {
        return Hider_NormalizeBundleID(b.bundleIdentifier);
      }
    }
  }

  return nil;
}



static NSString *Hider_ResolveTileBundleID(id tile) {
  if (!tile) return nil;
  static __thread BOOL in_resolve = NO;
  if (in_resolve) return nil;
  in_resolve = YES;
  NSString *bid = nil;
  @try {
    bid = objc_getAssociatedObject(tile, &kHiderBundleIDTag);
    if (!bid) {
      bid = Hider_NormalizeBundleID(Hider_GetBundleID(tile));
      if (bid) {
        LOG_TO_FILE("ResolveTileBundleID: direct=%@ class=%s", bid,
                    class_getName([tile class]));
      }
    }
    if (!bid) {
      bid = Hider_ResolveBundleIDByPID(tile);
      if (bid) {
        LOG_TO_FILE("ResolveTileBundleID: pid-fallback=%@ class=%s", bid,
                    class_getName([tile class]));
      }
    }
    if (bid) {
      Hider_RegisterTile(tile, bid);
    }
  } @finally {
    in_resolve = NO;
  }
  return bid;
}

static void Hider_TrackResolvedTile(id tile, NSString *bundleID) {
  if (!tile || !bundleID) return;
  if (Hider_IsFinder(bundleID)) {
    g_finderTileObject = tile;
    return;
  }
  if (Hider_IsTrash(bundleID)) {
    g_trashTileObject = tile;
    return;
  }
  Hider_RegisterTile(tile, bundleID);
}

// Force the tile model toward "not running / not app-like / pending removal"
// without issuing doCommand:1004 for custom hidden apps.
static void Hider_DemoteTileModelForHiddenApp(id tile, NSString *bundleID) {
  if (!tile || !bundleID.length) return;
  Hider_RunOnce(tile, &kHiderTileDemotedKey, ^{
    LOG_TO_FILE("DemoteTileModel: %@ class=%s", bundleID,
                class_getName([tile class]));
    // Hard-state booleans that influence Dock running/app treatment.
    NSArray<NSString *> *falseSelectors = @[
      @"setValid:", @"setRunning:", @"setIsRunning:",
      @"setActive:", @"setIsActive:", @"setLaunching:",
      @"setVisible:", @"setHighlighted:", @"setNeedsAttention:",
      @"setShowsIndicator:", @"setShowIndicator:",
    ];
    for (NSString *name in falseSelectors) {
      SEL s = NSSelectorFromString(name);
      (void)Hider_InvokeBoolSetter(tile, s, NO);
    }

    // Some Tile subclasses expose an explicit process-mode transition.
    SEL actSel = NSSelectorFromString(@"actAsProcess:");
    (void)Hider_InvokeBoolSetter(tile, actSel, NO);
    SEL stopActSel = NSSelectorFromString(@"stopActingAsProcess");
    (void)Hider_InvokeVoidNoArg(tile, stopActSel);
    // NOTE: avoid removal/render lifecycle calls here (removeLayer,
    // willBeRemovedFromDock, render/update). These can re-enter Dock model
    // mutation while SwiftUI/layout is mid-transaction and cause hangs.
  });
}

static void Hider_ApplyHiddenTilePipeline(id tile, NSString * _Nullable bundleID,
                                          BOOL requestRemoval __unused) {
  if (!tile) return;
  static __thread BOOL in_pipeline = NO;
  if (in_pipeline) return;
  in_pipeline = YES;

  NSString *resolved = bundleID ? bundleID : Hider_ResolveTileBundleID(tile);
  if (!resolved) { in_pipeline = NO; return; }

  Hider_TrackResolvedTile(tile, resolved);
  if (!Hider_IsCustomHiddenApp(resolved)) { in_pipeline = NO; return; }

  Hider_DemoteTileModelForHiddenApp(tile, resolved);

  // Idempotency check: if already suppressed, don't re-run expensive render suppression.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  if (tile) {
      CALayer *checkLayer = nil;
      SEL ls = @selector(layer);
      if ([tile respondsToSelector:ls]) {
          id l = [tile performSelector:ls];
          if ([l isKindOfClass:[CALayer class]])
            checkLayer = (CALayer *)l;
      }
      if (!checkLayer && ![tile isKindOfClass:[CALayer class]]) {
          __block CALayer *found = nil;
          void (^findLayer)(CALayer *) = ^(CALayer *floor) {
            if (!floor || found) return;
            for (CALayer *sub in Hider_CopySublayersSnapshot(floor)) {
              if (sub.delegate == tile) { found = sub; return; }
            }
          };
          findLayer(g_modernFloorLayer);
          findLayer(g_legacyFloorLayer);
          checkLayer = found;
      }
      if (checkLayer && checkLayer.hidden && checkLayer.opacity == 0.0f) {
          in_pipeline = NO;
          return;
      }
  }
#pragma clang diagnostic pop

  // Custom hidden apps stay on the visual-only path. Dock will try to recreate
  // running tiles through addProcessForASN:separatorIndex: during launch and
  // launch-complete handling, so removing the running tile from DockBar's model
  // still destabilizes separator bookkeeping. CoreDock prefs + root-layer
  // blocking remain the authoritative hide mechanism; this pipeline only keeps
  // the live tile visually suppressed.
  Hider_SuppressTileRender(tile);
  Hider_HideTileDecorations(tile);
  Hider_HideRootLayerTile(resolved);

  in_pipeline = NO;
}

static void Hider_DeferForceRemoveHiddenTile(id tile, NSString *bundleID,
                                             int64_t delayMs) {
  if (!tile || !bundleID.length || !Hider_IsCustomHiddenApp(bundleID)) return;
  __weak id weakTile = tile;
  NSString *bidCopy = [bundleID copy];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayMs * (int64_t)NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   id strongTile = weakTile;
                   if (!strongTile) return;
                   // Deferred pass: keep custom hidden apps visually suppressed
                   // after Dock finishes its current insertion/reconciliation
                   // transaction, but do not remove the running tile from DockBar.
                   Hider_ApplyHiddenTilePipeline(strongTile, bidCopy, NO);
                 });
}

BOOL Hider_IsCustomHiddenApp(NSString *bundleID) {
  if (!bundleID || !g_hiddenAppBundleIDs) return NO;
  NSString *normalized = Hider_NormalizeBundleID(bundleID);
  if (!normalized) return NO;
  if (Hider_IsFinder(normalized) || Hider_IsTrash(normalized)) return NO;
  return [g_hiddenAppBundleIDs containsObject:normalized];
}

// Normalize an array of bundle-ID strings into a set.
static NSSet *Hider_NormalizeSet(NSArray *arr) {
  NSMutableSet *s = [NSMutableSet setWithCapacity:arr.count];
  for (NSString *bid in arr) {
    NSString *n = Hider_NormalizeBundleID(bid);
    if (n.length > 0) [s addObject:n];
  }
  return [s copy];
}

// Read hiddenApps plist array from our prefs domain (with disk sync).
static void Hider_LoadCustomAppsFromPrefs(void) {
  CFPropertyListRef raw = CFPreferencesCopyAppValue(
      CFSTR("hiddenApps"), CFSTR("com.aspauldingcode.hider"));
  if (raw) {
    if (CFGetTypeID(raw) == CFArrayGetTypeID()) {
      NSArray *arr = (__bridge_transfer NSArray *)raw;
      g_hiddenAppBundleIDs = Hider_NormalizeSet(arr);
    } else {
      CFRelease(raw);
      g_hiddenAppBundleIDs = [NSSet set];
    }
  } else {
    g_hiddenAppBundleIDs = [NSSet set];
  }
  LOG_TO_FILE("Custom hidden apps: %lu", (unsigned long)g_hiddenAppBundleIDs.count);
}

// Fast cache read (no disk sync) – safe to call from layout hooks.
static void Hider_LoadCustomAppsFromCache(void) {
  CFPropertyListRef raw = CFPreferencesCopyAppValue(
      CFSTR("hiddenApps"), CFSTR("com.aspauldingcode.hider"));
  if (raw) {
    if (CFGetTypeID(raw) == CFArrayGetTypeID()) {
      NSArray *arr = (__bridge_transfer NSArray *)raw;
      g_hiddenAppBundleIDs = Hider_NormalizeSet(arr);
    } else {
      CFRelease(raw);
    }
  }
  if (!g_hiddenAppBundleIDs)
    g_hiddenAppBundleIDs = [NSSet set];
}

NSString *Hider_GetBundleID(id obj) {
  if (!obj) return nil;

  // Guard against recursion during logging/selector probes.
  static __thread BOOL in_get_bundle_id = NO;
  if (in_get_bundle_id) return nil;
  in_get_bundle_id = YES;

  NSString *bundleID = nil;

  @try {

  id (^safeObjectCall)(id, SEL) = ^id(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 2) return nil;
    const char *ret = sig.methodReturnType;
    if (!ret || ret[0] != '@') return nil;
    @try {
      return ((id (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (__unused NSException *e) {
      return nil;
    }
  };

  // Keep probing narrowly scoped to avoid invalid-object crashes from deep
  // Dock model walks. We rely on PID fallback when these selectors are absent.
  NSMutableArray *candidates = [NSMutableArray arrayWithObject:obj];
  id delegate = safeObjectCall(obj, @selector(delegate));
  if (delegate) [candidates addObject:delegate];
  id represented = safeObjectCall(obj, @selector(representedObject));
  if (represented) [candidates addObject:represented];

  for (id c in candidates) {
    if (!c) continue;

    NSString *cn = NSStringFromClass([c class]);
    if ([cn isEqualToString:@"DOCKTrashTile"]) {
      bundleID = @"com.apple.trash";
      break;
    }
    if ([cn isEqualToString:@"DOCKDesktopTile"]) {
      bundleID = @"com.apple.finder";
      break;
    }

    NSArray<NSString *> *stringSelectors = @[
      @"bundleIdentifier", @"bundleID",
      @"applicationBundleIdentifier", @"appBundleID"
    ];
    for (NSString *name in stringSelectors) {
      id v = safeObjectCall(c, NSSelectorFromString(name));
      if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
        bundleID = (NSString *)v;
        break;
      }
    }
    if (bundleID) break;

    NSArray<NSString *> *appSelectors = @[@"application", @"runningApplication"];
    for (NSString *name in appSelectors) {
      id ra = safeObjectCall(c, NSSelectorFromString(name));
      if ([ra isKindOfClass:[NSRunningApplication class]]) {
        NSString *bid = [(NSRunningApplication *)ra bundleIdentifier];
        if (bid.length > 0) {
          bundleID = bid;
          break;
        }
      }
    }
    if (bundleID) break;

    NSArray<NSString *> *urlSelectors = @[@"fileURL", @"url", @"URL"];
    for (NSString *name in urlSelectors) {
      id u = safeObjectCall(c, NSSelectorFromString(name));
      if ([u isKindOfClass:[NSURL class]]) {
        NSBundle *b = [NSBundle bundleWithURL:(NSURL *)u];
        if (b.bundleIdentifier.length > 0) {
          bundleID = b.bundleIdentifier;
          break;
        }
      }
    }
    if (bundleID) break;
  }

  } @finally {
    in_get_bundle_id = NO;
  }
  return bundleID;
}

BOOL Hider_IsSeparatorTileLayer(id obj) {
  if (!obj)
    return NO;
  id current = obj;
  // NASA Rule 2: Upper bound on loop to prevent infinite walks.
  for (int i = 0; i < 10 && current; i++) {
    const char *name = class_getName([current class]);
    if (name && (strcmp(name, "DOCKSeparatorTile") == 0 ||
                 strcmp(name, "DOCKSpacerTile") == 0)) {
      return YES;
    }
    if ([current respondsToSelector:@selector(delegate)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      id d = [current performSelector:@selector(delegate)];
#pragma clang diagnostic pop
      if (d) {
        const char *dName = class_getName([d class]);
        if (dName && (strcmp(dName, "DOCKSeparatorTile") == 0 ||
                      strcmp(dName, "DOCKSpacerTile") == 0)) {
          return YES;
        }
      }
    }
    if ([current isKindOfClass:[CALayer class]])
      current = [(CALayer *)current superlayer];
    else if ([current isKindOfClass:[NSView class]])
      current = [(NSView *)current superview];
    else
      break;
  }
  return NO;
}

void Hider_RunOnce(id object, const void *key, void (^block)(void)) {
  if (!object || !key || !block)
    return;

  if (!objc_getAssociatedObject(object, key)) {
    objc_setAssociatedObject(object, key, @(YES),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    block();
  }
}

#pragma mark - Tile Registry + Enforcement Helpers

static void Hider_RegisterTile(id tile, NSString *bid) {
  if (!tile || !bid) return;
  NSString *normalized = Hider_NormalizeBundleID(bid);
  if (!normalized || normalized.length == 0) return;

  // Tag the tile model with its bundleID for layer-hook reverse-lookup.
  objc_setAssociatedObject(tile, &kHiderBundleIDTag, normalized,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  if (!g_customAppTileObjects)
    g_customAppTileObjects = [NSMapTable strongToWeakObjectsMapTable];
  [g_customAppTileObjects setObject:tile forKey:normalized];
}

static NSString *Hider_ResolveBundleIDForLayer(CALayer *layer) {
  if (!layer) return nil;

  const char *cn = class_getName([layer class]);
  if (cn && strcmp(cn, "DOCKTileLayer") == 0) {
    NSString *tileLayerBid = Hider_BundleIDFromTileLayer(layer);
    if (tileLayerBid.length > 0) return tileLayerBid;
  }

  // Fast path: direct probe.
  NSString *bid = Hider_GetBundleID(layer);
  if (bid) return Hider_NormalizeBundleID(bid);

  // Reverse-lookup via associated-object tag on the delegate.
  id delegate = layer.delegate;
  if (delegate) {
    bid = objc_getAssociatedObject(delegate, &kHiderBundleIDTag);
    if (bid) return bid;
  }

  // Pointer-comparison fallback through g_customAppTileObjects.
  if (delegate && g_customAppTileObjects && g_hiddenAppBundleIDs.count > 0) {
    NSSet *hiddenSnap = [g_hiddenAppBundleIDs copy];
    for (NSString *trackedBid in hiddenSnap) {
      if ([g_customAppTileObjects objectForKey:trackedBid] == delegate)
        return trackedBid;
    }
  }
  return nil;
}

// Resolve a hidden-app's bundle ID from a tile-model object's PID.
// When Hider_GetBundleID and associated-object tags all fail, this is the
// last resort: extract the process ID from the delegate, look it up via
// NSRunningApplication, and check against the hidden-app list.
// On success the tile is registered for future fast-path lookups.
static NSString *Hider_ResolveBundleIDByPID(id delegate) {
  if (!delegate || g_hiddenAppBundleIDs.count == 0) return nil;

  // NSXPCConnection responds to -processIdentifier but calls
  // xpc_connection_get_pid on an uninitialised session during Dock's early
  // LaunchServices setup, triggering _xpc_api_misuse. Skip all XPC objects.
  static Class xpcCls = nil;
  static dispatch_once_t xpcOnce;
  dispatch_once(&xpcOnce, ^{ xpcCls = NSClassFromString(@"NSXPCConnection"); });
  if (xpcCls && [delegate isKindOfClass:xpcCls]) return nil;

  // Only probe objects from DockCore — probing arbitrary ObjC objects for
  // -processIdentifier can invoke unexpected implementations.
  const char *cn = class_getName([delegate class]);
  if (!cn || (!strstr(cn, "DOCK") && !strstr(cn, "Dock") &&
              !strstr(cn, "Tile") && !strstr(cn, "Process"))) return nil;

  // Guard against recursion — some selectors may trigger layout/setHidden
  // which calls back into Hider_ShouldForceHideLayer.
  static __thread BOOL in_resolve_pid = NO;
  if (in_resolve_pid) return nil;
  in_resolve_pid = YES;

  NSString *normalized = nil;
  @try {

  pid_t tilePID = 0;
  SEL pidSels[] = {
    NSSelectorFromString(@"processIdentifier"),
    NSSelectorFromString(@"pid"),
    NSSelectorFromString(@"_pid"),
  };
  for (int i = 0; i < 3 && tilePID <= 0; i++) {
    if ([delegate respondsToSelector:pidSels[i]])
      tilePID = (pid_t)((int (*)(id, SEL))objc_msgSend)(delegate, pidSels[i]);
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  if (tilePID <= 0) {
    SEL appSel = NSSelectorFromString(@"application");
    if ([delegate respondsToSelector:appSel]) {
      id ra = [delegate performSelector:appSel];
      if ([ra isKindOfClass:[NSRunningApplication class]])
        tilePID = [(NSRunningApplication *)ra processIdentifier];
    }
  }
  if (tilePID <= 0) {
    SEL raSel = NSSelectorFromString(@"runningApplication");
    if ([delegate respondsToSelector:raSel]) {
      id ra = [delegate performSelector:raSel];
      if ([ra isKindOfClass:[NSRunningApplication class]])
        tilePID = [(NSRunningApplication *)ra processIdentifier];
    }
  }
  if (tilePID <= 0) {
    SEL itemSel = NSSelectorFromString(@"item");
    SEL modelSel = NSSelectorFromString(@"model");
    id nested = nil;
    if ([delegate respondsToSelector:itemSel])
      nested = [delegate performSelector:itemSel];
    else if ([delegate respondsToSelector:modelSel])
      nested = [delegate performSelector:modelSel];
    if (nested) {
      for (int i = 0; i < 3 && tilePID <= 0; i++) {
        if ([nested respondsToSelector:pidSels[i]])
          tilePID = (pid_t)((int (*)(id, SEL))objc_msgSend)(nested, pidSels[i]);
      }
    }
  }
#pragma clang diagnostic pop

  if (tilePID > 0) {
    NSRunningApplication *ra =
        [NSRunningApplication runningApplicationWithProcessIdentifier:tilePID];
    if (ra && ra.bundleIdentifier)
      normalized = Hider_NormalizeBundleID(ra.bundleIdentifier);
  }

  } @finally {
    in_resolve_pid = NO;
  }
  return normalized;
}

// Fast O(1) check: does this layer's delegate have a tracked hidden-app tag?
// Used as a broad net in generic CALayer hooks when DOCKTileLayer doesn't exist.
static BOOL Hider_DelegateIsHiddenApp(CALayer *layer) {
  if (!layer || g_hiddenAppBundleIDs.count == 0) return NO;
  id delegate = layer.delegate;
  if (!delegate) return NO;
  NSString *bid = objc_getAssociatedObject(delegate, &kHiderBundleIDTag);
  if (bid && Hider_IsCustomHiddenApp(bid)) return YES;
  // Also check the layer itself (it might be the tile object in some hierarchies).
  bid = objc_getAssociatedObject(layer, &kHiderBundleIDTag);
  return bid && Hider_IsCustomHiddenApp(bid);
}

static BOOL Hider_ShouldForceHideLayer(CALayer *layer) {
  if (!layer) return NO;

  NSNumber *cached = objc_getAssociatedObject(layer, &kHiderForcedHiddenCache);
  if (cached) return [cached boolValue];

  BOOL shouldHide = NO;
  BOOL identityKnown = NO;
  NSString *bid = Hider_ResolveBundleIDForLayer(layer);
  if (bid) {
    identityKnown = YES;
    if ((Hider_IsFinder(bid) && finderHidden) ||
        (Hider_IsTrash(bid) && trashHidden) ||
        Hider_IsCustomHiddenApp(bid)) {
      shouldHide = YES;
    }
  }

  if (!shouldHide && !bid && g_hiddenAppBundleIDs.count > 0) {
    id delegate = layer.delegate;
    if (delegate) {
      NSString *pidBid = Hider_ResolveBundleIDByPID(delegate);
      if (pidBid) {
        identityKnown = YES;
        if (Hider_IsCustomHiddenApp(pidBid))
          shouldHide = YES;
      }
    }
  }

  // Only cache when we got a definitive answer.  When the tile's identity
  // can't be resolved yet (newly-created process tile still initializing),
  // skip caching so the next call re-attempts resolution instead of sticking
  // with a stale NO that lets the Dock re-show the icon.
  if (shouldHide || identityKnown) {
    objc_setAssociatedObject(layer, &kHiderForcedHiddenCache, @(shouldHide),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return shouldHide;
}

// Flush the per-layer hide/show cache on all known tile layers and request a
// layout pass.  Must be called whenever g_hiddenAppBundleIDs, finderHidden, or
// trashHidden changes so DOCKTileLayer hooks re-evaluate against the new set.
static void Hider_InvalidateLayerCaches(void) {
  void (^clearFloorCaches)(CALayer *) = ^(CALayer *floor) {
    if (!floor) return;
    NSArray<CALayer *> *subs = Hider_CopySublayersSnapshot(floor);
    for (CALayer *sub in subs) {
      objc_setAssociatedObject(sub, &kHiderForcedHiddenCache, nil,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      [sub setNeedsLayout];
      for (CALayer *child in Hider_CopySublayersSnapshot(sub)) {
        objc_setAssociatedObject(child, &kHiderForcedHiddenCache, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      }
    }
    [floor setNeedsLayout];
  };
  clearFloorCaches(g_modernFloorLayer);
  clearFloorCaches(g_legacyFloorLayer);

  if (g_customAppTileObjects) {
    NSArray *trackedBIDs = nil;
    @try {
      trackedBIDs = [[g_customAppTileObjects keyEnumerator] allObjects];
    } @catch (NSException *) {
      trackedBIDs = nil;
    }
    for (NSString *bid in trackedBIDs) {
      id tile = [g_customAppTileObjects objectForKey:bid];
      if (!tile) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      SEL ls = @selector(layer);
      if ([tile respondsToSelector:ls]) {
        id l = [tile performSelector:ls];
        if ([l isKindOfClass:[CALayer class]]) {
          objc_setAssociatedObject((CALayer *)l, &kHiderForcedHiddenCache, nil,
                                   OBJC_ASSOCIATION_RETAIN_NONATOMIC);
          [(CALayer *)l setNeedsLayout];
        }
      }
#pragma clang diagnostic pop
    }
  }
}

static BOOL Hider_IsSlotSuppressed(CALayer *layer) {
  if (!layer) return NO;
  return [objc_getAssociatedObject(layer, &kHiderSlotSuppressed) boolValue];
}

// O(1) suppression check: we propagate kHiderSlotSuppressed to all direct
// children when a slot is suppressed, so this only needs to check the layer
// itself and at most 1 ancestor (its direct parent slot container).
// An unbounded walk to root was the root cause of the Dock freeze: this
// was invoked on every setHidden:/setOpacity:/drawInContext: call in the Dock.
static BOOL Hider_IsInSuppressedSlot(CALayer *layer) {
  if (!layer) return NO;
  // Check self first (direct tag - O(1) in the common case).
  if (Hider_IsSlotSuppressed(layer)) return YES;
  // Only check one level up: the direct slot container.
  CALayer *parent = layer.superlayer;
  if (parent && Hider_IsSlotSuppressed(parent)) return YES;
  return NO;
}

// Snapshot layer.sublayers to avoid Dock mutating QuartzCore's CALayerArray
// while we recurse or suppress in the same transaction.
static NSArray<CALayer *> *Hider_CopySublayersSnapshot(CALayer *layer) {
  if (!layer) return @[];
  NSArray<CALayer *> *subs = [layer.sublayers copy];
  return subs ? subs : @[];
}


// Propagate suppression tag to a layer and all its direct children.
// This makes Hider_IsInSuppressedSlot O(1) — children check themselves
// rather than walking up the ancestor chain.
static void Hider_TagLayerSuppressed(CALayer *layer) {
  if (!layer) return;
  objc_setAssociatedObject(layer, &kHiderSlotSuppressed, @YES,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  for (CALayer *child in Hider_CopySublayersSnapshot(layer)) {
    objc_setAssociatedObject(child, &kHiderSlotSuppressed, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
}

static void Hider_SuppressSlot(CALayer *tileLayer) {
  if (!tileLayer) return;
  CALayer *slot = tileLayer.superlayer;
  if (!slot) return;

  // Early-out: slot already tagged. No work needed.
  if (objc_getAssociatedObject(slot, &kHiderSlotSuppressed)) return;

  // If tile is attached directly under a floor-layer path, suppress the tile
  // itself (and nearby decorations) rather than the slot.
  const char *scn = class_getName([slot class]);
  BOOL slotLooksLikeFloor = (slot == g_modernFloorLayer || slot == g_legacyFloorLayer ||
                             (scn && strstr(scn, "FloorLayer")));
  if (slotLooksLikeFloor) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [tileLayer removeAllAnimations];
    tileLayer.opacity = 0.0f;
    tileLayer.hidden  = YES;
    // Tag tile and its children so the O(1) check works for them.
    Hider_TagLayerSuppressed(tileLayer);
    for (CALayer *sub in Hider_CopySublayersSnapshot(tileLayer)) {
      [sub removeAllAnimations];
      sub.opacity = 0.0f;
      sub.hidden  = YES;
    }
    // Hide sibling indicators (e.g. running dot) that live in the floor.
    CGRect tileRect = [tileLayer convertRect:tileLayer.bounds toLayer:slot];
    [HiderDockActions hideIndicatorLayersNearRect:tileRect
                                          inLayer:slot
                                     excludingTree:tileLayer];
    [CATransaction commit];
    return;
  }

  // Tag the slot AND its children so they are instantly identifiable without
  // walking up the ancestor chain in setHidden:/setOpacity: hooks.
  Hider_TagLayerSuppressed(slot);

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  slot.opacity = 0.0f;
  slot.hidden  = YES;
  for (CALayer *sibling in Hider_CopySublayersSnapshot(slot)) {
    [sibling removeAllAnimations];
    sibling.opacity = 0.0f;
    sibling.hidden  = YES;
  }
  [CATransaction commit];
}

static void Hider_UnsuppressSlot(CALayer *slot) {
  if (!slot) return;
  // Clear suppression tag on the slot and all its direct children.
  // This mirrors what Hider_TagLayerSuppressed does in reverse, ensuring
  // the O(1) Hider_IsInSuppressedSlot check gives the correct answer.
  objc_setAssociatedObject(slot, &kHiderSlotSuppressed, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  slot.opacity = 1.0f;
  slot.hidden  = NO;
  for (CALayer *sub in Hider_CopySublayersSnapshot(slot)) {
    objc_setAssociatedObject(sub, &kHiderSlotSuppressed, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sub.opacity = 1.0f;
    sub.hidden  = NO;
  }
  [CATransaction commit];
}

// Collect root layers from every reachable source:
//   1. [NSApp windows]  (may be empty on modern Dock)
//   2. _orderedWindows  (private NSApplication API)
//   3. g_modernFloorLayer / g_legacyFloorLayer root chain
//   4. Layer of every tracked tile in g_customAppTileObjects
// De-duplicated by pointer identity.
static NSArray<CALayer *> *Hider_CollectRootLayers(void) {
  NSMutableSet *seen = [NSMutableSet set];
  NSMutableArray<CALayer *> *roots = [NSMutableArray array];

  void (^addRoot)(CALayer *) = ^(CALayer *r) {
    if (!r) return;
    while (r.superlayer) r = r.superlayer;
    NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)r];
    if (![seen containsObject:ptr]) {
      [seen addObject:ptr];
      [roots addObject:r];
    }
  };

  // Source 1: public NSApp windows.
  for (NSWindow *w in [NSApp windows]) {
    addRoot(w.contentView.layer);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    SEL rlSel = NSSelectorFromString(@"_rootLayer");
    if ([w respondsToSelector:rlSel])
      addRoot([w performSelector:rlSel]);
#pragma clang diagnostic pop
  }

  // Source 2: private _orderedWindows (catches Dock windows hidden from public API).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  SEL owSel = NSSelectorFromString(@"_orderedWindows");
  if ([[NSApplication sharedApplication] respondsToSelector:owSel]) {
    NSArray *privWins = [[NSApplication sharedApplication] performSelector:owSel];
    for (id w in privWins) {
      if ([w isKindOfClass:[NSWindow class]]) {
        addRoot(((NSWindow *)w).contentView.layer);
        SEL rlSel = NSSelectorFromString(@"_rootLayer");
        if ([w respondsToSelector:rlSel])
          addRoot([w performSelector:rlSel]);
      }
    }
  }
#pragma clang diagnostic pop

  // Source 3: tracked floor layers → walk up to root.
  addRoot(g_modernFloorLayer);
  addRoot(g_legacyFloorLayer);

  // Source 4: every tile in g_customAppTileObjects → layer → root.
  // NSMapTable with weak values can mutate during enumeration when a weak
  // reference is zeroed on another thread.  Guard with @try/@catch so a
  // concurrent dealloc doesn't crash; the next enforcement pass will retry.
  if (g_customAppTileObjects) {
    NSArray *trackedBIDs = nil;
    @try {
      trackedBIDs = [[g_customAppTileObjects keyEnumerator] allObjects];
    } @catch (NSException *) {
      trackedBIDs = nil;
    }
    for (NSString *bid in trackedBIDs) {
      id tile = [g_customAppTileObjects objectForKey:bid];
      if (!tile) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      if ([tile isKindOfClass:[CALayer class]])
        addRoot((CALayer *)tile);
      else if ([tile respondsToSelector:@selector(layer)])
        addRoot([tile performSelector:@selector(layer)]);
#pragma clang diagnostic pop
    }
  }

  // Source 5: Finder / Trash tile objects → layer → root.
  void (^addTileRoot)(id) = ^(id tile) {
    if (!tile) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([tile isKindOfClass:[CALayer class]])
      addRoot((CALayer *)tile);
    else if ([tile respondsToSelector:@selector(layer)])
      addRoot([tile performSelector:@selector(layer)]);
#pragma clang diagnostic pop
  };
  addTileRoot(g_finderTileObject);
  addTileRoot(g_trashTileObject);

  // Source 6: when no roots yet, recursively walk key/main window view tree.
  // Catches Dock layouts where floor layers or window contentView aren't ready.
  if (roots.count == 0) {
    NSMutableArray *stack = [NSMutableArray array];
    NSWindow *kw = [NSApp keyWindow];
    NSWindow *mw = [NSApp mainWindow];
    if (kw && kw.contentView) [stack addObject:kw.contentView];
    if (mw && mw != kw && mw.contentView) [stack addObject:mw.contentView];
    while (stack.count > 0) {
      NSView *v = [stack lastObject];
      [stack removeLastObject];
      if (v.layer) addRoot(v.layer);
      for (NSView *sub in [v.subviews copy])
        [stack addObject:sub];
    }
  }

  return roots;
}


static void Hider_HideFloorSeparators(CALayer *layer) {
  if (!layer) return;
  BOOL hideRightmostOnly = trashHidden || separatorHiddenUntilRestart;
  CALayer *rightmostSeparator = nil;
  CGFloat maxRight = -CGFLOAT_MAX;
  for (CALayer *sub in Hider_CopySublayersSnapshot(layer)) {
    const char *subClass = class_getName([sub class]);
    if (subClass && strstr(subClass, "Indicator")) continue;
    if (sub.frame.size.width > 0 && sub.frame.size.width < 25) {
      CGFloat right = sub.frame.origin.x + sub.frame.size.width;
      if (right > maxRight) {
        maxRight = right;
        rightmostSeparator = sub;
      }
    }
  }
  if (hideRightmostOnly && rightmostSeparator && !rightmostSeparator.hidden) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    rightmostSeparator.hidden = YES;
    rightmostSeparator.opacity = 0.0f;
    [CATransaction commit];
  }
}


#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
static void Hider_SuppressTileRender(id tile) {
  if (!tile) return;
  SEL ls = @selector(layer);
  if ([tile respondsToSelector:ls]) {
    id l = [tile performSelector:ls];
    if (![l isKindOfClass:[CALayer class]]) return;
    CALayer *layer = (CALayer *)l;
    if (layer.hidden && layer.opacity == 0.0f) {
      Hider_SuppressSlot(layer);
      return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer removeAllAnimations];
    layer.hidden = YES;
    layer.opacity = 0.0f;
    layer.contents = nil;
    layer.backgroundColor = NSColor.clearColor.CGColor;
    for (CALayer *sub in Hider_CopySublayersSnapshot(layer)) {
      [sub removeAllAnimations];
      sub.hidden = YES;
      sub.opacity = 0.0f;
      sub.contents = nil;
      sub.backgroundColor = NSColor.clearColor.CGColor;
    }
    [CATransaction commit];
    Hider_SuppressSlot(layer);
  } else if ([tile isKindOfClass:[CALayer class]]) {
    CALayer *l = (CALayer *)tile;
    if (l.hidden && l.opacity == 0.0f) {
      Hider_SuppressSlot(l);
      return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [l removeAllAnimations];
    l.hidden = YES;
    l.opacity = 0.0f;
    l.contents = nil;
    l.backgroundColor = NSColor.clearColor.CGColor;
    for (CALayer *sub in Hider_CopySublayersSnapshot(l)) {
      [sub removeAllAnimations];
      sub.hidden = YES;
      sub.opacity = 0.0f;
      sub.contents = nil;
      sub.backgroundColor = NSColor.clearColor.CGColor;
    }
    [CATransaction commit];
    Hider_SuppressSlot(l);
  } else {
    // Tile model object with no -layer accessor (e.g. modern DOCKProcessTile).
    // Walk floor sublayers looking for any layer whose delegate is this tile.
    void (^walkFloor)(CALayer *) = ^(CALayer *floor) {
      if (!floor) return;
      for (CALayer *sub in Hider_CopySublayersSnapshot(floor)) {
        if (sub.delegate == tile) {
          [CATransaction begin];
          [CATransaction setDisableActions:YES];
          [sub removeAllAnimations];
          sub.hidden = YES;
          sub.opacity = 0.0f;
          sub.contents = nil;
          sub.backgroundColor = NSColor.clearColor.CGColor;
          for (CALayer *child in Hider_CopySublayersSnapshot(sub)) {
            [child removeAllAnimations];
            child.hidden = YES;
            child.opacity = 0.0f;
            child.contents = nil;
            child.backgroundColor = NSColor.clearColor.CGColor;
          }
          [CATransaction commit];
          Hider_SuppressSlot(sub);
          LOG_TO_FILE("SuppressTileRender: found delegate-matched layer %s for tile %s",
                      class_getName([sub class]), class_getName([tile class]));
        }
      }
    };
    walkFloor(g_modernFloorLayer);
    walkFloor(g_legacyFloorLayer);
  }
}
#pragma clang diagnostic pop


// Internal helper for the unified walk.
static void Hider_UnifiedEnforcementWalk(CALayer *layer, NSArray<NSString *> *discoveryBIDs, NSArray<NSNumber *> *discoveryPIDs) {
  if (!layer) return;

  // Check if this layer (or its delegate) is a tile: by class name OR by
  // having a delegate that's a DOCK tile-model object.  The modern Dock
  // doesn't use DOCKTileLayer so we must also match by delegate type.
  id delegate = layer.delegate;
  const char *cn = class_getName([layer class]);
  BOOL isTileLayer = cn && (strcmp(cn, "DOCKTileLayer") == 0 ||
                            strstr(cn, "ProcessTile") ||
                            strstr(cn, "AppTile"));
  if (!isTileLayer && delegate) {
    const char *dcn = class_getName([delegate class]);
    if (dcn && strstr(dcn, "DOCK") && strstr(dcn, "Tile"))
      isTileLayer = YES;
  }

  if (isTileLayer && delegate) {
    // ── discovery pass ──────────────────────────────────────────────────
    for (NSUInteger di = 0; di < discoveryBIDs.count; di++) {
      pid_t targetPID = (pid_t)[discoveryPIDs[di] intValue];
      NSString *targetBID = discoveryBIDs[di];

      BOOL match = NO;
      SEL pidSels[] = {NSSelectorFromString(@"processIdentifier"), NSSelectorFromString(@"pid"), NSSelectorFromString(@"_pid")};
      for (int i = 0; i < 3 && !match; i++) {
        if ([delegate respondsToSelector:pidSels[i]]) {
          if (((pid_t (*)(id, SEL))objc_msgSend)(delegate, pidSels[i]) == targetPID) match = YES;
        }
      }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      if (!match) {
        NSString *tileBid = Hider_ResolveTileBundleID(delegate);
        if (tileBid && [tileBid isEqualToString:targetBID])
          match = YES;
      }
      if (!match) {
        SEL appSel = NSSelectorFromString(@"application");
        SEL raSel = NSSelectorFromString(@"runningApplication");
        id ra = nil;
        if ([delegate respondsToSelector:appSel]) ra = [delegate performSelector:appSel];
        else if ([delegate respondsToSelector:raSel]) ra = [delegate performSelector:raSel];
        if ([ra isKindOfClass:[NSRunningApplication class]] && [ra processIdentifier] == targetPID) match = YES;
      }
#pragma clang diagnostic pop

      if (match) {
        LOG_TO_FILE("Discovery: matched tile layer (%s) for %@ (PID %d)", cn, targetBID, targetPID);
        Hider_RegisterTile(delegate, targetBID);
        break;
      }
    }

    // ── visibility enforcement ──────────────────────────────────────────
    if (Hider_ShouldForceHideLayer(layer) || Hider_IsInSuppressedSlot(layer) ||
        Hider_DelegateIsHiddenApp(layer)) {
      NSString *resolved = Hider_ResolveTileBundleID(delegate);
      if (resolved.length > 0 && Hider_IsCustomHiddenApp(resolved)) {
        Hider_RegisterTile(delegate, resolved);
        Hider_DeferForceRemoveHiddenTile(delegate, resolved, 140);
      }
      [layer removeAllAnimations];
      layer.hidden  = YES;
      layer.opacity = 0.0f;
      Hider_SuppressSlot(layer);
    }
    return;
  }

  // ── container pass (floor separators) ───────────────────────────────
  if (cn && (strstr(cn, "FloorLayer") || strstr(cn, "TileContainer"))) {
    Hider_HideFloorSeparators(layer);
  }

  // ── recursion ──────────────────────────────────────────────────────
  for (CALayer *sub in Hider_CopySublayersSnapshot(layer)) {
    Hider_UnifiedEnforcementWalk(sub, discoveryBIDs, discoveryPIDs);
  }
}

// Unified enforcement: single-pass discovery, suppression, and layout.
static void Hider_EnforceHiddenApps(NSString * _Nullable singleBID, pid_t pid) {
  HIDER_LOCK();
  static __thread BOOL in_enforce = NO;
  if (in_enforce) { HIDER_UNLOCK(); return; }
  in_enforce = YES;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  // 1. Instant suppression for already-tracked tiles (O(1) lookup)
  if (g_customAppTileObjects) {
    NSSet *snap = [g_hiddenAppBundleIDs copy];
    for (NSString *bid in snap) {
      id tile = [g_customAppTileObjects objectForKey:bid];
      if (tile) {
        Hider_SuppressTileRender(tile);
        Hider_HideTileDecorations(tile);
      }
    }
  }

  // 2. Build discovery context
  NSMutableArray *discoveryBIDs = [NSMutableArray array];
  NSMutableArray *discoveryPIDs = [NSMutableArray array];
  if (singleBID && pid > 0) {
    [discoveryBIDs addObject:singleBID];
    [discoveryPIDs addObject:@(pid)];
  }
  if (g_hiddenAppBundleIDs.count > 0) {
    for (NSRunningApplication *ra in [[NSWorkspace sharedWorkspace] runningApplications]) {
      NSString *bid = Hider_NormalizeBundleID(ra.bundleIdentifier);
      if (bid && [g_hiddenAppBundleIDs containsObject:bid] && ![g_customAppTileObjects objectForKey:bid]) {
        [discoveryBIDs addObject:bid];
        [discoveryPIDs addObject:@(ra.processIdentifier)];
      }
    }
  }

  // 3. Unified Walk
  for (CALayer *root in Hider_CollectRootLayers()) {
    Hider_UnifiedEnforcementWalk(root, discoveryBIDs, discoveryPIDs);
  }

  // 4. Hide DOCKTileLayer/DOCKIndicatorLayer in the root layer for hidden apps
  Hider_HideAllRootLayerHiddenTiles();

  [CATransaction commit];
  in_enforce = NO;
  HIDER_UNLOCK();
}

// Stage hidden tracked tiles through the Dock action pipeline even when their
// lifecycle path bypasses the usual update/init hooks.
static void Hider_ScheduleTrackedHiddenTileRemovals(NSString *source) {
  if (!g_customAppTileObjects || g_hiddenAppBundleIDs.count == 0) return;
  NSString *label = source ? source : @"unknown";

  NSSet *hiddenSnap = [g_hiddenAppBundleIDs copy];
  for (NSString *bid in hiddenSnap) {
    id tile = [g_customAppTileObjects objectForKey:bid];
    if (!tile) continue;
    LOG_TO_FILE("TrackedRemoval[%@]: %@", label, bid);
    Hider_HideTileDecorations(tile);
    Hider_DeferForceRemoveHiddenTile(tile, bid, 120);
    Hider_DeferForceRemoveHiddenTile(tile, bid, 320);
  }
}

// Immediately apply hidden-app settings to both:
//   1) persistent Dock tiles (via refresh_dock caller), and
//   2) already-running apps that may currently own transient/running tiles.
// Called from settings-changed flow with short retries for SwiftUI/Dock timing.
static void Hider_HotloadHiddenAppsNow(void) {
  Hider_LoadSettingsFromCache();
  if (g_hiddenAppBundleIDs.count == 0) {
    Hider_EnforceHiddenApps(nil, 0);
    return;
  }

  NSArray *running = [[NSWorkspace sharedWorkspace] runningApplications];
  for (NSRunningApplication *app in running) {
    NSString *bid = Hider_NormalizeBundleID(app.bundleIdentifier);
    if (!bid || ![g_hiddenAppBundleIDs containsObject:bid]) continue;
    pid_t appPID = app.processIdentifier;
    Hider_EnforceHiddenApps(bid, appPID);
    id tile = [g_customAppTileObjects objectForKey:bid];
    if (tile) {
      Hider_SuppressTileRender(tile);
      Hider_HideTileDecorations(tile);
    }
  }

  Hider_EnforceHiddenApps(nil, 0);
}

// Force one hidden-running-app pass: enforce + explicit tile suppression.
// This is stronger than Hider_HotloadHiddenAppsNow alone because it reapplies
// visual suppression on every pass if a tile object is known.
//
// SETTING `enforce` to NO allows callers to skip the expensive root-layer walk
// if they already performed a broad Hider_EnforceHiddenApps pass.
static void Hider_ForceHideRunningApp(NSString * _Nullable bid, pid_t pid, BOOL enforce) {
  static NSMutableDictionary<NSString *, NSNumber *> *s_lastNoTileLogMs = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    s_lastNoTileLogMs = [NSMutableDictionary dictionary];
  });

  if (enforce)
    Hider_EnforceHiddenApps(bid, pid);
  
  if (!bid || bid.length == 0) return;

  id tile = [g_customAppTileObjects objectForKey:bid];
  if (tile) {
    LOG_TO_FILE("ForceHideRunningApp: tracked tile found for %@", bid);
    Hider_HideTileDecorations(tile);
    Hider_ApplyHiddenTilePipeline(tile, bid, NO);
  } else if (enforce) {
    // No tracked tile yet. Keep the running app on the visual discovery path
    // only; repeatedly re-applying model hidden state here can make Dock treat
    // the app as perpetually launching, which shows up as an infinite bounce.
    uint64_t nowMs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
    uint64_t lastMs = [[s_lastNoTileLogMs objectForKey:bid] unsignedLongLongValue];
    if (lastMs == 0 || nowMs - lastMs > 1200) {
      LOG_TO_FILE("ForceHideRunningApp: no tracked tile for %@ (pid=%d)", bid, pid);
      [s_lastNoTileLogMs setObject:@(nowMs) forKey:bid];
    }
    // Tile not yet cached and we just tried to discover it — schedule repeat 
    // enforcement passes so it gets picked up and suppressed once ready.
    // Keep retries on the visual discovery path only so we do not loop back
    // through ForceHideRunningApp/CoreDock on every scheduled pass.
    const int64_t delays[] = {700};
    Hider_ScheduleAppEnforcementPasses(bid, pid, NO, NO, delays, 1);
  }
}

// Compatibility wrapper for older call sites.
static void Hider_ForceHideRunningAppNow(NSString * _Nullable bid, pid_t pid) {
    Hider_ForceHideRunningApp(bid, pid, YES);
}

// Force a broad hidden-app pass over all running hidden apps, including direct
// visual suppression requests for any tile objects currently known.
static void Hider_ForceHotloadHiddenTilesNow(void) {
  Hider_HotloadHiddenAppsNow();
}

void Hider_ForceLayoutRecursive(CALayer *layer) {
  if (!layer)
    return;
  // Only invalidate layout — never setNeedsDisplay.  DOCKTileLayer renders
  // its content through the compositor pipeline (layer.contents), not via
  // drawInContext:.  Calling setNeedsDisplay triggers drawInContext: which
  // produces a blank frame and makes every tile invisible.
  [layer setNeedsLayout];
  for (CALayer *sub in Hider_CopySublayersSnapshot(layer))
    Hider_ForceLayoutRecursive(sub);
}

// Walk the NSView subview tree and invalidate layout on every layer-backed
// view.  This is the correct path for SwiftUI-hosted Dock content: SwiftUI
// views live inside NSHostingView (an NSView subclass), so calling
// setNeedsLayout: on the NSView triggers SwiftUI's reconciliation pass, which
// in turn calls layoutSublayers on the backing CALayers — hitting our hook.

// Use the tracked floor layer as an anchor to locate the tile container layer
// directly (avoids having to traverse from the window root).  The floor layers
// are siblings of — or one level above — the DOCKTileLayer instances, so we
// walk up the superlayer chain until we find a parent that has DOCKTileLayer
// children, then apply visibility and force layout on that subtree.
// Trigger a floor-separator pass on tracked floor layers.
// Finder/Trash removal is handled via CoreDock APIs and tile swizzles.
// Positional fallback for Finder/Trash hiding: on modern macOS, Dock's private
// ownership chains are opaque so Hider_GetBundleID returns nil for every
// Edge-tile fallback is intentionally disabled.
// On newer Dock builds this heuristic can target non-trash/non-finder tiles
// (indicators or regular app icons). Keep this symbol for easy rollback but
// do not mutate any edge tiles from here.
static void Hider_ApplyEdgeTileVisibility(CALayer *parent) {
  (void)parent;
}

static void Hider_TriggerLayoutOnTrackedLayers(void) {
  CALayer *anchor = g_modernFloorLayer ? g_modernFloorLayer : g_legacyFloorLayer;
  if (!anchor)
    return;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  Hider_HideFloorSeparators(anchor);
  if (anchor.superlayer)
    Hider_HideFloorSeparators(anchor.superlayer);
  [CATransaction commit];

  // Force layout so hidden tiles (e.g. Trash) disappear immediately instead
  // of lingering until hover triggers a redraw.
  Hider_ForceLayoutRecursive(anchor);
  if (anchor.superlayer)
    Hider_ForceLayoutRecursive(anchor.superlayer);

  // Apply positional Finder/Trash hiding.  The floor layer's immediate parent
  // is the tile container — do NOT walk to grandparent as that can reach
  // sub-containers and misidentify regular app tiles as Finder/Trash.
  if (finderHidden || trashHidden)
    Hider_ApplyEdgeTileVisibility(anchor.superlayer);
}

void Hider_DumpLayer(CALayer *layer, int depth, NSMutableString *output) {
  if (!layer)
    return;

  NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                       withString:@" "
                                  startingAtIndex:0];
  NSString *className = NSStringFromClass([layer class]);
  NSString *frameStr = NSStringFromRect(NSRectFromCGRect(layer.frame));
  NSString *bundleID = Hider_GetBundleID(layer);

  [output appendFormat:@"%@<%@: %p; frame = %@; bundleID = %@>\n", indent,
                       className, (void *)layer, frameStr,
                       bundleID ? bundleID : @"none"];

  for (CALayer *sub in Hider_CopySublayersSnapshot(layer)) {
    Hider_DumpLayer(sub, depth + 1, output);
  }
}

void Hider_DumpDockHierarchy(void) {
  LOG_TO_FILE("Dumping Dock Layer Hierarchy...");
  NSMutableString *output = [NSMutableString string];
  [output appendString:@"Dock CALayer Hierarchy Dump\n"];
  [output appendFormat:@"Timestamp: %@\n", [NSDate date]];
  [output appendString:@"========================================\n\n"];

  // Use the unified root-layer collection so we see the same tree as enforcement.
  NSArray<CALayer *> *roots = Hider_CollectRootLayers();
  [output appendFormat:@"Root layers found: %lu\n\n", (unsigned long)roots.count];
  LOG_TO_FILE("Dump: found %lu root layers", (unsigned long)roots.count);

  for (NSUInteger ri = 0; ri < roots.count; ri++) {
    CALayer *rootLayer = roots[ri];
    [output appendFormat:@"Root %lu: %@ (%p)\n", (unsigned long)ri,
                         NSStringFromClass([rootLayer class]),
                         (void *)rootLayer];
    [output appendString:@"----------------------------------------\n"];
    Hider_DumpLayer(rootLayer, 0, output);
    [output appendString:@"\n"];
  }

  // Also dump tracked tile info.
  [output appendString:@"=== Tracked Tiles ===\n"];
  [output appendFormat:@"g_customAppTileObjects count: %lu\n",
                       (unsigned long)g_customAppTileObjects.count];
  NSArray *trackedBIDs = nil;
  @try {
    trackedBIDs = [[g_customAppTileObjects keyEnumerator] allObjects];
  } @catch (NSException *) {
    trackedBIDs = nil;
  }
  for (NSString *bid in trackedBIDs) {
    id tile = [g_customAppTileObjects objectForKey:bid];
    [output appendFormat:@"  %@ → %@ (%p)\n", bid,
                         NSStringFromClass([tile class]), (void *)tile];
  }
  [output appendFormat:@"g_hiddenAppBundleIDs: %@\n", g_hiddenAppBundleIDs];

  NSError *error = nil;
  [output writeToFile:@"/tmp/dock_layer_dump.txt"
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:&error];

  if (error) {
    LOG_TO_FILE("Failed to write dump: %@", error.localizedDescription);
  } else {
    LOG_TO_FILE("Dump successful: /tmp/dock_layer_dump.txt");
  }
}

void Hider_DumpDockClasses(void) {
  LOG_TO_FILE("Dumping Dock runtime classes...");
  NSMutableString *output = [NSMutableString string];
  [output appendString:@"Dock Runtime Class Dump\n"];
  [output appendFormat:@"Timestamp: %@\n", [NSDate date]];
  [output appendString:@"========================================\n\n"];

  unsigned int classCount = 0;
  Class *classes = objc_copyClassList(&classCount);
  NSMutableArray<NSString *> *entries = [NSMutableArray array];

  for (unsigned int i = 0; i < classCount; i++) {
    Class cls = classes[i];
    const char *name = class_getName(cls);
    if (!name) continue;

    BOOL isDockLike =
        (strstr(name, "DOCK") != NULL) ||
        (strstr(name, "DockCore") != NULL) ||
        (strstr(name, "_TtC8DockCore") != NULL);

    BOOL inTileHierarchy = NO;
    Class superClass = class_getSuperclass(cls);
    while (superClass) {
      const char *sn = class_getName(superClass);
      if (sn && (strcmp(sn, "Tile") == 0 || strstr(sn, "DOCK") != NULL ||
                 strstr(sn, "DockCore") != NULL || strstr(sn, "Tile") != NULL)) {
        inTileHierarchy = YES;
        break;
      }
      superClass = class_getSuperclass(superClass);
    }

    BOOL isBaseTileClass = (strcmp(name, "Tile") == 0);
    if (!isDockLike && !inTileHierarchy && !isBaseTileClass) continue;

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    if (!methods) continue;

    NSMutableArray<NSString *> *methodNames =
        [NSMutableArray arrayWithCapacity:methodCount];
    for (unsigned int mi = 0; mi < methodCount; mi++) {
      SEL sel = method_getName(methods[mi]);
      if (!sel) continue;
      const char *selName = sel_getName(sel);
      if (!selName) continue;
      [methodNames addObject:[NSString stringWithUTF8String:selName]];
    }
    free(methods);

    [methodNames sortUsingSelector:@selector(compare:)];

    BOOL interesting =
        [cls instancesRespondToSelector:NSSelectorFromString(@"doCommand:")] ||
        [cls instancesRespondToSelector:NSSelectorFromString(@"performCommand:")] ||
        [cls instancesRespondToSelector:NSSelectorFromString(@"bundleIdentifier")] ||
        [cls instancesRespondToSelector:NSSelectorFromString(@"processIdentifier")] ||
        [cls instancesRespondToSelector:NSSelectorFromString(@"setRunning:")] ||
        [cls instancesRespondToSelector:NSSelectorFromString(@"setActive:")];

    NSMutableString *entry = [NSMutableString string];
    [entry appendFormat:@"Class: %s\n", name];
    [entry appendFormat:@"Superclass: %s\n",
                        class_getSuperclass(cls)
                            ? class_getName(class_getSuperclass(cls))
                            : "nil"];
    [entry appendFormat:@"InTileHierarchy: %d\n", inTileHierarchy ? 1 : 0];
    [entry appendFormat:@"Interesting: %d\n", interesting ? 1 : 0];
    [entry appendFormat:@"MethodCount: %u\n", methodCount];

    // Add ivars for tile-like classes to aid reverse-engineering relationships
    // between tile model objects and CALayer/NSView instances.
    if (inTileHierarchy || strstr(name, "Tile") != NULL) {
      unsigned int ivarCount = 0;
      Ivar *ivars = class_copyIvarList(cls, &ivarCount);
      [entry appendFormat:@"IvarCount: %u\n", ivarCount];
      for (unsigned int ii = 0; ii < ivarCount; ii++) {
        const char *in = ivar_getName(ivars[ii]);
        const char *it = ivar_getTypeEncoding(ivars[ii]);
        [entry appendFormat:@"  ivar: %s (%s)\n", in ? in : "?", it ? it : "?"];
      }
      free(ivars);
    }

    NSUInteger maxMethodsToPrint = 220;
    NSUInteger limit = MIN((NSUInteger)methodNames.count, maxMethodsToPrint);
    for (NSUInteger k = 0; k < limit; k++) {
      [entry appendFormat:@"  - %@\n", methodNames[k]];
    }
    if ((NSUInteger)methodNames.count > maxMethodsToPrint) {
      [entry appendFormat:@"  ... (%lu more)\n",
                          (unsigned long)((NSUInteger)methodNames.count -
                                          maxMethodsToPrint)];
    }
    [entry appendString:@"\n"];
    [entries addObject:entry];
  }
  free(classes);

  [entries sortUsingSelector:@selector(compare:)];
  [output appendFormat:@"Matched classes: %lu\n\n", (unsigned long)entries.count];
  for (NSString *e in entries) {
    [output appendString:e];
  }

  NSError *error = nil;
  [output writeToFile:@"/tmp/dock_class_dump.txt"
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:&error];
  if (error) {
    LOG_TO_FILE("Failed to write class dump: %@", error.localizedDescription);
  } else {
    LOG_TO_FILE("Class dump successful: /tmp/dock_class_dump.txt");
  }
}

#pragma mark - Hider Logic

#pragma mark - Preferences

static void Hider_LoadSettings(void) {
  LOG_TO_FILE("Loading settings from com.aspauldingcode.hider");
  Hider_LoadVisibilityFlags(YES);

  // The hidden-app set or Finder/Trash flags may have changed.  Flush
  // per-layer caches so DOCKTileLayer hooks re-evaluate against the new state.
  Hider_InvalidateLayerCaches();

  LOG_TO_FILE("Settings: Finder=%d, Trash=%d, customApps=%lu (separators=auto)",
              finderHidden, trashHidden,
              (unsigned long)g_hiddenAppBundleIDs.count);
}

// Fast path for layout hooks: refresh in-memory flags from CFPreferences cache
// (no disk sync). This makes SwiftUI layout passes pick up settings immediately.
static void Hider_LoadSettingsFromCache(void) {
  Hider_LoadVisibilityFlags(NO);
}

static void Hider_LoadVisibilityFlags(BOOL synchronizePrefs) {
  if (synchronizePrefs)
    CFPreferencesAppSynchronize(CFSTR("com.aspauldingcode.hider"));

  finderHidden = NO;
  CFPropertyListRef fVal = CFPreferencesCopyAppValue(CFSTR("hideFinder"), CFSTR("com.aspauldingcode.hider"));
  if (fVal) {
    if (CFGetTypeID(fVal) == CFBooleanGetTypeID()) finderHidden = CFBooleanGetValue((CFBooleanRef)fVal) ? YES : NO;
    else if (CFGetTypeID(fVal) == CFNumberGetTypeID()) {
        int i = 0;
        CFNumberGetValue((CFNumberRef)fVal, kCFNumberIntType, &i);
        finderHidden = (i != 0);
    }
    CFRelease(fVal);
  }

  trashHidden = NO;
  CFPropertyListRef tVal = CFPreferencesCopyAppValue(CFSTR("hideTrash"), CFSTR("com.aspauldingcode.hider"));
  if (tVal) {
    if (CFGetTypeID(tVal) == CFBooleanGetTypeID()) trashHidden = CFBooleanGetValue((CFBooleanRef)tVal) ? YES : NO;
    else if (CFGetTypeID(tVal) == CFNumberGetTypeID()) {
        int i = 0;
        CFNumberGetValue((CFNumberRef)tVal, kCFNumberIntType, &i);
        trashHidden = (i != 0);
    }
    CFRelease(tVal);
  }

  if (synchronizePrefs)
    Hider_LoadCustomAppsFromPrefs();
  else
    Hider_LoadCustomAppsFromCache();
}

// CoreDock function pointers (storage; types are in tweak.h)
CoreDockSetTileHiddenFunc CoreDockSetTileHidden = NULL;
CoreDockIsTileHiddenFunc CoreDockIsTileHidden = NULL;
CoreDockRefreshTileFunc CoreDockRefreshTile = NULL;
CoreDockSendNotificationFunc CoreDockSendNotification = NULL;

#pragma mark - CoreDock Loading

static BOOL Hider_LoadCoreDockFunctions(void) {
  if (g_coreDockLoaded)
    return YES;

  const char *coreDockPaths[] = {
      "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices",
      "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
      "/System/Library/PrivateFrameworks/CoreDock.framework/Versions/A/CoreDock",
      "/System/Library/PrivateFrameworks/CoreDock.framework/CoreDock",
      "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
  };
  g_coreDockHandle = NULL;
  for (size_t i = 0; i < (sizeof(coreDockPaths) / sizeof(coreDockPaths[0])); i++) {
    g_coreDockHandle = dlopen(coreDockPaths[i], RTLD_LAZY);
    if (g_coreDockHandle) {
      LOG_TO_FILE("Loaded ApplicationServices from: %s", coreDockPaths[i]);
      break;
    }
  }
  if (!g_coreDockHandle) {
    LOG_TO_FILE("Failed to load ApplicationServices: %s", dlerror());
    return NO;
  }

  CoreDockSetTileHidden = (CoreDockSetTileHiddenFunc)dlsym(
      g_coreDockHandle, "CoreDockSetTileHidden");
  CoreDockIsTileHidden =
      (CoreDockIsTileHiddenFunc)dlsym(g_coreDockHandle, "CoreDockIsTileHidden");
  CoreDockRefreshTile =
      (CoreDockRefreshTileFunc)dlsym(g_coreDockHandle, "CoreDockRefreshTile");
  CoreDockSendNotification = (CoreDockSendNotificationFunc)dlsym(
      g_coreDockHandle, "CoreDockSendNotification");

  LOG_TO_FILE("CoreDock symbols: set=%d is=%d refresh=%d notify=%d",
              CoreDockSetTileHidden != NULL, CoreDockIsTileHidden != NULL,
              CoreDockRefreshTile != NULL, CoreDockSendNotification != NULL);

  // Modern macOS may expose only a subset. Treat CoreDock as available if any
  // relevant symbol resolved; callers already guard each function pointer.
  g_coreDockLoaded = (CoreDockSetTileHidden != NULL ||
                      CoreDockIsTileHidden != NULL ||
                      CoreDockRefreshTile != NULL ||
                      CoreDockSendNotification != NULL);
  return g_coreDockLoaded;
}

#pragma mark - Dock Preferences

// The Dock's SwiftUI view tree is rebuilt from com.apple.dock preferences.
// Writing a pref and posting the preferences-changed notification is the only
// guaranteed round-trip for both remove AND restore — layer reinsertion fights
// SwiftUI's reconciler and loses.  We use this as the primary mechanism and
// keep doCommand:1004 only as a belt-and-suspenders on the hide side.

static void Hider_PostDockPrefsChangedNotification(void) {
  // Coalesce noisy notification storms; Dock can terminate itself when flooded
  // while reconciling many tile mutations on the main queue.
  static CFAbsoluteTime s_lastPostTime = 0.0;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (s_lastPostTime > 0.0 && (now - s_lastPostTime) < 0.25) return;
  s_lastPostTime = now;

  // Avoid synchronous CoreDockSendNotification from inside Dock process.
  // notify_post + distributed notifications are sufficient for refresh.
  notify_post("com.apple.dock.prefchanged");
  notify_post("com.apple.dock.preferencesCached");
  [[NSDistributedNotificationCenter defaultCenter]
      postNotificationName:@"com.apple.dock.prefschanged"
                    object:nil
                  userInfo:nil
        deliverImmediately:YES];
}

static void Hider_CoreDockSetHiddenBundle(NSString *bundleID, BOOL hidden) {
  if (!bundleID.length) return;
  if (Hider_LoadCoreDockFunctions() && CoreDockSetTileHidden)
    CoreDockSetTileHidden((__bridge CFStringRef)bundleID, hidden ? YES : NO);
}

static void Hider_CoreDockRefreshBundle(NSString *bundleID) {
  if (!bundleID.length) return;
  if (!Hider_LoadCoreDockFunctions()) return;
  if (CoreDockRefreshTile)
    CoreDockRefreshTile((__bridge CFStringRef)bundleID);
}

static BOOL Hider_ApplyModelHiddenForBundle(NSString *bundleID,
                                            NSString *source) {
  if (!bundleID.length) return NO;
  NSString *normalized = Hider_NormalizeBundleID(bundleID);
  if (!normalized.length) return NO;

  static NSMutableDictionary<NSString *, NSNumber *> *s_lastModelHideMs = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    s_lastModelHideMs = [NSMutableDictionary dictionary];
  });

  uint64_t nowMs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
  uint64_t lastMs =
      [[s_lastModelHideMs objectForKey:normalized] unsignedLongLongValue];
  BOOL haveCoreDock = Hider_LoadCoreDockFunctions();
  BOOL alreadyHidden = NO;
  if (haveCoreDock && CoreDockIsTileHidden) {
    alreadyHidden =
        CoreDockIsTileHidden((__bridge CFStringRef)normalized) ? YES : NO;
  }

  // Dock can re-enter this path aggressively during launch/activation. Once
  // the persistent model is already hidden, additional CoreDock hide+refresh
  // calls just create notification churn without changing state.
  if (alreadyHidden && lastMs != 0 && (nowMs - lastMs) < 1500) {
    return NO;
  }

  // Also guard the state-transition window where CoreDock may not yet reflect
  // the prior write but the same bundle is already being processed repeatedly.
  if (lastMs != 0 && (nowMs - lastMs) < 250) {
    return NO;
  }

  Hider_CoreDockSetHiddenBundle(normalized, YES);
  if (!alreadyHidden || lastMs == 0 || (nowMs - lastMs) > 500) {
    Hider_CoreDockRefreshBundle(normalized);
  }
  [s_lastModelHideMs setObject:@(nowMs) forKey:normalized];
  NSString *label = source ? source : @"unknown";
  LOG_TO_FILE("ModelHide[%@]: %@", label, normalized);
  return YES;
}

static BOOL Hider_InvokeBoolSetter(id target, SEL selector, BOOL value) {
  if (!target || !selector || ![target respondsToSelector:selector]) return NO;
  NSMethodSignature *sig = [target methodSignatureForSelector:selector];
  if (!sig || sig.numberOfArguments != 3) return NO;
  const char *arg = [sig getArgumentTypeAtIndex:2];
  if (!arg || !strchr("cCsSiIlLqQB", arg[0])) return NO;
  @try {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, selector, value);
    return YES;
  } @catch (__unused NSException *e) {
    return NO;
  }
}

static BOOL Hider_InvokeVoidNoArg(id target, SEL selector) {
  if (!target || !selector || ![target respondsToSelector:selector]) return NO;
  NSMethodSignature *sig = [target methodSignatureForSelector:selector];
  if (!sig || sig.numberOfArguments != 2) return NO;
  @try {
    ((void (*)(id, SEL))objc_msgSend)(target, selector);
    return YES;
  } @catch (__unused NSException *e) {
    return NO;
  }
}

static BOOL Hider_InvokeIntCommand(id target, SEL selector, NSInteger value) {
  if (!target || !selector || ![target respondsToSelector:selector]) return NO;
  NSMethodSignature *sig = [target methodSignatureForSelector:selector];
  if (!sig || sig.numberOfArguments != 3) return NO;
  const char *arg = [sig getArgumentTypeAtIndex:2];
  if (!arg || !strchr("cCsSiIlLqQB", arg[0])) return NO;
  @try {
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, selector, value);
    return YES;
  } @catch (__unused NSException *e) {
    return NO;
  }
}

static void Hider_ApplyAuthoritativeHiddenAppsModelState(NSString *source) {
  NSSet *hiddenSnap = [g_hiddenAppBundleIDs copy];
  for (NSString *bid in hiddenSnap) {
    (void)Hider_ApplyModelHiddenForBundle(bid, source);
  }
}

static void Hider_ApplyCoreDockHiddenState(void) {
  Hider_CoreDockSetHiddenBundle((__bridge NSString *)kCoreDockFinderBundleID,
                                finderHidden);
  Hider_CoreDockRefreshBundle((__bridge NSString *)kCoreDockFinderBundleID);
  Hider_CoreDockSetHiddenBundle((__bridge NSString *)kCoreDockTrashBundleID,
                                trashHidden);
  Hider_CoreDockRefreshBundle((__bridge NSString *)kCoreDockTrashBundleID);
  Hider_ApplyAuthoritativeHiddenAppsModelState(@"applyCoreDockHiddenState");
}

static void Hider_SendDockTileCommand(id tile, int command) {
  if (!tile) return;
  if (command == 1004) {
    Hider_RunOnce(tile, &kHiderTileRemoveCommandKey, ^{
      [HiderDockActions removeDockTile:tile];
    });
    return;
  }
  if (command == 1003) {
    objc_setAssociatedObject(tile, &kHiderTileRemoveCommandKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  SEL doCommandSel = NSSelectorFromString(@"doCommand:");
  SEL performCommandSel = NSSelectorFromString(@"performCommand:");
  if (!Hider_InvokeIntCommand(tile, doCommandSel, command)) {
    if (!Hider_InvokeIntCommand(tile, performCommandSel, command)) {
      // Compatibility fallback: some Dock variants may box command values.
      NSNumber *boxed = @(command);
      NSMethodSignature *doSig = [tile methodSignatureForSelector:doCommandSel];
      NSMethodSignature *performSig = [tile methodSignatureForSelector:performCommandSel];
      @try {
        if (doSig && doSig.numberOfArguments == 3 &&
            [doSig getArgumentTypeAtIndex:2][0] == '@') {
          ((void (*)(id, SEL, id))objc_msgSend)(tile, doCommandSel, boxed);
        } else if (performSig && performSig.numberOfArguments == 3 &&
                   [performSig getArgumentTypeAtIndex:2][0] == '@') {
          ((void (*)(id, SEL, id))objc_msgSend)(tile, performCommandSel, boxed);
        }
      } @catch (__unused NSException *e) {
      }
    }
  }
}

static void Hider_HideTileDecorations(id tile) {
  if (!tile) return;
  NSString *bid = Hider_ResolveTileBundleID(tile);
  if (bid && Hider_IsCustomHiddenApp(bid)) {
    // Custom hidden apps: visual-only suppression, NO doCommand:1004.
    // Calling removeDockTile (→ doCommand:1004) on a running tile empties the
    // running-apps section, Dock removes the separator, and the next launch of
    // any hidden app hits insertTile:atIndex:NSNotFound → EXC_BREAKPOINT.
    [HiderDockActions suppressDockTile:tile];
    Hider_HideRootLayerTile(bid);
  } else {
    // Finder, Trash, separator, and other persistent tiles: full removal OK.
    [HiderDockActions removeDockTile:tile];
  }
}

#pragma mark - Root Layer Tile Hiding

// Get the root CALayer that contains DOCKTileLayer/DOCKIndicatorLayer as
// direct children.  This is the superlayer of the floor layers.
__attribute__((unused))
static CALayer *Hider_GetRootLayer(void) {
  CALayer *floor = g_modernFloorLayer ? g_modernFloorLayer : g_legacyFloorLayer;
  return floor ? floor.superlayer : nil;
}

// Checks whether an about-to-be-added layer is a DOCKTileLayer or
// DOCKIndicatorLayer belonging to a hidden app.  Used by the root-layer
// isa-swizzle to block re-additions.
static BOOL Hider_ShouldBlockTileLayer(CALayer *layer) {
  if (!layer || g_hiddenAppBundleIDs.count == 0) return NO;
  const char *cn = class_getName([layer class]);
  if (!cn) return NO;

  if (strcmp(cn, "DOCKTileLayer") != 0) return NO;

  // Forward: try standard bundle-ID resolution
  NSString *bid = Hider_BundleIDFromTileLayer(layer);
  if (bid && Hider_IsCustomHiddenApp(bid)) return YES;

  // Reverse: check if any hidden app's tracked tile owns this layer via ivar
  @try {
    for (NSString *hbid in [g_hiddenAppBundleIDs copy]) {
      id trackedTile = [g_customAppTileObjects objectForKey:hbid];
      if (!trackedTile) continue;
      CALayer *owned = Hider_FindTileLayerInIvars(trackedTile);
      if (owned == layer) return YES;
    }
  } @catch (NSException *ex) { (void)ex; }

  return NO;
}

static BOOL Hider_ShouldBlockIndicatorLayerForHiddenTiles(
    CALayer *indicatorLayer, NSArray<NSValue *> *blockedTileRects) {
  if (!indicatorLayer || blockedTileRects.count == 0) return NO;
  const char *cn = class_getName([indicatorLayer class]);
  if (!cn || strcmp(cn, "DOCKIndicatorLayer") != 0) return NO;
  CGRect indicatorFrame = indicatorLayer.frame;
  if (CGRectIsEmpty(indicatorFrame)) return NO;
  for (NSValue *v in blockedTileRects) {
    CGRect tileRect = [v rectValue];
    if (CGRectIsEmpty(tileRect)) continue;
    CGRect expanded = CGRectInset(tileRect, -28.0, -18.0);
    if (CGRectIntersectsRect(expanded, indicatorFrame)) {
      return YES;
    }
  }
  return NO;
}

// Isa-swizzle the root layer to intercept addSublayer: / insertSublayer:*
// so that DOCKTileLayer for hidden apps is never re-added after removal.
static void Hider_HookRootLayerIfNeeded(void) {
  // Safety valve: root-layer interception has caused "Dock alive but never
  // visible" failures on recent builds. Keep custom apps on the direct tile
  // suppression path and do not mutate the root layer tree.
  return;
}

// Scan an object's ivars (including superclass ivars up to stopClass) looking
// for an object-type ivar whose value == target.  Returns YES on first match.
static BOOL Hider_ObjectHasIvarPointingTo(id obj, id target, Class stopClass) {
  if (!obj || !target) return NO;
  Class cls = object_getClass(obj);
  while (cls && cls != stopClass) {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
      const char *type = ivar_getTypeEncoding(ivars[i]);
      if (type && type[0] == '@') {
        id val = object_getIvar(obj, ivars[i]);
        if (val == target) { free(ivars); return YES; }
      }
    }
    free(ivars);
    cls = class_getSuperclass(cls);
  }
  return NO;
}

// Scan an object's ivars for any value that is a CALayer with class name
// containing "TileLayer".  Returns the first match or nil.
static CALayer *Hider_FindTileLayerInIvars(id obj) {
  if (!obj) return nil;
  Class cls = object_getClass(obj);
  while (cls && cls != [NSObject class]) {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
      const char *type = ivar_getTypeEncoding(ivars[i]);
      if (type && type[0] == '@') {
        id val = object_getIvar(obj, ivars[i]);
        if (val && [val isKindOfClass:[CALayer class]]) {
          const char *cn = class_getName([val class]);
          if (cn && strstr(cn, "TileLayer")) {
            free(ivars); return (CALayer *)val;
          }
        }
      }
    }
    free(ivars);
    cls = class_getSuperclass(cls);
  }
  return nil;
}

// Resolve the bundle ID from a DOCKTileLayer using every available strategy.
static NSString *Hider_BundleIDFromTileLayer(CALayer *tileLayer) {
  // Strategy 1: full resolution via Hider_GetBundleID (walks delegate chain)
  NSString *bid = Hider_GetBundleID(tileLayer);
  if (bid.length > 0) return Hider_NormalizeBundleID(bid);

  // Strategy 2: check the delegate specifically
  id delegate = tileLayer.delegate;
  if (delegate) {
    NSString *tag = objc_getAssociatedObject(delegate, &kHiderBundleIDTag);
    if (tag.length > 0) return Hider_NormalizeBundleID(tag);

    bid = Hider_GetBundleID(delegate);
    if (bid.length > 0) return Hider_NormalizeBundleID(bid);
  }

  // Strategy 3: brute-force scan all object ivars of DOCKTileLayer for a
  // pointer to one of our tracked tile objects (DOCKFileTile etc.)
  if (g_customAppTileObjects) {
    @try {
      for (NSString *key in [[g_customAppTileObjects keyEnumerator] allObjects]) {
        id trackedTile = [g_customAppTileObjects objectForKey:key];
        if (!trackedTile) continue;
        if (Hider_ObjectHasIvarPointingTo(tileLayer, trackedTile, [CALayer class]))
          return key;
        if (delegate && Hider_ObjectHasIvarPointingTo(delegate, trackedTile, [NSObject class]))
          return key;
      }
    } @catch (NSException *ex) { (void)ex; }
  }

  return nil;
}

// Hide a specific DOCKTileLayer and its matching DOCKIndicatorLayer for the
// given bundle ID. Modern Dock builds often nest tile layers under container
// layers, so collect a stable descendant snapshot instead of assuming they are
// direct children of the root.
__attribute__((unused))
static void Hider_CollectDescendantLayers(CALayer *layer,
                                          NSMutableArray<CALayer *> *outLayers) {
  if (!layer || !outLayers) return;
  for (CALayer *child in Hider_CopySublayersSnapshot(layer)) {
    [outLayers addObject:child];
    Hider_CollectDescendantLayers(child, outLayers);
  }
}

__attribute__((unused))
static void Hider_HideSingleLayer(CALayer *layer) {
  if (!layer) return;
  CALayer *parent = layer.superlayer;
  if (parent) {
    // Hide the slot first so Dock does not leave behind a stale placeholder or
    // partially rendered tile while the layer tree is reconciling.
    Hider_SuppressSlot(layer);
  }
  [layer removeAllAnimations];
  layer.hidden = YES;
  layer.opacity = 0.0f;
  layer.contents = nil;
  [layer removeFromSuperlayer];
  [parent setNeedsLayout];
}

static void Hider_HideRootLayerTile(NSString *bundleID) {
  (void)bundleID;
  // Safety valve: do not remove or filter root-layer children on current Dock
  // builds. Direct tile suppression and model-hidden state remain active.
  return;
}

// Hide ALL DOCKTileLayer/DOCKIndicatorLayer in the root layer that belong
// to hidden apps.  Called during layout enforcement and settings reload.
static void Hider_HideAllRootLayerHiddenTiles(void) {
  return;
}

static void Hider_RunAndScheduleMainQueuePasses(dispatch_block_t block,
                                                BOOL runImmediately,
                                                const int64_t *delays,
                                                NSUInteger count) {
  if (!block) return;
  dispatch_block_t copied = [block copy];
  if (runImmediately)
    copied();
  for (NSUInteger i = 0; i < count; i++) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays[i] * (int64_t)NSEC_PER_MSEC),
                   dispatch_get_main_queue(), copied);
  }
}

static void Hider_ScheduleHotloadPasses(BOOL runImmediately,
                                        const int64_t *delays,
                                        NSUInteger count) {
  Hider_RunAndScheduleMainQueuePasses(^{
    Hider_ForceHotloadHiddenTilesNow();
  }, runImmediately, delays, count);
}

static void Hider_ScheduleAppEnforcementPasses(NSString * _Nullable bid,
                                               pid_t pid,
                                               BOOL runImmediately,
                                               BOOL requestRemoval,
                                               const int64_t *delays,
                                               NSUInteger count) {
  Hider_RunAndScheduleMainQueuePasses(^{
    if (requestRemoval)
      Hider_ForceHideRunningAppNow(bid, pid);
    else
      Hider_EnforceHiddenApps(bid, pid);
  }, runImmediately, delays, count);
}

void HiderBridgeRefreshDock(void) {
  refresh_dock();
}

NSString *HiderBridgeResolveTileBundleID(id tile) {
  return Hider_ResolveTileBundleID(tile);
}

// Write show-finder to the Dock's pref domain.
// "show-finder" is a real key the Dock reads on preference-changed notifications.
// There is no equivalent pref key for Trash — we handle Trash via doCommand:.
static void Hider_WriteFinderPref(void) {
  CFPreferencesSetAppValue(CFSTR("show-finder"),
                           finderHidden ? kCFBooleanFalse : kCFBooleanTrue,
                           CFSTR("com.apple.dock"));
  CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  LOG_TO_FILE("Wrote prefs: show-finder=%d", !finderHidden);
}


#pragma mark - Refresh

/// Unified helper to apply robust removal to a tile.
static void Hider_ApplyUnifiedRemoval(id tile) {
  if (!tile) return;
  LOG_TO_FILE("Applying unified removal to: %@", tile);
  
  // DOCKProcessTile has no doCommand: — use CoreDock API directly.
  // This is the only reliable way to remove a running-app tile.
  NSString *tileClass = NSStringFromClass([tile class]);
  BOOL isProcessTile = [tileClass containsString:@"ProcessTile"];
  if (isProcessTile) {
    NSString *bid = Hider_ResolveTileBundleID(tile);
    if (!bid) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      SEL bidSel = NSSelectorFromString(@"bundleIdentifier");
      if ([tile respondsToSelector:bidSel])
        bid = [tile performSelector:bidSel];
#pragma clang diagnostic pop
    }
    if (bid) {
      bid = Hider_NormalizeBundleID(bid);
      Hider_CoreDockSetHiddenBundle(bid, YES);
      Hider_CoreDockRefreshBundle(bid);
      LOG_TO_FILE("CoreDock hide for DOCKProcessTile: %@", bid);
    }
  }

  // Phase 1: Immediate visual suppression
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  Hider_SuppressTileRender(tile);
  Hider_HideTileDecorations(tile); // Custom apps stay visual-only; system tiles may remove.
  [CATransaction commit];
  [CATransaction flush];
  
  Hider_TriggerLayoutOnTrackedLayers();

  // Phase 2: Send actual removal command (one-shot with retries)
  Hider_RequestTileRemoval(tile);

  // Phase 3: Staggered enforcement for stubborn tiles/indicators
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                 dispatch_get_main_queue(), ^{
    Hider_SuppressTileRender(tile);
    Hider_HideTileDecorations(tile);
  });
  
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)),
                 dispatch_get_main_queue(), ^{
    Hider_SuppressTileRender(tile);
    Hider_HideTileDecorations(tile);
  });
}



/// Single reusable function for all Dock refresh operations (Finder, Trash, hidden apps, etc.)
static void refresh_dock(void) {
  LOG_TO_FILE("Refreshing Dock state...");
  
  BOOL finderBecameHidden  = finderHidden  && !g_prevFinderHidden;
  BOOL finderBecameVisible = !finderHidden && g_prevFinderHidden;
  BOOL trashBecameHidden   = trashHidden   && !g_prevTrashHidden;
  BOOL trashBecameVisible  = !trashHidden  && g_prevTrashHidden;

  // ── Finder ──────────────────────────────────────────────────────────────────
  Hider_WriteFinderPref();
  if (finderBecameHidden && g_finderTileObject) {
    Hider_ApplyUnifiedRemoval(g_finderTileObject);
  }
  if (finderBecameVisible && g_finderTileObject) {
    Hider_SendDockTileCommand(g_finderTileObject, 1003);
  }

  // ── Trash ───────────────────────────────────────────────────────────────────
  if (trashBecameHidden && g_trashTileObject) {
    Hider_ApplyUnifiedRemoval(g_trashTileObject);
    
    // Trash removal requires additional handling for the rightmost separator.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
      id rightmost = nil;
      CGFloat maxVal = -CGFLOAT_MAX;
      
      // Use a common coordinate space (window) to compare separator positions.
      for (id obj in g_separatorTileObjects) {
          if (![NSStringFromClass([obj class]) isEqualToString:@"DOCKSeparatorTile"]) continue;
          
          NSView *v = nil;
          CALayer *l = nil;
          if ([obj isKindOfClass:[NSView class]]) v = (NSView *)obj;
          else if ([obj isKindOfClass:[CALayer class]]) l = (CALayer *)obj;
          else if ([obj respondsToSelector:@selector(delegate)]) {
              id d = [obj valueForKey:@"delegate"];
              if ([d isKindOfClass:[NSView class]]) v = (NSView *)d;
              else if ([d isKindOfClass:[CALayer class]]) l = (CALayer *)d;
          } else if ([obj respondsToSelector:@selector(layer)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
              id layer = [obj performSelector:@selector(layer)];
              if ([layer isKindOfClass:[CALayer class]]) l = (CALayer *)layer;
#pragma clang diagnostic pop
          }
          
          if (v && v.window) {
              CGRect f = [v convertRect:v.bounds toView:v.window.contentView];
              // Dock is usually horizontal; check MaxX. If vertical, check MaxY.
              BOOL horizontal = (v.window.frame.size.width > v.window.frame.size.height);
              CGFloat val = horizontal ? CGRectGetMaxX(f) : CGRectGetMaxY(f);
              if (val > maxVal) {
                  maxVal = val;
                  rightmost = obj;
              }
          } else if (l) {
              CALayer *root = l;
              while (root.superlayer) {
                  root = root.superlayer;
              }
              CGRect f = [l convertRect:l.bounds toLayer:root];
              BOOL horizontal = (root.bounds.size.width > root.bounds.size.height);
              CGFloat val = horizontal ? CGRectGetMaxX(f) : CGRectGetMaxY(f);
              if (val > maxVal) {
                  maxVal = val;
                  rightmost = obj;
              }
          }
      }

      if (rightmost) {
          LOG_TO_FILE("Removing Trash separator via spatial check: %@", rightmost);
          Hider_ApplyUnifiedRemoval(rightmost);
      } else {
          // Fallback: use reverse order if spatial check failed
          for (id obj in [g_separatorTileObjects reverseObjectEnumerator]) {
              if ([NSStringFromClass([obj class]) isEqualToString:@"DOCKSeparatorTile"]) {
                  LOG_TO_FILE("Removing Trash separator via fallback list check: %@", obj);
                  Hider_ApplyUnifiedRemoval(obj);
                  break;
              }
          }
      }
    });
  }
  if (trashBecameVisible && g_trashTileObject) {
    Hider_SendDockTileCommand(g_trashTileObject, 1003);
  }

  // ── CoreDock Visibility ──────────────────────────────────────────────────
  Hider_ApplyCoreDockHiddenState();

  // ── Custom hidden apps ────────────────────────────────────────────────────
  if (g_hiddenAppBundleIDs.count > 0) {
    // Stage 1: Fast in-memory enforcement (root layer walk + slot suppression)
    // This ensures already-cached tiles and visible layers are hidden INSTANTLY.
    Hider_EnforceHiddenApps(nil, 0);
    Hider_ScheduleTrackedHiddenTileRemovals(@"refreshDock:postEnforce");

    // Stage 2: Persistent Apps Management
    // Only write to preferences if the persistent-apps list actually needs a change.
    CFArrayRef rawApps = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    if (rawApps) {
      NSArray *dockItems = (NSArray *)CFBridgingRelease(rawApps);
      NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:dockItems.count];
      BOOL changed = NO;
      for (id item in dockItems) {
        NSString *normalizedBid = Hider_BundleIDFromDockPersistentItem(item);
        if (normalizedBid && [g_hiddenAppBundleIDs containsObject:normalizedBid]) {
          changed = YES;
          continue;
        }
        [filtered addObject:item];
      }
      if (changed) {
        LOG_TO_FILE("Updating persistent-apps (removed %lu hidden items)", (unsigned long)(dockItems.count - filtered.count));
        CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFArrayRef)filtered, CFSTR("com.apple.dock"));
        CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
        // Reassert hidden flags after prefs mutation so model state cannot race.
        Hider_ApplyAuthoritativeHiddenAppsModelState(@"refreshDock:persistentAppsChanged");
        Hider_ScheduleTrackedHiddenTileRemovals(@"refreshDock:persistentAppsChanged");
      }
    }
  }

  // Step 3: Un-suppress apps that were removed from the hidden list.
  if (g_prevHiddenAppBundleIDs) {
    for (NSString *bid in g_prevHiddenAppBundleIDs) {
      if (![g_hiddenAppBundleIDs containsObject:bid]) {
        id tile = [g_customAppTileObjects objectForKey:bid];
        
        Hider_CoreDockSetHiddenBundle(bid, NO);
        Hider_CoreDockRefreshBundle(bid);

        if (tile) {
          objc_setAssociatedObject(tile, &kHiderBundleIDTag, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
          objc_setAssociatedObject(tile, &kHiderCustomAppRemoveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
          objc_setAssociatedObject(tile, &kHiderTileDemotedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
          
          // Restore visual state
          SEL ls = @selector(layer);
          if ([tile respondsToSelector:ls]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            CALayer *l = [tile performSelector:ls];
            if ([l isKindOfClass:[CALayer class]]) {
               Hider_UnsuppressSlot(l.superlayer);
            }
#pragma clang diagnostic pop
          }
          
          Hider_SendDockTileCommand(tile, 1003);
        }
      }
    }
  }

  g_prevHiddenAppBundleIDs = [g_hiddenAppBundleIDs copy];
  g_prevFinderHidden = finderHidden;
  g_prevTrashHidden  = trashHidden;

  Hider_PostDockPrefsChangedNotification();
  Hider_ScheduleTrackedHiddenTileRemovals(@"refreshDock:final");
  
  const int64_t applyDelays[] = {100, 300, 600};
  Hider_ScheduleAppEnforcementPasses(nil, 0, YES, NO, applyDelays, 3);
}

static void Hider_HideFinderIcon(Boolean hide) {
  finderHidden = (BOOL)hide;
  Hider_CoreDockSetHiddenBundle((__bridge NSString *)kCoreDockFinderBundleID,
                                hide ? YES : NO);
  [HiderDockActions refreshDock];
}

static void Hider_HideTrashIcon(Boolean hide) {
  trashHidden = (BOOL)hide;
  Hider_CoreDockSetHiddenBundle((__bridge NSString *)kCoreDockTrashBundleID,
                                hide ? YES : NO);
  [HiderDockActions refreshDock];
}

static Boolean Hider_IsFinderIconHidden(void) {
  if (CoreDockIsTileHidden && Hider_LoadCoreDockFunctions()) {
    return CoreDockIsTileHidden(kCoreDockFinderBundleID);
  }
  return (Boolean)finderHidden;
}

static Boolean Hider_IsTrashIconHidden(void) {
  if (CoreDockIsTileHidden && Hider_LoadCoreDockFunctions()) {
    return CoreDockIsTileHidden(kCoreDockTrashBundleID);
  }
  return (Boolean)trashHidden;
}

#pragma mark - DockTileLayer Swizzling

static void HiderScheduleDeferredSystemTileRemoval(id tile, NSString *bundleID) {
  if (!tile || !bundleID.length) return;
  __weak id weakTile = tile;
  NSString *bundleIDCopy = [bundleID copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    id strongTile = weakTile;
    if (!strongTile) return;
    Hider_RunOnce(strongTile, "Hider_TileLayer_Remove", ^{
      LOG_TO_FILE("setHidden: deferred doCommand:1004 for %@", bundleIDCopy);
      Hider_SendDockTileCommand(strongTile, 1004);
    });
  });
}

static void HiderTrackSeparatorTileObject(id tile) {
  if (!tile) return;
  if (!g_separatorTileObjects)
    g_separatorTileObjects = [NSMutableArray array];
  if (![g_separatorTileObjects containsObject:tile])
    [g_separatorTileObjects addObject:tile];
}

static void HiderApplyHiddenFloorLayerInterception(CALayer *layer, NSString *bundleID) {
  if (!layer || !bundleID.length || !Hider_IsCustomHiddenApp(bundleID)) return;

  LOG_TO_FILE("Floor layer intercepted for hidden app: %@", bundleID);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [HiderDockActions hideLayerTree:layer];
  Hider_SuppressSlot(layer);
  [CATransaction commit];

  id delegate = layer.delegate;
  if (delegate) {
    Hider_TrackResolvedTile(delegate, bundleID);
    Hider_SuppressTileRender(delegate);
  }
}

static void HiderScheduleDeferredFloorLayerCheck(CALayer *layer) {
  if (!layer || g_hiddenAppBundleIDs.count == 0) return;

  __weak CALayer *weakLayer = layer;
  int64_t deferDelays[] = {50, 150, 400};
  for (int di = 0; di < 3; di++) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 deferDelays[di] * (int64_t)NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
      CALayer *strongLayer = weakLayer;
      if (!strongLayer) return;
      id delegate = strongLayer.delegate;
      NSString *bundleID = delegate ? Hider_ResolveTileBundleID(delegate) : nil;
      if (!bundleID) {
        const char *cn = class_getName([strongLayer class]);
        if (cn && strstr(cn, "Tile"))
          bundleID = Hider_ResolveTileBundleID(strongLayer);
      }
      if (bundleID && Hider_IsCustomHiddenApp(bundleID)) {
        HiderApplyHiddenFloorLayerInterception(strongLayer, bundleID);
      }
    });
  }
}

static NSString *HiderResolveFloorLayerBundleID(CALayer *layer) {
  if (!layer) return nil;
  const char *cn = class_getName([layer class]);
  if (cn && strcmp(cn, "DOCKTileLayer") == 0) {
    NSString *tileLayerBid = Hider_BundleIDFromTileLayer(layer);
    if (tileLayerBid.length > 0) return tileLayerBid;
  }
  id delegate = layer.delegate;
  NSString *bundleID = delegate ? Hider_ResolveTileBundleID(delegate) : nil;
  if (!bundleID)
    bundleID = Hider_ResolveTileBundleID(layer);
  if (!bundleID && delegate)
    bundleID = Hider_NormalizeBundleID(Hider_GetBundleID(delegate));
  return bundleID;
}

static void HiderHandleFloorLayerCandidate(CALayer *layer, BOOL allowDeferred) {
  if (!layer) return;
  NSString *bundleID = HiderResolveFloorLayerBundleID(layer);
  if (bundleID && Hider_IsCustomHiddenApp(bundleID)) {
    HiderApplyHiddenFloorLayerInterception(layer, bundleID);
  } else if (!bundleID && allowDeferred) {
    Hider_RunOnce(layer, "Hider_FloorDeferredCheck", ^{
      HiderScheduleDeferredFloorLayerCheck(layer);
    });
  }
}

static void HiderTrackFloorLayer(CALayer *layer) {
  const char *name = class_getName([layer class]);
  if (name && strstr(name, "ModernFloorLayer"))
    g_modernFloorLayer = layer;
  else if (name && strstr(name, "LegacyFloorLayer"))
    g_legacyFloorLayer = layer;
}

static void HiderDOCKTileLayerSetHiddenHook(id self, SEL _cmd, BOOL hidden) {
  HiderBoolIMP originalIMP = (HiderBoolIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  static __thread BOOL in_swizzle = NO;
  if (in_swizzle) {
    originalIMP(self, _cmd, hidden);
    return;
  }
  in_swizzle = YES;

  BOOL shouldHide = Hider_ShouldForceHideLayer((CALayer *)self) ||
                    Hider_IsInSuppressedSlot((CALayer *)self);
  if (shouldHide) {
    id delegate = [(CALayer *)self delegate];
    if (delegate) {
      NSString *bundleID = Hider_ResolveTileBundleID(delegate);
      if (bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID))) {
        HiderScheduleDeferredSystemTileRemoval(delegate, bundleID);
      }
    }
    Hider_SuppressSlot((CALayer *)self);
  }

  originalIMP(self, _cmd, shouldHide ? YES : hidden);
  in_swizzle = NO;
}

static void HiderDOCKTileLayerSetOpacityHook(id self, SEL _cmd, float opacity) {
  HiderFloatIMP originalIMP = (HiderFloatIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  BOOL forceZero = Hider_ShouldForceHideLayer((CALayer *)self) ||
                   Hider_IsInSuppressedSlot((CALayer *)self);
  originalIMP(self, _cmd, forceZero ? 0.0f : opacity);
}

static void HiderDOCKTileLayerDrawInContextHook(id self, SEL _cmd,
                                                CGContextRef ctx) {
  HiderCGContextIMP originalIMP =
      (HiderCGContextIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  if (Hider_ShouldForceHideLayer((CALayer *)self) ||
      Hider_IsInSuppressedSlot((CALayer *)self)) {
    CGRect rect = CGContextGetClipBoundingBox(ctx);
    CGContextClearRect(ctx, rect);
    return;
  }
  originalIMP(self, _cmd, ctx);
}

static void HiderDOCKTileLayerLayoutSublayersHook(id self, SEL _cmd) {
  HiderVoidIMP originalIMP = (HiderVoidIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  originalIMP(self, _cmd);
  Hider_LoadSettingsFromCache();

  if (Hider_IsInSuppressedSlot((CALayer *)self) ||
      Hider_ShouldForceHideLayer((CALayer *)self)) {
    [(CALayer *)self setHidden:YES];
    [(CALayer *)self setOpacity:0.0f];
    Hider_SuppressSlot((CALayer *)self);
  }
}

static id HiderDOCKTrashTileInitHook(id self, SEL _cmd) {
  HiderObjectIMP originalIMP = (HiderObjectIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return self;

  id result = originalIMP(self, _cmd);
  g_trashTileObject = result ? result : self;
  if (trashHidden) {
    __weak id weakTile = result ? result : self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
      id strongTile = weakTile;
      if (strongTile) Hider_SendDockTileCommand(strongTile, 1004);
    });
  }
  return result;
}

static void HiderDOCKTrashTileUpdateHook(id self, SEL _cmd) {
  HiderVoidIMP originalIMP = (HiderVoidIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  g_trashTileObject = self;
  Hider_RunOnce(self, "Hider_Trash_Remove", ^{
    if (trashHidden) Hider_SendDockTileCommand(self, 1004);
  });
  originalIMP(self, _cmd);
}

static id HiderDOCKDesktopTileInitHook(id self, SEL _cmd) {
  HiderObjectIMP originalIMP = (HiderObjectIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return self;

  id result = originalIMP(self, _cmd);
  g_finderTileObject = result ? result : self;
  if (finderHidden) {
    __weak id weakTile = result ? result : self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
      id strongTile = weakTile;
      if (strongTile) Hider_SendDockTileCommand(strongTile, 1004);
    });
  }
  return result;
}

static void HiderDOCKDesktopTileUpdateHook(id self, SEL _cmd) {
  HiderVoidIMP originalIMP = (HiderVoidIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  g_finderTileObject = self;
  Hider_RunOnce(self, "Hider_Desktop_Remove", ^{
    if (finderHidden) Hider_SendDockTileCommand(self, 1004);
  });
  originalIMP(self, _cmd);
}

static void HiderHandleDOCKFileTilePostLifecycle(id tile) {
  NSString *bundleID = Hider_ResolveTileBundleID(tile);
  if (!bundleID) return;

  if (Hider_IsFinder(bundleID)) {
    g_finderTileObject = tile;
    Hider_RunOnce(tile, "Hider_FileTile_Finder_Remove", ^{
      if (finderHidden) Hider_SendDockTileCommand(tile, 1004);
    });
  } else {
    HiderCustomAppDockHiderHandleFileTileLifecycle(tile, bundleID);
    Hider_SuppressIfHidden(tile);
  }
}

static id HiderDOCKFileTileInitHook(id self, SEL _cmd) {
  HiderObjectIMP originalIMP = (HiderObjectIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return self;

  id result = originalIMP(self, _cmd);
  HiderHandleDOCKFileTilePostLifecycle(result ? result : self);
  return result;
}

static void HiderDOCKFileTileUpdateHook(id self, SEL _cmd) {
  HiderVoidIMP originalIMP = (HiderVoidIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  originalIMP(self, _cmd);
  HiderHandleDOCKFileTilePostLifecycle(self);
}

static id HiderDOCKSpacerTileInitHook(id self, SEL _cmd) {
  HiderObjectIMP originalIMP = (HiderObjectIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return self;

  id result = originalIMP(self, _cmd);
  HiderTrackSeparatorTileObject(result ? result : self);
  return result;
}

static void HiderDOCKSpacerTileUpdateHook(id self, SEL _cmd) {
  HiderVoidIMP originalIMP = (HiderVoidIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  HiderTrackSeparatorTileObject(self);
  originalIMP(self, _cmd);
}

static void HiderDOCKSpacerTileSetHiddenHook(id self, SEL _cmd, BOOL hidden) {
  HiderBoolIMP originalIMP = (HiderBoolIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  BOOL hide = HiderClassIsSeparatorTileClass(object_getClass(self))
                  ? separatorHiddenUntilRestart
                  : hidden;
  originalIMP(self, _cmd, hide ? YES : hidden);
}

static void HiderDOCKSpacerTileSetAlphaHook(id self, SEL _cmd, CGFloat alpha) {
  HiderCGFloatIMP originalIMP =
      (HiderCGFloatIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  if (HiderClassIsSeparatorTileClass(object_getClass(self)) &&
      separatorHiddenUntilRestart)
    originalIMP(self, _cmd, 0.0);
  else
    originalIMP(self, _cmd, alpha);
}

static void HiderDOCKSpacerTileDrawRectHook(id self, SEL _cmd, NSRect rect) {
  HiderNSRectIMP originalIMP = (HiderNSRectIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  if (HiderClassIsSeparatorTileClass(object_getClass(self)) &&
      separatorHiddenUntilRestart)
    return;
  originalIMP(self, _cmd, rect);
}

static void HiderDOCKSpacerTileLayoutSublayersHook(id self, SEL _cmd) {
  HiderVoidIMP originalIMP = (HiderVoidIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  originalIMP(self, _cmd);
  if (HiderClassIsSeparatorTileClass(object_getClass(self)) &&
      separatorHiddenUntilRestart) {
    if ([self isKindOfClass:[CALayer class]]) {
      [(CALayer *)self setHidden:YES];
      [(CALayer *)self setOpacity:0.0f];
    } else if ([self isKindOfClass:[NSView class]]) {
      [(NSView *)self setHidden:YES];
      [(NSView *)self setAlphaValue:0.0];
    }
  }
}

static void HiderDOCKFloorLayerLayoutSublayersHook(id self, SEL _cmd) {
  HiderVoidIMP originalIMP = (HiderVoidIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  HiderTrackFloorLayer((CALayer *)self);
  originalIMP(self, _cmd);
  Hider_LoadSettingsFromCache();
  Hider_HideFloorSeparators((CALayer *)self);
  if (g_hiddenAppBundleIDs.count > 0) {
    CALayer *scanRoot = [(CALayer *)self superlayer];
    if (!scanRoot) scanRoot = (CALayer *)self;
    NSMutableArray<CALayer *> *descendants = [NSMutableArray array];
    Hider_CollectDescendantLayers(scanRoot, descendants);
    for (CALayer *layer in descendants) {
      const char *cn = class_getName([layer class]);
      BOOL looksRelevant =
          layer.delegate != nil ||
          (cn && (strstr(cn, "Tile") || strstr(cn, "Indicator") ||
                  strstr(cn, "App")));
      if (!looksRelevant) continue;
      HiderHandleFloorLayerCandidate(layer, YES);
    }
  }
  Hider_HookRootLayerIfNeeded();
  if (g_hiddenAppBundleIDs.count > 0) {
    Hider_HideAllRootLayerHiddenTiles();
  }
}

static void HiderDOCKFloorLayerAddSublayerHook(id self, SEL _cmd,
                                               CALayer *newLayer) {
  HiderCALayerIMP originalIMP = (HiderCALayerIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  originalIMP(self, _cmd, newLayer);
  if (!newLayer) return;

  id delegate = newLayer.delegate;
  const char *layerCN = class_getName([newLayer class]);
  const char *delCN = delegate ? class_getName([delegate class]) : "nil";
  if (g_hiddenAppBundleIDs.count > 0) {
    LOG_TO_FILE("Floor addSublayer: layer=%s delegate=%s", layerCN, delCN);
  }
  HiderHandleFloorLayerCandidate(newLayer, YES);
}

static void HiderDOCKFloorLayerInsertSublayerHook(id self, SEL _cmd,
                                                  CALayer *newLayer,
                                                  unsigned int idx) {
  HiderCALayerIndexIMP originalIMP =
      (HiderCALayerIndexIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  originalIMP(self, _cmd, newLayer, idx);
  if (!newLayer || g_hiddenAppBundleIDs.count == 0) return;

  id delegate = newLayer.delegate;
  const char *layerCN = class_getName([newLayer class]);
  const char *delCN = delegate ? class_getName([delegate class]) : "nil";
  LOG_TO_FILE("Floor insertSublayer:atIndex: layer=%s delegate=%s idx=%u",
              layerCN, delCN, idx);
  HiderHandleFloorLayerCandidate(newLayer, NO);
}

static void HiderGenericCALayerSetHiddenHook(id self, SEL _cmd, BOOL hidden) {
  HiderBoolIMP originalIMP = (HiderBoolIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  @autoreleasepool {
    IF_HIDER_LOCKED() {
      originalIMP(self, _cmd, hidden);
      return;
    }
    HIDER_LOCK();
    static __thread BOOL in_swizzle = NO;
    if (in_swizzle) {
      originalIMP(self, _cmd, hidden);
      HIDER_UNLOCK();
      return;
    }
    in_swizzle = YES;

    if ([self isKindOfClass:[CALayer class]] &&
        Hider_IsInSuppressedSlot((CALayer *)self)) {
      originalIMP(self, _cmd, YES);
      in_swizzle = NO;
      HIDER_UNLOCK();
      return;
    }

    if ([self isKindOfClass:[CALayer class]]) {
      const char *cn = class_getName([self class]);
      if (cn && strstr(cn, "TileLayer")) {
        if (Hider_ShouldForceHideLayer((CALayer *)self)) {
          originalIMP(self, _cmd, YES);
          in_swizzle = NO;
          HIDER_UNLOCK();
          return;
        }
      }
    }
    if (separatorHiddenUntilRestart && Hider_IsSeparatorTileLayer(self)) {
      originalIMP(self, _cmd, YES);
      in_swizzle = NO;
      HIDER_UNLOCK();
      return;
    }
    originalIMP(self, _cmd, hidden);
    in_swizzle = NO;
    HIDER_UNLOCK();
  }
}

static void HiderGenericCALayerSetOpacityHook(id self, SEL _cmd, float opacity) {
  HiderFloatIMP originalIMP = (HiderFloatIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  @autoreleasepool {
    IF_HIDER_LOCKED() {
      originalIMP(self, _cmd, opacity);
      return;
    }
    HIDER_LOCK();
    static __thread BOOL in_op_swizzle = NO;
    if (in_op_swizzle) {
      originalIMP(self, _cmd, opacity);
      HIDER_UNLOCK();
      return;
    }
    in_op_swizzle = YES;
    if ([self isKindOfClass:[CALayer class]] &&
        Hider_IsInSuppressedSlot((CALayer *)self)) {
      originalIMP(self, _cmd, 0.0f);
      in_op_swizzle = NO;
      HIDER_UNLOCK();
      return;
    }
    {
      const char *cn = class_getName([self class]);
      if (cn && strstr(cn, "TileLayer")) {
        if ([self isKindOfClass:[CALayer class]] &&
            Hider_ShouldForceHideLayer((CALayer *)self)) {
          originalIMP(self, _cmd, 0.0f);
          in_op_swizzle = NO;
          HIDER_UNLOCK();
          return;
        }
      }
    }
    if (separatorHiddenUntilRestart && Hider_IsSeparatorTileLayer(self))
      originalIMP(self, _cmd, 0.0f);
    else
      originalIMP(self, _cmd, opacity);
    in_op_swizzle = NO;
    HIDER_UNLOCK();
  }
}

static void HiderGenericCALayerDrawInContextHook(id self, SEL _cmd,
                                                 CGContextRef ctx) {
  HiderCGContextIMP originalIMP =
      (HiderCGContextIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  if ([self isKindOfClass:[CALayer class]]) {
    CALayer *layer = (CALayer *)self;
    if (Hider_IsInSuppressedSlot(layer) || Hider_ShouldForceHideLayer(layer)) {
      CGRect rect = CGContextGetClipBoundingBox(ctx);
      CGContextClearRect(ctx, rect);
      return;
    }
  }
  if (separatorHiddenUntilRestart && Hider_IsSeparatorTileLayer(self)) {
    CGRect rect = CGContextGetClipBoundingBox(ctx);
    CGContextClearRect(ctx, rect);
    return;
  }
  originalIMP(self, _cmd, ctx);
}

static void HiderGenericCALayerLayoutSublayersHook(id self, SEL _cmd) {
  HiderVoidIMP originalIMP = (HiderVoidIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  @autoreleasepool {
    IF_HIDER_LOCKED() {
      originalIMP(self, _cmd);
      return;
    }
    HIDER_LOCK();
    originalIMP(self, _cmd);

    if ([self isKindOfClass:[CALayer class]] &&
        Hider_IsInSuppressedSlot((CALayer *)self)) {
      [(CALayer *)self setHidden:YES];
      [(CALayer *)self setOpacity:0.0f];
      HIDER_UNLOCK();
      return;
    }

    if (Hider_ShouldForceHideLayer((CALayer *)self)) {
      [(CALayer *)self setHidden:YES];
      [(CALayer *)self setOpacity:0.0f];
      Hider_SuppressSlot((CALayer *)self);
    } else if (separatorHiddenUntilRestart &&
               Hider_IsSeparatorTileLayer(self)) {
      [(CALayer *)self setHidden:YES];
      [(CALayer *)self setOpacity:0.0f];
    }

    const char *lcn = class_getName([self class]);
    if (lcn && (strstr(lcn, "FloorLayer") || strstr(lcn, "Container"))) {
      Hider_HideFloorSeparators((CALayer *)self);
    }
    HIDER_UNLOCK();
  }
}

static void HiderGenericCALayerAddAnimationHook(id self, SEL _cmd,
                                                CAAnimation *anim,
                                                NSString *key) {
  HiderCAAnimationIMP originalIMP =
      (HiderCAAnimationIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  @autoreleasepool {
    IF_HIDER_LOCKED() {
      originalIMP(self, _cmd, anim, key);
      return;
    }
    HIDER_LOCK();
    if ([self isKindOfClass:[CALayer class]]) {
      CALayer *layer = (CALayer *)self;
      if (Hider_IsInSuppressedSlot(layer) || Hider_ShouldForceHideLayer(layer)) {
        HIDER_UNLOCK();
        return;
      }
    }
    originalIMP(self, _cmd, anim, key);
    HIDER_UNLOCK();
  }
}

static void HiderGenericNSViewSetHiddenHook(id self, SEL _cmd, BOOL hidden) {
  HiderBoolIMP originalIMP = (HiderBoolIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  static __thread BOOL in_swizzle = NO;
  if (in_swizzle) {
    originalIMP(self, _cmd, hidden);
    return;
  }
  in_swizzle = YES;
  @try {
    NSString *bundleID = Hider_GetBundleID(self);
    BOOL forceHide = (separatorHiddenUntilRestart &&
                      Hider_IsSeparatorTileLayer(self));
    if (bundleID) {
      if (Hider_IsFinder(bundleID) && finderHidden) forceHide = YES;
      else if (Hider_IsTrash(bundleID) && trashHidden) forceHide = YES;
      else if (Hider_IsCustomHiddenApp(bundleID)) forceHide = YES;
    }
    originalIMP(self, _cmd, forceHide ? YES : hidden);
  } @finally {
    in_swizzle = NO;
  }
}

static void HiderGenericNSViewSetAlphaHook(id self, SEL _cmd, CGFloat alpha) {
  HiderCGFloatIMP originalIMP = (HiderCGFloatIMP)HiderDockOriginalIMP(self, _cmd);
  if (!originalIMP) return;

  BOOL forceZero = (separatorHiddenUntilRestart &&
                    Hider_IsSeparatorTileLayer(self));
  if (!forceZero) {
    NSString *bundleID = Hider_GetBundleID(self);
    if (bundleID) {
      if (Hider_IsFinder(bundleID) && finderHidden) forceZero = YES;
      else if (Hider_IsTrash(bundleID) && trashHidden) forceZero = YES;
      else if (Hider_IsCustomHiddenApp(bundleID)) forceZero = YES;
    }
  }
  originalIMP(self, _cmd, forceZero ? 0.0 : alpha);
}

static void swizzleDOCKTileLayer(void) {
  Class cls = NSClassFromString(@"DOCKTileLayer");
  if (!cls)
    return;

  (void)HiderInstallConcreteDockHook(cls, @selector(setHidden:),
                                     (IMP)HiderDOCKTileLayerSetHiddenHook);
  (void)HiderInstallConcreteDockHook(cls, @selector(setOpacity:),
                                     (IMP)HiderDOCKTileLayerSetOpacityHook);
  (void)HiderInstallConcreteDockHook(cls, @selector(drawInContext:),
                                     (IMP)HiderDOCKTileLayerDrawInContextHook);
  (void)HiderInstallConcreteDockHook(cls, @selector(layoutSublayers),
                                     (IMP)HiderDOCKTileLayerLayoutSublayersHook);
}

#pragma mark - Generic Swizzling (CALayer/NSView fallback)

void swizzleCALayer(void) {
  Class cls = [CALayer class];
  (void)HiderInstallConcreteDockHook(cls, @selector(setHidden:),
                                     (IMP)HiderGenericCALayerSetHiddenHook);
  (void)HiderInstallConcreteDockHook(cls, @selector(setOpacity:),
                                     (IMP)HiderGenericCALayerSetOpacityHook);
  (void)HiderInstallConcreteDockHook(cls, @selector(drawInContext:),
                                     (IMP)HiderGenericCALayerDrawInContextHook);
  (void)HiderInstallConcreteDockHook(cls, @selector(layoutSublayers),
                                     (IMP)HiderGenericCALayerLayoutSublayersHook);
  (void)HiderInstallConcreteDockHook(cls, @selector(addAnimation:forKey:),
                                     (IMP)HiderGenericCALayerAddAnimationHook);
}

void swizzleNSView(void) {
  Class cls = [NSView class];
  (void)HiderInstallConcreteDockHook(cls, @selector(setHidden:),
                                     (IMP)HiderGenericNSViewSetHiddenHook);
  (void)HiderInstallConcreteDockHook(cls, @selector(setAlphaValue:),
                                     (IMP)HiderGenericNSViewSetAlphaHook);
}

#pragma mark - DockCore Class Swizzling

static void swizzleDOCKTrashTile(Class cls) {
  if ([cls instancesRespondToSelector:NSSelectorFromString(@"update")]) {
    (void)HiderInstallConcreteDockHook(cls, NSSelectorFromString(@"update"),
                                       (IMP)HiderDOCKTrashTileUpdateHook);
  } else if ([cls instancesRespondToSelector:@selector(init)]) {
    (void)HiderInstallConcreteDockHook(cls, @selector(init),
                                       (IMP)HiderDOCKTrashTileInitHook);
  }
}

static void swizzleDOCKDesktopTile(Class cls) {
  if ([cls instancesRespondToSelector:NSSelectorFromString(@"update")]) {
    (void)HiderInstallConcreteDockHook(cls, NSSelectorFromString(@"update"),
                                       (IMP)HiderDOCKDesktopTileUpdateHook);
  } else if ([cls instancesRespondToSelector:@selector(init)]) {
    (void)HiderInstallConcreteDockHook(cls, @selector(init),
                                       (IMP)HiderDOCKDesktopTileInitHook);
  }

  NSArray *desktopBoolSetterNames = @[
    @"setActive:", @"setRunning:", @"setLaunching:",
    @"setShowsIndicator:", @"setIsRunning:", @"setIsActive:",
    @"setNeedsRedraw:", @"setShowIndicator:",
    @"setHighlighted:", @"setVisible:",
  ];
  HiderRuntimeSwizzleBoolSelectorsForConfiguredTileSuppression(
      cls, desktopBoolSetterNames);

  NSArray *desktopVoidMethodNames = @[
    @"updateRunningIndicator", @"_updateRunningIndicator",
    @"updateIndicator", @"_updateIndicator",
    @"updateVisibility", @"_updateVisibility",
    @"display", @"_display",
    @"updateIconImage", @"_updateIconImage",
    @"redisplay",
  ];
  HiderRuntimeSwizzleVoidSelectorsForConfiguredTileSuppression(
      cls, desktopVoidMethodNames);
}

static void swizzleDOCKFileTile(Class cls) {
  if ([cls instancesRespondToSelector:NSSelectorFromString(@"update")]) {
    (void)HiderInstallConcreteDockHook(cls, NSSelectorFromString(@"update"),
                                       (IMP)HiderDOCKFileTileUpdateHook);
  } else if ([cls instancesRespondToSelector:@selector(init)]) {
    (void)HiderInstallConcreteDockHook(cls, @selector(init),
                                       (IMP)HiderDOCKFileTileInitHook);
  }

  // ── DOCKFileTile lifecycle swizzles ─────────────────────────────────────
  // Same treatment as swizzleGenericAppTile: intercept every state setter and
  // void lifecycle method so the Dock cannot re-show a hidden tile when the
  // app becomes active or running.
  NSArray *ftBoolSetterNames = @[
    @"setActive:", @"setRunning:", @"setLaunching:",
    @"setShowsIndicator:", @"setIsRunning:", @"setIsActive:",
    @"setNeedsRedraw:", @"setShowIndicator:",
    @"setHighlighted:", @"setVisible:",
  ];
  HiderRuntimeSwizzleBoolSelectorsForConfiguredTileSuppression(
      cls, ftBoolSetterNames);

  NSArray *ftVoidMethodNames = @[
    @"updateRunningIndicator", @"_updateRunningIndicator",
    @"updateIndicator", @"_updateIndicator",
    @"updateVisibility", @"_updateVisibility",
    @"display", @"_display",
    @"updateIconImage", @"_updateIconImage",
    @"redisplay",
  ];
  HiderRuntimeSwizzleVoidSelectorsForConfiguredTileSuppression(
      cls, ftVoidMethodNames);
}

static void swizzleDOCKSpacerTile(Class cls) {
  // Determine once at swizzle time: DOCKSeparatorTile is the built-in
  // irremovable section divider between persistent-apps and persistent-others
  // (left of Trash). DOCKSpacerTile is a user-added spacer — never touched.
  BOOL isSeparatorTile = strcmp(class_getName(cls), "DOCKSeparatorTile") == 0;
  if (isSeparatorTile)
    HiderRegisterSeparatorTileClass(cls);

  if ([cls instancesRespondToSelector:NSSelectorFromString(@"update")]) {
    (void)HiderInstallConcreteDockHook(cls, NSSelectorFromString(@"update"),
                                       (IMP)HiderDOCKSpacerTileUpdateHook);
  } else if ([cls instancesRespondToSelector:NSSelectorFromString(@"updateRect")]) {
    (void)HiderInstallConcreteDockHook(cls, NSSelectorFromString(@"updateRect"),
                                       (IMP)HiderDOCKSpacerTileUpdateHook);
  } else if ([cls instancesRespondToSelector:@selector(init)]) {
    (void)HiderInstallConcreteDockHook(cls, @selector(init),
                                       (IMP)HiderDOCKSpacerTileInitHook);
  }

  (void)HiderInstallConcreteDockHook(cls, @selector(setHidden:),
                                     (IMP)HiderDOCKSpacerTileSetHiddenHook);
  if ([cls isSubclassOfClass:[NSView class]]) {
    (void)HiderInstallConcreteDockHook(cls, @selector(setAlphaValue:),
                                       (IMP)HiderDOCKSpacerTileSetAlphaHook);
    (void)HiderInstallConcreteDockHook(cls, @selector(drawRect:),
                                       (IMP)HiderDOCKSpacerTileDrawRectHook);
  }
  (void)HiderInstallConcreteDockHook(cls, @selector(layoutSublayers),
                                     (IMP)HiderDOCKSpacerTileLayoutSublayersHook);
}

static void swizzleDOCKFloorLayer(Class cls) {
  if (!cls)
    return;

  (void)HiderInstallConcreteDockHook(cls, @selector(layoutSublayers),
                                     (IMP)HiderDOCKFloorLayerLayoutSublayersHook);
  (void)HiderInstallConcreteDockHook(cls, @selector(addSublayer:),
                                     (IMP)HiderDOCKFloorLayerAddSublayerHook);
  (void)HiderInstallConcreteDockHook(cls, @selector(insertSublayer:atIndex:),
                                     (IMP)HiderDOCKFloorLayerInsertSublayerHook);

  LOG_TO_FILE("Swizzled floor layer: %s", class_getName(cls));
}

// Request tile removal with immediate+retry passes.
// Hidden custom apps stay visual-only here; persistent/system tiles may use
// Dock's private removal path.
static void Hider_RequestTileRemoval(id tile) {
  if (!tile) return;
  Hider_RunOnce(tile, &kHiderCustomAppRemoveKey, ^{
    __weak id weakTile = tile;

    NSString *bid = Hider_ResolveTileBundleID(tile);
    const char *tileClass = class_getName([tile class]);
    BOOL isCustomApp = bid && Hider_IsCustomHiddenApp(bid);
    LOG_TO_FILE("RequestTileRemoval: class=%s bid=%@ custom=%d",
                tileClass ? tileClass : "unknown", bid, isCustomApp ? 1 : 0);

    if (isCustomApp && bid.length > 0) {
      if (Hider_ApplyModelHiddenForBundle(bid, @"requestTileRemoval")) {
        Hider_PostDockPrefsChangedNotification();
      }
    }

    int64_t delays[] = {0, 80, 250, 900};
    for (int i = 0; i < 4; i++) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays[i] * (int64_t)NSEC_PER_MSEC),
                     dispatch_get_main_queue(), ^{
                       id t = weakTile;
                       if (!t) return;
                      if (isCustomApp) {
                        Hider_ApplyHiddenTilePipeline(t, bid, NO);
                        return;
                      }
                      Hider_SuppressTileRender(t);
                      [HiderDockActions removeDockTile:t];
                     });
    }
  });
}

// Helper: if `tile` is a hidden custom app, schedule a deferred visual-only
// pass after Dock has unwound the current lifecycle callback.
//
// WHY no synchronous Hider_SuppressTileRender:
//   Calling Hider_SuppressTileRender synchronously from a bool-setter hook
//   (setRunning:, setActive:, display, etc.) triggers [CATransaction commit],
//   which can trigger more display/layout hooks, which call this function
//   again — creating a tight synchronous loop that exhausts memory
//   (EXC_RESOURCE MEMORY > 560 MB) within seconds.
//
// Custom hidden apps intentionally stay off Dock's private removal path here.
// `doCommand:1004` is reserved for persistent/system tiles where Dock's model
// bookkeeping remains stable.
static void Hider_SuppressIfHidden(id tile) {
  if (!tile) return;

  NSString *bundleID = Hider_ResolveTileBundleID(tile);
  if (!bundleID || !Hider_IsCustomHiddenApp(bundleID)) return;

  Hider_RegisterTile(tile, bundleID);

  // Runtime post-hooks run after Dock mutates tile state. Schedule an immediate
  // deferred visual suppression pass so hidden running apps do not remain
  // visible until the next retry window.
  Hider_DeferForceRemoveHiddenTile(tile, bundleID, 0);
  HiderCustomAppDockHiderHandleVisibilityRefresh(tile);
}

static void Hider_SuppressConfiguredTileIfHidden(id tile) {
  if (!tile) return;

  NSString *bundleID = Hider_ResolveTileBundleID(tile);
  if (bundleID && Hider_IsFinder(bundleID) && finderHidden) {
    g_finderTileObject = tile;
    Hider_SuppressTileRender(tile);
    Hider_HideTileDecorations(tile);
    Hider_RunOnce(tile, "Hider_Finder_Lifecycle_Remove", ^{
      Hider_SendDockTileCommand(tile, 1004);
    });
    return;
  }

  if (bundleID && Hider_IsTrash(bundleID) && trashHidden) {
    g_trashTileObject = tile;
    Hider_SuppressTileRender(tile);
    Hider_HideTileDecorations(tile);
    Hider_RunOnce(tile, "Hider_Trash_Lifecycle_Remove", ^{
      Hider_SendDockTileCommand(tile, 1004);
    });
    return;
  }

  Hider_SuppressIfHidden(tile);
}

BOOL HiderCustomAppDockHiderIsBundleHidden(NSString *bundleID) {
  return Hider_IsCustomHiddenApp(bundleID);
}

NSString *HiderCustomAppDockHiderResolveTileBundleID(id tile) {
  return Hider_ResolveTileBundleID(tile);
}

NSString *HiderCustomAppDockHiderPreRegisteredBundleID(id tile) {
  if (!tile) return nil;
  id value = objc_getAssociatedObject(tile, &kHiderBundleIDTag);
  return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

void HiderCustomAppDockHiderRegisterTile(id tile, NSString *bundleID) {
  Hider_RegisterTile(tile, bundleID);
}

void HiderCustomAppDockHiderSuppressTileRender(id tile) {
  Hider_SuppressTileRender(tile);
}

void HiderCustomAppDockHiderDeferHiddenTileSuppression(id tile,
                                                       NSString *bundleID,
                                                       int64_t delayMs) {
  Hider_DeferForceRemoveHiddenTile(tile, bundleID, delayMs);
}

void swizzleDockCoreClasses(void) {
  // Hook the single gate through which all tiles enter DockBar's model.
  // Must be installed before any tile is inserted (i.e., before the class
  // scan below triggers generic tile swizzles).
  HiderInstallCustomAppDockHiderHooks();

  if (NSClassFromString(@"DOCKTileLayer"))
    swizzleDOCKTileLayer();

  Class modernFloor = NSClassFromString(@"_TtC8DockCore16ModernFloorLayer");
  if (modernFloor) {
    LOG_TO_FILE("Found ModernFloorLayer");
    swizzleDOCKFloorLayer(modernFloor);
  }

  Class legacyFloor = NSClassFromString(@"_TtC8DockCore16LegacyFloorLayer");
  if (legacyFloor) {
    LOG_TO_FILE("Found LegacyFloorLayer");
    swizzleDOCKFloorLayer(legacyFloor);
  }

  unsigned int classCount = 0;
  Class *classes = objc_copyClassList(&classCount);

  for (unsigned int i = 0; i < classCount; i++) {
    Class cls = classes[i];
    const char *name = class_getName(cls);
    if (strstr(name, "Dock") || strstr(name, "DOCK")) {
      // Check if this class or any superclass has already been handled in the 
      // specific-class chain to avoid redundant generic swizzles.
      BOOL isSpecific = (strcmp(name, "DOCKTrashTile") == 0 ||
                        strcmp(name, "DOCKFileTile") == 0 ||
                        strcmp(name, "DOCKDesktopTile") == 0 ||
                        strcmp(name, "DOCKSeparatorTile") == 0 ||
                        strcmp(name, "DOCKSpacerTile") == 0);

      if (strcmp(name, "DOCKTrashTile") == 0) {
        LOG_TO_FILE("Swizzling trash tile class: %s", name);
        swizzleDOCKTrashTile(cls);
      } else if (strcmp(name, "DOCKFileTile") == 0) {
        LOG_TO_FILE("Swizzling file tile class: %s", name);
        swizzleDOCKFileTile(cls);
      } else if (strcmp(name, "DOCKDesktopTile") == 0) {
        LOG_TO_FILE("Swizzling desktop tile class: %s", name);
        swizzleDOCKDesktopTile(cls);
      } else if (strcmp(name, "DOCKSeparatorTile") == 0 ||
                 strcmp(name, "DOCKSpacerTile") == 0) {
        LOG_TO_FILE("Swizzling spacer/separator class: %s", name);
        swizzleDOCKSpacerTile(cls);
      } else if (!isSpecific &&
                 HiderCustomAppDockHiderClassLooksLikeTileClass(cls, name)) {
        // Catch all remaining DOCK tile classes — DOCKApplicationTile,
        // DOCKURLTile, DOCKRunningAppTile, etc. — for custom hidden-app
        // tracking.
        LOG_TO_FILE("Swizzling generic tile class: %s", name);
        HiderCustomAppDockHiderSwizzleTileClass(cls);
      }

      // addProcessForASN swizzle removed: on arm64e, calling originalIMP via
      // imp_implementationWithBlock trampoline crashes inside the Swift DockBar
      // implementation (PAC signing mismatch in the call chain). Tile removal
      // is handled exclusively by the init/update/bundleIdentifier hooks above.
    }
  }
  free(classes);
}

#pragma mark - Initialization

static int tokenHideFinder, tokenShowFinder, tokenToggleFinder;
static int tokenHideTrash, tokenShowTrash, tokenToggleTrash;
static int tokenHideAll, tokenShowAll;
static int tokenDump;
static int tokenClassDump;

// Debounce: coalesce rapid settingsChanged bursts into one refresh
static BOOL g_pendingRefresh = NO;

__attribute__((constructor)) static void Hider_Init(void) {
  @autoreleasepool {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.dock"])
      return;

    // Install crash signal trap first so any early crash is logged.
    Hider_InstallSignalTrap();
    LOG_TO_FILE("Hider_Init: starting (signal trap installed)");

    Hider_LoadSettings();
    HiderInstallHooks();

    // On initial injection apply current settings so a freshly-restarted Dock
    // starts with the correct pref state (e.g. separators absent when trash is
    // hidden).  g_prev* are all NO at this point, so refresh_dock treats every
    // enabled setting as a fresh transition and removes items from prefs.
    // Stagger two passes: first at 300 ms (Dock is likely ready), second at
    // 800 ms as a belt-and-suspenders in case startup takes longer.
    void (^initRefresh)(void) = ^{
      Hider_LoadSettings();
      [HiderDockActions refreshDock];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), initRefresh);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), initRefresh);

    // Settings changes and hidden-app additions share the same authoritative
    // model-first pipeline so both paths behave identically for running apps.
    void (^handleSettingsEvent)(BOOL, NSString *) = ^(BOOL hiddenAppAdded, NSString *eventName) {
      if (g_pendingRefresh) return;
      g_pendingRefresh = YES;
      dispatch_async(dispatch_get_main_queue(), ^{
        g_pendingRefresh = NO;
        LOG_TO_FILE("Settings event: %@ (hiddenAppAdded=%d)", eventName,
                    hiddenAppAdded ? 1 : 0);
        Hider_LoadSettings();

        if (hiddenAppAdded && g_customAppTileObjects) {
          NSSet *snap = [g_hiddenAppBundleIDs copy];
          for (NSString *bid in snap) {
            id tile = [g_customAppTileObjects objectForKey:bid];
            if (!tile) continue;
            objc_setAssociatedObject(tile, &kHiderCustomAppRemoveKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
          }
        }

        [HiderDockActions refreshDock];
        Hider_ApplyAuthoritativeHiddenAppsModelState(eventName);

        if (hiddenAppAdded) {
          const int64_t followups[] = {450};
          Hider_ScheduleHotloadPasses(NO, followups, 1);
        } else {
          const int64_t hotloadDelays[] = {200};
          Hider_ScheduleHotloadPasses(YES, hotloadDelays, 1);
        }
      });
    };

    // Settings changed — debounced to prevent notification storm loops.
    int settingsToken;
    notify_register_dispatch(
        "com.aspauldingcode.hider.settingsChanged", &settingsToken,
        dispatch_get_main_queue(), ^(__unused int t) {
          handleSettingsEvent(NO, @"settingsChanged");
        });

    int hiddenAppAddedToken;
    notify_register_dispatch(
        "com.aspauldingcode.hider.hiddenAppAdded", &hiddenAppAddedToken,
        dispatch_get_main_queue(), ^(__unused int t) {
          handleSettingsEvent(YES, @"hiddenAppAdded");
        });

    notify_register_dispatch("com.hider.finder.hide", &tokenHideFinder,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideFinderIcon(YES);
                             });
    notify_register_dispatch("com.hider.finder.show", &tokenShowFinder,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideFinderIcon(NO);
                             });
    notify_register_dispatch("com.hider.finder.toggle", &tokenToggleFinder,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               BOOL hidden = (BOOL)Hider_IsFinderIconHidden();
                               Hider_HideFinderIcon(!hidden);
                             });

    notify_register_dispatch("com.hider.trash.hide", &tokenHideTrash,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideTrashIcon(YES);
                             });
    notify_register_dispatch("com.hider.trash.show", &tokenShowTrash,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideTrashIcon(NO);
                             });
    notify_register_dispatch("com.hider.trash.toggle", &tokenToggleTrash,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               BOOL hidden = (BOOL)Hider_IsTrashIconHidden();
                               Hider_HideTrashIcon(!hidden);
                             });

    notify_register_dispatch("com.hider.dump", &tokenDump,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_DumpDockHierarchy();
                             });
    notify_register_dispatch("com.hider.classdump", &tokenClassDump,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_DumpDockClasses();
                             });

    notify_register_dispatch("com.hider.hideall", &tokenHideAll,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideFinderIcon(YES);
                               Hider_HideTrashIcon(YES);
                             });

    notify_register_dispatch("com.hider.showall", &tokenShowAll,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideFinderIcon(NO);
                               Hider_HideTrashIcon(NO);
                             });

    // Watch for app launches: hidden apps must be suppressed immediately.
    // Uses Hider_EnforceHiddenApps (which does PID discovery + _rootLayer
    // fallback + layer suppression + slot tagging) on an aggressive schedule
    // so the icon never visually appears, even briefly.
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceDidLaunchApplicationNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
          NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
          NSString *bid = app.bundleIdentifier;
          Hider_LoadSettingsFromCache();
          if (!bid || !Hider_IsCustomHiddenApp(bid)) return;

          LOG_TO_FILE("Hidden app launched: %@", bid);
          NSString *normalized = Hider_NormalizeBundleID(bid);
          pid_t appPID = app.processIdentifier;

          int64_t removeDelays[] = {120, 450, 1200};
          Hider_ScheduleAppEnforcementPasses(normalized, appPID, YES, NO,
                                             removeDelays, 3);
        }];

    // Watch for app activations: when a hidden app becomes the active
    // (frontmost) app, the Dock normally re-shows its tile and indicator.
    // Re-suppress immediately so the tile never visually reappears.
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceDidActivateApplicationNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
          NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
          NSString *bid = app.bundleIdentifier;
          Hider_LoadSettingsFromCache();
          if (!bid || !Hider_IsCustomHiddenApp(bid)) return;

          LOG_TO_FILE("Hidden app activated: %@", bid);
          NSString *normalized = Hider_NormalizeBundleID(bid);
          pid_t appPID = app.processIdentifier;

          int64_t delays[] = {0, 120, 400};
          Hider_ScheduleAppEnforcementPasses(normalized, appPID, YES, NO,
                                             delays, 3);
        }];

    // Watch for app deactivations: the Dock updates indicator state when an
    // app resigns active status.  Re-suppress so indicator dots don't creep
    // back in for hidden apps.
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceDidDeactivateApplicationNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
          NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
          NSString *bid = app.bundleIdentifier;
          Hider_LoadSettingsFromCache();
          if (!bid || !Hider_IsCustomHiddenApp(bid)) return;

          NSString *normalized = Hider_NormalizeBundleID(bid);
          pid_t appPID = app.processIdentifier;

          int64_t delays[] = {50, 250};
          Hider_ScheduleAppEnforcementPasses(normalized, appPID, NO, NO,
                                             delays, 2);
        }];

    LOG_TO_FILE("Hider_Init: complete");
  }
}
