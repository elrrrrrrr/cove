# 本地站点规则回归测试

运行完整测试：

```sh
cd EasyReader
xcodegen generate
xcodebuild -project EasyReader.xcodeproj -scheme EasyReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO test
```

只验证规则样本时，增加 `-only-testing:EasyReaderTests/SiteRegressionTests`。已有 `SiteScriptTests` 检查构建中每份 `.site` 的 YAML 和 JavaScript 语法；新测试进一步验证实际输出。

## 样本目录

```text
config/site-tests/          # 私有；Git 忽略，公开导出排除
├── cases.json              # 样本清单
├── source-a/
│   ├── catalog.html        # 保存的网页快照
│   ├── catalog.json        # 人工核对过的预期结果
│   ├── cover.bin           # 加密图片原始字节
│   └── cover.json          # 解码后的预期尺寸
└── source-b/...
```

`.site` 仍放在根目录 `sites/`。测试读取本次构建中的真实规则，不复制解析实现，也不新增运行时配置版本。`scripts/bundle-site-tests.sh` 只把快照复制到 XCTest 资源目录；正常应用构建不运行这个脚本。目录缺失时公开虚构样本照常运行，私有门户/图片样本明确跳过。脚本清除旧资源，避免删除本地快照后继续测试旧副本。

清单是测试数据，不属于 `.site` 格式。公开示例见 [cases.json](../EasyReader/Tests/Fixtures/SiteRegressions/cases.json)：

```json
[
  {
    "name": "catalog-current",
    "definitionID": "example.media",
    "operation": "extract",
    "ruleID": "video-list",
    "pageURL": "https://media.example/latest/",
    "input": "source-a/catalog.html",
    "expected": "source-a/catalog.json"
  }
]
```

`name` 在清单内唯一；`definitionID` 关联 `.site`，`ruleID` 指定并验证页面选中的规则。输入和预期文件的路径必须位于样本目录内，拒绝目录逃逸和符号链接。

| operation | 检查内容 | expected |
| --- | --- | --- |
| extract | CSS/JS 提取；视频、漫画、章节使用同样的结果合同 | JSON 数组或对象 |
| search | 从入口规则生成搜索 URL，再选择结果页规则并提取 | `{"url": "…", "pagination": "none", "items": […]}` |
| pagination | 下一页链接，或指定 `page` 的 AJAX 输出 | URL 字符串或条目数组 |
| portal | 门户快照解析，保留目标页面路径和参数 | 解析后的 URL 字符串 |
| image | localhost 返回原始加密字节，由实际 ThumbnailCache 解码 | `{"width": 120, "height": 80}` |

预期对象只断言写出的字段，数组同时断言数量与顺序。至少固定标题、页面 URL 和封面 URL，避免只有“结果非空”却提取错资源。图片测试还会移除站点转换配置，确认同一加密样本被拒绝，防止遗漏 `images` 配置。

AJAX 样本额外填写 `page` 和 `responses`，将指定请求替换为快照响应：

```json
"page": 2,
"responses": [
  {"url": "https://media.example/latest/2/", "file": "source-a/page-two.html"}
]
```

测试检查请求地址和次序；未配置的请求直接失败。WebKit 使用临时 profile，CSP 阻止页面脚本和外部网络，保留含数据的 script 标签供解析规则读取。图片请求仅访问 localhost，测试不会定时抓站或依赖互联网。

搜索样本额外填写 `keyword`；如果结果页使用另一条列表规则，填写 `resultRuleID`。`pageURL` 是提交搜索前的入口 URL，`input` 是结果页 HTML。测试同时检查搜索地址、实际选中的提取规则、分页方式和条目，不只断言“有结果”。没有分页的搜索页应单独匹配规则并配置 `pagination: {mode: none}`，避免重复请求同一页。

`SiteSearchTests` 覆盖中文/emoji、路径和查询参数转义、镜像域名、连续搜索、空输入、取消搜索返回分类、规则更新和分页切换。`SiteSearchUITests` 使用 localhost 走交互链路：搜索结果显示 → 取消返回分类 → 再次搜索 → 打开漫画详情；它可发现只跑解析脚本无法发现的规则复用和路由问题。

## 维护与覆盖范围

修改规则时先运行既有样本，再用已确认的网页结构补充样本。预期结果需要单独核对，不要为了让失败消失自动重录。优先增加：懒加载封面、无埋点属性卡片、分页、搜索结果、镜像/CDN 变更、视频选集以及漫画章节。

`testDefinitionRoundTripsAndReportsFixtureCoverage` 输出每个定义已经覆盖的提取规则和缺少样本的规则。没有样本只能算语法和格式已校验，不代表该站点的功能已经验证。本地首批覆盖近期列表、门户和封面问题；其他站点的网页样本仍需补充。

离线回归防止代码或规则修改破坏已保存的页面；网站自身改版、登录态、网络可达性和真机播放需要现场验证。解析测试通过也不能替代布局、手势或性能测试。
