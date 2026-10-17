# 动态列表与短帖阅读

沿用 `schemaVersion: 1`。动态站点仍由 `.site` 的 `catalog` 和 `article` 规则描述，应用代码不判断站点名称、域名或账号。

## 图文脚本

CSS 的 `content: true` 和 JavaScript 使用同一图文块合同。`extract.script` / `extract.expression` 中可调用 `readArticleContent(element)`，复用段落、图片、引用和安全链接提取；样式为 `pre-wrap` 的短帖保留换行。

```yaml
schemaVersion: 1
id: example.dynamic
name: 动态阅读示例
match: {hosts: [social.example]}
entries:
  - {id: profile, name: 个人主页, path: /people/demo, category: news}
rules:
  - id: posts
    role: catalog
    contentType: article
    load: {mode: webView}
    extract:
      items: '[data-post]'
      fields:
        title: {selector: '[data-body]', text: true}
        url: {selector: 'a[data-permalink]', attribute: href}
  - id: detail
    role: article
    load: {mode: webView}
    extract:
      script: |
        const post = document.querySelector('main [data-post-body]');
        if (!post) throw new Error('尚未找到正文，请查看原始网页后重试');
        return {title: document.title, blocks: readArticleContent(post)};
```

以上结构与域名均为虚构示例；真实域名、选择器和转换参数留在本地私有配置。

## 无限列表的结束信号

`pagination.mode: ajax` 可选配 `hasMoreExpression`，它必须返回布尔值：

```yaml
pagination:
  mode: ajax
  script: |
    // 网站自己的下一批内容逻辑；返回列表数组或 JSON 字符串。
    return await window.exampleFeed.next(page);
  hasMoreExpression: 'window.exampleFeed.hasMore'
```

明确返回 `false` 时停止分页，空末页保留已加载内容。没有结束信号的空响应仍提供重试，避免把网络等待当作列表结束。列表按资源 URL 去重，分页重叠时保留已有行的标识与顺序。后台 WebView 使用非零手机视口，让响应式布局与虚拟列表可以正常生成 DOM。

同源登录跳转落地后若没有新的文章规则，会继续使用原请求的规则，以显示规则提供的登录提示；跨源不进行这一回退。用户在原始网页里完成登录后可重新解析，Cookie 留在 WebKit 的本地持久存储，不写进 `.site` 或备份。

## 本地 X 实验

本地 `sites/local.x.site` 默认打开登录用户的个人 Feed，也支持个人主页列表和单帖阅读；入口可在 schema 表单或 YAML 中编辑。旧安装需显式重新导入本地规则替换配置，不依靠重新打包覆盖用户已保存的入口。规则、合成回归样本均被 Git 忽略，公开仓库不附带真实 X 选择器，也不需要 API token。

本轮范围是正文、图片、引用文字、链接和本地收藏。视频在原始网页查看。X 的网络加载与登录状态会影响结果，没有明确末页信号时保留重试。浏览器中已验证登录后的主页与单帖结构；Cove 自己的 WebKit 会话仍需在设备上登录验证，浏览器登录不会迁移过去。

## 网站登录数据

登录页、列表解析、单帖阅读、视频解析和漫画网页共用 `SiteWebSession.dataStore`，继续使用 WebKit 默认持久化存储，保留已有登录数据。网站 Cookie、LocalStorage 和 IndexedDB 不随 WebView 重建、站点规则修改或内容缓存清理而删除，也不写入 `.site` 或配置备份。设置中的“清除内容与设置”保留网站登录数据。

这不是永久登录保证：Cookie 的有效期、会话 Cookie 生命周期和服务端登出仍由 WebKit 与站点控制。应用不修改 Cookie 有效期、不恢复被站点撤销的登录、不导出登录凭据。卸载 App 或系统删除其数据后需重新登录。
