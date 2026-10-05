# 版主小说

iOS 单站点阅读器（`com.reader.bjvu`）—— 言璃版（mianmian111111.com 系，GBK + `_guard` 盾）。

## 构建要求

- Xcode 16.4+
- iOS 17.0+ SDK
- Swift 5.9

## 本地配置

1. 复制 `.env.example` → `.env`
2. 填入本地 secrets（见 `.env.example`）
3. `.env` 已在 `.gitignore`，不会提交

## 开发

```bash
# 架构校验
sh scripts/check-architecture.sh

# 生成 Xcode 工程
xcodegen generate

# 编译
xcodebuild -project BanzhuNovel.xcodeproj -scheme BanzhuNovel -destination 'generic/platform=iOS Simulator' build
```

## 文档

完整文档（需求、ADR、交接文档等）留在本地工作副本，不纳入公开仓库。

## License

MIT
