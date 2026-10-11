import ComposableArchitecture
import Foundation

// 相邻章切换：到章尾无缝进下一章（全景图 `+1` 格）、到章首无缝退上一章（`-1` 格）。
//
// 从 `ReaderFeature.swift` 拆出来的：那个文件已经贴着 SwiftLint `file_length` 600 的
// warning 线（CI `--strict` 下 warning 即失败），而「相邻章」是其中最独立的一段
// —— 搬走不改行为（先例：`ReaderView+PageGesture.swift` 从 `ReaderView.swift` 拆出）。
//
// ## 两个方向逐条镜像（读的时候左右对照）
// | 关注点 | 下一章 | 上一章 |
// |---|---|---|
// | 预加载 | `preloadNextChapter` | `preloadPreviousChapter` |
// | 收结果 + 按当前 config 现算分页 | `applyNextChapterLoaded` | `applyPreviousChapterLoaded` |
// | 作废 | `invalidateNextChapter` | `invalidatePreviousChapter` |
// | 迁移 | `advanceToNextChapter` | `retreatToPreviousChapter` |
//
// 两个方向各自的那一步在 `preloadAdjacentChapters` 里**串行**接起来（先下一章、
// 后上一章）—— 它是唯一对外的一步，两个 `preload*Chapter` 因此可以是 `private`。
//
// 两个迁移**只在一处不同**，是需求本身要的：
// 退章后 `currentOffset` 落到**上一章最后一页的页首**（`previousPages.last?.location`），
// 不是 0 —— 退章要接在上一章章尾之后，进章才是从章首开始。
//
// ## 为什么每个迁移都要管「另一侧」
// 换章后 `previousChapter` 与 `nextChapter` **都**换了对象：只清一侧、把另一侧留在
// 原处，全景图那一格就会拿**别的章**的正文去切页（错配）。所以两个迁移都是
// 「本方向：清空 + 链式重新预加载；另一方向：同样清空 + 链式重新预加载」。
//
// ## 为什么两个预加载串行发（`concatenate` 而不是 `merge`）
// `.merge` 里两条 effect 是**并发**的，action 到达顺序没有保证；而 `TestStore` 是按
// 到达顺序收 action 的 ⇒ 用例会偶发红。两个读取都是本地缓存读（上一章刚读过、
// 下一章由自动缓存写好），串行多出来的那点延迟可以忽略；换来的是「先下一章、
// 后上一章」这条顺序**在代码里确定**，三处调用点与测试都按同一顺序。
//
// ⚠️ 下面这些函数（除两个 `private` 的 `preload*Chapter`）都不是 `private`：调用点在
// `ReaderFeature.swift` 的 reducer body 里，而 `private` 是**文件级**的，跨文件就看不见了。

// MARK: - 作废

/// 作废「下一章」的预加载结果。
///
/// 换章时必须调用（含从目录手动跳章、重新加载当前章）：否则上一章预加载的
/// `nextPages` 会被当成新章的「下一章」，翻过去就是错的正文。
func invalidateNextChapter(_ state: inout ReaderFeature.State) {
    state.nextText = ""
    state.nextPages = []
}

/// 作废「上一章」的预加载结果（与 `invalidateNextChapter` 同一模式）。
///
/// 换章时必须调用：否则更早那一章预加载的 `previousPages` 会被当成新章的
/// 「上一章」，往回翻就是错的正文。
func invalidatePreviousChapter(_ state: inout ReaderFeature.State) {
    state.previousText = ""
    state.previousPages = []
}

// MARK: - 迁移（换章）

/// 到章尾再往前：切到下一章。
///
/// **只做状态迁移，不重新加载** —— 下一章第 1 页此刻就摆在全景图的 `+1` 格上，
/// 换章后它正好变成当前页；正文与分页都是预加载好的，平移因此是连续的。
///
/// 边界（owner 选择）：最后一章、或下一章第 1 页还没就绪 ⇒ `.none`，
/// 手势原地回弹，**不提示**。
func advanceToNextChapter(
    _ state: inout ReaderFeature.State,
    loader: ReaderLoader,
    progressStore: ReadingProgressStore,
    cacheStore: ChapterCacheStore
) -> Effect<ReaderFeature.Action> {
    guard state.currentPageIndex >= 0,
          state.currentPageIndex == state.pages.count - 1,
          !state.nextPages.isEmpty,
          let next = state.nextChapter
    else { return .none }
    let nextText = state.nextText
    let nextPath = next.path
    // 口径与 `contentLoaded` 完全一致（同一个依赖、同样的参数含义），
    // 换章后的缓存行为才与「正常开章」等价。
    let precacheCount = state.precacheCount
    state.chapterPath = next.path
    state.chapterName = next.name
    state.text = nextText
    state.pages = state.nextPages
    // 🔴 数据契约：位置存字符偏移 —— 新章从头开始，不是「把页码归零」。
    state.currentOffset = 0
    // 先清空再重算（链式）：新的下一章预加载回来之前，旧的 nextPages
    // 绝不能被当成新章的下一章。
    invalidateNextChapter(&state)
    // 反向同理：换章后「上一章」也换了对象（变成刚离开的这一章），旧的 previousPages
    // 属于更早那一章 —— 不清空就会被当成新章的上一章，往回翻是错的正文。
    invalidatePreviousChapter(&state)
    return .merge(
        // 沿用既有口径：对新章写一条 offset 0 的阅读进度。
        saveProgress(chapterPath: state.chapterPath, offset: 0, store: progressStore),
        // 换章也要补一次自动缓存：否则「读过就缓存」这条闭环在换章路径上断掉，
        // 离线可读范围不再随阅读推进而扩大。对已缓存的本章是无操作
        // （`saveCachedText` 内容相同即不写盘、不刷新 `savedAt`）。
        .run { _ in
            await cacheStore.cacheCurrentAndFollowing(
                nextPath,
                nextText,
                precacheCount
            )
        },
        // 链式：到新章后再预加载它的下一章、以及（反向）它的上一章 —— 少了上一章
        // 这一步，「往前翻回上一章」在换过一次章之后就断了（owner 反馈的正是这一条）。
        preloadAdjacentChapters(state, loader: loader)
    )
}

/// 到章首再往后：切到上一章**最后一页**。
///
/// **只做状态迁移，不重新加载** —— 上一章最后一页此刻就摆在全景图的 `-1` 格上，
/// 退章后它正好变成当前页；正文与分页都是预加载好的，平移因此是连续的。
///
/// 边界（owner 选择）：第一章、或上一章最后一页还没就绪 ⇒ `.none`，
/// 手势原地回弹，**不提示**（与末章对称）。
func retreatToPreviousChapter(
    _ state: inout ReaderFeature.State,
    loader: ReaderLoader,
    progressStore: ReadingProgressStore,
    cacheStore: ChapterCacheStore
) -> Effect<ReaderFeature.Action> {
    guard state.currentPageIndex == 0,
          !state.previousPages.isEmpty,
          let previous = state.previousChapter,
          let lastLocation = state.previousPages.last?.location
    else { return .none }
    let previousText = state.previousText
    let previousPath = previous.path
    // 与 `advanceToNextChapter` 同口径（同一个依赖、同样的参数含义）。
    let precacheCount = state.precacheCount
    state.chapterPath = previous.path
    state.chapterName = previous.name
    state.text = previousText
    state.pages = state.previousPages
    // 🔴 数据契约：位置存字符偏移 —— 落到**上一章最后一页的页首**，不是「把页码归零」。
    // 这是与 `advanceToNextChapter` 唯一的实质差别：退章要接在上一章章尾之后。
    state.currentOffset = lastLocation
    // 先清空再重算（链式）：新的上一章预加载回来之前，旧的 previousPages
    // 绝不能被当成新章的上一章。
    invalidatePreviousChapter(&state)
    // 反向同理：换章后「下一章」也换了对象（变成刚离开的这一章），旧的 nextPages
    // 属于更晚那一章 —— 不清空就会被当成新章的下一章。
    invalidateNextChapter(&state)
    return .merge(
        // 落盘的是**末页页首**的字符偏移：`progressOffset` 已扣掉章名前缀，
        // 与 `ReadingProgressStore` 的落盘口径一致。
        saveProgress(
            chapterPath: state.chapterPath,
            offset: state.progressOffset,
            store: progressStore
        ),
        // 换章也要补一次自动缓存（与 `advanceToNextChapter` 同口径）。
        .run { _ in
            await cacheStore.cacheCurrentAndFollowing(
                previousPath,
                previousText,
                precacheCount
            )
        },
        // 链式：退到新章后再预加载它的上一章、以及（反向）它的下一章。
        preloadAdjacentChapters(state, loader: loader)
    )
}

// MARK: - 收结果 + 按当前 config 现算分页

/// 收下预加载的下一章正文，并按**当前** config 现算分页。
///
/// 分页刻意不放在预加载 effect 里：用户可能在预加载途中改字号，
/// 用旧 config 分出来的页会与渲染盒错位（B0-2 几何契约）。
/// 分页为空 ⇒ 安静留空：不报错、不提示（owner 明确不要提示）。
func applyNextChapterLoaded(
    path: String,
    text: String,
    to state: inout ReaderFeature.State,
    using paginationService: PaginationService
) -> Effect<ReaderFeature.Action> {
    // 竞态守卫：这次结果必须仍是**当前**的下一章 —— 换过章 / 从目录跳过章，
    // 路径就对不上了，结果作废（否则 A 章的下一页会被错配给 B 章）。
    guard let next = state.nextChapter, next.path == path else { return .none }
    let pages = paginationService.paginate(
        ReaderFeature.State.displayText(chapterName: next.name, text: text),
        state.config
    )
    guard !pages.isEmpty else { return .none }
    state.nextText = text
    state.nextPages = pages
    return .none
}

/// 收下预加载的上一章正文，并按**当前** config 现算分页（镜像 `applyNextChapterLoaded`）。
///
/// 分页与当前章同一份 config，退章后 `previousPages` 直接当新章的分页用时才对得上渲染盒。
/// 分页为空 ⇒ 安静留空：不报错、不提示。
func applyPreviousChapterLoaded(
    path: String,
    text: String,
    to state: inout ReaderFeature.State,
    using paginationService: PaginationService
) -> Effect<ReaderFeature.Action> {
    // 竞态守卫：这次结果必须仍是**当前**的上一章 —— 换过章 / 从目录跳过章，
    // 路径就对不上了，结果作废（否则 A 章的上一页会被错配给 B 章）。
    guard let previous = state.previousChapter, previous.path == path else { return .none }
    let pages = paginationService.paginate(
        ReaderFeature.State.displayText(chapterName: previous.name, text: text),
        state.config
    )
    guard !pages.isEmpty else { return .none }
    state.previousText = text
    state.previousPages = pages
    return .none
}

// MARK: - 预加载

/// 预加载「下一章」：读正文；**分页留给 reducer 收到结果时按当时的 config 现算**
/// （提前分页会在用户改字号后与渲染盒错位）。
///
/// - 没有下一章（最后一章 / 列表里找不到当前章）⇒ `.none`，到章尾保持回弹；
/// - 读失败、或拿到空正文 ⇒ 什么都不发：安静失败，不报错、不提示。
private func preloadNextChapter(
    _ state: ReaderFeature.State,
    loader: ReaderLoader
) -> Effect<ReaderFeature.Action> {
    guard let next = state.nextChapter else { return .none }
    return .run { send in
        guard let text = try? await loader.load(next.path), !text.isEmpty else { return }
        await send(.nextChapterLoaded(next.path, text))
    }
}

/// 预加载「上一章」：读正文；分页同样留给 reducer 按**当时**的 config 现算。
///
/// 上一章通常已在本地缓存（刚读过 / 开章时自动缓存过）⇒ 一般只是一次磁盘读。
///
/// - 没有上一章（第一章 / 列表里找不到当前章）⇒ `.none`，到章首保持回弹；
/// - 读失败、或拿到空正文 ⇒ 什么都不发：安静失败，不报错、不提示。
private func preloadPreviousChapter(
    _ state: ReaderFeature.State,
    loader: ReaderLoader
) -> Effect<ReaderFeature.Action> {
    guard let previous = state.previousChapter else { return .none }
    return .run { send in
        guard let text = try? await loader.load(previous.path), !text.isEmpty else { return }
        await send(.previousChapterLoaded(previous.path, text))
    }
}

/// 预加载相邻两章：**先下一章、后上一章**，串行。
///
/// 三处调用点（`contentLoaded` / `advanceToNextChapter` / `retreatToPreviousChapter`）
/// 都走这一条，顺序才只有一处定义（理由见文件头：`.merge` 的到达顺序没有保证，
/// 而 `TestStore` 按到达顺序收 action）。
func preloadAdjacentChapters(
    _ state: ReaderFeature.State,
    loader: ReaderLoader
) -> Effect<ReaderFeature.Action> {
    .concatenate(
        preloadNextChapter(state, loader: loader),
        preloadPreviousChapter(state, loader: loader)
    )
}
