// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LoomDesktop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LoomDesktop",
            path: "Sources/LoomDesktop",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("WebKit")]
        )
    ]
)
