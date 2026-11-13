// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import PackageDescription
import Foundation

let package = Package(
    name: "Tilvero",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PowerCore", targets: ["PowerCore"]),
        .library(name: "PowerTelemetry", targets: ["PowerTelemetry"]),
        .library(name: "PowerPersistence", targets: ["PowerPersistence"]),
        .library(name: "PowerDiagnostics", targets: ["PowerDiagnostics"]),
        .library(name: "ChargeBackends", targets: ["ChargeBackends"]),
        .library(name: "FanBackends", targets: ["FanBackends"]),
        .library(name: "KeyboardBackends", targets: ["KeyboardBackends"]),
        .library(name: "ComfortBackends", targets: ["ComfortBackends"]),
        .library(name: "PowerSimulator", targets: ["PowerSimulator"]),
        .library(name: "PowerPrivileged", targets: ["PowerPrivileged"]),
        .library(name: "ClosedLidControl", targets: ["ClosedLidControl"]),
        .executable(name: "TilveroLidHelper", targets: ["TilveroLidHelper"]),
        .executable(name: "TilveroApp", targets: ["TilveroApp"]),
        .executable(name: "TilveroHelper", targets: ["TilveroHelper"])
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "PowerCore"),
        .target(
            name: "PowerTelemetry",
            dependencies: ["PowerCore"],
            linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS])), .linkedFramework("CoreGraphics", .when(platforms: [.macOS]))]
        ),
        .target(name: "PowerPersistence", dependencies: ["PowerCore"], linkerSettings: [.linkedFramework("CoreData")]),
        .target(name: "PowerDiagnostics", dependencies: ["PowerCore"]),
        .target(name: "PowerUIBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "ChargeBackends", dependencies: ["PowerCore", "PowerUIBridge"], linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "FanBackends", dependencies: ["PowerCore"], linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "KeyboardBackends", dependencies: ["PowerUIBridge"]),
        .target(name: "ComfortBackends", linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("CoreGraphics")]),
        .target(name: "PowerSimulator", dependencies: ["PowerCore"]),
        .target(name: "PowerPrivileged", dependencies: ["PowerCore", "ChargeBackends", "FanBackends"], linkerSettings: [.linkedFramework("Security"), .linkedFramework("ServiceManagement")]),
        .target(name: "ClosedLidControl", dependencies: ["PowerPrivileged"],
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security"),
                                 .linkedFramework("SystemConfiguration"), .linkedFramework("CoreGraphics")]),
        .executableTarget(name: "TilveroLidHelper", dependencies: ["ClosedLidControl", "PowerPrivileged"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker",
                URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Config/TilveroLidHelper-Info.plist").path])]),
        .executableTarget(name: "TilveroHelper", dependencies: ["PowerPrivileged"], path: "Helper", exclude: ["THIRD_PARTY_NOTICES.md", "README.md"]),
        .executableTarget(
            name: "TilveroApp",
            dependencies: ["PowerCore", "PowerTelemetry", "PowerPersistence", "PowerDiagnostics", "PowerSimulator", "PowerPrivileged", "ChargeBackends", "FanBackends", "KeyboardBackends", "ComfortBackends", "ClosedLidControl", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources/Localizable.xcstrings"), .copy("Resources/BatteryAssembly.png"),
                        .copy("Resources/AdapterIllustration.png"), .copy("Resources/MacIllustration.png"),
                        .copy("Resources/RestIllustration.png"), .copy("Resources/OverviewMacIllustration.png")],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("SwiftUI", .when(platforms: [.macOS])),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(name: "PowerCoreTests", dependencies: ["PowerCore"]),
        .testTarget(name: "PowerTelemetryTests", dependencies: ["PowerTelemetry", "PowerCore", "PowerDiagnostics"]),
        .testTarget(name: "PowerPersistenceTests", dependencies: ["PowerPersistence", "PowerCore"]),
        .testTarget(name: "PowerControlTests", dependencies: ["PowerCore", "PowerSimulator", "ChargeBackends", "FanBackends"]),
        .testTarget(name: "KeyboardBackendsTests", dependencies: ["KeyboardBackends"]),
        .testTarget(name: "ComfortBackendsTests", dependencies: ["ComfortBackends"]),
        .testTarget(name: "PowerPrivilegedTests", dependencies: ["PowerPrivileged"]),
        .testTarget(name: "ClosedLidControlTests", dependencies: ["ClosedLidControl"]),
        .testTarget(name: "TilveroAppTests", dependencies: ["TilveroApp", "ClosedLidControl"])
    ],
    swiftLanguageModes: [.v6]
)
