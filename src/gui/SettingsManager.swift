import SwiftUI
import Combine
import Darwin

@_silgen_name("notify_post")
private func hider_notify_post(_ name: UnsafePointer<CChar>) -> UInt32

private func postNotification(_ name: String) {
    name.withCString { _ = hider_notify_post($0) }
}

private func removeHiddenAppsFromDockPrefs(_ bundleIDs: Set<String>) {
    guard let dockDefaults = UserDefaults(suiteName: "com.apple.dock"),
          let items = dockDefaults.array(forKey: "persistent-apps") as? [[String: Any]] else { return }
    let normalized = Set(bundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    let filtered = items.filter { item in
        guard let tileData = item["tile-data"] as? [String: Any],
              let bid = tileData["bundle-identifier"] as? String else { return true }
        let n = bid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.contains(n)
    }
    if filtered.count != items.count {
        dockDefaults.set(filtered, forKey: "persistent-apps")
        dockDefaults.synchronize()
        postNotification("com.apple.dock.prefchanged")
    }
}

private func restartDockProcess(after delay: TimeInterval = 0.15) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
    }
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = UserDefaults(suiteName: "com.aspauldingcode.hider")!

    private enum DockRestartReason: Hashable {
        case finderRestore
        case trashRestore
    }

    private var pendingDockRestartReasons = Set<DockRestartReason>() {
        didSet {
            showRestartDockButton = !pendingDockRestartReasons.isEmpty
        }
    }
    
    private static func normalizeBundleID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @Published var hideFinder: Bool {
        didSet {
            defaults.set(hideFinder, forKey: "hideFinder")
            updateRestartRequirement(.finderRestore,
                                     wasHidden: oldValue,
                                     isHidden: hideFinder)
            notifyTweak()
        }
    }

    @Published var hideTrash: Bool {
        didSet {
            defaults.set(hideTrash, forKey: "hideTrash")
            updateRestartRequirement(.trashRestore,
                                     wasHidden: oldValue,
                                     isHidden: hideTrash)
            notifyTweak()
        }
    }

    @Published var hiddenApps: [String] {
        didSet {
            defaults.set(hiddenApps, forKey: "hiddenApps")
            let previous = Set(oldValue.map(Self.normalizeBundleID))
            let current = Set(hiddenApps.map(Self.normalizeBundleID))
            let added = current.subtracting(previous)
            if !added.isEmpty {
                defaults.synchronize()
                removeHiddenAppsFromDockPrefs(added)
                postNotification("com.aspauldingcode.hider.hiddenAppAdded")
            } else {
                notifyTweak()
            }
            pendingDockRestartReasons.removeAll()
        }
    }

    @Published private(set) var showRestartDockButton: Bool = false
    @Published var showAppPicker: Bool = false

    init() {
        hideFinder = defaults.object(forKey: "hideFinder") as? Bool ?? false
        hideTrash  = defaults.object(forKey: "hideTrash")  as? Bool ?? false
        hiddenApps = defaults.object(forKey: "hiddenApps") as? [String] ?? []
        defaults.register(defaults: [
            "hideFinder": false,
            "hideTrash":  false,
            "hiddenApps": [String]()
        ])
    }

    func addHiddenApp(_ bundleID: String) {
        guard !hiddenApps.contains(bundleID) else { return }
        hiddenApps.append(bundleID)
    }

    func removeHiddenApp(_ bundleID: String) {
        hiddenApps.removeAll { $0 == bundleID }
    }

    func synchronize() {
        defaults.synchronize()
        notifyTweak()
    }

    func restartDock() {
        pendingDockRestartReasons.removeAll()
        restartDockProcess()
    }

    private func updateRestartRequirement(_ reason: DockRestartReason,
                                          wasHidden: Bool,
                                          isHidden: Bool) {
        if wasHidden && !isHidden {
            pendingDockRestartReasons.insert(reason)
        } else {
            pendingDockRestartReasons.remove(reason)
        }
    }

    private func notifyTweak() {
        defaults.synchronize()
        postNotification("com.aspauldingcode.hider.settingsChanged")
    }
}
