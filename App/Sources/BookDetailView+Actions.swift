import ComposableArchitecture
import NovelCore
import SwiftUI

/// 详情页按钮组（U1-8 从 `BookDetailView.swift` 原样拆出，并重排到「简介」之前）。
///
/// ## 为什么单独一个文件
/// 这一块自成一个整体：只读 `ViewStore` 与「入下载队列 / 打开章节选择面板」两个动作，
/// 与简介 / 信息区 / 目录零耦合 —— 整体搬走，不复制任何代码（拆法沿用 `BookshelfView+GroupBar`
/// 的先例）。拆出后 `BookDetailView.swift` 重新远离 SwiftLint `file_length` 门槛（600）。
///
/// ## 布局（owner 2026-10-11 第二次拍板：B+C 组合）
/// **一行三个等宽按钮**：加入 / 移出书架（左）· 下载章节（中）· 开始 / 继续阅读（右），
/// 列间距 `Spacing.sm`(12)、各自撑满列宽 ⇒ 三等分。
/// - 两个**次级**按钮**去边框**（`.borderless`：无边框、无底色，只有强调色的图标 + 文字）；
/// - **唯一的主按钮**「开始 / 继续阅读」是**自绘实心胶囊**（`AppTheme.accent` 填充 + 白字），
///   只占 1/3 宽；
/// - 标签**竖排**（图标在上、文字在下）：4 个汉字的词条在 ≈106pt 的列里放得下，
///   不必缩成「加入」「下载」这类两个字的残词。
///
/// 旧版是「一行两个 `.bordered` 次级按钮 + 一行横贯整屏的主按钮」：三处标签都被
/// `.frame(minHeight: 44)` 钉住、外面又套了 `.controlSize(.large)`（系统内边距再叠一层）
/// ⇒ 单个按钮 ≈68pt、**两行**合计 ≈144pt（68 + `Spacing.xs`(8) + 68）。owner 反馈「太大」，
/// 高度 / 宽度 / 色块三项都要减 ⇒ 现在只有**一行**，行高 **44pt**（算式见下）。
///
/// ## 高度算式（数字可自己推）：三个按钮**逐值 44pt**
/// 竖排标签自然高 = 图标 `.body`(17pt 字身，行高 ≈20.3) + `Spacing.xxs`(4)
/// + 文字 `.caption`(12pt，行高 ≈14.3) ≈ **38.6pt** ≤ 44 ⇒ 三个按钮的高度**只由**
/// `detailActionHitBox()` 的 `.frame(minHeight: 44)` 决定（HIG §9 的最小触控目标，
/// 命中区 = 可视区），行高 = **44pt**。
///
/// ⚠️ **主按钮为什么也自绘**（owner 2026-10-11 第三次裁决「三个都自绘：严格 44pt 等高」）：
/// 系统 `.borderedProminent` 会在标签**之外**再加一层自己的上下内边距（≈7pt/侧：
/// 依据 `BookshelfView.swift:100-101` 的实测注释 —— 默认标签 ≈20.3pt 时系统按钮 ≈34pt），
/// 标签 44pt 时按钮会变成 ≈58pt —— **物理上做不到 44**，而这一行三个必须等高。
/// ⇒ 主按钮自绘：填充画在 **label 的 `.background`** 上、`PressableCardButtonStyle`
/// 的 `shape` 与填充同形（照 `BookshelfView+GroupBar.swift` 的 `GroupChip` 既有模式）。
/// ⚠️ 填充**必须**落在 label 内部：写在外层再挂 `.buttonStyle` 的话，按下时只有缩放 /
/// 强调层生效、**胶囊本身不动** ⇒ 破了「按下瞬间必须有可感知反馈」。
///
/// ⚠️ Dynamic Type：大字号下竖排标签自然会长过 44pt ⇒ 按钮**跟着长**
/// （`.frame(minHeight:)` 是**下限**，不裁字）—— 这是刻意的：宁可三个按钮一起长高，
/// 也不把字切掉；三者共用同一个标签本体与同一个命中框 ⇒ 永远一起长、一起等高。
///
/// ⚠️ 三个按钮的**字体 / 间距 / 单行缩字**只有 `actionLabelBody` 一处来源，
/// **命中框（撑满列宽 + 44pt + 整块可点）**只有 `detailActionHitBox` 一处来源 ——
/// 「三个按钮大小不一致」在真机上反馈过两次，每次都是因为出现了第二份写法。
///
/// ## 跨文件的可见性（拆分的唯一代价）
/// - `actionSection` 必须 `internal`：`BookDetailView.body` 在另一个文件里调用它；
/// - 本文件其余成员只在本文件内互相引用，仍是 `private`；
/// - `BookDetailView` 上的 `openReader` / `presentChapterPicker` 同理放开为 `internal`
///   （跨文件的 extension 读不到 file-private 成员），可见性说明留在原文件里。
extension BookDetailView {
    /// 按钮组整体：一行三个按钮 + 书架操作的失败提示。
    func actionSection(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                shelfButton(viewStore)
                downloadChaptersButton
                // 目录还没加载出来时 `primaryActions` 一个视图都不产出 ⇒ 那一格不占位
                // （这一行会暂时变成两个按钮各占一半宽）。**不**给它加占位视图：
                // 一个点不动的灰按钮比暂时少一个按钮更糟（同 `primaryActions` 的既有口径）。
                primaryActions(viewStore)
            }

            if let notice = viewStore.shelfNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(AppTheme.statusDanger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - 三个按钮共用的标签与命中框

private extension BookDetailView {
    /// 竖排标签本体：图标在上、文字在下。
    ///
    /// ## 为什么竖排
    /// 三个按钮现在并成一行、各占 ≈106pt（375pt 屏的算式：`375 − 2×Spacing.md(16)` = 343，
    /// 再减两条 `Spacing.sm`(12) 列间距 = 319，三等分 ≈106.3pt）。
    /// 横排「图标 + 4 个汉字」在 `.body` 下约需 17 + 6 + 68 ≈ 91pt，留给图标与文字都会很紧；
    /// 竖排则把宽度需求降到「最长词条 4 字」—— `.caption`(12pt) 下 4×12 = **48pt** ≤ 106 ✓，
    /// 词条可以写全（「加入书架」而不是「加入」）。
    ///
    /// ## 为什么 `lineLimit(1)` + `minimumScaleFactor(0.8)`
    /// 大字号（Dynamic Type）下文字会变宽：先**缩字**到 0.8，仍放不下才**截断**。
    /// **绝不换行** —— 换行会把这一行顶高，三个按钮立刻不等高（真机反馈过两次的那条）。
    /// 高度也随 Dynamic Type 长大，但三个按钮**共用**这一个本体 ⇒ 永远一起长、一起等高等。
    func actionLabelBody(_ title: String, systemImage: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: systemImage)
                .font(.body)

            Text(title)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private extension View {
    /// 详情页按钮的命中框：**撑满列宽**（三等分靠它）+ **至少 44pt 高**（HIG §9 的最小触控目标）
    /// + **整块可点**（`.contentShape` 让 44pt 框内没有点不动的死区）。
    ///
    /// ## 三个按钮的**唯一**高度来源
    /// 两个次级按钮是 `.borderless`（系统不加内边距），主按钮是自绘胶囊（不经系统样式）
    /// ⇒ 三者都只吃这一个下限，标签自然高 38.6 ≤ 44 ⇒ **逐值同为 44pt**（算式见文件头）。
    /// ⚠️ 不要在这里按按钮分档传不同高度：一旦出现第二档，三个按钮就不再等高
    /// （owner 2026-10-11 的裁决就是「严格 44pt 等高」）。
    func detailActionHitBox() -> some View {
        frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - 加入 / 移出书架

private extension BookDetailView {
    /// 书架开关（**次级**按钮，无边框）。按 `isOnShelf` 切换。
    ///
    /// 视觉分工（§9 主次分明）：主按钮只留给「开始 / 继续阅读」，本按钮只有图标 + 文字、
    /// **没有底色块**（`.borderless`），颜色就是它唯一的强调手段。
    ///
    /// 已加入时用**红色**（`statusDanger`）而不是绿色：本按钮此刻的动作是「移出书架」，
    /// 是**破坏性操作**，按 §11 要给警示色；红色同时说明「点下去会失去什么」。
    /// （原先用绿色表达「已在书架」这个状态 —— 那是拿状态色去粉饰一个删除动作，已废。）
    /// 文字仍写**动作**而不是状态（§11：按钮标签用动词）：写「已加入」会看不出点了会怎样。
    func shelfButton(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        Group {
            if viewStore.isOnShelf {
                Button {
                    removeFromShelf(viewStore)
                } label: {
                    shelfLabel(viewStore, title: "移出书架", systemImage: "checkmark.circle.fill")
                }
                // 红色 = 破坏性操作（§11）。绿色留给「已完成 / 已在架」这类**状态**表达。
                .tint(AppTheme.statusDanger)
            } else {
                Button {
                    viewStore.send(.addRequested)
                } label: {
                    shelfLabel(viewStore, title: "加入书架", systemImage: "plus")
                }
                // 去边框后按钮只剩图标 + 文字，颜色就是全部视觉 —— 这里显式写 `AppTheme.accent`
                // 而不是依赖 `.borderless` 去读环境 tint：环境 tint 是 `RootView` 单点设的，
                // 本行写出来只是把「次级按钮用强调色」这条口径落在按钮自己身上（同一个令牌，
                // 不新增颜色真相源）。
                .tint(AppTheme.accent)
            }
        }
        .buttonStyle(.borderless)
        .disabled(viewStore.isShelfBusy)
    }

    /// 书架按钮的标签：忙碌时换成 `ProgressView`，**仍然吃同一个命中框**。
    ///
    /// 常态与忙碌态共用 `detailActionHitBox()`：切到加载态时按钮不会突然变矮
    /// （`ProgressView` 只有 ≈20pt，没有这个下限就会塌）。
    /// 标签本体的字体 / 间距与另外两个按钮同源（`actionLabelBody`）。
    func shelfLabel(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>,
        title: String,
        systemImage: String
    ) -> some View {
        Group {
            if viewStore.isShelfBusy {
                ProgressView()
            } else {
                actionLabelBody(title, systemImage: systemImage)
            }
        }
        .detailActionHitBox()
    }

    func removeFromShelf(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) {
        // 与书架编辑态的删除保持一致：先把这本书在下载队列里的任务取消掉，
        // 再删本地记录与已下载正文。
        downloadStore.send(.cancelBook(viewStore.detail.bookPath))
        viewStore.send(.removeRequested)
    }
}

// MARK: - 下载入口（U1-7）

private extension BookDetailView {
    /// 下载章节入口（**次级**按钮，无边框，与左右两个按钮等宽 ⇒ 一行三等分）。
    ///
    /// 动作**直接复用**详情页既有的 `presentChapterPicker()`：它自带防重入，面板内容取自
    /// `viewStore.chapters` 的当前值 —— 这里不新写任何业务逻辑，也不再从目录 header 进
    /// （同页两个相同入口是本次要消掉的重复）。
    ///
    /// ⚠️ 本按钮**始终显示**，不沿用旧 header 那个「0 章时不摆恒不可用的入口」守卫：
    /// owner 指定的是一行三等分的三个按钮（加入 / 移出书架在左、下载章节在中），
    /// 0 章或目录加载中时隐藏会让这一行塌成两个按钮、破坏该布局；
    /// 「还没有章节」由选择面板自己的空态表达（`ChapterDownloadPicker`）。
    var downloadChaptersButton: some View {
        Button {
            presentChapterPicker()
        } label: {
            actionLabelBody("下载章节", systemImage: "arrow.down.circle")
                .detailActionHitBox()
        }
        .buttonStyle(.borderless)
        .tint(AppTheme.accent)
        .accessibilityLabel("下载章节，选择要下载的章节")
    }
}

// MARK: - 阅读入口（U1-6）

private extension BookDetailView {
    /// 主行动入口：有上次阅读记录就是「继续阅读」，否则是「开始阅读」。
    ///
    /// 目录还没加载出来时**什么都不摆** —— 点了没反应的死按钮比没有按钮更糟，
    /// 而「加载中 / 失败 / 为空」由下面的目录区块统一表达（只在那里出一个 ProgressView，
    /// 首屏不会出现两条「目录加载中…」）。
    @ViewBuilder
    func primaryActions(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        if let continueChapter = viewStore.continueChapter {
            readButton("继续阅读", systemImage: "book.pages", chapter: continueChapter)
        } else if let first = viewStore.chapters.first {
            readButton("开始阅读", systemImage: "book.pages", chapter: first)
        }
    }

    /// 页面上**唯一**的主按钮：**自绘实心胶囊**（`AppTheme.accent` 填充 + 白字），
    /// 只占一行 1/3 宽，高度与旁边两个按钮**逐值相同（44pt）**。
    ///
    /// ## 为什么不用系统 `.borderedProminent`
    /// 它在标签**之外**自带 ≈7pt/侧的上下内边距（标签 44 ⇒ 按钮 ≈58pt），**做不到 44pt**，
    /// 而这一行三个按钮必须等高 ⇒ owner 2026-10-11 裁决「三个都自绘：严格 44pt 等高」
    /// （算式见文件头）。
    ///
    /// ## 填充必须画在 label 内部
    /// 照 `BookshelfView+GroupBar.swift` 的 `GroupChip` 既有模式：填充落在 **label 的
    /// `.background`** 上，`.buttonStyle` 的 `shape` 与填充同形（`Capsule()`）。
    /// ⚠️ 若把填充写在 `Button` **外面**再挂 `.buttonStyle`，按下时只有缩放 / 强调层生效、
    /// **胶囊本身不动** ⇒ 破了「按下瞬间必须有可感知反馈」。
    ///
    /// ## 强调层用默认色
    /// `PressableCardButtonStyle` 的 `pressedHighlightColor` 保持默认 `Color.primary`：
    /// 它的文档写明只有「元素底色可能与 `Color.primary` 同色」时才需要换色，
    /// 而这里是 `AppTheme.accent` 填充 ⇒ 默认值即可（浅色下变暗、深色下提亮，都可感知）。
    /// 白字压在强调色上是**项目已裁定**的取舍（见 `AppTheme.accent` 的文档注释：深色下 3.65:1，
    /// 任何单一深色值都无法同时满足两条 ≥ 4.5）⇒ 不为此新增硬编码色、也不改 `AppTheme.accent`。
    func readButton(
        _ title: String,
        systemImage: String,
        chapter: ChapterItem
    ) -> some View {
        Button {
            openReader(chapter)
        } label: {
            actionLabelBody(title, systemImage: systemImage)
                .detailActionHitBox()
                .background(AppTheme.accent, in: Capsule())
                .foregroundStyle(Color.white)
        }
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(Capsule())))
    }
}
