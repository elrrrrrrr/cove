> 历史候选：本文记录被回退的 v2 重构分支，不是当前恢复版的界面或数据契约。当前版本见 [恢复记录](ui-recovery.md)。

# Cove .site v2

一份 .site 描述一个资源来源。本地文件、SMB 和网页使用相同的来源列表、收藏及阅读入口。格式为 UTF-8 YAML；旧格式不再导入，也不读取旧数据库。

## 最小配置

```yaml
schemaVersion: 2
id: my-media
name: 我的媒体
source:
  adapter: web
  url: https://media.example/
modules:
  catalog:
    kind: video
    items: article.card
    fields:
      title: .title
      url: a@href
      thumbnail: img@src
  video:
    fields: {url: 'video@src'}
```

向导自动生成稳定 id。修改名称、规则、布局不需要修改 id；另一个账号或独立资源源使用另一个 id。无需手动递增配置 version：引擎自动计算配置指纹。

source.adapter 为 web / files / smb。文件来源只需 adapter: files，在 App 选择授权目录。SMB 另外填写 host / share / username，使用标准 SMB 端口；密码只进 Keychain。配置导出不包含密码及文件夹授权。没有网页模块时，网页来源可以使用通用链接浏览。

## 入口

省略 entries 自动创建主入口。多个入口可在向导中添加：

```yaml
entries:
  - id: latest
    name: 最新视频
    path: /videos/
    kind: video
  - id: comics
    name: 漫画
    path: /books/
    kind: comic
```

网页路径相对于 source.url；文件和 SMB 路径相对于所选目录或共享。内容 kind 为 folder / video / comic / ebook / audio / image / web / unknown。格式与内容类型分开：例如漫画格式为 CBZ、RAR 或网页图片；电子书格式为 EPUB、PDF、TXT。

## 可选模块

| 模块 | 用途 |
| --- | --- |
| catalog | 提取列表，必需 title、url；可选 id、thumbnail、tags、duration、format、byteSize、modifiedAt |
| pagination | 下一页链接，或 AJAX/页面脚本 |
| search | 使用 {query} 的搜索 URL |
| login | 在来源自己的浏览器会话里登录 |
| video / audio / ebook | 返回 url，必要时返回 headers、format 等资源参数 |
| comic | 漫画信息及 chapters 数组，每章含 title、url |
| chapter | images 数组，或通用文本接口 request |
| tags | 标签数组 |
| episodes | 列表选集：countField、含 {url} / {episode} 的 url 模板 |
| portal | 门户地址及通用解码参数 |
| images | 来源图片的 AES-CBC 参数 |

收藏、历史、进度、文件解码、原生阅读器由 App 管理，不在配置内重复实现。

## CSS 简写与完整字段

- .title：读取文本。
- a@href：读取属性。
- .tag[]：读取多个文本。
- img@src[]：读取多个图片地址。

url、thumbnail、cover、images 等地址自动补全相对路径。复杂字段可以写完整对象：

```yaml
thumbnail:
  selector: img
  attribute: data-src
  fallbackAttributes: [src]
chapters:
  selector: .chapters a
  all: true
  fields:
    title: {text: true}
    url: {attribute: href}
```

完整选项还包括 number、resolveURL、pattern、capture、value、嵌套 fields。漫画章节、图片、标签字段必须为数组。未知字段、重复键、无效模式及缺少必要字段会报错。

模块的 fields 与 script/expression/request 不能同时指定。items 只用于列表；其他模块通过数组字段表达多值。

## JavaScript 与页面变体

```yaml
modules:
  catalog:
    kind: video
    script: |
      await Promise.resolve();
      return [...document.querySelectorAll('article')].map(card => ({
        title: card.querySelector('h2')?.textContent.trim(),
        url: card.querySelector('a')?.href
      }));
```

script 为支持 await 的函数体；expression 为完整表达式。CSS 和 JS 返回相同结构。DOM、登录 Cookie 与 fetch 使用这个来源的 WebKit 会话；后台解析只接收序列化结果。配置 JS 不提供文件、Keychain 或原生界面访问。

同模块可添加 variants：按声明顺序匹配 pathPrefix、pathPattern、query，匹配后使用完整变体；未匹配时使用基础规则。变体需完整 items/fields 或脚本，不做隐式字段合并。

```yaml
variants:
  - match: {pathPrefix: /books/}
    kind: comic
    items: .book
    fields: {title: .title, url: a@href}
```

load 支持 waitSeconds（0–30）、headers、preNavigateScript。动态网页由 WebKit 渲染；不会用删 script 的正则来模拟安全沙箱。EPUB 使用独立、无页面 JS、无外部网络加载的阅读会话。

## 分页、搜索、登录

```yaml
modules:
  pagination:
    next: 'a[rel=next]@href'
  search:
    url: '/search?q={query}'
  login:
    url: /login
```

分页还支持 mode: ajax / webNavigation / none，以及 script 或 expression。AJAX 脚本可使用 page，返回列表数组；空数组结束分页。来源接口向界面统一提供 items + nextCursor，界面不猜页码。

搜索关键词按单个 URL 值编码，& = # 不会变成额外参数。没有远程搜索模块时，搜索框筛选当前列表。分页测试和搜索测试在向导的预览页执行。

## 浏览与播放

```yaml
presentation:
  layout: grid
  openItem: videoFeed
  feed:
    nextGesture: swipeUp
    autoplay: true
    preloadNext: 1
    onPlaybackEnd: stop
```

layout 为 grid / portrait / list。openItem 为 reader / videoFeed。swipeUp 表示下一项在下方、手指向上划；swipeDown 使用相反方向。播放器只激活当前视频，取消过期解析，并在接近列表末尾时追加分页。

onPlaybackEnd 为 stop / nextItem / nextEpisode。列表下一项与视频解析结果的 nextPageURL（下一集）分别处理。预取仅准备下一项的播放描述，不预先下载整部视频。

## 通用转换

portal 保留 url、headers、base64Pattern、dataPattern、keyPattern、urlPaths、identityPaths、identityPattern、excludedHosts，用于声明入口重写。图片 images 使用 key、iv 和可选 hosts；引擎提供通用 AES-CBC 解码，不含真实站点分支。

chapter.request 使用 capturePattern、urlTemplate（{capture}）、responsePattern、exclude 访问图片列表接口。

## 本地文件与用户数据

根目录 sites/、data/、config/ 被 Git 忽略。构建可自动打包 sites/*.site 和 data/favorites.json；只有首次初始化导入，包括空目录。以后增加文件或删除来源都不会自动再导入。

应用使用 Application Support/Cove2/config 和 data；缓存放 Caches/Cove2。收藏 JSON 使用 schemaVersion: 2、items 数组，从收藏页导出即可编辑或作为预置数据。持久离线文件使用相对路径，不把容器 UUID 写进数据库；清缓存不会删除离线内容。

ZIP/CBZ、EPUB、PDF、TXT、音频、图片和视频已有阅读入口。RAR/CBR 已有格式识别与解码器接口，当前尚未集成实际 RAR 解码器。HLS 可在线播放，当前不提供 HLS 离线打包；网页漫画当前不提供整本离线下载。下载是有容量限制的前台任务，不声称支持后台恢复或断点续传。
