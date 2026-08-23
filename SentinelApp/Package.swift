// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Sentinel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sentinel",
            path: "Sources/Sentinel",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
