# 2026-11-20 修复验证与 IPA 交付记录

## 基线与分支
- 发布基线：`v1.0`，提交 `f2b5a82`。
- 修复分支：`fix/catalog-reader-ui`。
- 最终提交：`fdb3d403165cb48b076a048f58de2f28476a7b89`。
- 未修改远端 `main`（仍 `c11af05`），未改写发布标签；修复只在独立分支。

## CI
- Workflow run：[44582493034](https://github.com/NANYUA/banzhu-novel/actions/runs/44582493034)
- 编译 / 测试 / Lint / 架构检查：success。
- 未签名 IPA 打包：success。
- runner 最终使用 `macos-15-intel`。最初 `macos-15` 因 macOS ARM 容量未分配导致取消；切换官方标准标签后完成。
- IPA 是未签名产物，需要签名后才能安装。

## 产物
- Artifact：`BanzhuNovel-unsigned-fdb3d403165cb48b076a048f58de2f28476a7b89`（GitHub artifact 下载保留 7 天）。
- 本地：`/var/minis/workspace/novel-reader-release-package-20261120/BanzhuNovel-unsigned.ipa`。
- IPA SHA-256：`7e23152bfb8aabeed56429009a0ed72cf848458de110efe2665daae344473208`。
- 已从 IPA 核对主 App `Payload/BanzhuNovel.app/Info.plist`，Bundle ID `com.example.novelreader.BanzhuNovel`，版本 `1.0`，Build `1`，Display Name `BanXS`。

## 修复范围概述
- 目录抓取完整分页、排除最新栏、保持原章节编号；详情页可刷新旧书目录，成功后更新当前 Reader 的章节目录与相邻章预加载。
- 保存失败恢复目录与书籍元数据原值；分页编号/路径冲突拒绝静默覆盖。
- 翻页跟手更新跳过重复正文归一化与切片；保留既有动画。
- 分类浮层可上滑收起；悬浮栏底缘渐变材质过渡。

## 限制
CI 验证不等于真机体验验收。需实机验证翻页帧率、分类手势/滚动续用、模糊过渡与可访问性。IPA 未签名，不是安装包成品。
