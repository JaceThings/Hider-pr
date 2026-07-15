# Architecture

The parts that make up Hider and how they talk to each other.

| Component | Role |
|-----------|------|
| `src/Hider.m` | ObjC dylib, built to `build/libHider.dylib`. Ammonia injects it into `com.apple.dock`. It swizzles private DockCore classes; all Dock manipulation happens here. |
| [Ammonia](https://github.com/CoreBedtime/ammonia) | The injector. Loads every dylib in `/var/ammonia/core/tweaks/`. Requires SIP off and the `-arm64e_preview_abi` boot-arg. |
| `Hider.app` | SwiftUI settings app. Writes preferences and restarts the Dock. It never edits the Dock directly. |
| `hiderctl` | CLI over the same preferences. |
| `HiderCore` | Swift library shared by the app and CLI: the config model and the preferences store. |

The app and CLI write the preferences domain, then post a Darwin notification. The dylib reads the preferences and reacts.

```
domain: com.aspauldingcode.hider
keys:   hideFinder, hideTrash, hideSeparators, hideRunningApps, hiddenApps
notify: com.aspauldingcode.hider.settingsChanged
```

The relevant DockCore symbols are private and reverse-engineered:

```objc
DockBar                                     // owns `tiles`, a bridged Swift [Tile]
DOCKProcessTile                             // a running app's tile
DOCKTileLayer                               // a tile's on-screen CALayer
-[DockBar insertTile:atIndex:forReason:]    // the one insertion point
-[DockBar addProcessForASN:...]             // builds a running app's tile
```

See [hiding.md](hiding.md) for how the dylib uses these to hide a running app.
