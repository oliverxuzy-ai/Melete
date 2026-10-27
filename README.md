# Melete 口述练习

给 business communication 练习用的本地 Mac App。每天给你准备好一到两段演讲片段和一道为你定制的即兴题，按一个键就开始录，本地 Whisper 转写，算出语速、停顿、填充词、音高起伏，再给一句最该改的点评。所有录音和数据只在本机。

设计语言和每个决定的理由见 [docs/DESIGN.md](docs/DESIGN.md)。

## 安装

```sh
./build_native.sh --install
```

会打包 `dist/Melete.app` 并装到 /Applications，替换旧的 SpeechPractice.app。Bundle ID 没变，历史记录、练习和设置都会保留。App 正在运行时脚本会拒绝安装，先退出再装。需要 Xcode 26。

每日片段需要本机有 yt-dlp 和 ffmpeg：

```sh
brew install yt-dlp ffmpeg
```

## 每天怎么用

一个窗口，三个地方，顶部中间的胶囊切换：

- **总览**：本周的桂冠居中，左边是自己讲的表现走势（语速、填充词、音高起伏、要点覆盖），右边是节奏（这周每天几分钟、连续天数、下一场要讲的会）。下面是两扇门（跟读、主题），再往下是每一次的结论、周小结和这一年的练习点阵。
- **跟读**：先听别人怎么讲，再跟着讲，或者听完用自己的话复述。讲台在中间，底下的素材架放今天的片段和片段库。左边按钮只管原文（听原文、暂停、继续听），中间按钮只管录你（开始跟读或开始复述）；原文放完不会自己开录。点左边原文的任意一句，就从那一句开始听。用扬声器外放时，跟读录音期间原声不放（免得麦克风把原声录进去），字幕跟着你的声音走：本机实时识别你读到哪个词（用最快的听写识别器，约 0.3 秒），一句还剩一个词时就滚到下一句，按你自己的速度读；跟丢了点一下你读到的那句。戴耳机时原声在耳机里同步播放，字幕跟原声。
- **主题**：围绕一个题目、讲稿或要讲的会，自己讲。素材架放今天的即兴题、讲稿和议程。

1. 打开 App 停在总览。按回车，直接进入今天下一项所在的那一边，水钟注满三秒后自动开始录音。
2. 再按空格停止。讲完出现点评卡：一句结论，几个这个训练块关心的数字，最多三条下次怎么改。“下一项”直接进入下一段。讲到一半不满意，点“放弃这段”或按 Esc，这一段不保存也不分析。
3. 一次录音的完整分析、讲稿编辑、全部记录、设置，都升起一个四边完整的面板，看完按 Esc 收起，回到原来的地方。设置一次只显示一个分区。

完成任意一项就算今天练过。别的入口：

- 任何应用里按 ⌃⌥R：直接开始今天的下一项。
- 菜单栏的桂冠图标：看今天的计划，一键开始。
- ⌘R 开始或停止，⌘1 到 ⌘3 切换 总览、跟读、主题，⌘4 全部记录，⌘N 新讲稿，⌘, 设置。

分析服务在后台启动，不再挡住窗口。服务还没好时也可以录，录完的音频先存起来，服务好了自动分析。

## 功能

- **训练周期**：九周一个循环，语速与音量两周，语调与停顿两周，讲故事两周，看对象换说法两周，减量一周。目标从你自己最近的录音算出来，不是通用标准。可以在设置里固定在某一块。
- **每日片段**：每天清晨从演讲和讲座里挑片段，讲故事的用来跟读，讲道理的用来复述。也可以在跟读的素材架上点“贴链接”（YouTube 链接，带 `&t=` 就从那里截），马上做成片段。
- **即兴题库**：按古希腊修辞学校的练习形式（叙事、引申、描述、比较、立论、换对象、致谢、反驳、答问、汇报）写的题目，内容来自你真实会讲的话题：事故复盘、内部工具推广、数据平台、semantic layer、成本评审、站会汇报、面试问题。
- **议程**：把要讲的场合加进来（架构评审、1:1、onsite、面试），从那天往前倒排六步备讲，像比赛前的减量。
- **周小结**：每周一份给自己看的小结：练了几天、哪些指标变了、下周练什么。
- **提醒**：Mac 通知（设置里打开），可选推到手机（ntfy.sh，免费）。
- **跟读和要点覆盖**：原有功能都在。跟读可以 0.8 到 1.0 倍速，复述按意思算要点覆盖，不按逐字。

## 可选：Claude

设置 > Claude（可选）。填上 Anthropic API key 以后，每天一次请求，Claude 从规则挑出的候选段落里选最合适的一段，写一个中文标题和两条“注意他怎么停顿、重读哪里”。默认 Claude Opus 5.5，可以换 Sonnet 5.5 或 Haiku 5.5。不开也完全能用，请求失败时自动退回本机规则。Key 只存在本机的 `settings.json`（权限 600）。

## 开发模式

```sh
./run.sh            # 或 .venv/bin/python server.py
```

调试参数（对 `dist/Melete.app/Contents/MacOS/SpeechPractice`）：

- `SPEECH_SERVER_URL=http://127.0.0.1:8765` 连开发服务而不拉子进程。
- `--space home|shadow|topic` 直接打开某个地方，`--tray settings|history|clips|agenda|newTopic|newEvent|addLink` 直接打开某个抽屉。
- `--selftest` 解析所有接口然后退出。
- `--render <目录>` 用离屏渲染把各个地方画成浅色和深色的 PNG 然后退出，用来审视设计（`RENDER_ONLY=home,settings` 只画其中几张）。需要用 `open` 启动（直接执行二进制时 SwiftUI 不开主窗口）：`open -n --env SPEECH_SERVER_URL=http://127.0.0.1:8765 dist/Melete.app --args --render /tmp/render`
- `--e2e <报告>` 端到端测试：用 `MELETE_FAKE_MIC=<wav>` 代替麦克风，走真实的上传、转写和点评，逐项写 PASS 或 FAIL，包括录音时的帧间隔。`--perf <报告>` 只测说话时的帧率。都要指向一份数据副本的服务。

服务端的环境变量：`SPEECH_DATA_DIR` 换数据目录（测试时用一份副本），`SPEECH_NO_DAILY=1` 关掉每日片段的后台任务，`DAILY_START_DELAY` 改后台任务启动前的等待秒数（默认 120）。

离线测试片段流水线：`.venv/bin/python daily.py --local 音频文件 "标题" "说话人" story`

## 模型

英文用 Whisper `small`（约 500 MB，60 秒录音约 8 秒出结果），启动时预热。中文用 `large-v3-turbo`（约 1.6 GB），第一次录中文时才加载，平时不占内存。

为什么分开：small 对普通话不稳定，会掉句、混入繁体和乱码；turbo 稳定且更准。英文没有用 turbo，是因为它会把 like、um 这类填充词吞掉，而 small 会保留。

想换：`WHISPER_MODEL=medium ./run.sh` 改英文模型，`WHISPER_MODEL_ZH=medium ./run.sh` 改中文模型。

## 指标说明

| 指标 | 含义 |
|---|---|
| 语速 | 总词数 / 总时长。目标带由你自己的基线算出，语速块里每周上调 |
| 去掉停顿后的语速 | 词数 / 实际开口时间 |
| 停顿 | 相邻两个词之间间隔 ≥ 0.5 秒 |
| 填充词 | um / uh / like / you know / I mean / basically 等 |
| 弱化 / 犹豫用语 | maybe / I think / just / kind of 等 |
| 音量 | 只和你最近五次录音比，因为分贝的绝对值取决于麦克风和距离 |
| 音高起伏 | 粗略的基频范围（半音）。太小可能是语调单一 |
| 要点覆盖 | 原文按句拆成要点，按意思判断讲到、部分讲到、没讲 |

指标都是启发式的自我追踪数据，不是专业测量。填充词和弱化词列表在 `analysis.py` 顶部，同时镜像在 `native/Sources/SpeechPractice/SessionDetailView.swift` 和 `static/index.html`，改的时候一起改。

## 文件

- `native/`：SwiftUI App。`Theme.swift` 是设计令牌，`Components.swift` 是水钟、桂冠、语速刻度等组件，`Controls.swift` 是表单控件。`RootView.swift` 是窗口和顶部导航，`HomeView.swift` 是总览，`StudioView.swift` 是跟读和主题两个工作室，`Stage.swift` 是讲台的状态和点评卡，`Trays.swift` 是底部抽屉，`SettingsPanel.swift` 是设置。`SystemIntegration.swift` 是通知、全局快捷键、开机启动和菜单栏，`E2E.swift` 是端到端测试。
- `server.py`：FastAPI 服务。
- `coach.py`：训练周期、目标、题库、今日计划、议程、点评、周报。
- `daily.py`：每日片段流水线和后台任务。
- `analysis.py`：转写与指标计算。`coverage.py`：要点覆盖。`shadow.py`：跟读字幕对齐。
- `build_assets/AppIcon.icon`：App 图标（水钟：玻璃球里半球埃及蓝的水），Icon Composer 格式，macOS 26 自己画玻璃，并生成深色、透明、着色几种风格。`make_icon.swift` 生成它，`make_icon.sh` 再用 Xcode 的 actool 编译成 `Assets.car` 和 `AppIcon.icns`；构建只拷这两个编译结果，不需要 Xcode。
- `static/index.html`、`app.py`、`build_app.sh`：旧的网页版，不再维护。
- 数据在 `~/Library/Application Support/SpeechPractice/`：`sessions/`、`practices/`、`activity/`，新增 `settings.json`、`agenda.json`、`plans/`（每天的计划状态）、`daily/`（片源列表 `sources.json`、已用视频和每天的片段 `state.json`）、`pending/`（服务启动前录的音频）。

改版前的源码备份在 `.backup/pre-redesign-2026-10-25.tar.gz`。
