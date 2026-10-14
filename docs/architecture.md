# Cove 代码结构

App 负责启动、资料库和根导航。Models 保存站点书签、收藏、阅读历史、离线文件及 SMB 连接；Features 提供对应界面；Shared 放通用组件、缓存、下载和文件安全工具。

网页处理分为 SiteDefinition（格式校验与 CSS/JS 契约）、SiteDefinitionStore（本地配置与首次初始化）、SiteParserRegistry（按定义和地址选规则）、PageLoader（加载、提取、分页）及专用内容阅读器。

图文使用同一 `.site` 契约：`catalog` 的 `contentType: article` 路由到 `ArticleReaderView`，`article` 角色提供详情规则。`ArticleDOM` 把 CSS 选中的 DOM 转成有序块；JavaScript 可返回同一结构。`ArticleLoader` 在 WebView 中加载和提取，使用共享 Cookie 与默认 TLS；`ArticleDocument` 在后台校验大小、数量和链接并准备文本，SwiftUI 负责原生展示。`ArticleImage` 复用 ImagePipeline 的下采样、请求上下文和缓存预算。查看原始网页复用同一个 WebView。

`ArticleReadingStore` 按 URL 查询并更新本地记录。历史用 `.article` 内容类型区分网页查看，保留 UUID；收藏在原模型中增加默认关闭的 `isArticle`，置顶、备份和文件夹同步继续走现有结构，仍只有 `schemaVersion: 1`。

.site、收藏预置和配置备份使用同一个 schemaVersion: 1。站点 id/入口 id 用于配置关联，书签和 NAS UUID 在导出导入中保留。凭据留在 Keychain。应用只使用 Application Support/Cove 资料库。

站点规则和展示设置按页面定义；Bento、竖版、导航列表、分类和选集是产品能力。代码整理与缓存优化应保持这些能力，不以通用简化页替换。

ReaderFileSafety 负责路径边界。缩略图写入使用 URL 哈希，并安全复用已有缓存文件。网络采用系统 TLS 校验。压缩文件和 EPUB 引用拒绝逃逸及符号链接。

验证使用虚构规则和本地夹具，同时检查现有数据、入口和布局。真实规则、数据和开发备份不提交 Git。
