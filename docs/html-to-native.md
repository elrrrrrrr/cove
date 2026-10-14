# 把 HTML 网页变成原生阅读界面

Cove 负责加载网页、执行配置、展示内容与保存阅读记录。一份 `.site` 描述域名、入口和页面规则；CSS 和 JavaScript 返回同一套结果结构。站点名称、域名和选择器留在配置中。

[Hacker News 配置](../examples/sites/hacker-news.site)是可导入的公开示例；本教程的 `read.example` 是虚构域名，用来说明字段如何对应 HTML。

## 1. 找到列表与正文

假设列表页 `/stories/` 有如下条目：

```html
<article class="story">
  <a class="title" href="/posts/1">如何整理每天的阅读</a>
  <img src="/cover.png" alt="文章封面">
  <span class="author">演示作者</span>
</article>
```

点击后，`/posts/1` 的正文是：

```html
<h1>如何整理每天的阅读</h1>
<span class="author">演示作者</span>
<article class="body">
  <p>从收藏开始，再把资料放进同一个阅读空间。</p>
  <img src="/diagram.png" width="960" height="540" alt="内容整理流程">
  <h2>规则决定读取什么</h2>
  <p>也可以打开<a href="/reference">参考页面</a>。</p>
</article>
```

## 2. 用一份配置连接两种页面

```yaml
schemaVersion: 1
id: example.reading
name: 图文演示
match:
  hosts: [read.example]
entries:
  - {id: stories, name: 文章, path: /stories/, category: news}
rules:
  - id: stories
    role: catalog
    contentType: article
    match: {pathPrefix: /stories/}
    presentation: {layout: list}
    extract:
      items: article.story
      fields:
        title: {selector: .title, text: true}
        url: {selector: .title, attribute: href}
        thumbnail: {selector: img, attribute: src}
        extra: {selector: .author, text: true}
  - id: article
    role: article
    match: {pathPrefix: /posts/}
    extract:
      fields:
        title: {selector: h1, text: true}
        author: {selector: .author, text: true}
        blocks: {selector: article.body, content: true}
```

`catalog` 提取卡片数组，每项需要 `title` 和 `url`。`contentType: article` 决定点击后进入图文阅读器；`presentation.layout` 提供初始布局，用户仍可在右上角切换列表、Bento、竖版。

`article` 提取一个对象。`blocks` 的 `content: true` 会遍历选中的正文元素，按顺序生成段落、标题、图片、引用、代码和链接；跳过脚本、表单、iframe 等元素。段落内的链接保留为可点击文本，图片使用共享的下采样缓存。HTML 样式不会直接复制进原生阅读器。

相对链接按网页地址补全。正文没有提取成功时，阅读器提供重试和查看原始网页。原始网页检查默认复用当前解析 WebView，保留页面状态。

## 3. 复杂页面改用 JavaScript

Hacker News 用相邻的表格行分别保存标题和元信息，列表规则因此需要组合两行。示例将每一项的地址统一指向 `/item?id=…`，先打开帖子；Ask HN 正文由 `.toptext` 提取，评论保留在原网页中。

详情规则也可以用 `extract.script` 返回以下对象，替代 `fields`：

```yaml
extract:
  script: |
    return {
      title: document.querySelector('h1')?.textContent.trim() || '',
      author: document.querySelector('.author')?.textContent.trim() || '',
      blocks: [
        {type: 'paragraph', text: '第一段正文'},
        {type: 'heading', level: 2, text: '小标题'},
        {type: 'image', url: '/diagram.png', alt: '内容整理流程', width: 960, height: 540},
        {type: 'paragraph', runs: [
          {text: '查看'},
          {text: '参考页面', url: '/reference'}
        ]}
      ]
    };
```

`fields`、`script`、`expression` 三选一。脚本可使用 `await`，返回原生对象即可，引擎负责序列化。

| 图文对象字段 | 含义 |
| --- | --- |
| `title` | 可选；为空时使用列表标题 |
| `author`、`publishedAt` | 可选的展示文字；时间不自动转换 |
| `sourceURL` | 可选的外部原文地址；显示「阅读原文」 |
| `commentsURL` | 可选的评论页；在原网页中打开 |
| `blocks` | 必需；按显示顺序排列的正文块 |

| `blocks[].type` | 使用的字段 |
| --- | --- |
| `paragraph`、`quote`、`code` | `text`，或保留行内链接的 `runs: [{text, url?}]` |
| `heading` | 同上，另有 `level: 1…6` |
| `image` | `url`，可选 `alt / width / height` |
| `link` | `url` 和 `text` |

正文、图片和链接地址仅接受 HTTP(S)，拒绝含账号密码的 URL。未知块类型会报错；输出上限为 2 MiB JSON、2,000 个块和 100 万正文字符。`blocks: []` 仅在提供有效且不同于当前页的 `sourceURL` 时有效，适用于只有外部链接的帖子。

外部原文没有匹配的详情规则时，尝试提取 `h1 / title` 与 `article / main / [role=main]`。这不是对任意网页的适配保证；导航过多、登录或正文结构特殊的页面仍需要规则或原网页查看。

图文详情使用共享登录数据的 WebView，支持 `load.headers`、`waitSeconds` 与跳转脚本；`load.mode` 不改变它的加载方式。`transformScript` 是列表快加载的 HTML 转换选项，图文详情不使用它。

## 4. 导入和调试

1. 在「设置 → 管理网站」导入 `.site`，或创建规则。
2. 打开站点右侧的配置按钮，用表单或完整 YAML 编辑。
3. 用网页点选定位元素，再到解析预览检查结果。
4. 保存后打开入口，确认列表、正文、图片与分页；失败时查看当前原始网页。
5. 长按卡片或在图文阅读器收藏；下次从收藏或主页继续阅读。

要试 Hacker News，导入公开示例后打开 Ask HN。首页的链接帖可能没有站内正文，通过「阅读原文」继续阅读外部文章；评论始终在原网页中查看。

## 5. 用离线页面验证规则

新增规则应有固定 HTML 样本，避免测试依赖线上内容。Hacker News 的测试直接读取公开 `.site`，用虚构标题、作者与正文验证：列表和下一页、正文顺序、图片与链接、评论边界、收藏类型、阅读记录身份、备份和文件夹同步。

`ArticleUITests` 通过 localhost 执行真实的导入、列表、阅读、收藏、原网页查看与继续阅读流程，同时生成截图。图片和内容来自 `Tests/Fixtures/Articles/`，不包含真实用户资料。其他私有规则的快照仍放在 Git 忽略的 `config/site-tests/`；详见[站点测试指南](site-tests.md)。
