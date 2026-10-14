# 用实例认识 Cove

这些配置可以导入 Cove，不自动预置进 App。四套本地网站使用固定虚构内容；公开内容展示使用 Hacker News、Rust Book 简体中文版与赵雷试听，见 [素材说明](showcase/README.md)。本地真实站点规则仍留在 Git 忽略的根目录 `sites/`。

| 示例 | 用到的能力 | 配置 |
| --- | --- | --- |
| 山海影库 | 视频、Bento、分类、搜索、分页、播放地址 | [local-video.site](sites/local-video.site) |
| 漫游书架 | 竖版封面、漫画详情、章节与图片 | [local-comic.site](sites/local-comic.site) |
| 沿途手记 | 列表、原生图文、图片、链接、收藏与进度 | [local-journal.site](sites/local-journal.site) |
| 资源导航 | 目录列表 → 子列表 → 视频详情 | [local-directory.site](sites/local-directory.site) |
| Hacker News | 公开站点、JS 组合列表、CSS 正文、下一页 | [hacker-news.site](sites/hacker-news.site) |
| Rust 学习指南 | Rust Book 简体中文版与 EPUB 阅读 | [阅读文件](nas/files/Rust%20学习指南.epub) |
| 赵雷 · 成都 | 真实专辑封面、元数据与公开试听 | [来源与复现](showcase/README.md) |
| NAS 资料库 | SMB 文件、列表/Bento/竖版、阅读与播放 | [NAS 示例](nas/README.md) |

## 启动本地网站

```sh
python3 scripts/serve-examples.py
```

打开 `http://127.0.0.1:8765/` 查看原始网站。在模拟器中的 Cove 导入 `examples/sites/local-*.site`，打开入口查看同一内容的原生界面。

这四个配置保留 `schemaVersion: 1`，使用 CSS 为主；Hacker News 演示复杂页面用 JavaScript 的方式。结构来自本地站点适配时遇到的常见场景，域名、页面内容与选择器重新编写为可公开的示例，不复制私有规则。

模拟器可以直接访问 Mac 的 loopback 服务。真机请在受信任的局域网启动 `python3 scripts/serve-examples.py --host 0.0.0.0`，再将配置的 `127.0.0.1` 和入口地址改为 Mac 的局域网地址；内容链接使用相对路径。无需把真实网站或账户交给演示服务器。

## 素材与验证

`local-demo/assets/` 的 SVG 是可编辑的原创矢量封面，PNG 用于实际缩略图；`demo.mp4` 是原创 6 秒动画。`local-demo/pages/` 是由同一个演示服务生成的离线 HTML，单测直接用公开配置验证列表、搜索、分页、漫画章节与图文内容。

`nas/files/` 提供同类可打开资源。音频使用现有公开 Opus 测试音。示例不包含 RAR 解码或 X 适配，不代表任意站点可自动读取。
