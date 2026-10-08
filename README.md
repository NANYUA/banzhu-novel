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

`package-unsigned` does not run on push. It is manual-only:
run the `CI` workflow with `workflow_dispatch` and set `run_package=true`.

## License

MIT
