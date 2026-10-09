import ComposableArchitecture
import NovelCore
import SwiftUI
import WebKit

/// 验证弹窗（iOS 18 基线）。无自动流程：弹出后由用户手动完成或取消。
struct GuardOverlayView: View {
    let store: StoreOf<GuardFeature>

    @StateObject private var manualController = ManualGuardWebController()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            if let request = viewStore.request {
                manualVerification(
                    request: request,
                    viewStore: viewStore
                )
            }
        }
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
                Button {
                    viewStore.send(.cancelled)
                } label: {
                    Text("返回")
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
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
                .controlSize(.large)

                Button("验证已完成") {
                    manualController.finish()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(16)
        }
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
        }
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
