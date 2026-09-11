// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Wizardsper",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WizardsperKit", targets: ["WizardsperKit"]),
        .executable(name: "wizardsper-cli", targets: ["wizardspercli"]),
    ],
    targets: [
        .target(
            name: "WizardsperKit",
            path: "Sources/WizardsperKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "wizardspercli",
            dependencies: ["WizardsperKit"],
            path: "Sources/wizardspercli",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WizardsperKitTests",
            dependencies: ["WizardsperKit"],
            path: "Tests/WizardsperKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
