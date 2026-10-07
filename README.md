# Cove

Cove 是可配置的 iOS 浏览与阅读应用，支持网页、SMB、本地文件、视频、音乐、漫画和电子书。

音频包含 `.opus`（Ogg Opus），支持 NAS 流式播放及本地/离线播放，沿用暂停、跳转和切曲控件。

首页提供快速访问、继续阅读、最近阅读、下载和稍后再看。站点保留图标、封面、分类、搜索、分页与选集；列表支持 Bento、竖版和导航样式。

## 构建

    cd EasyReader
    xcodegen generate
    open EasyReader.xcodeproj

需要 Xcode、XcodeGen，目标 iOS 26+，Swift 6 严格并发。依赖 AMSMB2、ZIPFoundation、Yams。

## 配置与数据

项目只维护当前一套配置格式：schemaVersion: 1。站点规则用 .site YAML，普通规则用 CSS，复杂规则用 JavaScript。

- [站点、收藏与备份格式](docs/site-format.md)
- [代码结构](docs/architecture.md)
- [审计修复与剩余工作](docs/review-status.md)
- [虚构站点示例](examples/sites/demo.site)
- [预置收藏示例](examples/data/favorites.json)

真实规则放 sites/，可选收藏预置放 data/favorites.json；两个目录和 config/ 被 Git 忽略。存在时本地打包自动加载，不存在也能构建。预置仅在首次初始化导入一次。

应用数据位于 Application Support/Cove/config 和 data。密码放 Keychain。修改架构和性能时保留现有界面与用户数据。

## 验证

    python3 scripts/test_export.py
    cd EasyReader
    xcodebuild -project EasyReader.xcodeproj -scheme EasyReader \
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

测试使用虚构配置和本地页面。真实站点、NAS 和真机性能需要实际环境验证。RAR/CBR 尚未包含实际解码器。仓库保持 Private。
