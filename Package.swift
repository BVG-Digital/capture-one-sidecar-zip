// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SidecarZip",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SidecarZip", path: "Sources/SidecarZip")
    ]
)
