import Foundation

/// 重试循环本体：与具体传输**解耦**，便于用假传输驱动测试。
///
/// 单独抽出来的唯一理由就是「可测」—— 循环依赖真实 `URLSession` 时，
/// 「`shouldRetry` 的分类改对了、但循环压根没查它」这种错位无法被任何测试发现
/// （这正是本仓库真实踩过一次的坑：通用 `catch` 把 `URLError` 收枘成 `.transport` 后
/// 直接去休眠，`shouldRetry` 在运行时从未被调用，DNS 查不到照样白等约 9 秒）。
enum RetryLoop {
    /// 跑完整个重试循环。
    ///
    /// - Parameters:
    ///   - retries: 额外重试次数（总尝试次数 = retries + 1）。
    ///   - logContext: 日志里的请求上下文（调用方传 `url.absoluteString`）。
    ///     循环拿不到 `url`，所以由调用方给；它只影响日志，不参与任何判定。
    ///   - sleep: 退避等待。注入以便测试不真等约 9 秒。
    ///   - perform: 第 `attempt` 次尝试（从 0 开始）。
    static func run<T: Sendable>(
        retries: Int = 3,
        logContext: String = "",
        sleep: @Sendable (UInt64) async -> Void,
        perform: @Sendable (Int) async throws -> T
    ) async throws -> T {
        // 不预设「默认错误」：循环体每个 catch 都会覆写它，所以这里只需要「有没有失败过」。
        var lastError: Error?
        for attempt in 0...retries {
            do {
                return try await perform(attempt)
            } catch {
                // H4 收尾：把「错误收枘」与「是否重试」合并成**唯一**决策点。
                //
                // 原先这里是两个 catch：只有 `catch let e as NetworkError` 会查 `shouldRetry`，
                // 而通用 catch 只是 `lastError = .transport(error)` —— 收枘完**直接进退避休眠，
                // 从不查 shouldRetry**。偏偏 `URLSession` 抛的是 `URLError`（不是 `NetworkError`），
                // 必然走通用分支，于是 `shouldRetry` 里对 `.transport` 的分类**在运行时从未被调用**，
                // DNS 查不到 / 证书不受信 / 压根没网照样白等约 9 秒。
                // 现在两条路径合一：先收枘，再问一次 shouldRetry。
                let wrapped = NetworkClient.wrap(error)
                if !wrapped.shouldRetry { throw wrapped }
                lastError = wrapped
            }
            if attempt < retries {
                EngineLog.log(.warning, "retry", "第 \(attempt + 1) 次失败，重试中… \(logContext)")
                await sleep(UInt64(1_500_000_000 * (attempt + 1)))
            }
        }
        // 走到这里必然失败过（成功即 return，不重试即 throw）；`??` 只是给类型收口。
        let failure: any Error = lastError ?? NetworkError.nonHTTPResponse(logContext)
        EngineLog.log(.error, "fail", "放弃：\((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription) \(logContext)")
        throw failure
    }
}
