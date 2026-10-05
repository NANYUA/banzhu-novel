// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NovelCore",
    // platforms 同时列出 macOS，**只为让 CI 的 `swift test` 能跑**：
    // swift test 在 macOS 主机上执行，而包若只声明 iOS，
    // macOS 会拿到默认的极低部署目标，导致 Logger/Task 等报「不可用」。
    // App 本身只发 iOS（D5 已定 iOS 17）；单元测试跑的是纯逻辑，不依赖平台差异。
    //
    // 🔴 必须是 .macOS(.v14) 而不是 .v13：本包用 SwiftData（`@Model` / `ModelContainer`），
    //    SwiftData 的硬门槛是 **macOS 14**（与 iOS 17 对称）。
    //    写成 .v13 时 5 个模型文件 + NovelStore 会全线报
    //    「'Model()' is only available in macOS 14 or newer」。
    //
    // 🔴 NovelEngine 也必须同步升到 .macOS(.v14)：
    //    SwiftPM 要求**依赖的包**的平台版本不得低于**依赖它的一方**，
    //    否则报「the library 'NovelCore' requires macos 14.0, but depends on the
    //    product 'NovelEngine' which requires macos 13.0」。两处必须一起改。
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NovelCore", targets: ["NovelCore"]),
    ],
    dependencies: [
        // 🔒 依赖方向：NovelCore → NovelEngine（单向）。
        //    NovelEngine 的 dependencies 是空的，因此它无法反向引用本包。
        .package(path: "../NovelEngine"),
        // D2 已定 TCA（Point-Free）。
        //
        // 🔴 必须 exact 锁定 1.23.0，不能写 from：
        //   1.23.0 是最后一个 `swift-tools-version:5.9` 的版本，1.24+ 提到了 6.1
        //   → 而 6.1 会要求更新版本的 XcodeToolchain，而 CI 用的是
        //   macos-15 的**默认 Xcode**，具体版本不可控。
        //   换版本 = 同时验证两件事（版本可用 + 工具链够新），CI 一次只能给出一个答案。
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.23.0"),
    ],
    targets: [
        // 🔒 本包禁止引用 UI：SwiftPM 管不到系统框架，故由
        //    .github/workflows/ci.yml 的架构校验脚本来拦。
        .target(
            name: "NovelCore",
            dependencies: [
                .product(name: "NovelEngine", package: "NovelEngine"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            path: "Sources/NovelCore"
        ),
        .testTarget(
            name: "NovelCoreTests",
            dependencies: [
                "NovelCore",
                // 测试要用 TestStore / withDependencies，就必须能 import ComposableArchitecture
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            path: "Tests/NovelCoreTests"
        ),
    ]
)
