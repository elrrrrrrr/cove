# WebReader

站点定义通过 `.site` YAML 导入并持久化，所有页面统一使用 `SiteParserRegistry` 解析。

- `SiteDefinition.swift`：模型、校验、CSS 提取编译和 JavaScript 契约。
- `SiteDefinitionStore.swift`：本地保存、首次导入与已有配置关联。
- `SiteSetupWizard.swift` / `SiteElementPicker.swift`：点选、高级编辑与预览。
- `PageLoader.swift`：加载、提取和分页。
- `VideoURLExtractor.swift`：配置驱动的视频详情提取和通用兜底。
- `SiteTransforms.swift`：通用门户、图片转换能力。

真实域名、页面选择器、接口路径及专用参数只存在于用户配置。完整规范见仓库根目录 `docs/site-format.md`。
