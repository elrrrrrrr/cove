# 截图来源

这三张 PNG 是实际应用截图，未经裁切或修改，由 `ArticleUITests/testHNListNativeBodyFavoriteHistoryAndOriginalPage` 生成。

- 环境：iPhone 17 Pro 模拟器，iOS 26.3.1，浅色主题。
- 构建：不含私有 `sites/`、`data/`、`config/` 的导出目录。
- 内容：`Cove/Tests/Fixtures/Articles/` 中的固定虚构资料，通过 localhost 提供。
- 配置：测试读取 `examples/sites/hacker-news.site`，将域名替换为 localhost。

`hn-original-article.png` 展示同一个解析 WebView 中的 HTML；`hn-native-list.png` 展示列表与下一页条目；`hn-native-article.png` 展示原生正文。截图中的标题、作者和图片均为演示素材，不是线上用户帖子。

## 网站与 NAS 展示

`website-bento.png`、`website-comic.png`、`nas-list.png` 和 `nas-bento.png` 来自 `ExampleShowcaseTests/testCaptureProductionWebsiteAndSMBShowcase`，截图未修改。

- iPhone 17 Pro 模拟器，iOS 26.3，浅色主题。
- 网站读取 `examples/sites/local-*.site`，使用 `scripts/serve-examples.py` 的 localhost 页面。
- NAS 读取 loopback 上的只读 SMB 共享 `CoveDemo`；文件来自 `examples/nas/files/`。
- 网站使用生产 `SiteGalleryView`，NAS 使用生产 `NASDirectoryContent` 与真实 SMB 缩略图请求。
- 标题、作者、封面、视频与阅读文件为公开演示内容；音频为已有公开 Opus 测试音。

`docs/brand/hero.png` 将原图排版进宣传图，版式由 `scripts/render-brand.mjs` 生成。设备外框是展示装饰，屏幕内容来自以上截图。

## Hacker News、Rust 与赵雷

`hacker-news.png`、`rust-reader.png`、`zhaolei-player.png` 来自 `ExampleShowcaseTests/testCaptureHackerNewsRustAndZhaoLei`，截图未修改：

- Hacker News 是 2026-10-14 公开首页的标题与元信息快照，使用现有 HN 配置经 localhost 解析。
- Rust 学习指南是实际打开的 Rust Book 简体中文版 EPUB，来自 MIT 许可的上游项目；正文未改写。
- 音乐播放器使用赵雷《成都》的官方公开试听流与《无法长大》真实封面，加载完成后暂停。仓库没有存放音乐音频。

完整来源与复现方法见 [展示素材](../../examples/showcase/README.md)。宣传图的三台设备分别展示这些实际屏幕，几何演示插画保留在本地配置教学样例中。
