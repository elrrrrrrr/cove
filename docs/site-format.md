# Cove `.site` 配置规范

`.site` 是 UTF-8 YAML 文本，一份文件描述一个站点的完整规则。普通规则用 CSS 选择器，复杂规则用 JavaScript；两者使用同一结果结构。虚构示例见 [`demo.site`](../examples/sites/demo.site)，公开 Hacker News 示例见 [`hacker-news.site`](../examples/sites/hacker-news.site)。图文阅读的完整教程见 [HTML → 原生阅读](html-to-native.md)。

## 本地目录与首次安装

```text
仓库根目录/
├── sites/                 # 私有 .site 文件；本地构建自动打包
├── data/favorites.json    # 可选的私有预置收藏
├── config/                # 私有参考、工具等
└── examples/              # 虚构示例与获准公开的 Hacker News 教学配置

App Application Support/Cove/
├── config/sites.json      # 已导入的完整规则
└── data/Cove.store        # 收藏、历史、书签、NAS、离线记录的 SwiftData 存储
```

`sites/`、`data/`、`config/` 被 Git 忽略。不存在这些目录时，公开构建也正常工作。构建仅收集 `sites/` 第一层的 `.site` 和 `data/favorites.json`，并清理上一次构建的资源副本。

只有全新安装的第一次初始化会导入预置规则和收藏；空目录也记录初始化完成。以后升级、增加文件、删除站点，都不会触发自动导入。在“管理网站”手动导入配置；相同 `id` 可以替换或另存副本。导入收藏采用合并方式，以页面 URL 去重。

“管理网站”每行右侧的文档按钮可以打开当前配置；也可长按站点选择“查看配置”。默认直接显示交互式表单，右上角菜单可切换到完整 `.site` YAML 源码，或进入基本设置、网页点选和解析预览，包含全部入口、规则、门户和图片参数。表单按当前 schema 提供文字、开关、选项、列表和嵌套字段编辑，脚本仍可直接编辑。两种方式共用同一份草稿；无法解析的源码会保留原文并阻止切换，保存时统一校验。取消不会写入修改。查看配置不加载网页，进入点选或预览步骤才加载入口。没有保存规则时明确显示配置草稿。

修改已配置入口的名称、地址或分类会更新关联书签并保留 UUID；新增入口会创建书签。未修改的自定义书签名称保持原样，曾经删除的入口不会因保存其他配置重新出现。移除配置中的入口不会自动删除已经保存的书签，书签可在站点列表单独删除。已有站点标识保持稳定；需要副本时可导出后另存、导入。

已有数据的配置引用只关联当前规则，不新增预设入口。应用始终使用现有 Cove 资料库。SMB 配置包含主机、端口、用户名和共享名。

## 顶层字段

| 字段 | 含义 |
| --- | --- |
| `schemaVersion` | 必填；当前为 `1` |
| `id` | 必填；稳定身份，字母、数字、点、下划线或连字符 |
| `name` | 必填；显示名称 |
| `match` | 必填；域名匹配 |
| `entries` | 必填；入口数组，至少一个 |
| `rules` | 必填；解析规则数组，至少一个 |
| `portal` | 可选；通用门户地址解析 |
| `images` | 可选；图片 AES-CBC 转换参数 |

未知字段、重复 YAML 字段、不支持的版本和不完整规则均报告错误。文件可用普通文本编辑器修改，也可在 App 的“高级”页编辑、校验、导出。

## 匹配与入口

```yaml
match:
  hosts: [media.example]
  includeSubdomains: false
entries:
  - id: latest
    name: 最新内容
    path: /latest/
    category: video
```

`hosts` 匹配完整域名，`includeSubdomains: true` 才接受其子域。可选的 `hostPattern` 是明确的正则表达式，用于轮换域名；不会隐式使用字符串包含判断。

入口 `path` 可以是绝对 HTTP(S) 地址，也可以相对于 `hosts` 第一个域名的路径。分类为 `video / comic / image / novel / news / other`。入口身份 `id` 在一个站点内唯一，配置替换保留已有入口的书签 UUID。

规则的 `match` 可使用 `pathPrefix`、`pathPattern`、`query`，也支持域名条件。未指定规则匹配条件时匹配该站点所有路径。同角色的规则先按 `priority`（默认 0）降序，再按匹配具体程度，最后按规则 `id` 排序。为有重叠的规则显式设置优先级。

收藏、历史和子页面尽可能保留 `definitionID`，因此跨域跳转仍使用关联站点的规则。没有关联时通过域名寻找配置，列表和视频有通用兜底；漫画需要配置详情与章节规则。

## CSS 提取

```yaml
extract:
  items: article.card
  fields:
    title: {selector: .title, text: true}
    url: {selector: a, attribute: href}
    thumbnail:
      selector: img
      attribute: data-src
      fallbackAttributes: [src]
```

`items` 选择每个列表卡片；内部字段的 `selector` 相对卡片查询。没有 `items` 时，字段相对整个文档查询并返回一个对象。

| 字段选项 | 含义 |
| --- | --- |
| `selector` | 标准 CSS 选择器；省略时读取当前元素 |
| `text` | 文本读取，默认方式；文本会去除首尾空白 |
| `attribute` | 读取属性，如 `href / src / data-src` |
| `fallbackAttributes` | 主属性为空时依次尝试的属性 |
| `all` | 返回所有匹配结果组成的数组，适用于图片、标签、章节 |
| `resolveURL` | 补全相对链接；`url / thumbnail / cover / images / nextPageURL / prevChapter / nextChapter / sourceURL / commentsURL` 自动补全 |
| `number` | 转为数值；集数相关字段自动转为数值 |
| `pattern` / `capture` | 用 JavaScript 正则取捕获组；捕获组默认 1 |
| `value` | 固定文本值 |
| `fields` | 嵌套字段，适用于章节等对象数组 |
| `content` | `true` 时把选中的正文元素转成有序图文块；不可与属性、固定值、数组、嵌套字段或文本转换选项混用 |

## JavaScript 提取

`fields`、`script`、`expression` 三种提取方式只能选择一种。

```yaml
extract:
  script: |
    await Promise.resolve();
    return [...document.querySelectorAll('article.card')].map(card => ({
      title: card.querySelector('.title')?.textContent.trim() || '',
      url: card.querySelector('a')?.href || '',
      thumbnail: card.querySelector('img')?.src || ''
    }));
```

`script` 是函数体，支持 `await`、`return`、DOM 和 WebView 页面上下文中的 `fetch`。返回原生对象/数组，引擎负责 JSON 序列化；也兼容返回 JSON 文本。`expression` 用于完整 JavaScript 表达式。

## 页面角色及结果

| `role` | 结果契约 |
| --- | --- |
| `catalog` | 数组；每项必需 `title / url`，可选 `thumbnail / duration / extra / article` |
| `video` | 对象；必需 `url`，可选 `type`（hls/mp4）、`headers`、`title`、`nextPageURL`、`episodeNumber`、`episodeCount` |
| `comic` | 对象；必需 `chapters` 数组（每项 `url`，可选 `id / title`）；可选 `title / author / status / tags / desc / cover` |
| `chapter` | 对象；必需 `images` 数组；可选 `bookId / chapterId / bookName / chapterName / prevChapter / nextChapter` |
| `tags` | 标签文本数组，或带 `tags` 数组的对象 |
| `article` | 对象；必需 `blocks`，可选 `title / author / publishedAt / sourceURL / commentsURL` |

`catalog` 的可选 `article` 与单篇图文使用同一内容合同；可用嵌套 `fields` 和 `content: true` 直接生成正文预览，详情复用提取结果。CSS 和 JavaScript 示例见[动态图文与 Feed](dynamic-articles.md)。

列表 `contentType` 为 `video / comic / navLink / article`；分别进入视频、漫画、目录子页面、原生图文阅读。`navLink` 用于继续浏览目录，图文正文使用 `article`。混合列表仍可通过长按查看网页详情。电子书、TXT、PDF、压缩漫画、图片和音乐继续使用本地/SMB 阅读播放能力。

CSS 图文详情通常用 `blocks: {selector: article, content: true}`；手动构造块数组也可用 `all: true` 与嵌套 `fields`。JavaScript 返回相同对象，块类型为 `paragraph / heading / image / quote / code / link`，文字可用 `text` 或 `runs: [{text, url?}]`，图片使用 `url` 和可选尺寸、说明。完整字段、边界和示例见[图文契约](html-to-native.md#3-复杂页面改用-javascript)。

图文阅读支持本地收藏、置顶、历史和进度恢复。普通链接和评论在原网页查看；`sourceURL` 可进入外部原文的原生阅读。没有适用规则时使用语义正文选择器兜底，失败可查看原始网页。

## 加载、分页与展示

`load` 支持 `mode: auto / webView`、`waitSeconds`（0–30）、`headers`，以及可选 `preNavigateScript`（返回跳转地址）、`preNavigateExpression`（完整表达式）、`transformScript`（接收 `html`，返回资源标签剥离前的 HTML）。需要网页脚本生成内容时选择 `webView`。图文详情始终用 WebView，支持请求头、等待和跳转；`mode` 不改变此行为，`transformScript` 仅用于列表的快加载路径。

```yaml
pagination:
  mode: nextLink
  selector: 'a[rel="next"]'
  attribute: href
```

分页模式：

- `none`：不分页。
- `nextLink`：CSS 选择器读取下一页地址。
- `webNavigation`：`script` 返回下一页地址，或 `expression` 使用完整表达式。
- `ajax`：`script` 为异步函数体，可使用 `page` 数字，返回与列表相同的数组或 JSON 文本。可选 `thumbnailScript` 使用相同调用方式，返回页面 URL 到 data URI 的字典。

规则可配置 `searchURLTemplate`（`{keyword}` 占位）、`categories`（`name / path` 数组）。`presentation.layout` 为 `bento / portrait / list`；`mixedMedia: true` 启用长按网页详情；可选 `episodeCountField: duration / extra / title` 和 `episodeURLTemplate`（`{url}`、`{episode}`）提供列表选集。

## 通用门户与图片转换

`portal.url` 是入口，`headers` 可指定门户请求头。`base64Pattern` 用正则捕获 Base64 HTML 并寻找链接；加密 JSON 使用 `dataPattern`、`keyPattern`，按 AES-CBC、SHA256 派生密钥及载荷前 16 字节 IV 解码。`urlPaths` 可使用 `routes.*.address` 形式选择地址；`identityPaths` 与 `identityPattern` 可验证响应；`excludedHosts` 排除无关链接。这些字段全部来自配置。

`images` 可包含 `hosts`、`key`、`iv`。密钥与 IV 为 UTF-8 文本，密钥长度 16/24/32 字节，IV 16 字节。转换按关联站点或明确的图片域名启用。引擎只提供通用算法。

章节也支持 `request`：`capturePattern` 从当前 URL 捕获标识，`urlTemplate` 使用 `{capture}` 发起请求，`responsePattern` 提取图片地址，`exclude` 排除匹配文本。适用于图片列表接口；复杂 DOM 仍使用选择器或脚本。

## 收藏数据与备份

预置收藏示例见 `examples/data/favorites.json`。`schemaVersion` 为 `1`，`favorites` 数组每项必需 `title / pageURL`，可选 `id / thumbnail / duration / siteName / isComic / isArticle / definitionID / addedAt / isPinned / pinOrder`。日期使用 ISO 8601。`isArticle: true` 表示图文收藏，`isComic: true` 表示漫画，两者不可同时为真；均省略或为假时为视频。已有收藏省略 `isArticle` 默认不是图文，格式仍为 `schemaVersion: 1`。`isPinned` 为置顶开关，`pinOrder` 为非负顺序值；省略时默认不置顶。收藏页长按可置顶/取消置顶，右上角“管理置顶”可拖动排序。合并导入保留已有收藏的置顶选择和顺序，新导入的置顶项目按文件顺序追加（优先 `pinOrder`），取消置顶不删除收藏。App 收藏页可导出这种格式，然后保存到私有 `data/favorites.json`。

配置备份同样使用 `schemaVersion: 1`，包含阅读设置、站点定义、入口身份、单站解析覆盖和 NAS UUID；不包含密码。配置备份的“导入并替换”与单站点导入分开；单站点导入不替换其他配置，收藏导入以合并为准。

图文收藏可带可选 `articleSnapshot`，由 App 生成的 Base64 JSON 正文快照，继续使用 `schemaVersion: 1`。导入会校验图文类型、内容大小和正文块；备份与同步保留快照。它不包含 Cookie，图片仍为来源链接，不能替代完整离线媒体包。
