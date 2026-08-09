// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReleaseKitApp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ReleaseKitApp", targets: ["ReleaseKitApp"]),
    ],
    targets: [
        .executableTarget(
            name: "ReleaseKitApp",
            path: "Sources"
        ),
        .testTarget(
            name: "ReleaseKitAppTests",
            dependencies: ["ReleaseKitApp"],
            path: "Tests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
