// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hmon",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "hmon",
            path: "Sources/hmon",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Foundation"),
            ]
        )
    ]
)
