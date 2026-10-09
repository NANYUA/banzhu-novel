import Foundation

/// 网络错误
public enum NetworkError: LocalizedError {
    case guarded          // 被人机验证盾拦截
    case httpStatus(Int)  // 明确的 HTTP 错误状态（如 403）
    case badResponse

    /// 导航页拿到了，但一条候选 host 都没匹配到（带响应字节数）。
    ///
    /// 与 `.badResponse` 分开，是因为这两类原因的排查方向完全不同：
    /// `.badResponse` 是响应本身不合法，而这个是「页面合法但没有可用地址」
    /// （例如页面只是个 JS 加载器壳，真正清单要执行脚本后才出现）。
    case noCandidates(Int)

    case decodeFailed
    case transport(any Error)

    /// SwiftPM 拆包后：`LocalizedError` 的协议要求必须 public，否则外层包拿不到错误文案
    public var errorDescription: String? {
        switch self {
        case .guarded:            return "需要人机验证，请完成验证后重试。"
        case .httpStatus(let code): return "服务器返回错误（HTTP \(code)）。"
        case .badResponse:        return "服务器响应异常。"
        case .noCandidates(let bytes):
            return "已取回页面（\(bytes) 字节），但没匹配到任何候选地址。"
        case .decodeFailed:       return "内容解码失败。"
        case .transport(let e):   return "网络错误：\(e.localizedDescription)"
        }
    }

    /// 是否应让调用方再次重试。
    ///
    /// 盾与明确的 HTTP 状态错误都不重试：前者需要用户去处理验证，
    /// 后者是服务器已经给出决定（如 403），继续重试只会加剧风险。
    /// 解码失败属瞬时问题，交由上层重试。
    public var shouldRetry: Bool {
        switch self {
        case .guarded, .httpStatus, .noCandidates:
            return false
        case .badResponse, .decodeFailed:
            return true
        case let .transport(error):
            return Self.isTransientTransportError(error)
        }
    }

    /// 传输层错误是否值得重试（H4）。
    ///
    /// 原先 `.transport` **一律**重试：调用侧共 4 次尝试、退避 `1.5s × (attempt+1)`
    /// ≈ **9 秒**。但 DNS 解析不了、证书不受信、根本没联网这类错误
    /// **不可能因为再等 9 秒就自愈**，用户只是白等一场。
    ///
    /// 这里改成**白名单**：只有确实可能是瞬时抖动的错误才重试；未列出的
    /// （含非 `URLError` 的情形，例如任务取消产生的 `CancellationError`）一律不重试，
    /// 立刻把真实原因交给用户。
    private static func isTransientTransportError(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .resourceUnavailable:
            // 超时 / 连接中途断开 / 拒绝连接 / 资源暂不可用：换一次常能成功。
            return true
        default:
            return false
        }
    }

    /// 是否需要由上层弹出人机验证界面。
    public var isGuardRequired: Bool {
        if case .guarded = self {
            return true
        }
        return false
    }

    /// 是否属于当前 host 不可用，可尝试切换到下一个 host。
    public var isHostUnavailable: Bool {
        switch self {
        case .guarded, .decodeFailed, .noCandidates:
            return false
        case .httpStatus, .badResponse, .transport:
            return true
        }
    }
}

/// 网络客户端：GBK 编解码、移动 UA、Cookie 复用、GET/POST、重试退避、人机验证检测。
actor NetworkClient {
    static let shared = NetworkClient()

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared   // 与 WKWebView 验证后共享 Cookie
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    /// 检测是否被人机验证页面拦截
    private func isGuarded(_ html: String) -> Bool {
        return html.contains("guard") || html.contains("slider_html") || html.count < 200
    }

    /// GET 一个页面，返回 GBK 解码后的 HTML
    func get(_ url: URL) async throws -> String {
        try await requestWithGuard(url: url, body: nil)
    }

    /// POST 搜索：body 为已 GBK 百分号编码的字符串
    func post(_ url: URL, bodyString: String) async throws -> String {
        try await requestWithGuard(url: url, body: bodyString)
    }

    /// 请求入口。遇盾时只上报，由上层统一决定是否进入全局验证流程。
    private func requestWithGuard(url: URL, body: String?) async throws -> String {
        try await request(url: url, body: body)
    }

    private func request(url: URL, body: String?, retries: Int = 3) async throws -> String {
        var lastError: Error = NetworkError.badResponse
        for attempt in 0...retries {
            do {
                var req = URLRequest(url: url)
                req.setValue(SiteConfig.userAgent, forHTTPHeaderField: "User-Agent")
                // 注意：不要手动设置 Accept-Encoding: gzip。
                // URLSession 只有在"你没设该头"时才会自动解压 gzip；
                // 一旦手动设置，它会把原始 gzip 字节交给你（GBK 解码即乱码）。
                if let scheme = url.scheme, let host = url.host {
                    req.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
                }
                if let body = body {
                    req.httpMethod = "POST"
                    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    // body 已是 GBK 百分号编码的 ASCII 串
                    req.httpBody = body.data(using: .ascii)
                }
                let tag = body == nil ? "GET" : "POST"
                EngineLog.log(.info, tag, "\(url.absoluteString)\(body.map { " body=\($0)" } ?? "")")
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    EngineLog.log(.error, tag, "非 HTTP 响应 \(url.absoluteString)")
                    throw NetworkError.badResponse
                }
                guard (200..<400).contains(http.statusCode) else {
                    EngineLog.log(.error, tag, "HTTP \(http.statusCode) \(url.absoluteString)")
                    throw NetworkError.httpStatus(http.statusCode)
                }
                let html = GBK.decode(data)
                if isGuarded(html) {
                    EngineLog.log(.warning, tag, "遇到盾（\(html.count) 字节）\(url.absoluteString)")
                    throw NetworkError.guarded
                }
                EngineLog.log(.info, tag, "HTTP \(http.statusCode) · \(html.count) 字节 · \(url.absoluteString)")
                return html
            } catch {
                // H4 收尾：把「错误收枘」与「是否重试」合并成**唯一**决策点。
                //
                // 原先这里是两个 catch：只有 `catch let e as NetworkError` 会查 `shouldRetry`，
                // 而通用 catch 只是 `lastError = .transport(error)` —— 收枘完**直接进退避休眠，
                // 从不查 shouldRetry**。偏偏 `URLSession` 抛的是 `URLError`（不是 `NetworkError`），
                // 必然走通用分支，于是 `shouldRetry` 里对 `.transport` 的分类**在运行时从未被调用**，
                // DNS 查不到 / 证书不受信 / 压根没网照样白等约 9 秒。
                // 现在两条路径合一：先收枘，再问一次 shouldRetry。
                let wrapped = Self.wrap(error)
                if !wrapped.shouldRetry { throw wrapped }
                lastError = wrapped
            }
            if attempt < retries {
                EngineLog.log(.warning, "retry", "第 \(attempt + 1) 次失败，重试中… \(url.absoluteString)")
                try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1)))
            }
        }
        EngineLog.log(.error, "fail", "放弃：\((lastError as? LocalizedError)?.errorDescription ?? lastError.localizedDescription) \(url.absoluteString)")
        throw lastError
    }

    /// 把任意抛出的错误收枘成 `NetworkError` —— 重试循环与单测**共用**的唯一入口（H4 收尾）。
    ///
    /// 抽出来的理由：循环本身依赖真实 `URLSession`，在 `swift test` 里注入不了。
    /// 于是「`shouldRetry` 的分类改对了，但循环压根没查它」这种错位，
    /// 只有靠单测直接盯住这个入口才防得住 —— 这正是 H4 第一次改歪的方式。
    static func wrap(_ error: any Error) -> NetworkError {
        (error as? NetworkError) ?? .transport(error)
    }
}

protocol NetworkTransport: Sendable {
    func get(_ url: URL) async throws -> String
    func post(_ url: URL, bodyString: String) async throws -> String
}

extension NetworkClient: NetworkTransport {}
