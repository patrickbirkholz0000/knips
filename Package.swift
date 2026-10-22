// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Knips",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Automatische Updates (MIT). Feste Version — eine neue Sparkle-Version nur bewusst übernehmen
        // (Änderungen lesen, `scripts/update-test.sh` laufen lassen).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Knips",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Knips",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                // Sparkle.framework liegt im App-Bundle unter Contents/Frameworks (scripts/build.sh).
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
