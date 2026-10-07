// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Knips",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Knips",
            path: "Sources/Knips",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
