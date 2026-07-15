import AppKit
import SwiftUI
import Combine
import HiderCore

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let store: HiderConfigStore

    // True while we are pulling fresh values in from the store (an external
    // change). The property didSets check this so a reload updates the UI
    // WITHOUT writing back or marking changes — otherwise the app would clobber
    // changes made via the CLI / another instance.
    private var isReloading = false

    // Set whenever a change needs a Dock rebuild to take effect (running-app
    // hiding is applied by rebuilding the Dock, and restoring a hidden built-in
    // also needs a restart). While true the UI shows an "Applying…" status; it is
    // set the moment a change is staged and cleared once the relaunch fires.
    @Published var needsApply = false

    @Published var hideFinder: Bool {
        didSet {
            guard !isReloading, oldValue != hideFinder else { return }
            do {
                try store.setFinderHidden(hideFinder)
            } catch {
                NSLog("Hider: failed to save Finder setting: %@", error.localizedDescription)
            }
            // Apply on ANY change via a Dock rebuild. Hiding Finder live leaves
            // its running-dot orphaned (the Dock never relayouts on its own to
            // clean it up), and un-hiding needs a rebuild to recreate the tile —
            // so both directions auto-apply, same as app hiding.
            stageChange()
        }
    }

    @Published var hideTrash: Bool {
        didSet {
            guard !isReloading, oldValue != hideTrash else { return }
            do {
                try store.setTrashHidden(hideTrash)
            } catch {
                NSLog("Hider: failed to save Trash setting: %@", error.localizedDescription)
            }
            stageChange()
        }
    }

    @Published var hideSeparators: Bool {
        didSet {
            guard !isReloading, oldValue != hideSeparators else { return }
            do {
                try store.setSeparatorsHidden(hideSeparators)
            } catch {
                NSLog("Hider: failed to save separator setting: %@", error.localizedDescription)
            }
            stageChange()
        }
    }

    @Published var hideRunningApps: Bool {
        didSet {
            guard !isReloading, oldValue != hideRunningApps else { return }
            do {
                try store.setRunningAppsHidden(hideRunningApps)
            } catch {
                NSLog("Hider: failed to save running apps setting: %@", error.localizedDescription)
            }
            stageChange()
        }
    }

    @Published var hiddenApps: [String] {
        didSet {
            guard !isReloading, oldValue != hiddenApps else { return }
            do {
                try store.setHiddenApps(hiddenApps)
            } catch {
                NSLog("Hider: failed to save hidden apps: %@", error.localizedDescription)
            }
            stageChange()
        }
    }

    @Published var showAppPicker: Bool = false

    init(store: HiderConfigStore = .shared) {
        self.store = store
        let config = store.currentConfig()
        hideFinder = config.hideFinder
        hideTrash = config.hideTrash
        hideSeparators = config.hideSeparators
        hideRunningApps = config.hideRunningApps
        hiddenApps = config.hiddenApps
        observeExternalChanges()
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Add an app to the hidden list. Because putting an app in the list means
    /// "hide it," this also switches the running-hide feature on if it was off,
    /// so a following Apply actually removes the tile.
    func addHiddenApp(_ bundleID: String) {
        guard !hiddenApps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
        else { return }
        hiddenApps.append(bundleID)
        if !hideRunningApps { hideRunningApps = true }
    }

    func removeHiddenApp(_ bundleID: String) {
        hiddenApps.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    func synchronize() {
        store.postSettingsChanged()
    }

    /// Pull fresh values from the store without writing back or marking changes.
    /// Called when another process (the CLI, a second window) changes settings.
    func reloadFromStore() {
        let config = store.currentConfig()
        isReloading = true
        defer { isReloading = false }
        if hideFinder != config.hideFinder { hideFinder = config.hideFinder }
        if hideTrash != config.hideTrash { hideTrash = config.hideTrash }
        if hideSeparators != config.hideSeparators { hideSeparators = config.hideSeparators }
        if hideRunningApps != config.hideRunningApps { hideRunningApps = config.hideRunningApps }
        if hiddenApps != config.hiddenApps { hiddenApps = config.hiddenApps }
    }

    private func observeExternalChanges() {
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let manager = Unmanaged<SettingsManager>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { manager.reloadFromStore() }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            callback,
            HiderConfigStore.settingsChangedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// Stage a change and apply it automatically after a short debounce. Toggling
    /// several apps in a row coalesces into ONE Dock rebuild once you stop — no
    /// button to press, and no relaunch-per-toggle. The debounce plus the
    /// rate-limited relaunch below keep it smooth and safe.
    private let autoApplyDebounce: TimeInterval = 1.0
    private func stageChange() {
        needsApply = true
        relaunchRequested = true
        scheduleRelaunchAttempt(after: autoApplyDebounce)
    }

    /// Apply pending changes immediately (menu command / keyboard shortcut).
    func apply() {
        relaunchRequested = true
        scheduleRelaunchAttempt(after: 0.05)
    }

    // ── Safe Dock relaunch ─────────────────────────────────────────────────
    // Applying a change means killing the Dock so it rebuilds. Doing that
    // repeatedly in quick succession — mashing Apply, or applying again while the
    // Dock is mid-relaunch/dead — fired killall repeatedly, tripping launchd's
    // respawn throttle and wedging the Dock. Every relaunch funnels through here,
    // which coalesces bursts into one relaunch, keeps a 5s minimum gap, and never
    // kills a Dock that isn't fully back up. The injected dylib's crash-loop guard
    // (with an intentional-restart exemption) is the backstop beneath this.
    private var pendingRelaunch: DispatchWorkItem?
    private var relaunchRequested = false
    private var lastRelaunchAt = Date.distantPast
    private let minRelaunchGap: TimeInterval = 5

    /// Request a Dock relaunch directly (e.g. a "Restart Dock" action). Safe to
    /// call as often as you like.
    func restartDock() {
        relaunchRequested = true
        scheduleRelaunchAttempt(after: 0.6)
    }

    private func scheduleRelaunchAttempt(after delay: TimeInterval) {
        pendingRelaunch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.attemptRelaunch() }
        pendingRelaunch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func attemptRelaunch() {
        guard relaunchRequested else { return }
        let sinceLast = Date().timeIntervalSince(lastRelaunchAt)
        if sinceLast < minRelaunchGap {
            scheduleRelaunchAttempt(after: minRelaunchGap - sinceLast)
            return
        }
        guard isDockRunning() else {
            scheduleRelaunchAttempt(after: 2)
            return
        }
        relaunchRequested = false
        lastRelaunchAt = Date()
        needsApply = false
        store.postPrepareRestart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            task.arguments = ["Dock"]
            try? task.run()
        }
    }

    private func isDockRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.dock"
        }
    }

}
