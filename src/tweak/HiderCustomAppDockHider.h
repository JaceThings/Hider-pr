/*
 * HiderCustomAppDockHider.h
 *
 * Dedicated custom-app Dock hiding subsystem.
 *
 * This module owns the code-injection and method-swizzling path used to keep
 * configured apps out of the Dock without destabilizing the Dock process.
 *
 * Implementation requirements:
 * - Never mutate Dock model state synchronously from insert/update hooks.
 * - Always defer hidden-app suppression onto the main queue after Dock finishes
 *   its current transaction.
 * - Install hooks on the concrete class whenever possible to avoid mutating
 *   shared inherited method objects.
 * - Prefer C-function replacements installed via method_setImplementation over
 *   block trampolines for DockCore / DockBar hooks so PAC-sensitive call paths
 *   keep using direct typed function pointers to the original IMP.
 * - Capture Dock objects weakly across async boundaries to avoid retaining
 *   half-initialized tiles longer than necessary.
 * - Treat render suppression as the safe default for running apps. The module
 *   should not force model removal from the DockBar insertion hook.
 *
 * Hider.m provides the bridge functions declared below. This keeps Dock-specific
 * runtime state private while letting this file own the custom-app swizzles.
 */

#ifndef HIDER_CUSTOM_APP_DOCK_HIDER_H
#define HIDER_CUSTOM_APP_DOCK_HIDER_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

void HiderInstallCustomAppDockHiderHooks(void);
BOOL HiderCustomAppDockHiderClassLooksLikeTileClass(Class cls,
                                                    const char *name);
void HiderCustomAppDockHiderSwizzleTileClass(Class cls);
void HiderCustomAppDockHiderHandleFileTileLifecycle(id tile,
                                                    NSString *bundleID);
void HiderCustomAppDockHiderHandleVisibilityRefresh(id tile);

// Bridge supplied by Hider.m.
BOOL HiderCustomAppDockHiderIsBundleHidden(NSString *bundleID);
NSString * _Nullable HiderCustomAppDockHiderResolveTileBundleID(id tile);
NSString * _Nullable HiderCustomAppDockHiderPreRegisteredBundleID(id tile);
void HiderCustomAppDockHiderRegisterTile(id tile, NSString *bundleID);
void HiderCustomAppDockHiderSuppressTileRender(id tile);
void HiderCustomAppDockHiderDeferHiddenTileSuppression(id tile,
                                                       NSString *bundleID,
                                                       int64_t delayMs);
void Hider_LogToFile(const char *func, int line, NSString *format, ...);

NS_ASSUME_NONNULL_END

#endif
