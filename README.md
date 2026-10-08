# 面试音频

在 Mac 本机把中文面试录音转成可搜索的文字，点击片段即可回听。音频只引用原文件；语音转写与说话人区分均在本机执行。

## 使用

1. 打开 `dist/面试音频.app`。
2. 首次使用检查“模型设置”。本项目已下载模型时，应用会使用旁边的 `dist/Models`；也可选择任意模型目录，或在应用内下载/导入模型。
3. 导入 MP3、M4A、WAV、FLAC，或把文件拖入窗口。模型就绪后自动按队列处理。
4. 用顶部搜索框搜索当前录音或全部录音，点击搜索结果或片段时间回听。播放从该片段前一秒开始，可调倍速并开启跟随播放。
5. 点击铅笔修改文字；通过片段的说话人菜单纠正归属，通过“说话人名称”统一改名。修改后自动保存，时间戳保持原样。
6. 通过“导出”保存带时间和说话人的 TXT 或 SRT。

说话人数默认自动估计；知道人数时可在处理前指定。跨说话人边界或未匹配到说话人的片段显示“待核对”。自动标签仅代表同份录音内的声音聚类，不自动判断面试官/候选人身份。

原音频被移动后，可通过播放器的“重新定位文件”选择原文件；程序校验内容相同后继续使用已有文字。移除资料库记录不会删除原音频。

重新转写创建新版本。如果旧版本有文字纠错、归属纠正或说话人改名，保留旧版本为当前版本；可在版本菜单切换。说话人区分失败时文字仍然可用，可单独重试。关闭窗口后应用可继续处理，退出应用后未完成的任务显示中断，需手动重试。

## 环境与本地数据

- 当前交付面向 Apple Silicon Mac，macOS 14 或更高版本。
- Whisper large-v3 模型约 3.1 GB；另有约 1 MB 的 Silero VAD 模型和两个本地说话人模型。首次下载需要网络，模型准备完成后可离线使用。
- 转写使用 whisper.cpp 1.9.5 / Metal；说话人区分使用 sherpa-onnx 1.13.8 / CPU；格式转换使用 FFmpeg。
- 默认数据位置：`~/Library/Application Support/InterviewAudio/`。SQLite 保存资料库、文字、说话人名称和播放位置，`settings.json` 保存模型目录。
- `INTERVIEW_AUDIO_DATA_DIR` 可指定独立的数据目录，用于开发与验收。
- 应用不会建立 HTTP 服务，不会上传录音，不含账号、云端识别或遥测。

把应用单独移到其他位置后，可在模型设置中重新选择本项目 `Models` 目录；模型不必随应用复制。

## 构建

本机需安装 Apple Command Line Tools、Python 3.12+ 和 CMake。项目不依赖第三方 Swift 包或完整 Xcode。

```sh
python3 Scripts/bootstrap.py
python3 Scripts/download_whisper.py
zsh Scripts/package.sh
```

`bootstrap.py` 下载固定版本工具到 `.runtime/`，构建启用 Metal 的 whisper.cpp，并准备 ARM64 FFmpeg / sherpa-onnx。`package.sh` 构建 Swift 程序，打包并进行本地 ad-hoc 签名；这是个人本机交付，不包含开发者证书或公证发布。

完整模型目录需要：

| 文件 | 用途 |
|---|---|
| `ggml-large-v3.bin` | Whisper large-v3 转写 |
| `ggml-silero-v6.2.0.bin` | 检测语音，过滤非语音片段 |
| `segmentation.onnx` | pyannote segmentation 3.0 |
| `3dspeaker.onnx` | 中文 ERes2Net 声纹模型 |

应用下载和导入模型时进行 SHA-256 校验；安装的模型必须与固定版本一致。第三方组件来源见 `THIRD_PARTY_NOTICES.md`。

识别不使用指令式提示语，避免模型在弱语音区域重复提示语。Whisper 的内置 VAD 保留到原音频的时间映射。说话人分段使用 50% 窗口重叠、自动聚类阈值 0.8；这些默认值经过官方中文四人样本验证，其他录音仍可手动指定人数和纠正标签。

## 验证

```sh
swift test --disable-sandbox --cache-path .build/cache
python3 Scripts/test_worker.py
```

准备好实际录音验收产物后，可选择运行本地实际样本检查：

```sh
INTERVIEW_ACTUAL_TEST_DIR="$PWD/TestArtifacts" swift test --disable-sandbox --cache-path .build/cache
```

该检查使用完整录音的说话人结果，以及开头、中段、结尾的转写摘录，验证原文件未变化、原音频时间位置、中文搜索和 TXT/SRT 导出。输出标题明确标注“非完整转写”，不把测试摘录当作整段转写交付。

核心测试覆盖中文单字/子串与字面符号搜索、毫秒时间戳、长音频偏移、SRT 输出、人工纠错保护、资料库恢复及文件内容校验。进程集成测试覆盖转换/识别顺序、转写检查点、说话人阶段失败，以及取消后停止子进程和清理临时文件。

实际录音测试产物保存在忽略版本控制的 `TestArtifacts/`。识别准确率和耗时取决于录音质量、术语、插话与设备负载；结果保留原稿并允许人工核对，不预设准确率。
