# Novel Reader · Project Guide

## Status

业务开发阶段。骨架完成，CI 五道关卡全绿，第一个 feature（书架）已落地。

## 技术栈

| 项 | 值 |
|---|---|
| 最低系统版本 | iOS 17.0（SwiftData 的硬门槛） |
| 状态管理 | TCA (Point-Free) 1.23.0 |
| 持久化 | SwiftData |
| 工程生成 | XcodeGen |
| 格式化 / 静态检查 | SwiftFormat + SwiftLint |
| CI | GitHub Actions，五道关卡 |

## 架构

依赖方向**单向不可逆**：

```
App → NovelCore → NovelEngine
```

- `NovelEngine`：纯逻辑层（网络 / 解析 / 解码），零 UI 依赖
- `NovelCore`：状态管理（TCA）+ 持久化（SwiftData）
- `App`：SwiftUI 视图，不含业务逻辑

`Packages/` 内禁止 `import SwiftUI`，由 `scripts/check-architecture.sh` 强制
（CI 关卡 0，本地也可跑）。

## 三个必须知道的踩坑结论

### 1. 宏在 CI 上不可用

Xcode 16.4 + macos-15 runner 下，宏插件报 `produced malformed response`，
两层 `-skip*Validation` 都无效。

→ 所有 feature **手写 `Reducer` 协议**，只保留 `@Dependency`
（它是 property wrapper，不是宏）。
→ View 层用 `WithViewStore` 观察状态，不用 `store.state`
（后者要求 `ObservableState`）。

### 2. SwiftFormat 与 SwiftLint 有直接冲突项

`trailingComma`（Format 要求加 / Lint 要求不要）、
`multiple_closures_with_trailing_closure`（与 `trailingClosures` 打架）。

→ 格式归 SwiftFormat 独家负责，冲突的 Lint 规则已在 `.swiftlint.yml` 关闭。

### 3. Fixtures 必须声明为 SwiftPM 资源

否则测试读不到文件 → 空字符串 → 解析出 0 条 → **数组越界崩溃**。
且不能用 `Bundle.module`（xcodebuild 场景下不生成）。

## 目录结构

```
├── App/
│   ├── Resources/Info.plist
│   └── Sources/
│       ├── AppMain.swift
│       ├── RootView.swift
│       └── BookshelfView.swift
├── Packages/
│   ├── NovelEngine/             # 纯逻辑层
│   │   ├── Sources/NovelEngine/ # 9 个文件
│   │   └── Tests/               # 含 Fixtures 快照测试
│   └── NovelCore/               # 状态 + 存储
│       ├── Sources/NovelCore/
│       │   ├── Models/          # BookRecord / ChapterRecord / BookGroup / DownloadTask
│       │   ├── Storage/         # NovelStore (SwiftData)
│       │   └── Shelf/           # BookshelfFeature / ShelfRow / ShelfLoader
│       └── Tests/
├── scripts/
│   └── check-architecture.sh    # 5 条架构约束
└── .github/workflows/ci.yml     # 五道关卡
```

## 常用命令

```bash
# 架构校验（不需要 macOS）
sh scripts/check-architecture.sh

# 生成 Xcode 工程
xcodegen generate

# 编译
xcodebuild -project BanzhuNovel.xcodeproj -scheme BanzhuNovel \
  -destination 'generic/platform=iOS Simulator' \
  -skipMacroValidation -skipPackagePluginValidation build

# 测试
swift test --package-path Packages/NovelCore
swift test --package-path Packages/NovelEngine
```

## 两条数据契约（破了就是用户可感知损失）

1. **缓存淘汰不能删用户下载的章节**
   `ChapterSource.isEvictable` 是闸门，且必须**按章不按书**淘汰。

2. **阅读位置存 `characterOffset`，不存页码**
   字号/行距/页边距等设置都会改变分页。
