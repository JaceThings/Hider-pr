<p align="center"> <img src="media/Hider.png" width="100%"> </p>

# Hider

Hide items from the macOS Dock — Finder, Trash, the separator, and running apps — from a native settings app (`Hider.app`) or the `hiderctl` CLI. A hidden running app leaves no trace in the Dock: no icon, no gap, nothing to click, while it keeps running.

Running apps are the hard case — macOS has no API for changing the Dock — so the [`docs/`](docs/) folder covers how it works.

## Requirements

- Apple Silicon Mac, macOS 26 or 27.
- **SIP disabled.** macOS has no API for modifying the Dock; the only way in is injecting code into the Dock process, which SIP blocks. Real trade-off — use a machine you don't mind tinkering with. Reversible (see [Uninstall](#uninstall)).
- **[Ammonia](https://github.com/CoreBedtime/ammonia)** — the tweak loader that injects Hider into the Dock.

## Install

In order; steps 2–4 each reboot.

**1. Command Line Tools** (for `make`):
```sh
xcode-select --install
```

**2. Disable SIP** — only possible from Recovery. Shut down, hold the power button until "Loading startup options," then Options → Continue → Utilities → Terminal:
```sh
csrutil disable
```
Restart into macOS.

**3. Enable the arm64e preview ABI** (Ammonia ships `arm64e` code that needs it):
```sh
sudo nvram boot-args=-arm64e_preview_abi   # keep existing args if you have any
sudo reboot
```

**4. Install Ammonia:**
```sh
curl -L -o /tmp/ammonia.pkg \
  https://github.com/CoreBedtime/ammonia/releases/download/1.5/ammonia.pkg
sudo installer -pkg /tmp/ammonia.pkg -target /
```

**5. Install Hider:**
```sh
make install   # or `make all` to build without sudo
```
Builds the dylib into Ammonia's tweaks folder, installs `Hider.app` and `hiderctl`, and restarts the Dock. Open `Hider.app` and hide something to confirm.

## App

Two panes: **Dock Items** (Finder, Trash, separator, and the running-apps master switch) and **Applications** (hidden apps, currently-running apps, and search). Changes auto-apply — running-app hiding needs a Dock rebuild, so ~1s after you stop toggling the Dock refreshes once. Rapid toggling can't wedge it; bursts collapse into one rate-limited relaunch.

## CLI

Apps are named by bundle ID (`hiderctl list`, or `osascript -e 'id of app "Spotify"'`).
```sh
hiderctl status                        # settings + install status
hiderctl list                          # installed apps; * marks hidden
hiderctl hide <bundleID|finder|trash>  # hide
hiderctl show <bundleID|finder|trash>  # show
hiderctl apply|export [path]           # JSON config in / out
hiderctl watch                         # re-enforce as apps launch
```
With running-app hiding on, `hide`/`show` restart the Dock; set `HIDER_NO_RESTART=1` to batch changes and restart once.

## How it works

The injected dylib (`src/Hider.m`) hooks DockCore. For a hidden running app it refuses the tile at insertion (`-[DockBar insertTile:atIndex:forReason:]`), so it never enters the Dock model — no icon, no gap, nothing to hit-test. An index clamp avoids a DockCore Swift precondition crash, and a crash-loop guard restores the Dock if anything breaks. Details in [`docs/hiding.md`](docs/hiding.md).

## If the Dock misbehaves

Running-app hiding is off by default and fails safe. If the Dock won't appear:
```sh
mv /var/ammonia/core/tweaks/libHider.dylib /tmp/
launchctl kickstart gui/$(id -u)/com.apple.Dock.agent
```
Never `kickstart -k` — it can wedge the injector. A reboot clears leftover state.

## Uninstall

```sh
make uninstall
sudo nvram -d boot-args
```
Then re-enable SIP from Recovery: `csrutil enable`. Ammonia can stay or go.

## Credits

- Created by **Alex Spaulding** (@aspauldingcode).
- Running-app hiding, `Hider.app`, and `hiderctl` by **Jace** (@JaceThings).
- Dock tile rendering fix by **Salty** (@ogui-775).
- Built on [Ammonia](https://github.com/CoreBedtime/ammonia) by CoreBedtime.

## License

[MIT](LICENSE)
