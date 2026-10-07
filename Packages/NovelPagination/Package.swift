// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NovelPagination",
    // platforms 同时列出 macOS，**只为让 CI 的 `swift test` 能跑**：
    // swift test 在 macOS 主机上执行，而包若只声明 iOS，
    // macOS 会拿到默认的极低部署目标，导致 Logger/Task 等报「不可用」。
    //
    // 🔴 必须是 .macOS(.v14) 而不是 .v13：本包依赖 NovelCore，
    //    NovelCore 用了 SwiftData（需 macOS 14），
    //    SwiftPM 会以「依赖的平台版本不得低于依赖方」为由拒绝加载。
    //    **被依赖方（NovelCore）的版本不能倒挂**——三包平台必须一致。
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NovelPagination", targets: ["NovelPagination"]),
    ],
    dependencies: [
        .package(path: "../NovelCore"),
    ],
    targets: [
        .target(
            name: "NovelPagination",
            dependencies: [
                .product(name: "NovelCore", package: "NovelCore"),
            ],
            path: "Sources/NovelPagination"
        ),
    ]
)