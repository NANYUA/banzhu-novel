import Foundation
import NovelEngine

/// 核心层占位：状态管理（TCA）、存储（SwiftData）、下载队列等都将落在这里。
///
/// 依赖方向：`App → NovelCore → NovelEngine`，**绝不可反向**。
/// `import NovelEngine` 能编译通过；反过来（Engine 引 Core）会直接编译失败。
public enum NovelCore {
    /// 便于确认 App ↔ Core ↔ Engine 三层确实连通
    public static func engineProbe() -> String {
        "site=\(SiteConfig.default.host)"
    }
}
