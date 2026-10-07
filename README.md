# Cove

当前维护版恢复重构前的完整界面和数据入口：主页快速访问、继续阅读、最近阅读、下载与稍后再看；站点图标/内容缩略图；视频 Bento、漫画竖版、导航列表及图片内容样式；收藏、NAS、原生阅读器和设置。

网站解析仍使用通用 .site 配置和可编辑 JavaScript，真实规则放 sites/，预置收藏放 data/。这些目录及 config/ 保持 Git 忽略。DSM/FnOS 登录没有恢复。

    cd EasyReader
    xcodegen generate
    open EasyReader.xcodeproj

恢复版重新使用原有 Application Support/Cove 资料库及已有 v1 规则。Cove2 数据和 v2 源码备份保留，不删除用户数据。此前 v2 架构分支只是候选方案；后续优化必须保持已有功能、默认布局及站点样式，再逐项验证。

恢复时保留了默认 TLS 证书校验、完整 URL 哈希缓存文件名和压缩包路径边界检查。

[恢复记录](docs/ui-recovery.md)说明数据保留与验证情况。
