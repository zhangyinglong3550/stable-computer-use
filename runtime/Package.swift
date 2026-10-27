// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "scu-ax",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "scu-ax",
            path: "Sources/scu-ax"
        )
    ]
)
