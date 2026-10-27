// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "smac-ax",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "smac-ax",
            path: "Sources/smac-ax"
        )
    ]
)
