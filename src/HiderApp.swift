import AppKit
import Combine
import HiderCore
import SwiftUI

// The macOS 27 SDK exposes a same-named State macro, but the Command Line
// Tools distribution does not ship its SwiftUIMacros implementation. This
// alias selects the long-standing property-wrapper type explicitly.
private typealias ViewState<Value> = SwiftUI.State<Value>

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchWatcher = LaunchWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        launchWatcher.start()
    }
}

struct AppInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: NSImage

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.id == rhs.id
    }
}

final class AppListLoader: ObservableObject {
    @Published private(set) var apps: [AppInfo] = []
    @Published private(set) var isLoading = false

    private var loaded = false

    func load() {
        guard !loaded, !isLoading else { return }
        isLoading = true
        loaded = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let result = AppCatalog.installedApplications()
                .filter {
                    $0.bundleID.caseInsensitiveCompare("com.apple.finder") != .orderedSame
                        && $0.bundleID.caseInsensitiveCompare("com.apple.trash") != .orderedSame
                }
                .map { application in
                    AppInfo(
                        id: application.bundleID,
                        name: application.displayName,
                        icon: NSWorkspace.shared.icon(forFile: application.bundleURL.path)
                    )
                }

            DispatchQueue.main.async {
                self.apps = result
                self.isLoading = false
            }
        }
    }

    /// Look up display info for a bundle ID, preferring the loaded catalog.
    func appInfo(for bundleID: String) -> AppInfo? {
        apps.first { $0.id.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

/// Tracks the apps that currently have a regular (Dock-visible) presence, kept
/// fresh as apps launch and quit. These are the apps a running-hide actually
/// affects, so the UI surfaces them first instead of the full installed dump.
final class RunningAppsMonitor: ObservableObject {
    @Published private(set) var apps: [AppInfo] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.refresh()
                })
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
    }

    func refresh() {
        var seen = Set<String>()
        var result: [AppInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard
                let bundleID = app.bundleIdentifier,
                bundleID.caseInsensitiveCompare("com.apple.finder") != .orderedSame,
                bundleID.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") != .orderedSame,
                !seen.contains(bundleID.lowercased())
            else { continue }
            seen.insert(bundleID.lowercased())
            let icon = app.icon
                ?? app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage()
            result.append(AppInfo(id: bundleID, name: app.localizedName ?? bundleID, icon: icon))
        }
        apps = result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case dockItems
    case applications
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .dockItems: "Dock Items"
        case .applications: "Applications"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .dockItems: "dock.rectangle"
        case .applications: "square.grid.2x2"
        case .about: "info.circle"
        }
    }
}

private struct SidebarLabel: View {
    let category: SettingsCategory

    var body: some View {
        Label(category.title, systemImage: category.symbolName)
            .symbolRenderingMode(.hierarchical)
    }
}

struct HiderSettingsView: View {
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var appLoader = AppListLoader()
    @ViewState private var selection: SettingsCategory? = .applications

    var body: some View {
        if #available(macOS 15.0, *) {
            splitView
                .containerBackground(.windowBackground, for: .window)
        } else {
            splitView
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SettingsCategory.allCases) { category in
                        NavigationLink(value: category) {
                            SidebarLabel(category: category)
                        }
                        .badge(category == .applications ? settings.hiddenApps.count : 0)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            switch selection ?? .applications {
            case .dockItems:
                DockItemsView(settings: settings)
            case .applications:
                ApplicationsView(settings: settings, appLoader: appLoader)
            case .about:
                AboutStatusView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct DetailHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title)
                .fontWeight(.bold)

            if let subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }
}

private struct DockItemsView: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader("Dock Items", subtitle: "Choose which built-in items appear in the Dock.")
            ApplyBar(settings: settings)

            Form {
                Section {
                    Toggle("Hide Finder", isOn: $settings.hideFinder)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("hide-finder-toggle")
                    Toggle("Hide Trash", isOn: $settings.hideTrash)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("hide-trash-toggle")
                    Toggle("Hide Separator", isOn: $settings.hideSeparators)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("hide-separator-toggle")
                }

                Section {
                    Toggle("Hide running apps", isOn: $settings.hideRunningApps)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("hide-running-apps-toggle")
                        .help(
                            "Remove a hidden app's Dock tile entirely while it is running."
                        )
                } footer: {
                    Text(
                        "Master switch for running-app hiding. When on, any app in the "
                            + "hidden list has its Dock tile completely removed while running — "
                            + "no icon, no gap, not clickable. Adding an app in Applications turns "
                            + "this on for you."
                    )
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// A prominent bar that appears when settings have changed but the Dock hasn't
/// been rebuilt yet. Running-app hiding only takes effect on a Dock rebuild, so
/// changes are staged and applied explicitly here — no surprise Dock flicker.
private struct ApplyBar: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        if settings.needsApply {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Applying changes to the Dock…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5))
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("applying-status")
        }
    }
}

private struct ApplicationsView: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject var appLoader: AppListLoader
    @StateObject private var running = RunningAppsMonitor()
    @ViewState private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(_ app: AppInfo) -> Bool {
        app.name.localizedCaseInsensitiveContains(query)
            || app.id.localizedCaseInsensitiveContains(query)
    }

    private func isHidden(_ id: String) -> Bool {
        settings.hiddenApps.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Resolve display info for a hidden bundle ID even if it is not running and
    /// not in the installed catalog (so a manually-added ID still renders).
    private func resolve(_ id: String) -> AppInfo {
        if let a = running.apps.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            return a
        }
        if let a = appLoader.appInfo(for: id) { return a }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        let name = url?.deletingPathExtension().lastPathComponent ?? id
        return AppInfo(id: id, name: name, icon: icon)
    }

    private var hiddenApps: [AppInfo] {
        settings.hiddenApps.map(resolve)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var runningNotHidden: [AppInfo] {
        running.apps.filter { !isHidden($0.id) }
    }

    /// Flat search results across running + installed, de-duplicated by ID.
    private var searchResults: [AppInfo] {
        var seen = Set<String>()
        var result: [AppInfo] = []
        for app in running.apps + appLoader.apps where matches(app) {
            let key = app.id.lowercased()
            if seen.insert(key).inserted { result.append(app) }
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(
                "Applications",
                subtitle: "Hide an app from the Dock — even while it is running."
            )
            ApplyBar(settings: settings)

            Form {
                if query.isEmpty {
                    defaultSections
                } else {
                    searchSection
                }
            }
            .formStyle(.grouped)
            .searchable(
                text: $searchText, placement: .toolbar,
                prompt: "Search all applications")
        }
        .onAppear {
            appLoader.load()
            running.refresh()
        }
    }

    @ViewBuilder private var defaultSections: some View {
        if !hiddenApps.isEmpty {
            Section {
                ForEach(hiddenApps) { app in
                    ApplicationToggleRow(app: app, settings: settings, isRunning: isRunning(app.id))
                }
            } header: {
                Text("Hidden — \(hiddenApps.count)")
            } footer: {
                Text("Turn off to show an app in the Dock again.")
            }
        }

        Section {
            if runningNotHidden.isEmpty {
                Text(hiddenApps.isEmpty ? "No apps are running." : "Every running app is hidden.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(runningNotHidden) { app in
                    ApplicationToggleRow(app: app, settings: settings, isRunning: true)
                }
            }
        } header: {
            Text("Running Apps")
        } footer: {
            Text(
                "These apps currently have a Dock tile. Turn one on to remove it. "
                    + "To hide an app that isn't running, search for it above."
            )
        }
    }

    @ViewBuilder private var searchSection: some View {
        if searchResults.isEmpty {
            Section {
                VStack(spacing: 8) {
                    Label("No Results", systemImage: "magnifyingglass")
                        .font(.headline)
                    Text("No application matches “\(query)”.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
        } else {
            Section {
                ForEach(searchResults) { app in
                    ApplicationToggleRow(app: app, settings: settings, isRunning: isRunning(app.id))
                }
            } header: {
                Text("\(searchResults.count) result\(searchResults.count == 1 ? "" : "s")")
            } footer: {
                Text("Finder and Trash are managed separately under Dock Items.")
            }
        }
    }

    private func isRunning(_ id: String) -> Bool {
        running.apps.contains { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
}

private struct ApplicationToggleRow: View {
    let app: AppInfo
    @ObservedObject var settings: SettingsManager
    var isRunning: Bool = false

    private var isHidden: Binding<Bool> {
        Binding(
            get: {
                settings.hiddenApps.contains { $0.caseInsensitiveCompare(app.id) == .orderedSame }
            },
            set: { shouldHide in
                if shouldHide {
                    settings.addHiddenApp(app.id)
                } else {
                    settings.removeHiddenApp(app.id)
                }
            }
        )
    }

    var body: some View {
        Toggle(isOn: isHidden) {
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(app.name)
                        if isRunning {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                                .help("Running")
                                .accessibilityLabel("Running")
                        }
                    }
                    Text(app.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.switch)
        .accessibilityIdentifier("application-toggle-\(app.id)")
    }
}

private struct AboutStatusView: View {
    private let ammoniaPath = "/var/ammonia"
    private let tweakPath = "/var/ammonia/core/tweaks/libHider.dylib"

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)) where version != build:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        default:
            return "Development Build"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader("About", subtitle: "Installation details for Hider.")

            Form {
                Section("Status") {
                    StatusRow(
                        title: "Ammonia",
                        isInstalled: FileManager.default.fileExists(atPath: ammoniaPath)
                    )
                    StatusRow(
                        title: "Hider Tweak",
                        isInstalled: FileManager.default.fileExists(atPath: tweakPath)
                    )
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                }

                Section {
                    Text("Live Dock hiding requires SIP to be disabled and Ammonia to be installed.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct StatusRow: View {
    let title: String
    let isInstalled: Bool

    var body: some View {
        LabeledContent(title) {
            Label(
                isInstalled ? "Installed" : "Not Installed",
                systemImage: isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(isInstalled ? .green : .secondary)
        }
    }
}

@main
struct HiderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Hider", id: "main") {
            HiderSettingsView()
                .frame(minWidth: 700, minHeight: 460)
        }
        .defaultSize(width: 860, height: 580)
        .windowResizability(.contentMinSize)
    }
}
