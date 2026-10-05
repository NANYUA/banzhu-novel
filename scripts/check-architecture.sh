#!/usr/bin/env bash
#
# 架构约束校验（ADR-012 / D12 CI 第 5 道关卡）
#
# 为什么需要它：SwiftPM 的 `dependencies: []` 只能保证**包与包之间**的依赖方向
# （Engine 引用 Core 会编译失败），但**无法禁止引擎层 import 系统 UI 框架**——
# `import SwiftUI` / `import UIKit` 在任何包里都能编译。
# 所以「引擎不许碰 UI」这条规矩必须靠本脚本拦。
#
# 违反即 exit 1 → CI 失败 → 发不出包。这就是「约束是强制的」的实际含义。
#
# ⚠️ 两条踩坑教训（都真实发生过，勿改回）：
#  1. 不要用 `grep --include` —— BusyBox grep 不支持，会静默报错造成假失败/假通过。
#  2. 不要把 `find -exec ... +` 放进 shell 函数再调用 —— BusyBox sh 下会
#     把文件清单当匹配结果输出，导致「所有文件都被标红」。

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

# ── 规则 1：Packages/ 内禁止引用 UI 框架 ─────────────────────────────
# 注：WebKit **不在禁列** —— GuardResolver 需要 WKWebView 跑盾页挑战脚本，
#     WebKit 是网页引擎而非 UI 框架，属有意豁免。
echo "▸ 规则 1：Packages/ 禁止 import SwiftUI / UIKit（WebKit 有意豁免）"
h=$(find Packages -name "*.swift" ! -name "Package.swift" -type f \
  -exec grep -HnE "^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(SwiftUI|UIKit|AppKit)\b" {} + 2>/dev/null || true)
if [ -n "$h" ]; then
  echo "$h" | sed 's/^/  ❌ /'
  echo "     Packages/ 是纯逻辑层，不得依赖 UI"
  fail=1
else
  echo "  ✅ 通过"
fi

# ── 规则 2：Engine 不得依赖 Core（只看依赖声明，不看注释）──────────────
echo "▸ 规则 2：NovelEngine 不得依赖 NovelCore"
# 先去掉注释行，再全文搜 NovelCore —— 只匹配行首 .package( 会漏掉
# 写在 dependencies: [...] 数组里的依赖
h=$(grep -vE "^[[:space:]]*//" Packages/NovelEngine/Package.swift 2>/dev/null | grep "NovelCore" || true)
if [ -n "$h" ]; then
  echo "  ❌ 违反：依赖方向必须是 NovelCore → NovelEngine"
  fail=1
else
  echo "  ✅ 通过"
fi

# ── 规则 3：Core 不得依赖除 Engine 外的本地包 ─────────────────────────
# 注：**只拦本地包（.package(path:)），不拦远程三方包（.package(url:)）**——
#     TCA（D2 决策）就是远程三方包，规则 3 必须放行它。
#     真正要防的是「Core 又引了一个新的本地包」，那会绕过 D1 的分层设计。
echo "▸ 规则 3：NovelCore 不得依赖除 NovelEngine 外的本地包（远程三方包如 TCA 允许）"
# 只认包级依赖 .package(path: "...")；target 里的 path: "Sources/..." 不是包依赖
h=$(grep -vE "^[[:space:]]*//" Packages/NovelCore/Package.swift 2>/dev/null \
    | grep -E '\.package\(path:' | grep -v "NovelEngine" || true)
if [ -n "$h" ]; then
  echo "  ❌ 违反：Core 只能向下依赖 Engine"
  echo "$h" | sed 's/^/     /'
  fail=1
else
  echo "  ✅ 通过"
fi

# ── 规则 4：Engine 层不得使用状态管理框架（D2 已定 TCA）──────────────
echo "▸ 规则 4：Engine 不得使用 ObservableObject / @Published（D2 已定 TCA）"
# 先排除注释行（// 开头），否则文档里提到这些词会被误报
h=$(find Packages/NovelEngine -name "*.swift" -type f \
  -exec grep -HnE "\bObservableObject\b|@Published" {} + 2>/dev/null | grep -vE ":[0-9]+:[[:space:]]*//" || true)
if [ -n "$h" ]; then
  echo "$h" | sed 's/^/  ❌ /'
  echo "     状态管理归 Core 层（TCA）"
  fail=1
else
  echo "  ✅ 通过"
fi

# ── 规则 5：Packages/ 不得出现 App 入口 ──────────────────────────────
echo "▸ 规则 5：Packages/ 不得出现 @main"
h=$(find Packages -name "*.swift" ! -name "Package.swift" -type f \
  -exec grep -HnE "^[[:space:]]*@main\b" {} + 2>/dev/null)
if [ -n "$h" ]; then
  echo "$h" | sed 's/^/  ❌ /'
  fail=1
else
  echo "  ✅ 通过"
fi

echo ""
if [ "$fail" -ne 0 ]; then
  echo "🚫 架构约束校验未通过"
  exit 1
fi
echo "✅ 架构约束校验全部通过"