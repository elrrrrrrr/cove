# 展示真实的阅读与音乐场景

README 首屏的三张屏幕都是运行 Cove 后拍摄的实际界面。私有站点规则和个人资料没有进入展示。

| 场景 | 内容与来源 | 如何复现 |
| --- | --- | --- |
| Hacker News | [公开首页](https://news.ycombinator.com/)于 2026-10-14 的前十二条标题和元信息，保存为 `hacker-news.html`。不含文章正文。 | 导入 [hacker-news.site](../sites/hacker-news.site)访问线上站点；拍摄测试将同一规则指向 localhost 快照。 |
| Rust 学习指南 | [Rust 程序设计语言简体中文版](https://github.com/KaiserY/trpl-zh-cn)提供的真实 EPUB，MIT 许可。上游版本与 SHA-256 固定在 `rust-book-source.json`，许可全文在 `rust-book-LICENSE`。文件没有改写正文。 | 打开 [EPUB](../nas/files/Rust%20学习指南.epub)；固定版本的下载脚本在 `scripts/make-reading-example.py`。 |
| 赵雷 · 成都 | [Apple Music 的《无法长大》](https://music.apple.com/us/album/无法长大/1722409813)与[《成都》](https://music.apple.com/us/album/成都/1722409813?i=1722409913)。封面、曲目与试听地址来自公开 [iTunes 目录](https://itunes.apple.com/lookup?id=1722409813&entity=song&country=us)。 | 拍摄测试将公开试听流交给实际 `AudioPlayerManager`，元信息通过 `AVPlayerItem.externalMetadata` 提供，加载完成后暂停拍摄。 |

`zhaolei.json` 保存来源、曲目信息与公开试听 URL；`zhaolei-cover.jpg` 是该专辑的公开封面。封面与音乐权利归原权利人；仓库不包含歌曲音频文件。试听服务的可达性取决于网络和服务方，普通单测不依赖它。

## 重新拍摄

启动 [本地 HTTP/SMB 演示](../nas/README.md)，设置测试环境变量 `COVE_CAPTURE_SHOWCASE=1`，运行 `ExampleShowcaseTests`。真实内容拍摄的测试名是 `testCaptureHackerNewsRustAndZhaoLei`，需要网络访问公开试听。测试附件保存 `hacker-news`、`rust-reader` 和 `zhaolei-player` 三张截图。

Hacker News 的配置、Rust 的内容和赵雷的资料都位于示例目录，应用代码没有写入这些品牌或站点名称。音乐播放器通用地读取标题、艺术家、专辑和封面；没有元信息的文件继续显示文件名和波形图。
