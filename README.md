# CodeCut 自动剪辑

**面向口播、产品视频和素材整理的原生 macOS 本地 AI 剪辑工具。**

CodeCut 把文稿、逐词转写、口播精剪、B-roll 素材识别、分镜编排和音乐参考库放在一个桌面工作流中。通过文字稿定位剪辑，用 AI 辅助审阅和选片，再导出视频或交换格式继续后期制作。

> 当前是开发预览版，适用于 Apple Silicon Mac / macOS 15+。AI 默认在本机运行，首次准备模型需要联网。现有下载包未经 Apple 公证，模型和外部运行环境不随软件包分发。

[下载软件与源码](https://github.com/Mooyumm/CodeCut/releases) · [完整使用指南](docs/USAGE.md) · [AI 接入模式与开发建议](docs/AI_INTEGRATION.md) · [功能细节](docs/FEATURE_DETAILS.md) · [发布记录](CodeCutMac/RELEASE_NOTES.md)

## 能做什么

| 工作区 | 当前能力 |
| --- | --- |
| 文稿 | 导入产品 brief、参考图、口播稿与分镜表；支持 PDF、Word、PPT、图片及文本等格式 |
| 口播 | WhisperKit 本地逐词转写、字幕校对、删词、气口处理、口误与重复内容审阅、撤销与重做 |
| B-roll | 导入实拍素材、画面与产品识别、按产品归类、标记待确认物品、推荐素材区间 |
| 分镜 | 表格编辑、CSV 导入导出、匹配口播时间、从素材库辅助选择 B-roll、生成制作提示词 |
| 音乐参考 | 跨项目曲库、波形选段、批注、片段导出；可选本地音频分析与去人声 |
| 交付 | MP4、SRT、FCPXML、EDL 等导出；项目自动保存与备份恢复 |

AI 生成的是待审阅建议。分镜提示词生成不等于自动生成视频；Web 页面是历史原型，完整功能在原生 Mac 应用中。

## 快速开始

1. 从 [Releases](https://github.com/Mooyumm/CodeCut/releases) 下载 `CodeCut-macOS-arm64.zip`，解压后将应用放入「应用程序」。下载包是未公证的本地构建；若系统拒绝运行，可用 Xcode 从源码构建。
2. 打开应用，在 AI 设置中点击「准备本地模型」，下载完成后点击「检查状态」和「测试连接」。首次转写还会准备 WhisperKit 模型。
3. 导入视频，在「文稿」工作区放入口播稿和产品资料，在「口播」工作区点击「转写」。
4. 校对文字稿，检查删词、气口与去重建议，试听剪辑结果。
5. 按需导入 B-roll、编辑分镜，再导出 MP4 或 SRT / FCPXML / EDL。

音乐分析、NCM 解码和去人声还需要单独配置外部运行环境，详见 [使用指南](docs/USAGE.md)。

## 从源码运行

需要带 macOS SDK 与 Swift 6 工具链的 Xcode；项目构建目标是 macOS 15 和 arm64。

```sh
git clone https://github.com/Mooyumm/CodeCut.git
cd CodeCut
open CodeCutMac/CodeCut.xcodeproj
```

在 Xcode 中选择 `CodeCut` scheme 和 `My Mac`，在 Signing & Capabilities 中选择自己的开发团队后运行。仓库里的开发团队配置不是可共享的签名凭据。`Package.swift` 用于核心逻辑测试，不是应用启动入口。

```sh
# 原生测试
cd CodeCutMac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
cd ..

# 本地 Release 打包：先提交所有需要包含的源码修改
bash CodeCutMac/scripts/package.sh

# 可选：历史 Web 原型，另需 Node.js / Python 3
npm test
npm start
```

原生打包结果位于 `dist/`。Web 原型运行在 `http://localhost:5173`，使用演示分析结果。开发机在 2026-10-11 完成 Release 编译、299 项 Swift 测试和 Web 时间线测试；真实模型、外部依赖和个人样例集成测试需另行配置，普通测试通过不代表这些环境已安装。

## AI 与数据流

- **语音识别**：WhisperKit / Core ML，在本机获得逐词时间戳。
- **断句与时间对齐**：文稿标点、真实停顿与本地匹配算法，无需大模型。
- **文本与视觉理解**：llama.cpp + Qwen3-VL，通过本机回环地址调用；默认 8B，代码也支持 4B 配置。
- **音乐理解**：可选 Essentia 特征提取 + 独立 Qwen2-Audio / MLX 环境；去人声另依赖 AudioForge。
- **云端模式**：当前关闭。源码保留 DeepSeek 适配代码，但没有启用云端配置界面。

模型下载会访问外部下载源；模型准备好后的上述推理在本机执行。原始素材、个人项目、模型权重和钥匙串凭据不包含在仓库中。当前 llama.cpp 自动下载地址使用第三方代理，下载与模型路径详见 [AI 接入说明](docs/AI_INTEGRATION.md)。

## 项目结构

```text
CodeCutMac/
  CodeCut.xcodeproj/       原生应用工程
  Sources/CodeCutMac/      界面、剪辑逻辑、导出与 AI 接入
  Tests/CodeCutMacTests/   单元与可选集成测试
  Vendor/                 本地 WhisperKit 依赖源码
  scripts/                打包与模型下载脚本
docs/                     使用与开发文档
index.html / app.js        历史 Web 原型
```

## 当前限制与反馈

当前未提供 Windows、Linux 或 Intel Mac 构建。未提供“一键安装所有音乐 AI 依赖”的安装器；音频分析、去人声、NCM 解码需要 README 和指南中列出的组件。模型推断可能出错，导出前应逐段试听并确认素材区间。跨机分发签名、公证流程见 [DISTRIBUTION.md](CodeCutMac/DISTRIBUTION.md)。

可通过 [Issues](https://github.com/Mooyumm/CodeCut/issues) 反馈问题，附系统版本、芯片、复现步骤和脱敏日志；请不要上传私密素材或密钥。

## 许可

仓库公开不代表已授予任意再分发或商业使用许可：目前尚未为 CodeCut 自有代码指定统一开源许可证。第三方源码、模型和外部工具分别遵循各自许可；WhisperKit 的许可保留在 [Vendor/LICENSE](CodeCutMac/Vendor/argmax-oss-swift-1.1.0/LICENSE)。
