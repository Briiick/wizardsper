// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Wizard",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WizardKit", targets: ["WizardKit"]),
        .executable(name: "wizard-cli", targets: ["wizardcli"]),
    ],
    targets: [
        .target(
            name: "WizardKit",
            path: "Sources/WizardKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "wizardcli",
            dependencies: ["WizardKit"],
            path: "Sources/wizardcli",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WizardKitTests",
            dependencies: ["WizardKit"],
            path: "Tests/WizardKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
