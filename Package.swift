// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirGrab",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "AirGrab", path: "Sources/AirGrab")
    ]
)
