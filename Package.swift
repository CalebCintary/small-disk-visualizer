// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DiskVisualizer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DiskVisualizer")
    ]
)
