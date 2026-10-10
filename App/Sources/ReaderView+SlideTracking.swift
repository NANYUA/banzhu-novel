import SwiftUI

/// 滑动翻页「从当前显示位置继续跟手」（方案 A）所需的**呈现值回报**。
///
/// ## 要修的问题
/// `DragGesture.translation.width` 是**相对本次手势起点**的，而 `slideOffset` 是
/// **相对页面静止位置**的。吸附回位动画（0.22s 缓动）跑到一半再抓手势时，页面此刻
/// 显示在（比如）35pt 处，新手势的 translation 从 0 起 —— 照旧写
/// `slideOffset = translation`，画面就会从 35pt 瞬间跳到 10pt。
///
/// ## 怎么拿到「动画进行中的呈现值」
/// `slideOffset` 是 `@State`：`withAnimation { slideOffset = 0 }` 一执行，
/// **state 就已经是 0**，被插值的是**呈现值** —— SwiftUI 不把它交给 View。
/// 于是让**被动画的那一层自己回报**：`SlidePresentationReporter` 是个
/// `AnimatableModifier`，SwiftUI 每帧把插值结果写进它的 `animatableData`，
/// setter 顺手记进 `SlidePresentation`。抓取瞬间读盒子 = 页面当时真实显示的偏移
/// （最多差一帧，肉眼不可见），基线因此永远等于「当前显示位置」。
/// 纯数学交给 `SlideTracking`（NovelCore，CI 可测）。
///
/// ## 为什么是普通 class，不是 `@State` / `@Binding`
/// `animatableData` 的 setter 是在**视图更新期间**被调用的：往 `@State` 写会踩
/// 「Modifying state during view update」，而且会反过来触发一轮渲染，跟正在跑的
/// 动画互相打扰。写一个普通对象既不触发重渲染、也不打断动画；View 只在手势回调里
/// **读**它（不参与 body 求值），因此不构成反馈环。
///
/// ⚠️ 持有它的 `ReaderView.slidePresentation` 必须是 `@State`，不能写成 `let`：
/// View 结构体每次重新求值都会重建 `let` 属性，手势闭包与探针就会各拿一个盒子。
///
/// 注：本文件没有 `extension ReaderView` —— 它要接的 `slideOffset` /
/// `slidePresentation` 是 `ReaderView.swift` 里的 `@State`（extension 加不了存储属性），
/// 所以这里只放「回报机制」，接线的那两行在 `ReaderView.slideGesture`。
final class SlidePresentation {
    /// 页面此刻显示在的横向偏移；吸附回位动画进行中即插值中的呈现值。
    var offset: CGFloat = 0
}

/// 呈现值探针：自己**不可见、不参与命中测试**，只负责把每帧的呈现值回报出去。
///
/// 页面真正被平移仍然是 `ReaderView` 里原来那行 `.offset(x: slideOffset)` ——
/// 探针不参与渲染。这是刻意的：回报这条路万一不灵（例如某代 SwiftUI 不再回调
/// `animatableData` 的 setter），最坏结果只是**退回改动前的行为**，
/// 而不会把 owner 已验收的吸附回位动画弄坏。
struct SlidePresentationProbe: View {
    /// 目标偏移（与 `ReaderView.slideOffset` 同源）。
    let offset: CGFloat
    /// 呈现值的存放处。
    let presentation: SlidePresentation

    var body: some View {
        Color.clear
            .modifier(SlidePresentationReporter(offset: offset, presentation: presentation))
            .allowsHitTesting(false)
    }
}

/// 施加偏移并把每帧插值出的**呈现值**回报给 `presentation`。
struct SlidePresentationReporter: AnimatableModifier {
    /// 目标偏移；动画期间会被 SwiftUI 改写成插值中的呈现值。
    var offset: CGFloat
    /// 引用类型：修饰器每帧的临时副本共享同一个盒子。
    let presentation: SlidePresentation

    var animatableData: CGFloat {
        get { offset }
        set {
            offset = newValue
            presentation.offset = newValue
        }
    }

    func body(content: Content) -> some View {
        content.offset(x: offset)
    }
}
