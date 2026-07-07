// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OutputsSyncNightly",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "OutputsSyncNightly",
            path: "Sources/OutputsSyncNightly",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Network")
            ]
        )
    ]
)
