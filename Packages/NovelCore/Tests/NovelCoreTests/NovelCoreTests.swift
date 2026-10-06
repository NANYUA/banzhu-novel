@testable import NovelCore
import XCTest

/// Core 层测试骨架（D11 已定：XCTest）。
/// 目的是**验证测试真的挂上了 CI**，而不是空跑。
final class NovelCoreTests: XCTestCase {
    /// 连通性冒烟测试：Core 能拿到 Engine 的东西 → 说明三层依赖方向配对了
    func testCoreCanReachEngine() {
        let probe = NovelCore.engineProbe()
        XCTAssertTrue(probe.hasPrefix("site="), "探针应返回 host，实际：\(probe)")
    }
}
