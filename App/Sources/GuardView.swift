import ComposableArchitecture
import NovelCore
import SwiftUI
import WebKit

/// 全局过验证覆盖层。
///
/// 自动验证阶段保留底层界面可见；手动验证阶段提供独立返回入口，
/// 不允许用户被困在阅读页或任意网络请求里。
struct GuardOverlayView: View {
    let store: StoreOf<GuardFeature>

    @StateObject private var manualController = ManualGuardWebController()

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            if let request = viewStore.request {
                ZStack {
                    if viewStore.phase == .autoPassing {
                        autoPassing(viewStore)
                    } else {
                        manualVerification(
                            request: request,
                            viewStore: viewStore
                        )
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func autoPassing(
        _ viewStore: ViewStore<GuardFeature.State, GuardFeature.Action>
    ) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在自动过验证…")
                    .font(.headline)
            }

            Text("界面会保留在当前页面，也可以立即改为手动验证。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("改为手动验证") {
                    viewStore.send(.switchToManual)
                }
                .buttonStyle(.borderedProminent)

                Button("取消", role: .cancel) {
                    viewStore.send(.cancelled)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
    }

    private func manualVerification(
        request: GuardRequest,
        viewStore: ViewStore<GuardFeature.State, GuardFeature.Action>
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("手动过验证")
                    .font(.headline)
                Spacer()
                Button("返回") {
                    viewStore.send(.cancelled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let message = viewStore.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            ManualGuardWebView(controller: manualController)

            HStack(spacing: 12) {
                Button("取消", role: .cancel) {
                    viewStore.send(.cancelled)
                }
                .buttonStyle(.bordered)

                Button("验证已完成") {
                    manualController.finish()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .background(.regularMaterial)
        .task(id: request.id) {
            manualController.onComplete = {
                viewStore.send(.manualCompleted)
            }
            manualController.load(request.siteURL)
        }
    }
}

private struct ManualGuardWebView: UIViewRepresentable {
    @ObservedObject var controller: ManualGuardWebController

    func makeUIView(context _: Context) -> WKWebView {
        controller.webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}
}

@MainActor
private final class ManualGuardWebController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    var onComplete: (() -> Void)?

    private var sawGuardPage = false
    private var didComplete = false

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

    func load(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        sawGuardPage = false
        didComplete = false
        webView.load(URLRequest(url: url))
    }

    func finish() {
        guard !didComplete else { return }
        didComplete = true
        Task {
            await syncCookies()
            onComplete?()
        }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                let html = result as? String ?? ""
                if Self.isGuardPage(html) {
                    self.sawGuardPage = true
                } else if self.sawGuardPage {
                    self.finish()
                }
            }
        }
    }

    private func syncCookies() async {
        let cookies = await webView.configuration.websiteDataStore
            .httpCookieStore
            .allCookiesAsync()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    private static func isGuardPage(_ html: String) -> Bool {
        html.contains("guard")
            || html.contains("slider_html")
            || html.contains("向右滑动")
            || html.contains("slide.js")
    }
}

private extension WKHTTPCookieStore {
    func allCookiesAsync() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
