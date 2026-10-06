# Cove

Cove 是可配置的 iOS 资源浏览与阅读应用。来源包括本地文件夹、SMB 和网页；统一浏览、搜索、收藏、历史以及内容打开方式。

当前重构使用全新 .site v2 和新资料库，不兼容旧配置与旧数据结构。GitHub 仓库保持 Private。

## 构建

需要 Xcode、XcodeGen，目标 iOS 26+、Swift 6 严格并发。

    cd EasyReader
    xcodegen generate
    open EasyReader.xcodeproj

新增、删除、移动 Swift 文件后必须重新生成工程。依赖：AMSMB2、ZIPFoundation、Yams。

## 配置

从“资源”添加来源，选择本地文件夹、SMB 或网站。网站支持 CSS 字段点选、内容预览、分页/搜索测试和 YAML/异步 JavaScript 编辑。

- [配置格式与例子](docs/site-format-v2.md)
- [资源架构及 review 修订](docs/architecture.md)
- [测试、性能证据和界面截图](docs/validation.md)
- [虚构网页示例](examples/sites/demo.site)
- [本地来源示例](examples/sites/files.site)
- [SMB 示例](examples/sites/smb.site)

真实规则放根目录 sites/，可选预置收藏放 data/favorites.json；两个目录及 config/ 均被 Git 忽略。没有这些目录也能正常构建。构建资源只在首次初始化导入一次。

本地配置与资料库在 Application Support/Cove2；有 TTL 的缓存在 Caches/Cove2。密码存 Keychain，文件夹授权不随配置导出。

## 内容与交互

- 视频：单个播放，或当前列表的垂直滑动播放；列表分页与下一集分别处理。
- 漫画：网页章节、ZIP/CBZ 共用图片阅读与下采样管线。
- 电子书：EPUB、PDF、TXT。
- 音乐：本地、HTTP、SMB 播放，播放队列、进度、迷你播放器。
- 图片、文件夹、网页原始浏览。
- 普通文件可前台离线保存；路径相对于应用数据目录持久化。

RAR/CBR 当前只有识别与解码器扩展接口，尚未集成实际 RAR 解码器。HLS 可在线播放，离线打包未实现；网页漫画整本离线未实现。真实站点与实体 NAS 需另做实际环境验证。

## 验证

Swift 测试覆盖配置契约、跨来源身份、资料库、路径及 EPUB 引用限制、图片尺寸和缓存失效、共享取消、HTTP 下载、文件目录与 SMB 分片媒体读取。界面测试使用 localhost 虚构网站及自制短视频。

    python3 scripts/test_export.py
    cd EasyReader
    xcodegen generate
    xcodebuild -project EasyReader.xcodeproj -scheme EasyReader \\
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

导出脚本会排除私有目录、凭据文件及非示例 .site，并在复制前检查常见密钥标记。公开前仍需 review 选定提交。
