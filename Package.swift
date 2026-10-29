// swift-tools-version: 6.0
import PackageDescription

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
        .library(name: "PowerSimulator", targets: ["PowerSimulator"]),
        .library(name: "PowerPrivileged", targets: ["PowerPrivileged"]),
        .executable(name: "TilveroApp", targets: ["TilveroApp"]),
        .executable(name: "TilveroHelper", targets: ["TilveroHelper"])
    ],
    targets: [
        .target(name: "PowerCore"),
        .target(
            name: "PowerTelemetry",
            dependencies: ["PowerCore"],
            linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]
        ),
        .target(name: "PowerPersistence", dependencies: ["PowerCore"], linkerSettings: [.linkedFramework("CoreData")]),
        .target(name: "PowerDiagnostics", dependencies: ["PowerCore"]),
        .target(name: "PowerUIBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "ChargeBackends", dependencies: ["PowerCore", "PowerUIBridge"], linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "FanBackends", dependencies: ["PowerCore"], linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "KeyboardBackends", dependencies: ["PowerUIBridge"]),
        .target(name: "PowerSimulator", dependencies: ["PowerCore"]),
        .target(name: "PowerPrivileged", dependencies: ["PowerCore", "ChargeBackends", "FanBackends"], linkerSettings: [.linkedFramework("Security"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "TilveroHelper", dependencies: ["PowerPrivileged"], path: "Helper", exclude: ["THIRD_PARTY_NOTICES.md", "README.md"]),
        .executableTarget(
            name: "TilveroApp",
            dependencies: ["PowerCore", "PowerTelemetry", "PowerPersistence", "PowerDiagnostics", "PowerSimulator", "PowerPrivileged", "ChargeBackends", "FanBackends", "KeyboardBackends"],
            resources: [.copy("Resources/Localizable.xcstrings"), .copy("Resources/BatteryAssembly.png"),
                        .copy("Resources/AdapterIllustration.png"), .copy("Resources/MacIllustration.png"),
                        .copy("Resources/RestIllustration.png")],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("SwiftUI", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(name: "PowerCoreTests", dependencies: ["PowerCore"]),
        .testTarget(name: "PowerTelemetryTests", dependencies: ["PowerTelemetry", "PowerCore", "PowerDiagnostics"]),
        .testTarget(name: "PowerPersistenceTests", dependencies: ["PowerPersistence", "PowerCore"]),
        .testTarget(name: "PowerControlTests", dependencies: ["PowerCore", "PowerSimulator", "ChargeBackends", "FanBackends"]),
        .testTarget(name: "KeyboardBackendsTests", dependencies: ["KeyboardBackends"]),
        .testTarget(name: "PowerPrivilegedTests", dependencies: ["PowerPrivileged"]),
        .testTarget(name: "TilveroAppTests", dependencies: ["TilveroApp"])
    ],
    swiftLanguageModes: [.v6]
)
