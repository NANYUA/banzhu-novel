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
/// ## 布局（owner 已拍板，2026-10-10）
/// - 第一行两个**次级**按钮：加入 / 移出书架（左）+ 下载章节（右），都 `.bordered`、都
///   `.frame(maxWidth: .infinity)` ⇒ 等宽对称；
/// - 第二行是页面上**唯一**的主按钮：开始 / 继续阅读（`.borderedProminent`）；
/// - 加入 / 移出书架的失败提示（`shelfNotice`）跟随本按钮组，不留在原处。
///
/// ⚠️ 「加入书架」在未加入时**原先**是主按钮，本次按 owner 决定降为次级 ——
/// 「一屏只留一个主按钮」优先于「加入书架要显眼」。
///
/// ## 跨文件的可见性（拆分的唯一代价）
/// - `actionSection` 必须 `internal`：`BookDetailView.body` 在另一个文件里调用它；
/// - 本文件其余成员只在本文件内互相引用，仍是 `private`；
/// - `BookDetailView` 上的 `openReader` / `presentChapterPicker` 同理放开为 `internal`
///   （跨文件的 extension 读不到 file-private 成员），可见性说明留在原文件里。
extension BookDetailView {
    /// 按钮组整体：次级按钮一行 + 主行动一行 + 书架操作的失败提示。
    func actionSection(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                shelfButton(viewStore)
                downloadChaptersButton
            }
            // 两个次级按钮共用一档控件尺寸 **且** 标签侧共用同一个 44pt 最小高度
            // （`shelfLabel` / `downloadChaptersButton`）⇒ 短边等高，且都是 44pt 触控目标（§9）。
            // ⚠️ 只写 `.controlSize(.large)` 不够：真机上「加入 / 移出书架」比「下载章节」矮，
            // 差别就在标签有没有 `.frame(minHeight: 44)` —— 控件尺寸只决定按钮的**内边距**，
            // 高度是「标签高度 + 内边距」，故标签侧的差异会原样变成按钮的高度差。
            .controlSize(.large)

            if let notice = viewStore.shelfNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(AppTheme.statusDanger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            primaryActions(viewStore)
        }
    }
}

// MARK: - 加入 / 移出书架

private extension BookDetailView {
    /// 书架开关（**次级**按钮）。按 `isOnShelf` 切换。
    ///
    /// 视觉分工（§9 主次分明）：主按钮只留给「开始 / 继续阅读」，本按钮一律 `.bordered`。
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
            }
        }
        .buttonStyle(.bordered)
        .disabled(viewStore.isShelfBusy)
    }

    /// 按钮标签：忙碌时是 `ProgressView`，否则是图标 + 动作文字。
    ///
    /// **三个按钮短边等高的唯一来源**：与「下载章节」（`downloadChaptersButton`）、
    /// 「开始 / 继续阅读」（`readLabel`）共用同一个 `.frame(minHeight: 44)`。
    /// 原先只有另外两处带这一行，本标签没有 ⇒ 同一个 `HStack` 里左右两个次级按钮高度不同
    /// （真机反馈「按钮大小不一致，三个按钮应该短边长度一致」）。
    ///
    /// 补在标签侧而不是去掉另外两处：这一行的高度**本来就由「下载章节」决定**
    /// （`HStack` 取两者最大值），所以补齐只是让左按钮长到与右按钮一样高，按钮组整体不变高；
    /// 反过来去掉另外两处会把整组按钮连同主按钮一起压矮，改动面更大。
    /// 忙碌态（`ProgressView`）同样吃这个最小高度 ⇒ 切到加载态时按钮不会突然变矮。
    func shelfLabel(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>,
        title: String,
        systemImage: String
    ) -> some View {
        Group {
            if viewStore.isShelfBusy {
                ProgressView()
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
    /// 下载章节入口（**次级**按钮，与左侧「加入 / 移出书架」等宽 ⇒ 一行左右对称）。
    ///
    /// 动作**直接复用**详情页既有的 `presentChapterPicker()`：它自带防重入，面板内容取自
    /// `viewStore.chapters` 的当前值 —— 这里不新写任何业务逻辑，也不再从目录 header 进
    /// （同页两个相同入口是本次要消掉的重复）。
    ///
    /// ⚠️ 本按钮**始终显示**，不沿用旧 header 那个「0 章时不摆恒不可用的入口」守卫：
    /// owner 指定的是一行左右对称的两个按钮（加入 / 移出书架在左、下载章节在右），
    /// 0 章或目录加载中时隐藏会让这一行塌成单个按钮、破坏该布局；
    /// 「还没有章节」由选择面板自己的空态表达（`ChapterDownloadPicker`）。
    var downloadChaptersButton: some View {
        Button {
            presentChapterPicker()
        } label: {
            Label("下载章节", systemImage: "arrow.down.circle")
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
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

    func readButton(
        _ title: String,
        systemImage: String,
        chapter: ChapterItem
    ) -> some View {
        Button {
            openReader(chapter)
        } label: {
            readLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    func readLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
