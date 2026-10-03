# Meeting Assistant 开发规范

本文件是本仓库开发规范的唯一维护版本。README 说明"怎么用"，本文件说明"怎么开发"。

## 1. 项目概述

Meeting Assistant 是一个原生 macOS 浮动面板应用，在线上会议中实时辅助用户：

1. **实时转写**：采集系统音频（Zoom / Teams / Meet / 浏览器等），用 macOS 26 自带的 `SpeechAnalyzer` / `SpeechTranscriber` 在本机离线转写日语或英语
2. **逐段翻译**：每个定稿段落由 LLM 翻译成简体中文，显示在原文下方
3. **点名回答提示**：有人叫到用户的名字（如「セキさん」）时，顶部横幅提醒，等对方说完后流式生成"对方在问 / 要点 / 可以这样说"

### 明确不做

- 不引入后端进程、额外的语音模型（Whisper 等）或任何第三方依赖
- 不做远端说话人分离（只按音频来源区分「我」和「对方」，见 6.3）、录音音频存档、会议纪要生成（文字记录的本地历史属于转写和翻译的直接延伸，见第 10 节）
- 不增加额外的 LLM 调用（意图分类、转写纠错、路由、复核等）

新增功能前先判断是否属于上述三项能力的直接延伸；如果不是，先与用户确认。

## 2. 技术栈

- Swift 5 语言模式，SwiftUI + AppKit（`NSPanel`）
- CoreAudio Process Tap（系统音频采集）
- Speech：`SpeechAnalyzer` + `SpeechTranscriber`（macOS 26+，本机离线）
- OpenAI Chat Completions：用 `URLSession` 直连 HTTPS + SSE 流式，不使用 SDK
- Security（Keychain）、CryptoKit（prompt cache key 指纹）、Carbon（全局快捷键）
- 最低系统版本 macOS 26.0，开发工具 Xcode 27+

## 3. 目录结构

```text
MeetingAssistant.xcodeproj/        Xcode 工程；MeetingAssistant/ 是文件系统同步组，新增源文件不需要改 pbxproj
Config/Info.plist                  app 元数据与权限说明（不放在同步组内，避免被当作资源复制）
Config/MeetingAssistant.entitlements  hardened runtime 下使用麦克风所需的 audio-input 授权
MeetingAssistant/
  App/                             启动入口、AppDelegate（浮动面板、全局快捷键、隐身）、NonActivatingFloatingPanel
  Models/                          值类型：TranscriptionLanguage、TranscriptionState、MeetingTurn、MeetingRecord（历史记录）
  Services/                        系统音频与麦克风采集、转写、段落组装、提示词、知识库、OpenAI、Keychain、点名检测
  ViewModels/                      MeetingViewModel（面板唯一业务入口）、SettingsViewModel、HistoryViewModel（历史窗口）
  Views/                           ContentView、HistoryView 与 Components/
Checks/MeetingChecks.swift         纯逻辑检查（不属于 app target），由 scripts/check.sh 编译运行
knowledge/                         会议背景资料（运行时读取）
scripts/check.sh                   纯逻辑检查脚本
```

## 4. 架构与数据流

```text
系统音频（对方）                              麦克风（我，开麦时）
  → ProcessTapAudioCaptureService               → MicrophoneCaptureService（外放时开语音处理）
  （各自的专用串行音频队列，以下两路各一套，互不共享）
  → AudioFeed（音频队列内转换为 analyzer 格式）
  → SpeechAnalyzerEngine（volatile / final 结果，回到 MainActor）
  → SpeechTranscriptionService（判断停顿、请求 finalize）
  → TranscriptAssembler（段落规则，纯逻辑）
  → MeetingViewModel（两路段落按关闭顺序合并成一条时间线，MeetingTurn.isMine 标记来源）
       ├─ 新段落 → MeetingPrompts + MeetingKnowledge → OpenAIChatClient → 中文翻译
       └─ 对方段落点名命中（MeetingCallDetector）→ 等待停顿 → OpenAIChatClient → 回答提示
  → Views（ContentView / MessageBubble / ToolbarView / SettingsView）
```

## 5. 代码规范

### 5.1 MVVM 分层

- **Models**：只放值类型和枚举，不依赖 UI 框架，不调用系统 API
- **Services**：负责系统能力和业务逻辑（音频、语音、网络、文件、Keychain），不渲染 UI。可以独立测试的规则（段落组装、点名匹配、提示词拼装、SSE 解析、翻译清理）必须写成纯函数或纯 struct，并加入 `Checks/MeetingChecks.swift`
- **ViewModels**：View 唯一的业务入口，对外暴露可绑定状态和明确的用户意图方法（如 `toggleListening()`、`requestHintNow()`）
- **Views**：只负责布局与组合，不直接调用 Speech、CoreAudio、文件系统、网络或 Keychain；`body` 中不写业务逻辑。通用控件放入 `Views/Components/`

### 5.2 并发

- UI 状态、ViewModel 和转写状态机都标注 `@MainActor`
- CoreAudio IOProc、buffer 复制和格式转换只在专用串行音频队列执行，不得切到 MainActor
- 跨队列共享的可变状态必须用锁保护（参考 `AudioFeedSlot` 的 `OSAllocatedUnfairLock`）；`@unchecked Sendable` 只用于确实由单一队列或锁保护的类型，并在注释里写明保护方式
- 异步回调用 generation 计数丢弃过期结果（参考 `SpeechTranscriptionService.generation`）
- 可取消的工作用 `Task` 持有引用，替换或清空时先 `cancel()`

### 5.3 代码风格

- 代码注释一律用英文；注释解释"为什么"，不复述代码
- 命名遵循 Swift API Design Guidelines；类型名带职责后缀（`...Service`、`...ViewModel`、`...View`）
- 可调参数集中写成带注释的 `private let` 常量，不要把魔法数字散落在逻辑中
- 优先用标准库和系统框架，不为几行代码引入依赖；不写只有一个实现的协议或"为以后准备"的抽象
- 错误用遵循 `LocalizedError` 的枚举表达，`errorDescription` 要能直接展示给用户
- 不使用强制解包，只有编译期确定的常量可以例外（如固定的 endpoint URL）
- 日志用 `print("[TypeName] event key=value")` 格式，只记录事件和数量，不打印 API key 或完整转写文本

## 6. 音频与转写规则

### 6.1 采集

- Process Tap 固定使用 mono mixdown 和 private tap，并排除本 app 自身进程
- private aggregate device 在创建时必须一次性写入当前 system output 的 `MainSubDevice` / `SubDeviceList` 和完整 `TapList`（sub-tap UID 加 drift compensation）。禁止先创建空 aggregate 再挂 tap，否则可能只采到全零音频
- 输入 `AudioBufferList` 只能在同步回调内复制为自有 `AVAudioPCMBuffer`；复制前必须先设置 `frameLength`（初始的 `mDataByteSize` 为 0，会把音频复制成全零）
- 停止和失败清理的顺序固定为：`AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`。Start / Stop 重复调用不能残留 tap 或 aggregate device
- 采集故障回调用 `captureGeneration` 过滤：被替换或已停止的 aggregate 的 device-alive 回调可能晚到，不能让它停掉新的采集
- 麦克风开启了语音处理时，aggregate 改为只挂 tap、不挂输出设备（`anchorsToOutputDevice = false`）：语音处理会接管内置输出，挂在输出设备上的 aggregate 会整个停止回调。实测（macOS 26.6）只挂 tap 时能正常采到音频；关麦后恢复挂输出设备

### 6.2 段落组装（`TranscriptAssembler`）

- 实时行 = 本段已定稿文本 + 当前 volatile 文本。final 替换 volatile 时实时行不会倒退，不需要额外的防倒退逻辑
- **停顿关段**：识别 0.6s 没有更新，**并且**音频（`AudioLevelMeter`，RMS ≥ 0.005 视为有声）已安静 0.6s，才视为停顿；识别 3s 没有更新时不看音量直接视为停顿。只看识别更新的间隔不可靠：开启 `fastResults` 时 volatile 本来就约每秒才批量更新一次，实测因此切出过半句碎段。判定停顿后先请求 analyzer finalize（实测约 50ms 返回 final，analyzer 自己断句要约 2s），等 final 到达后再关段；1.5s 内没有 final，就只提交已定稿的部分，volatile 留在实时行
- **实测事实**：连续讲话时，SpeechTranscriber 的 volatile 文本会从这一段开头一直累积，可能几十秒都没有 final；volatile 结果整段只有一个时间范围，没有逐词时间（开启 `.audioTimeRange` 后只有 final 有逐字时间）。去掉 `fastResults` 后首个结果要约 11s，不能去掉
- **短段关段在文本层面完成**：volatile 文本中累计到 1–2 句（软上限：日语 40 字 / 英语 120 字），就把最后一个句末标点之前的内容提交为一段，并记下"已提交前缀"；之后同一段的 volatile 和 final 都先去掉这个前缀。识别器修订前缀中的词时，在目标长度 ±8 字内找最近的句末或逗号作为切点。一直没有句末标点的连续讲话，达到硬上限（软上限的 3 倍）后在最后一个逗号处切分
- **禁止在说话中途调用 `finalize(through:)` 来切段**：实测会把词切成两半（如「Aコネク。」），还会影响之后的识别质量；`finalize` 只用于停顿和手动请求
- 每段单独翻译，段落短才能让翻译及时、简短。**禁止按固定时长从句子中间切段**
- 有效字符不足 2 个的段落视为噪声，直接丢弃
- analyzer 必须带 `SpeechDetector`（VAD）：没有它时，finalize 之后的静音会稳定幻觉出「はい。」这类段落
- 手动请求回答提示时，先请求 finalize，最多等 1s 再关段。禁止直接把 volatile 文本提交成段落，否则它的 final 到达后会重复
- 停止监听或切换语言时，用 `flushAll()` 保留已听到的全部文本
- 修改上述任何规则时，必须同步更新 `Checks/MeetingChecks.swift`

### 6.3 麦克风（「我」的发言）

- 工具栏麦克风按钮控制，每次启动默认关闭；跟随收听开关：没在收听时切换只决定下次开始时是否开麦
- 「我」和「对方」各用一个 `SpeechTranscriptionService`（source 分别为 `.microphone` / `.system`），各自独立的 analyzer、分段和停顿判定；两边的段落按关闭顺序合并到同一时间线，`MeetingTurn.isMine` 标记来源
- 外放时（内置扬声器、HDMI/USB 等）开启 Apple 语音处理消除回声，other-audio ducking 固定为 `.min`。实测：不处理时扬声器回声被完整转写成"我"的话；开启后回声为 0 字，双讲时用户的话仍清楚。代价是会议声音被压低约 8 dB；默认 ducking 约 -30 dB，几乎静音，禁止使用；高级 ducking 没有改善
- 戴耳机（内置耳机孔、蓝牙）时不开语音处理，直接录原始麦克风，会议音量不受影响
- 语音处理的输入有多个声道，只取第 0 声道（处理后的人声）
- 点名检测只看对方的段落；回答提示里用户自己的段落以 `[Me]` 开头，提示挂在对方最新一段下面
- 「我」的段落不翻译（用户知道自己说了什么），但仍作为后续翻译的上下文
- `SpeechTranscriptionService.start()` 用 `startRequest` 令牌：等待权限或模型期间用户停止了，启动流程在每次 await 后发现令牌变化就退出，不会再打开采集
- 系统音频一侧停止或失败时，麦克风一起停（麦克风跟随收听）
- 麦克风收到 `AVAudioEngineConfigurationChange`（会议 app 接管麦克风、插拔耳机等）时，等 0.5s 后重新判断是否需要回声消除并重启；5s 内再次变化才关闭麦克风并提示

## 7. LLM 与提示词规则

### 7.1 调用

- 只通过 `OpenAIChatClient` 调用；每次请求只有一条 system message 加一条 user message
- 翻译默认用 `gpt-5.4-mini`（temperature 0.2，max 800 tokens）；回答提示默认用 `gpt-5.4`（temperature 0.4，max 900 tokens）。模型名可以在设置中修改，不得在 View 中写死
- 翻译请求按段落并发执行；回答提示同一时间只保留一个，新请求会取消旧请求
- 流式文本写入 UI 时节流到约 60ms 一次（`renderInterval`），结束时必须再写一次完整文本

### 7.2 Prompt Cache

- system prompt 只能依赖 knowledge 文件夹的内容，不能依赖当前请求（转写、语言、名字、时间都不行）；所有逐次变化的内容放在 user message
- `prompt_cache_key` 由模型名加 system prompt 指纹组成，不得加入逐次变化的值

### 7.3 翻译

- 附前 3 段作为只读上下文，只翻译 TARGET
- 采用简洁口译风格：去掉口头禅、重复和说错重来，保留全部实质内容（事实、数字、人名、请求、观点和理由）
- 末尾的半句不翻，由下一段补齐整句。翻译完成后用 `MeetingTranslationCleanup` 去掉"完整句之后、以省略号结尾的残句"
- partial（实时行）不做翻译

### 7.4 回答提示

- 输出格式固定：「对方在问」（中文）/「要点」（中文 2–3 条）/「可以这样说」（会议语言 1–3 句）
- 不得编造用户没有表态的事实、数字、决定或承诺；事实未知时，建议确认前提、提问澄清或会后跟进
- 对方问「有没有疑问 / 不明白的地方」时，基于整场转写指出 1–2 个值得确认的具体点（日期、数字、负责人、依赖），没有就简短致谢
- 如果只是在第三人称提到用户、并不需要回应，输出（无需回应）
- 从最新的段落往前发送，总长不超过 12000 字（约日语 35 分钟 / 英语 13 分钟），超出时丢弃最旧的段；至少保留最新一段。会议结尾的「有什么问题吗」需要整场内容作为上下文

### 7.5 点名检测（`MeetingCallDetector`）

- 用确定性的本地别名匹配，不调用 LLM
- 日语别名必须带敬称，避免「セキュリティ」「会議の席」这类普通词误触发；匹配前两边都去掉空白和连字符
- partial 命中只做提醒（横幅，不播放提示音：外放或共享电脑声音时会被会议里的人听到）；实际请求要等段落关闭（说话人已停顿）且约 0.3s 内没有新识别结果后才发出
- 点名段落不超过 10 字时（例如只有「セキさん、」），额外等待 1.5s，让问题本身先到
- 已处理过的点名不会重复触发；手动触发不受点名条件限制

## 8. 知识库规则

- `knowledge/*.md|txt` 按文件名排序完整注入 `[MEETING BACKGROUND]`，`README*` 除外
- `instructions.md` 作为 `[ADDITIONAL INSTRUCTIONS]` 追加到两套 prompt，用于不改代码地调整风格
- 每次请求都重新读取，修改后无需重启 app
- 内容越多，每次请求的成本越高。知识库只放会影响翻译或回答的信息，例如术语、人名、议题和可以对外说的事实

## 9. UI 规则

- 原则是低干扰、高密度、一眼能读完；工具栏保持单行，如果新增元素会降低读取效率就不加
- 对话采用 iMessage / LINE 风格：对方的发言是左侧灰色气泡，「我」的发言是右侧绿色气泡，回答提示是右侧蓝色气泡；气泡宽度随内容自适应，最多占可用宽度的 78%，随窗口变宽而变宽，禁止写死最大宽度；不显示 Speaker 这类角色标签
- 中文翻译属于原文的附属信息，放在发言气泡内的原文下方，用细线分隔。细线用 overlay 绘制，不能用 `Divider`：`Divider` 会撑满宽度，把每个气泡都拉到最大宽
- 自动滚动只用原生的 `defaultScrollAnchor(.bottom, ...)`（见 `FollowBottomScrollView`），禁止手写 `scrollTo` 来跟随底部；`.initialOffset`、`.sizeChanges`、`.alignment` 三个角色都必须设为 `.bottom`，缺少 `.alignment` 时内容第一次超出视口后就不再跟随
- 滚动容器外的条件性元素（如生成中的 `ProgressView`）必须常驻布局、用 opacity 隐藏；条件插入会改变容器高度，导致贴底失效
- partial 文本由独立的 `LiveTranscript` 对象驱动，避免每次 partial 更新都重绘整个列表
- 面板是 non-activating 的，点击不会抢走会议 app 的焦点；隐身默认开启（`sharingType = .none`，属于尽力而为）
- 「会议记录」历史窗口是普通窗口（主动打开时可以获得焦点），左侧按日期分组、可搜索原文和翻译，右侧复用面板的气泡组件；隐身设置同样作用于它

## 10. 安全与隐私

- 麦克风只在用户打开麦克风按钮时使用，不保存音频
- API key 只存 Keychain；开发时可以用 scheme 环境变量 `OPENAI_API_KEY`。不得写入文件、UserDefaults、日志或提交到仓库。`scripts/check.sh` 会扫描已跟踪文件中的 `sk-...`；scheme 是共享文件，不要把填了 key 的 scheme 提交上去
- 会议文字记录（原文、翻译、回答提示）由 `MeetingHistoryStore` 保存在 `~/Library/Application Support/MeetingAssistant/History/`，每场会议一个 JSON 文件。该目录在仓库之外，**禁止把记录写进仓库目录**
- 一场会议从"启动或清空后的第一段"开始，到下一次清空或退出时结束；进行中最多每 5 秒保存一次（节流而不是防抖，持续讲话时防抖会一直推迟写入），清空、退出和打开历史窗口时立即保存
- 删除记录一律移到废纸篓，不直接删除；不保存音频
- "复制"功能只在用户主动操作时写入剪贴板
- `knowledge/` 中真实的会议资料可能涉及保密信息，提交前要确认是否适合进入仓库

## 11. 验证要求

每次改动后至少完成：

1. `./scripts/check.sh` 通过
2. `xcodebuild -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -derivedDataPath .derived-data build` 成功，且无新增 warning
3. 涉及音频、转写或 UI 行为的改动，在 app 中实际验证：开始和停止可以重复操作、实时行正常出现、停顿后能生成新段落、翻译和回答提示正常流式显示、向上翻看历史时不会被拉回底部

验证结束后删除 `.derived-data/`；为验证临时启动的进程必须在任务结束前停止。无法实际运行验证的部分，要在交付时如实说明。

## 12. 文档与提交

- 结构或行为变更后，同步更新 README 与本文件
- 每次代码变更完成后先做 git 提交，再结束当前开发回合；按功能或修复的粒度拆分提交，不混入无关改动
- 提交信息用英文，采用 Conventional Commits 格式（`feat:` / `fix:` / `docs:` / `refactor:` 等）
