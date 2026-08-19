# CutFlow 自动快编

## macOS / Xcode 版本

在 Xcode 中打开 `CutFlowMac/CutFlow.xcodeproj`，选择 `CutFlow` scheme、运行目标选择 `My Mac` 后运行。不要再用 `Package.swift` 启动应用；它只保留给单元测试。

原生版本目前包含：

- ChatCut 式 AI、素材/文字稿、播放器、时间线四区布局
- MiMo V2.5 ASR 逐词转写和 MiMo V2.5 Pro 结构化口误建议
- 逐词删除、AI建议确认、气口逐条确认/自动删除、撤销/重做
- 删除区间跳过预览、项目自动保存与安全书签恢复
- FCPXML、SRT、EDL JSON 一次导出
- API Key 仅保存至 macOS 钥匙串

MiMo V2.5 ASR 按官方 OpenAI 兼容协议调用 `/chat/completions`。应用会把视频音轨在本机转换为 16kHz 单声道 WAV，按 10 秒分段以 Base64 上传，并用本地语音边界检测缩小时间误差。官方 API 只返回文本而不返回逐词时间戳，因此当前版本是在各段实际有声区间内估算词语时间，而非服务端提供的强制对齐时间。
成功转写会按素材路径、大小、修改时间和 ASR 配置缓存；再次转写同一素材时直接恢复。项目原视频移动后，打开项目会引导重新定位。

命令行验证：

```bash
cd CutFlowMac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## 1.0 使用顺序

1. 在设置中保存 MiMo API Key，并测试连接。
2. 导入视频；视频会自动成为一个项目并出现在左侧项目栏。
3. 点击“转写”生成文字稿和字幕，或直接在文字稿区域输入内容。
4. 在时间线上拖动播放头、入点和出点；使用字幕块进行选择、拆分、合并、删除和编辑。
5. 导出 MP4、SRT、EDL 或 FCPXML；需要画面内字幕时开启“烧录字幕”。

项目、文字稿、AI 对话和编辑决定均为项目级数据，并带备份恢复。API Key 只保存在 macOS 钥匙串。

## 旧 Web 原型

无需安装依赖：

```bash
npm start
```

浏览器打开 `http://localhost:5173`。当前版本跑通导入、字幕校对、口误取舍、删气口与 FCPXML 导出；字幕分析暂用可编辑演示结果，下一步把 `analyze()` 接到 Whisper 即可获得真实转写。
