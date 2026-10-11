# Novel Reader · Project Guide

> ⚠️ **维护规则（重要）**：本文件是 harness **自动加载**的项目约定，必须与代码同步。
> 凡改动**目录结构 / 文件增删 / 构建命令 / 数据契约**，**必须在同一个改动里更新本文件**，不要留到下次。
> 本文件只写**模块级**结构，**不逐文件罗列**（会漂移）；文件级索引（每个文件的行数与主类型行号）、行数红线、测试映射见本地工作区文档 `PROJECT_MAP.md`（该文件不在本仓库内）。

## Status

业务开发阶段。书架、目录、阅读、搜索、发现、下载队列、书架分组、批量操作、
站点设置、阅读设置持久化均已落地；章节级 LRU 缓存淘汰规则与执行器已实现。

缓存闭环已接通：阅读成功后写入 `lastReadAt`；阅读时自动缓存后续章节，
缓存后触发 LRU 淘汰。淘汰**只清「已读章号 + 预缓存章数」之外的陈旧预取** ——
已读章节与当前预取窗口内的章节都保留（否则「点下一章 / 返回上一章」会重新联网加载）。

阅读页排版有三条长期口径（改分页 / 正文样式前先读）：
1. **任何一页都不得以换行开头** —— `Paginator` 会把紧随页末的连续换行并入本页
   （第 4 条守恒律）。否则页首空行会让各页正文首行的纵向位置不一致，
   章尾多余的换行还会撑出一个整页空白的末页。
2. **从段落中间开始的那一页，首行不加首行缩进** —— 判据唯一来源是
   `ParagraphBoundary.isParagraphStart`，度量侧（`TextKitMeasuring`）与渲染侧
   （`PageTextView`）**必须都调它**，否则度量盒与渲染盒错位、每页多塞或少塞正文。
3. 设置里的「正文边框标识」在阅读页画出正文盒边界（红色虚线），几何与正文层
   **同一份来源**（不另算 padding）。

阅读设置里的数值项一律用 `NumberInputRow`（`− 数字框 +`，可键入），不再用 `Slider`，也不再用
`Stepper`（「预缓存」也已换过来）。数值框是**固定宽度**（`NumberInputMetrics`，按「最宽 4 个字形」
算出、随 Dynamic Type 缩放）；键盘上只有**一份**「完成」——挂在设置页的 `@FocusState` 上，
⛔ 行内不要再各挂一份 `.toolbar(placement: .keyboard)`（10 份堆叠会同时出现多个「完成」并导致卡顿）。

阅读页两条控制栏的竖向边距（上标签上边距 / 下标签下边距）默认 **0**、范围 **0…70**，
**没有「自动档」**：`0` = 面板贴屏幕最边缘（上栏会被刘海/状态栏压住，这是 owner 口径、不是 bug）。
旧版本允许过的负值（面板移出屏幕边缘）已按 owner 第二版口径废弃，在合并处被收成 **0**。
`ReadingSettings` 里那两个字段仍是 `Optional`（`nil` = 老数据 ⇒ 按 0），
⛔ 不要改成非 Optional（会让老用户整份设置解码失败）。

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

### 3. Fixtures 靠 `#filePath` 定位，不要用 `Bundle.module`

测试里的 `fixture(_:)` 辅助函数用 `#filePath` 反推**源码目录**，再按
「`Tests/NovelEngineTests/Fixtures/` → `Tests/Fixtures/`」两级候选探测；
12 个 `.html` 实际放在 `Packages/NovelEngine/Tests/Fixtures/`（即**第二级候选命中**），
测试**不经过 bundle**。

→ 因此 `testTarget` **不声明 `resources:`**。曾写过的 `.copy("Fixtures")` 是**失效声明**
  （`Tests/NovelEngineTests/` 下并没有 `Fixtures/` 目录），没有任何消费者，已删除。
→ **仍不要用 `Bundle.module`**（xcodebuild 场景下不生成）。
→ 定位失败时辅助函数会把尝试过的路径打进断言消息，CI 日志能直接指出问题。

## 目录结构（模块级，文件数随代码变化请同步更新）

```
├── App/
│   ├── Resources/Info.plist
│   └── Sources/                     # SwiftUI 视图层（37 文件）
│       ├── AppMain.swift            # @main 入口
│       ├── RootView.swift           # 四 tab 根视图（书架/书城/搜索/设置）+ 全局盾页覆盖层
│       ├── BookshelfView*.swift     # 书架（+GroupBar 分组条 / +Reader 单点进阅读页）
│       ├── BookDetailView*.swift    # 详情页（+DownloadRefresh）
│       ├── ChapterListView.swift    # 目录页 + 章节下载选择
│       ├── Reader*.swift            # 阅读器：View / PageGesture / PageTurn /
│       │                            #   SlideTracking / PageTextView / Appearance /
│       │                            #   Chrome / ChromeStyle / Insets（上下栏边距解析）/
│       │                            #   MoreMenu（右上「更多」自绘下拉面板）/ SettingsView / SearchView /
│       │                            #   CornerHUD（角落标签：书名·章节名 / 电量 / 页码）/
│       │                            #   ChromeJumpBar（跳章条 + 可拖页码进度条）/
│       │                            #   TextAreaBorder（正文盒红线标尺，设置里开关）/
│       │                            #   DownloadPicker（阅读页「下载」弹的章节选择面板）
│       ├── SearchView.swift         # 搜索
│       ├── ExploreView.swift        # 发现/分类
│       ├── DownloadQueueView.swift  # 下载队列 + 下载设置（卡片常驻上栏）
│       ├── DownloadBookCard.swift   # 下载书卡 + 卡片装饰（downloadQueueCard/Row）+ 共享尺度
│       ├── DownloadSummaryCard.swift # 总进度卡片（与选择卡片**同位交替**）
│       ├── DownloadSelectionCard.swift # 选择模式四项操作卡片（横排一行）
│       ├── SiteSettingsView.swift   # 站点设置
│       ├── GuardView.swift          # 盾页/人机校验覆盖层
│       └── AppTheme / DesignTokens / PressableCardButtonStyle / NumberInputRow.swift
│                                    # NumberInputRow = 设置页「− 数字框 +」输入行（替代 Slider）
├── Packages/
│   ├── NovelEngine/                 # 纯逻辑层（9 文件）
│   │   ├── Sources/NovelEngine/     # 网络 / 解析 / 解码 / 重试 / 日志
│   │   └── Tests/                   # 含 Fixtures 快照测试（12 个 .html）
│   ├── NovelCore/                   # 状态 + 存储 + 分页算法（51 文件）
│   │   ├── Sources/NovelCore/
│   │   │   ├── Models/              # BookRecord / ChapterRecord / BookGroup / DownloadTask(+Snapshot)
│   │   │   ├── Storage/             # NovelStore (SwiftData) / CacheEvictionPlanner
│   │   │   ├── Shelf/               # BookshelfFeature / ShelfRow / ShelfLoader / ShelfAdder /
│   │   │   │                        #   ShelfGroupStore / ShelfBatchDownloader /
│   │   │   │                        #   ReadingTargetLoader（单点书卡 → 阅读落点）/ BookCoverLoader
│   │   │   ├── Search/ Detail/ Explore/
│   │   │   ├── Download/            # DownloadFeature（+State / +Selection）/ DownloadQueueStore /
│   │   │   │                        #   DownloadSettingsStore（下载设置持久化）/ DownloadNetworkMonitor
│   │   │   ├── Reader/              # ReaderFeature（+ChapterTransition 相邻章切换）/ ReaderLoader /
│   │   │   │                        #   ChapterCacheStore / ReadingSettingsStore /
│   │   │   │                        #   ReadingProgressStore / PagePanTracking / SlideTracking /
│   │   │   │                        #   ParagraphIndentStripper（行首空白归一化）…
│   │   │   ├── Pagination/          # Paginator / TextCursor / TextMeasuring / PageRange /
│   │   │   │                        #   ParagraphBoundary（段落边界判据，度量与渲染共用）
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

## 三条数据契约（破了就是用户可感知损失）

1. **「已下载」的唯一真相是 `ChapterRecord.source == .downloaded`**
   **不得**用 `hasLocalText` 或本地文件名反推 —— 阅读时的自动缓存同样会让
   `hasLocalText` 为 true，但那**可被 LRU 淘汰**，不是用户下载的内容。

2. **缓存淘汰不能删用户下载的章节，也不能删「已读章节 + 当前预取窗口」**
   `ChapterSource.isEvictable` 是闸门，且必须**按章不按书**淘汰。
   缓存上限只统计含自动缓存章节的书；用户下载的章节既不计入上限，也永不被淘汰。
   自动缓存里**可淘汰**的只有：`.cached` 且 `number > 已读章号 + precacheCount`
   （已读章号 = `BookRecord.lastReadChapterPath` 指向章节的 `number`，查不到按 0 算；
   `precacheCount` = 阅读设置里的「预缓存 N 章」，由 `ChapterCacheStore` 的 `followingCount` 传入）。
   ⇒ 正在读的那一本天然全保，被清的只有「窗口外的陈旧预取」。

3. **阅读位置存 `characterOffset`，不存页码**
   字号/行距/页边距等设置都会改变分页。
