// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NovelEngine",
    // platforms 同时列出 macOS，**只为让 CI 的 `swift test` 能跑**：
    // swift test 在 macOS 主机上执行，而包若只声明 iOS，
    // macOS 会拿到默认的极低部署目标，导致 Logger/Task 等报「不可用」。
    // App 本身只发 iOS（D5 已定 iOS 17）；单元测试跑的是纯逻辑，不依赖平台差异。
    //
    // 🔴 必须是 .macOS(.v14)：本包自身只需 Foundation/os/WebKit，.v13 本够用，
    //    但 NovelCore 依赖本包且用了 SwiftData（需 macOS 14），
    //    SwiftPM 会以「依赖的平台版本不得低于依赖方」为由拒绝加载。
    //    **两个包的 macOS 版本必须一致**，改一个就要改另一个。
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NovelEngine", targets: ["NovelEngine"]),
    ],
    targets: [
        .target(
            name: "NovelEngine",
            // 🔒 依赖方向：App → NovelCore → NovelEngine（绝不可反向）
            //    这里为空 → 本包无法引用 NovelCore，违反方向直接编译失败。
            //    （「不许 import UI」由 scripts/check-architecture.sh 拦，
            //      因为 SwiftPM 管不到系统框架）
            dependencies: [],
            path: "Sources/NovelEngine"
        ),
        // D11 已定：测试挂进 CI，不通过即构建失败。
        // 引擎测试跑在 macOS（swift test），故 platforms 需含 macOS。
        .testTarget(
            name: "NovelEngineTests",
            dependencies: ["NovelEngine"],
            path: "Tests/NovelEngineTests",
            resources: [
                // 🔴 必须声明！否则 Fixtures/ 不会被打进测试 bundle，
                //    测试运行时读到空字符串 → 0 结果 → 数组越界崩溃。
                .copy("Fixtures")
            ]
        ),
    ]
)
