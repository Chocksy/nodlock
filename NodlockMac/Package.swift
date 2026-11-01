// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Nodlock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nodlock",
            path: "Sources/Nodlock",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NodlockTests",
            dependencies: ["Nodlock"],
            path: "Tests/NodlockTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
