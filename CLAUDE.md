# Meeting Assistant 开发规范

## 1. 产品范围

原生 macOS 会议助手，只做三件事：

- 通过 CoreAudio Process Tap 采集系统音频，用 macOS 26 `SpeechAnalyzer` / `SpeechTranscriber` 做本机实时转写（日语 / 英语）
- 每个定稿段落用 LLM 翻译成简体中文
- 有人点名用户时，生成回答提示

不引入后端进程、额外语音模型（Whisper 等）或第三方依赖。LLM 只通过 `OpenAIChatClient` 直连 OpenAI。

## 2. 目录结构

```text
MeetingAssistant.xcodeproj/        Xcode 工程（MeetingAssistant/ 是文件系统同步组，新增文件无需改 pbxproj）
Config/Info.plist                  权限声明与 app 元数据
MeetingAssistant/App/              启动入口、AppDelegate、浮动面板
MeetingAssistant/Models/           值类型
MeetingAssistant/Services/         音频、转写、提示词、OpenAI、Keychain 等
MeetingAssistant/ViewModels/       MeetingViewModel（唯一业务入口）、SettingsViewModel
MeetingAssistant/Views/            页面与 Components/
Checks/MeetingChecks.swift         纯逻辑检查，由 scripts/check.sh 编译运行
knowledge/                         会议背景资料
```

## 3. MVVM

- Models 只放值类型；Services 负责系统能力与业务逻辑，不渲染 UI
- View 只依赖 ViewModel，不直接调用 Speech、CoreAudio、文件系统或网络
- partial 文本放在独立的 `LiveTranscript` 对象中，避免每次 partial 更新重绘整个列表

## 4. 音频与转写

- Process Tap 固定使用 mono mixdown、private tap、private aggregate device，并排除本 app 进程
- aggregate device 创建时必须一次性写入当前 system output 的 `MainSubDevice` / `SubDeviceList` 和完整 `TapList`
- IOProc 跑在专用串行音频队列；输入 buffer 只在同步回调内复制为自有 buffer，复制前先设置 `frameLength`
- 停止顺序固定：`AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`
- 格式转换在音频队列内由 `AudioFeed` 完成，不得进入 MainActor
- 段落规则集中在 `TranscriptAssembler`（纯逻辑，有检查覆盖）：
  - 实时行 = 本段已定稿文本 + 当前 volatile 文本，final 替换 volatile 时不会倒退
  - 1.2s 无识别更新视为停顿：先请求 analyzer finalize，等 final 到达后再关段；1.5s 内没有 final，就只提交已定稿部分，volatile 留在实时行
  - 长段只在 final 到达时关闭：达到软上限（日语 120 字 / 英语 320 字）且以句末标点结尾，或达到硬上限（软上限 2 倍）。禁止按固定时长从句子中间切段
  - 有效字符不足 2 个的段落视为噪声，丢弃
- 手动请求回答提示时，先请求 finalize 并等待最多 1s 再关段；禁止直接把 volatile 文本提交成段落，否则它的 final 到达后会重复

## 5. LLM

- 翻译默认 `gpt-5.4-mini`，回答提示默认 `gpt-5.4`，都可以在设置里修改
- system prompt 只依赖 knowledge 文件夹，不依赖当前请求，保证 OpenAI 前缀缓存可复用；每次请求只在 user message 中变化
- 翻译：附前 3 段作为只读上下文；末尾半句不翻、由下一段补齐；翻译完成后用 `MeetingTranslationCleanup` 去掉"完整句之后以省略号结尾的残句"
- 回答提示格式固定：对方在问（中文）/ 要点（中文 2–3 条）/ 可以这样说（会议语言 1–3 句）；不得编造用户未表态的事实、数字或承诺
- 点名检测（`MeetingCallDetector`）是确定性的本地别名匹配；日语别名必须带敬称；partial 命中只做提醒，等说话人停顿后再请求；过短的点名段落额外等待 1.5s
- 翻译请求按段落并发；回答提示同一时间只保留一个
- 不得增加额外的 LLM 调用（分类、纠错、路由等）

## 6. 知识库

- `knowledge/*.md|txt` 按文件名排序完整注入，README 除外，每次请求重新读取
- `instructions.md` 作为附加指令追加到两套 prompt

## 7. 安全

- API key 只存 Keychain（开发时可用 scheme 环境变量 `OPENAI_API_KEY`），不得写入文件、UserDefaults 或日志
- 日志不得打印 API key 或完整转写内容

## 8. 验证

每次改动后至少运行：

- `./scripts/check.sh`
- `xcodebuild -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -derivedDataPath .derived-data build`

验证结束后删除 `.derived-data/`。为验证临时启动的进程必须在任务结束前停止。

## 9. 文档与提交

- README 说明怎么用，CLAUDE.md 说明怎么开发；结构变更后同步更新
- 代码注释用英文
- 每次代码变更完成后先做 git 提交，按功能拆分提交
