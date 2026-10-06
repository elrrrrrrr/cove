# 重构验证记录（2026-10-07）

## 范围

全新资源来源架构与 .site schemaVersion 2。files、SMB、web 共用浏览、稳定资源身份、收藏历史和内容分发；CSS/异步 JS 使用同一提取结果。新资料库使用 Cove2，不读取旧配置或迁移旧数据库。

本地 8 份私有定义完成一次性文件转换、schema 校验和 JavaScript 语法检查。真实站点数据及旧工作区备份只保存在被忽略的 sites/、config/ 中。

## 环境与结果

- Xcode 27.0（27A266a），Swift 6 严格并发。
- iPhone 17 Pro / iOS 26.3.1 模拟器：47 项单元测试 + 2 项界面测试。
- iPad Pro 11-inch (M4) / iOS 26.3.1 模拟器：同样两项界面流程，使用没有私有预置内容的 Release 构建。
- Python：5 项导出策略与完整导出测试。
- Release：包含本地 sites/、data/ 的开发目录构建，以及完全不含这些目录的独立导出目录构建。

iPhone 最终完整运行：49/49 通过；Python 5/5 通过。iPad Release 两项界面流程 2/2 通过。两个 Release 构建均通过；应用 Swift 源码没有编译警告。测试全部使用本地夹具或 localhost，没有访问真实站点或实体 NAS。

## 检查内容

| 范围 | 证据 |
| --- | --- |
| 配置 | 拒绝旧 schema、重复/未知字段、无效数组规则；YAML 往返；CSS、嵌套字段与 async JS；修改章节选择器保留嵌套字段与数组语义 |
| 身份和存储 | 来源隔离、版本变化不改变资源身份、选集身份、收藏进度 upsert、失败回滚、空 bundle 也只初始化一次、删除来源不重新预置、离线相对路径可脱离来源打开 |
| Web | Cookie/profile 来源隔离、host-only/path/secure 过滤、登录 epoch 失效；脚本超时/取消只完成一次；分页和搜索编码；广告规则可编译 |
| 文件和压缩包 | traversal、绝对路径、相似前缀、符号链接、压缩膨胀限制、EPUB container/manifest 和编码后的 href 边界；临时解包目录有明确所有者 |
| 图片缓存 | URL 哈希文件名、TTL、索引恢复、总字节淘汰、符号链接拒绝、尺寸/mtime/请求/Cookie/变换失效、共享订阅取消、最后订阅取消底层任务 |
| 媒体 | SMB 分片读取请求不超过 512 KB；SMB 视频缩略图；HTTP 真实播放进度推进；切换时旧播放回调按 generation 失效 |
| 下载 | HTTP 404 和大小上限拒绝、取消、独立临时文件；导出拒绝凭据且复制前停止 |
| 界面 | 引导创建来源、标签搜索只进入搜索、上下滑切换视频并实际播放、退出返回当前列表；iPhone/iPad 截图 |

## 性能证据及限制

12 MP（4000 × 3000）JPEG 的回归测试输出 480 × 360 缩略图，解码像素缓冲成本约 0.66 MiB；与全尺寸 45.8 MiB 的理论 RGBA 缓冲比较，明显减少单图解码成本。这不是 App 峰值 RSS 测量。

并发两个图片订阅只触发一次冷请求，取消一个订阅不会取消另一个；暖命中不增加请求。最后一个订阅取消会取消底层请求。缓存淘汰与 TTL 通过受控字节数和时间验证。

来源快照和解析脚本准备移出 SwiftUI body；资料库索引、列表过滤、标签和阅读集合按数据变化准备。图片目标尺寸来自实际布局并分档；网络和解码有各自并发限制。TXT 检测、文件/图像解码在后台执行。

尚未用实体设备 Instruments 测量滚动 hitch、峰值 RSS、耗电或大规模真实目录。NSCache 的 96 MiB cost 上限是软预算，不能据此承诺进程内存上限或帧率提升。

## 可复现

    python3 scripts/test_export.py
    cd EasyReader
    xcodegen generate
    xcodebuild -project EasyReader.xcodeproj -scheme EasyReader \
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
      -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test

设备名称需要匹配本机已安装的模拟器。独立导出验证通过 scripts/export-public-repo.py 创建不含私有内容的新目录，再执行相同的工程生成和 Release build。

## 界面截图

截图使用虚构的 localhost 网站与自制媒体。

- [iPhone 列表](screenshots/phone-collection.png)、[设置](screenshots/phone-modules.png)、[搜索](screenshots/phone-search.png)、[滑动播放](screenshots/phone-feed.png)
- [iPad 列表](screenshots/ipad-collection.png)、[设置](screenshots/ipad-modules.png)、[搜索](screenshots/ipad-search.png)、[滑动播放](screenshots/ipad-feed.png)

## 未完成能力和观察项

RAR/CBR 尚未包含实际解码器；HLS 离线打包和网页漫画整本离线未实现。当前下载是前台任务，不提供后台续传保证。真实站点登录、反爬环境、实体 NAS 和各类复杂 EPUB 仍需实际环境验证。

Xcode 的界面测试在配置向导期间报告 Invalid frame dimension (negative or non-finite) 警告，没有源文件定位；已检查截图，流程没有崩溃或控件重叠。此诊断原因仍需后续定位。依赖的 Makefile.AMIGA 系列构建警告以及 SDK 的 AppIntents metadata skipped 与应用 Swift 源码警告分别记录。

本地 v1 规则和旧工作区备份位于 config/rebuild-backup-20261007/，不会提交或随应用打包。原开发仓库历史保留，GitHub 仓库保持 Private。
