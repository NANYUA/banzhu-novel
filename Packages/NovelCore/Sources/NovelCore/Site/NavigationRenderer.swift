import Foundation
import WebKit

/// 离屏渲染导航页（B0-6 Step 3）。
///
/// 有些导航页返回的只是一个 JS 加载器壳：真正的地址清单由脚本再发一跳请求、
/// 执行后才注入 DOM。这种页面用纯 `URLSession` + 正则**原理上**读不到，
/// 必须让网页引擎把脚本跑一遍。
///
/// - 完全离屏：`WKWebView` 不进任何视图层级、不上屏；
/// - 失败一律安静返回 nil（加载失败 / 超时 / 读不到 DOM），绝不抛错、绝不崩溃——
///   渲染只是纯 GET 之外的一次补充尝试，不能把整条拉取链拖死；
/// - 每次调用新建一个会话、用完即释放，不留常驻 WebView。
///
/// ⚠️ WebKit 是架构校验（`scripts/check-architecture.sh` 规则 1）对 Packages/ 的
/// 有意豁免项：它是网页引擎而不是 UI 框架。
enum NavigationRenderer {
    /// 渲染 `url` 并返回脚本跑完后的 `outerHTML`；拿不到返回 nil。
    @MainActor
    static func render(_ url: URL) async -> String? {
        await NavigationRenderSession().render(url)
    }
}

/// 一次渲染的会话：一个 URL 对应一个离屏 WebView，随 `render` 返回一起释放。
@MainActor
private final class NavigationRenderSession: NSObject, WKNavigationDelegate {
    /// `didFinish` 之后的轮询节奏（3 × 0.5s）：给第二跳 XHR 留出注入 DOM 的时间。
    private static let pollCount = 3
    private static let pollInterval = Duration.milliseconds(500)
    /// 等 `didFinish` 的上限；超时按「拿不到」处理，避免把拉取链挂死。
    private static let loadTimeout = Duration.seconds(10)
    /// 单次读 DOM 的上限：`evaluateJavaScript` 迟迟不回调时同样按「拿不到」处理。
    private static let snapshotTimeout = Duration.seconds(3)

    private let webView: WKWebView
    /// 等加载结束的等待者：didFinish / didFail / 超时三个出口共用，**只会 resume 一次**。
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private var loadTimeoutTask: Task<Void, Never>?
    /// 读 DOM 的等待者，同样是「先到先得、只 resume 一次」。
    private var snapshotWaiter: CheckedContinuation<String?, Never>?
    private var snapshotTimeoutTask: Task<Void, Never>?
    private var didFail = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        super.init()
        webView.navigationDelegate = self
    }

    func render(_ url: URL) async -> String? {
        webView.load(URLRequest(url: url))
        await waitForLoad()
        guard !didFail else { return nil }

        // 页面可能只是壳：didFinish 后再轮询几次，等地址清单被脚本注入 DOM
        // （与 didFinish 时的 DOM 相比出现变化即认为注入完成）。
        // 始终返回最后一次读到的 DOM，这样即便没等到，也能把「渲染后的字节数」
        // 交给引擎去报诊断；一次都没读到则返回 nil（引擎按纯 GET 的结果报错）。
        var baseline: String?
        var latest: String?
        for step in 0 ..< Self.pollCount {
            if step > 0 {
                try? await Task.sleep(for: Self.pollInterval)
            }
            guard let html = await snapshot(), !html.isEmpty else { continue }
            if let baseline, html != baseline {
                return html
            }
            baseline = baseline ?? html
            latest = html
        }
        return latest
    }

    /// 等 `didFinish`；加载失败或超时也照常返回（由 `didFail` 区分）。
    private func waitForLoad() async {
        await withCheckedContinuation { continuation in
            loadWaiter = continuation
            loadTimeoutTask = Task { @MainActor in
                try? await Task.sleep(for: Self.loadTimeout)
                self.resumeLoadWaiter()
            }
        }
    }

    private func resumeLoadWaiter() {
        guard let waiter = loadWaiter else { return }
        loadWaiter = nil
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        waiter.resume()
    }

    /// 读一次 DOM；`evaluateJavaScript` 不回调或报错都返回 nil。
    private func snapshot() async -> String? {
        await withCheckedContinuation { continuation in
            snapshotWaiter = continuation
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.finishSnapshot(result as? String)
                }
            }
            snapshotTimeoutTask = Task { @MainActor in
                try? await Task.sleep(for: Self.snapshotTimeout)
                self.finishSnapshot(nil)
            }
        }
    }

    private func finishSnapshot(_ html: String?) {
        guard let waiter = snapshotWaiter else { return }
        snapshotWaiter = nil
        snapshotTimeoutTask?.cancel()
        snapshotTimeoutTask = nil
        waiter.resume(returning: html)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation?) {
        resumeLoadWaiter()
    }

    func webView(
        _: WKWebView,
        didFail _: WKNavigation?,
        withError _: any Error
    ) {
        didFail = true
        resumeLoadWaiter()
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation?,
        withError _: any Error
    ) {
        didFail = true
        resumeLoadWaiter()
    }
}
