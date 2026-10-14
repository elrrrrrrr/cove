# Cove 展示素材

图标沿用 App 的原始资源。宣传图中的屏幕来自实际 SwiftUI 视图和本地演示资源；不生成虚构的 App 界面。

配色以原始 icon 的深蓝、淡紫和薄荷色为依据，文字使用系统无衬线字体。网页与 NAS 并列展示，schema 和构建步骤放在 README 后半部分。

## 适合的设计工具

查询日期：2026-10-14。以下按 Cove 的宣传需求选择，功能信息来自官方页面：

| 工具 | 在 Cove 中适合做什么 |
| --- | --- |
| [Figma Buzz](https://www.figma.com/buzz/) | 品牌海报、发布图、固定版式模板和多尺寸宣传素材；可限制可编辑部分以保持一致性。 |
| [Rotato](https://app.rotato.app/help) | 将实际截图或录屏放进手机、平板等 3D 设备样机，调整镜头并导出宣传图或视频。 |
| [Canva](https://www.canva.com/pro/brand-kit/) | 快速制作海报与社交素材，用 Brand Kit 管理 logo、颜色、字体和模板；Brand Kit 属于 Pro 等套餐功能。 |
| [Adobe Express](https://www.adobe.com/express/create/poster) | 使用海报模板调整文案、图标、字体与品牌配色，适合快速制作宣传素材。 |

Cove 如果要持续维护发布图，建议用 Figma Buzz 保存品牌模板，并用 Rotato 处理设备样机。仓库同时保留可本地修改的展示源文件，便于替换实际截图后重新导出。

## 修改与导出

- `icon.png` 是现有 AppIcon 的原样副本。
- `hero.png` 是 README 宣传图，`preview.html` 用于本地查看。
- `../../scripts/render-brand.mjs` 保存版式、文字与配色，原始截图在 `../assets/`。

脚本需要 Node.js 和 [Sharp](https://sharp.pixelplumbing.com/)。可以把依赖安装在临时目录，不增加 App 的依赖：

```sh
npm install --prefix /tmp/cove-brand-tools sharp
COVE_BRAND_SHARP=/tmp/cove-brand-tools/node_modules/sharp \
  node scripts/render-brand.mjs
```

加上 `--svg` 会同时导出嵌入截图的 SVG，便于导入设计工具；这个体积较大的中间文件由 Git 忽略。重新拍摄截图时，启动本地 HTTP/SMB 演示服务，并为 `ExampleShowcaseTests` 设置环境变量 `COVE_CAPTURE_SHOWCASE=1`。测试附件保存网站和 NAS 的实际截图；平时测试会跳过这项可选拍摄。
