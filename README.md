# 听阅

听阅是一款面向 Mac 的本地音频阅读与整理工具。将课程、会议、访谈和个人录音转成可搜索的文字，点击句子即可回听；也可接入自己的大模型接口，对资料提问、总结或修订正文。

支持 **Apple Silicon Mac、macOS 14 及以上**。语音转写、说话人区分和智能标点在本机运行，模型准备完成后可离线使用。AI 助手为可选功能。

## 核心功能

- **本地转写**：支持 MP3、M4A、WAV、FLAC，按队列处理，可指定说话人数、重新转写和切换版本。
- **阅读与回听**：按连续发言分段，点击句子定位音频；支持播放高亮、倍速、中文跨句搜索和阅读排版。
- **校对与整理**：修改文字和发言归属、合并说话人、批量标记核对状态，保留识别原稿，支持撤销与重做。
- **听阅助手**：围绕所选资料问答、汇总问题、整理正文，提供来源定位、修改差异和整次撤销。
- **材料与记忆**：导入和编辑 TXT/Markdown 个人材料，管理长期记忆，按资料日期汇总面试周报；支持关键词检索和可选的本地语义检索。
- **导出与扩展**：导出纯对话 TXT、带时间范围的 TXT 和 SRT，可配置外部 MCP 服务扩展助手工具。

## 安装与运行

### 从源码构建

准备 Apple Command Line Tools（Swift 5.9+）、Python 3.12+、CMake 和 `uv`，然后执行：

```sh
git clone https://github.com/HsxDeGitHub/audio_manager.git
cd audio_manager
python3 Scripts/bootstrap.py
zsh Scripts/package.sh
open dist/听阅.app
```

构建脚本会准备语音处理工具，并将 Python 3.12 后端运行时打包到应用中。构建后的应用运行时无需系统 Python 或 `uv`，本地业务服务随应用自动启停。

首次构建和下载模型需要网络。Whisper large-v3 模型约 **3.1 GB**，其他模型、运行依赖和构建缓存还需额外空间。应用使用本地 ad-hoc 签名，当前未提供开发者证书、公证和在线自动更新。

### 首次使用

1. 打开应用，在“模型设置”中下载、导入模型，或选择已有模型目录。
2. 导入音频或将文件拖入窗口，模型就绪后自动开始处理。
3. 点击正文句子回听，用顶部搜索查找内容；右键校对文字，在“说话人”面板调整归属或合并标签。
4. 通过“排版”调整阅读样式，通过“导出”保存文字或字幕。TXT 沿用当前阅读排版，SRT 保留片段文字和时间轴。

<details>
<summary>模型文件说明</summary>

应用下载或导入模型时会校验 SHA-256；模型放在独立目录，无需放入应用包。

| 文件 | 用途 |
| --- | --- |
| `ggml-large-v3.bin` | Whisper large-v3 语音转写 |
| `ggml-silero-v6.2.0.bin` | 语音活动检测 |
| `segmentation.onnx` | 说话人分段 |
| `3dspeaker.onnx` | 声纹聚类 |
| `punctuation.int8.onnx`（可选） | 本地中英混合智能标点，约 76 MB |

也可在项目根目录运行 `python3 Scripts/download_whisper.py` 预下载 Whisper，其余模型在应用内准备。

</details>

## 使用听阅助手

1. 齿轮菜单 → **大模型配置…**，填写接口地址、模型名称和 API Key。支持 OpenAI 兼容的 `chat/completions` 接口，例如 `https://服务地址/v1`；本机免认证服务可留空 Key。
2. 点击“检测模型能力”，查看文本、JSON、工具调用和流式协议支持情况，再保存配置。
3. 按 `⇧⌘A` 展开助手，确认资料范围后输入要求；也可选中正文或个人材料中的文字，点击“添加到对话”。

例如：

- “列出这次面试的全部问题，并给出每道问题的原文来源。”
- “直接整理当前正文，去掉口语赘词，改善断句，保留技术细节和原意。”
- “只分析所选回答的问题，给出建议，不要修改正文。”
- “结合本周已标注日期的面试，汇总重复问题和待补充知识点。”

回答可返回来源或定位回听。正文修改保留识别原稿和音频时间轴，可查看差异，并通过“修改记录与撤销…”撤销整次操作；纯总结、建议和明确只读的请求不会修改正文。

输入框中 `Enter` 发送、`Shift+Enter` 换行，生成期间可停止；会话名称旁的“话题管理”（⋯）支持重命名和删除。

## 数据隐私与主要限制

- **音频在本机处理**：语音转写、说话人区分和智能标点不上传录音；原音频只引用原文件，移除资料库记录不会删除音频。
- **助手按配置连接模型服务**：使用助手时，会向所配置的服务发送任务所需的文字、来源和要求；模型能力检测仅发送合成消息。
- **资料保存在本机**：默认目录为 `~/Library/Application Support/InterviewAudio/`，更新应用沿用已有资料和配置。备份前先退出应用，并保留原音频。
- **密钥保存在配置文件**：`llm-settings.json` 含明文 API Key，权限为 `0600`，仅当前用户可读写；密钥不写入正文、导出或诊断日志。

自动说话人标签代表声音聚类，不能直接当作真实身份。识别和模型回答可能有误，重要内容需结合原稿与录音核对。可选语义检索需在“工具与 MCP…”中准备模型，未准备时使用关键词检索。

## 开发

界面使用 SwiftUI，语音处理使用 whisper.cpp、sherpa-onnx 和 FFmpeg，本地业务后端使用 FastAPI、SQLite 和 LangGraph。

| 路径 | 内容 |
| --- | --- |
| `Sources/` | SwiftUI 应用、音频后台进程及阅读、校对、导出逻辑 |
| `backend/` | 本地业务服务、Agent、检索、MCP 和后端测试 |
| `Tests/` | Swift 自动测试 |
| `Scripts/` | 工具准备、模型下载、打包与检查脚本 |

在项目根目录运行测试：

```sh
uv sync --project backend --frozen --all-extras --group dev
uv run --project backend --frozen --all-extras --group dev pytest backend/tests -q
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFT_MODULECACHE_PATH="$PWD/.build/swift-module-cache" \
swift test --disable-sandbox --cache-path .build/cache
```

后端开发依赖安装到 `backend/.venv`。只需关键词检索时，可用 `PACKAGE_EMBEDDINGS=0 zsh Scripts/package.sh` 打包，省去本地语义检索依赖。固定提示词的维护方法见 [提示词管理](backend/src/interview_backend/prompts/README.md)。

## 许可说明

本仓库暂未包含项目自身的 `LICENSE` 文件。第三方组件与模型的来源及许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。
