import Foundation
import os

/// 引擎层日志出口。
///
/// ## 为什么不用 App 的 DebugLog
/// 引擎是纯逻辑层，**不能依赖 App 的调试设施**（那属于 Core/UI 层）。
/// 旧项目的 `NetworkClient` 直接调 `DebugLog.shared.log(...)`，
/// 而 `DebugLog` 在 Store/ 下、不在引擎包内 —— 拆包后无法编译。
///
/// ## 设计
/// - 基于系统 `os.Logger`，**零第三方依赖**
/// - 不使用 `print`：D10 已禁用 `print`，且 `print` 会把调试输出混进正式版
/// - 后续 Core 层若要做「全量日志收集/导出」，可在此加一个 hook 转发到自己的日志系统
public enum EngineLog {

    private static let logger = Logger(subsystem: "com.example.novelreader", category: "Engine")

    public enum Level: String {
        case info, warning, error
    }

    /// 记录一条引擎日志
    public static func log(_ level: Level, _ tag: String, _ message: String) {
        logger.log(level: level.osType, "\(tag, privacy: .public): \(message, privacy: .public)")
    }
}

private extension EngineLog.Level {
    var osType: OSLogType {
        switch self {
        case .info:    return .info
        case .warning: return .default
        case .error:   return .error
        }
    }
}
