# Cove

Cove 是使用 SwiftUI 和 SwiftData 构建的 iOS 阅读与媒体客户端，支持网页内容、视频、漫画、PDF、EPUB、TXT、压缩漫画、图片、音乐及 SMB 文件访问。

App 不包含真实站点预设。站点使用可导入的 `.site` YAML 配置，普通页面通过 CSS 选择器解析，复杂页面通过可选 JavaScript 扩展。App 提供页面点选、手动编辑、结果预览和配置导入导出。

## 构建

需要 Xcode（iOS 26+ SDK）、Swift 6 和 XcodeGen。

```sh
cd EasyReader
xcodegen generate
open EasyReader.xcodeproj
```

SPM 依赖为 AMSMB2、ZIPFoundation、Yams。项目配置以 `EasyReader/project.yml` 为准。真机运行时在 Xcode 配置自己的签名团队。

## 私有配置与数据

在仓库根目录的 `sites/` 放置真实 `.site`；本地构建自动打包。可在 `data/favorites.json` 放置预置收藏。两个目录均被 Git 忽略，不存在时也能构建。

仅全新安装首次导入。后续更新通过 App 手动导入，用户删除的站点不会重新出现。App 数据优先存放在本地 `Application Support/Cove/config/` 和 `data/`，NAS 接入统一使用 SMB。

详细规范：[.site 配置与本地数据](docs/site-format.md)。虚构示例：[demo.site](examples/sites/demo.site)、[favorites.json](examples/data/favorites.json)。示例域名不提供真实服务。

## 验证

```sh
cd EasyReader
xcodegen generate
xcodebuild -project EasyReader.xcodeproj -scheme EasyReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

测试使用虚构站点与本地 HTML，覆盖选择器、异步脚本、匹配、分页、章节、配置校验、首次导入、迁移、收藏合并及备份身份。

## 准备公开仓库

```sh
python3 scripts/export-public-repo.py /path/to/cove-public
```

导出当前工作区可公开的文件到新目录，并初始化一个没有旧提交历史的新 Git 仓库。原仓库、原历史和未提交工作保留。私有配置、数据、生成项目及构建输出不导出；脚本不创建远程仓库，也不上传。
