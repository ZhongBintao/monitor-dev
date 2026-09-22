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
            path: "Sources/InputscapeKit"
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
