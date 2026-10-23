# 模型提示词管理

这里是项目固定模型提示词的唯一源目录。Python 后端与 Swift 客户端都从这里读取所需资源；不要在调用代码中复制一份提示词。

| 文件 | 用途 | 调用位置 |
| --- | --- | --- |
| `agent/system.md` | 听阅助手的事实、来源、修改、工具与输出规则 | `agent/graph.py` |
| `memory/extract.md` | 从当前用户陈述提取个人事实与偏好 | `agent/memory.py` |
| `connection/text-system.md` | 文本连接测试的系统消息 | `Sources/AudioCore/AIConnectionClient.swift` |
| `connection/text-user.md` | 文本连接测试的用户消息 | 同上 |
| `connection/tool-user.md` | Python 工具调用连接测试 | `agent/models.py` |
| `tools/descriptions.json` → `tools` | 17 个本地业务工具、连接自检工具与外部工具默认描述 | `tools/catalog.py`、`agent/tools.py`、`agent/models.py`、`tools/mcp_client.py` |
| `tools/descriptions.json` → `fields` | 本地工具参数说明 | `tools/catalog.py` |

## 修改方法

- Markdown 文件只放实际发送的文字，不添加说明标题或代码围栏。读取时仅去掉文件末尾的一个换行，其余内容原样保留。
- JSON 使用 UTF-8；保持工具 ID 和字段名不变，只修改对应说明。增加工具时，先增加描述，再在工具注册处调用 `tool_description(...)`；参数说明调用 `field_description(...)`。
- 新增后端文本时调用 `interview_backend.prompt_catalog.load_text('用途/文件.md')`。新增 Swift 资源时，同时更新 `Package.swift` 中 `PromptResources` 的资源清单及 `PromptResources.swift` 的读取接口。
- 不在资源中放入密钥、录音、转写或个人资料。当前用户指令、历史、证据、范围、记忆和工具结果由调用代码按结构组装，不使用字符串模板替换，也不把资料中的指令当作授权。
- 缺失文件、空文本、JSON 格式错误或未知描述键会报错；没有代码内置的备用提示词。

## 运行与发布

开发时修改后重启后端；Swift 端重新构建。Python 加载器缓存固定资源，助手系统消息和工具 Schema 也会在进程内保留，因此不支持运行中热更新。

Python 使用 `importlib.resources` 读取随包文件，wheel 自动携带 Markdown/JSON，排除 Swift 加载器。SwiftPM 的 `PromptResources` 目标直接复用本目录中的 `connection/`，`Scripts/package.sh` 将对应资源 bundle 复制到 `.app/Contents/Resources/`。发布应用修改提示词后需要重新打包，不编辑应用包里的生成副本。

界面中的示例提问是普通 UI 文案；第三方 MCP 返回的工具描述在运行时读取。两者不作为这里的固定模型提示词。

## 验证

```sh
backend/.venv/bin/python -m pytest backend/tests/test_prompt_resources.py backend/tests/test_tool_adapters.py -q
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/swift-module-cache" swift test --disable-sandbox --cache-path .build/cache --filter AISettingsAndLegacyDraftTests
UV_CACHE_DIR="$PWD/.build/uv-cache" uv build backend --offline --wheel --out-dir .build/prompt-wheel
```

上述命令从项目根目录执行，只使用合成模型与临时资料；不代表真实模型回答质量验收。
