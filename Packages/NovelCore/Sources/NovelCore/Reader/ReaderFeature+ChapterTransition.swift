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
// | 迁移（章尾 / 章首手势） | `advanceToNextChapter` | `retreatToPreviousChapter` |
// | 迁移（跳章条按钮） | `jumpToNextChapterStart` | `jumpToPreviousChapterStart` |
// | 按钮入口（就绪则直接换、否则回退） | `reduceJumpToAdjacentChapter`（**两个方向共用一个**） | — |
//
// 两个方向各自的那一步在 `preloadAdjacentChapters` 里**串行**接起来（先下一章、
// 后上一章）—— 它是唯一对外的一步，两个 `preload*Chapter` 因此可以是 `private`。
//
// 迁移有**四个入口**（章尾左滑 / 章首退上一章 / 跳章条的上一章 / 下一章），
// 它们共用同一份实现 `migrateToChapter` —— 差别只有「前置条件」与「落到新章哪一页」两处：
// - **章尾左滑** `advanceToNextChapter`：要求当前在**最后一页**，落到下一章**第 1 页**；
// - **章首退上一章** `retreatToPreviousChapter`：要求当前在**第一页**，落到上一章
//   **最后一页的页首**（`previousPages.last?.location`）—— 退章要接在上一章章尾之后；
// - **跳章条的两个按钮** `jumpToNextChapterStart` / `jumpToPreviousChapterStart`：
//   **不要求页位置**（按钮在任何页都要能按），落到目标章**第 1 页**（`offset = 0`）。
//   必须是第 1 页 —— 与完整加载 `loadChapterWithName` 落同一页，否则「预加载有没有就绪」
//   会让同一个按钮跳到不同的页。
//
// ## 换章时两侧怎么处理（先都作废，再把「刚离开那一章」搬回它该在的那一侧）
// 换章后 `previousChapter` 与 `nextChapter` **都**换了对象：只清一侧、把另一侧留在
// 原处，全景图那一格就会拿**别的章**的正文去切页（错配）。所以两个迁移都先
// **两侧作废**，再用 `installLeavingChapter` 把「刚离开那一章」放回它在新章里的那一侧
// （它的正文与整章分页此刻就在内存里，直接搬 ⇒ 不必等预加载）；
// 远侧保持作废，靠链式预加载重新取 —— 两侧都仍然会重新预加载一遍。
//
// ## 为什么两个预加载串行发（`concatenate` 而不是 `merge`）
// `.merge` 里两条 effect 是**并发**的，action 到达顺序没有保证；而 `TestStore` 是按
// 到达顺序收 action 的 ⇒ 用例会偶发红。两个读取都是本地缓存读（上一章刚读过、
// 下一章由自动缓存写好），串行多出来的那点延迟可以忽略；换来的是「先下一章、
// 后上一章」这条顺序**在代码里确定**，三处调用点与测试都按同一顺序。
//
// ⚠️ 本文件里的函数**不都是** `private`：`private` 是**文件级**的，而调用点在
// `ReaderFeature.swift` 的 reducer body 里（`reduceJumpToAdjacentChapter` 等），跨文件就看不见了。
// 只有「唯一调用点在本文件内」的才收成 `private`：两个 `preload*Chapter`
// （只由 `preloadAdjacentChapters` 调）与两个 `jumpTo*ChapterStart`
// （只由 `reduceJumpToAdjacentChapter` 调）。

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

// MARK: - 刚离开的那一章（换章时直接搬过去）

/// 换章**之前**从 state 里取下的「刚离开那一章」：路径 + 正文 + 整章分页。
///
/// ## 为什么三件套必须一起取
/// `text` 与 `pages` 是**同源**的一对（`pages` 就是按 `displayText(chapterName:text:)`
/// 与当时的 config 分出来的）；分开取、或中途换了 config，搬过去的分页就与正文错位。
///
/// ## 为什么必须先取成值
/// `nextChapter` / `previousChapter` 是按 `chapterPath` **现算**的派生属性 ——
/// 一旦改了 `state.chapterPath`，旧章是哪一章就再也问不出来了。
struct LeavingChapter {
    let path: String
    let text: String
    let pages: [PageRange]

    init(_ state: ReaderFeature.State) {
        path = state.chapterPath
        text = state.text
        pages = state.pages
    }
}

/// 换章后把「刚离开那一章」放回它在新章里的那一侧；**另一侧保持作废**。
///
/// ## 为什么可以直接搬（owner 真机反馈的那一条）
/// 「切换章节的时候刚刚阅读的章节正文会消失」—— 旧章的正文与**整章分页**此刻本来就在
/// 内存里（`state.text` / `state.pages`），而且分页与正文同源 ⇒ 原样搬到 `previousPages` /
/// `nextPages` 就是那一章的合法分页：不必重新读盘 / 联网，也不必重新分页。
/// 少了这一步，换章那一瞬间两侧都是空的，而刚离开的那一章正好是其中一侧 ⇒
/// 马上往回滑（或往前滑回去）看到的是空白，要等预加载回来才有内容。
///
/// ## 为什么只搬一侧、另一侧必须作废
/// 换章后 `previousChapter` 与 `nextChapter` **都**换了对象，而刚离开的那一章只可能落在
/// 其中**一侧**（往前换 ⇒ 它是新的上一章；往回换 ⇒ 它是新的下一章）；另一侧现在指向的是
/// **另一个章**，留着旧数据就是错正文 —— 这正是 `invalidateNextChapter` /
/// `invalidatePreviousChapter` 存在的理由。
///
/// ## 方向怎么判
/// 不比对章号，而是问**换章后**的派生属性：`previousChapter` / `nextChapter` 都按新的
/// `chapterPath` 现算，谁的路径等于刚离开那一章，旧章就在谁那一侧。判据因此只有一处来源
/// （`chapters` + `chapterPath`），不会与派生属性分叉；两边都不等于（例如从目录跳到
/// 不相邻的章）⇒ 什么都不搬，两侧保持作废。
func installLeavingChapter(_ leaving: LeavingChapter, into state: inout ReaderFeature.State) {
    if state.previousChapter?.path == leaving.path {
        state.previousText = leaving.text
        state.previousPages = leaving.pages
    } else if state.nextChapter?.path == leaving.path {
        state.nextText = leaving.text
        state.nextPages = leaving.pages
    }
}

// MARK: - 迁移（换章）

/// 一次换章的**目标**：去哪一章 + 它的正文 + 它的分页 + 落到新章的哪个字符偏移。
///
/// 收成一个值类型而不是平铺成参数：`migrateToChapter` 平铺时是 **8 个参数**
/// （`state` + 三个依赖 + 这四个），越过 `function_parameter_count` 的门槛。
private struct ChapterMigration {
    let chapter: ChapterItem
    let text: String
    let pages: [PageRange]
    let offset: Int
}

/// **迁移的公共实现**：四个换章入口共用这一份 ——
/// 章尾左滑（`advanceToNextChapter`）、章首退上一章（`retreatToPreviousChapter`）、
/// 跳章条的「下一章」（`jumpToNextChapterStart`）与「上一章」（`jumpToPreviousChapterStart`）。
///
/// ## 为什么必须共用
/// 四者的差别**只有两处**：① 前置条件（是否要求「当前在最后一页 / 第一页」）；
/// ② 落到新章的哪一页（`offset`）。状态迁移本身（换 path / 章名 / 正文 / 分页 / 偏移）、
/// 两侧作废、落盘、补缓存、链式预加载**必须逐字相同** —— 复制出第二份，日后改一处忘另一处，
/// 就会变成「按钮换章与滑动换章行为不一致」这类极难查的缺陷。
///
/// ## 为什么目标（章 + 正文 + 分页 + 落页偏移）由调用方取好传进来
/// ① `nextChapter` / `previousChapter` 是按 `chapterPath` **现算**的派生属性 ⇒ 一旦改了
/// `state.chapterPath`，它们立刻指向新章的邻居。所以调用方必须**在调用前**把
/// 「要去的章 + 它的正文 + 它的分页」取好传进来；本函数只负责迁移与善后。
/// ② 还要取成**局部量**再传：`&state` 与 `state.nextText` 出现在同一次调用里属于
/// **重叠访问**（`state` 被 `inout` 借出期间不能再读它的属性）。
private func migrateToChapter(
    _ state: inout ReaderFeature.State,
    to target: ChapterMigration,
    loader: ReaderLoader,
    progressStore: ReadingProgressStore,
    cacheStore: ChapterCacheStore
) -> Effect<ReaderFeature.Action> {
    // 拆回局部量：函数体里原来的写法逐字保留 ⇒ 这次「收敛参数个数」没碰任何行为。
    let chapter = target.chapter
    let text = target.text
    let pages = target.pages
    let offset = target.offset
    let path = chapter.path
    // ⚠️ 必须在改 `chapterPath` **之前**取下「刚离开那一章」：`nextChapter` /
    // `previousChapter` 是按 `chapterPath` 现算的，改完就问不出旧章是哪一章了。
    let leaving = LeavingChapter(state)
    // 口径与 `contentLoaded` 完全一致（同一个依赖、同样的参数含义），
    // 换章后的缓存行为才与「正常开章」等价。
    let precacheCount = state.precacheCount
    state.chapterPath = path
    state.chapterName = chapter.name
    state.text = text
    state.pages = pages
    // 🔴 数据契约③：位置存字符偏移（`displayText` 坐标系、含章名前缀）——
    // 具体落到哪一页由调用方给：章首是 0，退上一章是末页页首。
    state.currentOffset = offset
    // 先清空再重算（链式）：新的邻居预加载回来之前，旧的 nextPages / previousPages
    // 绝不能被当成新章的邻居。**两侧都要清** —— 换章后两侧的对象都换了。
    invalidateNextChapter(&state)
    invalidatePreviousChapter(&state)
    // 再把「刚离开那一章」放回它在新章里的那一侧（另一侧保持刚作废的状态）：
    // 它的正文与整章分页此刻就在内存里，直接搬 ⇒ 换章后马上往回滑（或往前滑回去）
    // 立刻有内容，不必等预加载回来（owner 真机反馈：刚读过的那一章在滑动方向上是空白）。
    installLeavingChapter(leaving, into: &state)
    return .merge(
        // 落盘用 `progressOffset`（已扣掉章名前缀，与 `ReadingProgressStore` 同口径）：
        // 章首时它恒为 0，与旧 `advanceToNextChapter` 里写死的 0 **逐值等价**。
        saveProgress(chapterPath: path, offset: state.progressOffset, store: progressStore),
        // 换章也要补一次自动缓存：否则「读过就缓存」这条闭环在换章路径上断掉，
        // 离线可读范围不再随阅读推进而扩大（对已缓存的本章是无操作）。
        .run { _ in
            await cacheStore.cacheCurrentAndFollowing(path, text, precacheCount)
        },
        // 链式：到新章后再预加载它的相邻两章 —— 少了这一步，「往前翻回上一章」在换过一次章
        // 之后就断了（owner 反馈过这一条）。
        preloadAdjacentChapters(state, loader: loader)
    )
}

/// 到章尾再往前：切到下一章**第 1 页**。
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
    // ⚠️ 先取局部量：`&state` 与 `state.nextText` 同处一次调用 = 重叠访问（编译期错误）。
    let text = state.nextText
    let pages = state.nextPages
    return migrateToChapter(
        &state,
        to: ChapterMigration(chapter: next, text: text, pages: pages, offset: 0),
        loader: loader,
        progressStore: progressStore,
        cacheStore: cacheStore
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
    let text = state.previousText
    let pages = state.previousPages
    return migrateToChapter(
        &state,
        // 🔴 与「跳章条上一章」的**唯一**差别：退章要接在上一章章尾之后 ⇒ 落**末页页首**，
        // 不是章首（章首是「上一章按钮」的语义，见 `jumpToPreviousChapterStart`）。
        to: ChapterMigration(chapter: previous, text: text, pages: pages, offset: lastLocation),
        loader: loader,
        progressStore: progressStore,
        cacheStore: cacheStore
    )
}

/// 跳章条的「下一章」：切到下一章**第 1 页**；**不要求当前在最后一页**。
///
/// ## 为什么需要它（owner 真机反馈）
/// 「现在阅读界面的预缓存不起效果，我直接点击下一章还是需要加载」——
/// 预加载其实早就把 `nextText` / `nextPages` 备好了（章尾左滑换章一直是无 loading 的），
/// 只是跳章条的按钮原先走 `loadChapterWithName`：**整章重新加载** ⇒ `isLoading` 转圈。
/// 本函数把预加载好的那一份直接换上 ⇒ **没有 loading**。
///
/// ## 与 `advanceToNextChapter` 的唯一差别
/// 那个多一条 `currentPageIndex == pages.count - 1`（章尾左滑专用）。按钮在**任意页**都要能按，
/// 所以这里不设那条判据 —— 否则在中间页按下去就是「点了没反应」。
///
/// ## 落页口径必须与完整加载一致
/// `offset = 0`（新章第 1 页），与 `loadChapterWithName` 的落点**逐值相同** ——
/// 否则「预加载有没有就绪」会让同一个按钮跳到不同的页。
private func jumpToNextChapterStart(
    _ state: inout ReaderFeature.State,
    loader: ReaderLoader,
    progressStore: ReadingProgressStore,
    cacheStore: ChapterCacheStore
) -> Effect<ReaderFeature.Action> {
    guard !state.nextPages.isEmpty, let next = state.nextChapter else { return .none }
    let text = state.nextText
    let pages = state.nextPages
    return migrateToChapter(
        &state,
        to: ChapterMigration(chapter: next, text: text, pages: pages, offset: 0),
        loader: loader,
        progressStore: progressStore,
        cacheStore: cacheStore
    )
}

/// 跳章条的「上一章」：切到上一章**第 1 页**；**不要求当前在第一页**。
///
/// ⚠️ **刻意不是 `retreatToPreviousChapter`**：那个落到上一章**最后一页**（「章首退上一章」
/// 的语义）。跳章条按钮的语义必须与「完整加载」那条路落到**同一页**
/// （`loadChapterWithName` 就是 offset 0）—— 否则同一个按钮会因为「预加载有没有就绪」
/// 落到不同的页，那是 bug 而不是特性。
private func jumpToPreviousChapterStart(
    _ state: inout ReaderFeature.State,
    loader: ReaderLoader,
    progressStore: ReadingProgressStore,
    cacheStore: ChapterCacheStore
) -> Effect<ReaderFeature.Action> {
    guard !state.previousPages.isEmpty, let previous = state.previousChapter else { return .none }
    let text = state.previousText
    let pages = state.previousPages
    return migrateToChapter(
        &state,
        to: ChapterMigration(chapter: previous, text: text, pages: pages, offset: 0),
        loader: loader,
        progressStore: progressStore,
        cacheStore: cacheStore
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
/// 两处调用点（`ReaderFeature.swift` 的 `contentLoaded`、本文件的 `migrateToChapter`）
/// 都走这一条，顺序才只有一处定义（理由见文件头：`.merge` 的到达顺序没有保证，
/// 而 `TestStore` 按到达顺序收 action）。
/// ⚠️ 四个换章入口**共用** `migrateToChapter`，所以换章路径上这里只有**一处**调用 ——
/// 早先每个入口各调一次，改顺序就得改四遍。
func preloadAdjacentChapters(
    _ state: ReaderFeature.State,
    loader: ReaderLoader
) -> Effect<ReaderFeature.Action> {
    .concatenate(
        preloadNextChapter(state, loader: loader),
        preloadPreviousChapter(state, loader: loader)
    )
}

// MARK: - reducer 入口（放 extension：`type_body_length` 不计 extension）

extension ReaderFeature {
    /// 跳章条「上一章 / 下一章」按钮的 reducer 入口：**已就绪的相邻章 ⇒ 直接换章**
    /// （无 loading，与章尾左滑同一条路）；未就绪 ⇒ 回退 `loadChapterWithName` 完整加载
    /// （行为与改动前**完全一致**，含 loading）。
    ///
    /// ## 为什么不再让按钮直接发 `loadChapterWithName`（owner 真机反馈）
    /// 「现在阅读界面的预缓存不起效果，我直接点击下一章还是需要加载」——
    /// 相邻章其实早就预加载好了，只是按钮走的是**整章重新加载** ⇒ `isLoading` 转圈。
    ///
    /// ## 判据：路径对上 + 那一侧的 `*Pages` 非空
    /// 路径**必须**比对：`nextChapter` / `previousChapter` 是按当前 `chapterPath` 现算的
    /// 派生属性，不比对就会把「别处的章」当成邻居换过去（换错正文）。`*Pages` 非空
    /// = 预加载结果已收下且分页算出来了（读失败 / 分页为空都会被 reducer 丢掉，
    /// 那种情况这里自然判为「未就绪」）。
    ///
    /// ## 为什么不要求页位置
    /// 按钮在**任意页**都要能按 ⇒ 不像 `advanceToNextChapter` 那样 `guard` 最后一页
    /// （否则中间页按下去就是「点了没反应」）。两条路的落页口径**相同**（新章 `offset = 0`）
    /// ⇒ 就绪与否不影响落到哪一页。
    ///
    /// ## 为什么写成 extension 里的方法（而不是文件级函数）
    /// `ReaderFeature` 的类型体余量只剩个位数（`type_body_length` 250），而 **extension
    /// 不计入**该规则 ⇒ 判定逻辑放这里，reducer 里只留两行。依赖直接用本类型的
    /// `@Dependency` 属性：reducer 的 `body` 是**同步**调用它，依赖上下文与 `body` 内一致
    /// ⇒ 测试里的 `withDependencies` 照样生效（与 `body` 里直接读 `readerLoader` 等价）。
    func reduceJumpToAdjacentChapter(
        _ state: inout State,
        chapter: ChapterItem
    ) -> Effect<Action> {
        if state.nextChapter?.path == chapter.path, !state.nextPages.isEmpty {
            return jumpToNextChapterStart(
                &state,
                loader: readerLoader,
                progressStore: readingProgressStore,
                cacheStore: chapterCacheStore
            )
        }
        if state.previousChapter?.path == chapter.path, !state.previousPages.isEmpty {
            return jumpToPreviousChapterStart(
                &state,
                loader: readerLoader,
                progressStore: readingProgressStore,
                cacheStore: chapterCacheStore
            )
        }
        // 未就绪（还没预加载完 / 预加载失败 / 分页为空 / 目标不是相邻章）⇒ 完整加载兜底：
        // 按钮任何时候按下去都必须有反应。
        return .send(.loadChapterWithName(chapter.path, chapter.name))
    }
}
