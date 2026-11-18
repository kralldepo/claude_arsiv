// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SohbetTemizleyici",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SohbetTemizleyici",
            path: "Sources/SohbetTemizleyici"
        ),
    ]
)
