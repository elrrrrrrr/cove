# IPA 与 Release

GitHub Actions 使用 `macos-26`、Xcode 26.6 与 XcodeGen 编译真机 Release archive，再打包为 `Payload/Cove.app`。产物是 **未签名 IPA**，要求 iOS 26+，需要下载后用自己的签名工具签名才能安装。它不适用于直接提交 TestFlight / App Store。

不需要 Apple 证书或 GitHub Secrets。公开构建不包含私有站点、预置收藏、开发描述文件或用户资料；站点可在 App 内导入。本地 `Cove-test.ipa` 属于开发签名测试包，与此流程不同。

## 合并与发布

1. 通过 PR 合并代码到 `main`。涉及应用源码、资源、打包流程或项目配置的 PR 会验证真机 archive 和 IPA；单元测试等回归由 CI 负责。
2. 在准备好的提交上打标签，例如：

   ```sh
   git switch main
   git pull --ff-only
   git tag v1.0.0
   git push origin v1.0.0
   ```

3. `IPA Release` workflow 构建成功后生成 **Release 草稿**，附上 `Cove-1.0.0-unsigned.ipa` 和同名 `.sha256` 文件。
4. 在 GitHub Releases 编辑草稿，填写变更说明，再手动发布。

标签必须为 `vX.Y.Z`，例如 `v1.0.0`。暂不支持带后缀的预发布版本；草稿允许发布前复核。已有同名 Release 不会被覆盖，失败后先检查 Actions 日志与现有草稿。

## 手动测试包

合并 workflow 后，在 Actions → IPA Release → Run workflow 选择分支，并填写 `1.0.0` 这样的版本号。手动构建仅上传 artifact，保留 14 天，不生成 Release。PR 构建使用 `0.0.0`，同样只上传 artifact。

`CFBundleShortVersionString` 来自版本号，`CFBundleVersion` 来自该 workflow 的 `github.run_number`；重跑同一 run 保持相同 build number。日常 Xcode 构建仍使用项目里的 `1.0` / `1` 默认值，应用 Bundle ID 保持不变。

下载 IPA 与校验文件到同一目录后运行：

```sh
shasum -a 256 -c Cove-1.0.0-unsigned.ipa.sha256
```

## 本地复现

使用不含根目录 `sites/`、`data/`、`config/` 内容的干净 checkout，并安装 Xcode 26+ 与 XcodeGen：

```sh
python3 scripts/test_release.py
bash scripts/build-ipa.sh 1.0.0 1 /tmp/cove-release
```

输出目录需没有同版本 IPA。脚本验证 arm64、iPhoneOS、应用身份、签名与私有预置边界，失败时不发布 Release。正式版本使用新的版本标签；不要移动已有发布标签。
