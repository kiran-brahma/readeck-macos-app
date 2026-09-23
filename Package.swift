// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Readeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Readeck",
            path: "Sources/ReadeckApp"
        )
    ]
)
