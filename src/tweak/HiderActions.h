#ifndef HIDER_ACTIONS_H
#define HIDER_ACTIONS_H

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Action helpers used by `Hider.m` to perform Dock-facing operations.
@interface HiderDockActions : NSObject

/// Visually suppresses a dock tile (opacity 0, hidden, indicator off) without
/// sending the Dock model removal command (1004). The tile remains in the
/// Dock's internal model so the Dock doesn't crash when the app launches.
+ (void)suppressDockTile:(id _Nullable)tile;

/// Removes a dock tile (app icon or divider). Hides it first (opacity 0,
/// instant) then sends command 1004 to fully remove from the Dock model.
/// Only safe for tiles whose apps won't re-trigger model lookups (Finder,
/// Trash, separators). For custom hidden apps, use suppressDockTile: instead.
+ (void)removeDockTile:(id _Nullable)tile;

/// Same model removal as `removeDockTile:` (1004 / addTileRemoved path) but
/// without visual suppression or throttle. Used when the caller already
/// suppressed the tile or must run after `insertTile:` returns.
+ (void)queueDockTileModelRemoval:(id _Nullable)tile;

+ (void)hideLayerTree:(id _Nullable)layer;
+ (void)hideIndicatorLayersNearRect:(CGRect)targetRect
                            inLayer:(id _Nullable)container
                       excludingTree:(id _Nullable)excluded;

/// Visually updates the Dock rendering to reflect changes. Does not kill or
/// restart the Dock process.
+ (void)refreshDock;

@end

NS_ASSUME_NONNULL_END

#endif
