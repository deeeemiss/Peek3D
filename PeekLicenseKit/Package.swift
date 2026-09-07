// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PeekLicenseKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PeekLicenseKit", targets: ["PeekLicenseKit"])
    ],
    targets: [
        .target(
            name: "PeekLicenseKit"
        ),
        .testTarget(
            name: "PeekLicenseKitTests",
            dependencies: ["PeekLicenseKit"]
        )
    ]
)
