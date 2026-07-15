// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Hider",
    platforms: [
        // Build against the macOS 26 (Tahoe) SDK so the app gets the native
        // Liquid Glass appearance. macOS gates the new look on the linked SDK
        // version, not the OS at runtime — an older deployment target renders the
        // legacy (pre-Tahoe) controls even when run on 26/27.
        .macOS(.v26),
    ],
    products: [
        .library(name: "HiderCore", targets: ["HiderCore"]),
        .executable(name: "HiderApp", targets: ["HiderApp"]),
        .executable(name: "hiderctl", targets: ["hiderctl"]),
    ],
    targets: [
        .target(
            name: "NotifyBridge",
            path: "src",
            exclude: [
                "Hider-Bridging-Header.h",
                "Hider.m",
                "HiderApp.swift",
                "SettingsManager.swift",
                "ZKSwizzle",
                "tweak.h",
            ],
            sources: ["notify_bridge.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "HiderCore",
            dependencies: ["NotifyBridge"],
            path: "Sources/HiderCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "HiderApp",
            dependencies: ["HiderCore"],
            path: "src",
            exclude: [
                "Hider-Bridging-Header.h",
                "Hider.m",
                "ZKSwizzle",
                "notify_bridge.c",
                "include",
                "tweak.h",
            ],
            sources: ["HiderApp.swift", "SettingsManager.swift"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "hiderctl",
            dependencies: ["HiderCore"],
            path: "Sources/hiderctl",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "HiderCoreTests",
            dependencies: ["HiderCore"],
            path: "Tests/HiderCoreTests",
            swiftSettings: [
                .unsafeFlags([
                    "-plugin-path",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
