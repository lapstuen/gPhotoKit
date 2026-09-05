// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "gPhotoKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "gPhotoKit", targets: ["gPhotoKit"]),
    ],
    targets: [
        .target(
            name: "gPhotoKit",
            resources: [.process("Resources")]
        ),
    ]
)
