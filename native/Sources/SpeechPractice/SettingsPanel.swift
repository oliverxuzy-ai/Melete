import SwiftUI
import AppKit

/// Settings, as a tray in the same materials as the rest of Melete: one section at a time
/// (how practice starts, reminders, where clips come from, the training cycle, Claude, data,
/// the interface language),
/// chosen by the chips at the top, so a section fits the frame instead of one long scroll.
struct SettingsPanel: View {
    @Environment(AppState.self) private var state
    @State private var section = "start"

    private var sections: [(String, String)] {
        [("start", L("开始", "Start")), ("remind", L("提醒", "Reminders")), ("clips", L("片段", "Clips")),
         ("cycle", L("周期", "Cycle")), ("claude", "Claude"), ("data", L("数据", "Data")),
         // Both names, so the way back is readable from either language.
         ("language", isEnglishUI ? "Language · 语言" : "语言 · Language")]
    }

    var body: some View {
        VStack(spacing: 0) {
            ChoiceChips(options: sections.map(\.0), selection: $section) { id in sections.first { $0.0 == id }?.1 ?? id }
                .padding(.horizontal, 28).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            Hairline()
            ScrollView {
                Group {
                    switch section {
                    case "remind": ReminderSettings()
                    case "clips": ClipSettings()
                    case "cycle": CycleSettings()
                    case "claude": ClaudeSettings()
                    case "data": DataSettings()
                    case "language": LanguageSettings()
                    default: StartSettings()
                    }
                }
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 32)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await state.loadSettings() }
    }
}

// MARK: - Building blocks

struct SettingsSection<Rows: View>: View {
    let title: String
    var note: String = ""
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Typeface.display(21)).foregroundStyle(Palette.ink)
            if !note.isEmpty {
                Text(note).font(Typeface.italic(14)).foregroundStyle(Palette.ink2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) { rows }
                .paper(radius: Radius.panel)
                .padding(.top, 4)
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var detail: String = ""
    var divider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Typeface.ui(14, .medium)).foregroundStyle(Palette.ink)
                    if !detail.isEmpty {
                        Text(detail).font(Typeface.ui(12)).foregroundStyle(Palette.ink2).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            if divider { Hairline().padding(.leading, 18) }
        }
    }
}

/// Hour and minute as two small menus that read like a clock face.
struct TimeChip: View {
    let time: String
    let onChange: (String) -> Void

    private var parts: (Int, Int) {
        let p = time.split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 21, p.count > 1 ? p[1] : 30)
    }

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(5..<24, id: \.self) { h in Button(String(format: L("%02d 点", "%02d h"), h)) { onChange(String(format: "%02d:%02d", h, parts.1)) } }
            } label: { Text(String(format: "%02d", parts.0)).font(Typeface.display(18)).monospacedDigit().foregroundStyle(Palette.ink) }
            Text(":").font(Typeface.display(18)).foregroundStyle(Palette.ink3)
            Menu {
                ForEach([0, 10, 15, 20, 30, 40, 45, 50], id: \.self) { m in Button(String(format: L("%02d 分", "%02d min"), m)) { onChange(String(format: "%02d:%02d", parts.0, m)) } }
            } label: { Text(String(format: "%02d", parts.1)).font(Typeface.display(18)).monospacedDigit().foregroundStyle(Palette.ink) }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Palette.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.vein, lineWidth: 1))
    }
}

// MARK: - Sections

struct StartSettings: View {
    @AppStorage("menuBarExtra") private var menuBar = true
    @AppStorage("globalHotkey") private var hotkey = true
    @AppStorage("stageCountdown") private var countdown = true
    @State private var login = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        SettingsSection(title: L("开始练习", "Starting practice"), note: L("开始只需要一个动作：在任何地方按 ⌃⌥R，或者在总览按回车。", "Starting takes one move: press ⌃⌥R anywhere, or Return on the Overview.")) {
            SettingRow(title: L("全局快捷键 ⌃⌥R", "Global shortcut ⌃⌥R"), detail: hotkeyDetail) {
                MeleteToggle(isOn: $hotkey)
            }
            SettingRow(title: L("倒数三秒后自动录音", "Record after a three-second countdown"), detail: L("关掉的话，上台以后按回车才开始。", "When off, recording waits for Return once you're on stage.")) {
                MeleteToggle(isOn: $countdown)
            }
            SettingRow(title: L("菜单栏显示今天的计划", "Today's plan in the menu bar"), detail: L("不用打开窗口，从菜单栏一点就开始。", "Start with one click from the menu bar, no window needed.")) {
                MeleteToggle(isOn: $menuBar)
            }
            SettingRow(title: L("登录时打开 Melete", "Open Melete at login"), detail: loginError ?? L("分析服务和模型在你需要之前就已经就绪，清晨的片段也会备好。", "The analysis service and models are ready before you need them, and the morning clips get prepared."), divider: false) {
                MeleteToggle(isOn: $login)
            }
        }
        .onChange(of: hotkey) { _, on in on ? GlobalHotkey.shared.register() : GlobalHotkey.shared.unregister() }
        .onChange(of: login) { _, on in
            do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription; login = LoginItem.isEnabled }
        }
    }

    private var hotkeyDetail: String {
        if hotkey && GlobalHotkey.shared.status != noErr { return L("这个组合被别的 App 占用了，关掉再打开试试。", "Another app is using this combination. Try turning it off and on again.") }
        return L("在任何 App 里按下，直接打开今天的下一项，三秒后开始录。", "Press it in any app to open today's next item; recording starts three seconds later.")
    }
}

struct ReminderSettings: View {
    @Environment(AppState.self) private var state
    @AppStorage("remindersOn") private var remindersOn = false
    @State private var topic = ""
    @State private var note: String?

    var body: some View {
        SettingsSection(title: L("提醒", "Reminders"), note: L("每天到点提醒一次。漏了一天，第二天的提醒会说只录一分钟也算数。", "One reminder a day at the set time. After a missed day, the next reminder says one minute still counts.")) {
            if let s = state.settings {
                SettingRow(title: L("提醒时间", "Reminder time")) {
                    TimeChip(time: s.daily.notifyTime) { v in
                        Task {
                            await state.saveSettings(["daily": ["notify_time": v]])
                            if remindersOn { Reminders.shared.schedule(at: v) }
                        }
                    }
                }
                SettingRow(title: L("Mac 通知", "Mac notifications"), detail: note ?? L("通知里可以直接开始，或者一小时后再提醒。", "Start right from the notification, or get reminded again in an hour.")) {
                    HStack(spacing: 14) {
                        Button(L("试一条", "Send a test")) {
                            Task { note = await Reminders.shared.sendTest() ? L("两秒后会出现一条通知。", "A notification will appear in two seconds.") : L("系统没有允许通知。可以在 系统设置 > 通知 里打开 Melete。", "Notifications aren't allowed. Turn them on for Melete in System Settings > Notifications.") }
                        }
                        .buttonStyle(InkButtonStyle())
                        MeleteToggle(isOn: $remindersOn)
                    }
                }
                SettingRow(title: L("推到手机", "Push to phone"), detail: L("用免费的 ntfy.sh：手机装 ntfy，订阅一个只有你知道的主题名，填在这里。主题名谁知道谁就能看，别用真名。", "Uses the free ntfy.sh: install ntfy on your phone, subscribe to a topic name only you know, and enter it here. Anyone who knows the name can read it, so don't use your real name."), divider: false) {
                    HStack(spacing: 8) {
                        TextField(L("主题名", "Topic name"), text: $topic).fieldBox().frame(width: 170)
                            .onSubmit { save() }
                        Button(L("保存", "Save")) { save() }.buttonStyle(InkButtonStyle())
                            .disabled(topic == s.daily.ntfyTopic)
                    }
                }
            } else {
                ProgressView().padding(18)
            }
        }
        .onChange(of: remindersOn) { _, on in
            Task {
                if on {
                    let ok = await Reminders.shared.enable(at: state.settings?.daily.notifyTime ?? "21:30")
                    if !ok { remindersOn = false; note = L("系统没有允许通知。可以在 系统设置 > 通知 里打开 Melete。", "Notifications aren't allowed. Turn them on for Melete in System Settings > Notifications.") }
                } else { Reminders.shared.disable() }
            }
        }
        .onChange(of: state.settings?.daily.ntfyTopic, initial: true) { _, v in topic = v ?? "" }
    }

    private func save() { Task { await state.saveSettings(["daily": ["ntfy_topic": topic]]) } }
}

struct ClipSettings: View {
    @Environment(AppState.self) private var state
    @State private var sources: [SourceItem] = []

    var body: some View {
        SettingsSection(title: L("每日片段", "Daily clips"), note: L("偏向演讲和讲座：一个人连续讲，才适合跟读。讲故事的用来跟读，讲道理的用来复述。", "Talks and lectures first: one person speaking at length is what shadowing needs. Stories are for shadowing, explanations for retelling.")) {
            if let s = state.settings {
                SettingRow(title: L("每天清晨自动挑", "Pick every morning")) {
                    MeleteToggle(isOn: Binding(get: { s.daily.enabled }, set: { v in patchDaily(\.enabled, v, ["enabled": v]) }))
                }
                SettingRow(title: L("每天几段", "Clips a day")) {
                    ChoiceChips(options: [1, 2], selection: Binding(get: { s.daily.clipsPerDay }, set: { v in patchDaily(\.clipsPerDay, v, ["clips_per_day": v]) })) {
                        $0 == 1 ? L("一段，跟读", "One, to shadow") : L("两段，跟读和复述", "Two, to shadow and retell")
                    }
                    .fixedSize()
                }
                SettingRow(title: L("下载工具", "Download tools"), detail: toolsLine(s.tools), divider: !sources.isEmpty) {
                    Image(systemName: toolsOK(s.tools) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(toolsOK(s.tools) ? Palette.malachite : Palette.ochre)
                }
                ForEach(Array(sources.enumerated()), id: \.element.id) { i, src in
                    SettingRow(title: src.name, detail: (src.role == "story" ? L("讲故事，用来跟读", "Stories, to shadow") : L("讲道理，用来复述", "Explanations, to retell")) + L("，", ", ") + kindLabel(src.kind), divider: i < sources.count - 1) {
                        MeleteToggle(isOn: Binding(get: { sources[i].enabled }, set: { v in
                            sources[i].enabled = v
                            Task { await state.saveSources(sources) }
                        }))
                    }
                }
            } else {
                ProgressView().padding(18)
            }
        }
        .task { if let api = state.api { sources = (try? await api.sources()) ?? [] } }
    }

    private func patchDaily<T>(_ key: WritableKeyPath<DailySettings, T>, _ v: T, _ patch: [String: Any]) {
        state.settings?.daily[keyPath: key] = v
        Task { await state.saveSettings(["daily": patch]) }
    }

    private func toolsOK(_ t: ToolsInfo) -> Bool { t.ytDlp != nil && t.ffmpeg != nil }

    private func toolsLine(_ t: ToolsInfo) -> String {
        if toolsOK(t) { return L("yt-dlp 和 ffmpeg 都在。", "yt-dlp and ffmpeg are both installed.") }
        let missing = "\(t.ytDlp == nil ? "yt-dlp " : "")\(t.ffmpeg == nil ? "ffmpeg" : "")".trimmingCharacters(in: .whitespaces)
        return L("缺少 \(missing)。在终端运行 brew install yt-dlp ffmpeg。", "Missing \(missing). Run brew install yt-dlp ffmpeg in Terminal.")
    }

    private func kindLabel(_ k: String) -> String {
        switch k {
        case "talk": return L("演讲", "talks")
        case "interview": return L("访谈", "interviews")
        case "keynote": return L("发布会", "keynotes")
        case "search": return L("按关键词搜", "keyword search")
        case "video": return L("固定一个视频", "one fixed video")
        default: return k
        }
    }
}

struct CycleSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        SettingsSection(title: L("训练周期", "Training cycle"), note: L("九周一个周期：语速与音量两周，语调与停顿两周，讲故事两周，看对象换说法两周，然后一周减量。和跑步训练一样，减量之后更容易突破。", "A nine-week cycle: two weeks of pace and volume, two of tone and pauses, two of storytelling, two of speaking to the room, then a taper week. As in running, the breakthrough tends to come after the taper.")) {
            if let s = state.settings {
                SettingRow(title: L("每周目标", "Weekly goal"), detail: L("练过的天数，完成任意一项就算一天。", "Days practiced; finishing any one item counts the day.")) {
                    NumberStepper(value: Binding(get: { s.coach.weekTargetDays }, set: { v in
                        state.settings?.coach.weekTargetDays = v
                        Task { await state.saveSettings(["coach": ["week_target_days": v]]) }
                    }), range: 3...7, unit: L("天", "days"))
                }
                blockRow(key: "", greek: "", name: L("跟着周期走", "Follow the cycle"), detail: L("按周期自动换训练块。", "Move through the training blocks automatically."), selected: s.coach.blockOverride == nil)
                ForEach(s.blocks, id: \.key) { b in
                    blockRow(key: b.key, greek: b.greek, name: L("\(b.name)，\(b.weeks) 周", "\(b.name), \(plural(b.weeks, "week"))"), detail: b.why, selected: s.coach.blockOverride == b.key)
                }
                SettingRow(title: L("从本周重新开始周期", "Restart the cycle this week"), detail: L("回到第一个训练块。之前的记录都在。", "Back to the first training block. Your record stays."), divider: false) {
                    Button(L("重新开始", "Restart")) {
                        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
                        let iso = Calendar(identifier: .iso8601)
                        let monday = iso.date(from: iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
                        Task { await state.saveSettings(["coach": ["cycle_start": f.string(from: monday), "block_override": NSNull()]]) }
                    }
                    .buttonStyle(.glass)
                }
            } else {
                ProgressView().padding(18)
            }
        }
    }

    /// One training block; choosing it pins the cycle there.
    private func blockRow(key: String, greek: String, name: String, detail: String, selected: Bool) -> some View {
        Button {
            Task { await state.saveSettings(["coach": ["block_override": key.isEmpty ? NSNull() as Any : key as Any]]) }
        } label: {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14)).foregroundStyle(selected ? Palette.kyanos : Palette.ink3)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !greek.isEmpty { Text(greek).font(Typeface.italic(15)).foregroundStyle(Palette.kyanos) }
                            Text(name).font(Typeface.ui(14, .medium)).foregroundStyle(Palette.ink)
                        }
                        Text(detail).font(Typeface.ui(12)).foregroundStyle(Palette.ink2).lineSpacing(2)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                Hairline().padding(.leading, 18)
            }
            .background(selected ? Palette.kyanos.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ClaudeSettings: View {
    @Environment(AppState.self) private var state
    @State private var apiKey = ""

    var body: some View {
        SettingsSection(title: L("Claude（可选）", "Claude (optional)"), note: L("不开也能用：本机的规则会挑出一个人连续讲的段落。开了以后，每天一次请求，Claude 从候选段落里挑最适合的，并写两条要注意的停顿和重音。Key 只存在本机设置文件里。", "Everything works without it: local rules pick a passage where one person speaks at length. With it on, once a day Claude picks the best of the candidates and writes two notes on the pauses and stress to copy. The key stays in the settings file on this Mac.")) {
            if let s = state.settings {
                SettingRow(title: L("让 Claude 挑段落、写跟读提示", "Let Claude pick passages and write shadowing notes")) {
                    MeleteToggle(isOn: Binding(get: { s.daily.useClaude }, set: { v in
                        state.settings?.daily.useClaude = v
                        Task { await state.saveSettings(["daily": ["use_claude": v]]) }
                    }))
                }
                SettingRow(title: L("模型", "Model"), detail: L("按 Opus 5.5 估算每天几美分，Haiku 5.5 更便宜。", "A few cents a day with Opus 5.5; Haiku 5.5 costs less.")) {
                    ChoiceChips(options: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
                                selection: Binding(get: { s.daily.claudeModel }, set: { v in
                                    state.settings?.daily.claudeModel = v
                                    Task { await state.saveSettings(["daily": ["claude_model": v]]) }
                                })) { m in
                        m.contains("opus") ? "Opus 5.5" : m.contains("sonnet") ? "Sonnet 5.5" : "Haiku 5.5"
                    }
                    .fixedSize()
                }
                SettingRow(title: "Anthropic API key", detail: s.daily.hasClaudeKey == true ? L("已经保存过。留空不改。", "Saved. Leave empty to keep it.") : L("还没有保存。", "Not saved yet."), divider: false) {
                    HStack(spacing: 8) {
                        SecureField(s.daily.hasClaudeKey == true ? L("已保存", "Saved") : "sk-ant-", text: $apiKey).fieldBox().frame(width: 200)
                        Button(L("保存", "Save")) {
                            Task { await state.saveSettings(["daily": ["claude_api_key": apiKey]]); apiKey = "" }
                        }
                        .buttonStyle(InkButtonStyle())
                        .disabled(apiKey.isEmpty)
                    }
                }
            } else {
                ProgressView().padding(18)
            }
        }
    }
}

struct DataSettings: View {
    @Environment(AppState.self) private var state

    private var dataDir: URL {
        if let custom = ProcessInfo.processInfo.environment["SPEECH_DATA_DIR"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SpeechPractice")
    }

    var body: some View {
        SettingsSection(title: L("数据", "Data"), note: L("录音、分析和片段都存在这台 Mac 上。", "Recordings, analyses and clips all stay on this Mac.")) {
            if let c = state.config {
                ForEach(c.models.keys.sorted(), id: \.self) { name in
                    SettingRow(title: name == c.model ? L("英文转写：\(name)", "English transcription: \(name)") : L("中文转写：\(name)", "Chinese transcription: \(name)"),
                               detail: name == c.model ? L("保留 um、like 这类填充词。", "Keeps fillers like um and like.") : L("约 1.6 GB，第一次录中文时才加载，平时不占内存。", "About 1.6 GB; loaded the first time you record in Chinese, otherwise not in memory.")) {
                        Text(c.models[name] == true ? L("已就绪", "Ready") : L("用到时加载", "Loads when needed")).font(Typeface.ui(12))
                            .foregroundStyle(c.models[name] == true ? Palette.malachite : Palette.ink3)
                    }
                }
            }
            SettingRow(title: L("位置", "Location"), detail: dataDir.path) {
                Button(L("在访达中打开", "Show in Finder")) { NSWorkspace.shared.open(dataDir) }.buttonStyle(InkButtonStyle())
            }
            SettingRow(title: L("分析服务", "Analysis service"), detail: state.server.baseURL?.absoluteString ?? L("未启动", "Not started"), divider: false) {
                Text(state.server.isExternal ? L("外部", "External") : L("内置", "Built in")).font(Typeface.ui(12)).foregroundStyle(Palette.ink3)
            }
        }
    }
}

struct LanguageSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        SettingsSection(title: L("界面语言", "Interface language"),
                        note: L("App 里的文字、点评、计划和提醒都换成这种语言。练习用的语言不受影响：每段录音仍按你说的语言转写和分析。",
                                "The app's text, verdicts, plans and reminders switch to this language. The language you practice in is not affected: each recording is still transcribed and analyzed in the language you speak.")) {
            SettingRow(title: L("语言", "Language"),
                       detail: L("菜单栏里系统自带的菜单（退出、编辑、窗口）下次打开 Melete 时跟着换。",
                                 "The system's own menus (Quit, Edit, Window) follow the next time Melete opens."),
                       divider: false) {
                ChoiceChips(options: AppLanguage.allCases, selection: Binding(
                    get: { LanguageSetting.shared.current },
                    set: { lang in
                        guard lang != LanguageSetting.shared.current else { return }
                        LanguageSetting.shared.choose(lang)
                        Task { await state.languageChanged() }
                    })) { $0.nativeName }
                    .fixedSize()
            }
        }
    }
}
