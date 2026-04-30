// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MicBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MicBar",
            path: "Sources/MicBar",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
