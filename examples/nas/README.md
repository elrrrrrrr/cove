# NAS 也能成为自己的资料库

网站通过 `.site` 描述页面；NAS 通过 SMB 连接共享目录。两种来源共用列表、Bento、竖版布局，点击资源后进入对应的播放器或阅读器。

`files/` 提供实际可打开的演示资源：

```text
CoveDemo/
├── Rust 学习指南.txt    # 自动识别章节的纯文本样本
├── Rust 学习指南.epub   # MIT 许可的 Rust Book 简体中文版
├── 赵雷 — 无法长大.jpg   # 公开专辑封面，来源见下文
├── 山谷慢行.mp4         # 原创 6 秒动画
├── 沿海来信.jpg         # 原创矢量插画的图片
├── 沿途音频.opus        # 公开测试音频
├── 沿途绘本.cbz         # 三页原创演示图片
├── 阅读空间.txt         # 五章演示文字
├── Cove 使用手记.pdf    # 原创演示 PDF
└── 其他原创图片
```

## 使用自己的 NAS

把这些文件放进你选择的 SMB 共享目录。在 Cove 的 NAS 页添加连接，填写服务器地址、共享名和自己的账户；连接后打开目录，即可切换布局、阅读或播放。密码保存在 Keychain，不放进 `.site`、示例配置或备份。

## 在模拟器中体验本地 SMB

可选的本地演示使用 [Impacket 的 SMB 服务](https://github.com/fortra/impacket/blob/master/examples/smbserver.py)，只分享上面的示例文件，监听 loopback 并设为只读，不改动系统文件共享：

```sh
python3 -m venv /tmp/cove-demo-smb
/tmp/cove-demo-smb/bin/python -m pip install impacket
/tmp/cove-demo-smb/bin/python scripts/serve-examples.py --smb
```

在模拟器中添加 NAS：服务器地址填 `127.0.0.1:1445`，共享名填 `CoveDemo`，用户名和密码留空。这是仅供本地演示的访客共享；访问真实 NAS 时使用自己的服务器授权。

README 的 NAS 截图由实际生产目录视图读取这个共享生成，缩略图通过真实 SMB 请求加载。文件目录包含开放电子书、测试资源和公开专辑封面，没有展示个人 NAS 地址或凭据。赵雷音乐演示通过官方公开试听流拍摄，完整歌曲不放进共享目录；[封面与曲目信息来源](../showcase/README.md)。
