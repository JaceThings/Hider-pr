#ifndef HIDER_H
#define HIDER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Internal tweak contract for `Hider.m`.
/// `HiderActions.h` owns the only Dock action API: `removeDockTile` and
/// `refreshDock`.
///
/// `Hider.m` owns:
/// - reading Finder / Trash config from preferences
/// - normalizing and caching hidden custom apps for runtime enforcement
/// - tracking live Dock objects and layers privately
/// - implementing the tweak's swizzle and refresh behavior internally
///
/// Mutable runtime state is intentionally kept private to `Hider.m`.

NS_ASSUME_NONNULL_END

#endif
