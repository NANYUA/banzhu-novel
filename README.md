# iOS Novel Reader

A modular iOS reading app built with SwiftUI, SwiftData, and the Composable Architecture.

## Tech Stack

- **Language**: Swift 5.9
- **UI**: SwiftUI (iOS 17+)
- **Persistence**: SwiftData
- **State Management**: Composable Architecture (TCA)
- **Build**: XcodeGen + SPM
- **CI**: GitHub Actions

## Requirements

- Xcode 16.4+
- iOS 17.0+ SDK
- macOS 14+ (for CI)

## Quick Start

```bash
# Architecture check (runs locally without macOS)
sh scripts/check-architecture.sh

# Generate Xcode project
xcodegen generate

# Build
xcodebuild \
  -project BanzhuNovel.xcodeproj \
  -scheme BanzhuNovel \
  -destination 'generic/platform=iOS Simulator' \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  build
```

## Project Structure

```
App/Sources/              # SwiftUI app entry + views
Packages/NovelCore/       # Business logic, models, TCA features
Packages/NovelEngine/     # Network, parsing, site-specific logic
scripts/                  # Architecture constraints checker
```

## Architecture

- `NovelEngine`: Pure logic layer (no UI imports). Handles networking, HTML parsing, and content decoding.
- `NovelCore`: State management (TCA), persistence (SwiftData), and features.
- `App`: SwiftUI views only. No business logic.

Dependency direction: `App → NovelCore → NovelEngine` (strictly one-way).

## Testing

```bash
swift test --package-path Packages/NovelCore
swift test --package-path Packages/NovelEngine
```

## CI

Five gates on every push:
1. Architecture constraint check
2. SwiftFormat
3. SwiftLint strict
4. Xcode build (unsigned)
5. XCTest

## License

MIT

## 🚨 铁律：公开版零容忍

**公开版（GitHub）不允许包含任何敏感信息：**
- ❌ 站点域名、URL、标识
- ❌ 历史项目名称、关系
- ❌ API key、token、密码
- ❌ 个人路径、邮箱
- ❌ Bundle ID、应用名称（如有必要可保留）

**本地敏感信息管理：**
- 所有 secrets 写在 `.env`（已加入 `.gitignore`）
- 模板见 `.env.example`
- 完整文档（需求、ADR、交接）留在本地，不纳入公开版

**提交前自动检查：**
- pre-commit hook 自动扫描敏感词 + 硬编码 URL
- 发现敏感信息会阻止提交
