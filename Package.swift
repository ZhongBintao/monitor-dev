// swift-tools-version:5.9
import PackageDescription

// 模块划分（REFACTOR_PLAN.md §4）：
// - InputscapeCore    纯逻辑：键盘规范、分类器、分钟累加器、节奏/热力计算、Lab 评估。只依赖 Foundation，全部可单测。
// - InputscapeStore   SQLite（GRDB）：表结构、按分钟增量写入、查询、旧数据导入。
// - InputscapeCapture 系统接口：事件 tap、MultitouchSupport、输入源、生命周期。
// - Inputscape        SwiftUI 应用。
let package = Package(
    name: "Inputscape",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Inputscape", targets: ["Inputscape"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "InputscapeCore",
            path: "Sources/InputscapeCore"
        ),
        .target(
            name: "InputscapeStore",
            dependencies: [
                "InputscapeCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/InputscapeStore"
        ),
        .target(
            name: "InputscapeCapture",
            dependencies: ["InputscapeCore", "InputscapeStore"],
            path: "Sources/InputscapeCapture",
            linkerSettings: [
                // MultitouchSupport 为 macOS 私有框架，需显式指向 PrivateFrameworks。
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "MultitouchSupport"
                ])
            ]
        ),
        .executableTarget(
            name: "Inputscape",
            dependencies: ["InputscapeCore", "InputscapeStore", "InputscapeCapture"],
            path: "Sources/Inputscape"
        ),
        .testTarget(
            name: "InputscapeTests",
            dependencies: ["InputscapeCore", "InputscapeStore", "InputscapeCapture"],
            path: "Tests/InputscapeTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
