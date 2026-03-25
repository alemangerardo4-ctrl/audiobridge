// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioBridgeApp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AudioBridgeApp",
            path: "AudioBridgeApp",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("Cocoa"),
            ]
        )
    ]
)
