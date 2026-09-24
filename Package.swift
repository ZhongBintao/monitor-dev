// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Inputscape",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Inputscape", targets: ["InputscapeApp"])
    ],
    targets: [
        .target(
            name: "InputscapeKit",
            path: "Sources/InputscapeKit",
            linkerSettings: [
                // TouchpointMonitor：MultitouchSupport 为 macOS 私有框架，
                // SDK 不随默认搜索路径提供，需显式指向 PrivateFrameworks。
                // 路径不带 SDK 前缀——链接器会自动以 sysroot 前缀化，升级 SDK 无需改动。
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "MultitouchSupport"
                ])
            ]
        ),
        .executableTarget(
            name: "InputscapeApp",
            dependencies: ["InputscapeKit"],
            path: "Sources/InputscapeApp"
        ),
        .testTarget(
            name: "InputscapeKitTests",
            dependencies: ["InputscapeKit"],
            path: "Tests/InputscapeKitTests"
        )
    ]
)
