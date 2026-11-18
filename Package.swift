// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SimLab",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SimLab", targets: ["SimLab"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.30.0"),
        .package(path: "Vendor/SimKit"),
    ],
    targets: [
        .testTarget(name: "AndroidLabTests", dependencies: ["SimLab"]),
        .executableTarget(
            name: "SimLab",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "SimKit", package: "SimKit"),
            ],
            path: "Sources/AndroidLab"
        ),
    ]
)
