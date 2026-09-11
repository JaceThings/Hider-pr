/*
 * caribbean.m - HiddenGem Dock Method Swizzling
 * 
 * Method swizzling hooks for DockCore classes to hide/remove
 * Finder and Trash DockItems using runtime modifications.
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdarg.h>

// Suppress warnings from ZKSwizzle framework that we can't modify
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdollar-in-identifier-extension"
#pragma clang diagnostic ignored "-Wgnu-zero-variadic-macro-arguments"
#import "ZKSwizzle.h"
#pragma clang diagnostic pop

#import "coredock.h"

// Logging macro - writes to /tmp/hiddengem.log (only to file, not stdout to avoid Makefile interference)
// Use helper function to avoid variadic macro issues - C99 compliant version
static void _HiddenGem_LogToFile(const char *func, int line, NSString *format, ...) {
    FILE *logFile = fopen("/tmp/hiddengem.log", "a");
    if (logFile) {
        va_list args;
        va_start(args, format);
        NSString *logMsg = [[NSString alloc] initWithFormat:format arguments:args];
        NSString *fullMsg = [NSString stringWithFormat:@"[%s:%d] %@", func, line, logMsg];
        fprintf(logFile, "%s\n", [fullMsg UTF8String]);
        fflush(logFile);
        fclose(logFile);
        va_end(args);
    }
}
// C99 compliant variadic macro - use separate macros for with/without args
#define LOG_TO_FILE_NO_ARGS(fmt) do { \
    NSString *_fmt = [NSString stringWithUTF8String:fmt]; \
    _HiddenGem_LogToFile(__FUNCTION__, __LINE__, _fmt); \
} while (0)
#define LOG_TO_FILE_WITH_ARGS(fmt, ...) do { \
    NSString *_fmt = [NSString stringWithUTF8String:fmt]; \
    _HiddenGem_LogToFile(__FUNCTION__, __LINE__, _fmt, __VA_ARGS__); \
} while (0)
// Helper to determine which macro to use - always pass at least one dummy arg
#define LOG_TO_FILE(fmt, ...) LOG_TO_FILE_WITH_ARGS(fmt, __VA_ARGS__)

// Global state
static BOOL g_finderHidden = YES;
static BOOL g_trashHidden = YES;

// Forward declarations
extern void HiddenGem_HideFinderIcon(Boolean hide);
extern void HiddenGem_HideTrashIcon(Boolean hide);
extern Boolean HiddenGem_IsFinderIconHidden(void);
extern Boolean HiddenGem_IsTrashIconHidden(void);

// Static function prototypes
static BOOL isFinderBundleID(NSString *bundleID);
static BOOL isTrashBundleID(NSString *bundleID);
static BOOL shouldHideTile(NSString *bundleID);
static NSString* getBundleIDFromObject(id obj);
static void swizzleDOCKTileLayer(void);
static void swizzleDockCoreClasses(void);

#pragma mark - Helper Functions

static BOOL isFinderBundleID(NSString *bundleID) {
    return bundleID && [bundleID isEqualToString:@"com.apple.finder"];
}

static BOOL isTrashBundleID(NSString *bundleID) {
    return bundleID && [bundleID isEqualToString:@"com.apple.trash"];
}

static BOOL shouldHideTile(NSString *bundleID) {
    if (!bundleID) return NO;
    
    if (isFinderBundleID(bundleID)) {
        return (BOOL)HiddenGem_IsFinderIconHidden();
    }
    
    if (isTrashBundleID(bundleID)) {
        return (BOOL)HiddenGem_IsTrashIconHidden();
    }
    
    return NO;
}

#pragma mark - Helper: Get Bundle ID from Layer/View

static NSString* getBundleIDFromObject(id obj) {
    if (!obj) return nil;
    
    NSString *bundleID = nil;
    
    // Try delegate's bundleIdentifier
    id delegate = nil;
    if ([obj respondsToSelector:@selector(delegate)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wstrict-selector-match"
        delegate = [(id)obj delegate];
        #pragma clang diagnostic pop
    }
    if (delegate) {
        SEL bundleIDSel = NSSelectorFromString(@"bundleIdentifier");
        if ([delegate respondsToSelector:bundleIDSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            bundleID = [delegate performSelector:bundleIDSel];
            #pragma clang diagnostic pop
            if (bundleID) {
                LOG_TO_FILE_WITH_ARGS("Found bundleID from delegate: %@", bundleID);
                return bundleID;
            }
        }
    }
    
    // Try representedObject
    id representedObject = nil;
    if ([obj respondsToSelector:@selector(valueForKey:)]) {
        representedObject = [obj valueForKey:@"representedObject"];
    }
    if (representedObject) {
        SEL bundleIDSel = NSSelectorFromString(@"bundleIdentifier");
        if ([representedObject respondsToSelector:bundleIDSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            bundleID = [representedObject performSelector:bundleIDSel];
            #pragma clang diagnostic pop
            if (bundleID) {
                LOG_TO_FILE_WITH_ARGS("Found bundleID from representedObject: %@", bundleID);
                return bundleID;
            }
        }
    }
    
    // Try description string matching
    NSString *desc = [obj description];
    if ([desc containsString:@"com.apple.finder"]) {
        bundleID = @"com.apple.finder";
        LOG_TO_FILE_NO_ARGS("Found Finder from description");
    } else if ([desc containsString:@"com.apple.trash"] || [desc containsString:@"Trash"]) {
        bundleID = @"com.apple.trash";
        LOG_TO_FILE_NO_ARGS("Found Trash from description");
    }
    
    return bundleID;
}

#pragma mark - DockCore Tile Swizzling

// Swizzle DOCKTileLayer specifically - this is the actual class used for dock tiles
// We need to dynamically swizzle this class since it's not available at compile time

static void swizzleDOCKTileLayer(void) {
    Class dockTileLayerClass = NSClassFromString(@"DOCKTileLayer");
    if (!dockTileLayerClass) {
        LOG_TO_FILE_NO_ARGS("DOCKTileLayer class not found");
        return;
    }
    
    LOG_TO_FILE_WITH_ARGS("Found DOCKTileLayer class: %s", class_getName(dockTileLayerClass));
    
    // Swizzle setHidden: method using method_exchangeImplementations
    Method originalSetHidden = class_getInstanceMethod(dockTileLayerClass, @selector(setHidden:));
    if (originalSetHidden) {
        LOG_TO_FILE_NO_ARGS("Found setHidden: method on DOCKTileLayer");
        
        // Create a swizzled method implementation
        void (^swizzleBlockHidden)(id, BOOL) = ^(id self, BOOL hidden) {
            NSString *bundleID = getBundleIDFromObject(self);
            if (bundleID && shouldHideTile(bundleID)) {
                LOG_TO_FILE_WITH_ARGS("DOCKTileLayer setHidden: Forcing hide for %@ (was %d)", bundleID, hidden);
                // Call original with YES to force hide
                // We'll use the original implementation stored in the method
                IMP originalIMP = method_getImplementation(originalSetHidden);
                ((void (*)(id, SEL, BOOL))originalIMP)(self, @selector(setHidden:), YES);
            } else {
                // Call original normally
                IMP originalIMP = method_getImplementation(originalSetHidden);
                ((void (*)(id, SEL, BOOL))originalIMP)(self, @selector(setHidden:), hidden);
            }
        };
        
        // Add our swizzled method
        IMP swizzleIMP = imp_implementationWithBlock(swizzleBlockHidden);
        SEL swizzleSel = NSSelectorFromString(@"hiddengem_setHidden:");
        if (!class_addMethod(dockTileLayerClass, swizzleSel, swizzleIMP, method_getTypeEncoding(originalSetHidden))) {
            LOG_TO_FILE_NO_ARGS("Failed to add swizzled setHidden: method");
            return;
        }
        
        // Exchange implementations
        Method swizzleMethod = class_getInstanceMethod(dockTileLayerClass, swizzleSel);
        method_exchangeImplementations(originalSetHidden, swizzleMethod);
        LOG_TO_FILE_NO_ARGS("Swizzled setHidden: on DOCKTileLayer");
    }
    
    // Swizzle setOpacity: method
    Method originalSetOpacity = class_getInstanceMethod(dockTileLayerClass, @selector(setOpacity:));
    if (originalSetOpacity) {
        LOG_TO_FILE_NO_ARGS("Found setOpacity: method on DOCKTileLayer");
        
        void (^swizzleBlockOpacity)(id, float) = ^(id self, float opacity) {
            NSString *bundleID = getBundleIDFromObject(self);
            if (bundleID && shouldHideTile(bundleID)) {
                LOG_TO_FILE_WITH_ARGS("DOCKTileLayer setOpacity: Forcing opacity 0 for %@ (was %f)", bundleID, opacity);
                // Call original with 0.0 to make invisible
                IMP originalIMP = method_getImplementation(originalSetOpacity);
                ((void (*)(id, SEL, float))originalIMP)(self, @selector(setOpacity:), 0.0f);
            } else {
                // Call original normally
                IMP originalIMP = method_getImplementation(originalSetOpacity);
                ((void (*)(id, SEL, float))originalIMP)(self, @selector(setOpacity:), opacity);
            }
        };
        
        IMP swizzleIMP = imp_implementationWithBlock(swizzleBlockOpacity);
        SEL swizzleSel = NSSelectorFromString(@"hiddengem_setOpacity:");
        if (!class_addMethod(dockTileLayerClass, swizzleSel, swizzleIMP, method_getTypeEncoding(originalSetOpacity))) {
            LOG_TO_FILE_NO_ARGS("Failed to add swizzled setOpacity: method");
            return;
        }
        
        Method swizzleMethod = class_getInstanceMethod(dockTileLayerClass, swizzleSel);
        method_exchangeImplementations(originalSetOpacity, swizzleMethod);
        LOG_TO_FILE_NO_ARGS("Swizzled setOpacity: on DOCKTileLayer");
    }
}

// Fallback: Swizzle CALayer for any tiles we might miss
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wlanguage-extension-token"
#pragma clang diagnostic ignored "-Wcast-function-type-mismatch"
ZKSwizzleInterface(HiddenGem_CALayer, CALayer, CALayer)
@implementation HiddenGem_CALayer

- (void)setHidden:(BOOL)hidden {
    NSString *className = NSStringFromClass([self class]);
    if ([className isEqualToString:@"DOCKTileLayer"]) {
        NSString *bundleID = getBundleIDFromObject(self);
        if (bundleID && shouldHideTile(bundleID)) {
            LOG_TO_FILE_WITH_ARGS("CALayer swizzle: Forcing hide for %@", bundleID);
            ZKOrig(void, YES);
            return;
        }
    }
    ZKOrig(void, hidden);
}

- (void)setOpacity:(float)opacity {
    NSString *className = NSStringFromClass([self class]);
    if ([className isEqualToString:@"DOCKTileLayer"]) {
        NSString *bundleID = getBundleIDFromObject(self);
        if (bundleID && shouldHideTile(bundleID)) {
            LOG_TO_FILE_WITH_ARGS("CALayer swizzle: Forcing opacity 0 for %@", bundleID);
            ZKOrig(void, 0.0f);
            return;
        }
    }
    ZKOrig(void, opacity);
}

@end
#pragma clang diagnostic pop

#pragma mark - NSView-based Dock Item Swizzling

// Swizzle NSView classes that might represent dock items
// Dock items are often represented as NSViews or subclasses

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wlanguage-extension-token"
#pragma clang diagnostic ignored "-Wcast-function-type-mismatch"
ZKSwizzleInterface(HiddenGem_DockItemView, NSView, NSView)
@implementation HiddenGem_DockItemView

- (void)setHidden:(BOOL)hidden {
    // Check if this view represents Finder or Trash
    NSString *bundleID = nil;
    
    // Try various ways to get bundle identifier
    id representedObject = [self valueForKey:@"representedObject"];
    if (representedObject) {
        SEL bundleIDSel = NSSelectorFromString(@"bundleIdentifier");
        if ([representedObject respondsToSelector:bundleIDSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            bundleID = [representedObject performSelector:bundleIDSel];
            #pragma clang diagnostic pop
        }
    }
    
    // Check view's tooltip or accessibility label
    if (!bundleID && [self respondsToSelector:@selector(toolTip)]) {
        NSString *tooltip = [self toolTip];
        if ([tooltip containsString:@"Finder"]) {
            bundleID = @"com.apple.finder";
        } else if ([tooltip containsString:@"Trash"]) {
            bundleID = @"com.apple.trash";
        }
    }
    
    // Force hide if this is Finder or Trash and we want it hidden
    if (bundleID && shouldHideTile(bundleID)) {
        ZKOrig(void, YES); // Force hidden
        return;
    }
    
    ZKOrig(void, hidden);
}

- (void)setAlphaValue:(CGFloat)alphaValue {
    NSString *bundleID = nil;
    
    id representedObject = [self valueForKey:@"representedObject"];
    if (representedObject) {
        SEL bundleIDSel = NSSelectorFromString(@"bundleIdentifier");
        if ([representedObject respondsToSelector:bundleIDSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            bundleID = [representedObject performSelector:bundleIDSel];
            #pragma clang diagnostic pop
        }
    }
    
    // Make Finder/Trash views invisible if hidden
    if (bundleID && shouldHideTile(bundleID)) {
        ZKOrig(void, 0.0); // Fully transparent
        return;
    }
    
    ZKOrig(void, alphaValue);
}

@end
#pragma clang diagnostic pop

#pragma mark - DockCore Framework Class Swizzling

// Try to swizzle DockCore framework classes if they exist
// These are runtime-discovered classes that may not be available at compile time

static void swizzleDockCoreClasses(void) {
    LOG_TO_FILE_NO_ARGS("Searching for DockCore classes...");
    
    // Try to find and swizzle DockCore classes dynamically
    Class dockTileClass = NSClassFromString(@"DockTile");
    Class dockItemClass = NSClassFromString(@"DockItem");
    Class dockTileViewClass = NSClassFromString(@"DockTileView");
    Class dockTileLayerClass = NSClassFromString(@"DOCKTileLayer");
    
    if (dockTileClass) {
        LOG_TO_FILE_WITH_ARGS("Found DockTile class: %s", class_getName(dockTileClass));
    }
    
    if (dockItemClass) {
        LOG_TO_FILE_WITH_ARGS("Found DockItem class: %s", class_getName(dockItemClass));
    }
    
    if (dockTileViewClass) {
        LOG_TO_FILE_WITH_ARGS("Found DockTileView class: %s", class_getName(dockTileViewClass));
    }
    
    if (dockTileLayerClass) {
        LOG_TO_FILE_WITH_ARGS("Found DOCKTileLayer class: %s", class_getName(dockTileLayerClass));
        swizzleDOCKTileLayer();
    } else {
        LOG_TO_FILE_NO_ARGS("DOCKTileLayer not found, will use CALayer swizzle");
    }
    
    // Try to enumerate all classes to find DockCore-related ones
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    LOG_TO_FILE_WITH_ARGS("Enumerating %d classes...", classCount);
    
    for (unsigned int i = 0; i < classCount; i++) {
        const char *className = class_getName(classes[i]);
        if (strstr(className, "Dock") || strstr(className, "DOCK")) {
            LOG_TO_FILE_WITH_ARGS("Found Dock-related class: %s", className);
        }
    }
    
    free(classes);
}

#pragma mark - Initialization

__attribute__((constructor))
static void HiddenGem_CaribbeanInit(void) {
    @autoreleasepool {
        // Only run in Dock process
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.apple.dock"]) {
            LOG_TO_FILE("Not Dock process (bundleID: %@), skipping", bundleID);
            return;
        }
        
        LOG_TO_FILE_NO_ARGS("=== HiddenGem Caribbean Initialization ===");
        LOG_TO_FILE_NO_ARGS("Dock process detected, initializing swizzling");
        
        // Update global state from CoreDock functions
        g_finderHidden = (BOOL)HiddenGem_IsFinderIconHidden();
        g_trashHidden = (BOOL)HiddenGem_IsTrashIconHidden();
        
        LOG_TO_FILE_WITH_ARGS("Finder hidden: %d, Trash hidden: %d", g_finderHidden, g_trashHidden);
        
        // Try to swizzle DockCore classes if they exist
        swizzleDockCoreClasses();
        
        LOG_TO_FILE_NO_ARGS("Caribbean initialization complete");
    }
}
