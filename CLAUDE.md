# Novel Reader · Project Guide

> ⚠️ **维护规则（重要）**：本文件是 harness **自动加载**的项目约定，必须与代码同步。
> 凡改动**目录结构 / 文件增删 / 构建命令 / 数据契约**，**必须在同一个改动里更新本文件**，不要留到下次。
> 本文件只写**模块级**结构，**不逐文件罗列**（会漂移）；文件级索引（每个文件的行数与主类型行号）、行数红线、测试映射见本地工作区文档 `PROJECT_MAP.md`（该文件不在本仓库内）。

## Status

业务开发阶段。书架、目录、阅读、搜索、发现、下载队列、书架分组、批量操作、
站点设置、阅读设置持久化均已落地；章节级 LRU 缓存淘汰规则与执行器已实现。

缓存闭环已接通：阅读成功后写入 `lastReadAt`；阅读时自动缓存后续章节，
缓存后触发 LRU 淘汰。

## 技术栈

| 项 | 值 |
|---|---|
| 最低系统版本 | iOS 17.0（SwiftData 的硬门槛） |
| 状态管理 | TCA (Point-Free) 1.23.0 |
| 持久化 | SwiftData |
| 排版度量 | NovelPagination（TextKit：NSTextStorage / NSLayoutManager） |
| 工程生成 | XcodeGen |
| 格式化 / 静态检查 | SwiftFormat + SwiftLint |
| CI | GitHub Actions，五道关卡 + 独立打包 workflow |

## 架构

依赖方向**单向不可逆**：

```
App → NovelCore → NovelEngine
 └──→ NovelPagination        # 仅 App 直接使用（真实排版度量）
```

- `NovelEngine`：纯逻辑层（网络 / 解析 / 解码），零 UI 依赖
- `NovelCore`：状态管理（TCA）+ 持久化（SwiftData）+ 分页算法
- `NovelPagination`：TextKit 真实度量，是**包级 UIKit 白名单**（有意豁免）
- `App`：SwiftUI 视图，不含业务逻辑

`Packages/` 内禁止 `import SwiftUI`（`NovelPagination` 除外），由
`scripts/check-architecture.sh` 强制（CI 关卡 0，本地也可跑）。

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

## 目录结构（模块级，文件数随代码变化请同步更新）

```
├── App/
│   ├── Resources/Info.plist
│   └── Sources/                     # SwiftUI 视图层（23 文件）
│       ├── AppMain.swift            # @main 入口
│       ├── RootView.swift           # 三 tab 根视图 + 全局覆盖层
│       ├── BookshelfView*.swift     # 书架（+GroupBar 分组条）
│       ├── BookDetailView*.swift    # 详情页（+DownloadRefresh）
│       ├── ChapterListView.swift    # 目录页 + 章节下载选择
│       ├── Reader*.swift            # 阅读器：View / PageGesture / PageTurn /
│       │                            #   SlideTracking / PageTextView / Appearance /
│       │                            #   SettingsView / SearchView
│       ├── SearchView.swift         # 搜索
│       ├── ExploreView.swift        # 发现/分类
│       ├── DownloadQueueView.swift  # 下载队列 + 下载设置
│       ├── SiteSettingsView.swift   # 站点设置
│       ├── GuardView.swift          # 盾页/人机校验覆盖层
│       └── AppTheme / DesignTokens / PressableCardButtonStyle.swift
├── Packages/
│   ├── NovelEngine/                 # 纯逻辑层（9 文件）
│   │   ├── Sources/NovelEngine/     # 网络 / 解析 / 解码 / 重试 / 日志
│   │   └── Tests/                   # 含 Fixtures 快照测试
│   ├── NovelCore/                   # 状态 + 存储 + 分页算法（42 文件）
│   │   ├── Sources/NovelCore/
│   │   │   ├── Models/              # BookRecord / ChapterRecord / BookGroup / DownloadTask(+Snapshot)
│   │   │   ├── Storage/             # NovelStore (SwiftData) / CacheEvictionPlanner
│   │   │   ├── Shelf/               # BookshelfFeature / ShelfRow / ShelfLoader / ShelfAdder /
│   │   │   │                        #   ShelfGroupStore / ShelfBatchDownloader
│   │   │   ├── Search/ Detail/ Download/ Explore/
│   │   │   ├── Reader/              # ReaderFeature / ReaderLoader / ChapterCacheStore /
│   │   │   │                        #   ReadingSettingsStore / PagePanTracking / SlideTracking …
│   │   │   ├── Pagination/          # Paginator / TextCursor / TextMeasuring / PageRange
│   │   │   ├── Site/                # SiteFeature / SiteStore / NavigationRenderer
│   │   │   └── Guard/               # GuardFeature / GuardCoordinator
│   │   └── Tests/
│   └── NovelPagination/             # TextKit 真实度量（UIKit 白名单包，2 文件）
├── scripts/
│   └── check-architecture.sh        # 5 条架构约束
└── .github/workflows/
    ├── ci.yml                       # 五道关卡（架构 / 格式 / Lint / 编译 / 测试）
    └── package-dev.yml              # 未签名打包
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

⚠️ 本机（Windows，无 Xcode/Swift）**跑不了编译与单测**，验证只能靠 CI；
本地只能跑 `check-architecture.sh` 与 `swiftformat --lint`。CI 失败时会自动上传
`build.log` / `test-core.log` / `test-engine.log` 为 artifact。

## 两条数据契约（破了就是用户可感知损失）

1. **缓存淘汰不能删用户下载的章节**
   `ChapterSource.isEvictable` 是闸门，且必须**按章不按书**淘汰。
   缓存上限只统计含自动缓存章节的书；用户下载的章节既不计入上限，也永不被淘汰。

2. **阅读位置存 `characterOffset`，不存页码**
   字号/行距/页边距等设置都会改变分页。
