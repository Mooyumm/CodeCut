# CodeCut 功能与运行环境详解

本文保留实现细节与专项测试说明。首次使用请先阅读 [使用指南](USAGE.md)，AI 接入方案见 [AI 接入说明](AI_INTEGRATION.md)。以下本机实测数据只代表开发机结果，不构成性能保证。

## 音乐参考库

音乐列表右键「删除音乐…」可将当前参考库中的音乐副本、关联片段音频和批注一起移到系统废纸篓，删除前确认名称、片段数量及目录。原始导入来源文件、其他曲目／版本不受影响；废纸篓内附有 `deleted-track.json` 供恢复记录。删除去人声版本后，对原曲再次去人声会重新生成。正在导入、导出、分离、生成或迁移时禁用删除。导入和删除都使用「设置」中的参考库目录；尚未指定项目文件夹时仍使用系统默认目录。

原生版底部的「音乐参考」是跨视频项目保存的个人参考库：

1. 导入或拖入 NCM、MP3、WAV、M4A、AIFF 等音频。NCM 自动调用本机 AudioForge 解码：内含 MP3 时保留原始音频，其他支持的格式使用 FFmpeg 转为 320 kbps MP3。导入会复制音频到参考库，原文件不变，移动原曲不影响使用。
2. 空格播放／暂停，单击波形定位，按 I 设置入点、O 设置出点；可循环试听选区。编辑文字时这些按键不触发播放器。
3. 点击「确认片段」一次保存一个片段，同时写出 `Clips/<ID>/audio.m4a` 与 `annotation.json`。按 I 开始下一段，可保存多个重叠片段。
4. 左侧目录树统一整理音乐、片段与文件夹，整行（包括空白）均可点击选中，小箭头用于展开／收起。音乐和片段可拖到文件夹整行归档，文件夹可拖入其他文件夹形成多层级；拖到顶部「根目录」可移出。阻止移入自身／子目录及同名文件夹冲突。新建文件夹也可输入 `数码/思考`。片段右键菜单支持重命名、移到文件夹、删除记录（保留本地音频）。目录结构保存在索引中，音频采用稳定 ID 保存，不因拖放重复复制。
5. 批注区只保留一个输入框，自动保存；旧版的声音、避免项会合并到批注中。点击「AI 分类并生成提示词」整理用途与音乐提示词；结果在下方折叠区域查看、复制。批注改变后会提醒重新生成；「更多」支持批量生成及本地 AI 设置。
6. 「导出片段」输出裁好的 M4A、TXT 批注和 JSON。

「读取音乐」使用 Essentia 从选中片段的音频计算 RMS 电平、帧电平差、频谱重心，并在不少于 10 秒时估计 BPM／调性；结果和范围一起保存。Essentia 支持 1–600 秒片段，短片段或近静音会跳过不可靠的估计。范围改变后旧读取结果失效，改批注无需重新读音频。「AI 分类并生成提示词」会先读取缺失的音频特征和 Qwen 描述，再让现有本地语言模型结合特征与批注整理。Essentia 的特征提取不等于乐器／人声／情绪识别；BPM、调性和强度是算法估计，不是确定真值或概率。提示词整理模型不直接接收音频，编曲建议不代表原曲实测。读取结果和 AI 结果分开展示，批注仍是一个输入框。

Qwen2-Audio 接入：读取音乐会先计算 Essentia 特征，再调用独立 MLX 4-bit 音频模型生成中文声音描述。Qwen 实际读取所选片段的前 30 秒，界面明确标注覆盖范围；乐器、人声和情绪是模型推断，不是客观确认。生成提示词会自动补齐 Qwen 描述，并结合用户批注整理。运行时强制离线，不上传音频。每次分析使用独立子进程，完成、失败或取消后释放模型。

Qwen 运行期间自动暂停本程序的去人声队列：当前分离子进程被取消，等待它退出释放资源后才加载 Qwen。Qwen 结束后恢复队列；分离引擎没有断点功能，因此被中断的一首会从头重算。取消、失败也会恢复队列。不会暂停其他软件或终止其他本地 AI 服务。

独立环境：`~/Library/Application Support/CodeCut/Runtime/qwen-audio-env`；模型：同目录 `Qwen2-Audio-7B-Instruct-4bit`。MLX Audio 固定提交 `e66ad2ff4eb96ce1149000187b30370cbcd707aa`，模型固定提交 `c65570002626f41b4dc08b7b54f42f99f3e82e7f`。模型权重 6,562,540,479 字节，下载脚本 `../CodeCutMac/scripts/download_qwen_audio.py` 校验 SHA256。运行 `CODECUT_TEST_QWEN_AUDIO=/绝对路径/音乐.mp3 swift test --filter musicReferenceQwenActualAudio` 可验证真实音频；普通测试使用模拟分离任务检查暂停和恢复，不加载大模型。

本机 Qwen 依赖为 MLX 0.32.3、mlx-audio 0.5.8（上述提交）、Transformers 5.19.0；额外安装 `jinja2==3.1.6` 用于聊天模板。此环境不依赖 PyTorch 进行推理，Transformer 只负责离线处理器和分词；GPU 推理由 MLX/Metal 执行。不要把这些包装进 AudioForge 或 Essentia 环境。

适配器使用模型官方 `WhisperFeatureExtractor`（Slaney mel）替代该固定 MLX 提交的手写 HTK mel 前端；并在进入无 padding mask 的 MLX 音频编码器之前裁去短片段的补零帧，按有效长度生成音频 token。此修改只在本程序分析子进程中绑定，不改第三方安装文件。M4/16GB 对 14 秒真实音乐的首轮修正后测试：全流程约 9.4 秒，Qwen 加载和推理约 7.4 秒，MLX 峰值约 7.2GB（非全系统内存，耗时随输入与系统负载变化）。

Essentia 使用独立 Python 环境，不修改 AudioForge 的依赖。在本机安装：

```sh
~/.audioforge/venv/bin/python3 -m venv "$HOME/Library/Application Support/CodeCut/Runtime/essentia-env"
"$HOME/Library/Application Support/CodeCut/Runtime/essentia-env/bin/python3" -m pip install --only-binary=:all: 'essentia==2.1b6.dev1389'
```

其他账户需替换用户名路径；运行时按当前用户目录定位。音频由现有 FFmpeg 裁剪、重采样为单声道 44.1 kHz，仅在本地临时目录分析，结束后清理临时文件。无云端上传。依赖项目与许可见 [Essentia](https://github.com/MTG/essentia)，发布软件前应核对第三方许可要求。测试：`CODECUT_TEST_ESSENTIA=1 swift test --filter MusicReference`；设置 `CODECUT_TEST_FEATURE_AUDIO` 为真实音乐绝对路径可额外实测前 20 秒。

去人声时底部显示任务曲名、阶段、已用时和模型分离的真实进度条／百分比。加载模型时显示不确定进度；百分比达到 100% 仅表示模型计算完成，仍会明确显示保存、验证阶段，实际入库成功后才提示完成。进度来自本地引擎日志，不按时间模拟；取消或失败不会继续推进进度。

播放器右上角「去人声」调用本机 AudioForge 的 BS-Roformer 模型处理整首音乐，输出独立的 320 kbps MP3 伴奏并切换试听。原曲、原片段与批注保留；伴奏可重新选段建档。重复点击原曲的按钮会复用已有伴奏，不重复处理。状态栏可取消，失败不会覆盖原音频，处理期间不能迁移参考库。需要 `~/.audioforge/venv/bin/audio-separator`、FFmpeg 和 `~/.audioforge/models/` 中的模型就绪；不自动安装或下载模型。分离可能有残留或音质变化。设置 `CODECUT_TEST_SEPARATION=1` 可运行真实本地模型的短音频集成测试。

NCM 转换复用已有 AudioForge.app 的 `ncm_decode_cli.py` 和 `ncm_decoder.py`，不联网、不启动分离模型。优先查找 `/Applications/AudioForge.app`、`~/Applications/AudioForge.app`，再查找本机原有的 `~/Documents/Codex/2026-08-23/gei-w/outputs/AudioForge.app`。Python 和 FFmpeg 优先使用 `~/.audioforge/venv/bin/`。组件缺失、文件损坏或转换失败会逐文件报错，其他文件继续导入。真实 NCM 集成测试可设置 `CODECUT_TEST_NCM=/absolute/path/sample.ncm`，测试仅使用临时参考库并检查原文件未改变。

默认存储位置：`~/Library/Application Support/CodeCut/MusicReferences/`。在音乐参考页「设置 → 更改位置」选择项目文件夹，会在其中新建 `MusicReferences` 并复制整个参考库；切换成功后记住新位置，原目录保留备份、不再同步。不覆盖已有的目标文件夹。参考库独立于视频项目；`Audio/` 保存音乐、`Clips/` 保存新确认的片段音频与批注、`library.json` 保存索引，`library.backup.json` 保留上一份索引。旧片段的时间范围和原曲仍保留，可使用「导出片段」取得独立音频。读取损坏时尝试恢复备份；主档和备份都不可读时停止写入，避免覆盖。

使用 `open -a /path/to/CodeCut.app --args --music-reference` 可直接进入音乐参考库，不恢复视频项目。界面验证可通过环境变量 `CODECUT_MUSIC_REFERENCE_ROOT` 指定独立测试库。运行专项测试：`cd CodeCutMac && swift test --filter MusicReference`；真实模型验证额外设置 `CODECUT_TEST_MUSIC_MODEL=1`。

## 旧 Web 原型（保留）

无需安装依赖：

```bash
npm start
```

浏览器打开 `http://localhost:5173`。当前版本跑通导入、字幕校对、口误取舍、删气口与 FCPXML 导出；字幕分析暂用可编辑演示结果，下一步把 `analyze()` 接到 Whisper 即可获得真实转写。
