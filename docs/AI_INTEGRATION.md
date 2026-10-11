# AI 接入现状与建议模式

本文前半部分描述当前代码，后半部分是未来扩展建议。**本次文档不新增云端 API、Ollama、LM Studio 或视频生成接入。**

## 1. 当前已实现的数据流

| 任务 | 当前实现 | 输入 / 输出 |
| --- | --- | --- |
| 逐词语音转写 | WhisperKit / Core ML，`large-v3-v20240930_626MB` | 本地音频 → 文本与逐词时间戳 |
| 字幕断句 | 文稿标点与真实停顿规则 | 转写词与时间 → 字幕分段 |
| 分镜对齐口播 | 本地文本匹配与对齐 | 分镜台词与词时间 → 成片时间区间 |
| 口误审阅、去重、分镜提示词、候选选片 | `AIClient` → llama.cpp / Qwen3-VL | 文本 → 文本或结构化结果 |
| B-roll / 产品画面理解 | `LocalVLM` 与产品识别逻辑 | 本地抽帧及参考图 → 画面、产品与推荐区间 |
| 音乐数值特征 | 独立 Essentia Python 子进程 | 本地片段 → 电平、频谱及 BPM / 调性估计 |
| 音乐声音描述 | 独立 Qwen2-Audio / MLX 子进程 | 最多 30 秒音频 → 描述 |
| 去人声 | 外部 AudioForge / BS-Roformer | 本地音乐 → 独立伴奏文件 |

`AISettings.current` 固定返回 `.local`；DeepSeek 配置和请求代码保留，但当前入口不选择它。现有设置页不提供任意 Base URL / API Key 编辑器。界面中个别历史说明把断句归给模型，实际断句路径以当前规则实现为准。

## 2. 当前本地服务如何连接

相关文件：

- [AIClient.swift](../CodeCutMac/Sources/CodeCutMac/AIClient.swift)：设置、HTTP 请求、提示词、返回解析。
- [LocalVLM.swift](../CodeCutMac/Sources/CodeCutMac/LocalVLM.swift)：模型选择、下载、进程、健康检查与视觉调用。
- [WhisperTranscriber.swift](../CodeCutMac/Sources/CodeCutMac/WhisperTranscriber.swift)：语音模型、逐词转写与缓存。
- [MusicReference.swift](../CodeCutMac/Sources/CodeCutMac/MusicReference.swift)：音频处理、Qwen / Essentia 子进程、资源调度。

当前 llama-server 只监听本机 `127.0.0.1`，优先端口 8080，遇到其他服务占用时可能使用 8081。文本 Base URL 为 `http://127.0.0.1:<实际端口>/v1`，调用 `/chat/completions`，模型别名为 `codecut-local`。本地请求超时为 900 秒；本地 `apiKey = "local"` 是占位值，不是云端凭据。

视觉模型为 Qwen3-VL Instruct GGUF：8B / 4B 主权重使用 Q4_K_M，配套 mmproj 使用 Q8_0。默认 8B，`localModelChoice` 偏好值为 `8B` 或 `4B`；当前 AI 设置页没有模型下拉框。开发者需要切换时，可退出应用后设置偏好，再启动并重新准备对应模型：

```sh
defaults write com.mooyumm.codecut localModelChoice -string '4B'
# 恢复默认配置时，把 4B 改为 8B。
```

这只改变本应用选择的本地模型，不接入外部服务。不要在模型任务运行时改偏好。

### 下载与文件位置

- 主权重与视觉投影：`~/Library/Application Support/CodeCut/Models/`。
- llama.cpp：`~/Library/Application Support/CodeCut/Runtime/llama.cpp/`；也检查 Homebrew 常用位置的 `llama-server`。
- 当前自动下载固定 llama.cpp 构建 `b11065`，URL 经过 `gh-proxy.com` 转发 GitHub 发布文件；模型来自 ModelScope，代码使用 `Revision=master`。
- Qwen2-Audio 独立模型位于 `Runtime/Qwen2-Audio-7B-Instruct-4bit`，Python 环境位于 `Runtime/qwen-audio-env`。它与 Qwen3-VL 是两套模型。

未来发布建议改用可选择的官方下载源、固定模型 revision，并对运行时及全部权重做 SHA256 验证。当前 Qwen 音频权重脚本已有校验，但不能据此认定所有下载均已实现同等校验。

## 3. 建议接入模式

以下是基于当前架构的开发建议，并非现成开关。

| 模式 | 适用情况 | 建议处理方式 | 当前状态 |
| --- | --- | --- | --- |
| 全本地 | 私密素材、离线工作 | 转写、文本、视觉、音乐均本地执行 | 默认；音乐环境需另装 |
| 本地转写 + 云端文本 | 需要更强文本审阅或更快推理 | 本地保留音视频与逐词时间，只提交用户确认的文本片段 | 需要开发 |
| 自管本地服务 | 已有 llama.cpp / Ollama / LM Studio 服务 | 配置 Base URL、模型 ID 与能力，跳过应用自启服务逻辑 | 需要开发 |
| 自管局域网推理 | 多台机器共用算力 | 明确远程地址、认证、传输边界和排队机制 | 需要开发 |

推荐保留全本地作为默认，将“云端文本增强”作为显式可选项。转写和时间对齐继续在本机完成；大模型只提出候选编辑，最终时间区间由本地校验后应用。这样便于追溯，也避免模型自行编造切点。默认不要把音视频整段送到远端，更不要在本地请求失败时悄悄切到云端。

[llama.cpp 官方服务文档](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) 提供 OpenAI 兼容接口与多模态服务说明；[Ollama 兼容接口文档](https://github.com/ollama/ollama/blob/main/docs/api/openai-compatibility.mdx) 和 [LM Studio 本地服务文档](https://lmstudio.ai/docs/developer/core/server) 也提供可作为适配目标的接口。这只证明这些服务有相关能力，不意味着 CodeCut 已测试或直接支持它们。

## 4. 开发者应怎样扩展

### 配置与能力分离

增加统一的 Provider 配置，独立描述：服务类型、Base URL、模型 ID、密钥引用、是否由应用管理进程，以及文本、图片、结构化输出等能力。文本与视觉模型应分别配置；仅兼容文本 API 的模型不能自动替代 B-roll 视觉分析。

密钥保存在 macOS Keychain，项目文件只存非敏感配置引用。设置页应显示请求将发往本机、局域网或云端，并允许分别选择文本和视觉服务。

### 不要只替换 URL

现有 `AISettings.prepare()` 会调用 `LocalVLM.ensureServer()`；外部服务模式必须绕开本应用的运行时下载、自启及模型健康检查。现有非本地请求会添加 DeepSeek 特有的 `thinking` 字段；通用兼容服务需要独立参数适配，不能直接复用这一分支。

视觉调用也有自己的服务路径、图片格式和模型假设，需要单独适配。检查模型 ID、图片输入、上下文长度、JSON 支持、超时、取消和错误信息；“OpenAI 兼容”不保证每个参数与每个模型能力完全相同。

### 输出必须受本地数据约束

建议统一返回结构化编辑建议，包含词 ID、候选素材 ID、建议类型和原因。对返回值进行范围、存在性、时间顺序和重叠检查；拒绝不存在的词或素材。不合适的候选应允许返回空结果。应用修改仍经过既有撤销 / 重做与人工预览流程。

对重试、429、超时和无效 JSON 给出明确状态，避免重复应用编辑。云端模式只发送完成任务所必需的上下文；保存审阅记录时隐藏密钥与私密正文。

### 资源与验证

本地模型共享内存，应限制重型推理并发；当前 Qwen 音频与去人声互斥的设计可以作为参考。能力测试应涵盖文本连接、真实图片、结构化输出、取消、断网与失败恢复，不能以一次“回复 OK”代表完整兼容。

建议实施顺序：统一 Provider 配置 → 纯文本自管服务 → 显式云端文本增强 → 视觉服务适配 → 音频服务扩展。上线前补充对应测试，并更新 UI 的数据流说明。

## 5. 当前边界

本仓库尚未实现上述通用 Provider 界面或云端路由；没有直接集成商业视频生成 API。模型效果、运行内存和响应时间受片段长度、模型、硬件及同时运行的任务影响。有关第三方模型与运行时的许可应以对应上游仓库为准。
