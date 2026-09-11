/*
 * CoreDock Private API Header
 * Based on research from macEnhance cDock implementation
 * For HiddenGem Dock modifications
 * 
 * Sources:
 * - https://www.macenhance.com/blog/2021/coredock.html
 * - https://gist.github.com/w0lfschild/90db263867f469738c01e9e2d937f874
 * - https://gist.github.com/ThatsJustCheesy/823c806d78e6b3628cd6fdc86eb290d4
 */

#ifndef COREDOCK_H
#define COREDOCK_H

#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

#ifdef __cplusplus
extern "C" {
#endif

// CoreDock Enumerations
typedef enum {
    kCoreDockOrientationIgnore = 0,
    kCoreDockOrientationTop = 1,
    kCoreDockOrientationBottom = 2,
    kCoreDockOrientationLeft = 3,
    kCoreDockOrientationRight = 4
} CoreDockOrientation;

typedef enum {
    kCoreDockPinningIgnore = 0,
    kCoreDockPinningStart = 1,
    kCoreDockPinningMiddle = 2,
    kCoreDockPinningEnd = 3
} CoreDockPinning;

typedef enum {
    kCoreDockEffectGenie = 1,
    kCoreDockEffectScale = 2,
    kCoreDockEffectSuck = 3
} CoreDockEffect;

// Core Dock Functions - Tile Size and Layout
extern float CoreDockGetTileSize(void);
extern void CoreDockSetTileSize(float tileSize);

// Dock Orientation and Pinning
extern void CoreDockGetOrientationAndPinning(CoreDockOrientation *outOrientation, CoreDockPinning *outPinning);
extern void CoreDockSetOrientationAndPinning(CoreDockOrientation orientation, CoreDockPinning pinning);

// Dock Effects
extern void CoreDockGetEffect(CoreDockEffect *outEffect);
extern void CoreDockSetEffect(CoreDockEffect effect);

// Auto Hide
extern Boolean CoreDockGetAutoHideEnabled(void);
extern void CoreDockSetAutoHideEnabled(Boolean flag);

// Magnification
extern Boolean CoreDockIsMagnificationEnabled(void);
extern void CoreDockSetMagnificationEnabled(Boolean flag);
extern float CoreDockGetMagnificationSize(void);
extern void CoreDockSetMagnificationSize(float newSize);

// Launch Animations
extern Boolean CoreDockIsLaunchAnimationsEnabled(void);
extern void CoreDockSetLaunchAnimationsEnabled(Boolean flag);

// Workspaces/Spaces
extern Boolean CoreDockGetWorkspacesEnabled(void);
extern void CoreDockSetWorkspacesEnabled(Boolean flag);
extern int CoreDockGetWorkspacesCount(void);
extern void CoreDockSetWorkspacesCount(int count);

// Minimize in Place
extern void CoreDockSetMinimizeInPlace(Boolean enable);

// Preferences Dictionary
extern CFDictionaryRef CoreDockCopyPreferences(void);
extern void CoreDockSetPreferences(CFDictionaryRef preferenceDict);

// Trash State
extern void CoreDockSetTrashFull(Boolean full);

// Dock Status and Geometry
extern Boolean CoreDockIsDockRunning(void);
extern CGRect CoreDockGetRect(void);
extern CGRect CoreDockGetContainerRect(void);

// Custom HiddenGem Functions for Tile Management
typedef void (*CoreDockSendNotificationFunc)(CFStringRef notification, void* unknown);
typedef CFArrayRef (*CoreDockCopyApplicationsFunc)(void);
typedef void (*CoreDockSetTileHiddenFunc)(CFStringRef bundleID, Boolean hidden);
typedef Boolean (*CoreDockIsTileHiddenFunc)(CFStringRef bundleID);
typedef void (*CoreDockRefreshTileFunc)(CFStringRef bundleID);

// Function pointers for dynamic loading
extern CoreDockSendNotificationFunc CoreDockSendNotification;
extern CoreDockCopyApplicationsFunc CoreDockCopyApplications;
extern CoreDockSetTileHiddenFunc CoreDockSetTileHidden;
extern CoreDockIsTileHiddenFunc CoreDockIsTileHidden;
extern CoreDockRefreshTileFunc CoreDockRefreshTile;

// Dock Tile Information
typedef struct {
    CFStringRef bundleID;
    CFStringRef displayName;
    CFStringRef path;
    Boolean isRunning;
    Boolean isHidden;
    int position;
} CoreDockTileInfo;

extern CFArrayRef CoreDockCopyTileInfo(void);
extern CoreDockTileInfo* CoreDockGetTileInfoForBundle(CFStringRef bundleID);

// Dock Notifications
#define kCoreDockNotificationTileAdded      CFSTR("com.apple.dock.tile.added")
#define kCoreDockNotificationTileRemoved    CFSTR("com.apple.dock.tile.removed")
#define kCoreDockNotificationTileChanged    CFSTR("com.apple.dock.tile.changed")
#define kCoreDockNotificationDockChanged    CFSTR("com.apple.dock.changed")

// Special Bundle IDs
#define kCoreDockFinderBundleID    CFSTR("com.apple.finder")
#define kCoreDockTrashBundleID     CFSTR("com.apple.trash")

// Dock Preferences Keys
#define kCoreDockPrefShowHidden         CFSTR("showhidden")
#define kCoreDockPrefMagnification      CFSTR("magnification")
#define kCoreDockPrefTileSize           CFSTR("tilesize")
#define kCoreDockPrefOrientation        CFSTR("orientation")
#define kCoreDockPrefAutohide           CFSTR("autohide")
#define kCoreDockPrefMinimizeInPlace    CFSTR("minimize-to-application")
#define kCoreDockPrefLaunchAnim         CFSTR("launchanim")
#define kCoreDockPrefShowIndicators     CFSTR("show-process-indicators")

// HiddenGem Initialization and Helper Functions
BOOL HiddenGem_LoadCoreDockFunctions(void);
void HiddenGem_HideFinderIcon(Boolean hide);
void HiddenGem_HideTrashIcon(Boolean hide);
Boolean HiddenGem_IsFinderIconHidden(void);
Boolean HiddenGem_IsTrashIconHidden(void);
void HiddenGem_RefreshDock(void);
void HiddenGem_ToggleFinderIcon(void);
void HiddenGem_ToggleTrashIcon(void);
void HiddenGem_InitializeDockHooks(void);

#ifdef __cplusplus
}
#endif

#endif /* COREDOCK_H */
