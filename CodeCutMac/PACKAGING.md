# CodeCut 本地打包版

适用系统：Apple Silicon Mac，macOS 15 或更新版本。

## 安装与文件

- `CodeCut-macOS-arm64.zip`：解压后将 CodeCut.app 拖到「应用程序」。
- `CodeCut-source.zip`：对应提交的全部受版本控制源码，包含本地 WhisperKit 依赖和测试。
- `CodeCut-history.bundle`：Git 历史离线备份，可执行 `git clone CodeCut-history.bundle CodeCut` 恢复。
- `SOURCE_COMMIT.txt`：本次打包对应的源码提交。
- `SHA256SUMS.txt`：用 `shasum -a 256 -c SHA256SUMS.txt` 校验文件。

本包使用 ad-hoc 本地签名，未使用 Developer ID 签名、未经过 Apple 公证。它是本地构建备份，不是已公证的对外安装包。跨电脑使用可能受到 macOS 安全检查限制。正式分发流程见 `DISTRIBUTION.md`。

模型权重、用户项目、音乐参考库、个人素材、钥匙串、Python 运行环境及 AudioForge 均不包含在包内。WhisperKit 和本机视觉模型首次使用需要准备模型；音乐分析、去人声、NCM 解码依赖 README 所述本地运行环境，换电脑需要另外配置。

## 从源码构建

安装 Xcode 后，在源码根目录执行：

```sh
cd CodeCutMac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
cd ..
bash CodeCutMac/scripts/package.sh
```

脚本将当前工作区编译为 Release 应用，但源码归档取自 Git HEAD；运行前应先提交准备打包的修改，使应用与源码一致。输出到根目录 `dist/`，不进入 Git。

日常开发用 Xcode 打开 `CodeCutMac/CodeCut.xcodeproj`；`Package.swift` 用于测试。
