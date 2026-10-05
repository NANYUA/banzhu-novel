import Foundation

/// 网络错误
public enum NetworkError: LocalizedError {
    case guarded          // 被人机验证盾拦截
    case badResponse
    case decodeFailed
    case transport(any Error)

    /// SwiftPM 拆包后：`LocalizedError` 的协议要求必须 public，否则外层包拿不到错误文案
    public var errorDescription: String? {
        switch self {
        case .guarded:      return "需要人机验证，请完成验证后重试。"
        case .badResponse:  return "服务器响应异常。"
        case .decodeFailed: return "内容解码失败。"
        case .transport(let e): return "网络错误：\(e.localizedDescription)"
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

    /// 带自动验证的请求：遇到验证页 → 自动处理一次 → 重试；仍失败才抛 .guarded。
    private func requestWithGuard(url: URL, body: String?) async throws -> String {
        do {
            return try await request(url: url, body: body)
        } catch let e as NetworkError {
            guard case .guarded = e else { throw e }
            // 自动处理验证（离屏 WKWebView 执行挑战脚本写 Cookie）
            let origin = (url.scheme.map { "\($0)://" } ?? "https://") + (url.host ?? "")
            let passed = await GuardResolver.shared.autoPass(urlString: origin + "/")
            if passed {
                // 验证后重试一次
                return try await request(url: url, body: body)
            }
            throw NetworkError.guarded
        }
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
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                    EngineLog.log(.error, tag, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) \(url.absoluteString)")
                    throw NetworkError.badResponse
                }
                let html = GBK.decode(data)
                if isGuarded(html) {
                    EngineLog.log(.warning, tag, "遇到盾（\(html.count) 字节）\(url.absoluteString)")
                    throw NetworkError.guarded
                }
                EngineLog.log(.info, tag, "HTTP \(http.statusCode) · \(html.count) 字节 · \(url.absoluteString)")
                return html
            } catch let e as NetworkError {
                if case .guarded = e { throw e }   // 盾不重试，直接上报让用户去过验证
                lastError = e
            } catch {
                lastError = NetworkError.transport(error)
            }
            if attempt < retries {
                EngineLog.log(.warning, "retry", "第 \(attempt + 1) 次失败，重试中… \(url.absoluteString)")
                try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1)))
            }
        }
        EngineLog.log(.error, "fail", "放弃：\((lastError as? LocalizedError)?.errorDescription ?? lastError.localizedDescription) \(url.absoluteString)")
        throw lastError
    }
}
