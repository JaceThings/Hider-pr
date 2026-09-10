#import "HiderCustomAppDockHider.h"

#import <dispatch/dispatch.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu-zero-variadic-macro-arguments"
#define HIDER_CUSTOM_DOCK_LOG(fmt, ...)                                          \
  do {                                                                           \
    NSString *_fmt = [NSString stringWithUTF8String:fmt];                        \
    Hider_LogToFile(__FUNCTION__, __LINE__, _fmt, ##__VA_ARGS__);                \
  } while (0)
#pragma clang diagnostic pop

static CFMutableSetRef gHiderCustomDockHookedClasses = NULL;
static NSMutableDictionary<NSString *, NSNumber *> *gHiderCustomDockOriginalIMPs = nil;

typedef void (*HiderDockBarInsertTileIMP)(id, SEL, id, long long, id);
typedef void (*HiderVoidMethodIMP)(id, SEL);
typedef id (*HiderObjectMethodIMP)(id, SEL);

static NSString *HiderCustomAppDockHiderHookKey(Class cls, SEL sel) {
  return [NSString stringWithFormat:@"%@/%@", NSStringFromClass(cls),
                                    NSStringFromSelector(sel)];
}

static void HiderCustomAppDockHiderRememberOriginalIMP(Class cls, SEL sel,
                                                       IMP imp) {
  if (!cls || !sel || !imp) return;
  if (!gHiderCustomDockOriginalIMPs) {
    gHiderCustomDockOriginalIMPs = [NSMutableDictionary dictionary];
  }
  gHiderCustomDockOriginalIMPs[HiderCustomAppDockHiderHookKey(cls, sel)] =
      @((uintptr_t)imp);
}

static IMP HiderCustomAppDockHiderOriginalIMPForObject(id object, SEL sel) {
  if (!object || !sel || !gHiderCustomDockOriginalIMPs) return NULL;

  Class cls = object_getClass(object);
  while (cls) {
    NSNumber *boxed =
        gHiderCustomDockOriginalIMPs[HiderCustomAppDockHiderHookKey(cls, sel)];
    if (boxed) return (IMP)(uintptr_t)boxed.unsignedLongLongValue;
    cls = class_getSuperclass(cls);
  }
  return NULL;
}

static BOOL HiderCustomAppDockHiderInstallConcreteHook(Class cls, SEL sel,
                                                       IMP replacement) {
  if (!cls || !sel || !replacement) return NO;

  Method method = class_getInstanceMethod(cls, sel);
  if (!method) return NO;

  const char *types = method_getTypeEncoding(method);
  IMP inheritedIMP = method_getImplementation(method);

  // Make the concrete class own the selector first so we never mutate an
  // inherited Method entry shared by other Dock classes.
  if (class_addMethod(cls, sel, inheritedIMP, types)) {
    method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
  }

  IMP originalIMP = method_setImplementation(method, replacement);
  HiderCustomAppDockHiderRememberOriginalIMP(cls, sel, originalIMP);
  return YES;
}

static BOOL HiderCustomAppDockHiderShouldHideBundleID(NSString *bundleID) {
  return bundleID.length > 0 &&
         HiderCustomAppDockHiderIsBundleHidden(bundleID);
}

static void HiderCustomAppDockHiderScheduleSuppression(id tile,
                                                       NSString *bundleID,
                                                       const int64_t *delays,
                                                       size_t delayCount) {
  if (!tile || bundleID.length == 0) return;

  HiderCustomAppDockHiderRegisterTile(tile, bundleID);
  if (!HiderCustomAppDockHiderIsBundleHidden(bundleID)) return;

  for (size_t i = 0; i < delayCount; i++) {
    HiderCustomAppDockHiderDeferHiddenTileSuppression(tile, bundleID,
                                                      delays[i]);
  }
}

static void HiderCustomAppDockHiderSchedulePostInsertSuppression(
    id tile, NSString *bundleID) {
  __weak id weakTile = tile;
  NSString *bundleIDCopy = bundleID ? [bundleID copy] : nil;
  dispatch_async(dispatch_get_main_queue(), ^{
    id strongTile = weakTile;
    if (!strongTile) return;

    NSString *effectiveBundleID = bundleIDCopy;
    if (effectiveBundleID.length == 0) {
      effectiveBundleID =
          HiderCustomAppDockHiderResolveTileBundleID(strongTile);
      if (effectiveBundleID.length > 0) {
        HiderCustomAppDockHiderRegisterTile(strongTile, effectiveBundleID);
        HIDER_CUSTOM_DOCK_LOG("custom insertTile: late-discovered %@",
                              effectiveBundleID);
      }
    }

    if (!HiderCustomAppDockHiderShouldHideBundleID(effectiveBundleID)) return;

    // Render suppression is the safe path here. Keeping the running tile in
    // DockBar's model avoids separator-index corruption inside Dock's Swift
    // bookkeeping while still making the tile disappear visually.
    HiderCustomAppDockHiderSuppressTileRender(strongTile);
  });
}

static void HiderCustomAppDockHiderHandleLifecycleObject(id object) {
  NSString *bundleID = HiderCustomAppDockHiderResolveTileBundleID(object);
  if (bundleID.length == 0) return;

  static const int64_t delays[] = {0, 180, 500, 1200};
  HiderCustomAppDockHiderScheduleSuppression(object, bundleID, delays,
                                             sizeof(delays) / sizeof(delays[0]));
}

static void HiderCustomAppDockHiderHandleInitObject(id object) {
  NSString *bundleID = HiderCustomAppDockHiderResolveTileBundleID(object);
  if (bundleID.length == 0) return;

  static const int64_t delays[] = {0, 220, 600, 1400};
  HiderCustomAppDockHiderScheduleSuppression(object, bundleID, delays,
                                             sizeof(delays) / sizeof(delays[0]));
}

static void HiderCustomAppDockHiderHandleBundleIdentifierValue(id object,
                                                               id value) {
  if (![value isKindOfClass:[NSString class]]) return;

  static const int64_t delays[] = {0, 300};
  HiderCustomAppDockHiderScheduleSuppression(object, (NSString *)value, delays,
                                             sizeof(delays) / sizeof(delays[0]));
}

static void HiderCustomAppDockHiderHandleFileURLValue(id object, id value) {
  if (![value isKindOfClass:[NSURL class]]) return;

  NSBundle *bundle = [NSBundle bundleWithURL:(NSURL *)value];
  NSString *bundleID = bundle.bundleIdentifier;
  if (bundleID.length == 0) return;

  static const int64_t delays[] = {0, 300};
  HiderCustomAppDockHiderScheduleSuppression(object, bundleID, delays,
                                             sizeof(delays) / sizeof(delays[0]));
}

static void HiderCustomAppDockHiderDockBarInsertTileHook(id self, SEL _cmd,
                                                         id tile, long long idx,
                                                         id reason) {
  HiderDockBarInsertTileIMP originalIMP =
      (HiderDockBarInsertTileIMP)HiderCustomAppDockHiderOriginalIMPForObject(
          self, _cmd);
  if (!originalIMP) return;

  if (!tile) {
    originalIMP(self, _cmd, tile, idx, reason);
    return;
  }

  NSString *bundleID = HiderCustomAppDockHiderPreRegisteredBundleID(tile);
  BOOL shouldHide = HiderCustomAppDockHiderShouldHideBundleID(bundleID);
  HIDER_CUSTOM_DOCK_LOG("custom insertTile: cls=%s idx=%lld bid=%@ shouldHide=%d",
                        class_getName([tile class]), idx,
                        bundleID ? bundleID : @"(nil-not-pre-registered)",
                        shouldHide ? 1 : 0);

  if (shouldHide) {
    HiderCustomAppDockHiderRegisterTile(tile, bundleID);
  }

  originalIMP(self, _cmd, tile, idx, reason);
  HiderCustomAppDockHiderSchedulePostInsertSuppression(tile, bundleID);
}

static void HiderCustomAppDockHiderUpdateHook(id self, SEL _cmd) {
  HiderVoidMethodIMP originalIMP =
      (HiderVoidMethodIMP)HiderCustomAppDockHiderOriginalIMPForObject(self, _cmd);
  if (!originalIMP) return;

  originalIMP(self, _cmd);
  HiderCustomAppDockHiderHandleLifecycleObject(self);
}

static id HiderCustomAppDockHiderInitHook(id self, SEL _cmd) {
  HiderObjectMethodIMP originalIMP =
      (HiderObjectMethodIMP)HiderCustomAppDockHiderOriginalIMPForObject(self, _cmd);
  if (!originalIMP) return self;

  id result = originalIMP(self, _cmd);
  HiderCustomAppDockHiderHandleInitObject(result ? result : self);
  return result;
}

static id HiderCustomAppDockHiderBundleIdentifierHook(id self, SEL _cmd) {
  HiderObjectMethodIMP originalIMP =
      (HiderObjectMethodIMP)HiderCustomAppDockHiderOriginalIMPForObject(self, _cmd);
  if (!originalIMP) return nil;

  id value = originalIMP(self, _cmd);
  HiderCustomAppDockHiderHandleBundleIdentifierValue(self, value);
  return value;
}

static id HiderCustomAppDockHiderFileURLHook(id self, SEL _cmd) {
  HiderObjectMethodIMP originalIMP =
      (HiderObjectMethodIMP)HiderCustomAppDockHiderOriginalIMPForObject(self, _cmd);
  if (!originalIMP) return nil;

  id value = originalIMP(self, _cmd);
  HiderCustomAppDockHiderHandleFileURLValue(self, value);
  return value;
}

__attribute__((unused))
static void HiderCustomAppDockHiderSwizzleDockBarInsertTile(void) {
  Class cls = NSClassFromString(@"DockBar");
  if (!cls) {
    HIDER_CUSTOM_DOCK_LOG("custom-app dock hider: DockBar class not found");
    return;
  }

  SEL insertSel = NSSelectorFromString(@"insertTile:atIndex:forReason:");
  Method method = class_getInstanceMethod(cls, insertSel);
  if (!method) {
    HIDER_CUSTOM_DOCK_LOG("custom-app dock hider: DockBar insertTile hook not found");
    return;
  }
  if (!HiderCustomAppDockHiderInstallConcreteHook(
          cls, insertSel, (IMP)HiderCustomAppDockHiderDockBarInsertTileHook)) {
    HIDER_CUSTOM_DOCK_LOG("custom-app dock hider: failed to hook DockBar insertTile");
    return;
  }
  HIDER_CUSTOM_DOCK_LOG("custom-app dock hider: hooked DockBar insertTile");
}

BOOL HiderCustomAppDockHiderClassLooksLikeTileClass(Class cls,
                                                    const char *name) {
  if (!cls || !name) return NO;
  if (strstr(name, "TileLayer")) return NO;
  if (strstr(name, "Tile")) return YES;

  BOOL hasLifecycle =
      [cls instancesRespondToSelector:NSSelectorFromString(@"setRunning:")] ||
      [cls instancesRespondToSelector:NSSelectorFromString(@"setActive:")] ||
      [cls instancesRespondToSelector:NSSelectorFromString(@"update")];
  if (!hasLifecycle) return NO;

  BOOL hasIdentity =
      [cls instancesRespondToSelector:NSSelectorFromString(@"bundleIdentifier")] ||
      [cls instancesRespondToSelector:NSSelectorFromString(@"application")] ||
      [cls instancesRespondToSelector:NSSelectorFromString(@"runningApplication")] ||
      [cls instancesRespondToSelector:NSSelectorFromString(@"processIdentifier")];
  if (!hasIdentity) return NO;

  return strstr(name, "App") != NULL || strstr(name, "Process") != NULL ||
         strstr(name, "Running") != NULL;
}

void HiderCustomAppDockHiderHandleFileTileLifecycle(id tile,
                                                    NSString *bundleID) {
  static const int64_t delays[] = {0, 120, 450, 1200};
  HiderCustomAppDockHiderScheduleSuppression(tile, bundleID, delays,
                                             sizeof(delays) / sizeof(delays[0]));
}

void HiderCustomAppDockHiderHandleVisibilityRefresh(id tile) {
  NSString *bundleID = HiderCustomAppDockHiderResolveTileBundleID(tile);
  if (!bundleID || !HiderCustomAppDockHiderIsBundleHidden(bundleID)) return;

  static const int64_t delays[] = {0, 80, 250, 700};
  HiderCustomAppDockHiderScheduleSuppression(tile, bundleID, delays,
                                             sizeof(delays) / sizeof(delays[0]));
}

void HiderCustomAppDockHiderSwizzleTileClass(Class cls) {
  if (!cls) return;

  if (!gHiderCustomDockHookedClasses) {
    gHiderCustomDockHookedClasses = CFSetCreateMutable(NULL, 0, NULL);
  }
  if (!gHiderCustomDockHookedClasses) return;
  if (CFSetContainsValue(gHiderCustomDockHookedClasses,
                         (__bridge const void *)cls)) {
    HIDER_CUSTOM_DOCK_LOG("custom-app dock hider: skip %s (already hooked)",
                          class_getName(cls));
    return;
  }
  CFSetAddValue(gHiderCustomDockHookedClasses, (__bridge const void *)cls);

  SEL updateSel = NSSelectorFromString(@"update");
  if ([cls instancesRespondToSelector:updateSel]) {
    (void)HiderCustomAppDockHiderInstallConcreteHook(
        cls, updateSel, (IMP)HiderCustomAppDockHiderUpdateHook);
  }

  SEL initSel = @selector(init);
  if ([cls instancesRespondToSelector:initSel]) {
    (void)HiderCustomAppDockHiderInstallConcreteHook(
        cls, initSel, (IMP)HiderCustomAppDockHiderInitHook);
  }

  SEL bundleIDSel = @selector(bundleIdentifier);
  if ([cls instancesRespondToSelector:bundleIDSel]) {
    (void)HiderCustomAppDockHiderInstallConcreteHook(
        cls, bundleIDSel, (IMP)HiderCustomAppDockHiderBundleIdentifierHook);
  }

  SEL fileURLSel = @selector(fileURL);
  if ([cls instancesRespondToSelector:fileURLSel]) {
    (void)HiderCustomAppDockHiderInstallConcreteHook(
        cls, fileURLSel, (IMP)HiderCustomAppDockHiderFileURLHook);
  }

  if (strcmp(class_getName(cls), "DOCKProcessTile") == 0) {
    NSArray *probeNames = @[
      @"processIdentifier", @"pid", @"_pid",
      @"bundleIdentifier", @"bundleID", @"_bundleID",
      @"application", @"runningApplication",
      @"item", @"model", @"objectValue",
      @"url", @"fileURL", @"URL",
      @"setActive:", @"setRunning:", @"setLaunching:",
      @"update", @"init",
      @"applicationBundleIdentifier", @"appBundleID",
    ];
    NSMutableString *found = [NSMutableString string];
    for (NSString *selectorName in probeNames) {
      if ([cls instancesRespondToSelector:NSSelectorFromString(selectorName)]) {
        [found appendFormat:@" %@", selectorName];
      }
    }
    HIDER_CUSTOM_DOCK_LOG("custom-app dock hider: DOCKProcessTile selectors:%@",
                          found);
  }
}

void HiderInstallCustomAppDockHiderHooks(void) {
  // Safety valve: the post-insert DockBar hook has been the common caller on
  // the Dock crash stack. Keep the lifecycle/file tile hooks enabled so hidden
  // apps still get discovered and visually suppressed, but leave DockBar's
  // insertion path untouched until it can be proven safe on this Dock build.
  HIDER_CUSTOM_DOCK_LOG("custom-app dock hider: DockBar insertTile hook disabled");
}
