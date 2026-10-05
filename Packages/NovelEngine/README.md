# NovelEngine · 只读快照（⚠️ 尚未正式移植）

> **状态：冻结的参考副本，不是正式移植。**
> 本目录用于「先保住最干净的资产」，正式移植在 D1~D15 全部决策完成后进行。

---

## 这是什么

从旧项目 `小说阅读App_项目报告` 的 `ios/Sources/Engine/` 原样复制而来。

| 项 | 值 |
|---|---|
| 文件数 | 7 |
| 行数 | **884**（与源**逐行一致**，未做任何修改）|
| 复制时间 | 2026-10-05 |
| 源版本 | original project v1.26.8 |

## 为什么冻结它

旧项目在**动 UI 层**（抽屉交互打了 8 个版本），但**引擎层一直是干净且已验证的**。
现在冻结，是为了防止「等决策做完再搬」的这段时间里引擎被 UI 的临时需求污染。

**引擎是纯逻辑、零 UI 依赖，是整个 App 最值钱的资产。**

---

## 资产清单与价值

| 文件 | 行数 | 作用 | 价值 |
|---|---|---|---|
| `ContentDecoder.swift` | 292 | 正文解码（图片映射表还原、净化、排版）| 🔴 **最高**——最脏最难的活，全在这 |
| `HTMLParser.swift` | 162 | HTML 解析 | 🔴 高 |
| `GuardResolver.swift` | 144 | 自动过盾（离屏 WKWebView 跑挑战脚本）| 🟡 中——能过盾但有设计问题，见下 |
| `NetworkClient.swift` | 113 | 网络层（GBK 解码、POST、Cookie、域名切换）| 🔴 高 |
| `NovelEngine.swift` | 100 | 对外 API：search / bookInfo / toc / content | 🔴 高（对外接口契约）|
| `SiteConfig.swift` | 46 | 域名配置 | 🟢 低 |
| `GBK.swift` | 27 | GBK 编码 | 🟡 低——但踩过坑，别手写 |

---

## ⚠️ 冻结时发现的两个问题（正式移植时必须处理）

### 问题 1：`GuardState` 是状态对象，却待在引擎层 ❌ 跨层污染

```swift
// GuardResolver.swift 里
@MainActor
final class GuardState: ObservableObject {
    @Published var showManual = false      // ← UI 语义（要不要弹手动验证页）
    @Published var autoPassing = false
    @Published var reloadToken = 0         // ← UI 语义（通知界面重载）
}
```

**问题**：引擎层不该知道「界面要不要弹窗」「界面要不要重载」。这是**UI 的语义漏进了引擎**。

**新项目的处理方向**（D1 边界拆分时定）：
- 引擎只负责「过盾成功与否」→ 返回一个**结果**
- 「要不要弹手动验证页」「界面何时重载」→ 归 `NovelCore` 的 TCA 状态层

### 问题 2：引擎层用了 `ObservableObject` / `@Published`

新项目已定 **TCA**，引擎层不应引入任何状态管理框架。

**处理方向**：引擎层改用**纯返回值 + async/回调**，不做任何状态广播。

---

## 正式移植时要确认的事项

- [ ] 移除 `GuardState`，改为引擎返回结果 + Core 层管理状态
- [ ] 清掉所有 `ObservableObject` / `@Published` / `import Combine`
- [ ] 核对是否还有隐式全局单例（`static let shared`）需要改为依赖注入
- [ ] 补单元测试（**旧项目完全没有测试，这是新项目要补的硬指标**）
- [ ] 逐个函数核对注释里的「已验证」结论是否仍然成立

---

## 🔒 边界规则（由 Package.swift 强制，非文档约定）

```
App  →  NovelCore  →  NovelEngine
         ↑                ↑
         └──── 禁止 ───────┘
```

`NovelEngine` 的 `dependencies: []` 是**空的**，编译器会强制它无法引用上层。
想依赖 `NovelCore` 或 UI → **直接编译失败**。

> 这就是新项目原则 #1「依赖方向不可逆」的第一处落地：**不靠自觉，靠编译器。**