#import "HiderActions.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

void HiderBridgeRefreshDock(void);
NSString *HiderBridgeResolveTileBundleID(id tile);

static BOOL HiderInvokeSelectorInt(id target, SEL selector, NSInteger value) {
  if (!target || !selector || ![target respondsToSelector:selector]) return NO;
  NSMethodSignature *sig = [target methodSignatureForSelector:selector];
  if (!sig || sig.numberOfArguments != 3) return NO;

  const char *argType = [sig getArgumentTypeAtIndex:2];
  if (!argType || !strchr("cCsSiIlLqQB", argType[0])) return NO;

  @try {
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, selector, value);
    return YES;
  } @catch (__unused NSException *e) {
    return NO;
  }
}

static BOOL HiderInvokeSelectorObject(id target, SEL selector, id object) {
  if (!target || !selector || ![target respondsToSelector:selector]) return NO;
  NSMethodSignature *sig = [target methodSignatureForSelector:selector];
  if (!sig || sig.numberOfArguments != 3) return NO;

  const char *argType = [sig getArgumentTypeAtIndex:2];
  if (!argType || argType[0] != '@') return NO;

  @try {
    ((void (*)(id, SEL, id))objc_msgSend)(target, selector, object);
    return YES;
  } @catch (__unused NSException *e) {
    return NO;
  }
}



@implementation HiderDockActions

+ (CALayer *)layerForTile:(id)tile {
  if (!tile) return nil;
  if ([tile isKindOfClass:[CALayer class]]) return (CALayer *)tile;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  SEL layerSel = @selector(layer);
  if ([tile respondsToSelector:layerSel]) {
    id layer = [tile performSelector:layerSel];
    if ([layer isKindOfClass:[CALayer class]]) return (CALayer *)layer;
  }
#pragma clang diagnostic pop
  return nil;
}

+ (NSView *)viewForTile:(id)tile {
  if (!tile) return nil;
  if ([tile isKindOfClass:[NSView class]]) return (NSView *)tile;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  SEL viewSel = @selector(view);
  if ([tile respondsToSelector:viewSel]) {
    id view = [tile performSelector:viewSel];
    if ([view isKindOfClass:[NSView class]]) return (NSView *)view;
  }
#pragma clang diagnostic pop

  CALayer *layer = [self layerForTile:tile];
  if ([layer.delegate isKindOfClass:[NSView class]]) {
    return (NSView *)layer.delegate;
  }
  return nil;
}

+ (BOOL)isFloorLikeLayer:(CALayer *)layer {
  if (!layer) return NO;
  const char *cn = class_getName([layer class]);
  return cn && strstr(cn, "FloorLayer");
}

+ (BOOL)isIndicatorLikeObject:(id)object {
  if (!object) return NO;
  const char *cn = class_getName([object class]);
  if (cn && (strstr(cn, "Indicator") || strstr(cn, "Running") || strstr(cn, "Dot"))) return YES;

  if ([object isKindOfClass:[CALayer class]]) {
    id delegate = [(CALayer *)object delegate];
    if (delegate && delegate != object) {
      return [self isIndicatorLikeObject:delegate];
    }
  }

  return NO;
}

+ (BOOL)isSeparatorLikeObject:(id)object {
  if (!object) return NO;
  const char *cn = class_getName([object class]);
  return cn && (strstr(cn, "Separator") || strstr(cn, "Spacer"));
}

+ (NSString *)removalThrottleIdentifierForTile:(id)tile {
  NSString *bundleID = HiderBridgeResolveTileBundleID(tile);
  if (bundleID.length > 0) {
    return [@"bundle:" stringByAppendingString:bundleID];
  }
  if ([self isSeparatorLikeObject:tile]) {
    return @"separator";
  }
  return [NSString stringWithFormat:@"ptr:%p", (__bridge void *)tile];
}

+ (BOOL)shouldSendRemoveCommandForTile:(id)tile {
  static NSMutableDictionary<NSString *, NSNumber *> *recentRemovalTimes = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    recentRemovalTimes = [NSMutableDictionary dictionary];
  });

  NSString *identifier = [self removalThrottleIdentifierForTile:tile];
  CFTimeInterval now = CACurrentMediaTime();
  NSNumber *lastIssued = recentRemovalTimes[identifier];
  if (lastIssued && (now - lastIssued.doubleValue) < 1.0) {
    return NO;
  }
  recentRemovalTimes[identifier] = @(now);
  return YES;
}

+ (void)hideLayerTree:(CALayer *)layer {
  if (!layer) return;

  if (layer.hidden && layer.opacity == 0.0f) {
    // Branch is already suppressed; skip O(N) sublayer walk.
    return;
  }

  [layer removeAllAnimations];
  layer.hidden = YES;
  layer.opacity = 0.0f;
  layer.contents = nil;
  layer.backgroundColor = NSColor.clearColor.CGColor;

  NSArray *subs = layer.sublayers;
  NSUInteger count = subs.count;
  for (NSUInteger i = 0; i < count; i++) {
    [self hideLayerTree:subs[i]];
  }
}

+ (void)hideIndicatorLayersNearRect:(CGRect)targetRect
                            inLayer:(CALayer *)container
                       excludingTree:(CALayer *)excluded {
  if (!container) return;

  CGRect expandedRect = CGRectInset(targetRect, -24.0, -24.0);
  NSArray *subs = container.sublayers;
  NSUInteger count = subs.count;
  for (NSUInteger i = 0; i < count; i++) {
    CALayer *sub = subs[i];
    if (sub == excluded) continue;
    // Safety check for already-hidden paths.
    if (sub.hidden && sub.opacity == 0.0f && !sub.sublayers.count) continue;

    CGRect subRect = [sub convertRect:sub.bounds toLayer:container];
    BOOL intersects = CGRectIntersectsRect(expandedRect, subRect);
    
    // Pruning: if this branch doesn't even intersect our expanded search area,
    // skip its children. This avoids O(N) walks of the entire Dock for every tile.
    if (!intersects) continue;

    if ([self isIndicatorLikeObject:sub]) {
      [self hideLayerTree:sub];
      if ([sub.delegate isKindOfClass:[NSView class]]) {
        [self hideViewTree:(NSView *)sub.delegate];
      }
    }

    [self hideIndicatorLayersNearRect:targetRect inLayer:sub excludingTree:excluded];
  }
}

+ (void)hideViewTree:(NSView *)view {
  if (!view) return;

  if (view.hidden && view.alphaValue == 0.0) {
    // Branch is already suppressed; skip O(N) subview walk.
    return;
  }

  view.hidden = YES;
  view.alphaValue = 0.0;
  if (view.layer) {
    [self hideLayerTree:view.layer];
  }

  NSArray *subviews = view.subviews;
  NSUInteger count = subviews.count;
  for (NSUInteger i = 0; i < count; i++) {
    [self hideViewTree:subviews[i]];
  }
}

+ (void)hideIndicatorViewsNearRect:(CGRect)targetRect
                            inView:(NSView *)container
                      excludingView:(NSView *)excluded {
  if (!container) return;

  CGRect expandedRect = CGRectInset(targetRect, -24.0, -24.0);
  NSArray *subviews = container.subviews;
  NSUInteger count = subviews.count;
  for (NSUInteger i = 0; i < count; i++) {
    NSView *subview = subviews[i];
    if (subview == excluded) continue;

    CGRect subRect = [subview convertRect:subview.bounds toView:container];
    BOOL intersects = NSIntersectsRect(expandedRect, subRect);
    if ([self isIndicatorLikeObject:subview] && intersects) {
      [self hideViewTree:subview];
    }

    [self hideIndicatorViewsNearRect:targetRect inView:subview excludingView:excluded];
  }
}

+ (void)suppressIndicatorStateForObject:(id)object {
  if (!object) return;

  NSArray<NSString *> *falseSelectors = @[
    @"setShowsIndicator:", @"setShowIndicator:",
    @"setRunning:", @"setIsRunning:",
    @"setActive:", @"setIsActive:",
    @"setHighlighted:", @"setVisible:",
  ];

  for (NSString *selectorName in falseSelectors) {
    SEL sel = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:sel]) {
      ((void (*)(id, SEL, BOOL))objc_msgSend)(object, sel, NO);
    }
  }

  NSArray<NSString *> *refreshSelectors = @[
    @"updateRunningIndicator", @"_updateRunningIndicator",
    @"updateIndicator", @"_updateIndicator",
    @"updateVisibility", @"_updateVisibility",
    @"display", @"_display",
    @"redisplay",
  ];

  for (NSString *selectorName in refreshSelectors) {
    SEL sel = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:sel]) {
      ((void (*)(id, SEL))objc_msgSend)(object, sel);
    }
  }
}

+ (void)suppressDockTile:(id)tile {
  CALayer *layer = [self layerForTile:tile];
  NSView *view = [self viewForTile:tile];
  id layerDelegate = layer.delegate;
  [self suppressIndicatorStateForObject:tile];
  if (layerDelegate && layerDelegate != tile) {
    [self suppressIndicatorStateForObject:layerDelegate];
  }
  if (view && view != tile && (id)view != layerDelegate) {
    [self suppressIndicatorStateForObject:view];
  }

  if (layer) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    CALayer *slotLayer = layer.superlayer;
    CALayer *floorLayer = slotLayer;
    while (floorLayer && ![self isFloorLikeLayer:floorLayer]) {
      floorLayer = floorLayer.superlayer;
    }
    CALayer *searchLayer = floorLayer ? floorLayer : slotLayer;

    if (slotLayer && ![self isFloorLikeLayer:slotLayer]) {
      [self hideLayerTree:slotLayer];
    } else {
      [self hideLayerTree:layer];
    }

    if (searchLayer) {
      CGRect targetRect = [layer convertRect:layer.bounds toLayer:searchLayer];
      [self hideIndicatorLayersNearRect:targetRect
                                inLayer:searchLayer
                           excludingTree:layer];
    }
    [CATransaction commit];
    [CATransaction flush];
  }

  if (view) {
    NSView *slotView = view.superview;
    NSView *searchView = slotView;
    while (searchView) {
      const char *vcn = class_getName([searchView class]);
      if (vcn && strstr(vcn, "Floor")) break;
      if (!searchView.superview) break;
      searchView = searchView.superview;
    }

    if (slotView && slotView != view) {
      const char *svcn = class_getName([slotView class]);
      if (!svcn || !strstr(svcn, "Floor")) {
        [self hideViewTree:slotView];
      }
    } else {
      [self hideViewTree:view];
    }

    if (searchView) {
      CGRect targetRect = [view convertRect:view.bounds toView:searchView];
      [self hideIndicatorViewsNearRect:targetRect
                                inView:searchView
                          excludingView:view];
    }
  }
}


// Model removal for command 1004. Prefer Tile::doCommand: (Dock case 0x3ec) so
// the Dock runs its own guards. Fall back to [dock accessingLockedEventQueue:]
// + addTileRemovedForTile:animate: only when doCommand is unavailable.
//
// Note: right after DockBar insertTile:, internal Swift tile arrays can still
// be mid-update; addTileRemoved then hits a bounds trap (Dock FUN_1002c80f0 /
// brk #1). Callers that run immediately post-insert must delay (see Hider.m).
+ (void)queueDockTileModelRemoval:(id)tile {
  if (!tile) return;

  SEL doCommandSel = NSSelectorFromString(@"doCommand:");
  SEL performCommandSel = NSSelectorFromString(@"performCommand:");
  if (HiderInvokeSelectorInt(tile, doCommandSel, 1004)) return;
  if (HiderInvokeSelectorInt(tile, performCommandSel, 1004)) return;
  NSNumber *boxed = @(1004);
  if (HiderInvokeSelectorObject(tile, doCommandSel, boxed)) return;
  if (HiderInvokeSelectorObject(tile, performCommandSel, boxed)) return;

  SEL dockSel = NSSelectorFromString(@"dock");
  SEL lockSel = NSSelectorFromString(@"accessingLockedEventQueue:");
  SEL removeSel = NSSelectorFromString(@"addTileRemovedForTile:animate:");

  id dockTarget = nil;
  if ([tile respondsToSelector:dockSel]) {
    @try {
      dockTarget = ((id (*)(id, SEL))objc_msgSend)(tile, dockSel);
    } @catch (__unused NSException *e) {
      dockTarget = nil;
    }
  }

  if (!dockTarget || ![dockTarget respondsToSelector:removeSel]) return;

  __weak id weakTile = tile;
  void (^removeWork)(void) = ^{
    id strongTile = weakTile;
    if (!strongTile) return;
    @try {
      ((void (*)(id, SEL, id, BOOL))objc_msgSend)(dockTarget, removeSel,
                                                  strongTile, NO);
    } @catch (__unused NSException *e) {
    }
  };

  if ([dockTarget respondsToSelector:lockSel]) {
    @try {
      ((void (*)(id, SEL, void (^)(void)))objc_msgSend)(dockTarget, lockSel,
                                                        removeWork);
      return;
    } @catch (__unused NSException *e) {
    }
  }
  removeWork();
}

+ (void)removeDockTile:(id)tile {
  if (!tile) return;

  if (![self shouldSendRemoveCommandForTile:tile]) return;

  // Visually suppress immediately so there is no visible flash.
  [self suppressDockTile:tile];

  [self queueDockTileModelRemoval:tile];
}

+ (void)refreshDock {
  HiderBridgeRefreshDock();
}

@end
