#import "Hooks.h"

void swizzleCALayer(void);
void swizzleNSView(void);
void swizzleDockCoreClasses(void);

static void HiderInstallTileModelHooks(void) {
  swizzleDockCoreClasses();
}

static void HiderInstallLayerHooks(void) {
  swizzleCALayer();
  swizzleNSView();
}

static void HiderInstallWorkspaceHooks(void) {
  // NSWorkspace launch/activate/deactivate observers are still registered
  // from tweak lifecycle initialization. This hook module is the dedicated
  // home for future extraction of those observer registrations.
}

void HiderInstallHooks(void) {
  HiderInstallTileModelHooks();
  HiderInstallLayerHooks();
  HiderInstallWorkspaceHooks();
}
