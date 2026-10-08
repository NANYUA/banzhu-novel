import Dependencies
import Foundation
import Network

/// 下载调度看到的网络类型。
public enum DownloadNetworkKind: Equatable, Sendable {
    /// App 尚未收到系统网络状态。
    case unknown
    /// 当前没有可用网络。
    case offline
    /// Wi-Fi。
    case wifi
    /// 蜂窝网络。
    case cellular
    /// 其它可用网络（有线、VPN 等）。
    case other
}

extension DownloadNetworkKind {
    /// 当前网络是否允许启动下一章下载。
    func permitsDownload(allowingCellular: Bool) -> Bool {
        switch self {
        case .wifi, .other:
            true
        case .cellular:
            allowingCellular
        case .unknown, .offline:
            false
        }
    }
}

/// 网络状态流依赖。
///
/// 下载服务测试只关心调度规则，默认给一个立即结束的空流，
/// 需要验证网络切换的测试再显式注入事件。
struct DownloadNetworkMonitor: Sendable {
    var updates: @Sendable () -> AsyncStream<DownloadNetworkKind>
}

extension DependencyValues {
    var downloadNetworkMonitor: DownloadNetworkMonitor {
        get { self[DownloadNetworkMonitorKey.self] }
        set { self[DownloadNetworkMonitorKey.self] = newValue }
    }

    private enum DownloadNetworkMonitorKey: DependencyKey {
        static let liveValue = DownloadNetworkMonitor(
            updates: { DownloadNetworkMonitorLive.updates() }
        )

        static let testValue = DownloadNetworkMonitor(
            updates: { AsyncStream { continuation in continuation.finish() } }
        )
    }
}

private enum DownloadNetworkMonitorLive {
    static func updates() -> AsyncStream<DownloadNetworkKind> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "NovelCore.DownloadNetworkMonitor")

            monitor.pathUpdateHandler = { path in
                continuation.yield(kind(for: path))
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: queue)
        }
    }

    private static func kind(for path: NWPath) -> DownloadNetworkKind {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) {
            return .wifi
        }
        if path.usesInterfaceType(.cellular) {
            return .cellular
        }
        return .other
    }
}
