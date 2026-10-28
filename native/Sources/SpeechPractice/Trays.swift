import SwiftUI

// MARK: - Host and chrome

/// Trays rise from the bottom over whichever space you are in. One at a time; a tray opened
/// from another (a recording from its practice) can step back. Esc or the scrim closes it.
struct TrayHost: View {
    /// Where the top bar ends; a tray floats below it.
    var topInset: CGFloat = 0
    @Environment(AppState.self) private var state

    var body: some View {
        let _ = FrameProbe.drawnTray = state.tray?.id ?? ""
        ZStack(alignment: .bottom) {
            if state.tray != nil {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture { state.closeTray() }
                    .transition(.opacity)
                    .zIndex(1)
            }
            if let t = state.tray {
                TraySheet(tray: t, topInset: topInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(Motion.glass, value: state.tray)
        .id(state.trayEpoch)
    }
}

/// A whole sheet floating in the window: every edge and corner inside it, so it reads as one
/// finished thing, with long content scrolling inside the frame.
struct TraySheet: View {
    let tray: Tray
    var topInset: CGFloat = 0
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: Radius.stage, style: .continuous)
            VStack(spacing: 0) {
                header
                Hairline()
                content
                    .id(tray.id)
                    .transition(.opacity)
            }
            .frame(width: min(geo.size.width - 56, 1040), height: max(360, geo.size.height - topInset - 34))
            .background(Palette.marble, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.vein, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 8)
            .padding(.top, topInset + 10).padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            if state.trayBack != nil {
                Button { Task { await state.trayGoBack() } } label: {
                    Label(L("返回", "Back"), systemImage: "chevron.left").font(Typeface.ui(13, .medium))
                }
                .buttonStyle(InkButtonStyle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typeface.display(22)).foregroundStyle(Palette.ink).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(Typeface.ui(12)).foregroundStyle(Palette.ink2).lineLimit(1) }
            }
            Spacer()
            Button { state.closeTray() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink2)
                    .frame(width: 30, height: 30).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .keyboardShortcut(.cancelAction)
            .help(L("关闭（Esc）", "Close (Esc)"))
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 14)
    }

    private var title: String {
        switch tray {
        case .settings: return L("设置", "Settings")
        case .session: return state.currentSession.map { $0.title.isEmpty ? L("这一次", "This take") : $0.title } ?? L("这一次", "This take")
        case .practice: return state.practice?.title ?? L("讲稿", "Script")
        case .newTopic: return L("新讲稿", "New script")
        case .newEvent: return L("加一场要讲的", "Add a talk")
        case .addLink: return L("贴一个链接", "Paste a link")
        case .history: return L("全部记录", "All takes")
        case .clips: return L("全部片段", "All clips")
        case .agenda: return L("议程", "Agenda")
        case .progress: return L("进展", "Progress")
        }
    }

    private var subtitle: String {
        switch tray {
        case .settings: return L("开始练习的方式、提醒、片段来源和训练周期", "How practice starts, reminders, clip sources and the training cycle")
        case .session: return state.currentSession.map { "\(relativeDay($0.createdAt)) \(String($0.createdAt.dropFirst(11).prefix(5)))" } ?? ""
        case .practice: return state.practice.map {
            $0.isClip ? L("片段，练过 \($0.sessions.count) 遍", "Clip, practiced \(plural($0.sessions.count, "time"))")
                      : L("讲稿，练过 \($0.sessions.count) 遍", "Script, practiced \(plural($0.sessions.count, "time"))")
        } ?? ""
        case .newTopic: return L("写下要点，当提纲用。讲完会算覆盖了几个", "Write the key points as an outline. Each take counts how many you covered")
        case .newEvent: return L("离那天十天以内，今天的计划会换成备讲", "Within ten days of the talk, today's plan switches to prep")
        case .addLink: return L("把一段演讲做成跟读或复述的片段", "Turn part of a talk into a clip to shadow or retell")
        case .history: return L("\(state.history.count) 次录音", plural(state.history.count, "recording"))
        case .clips: return L("每天从演讲里挑一到两段", "One or two passages picked from talks every day")
        case .agenda: return L("要讲的场合，每一场倒排六步准备", "Talks you have coming up, each prepped in six steps counted back")
        case .progress: return L("本周、走势、记录和这一年", "This week, trends, the record and the year")
        }
    }

    @ViewBuilder private var content: some View {
        switch tray {
        case .settings: SettingsPanel()
        case .session: TrayScroll { SessionDetailView() }
        case .practice: TrayScroll { PracticeTray() }
        case .newTopic: TrayScroll { NewTopicForm() }
        case .newEvent: TrayScroll { NewEventForm() }
        case .addLink: TrayScroll { AddLinkForm() }
        case .history: TrayScroll { HistoryTray() }
        case .clips: TrayScroll { ClipsContent() }
        case .agenda: TrayScroll { AgendaContent() }
        case .progress: TrayScroll { ProgressTray() }
        }
    }
}

/// Scrolling body of a tray, with the page margins every tray shares.
struct TrayScroll<C: View>: View {
    @ViewBuilder var content: C
    @Environment(\.renderMode) private var renderMode

    var body: some View {
        if renderMode {
            // Offscreen a scroll view draws blank, so the render harness gets the top of the page.
            content
                .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)   // without minHeight the frame grows to the page
                .clipped()
        } else {
            ScrollView {
                content
                    .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - A practice

/// A script or a clip: its text, its reference audio, every attempt.
struct PracticeTray: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let p = state.practice {
                actions(p)
                PracticeHeaderView()
                if p.reference != nil || !p.isClip { ShadowingView() }
                AttemptsSection()
            }
        }
    }

    private func actions(_ p: Practice) -> some View {
        HStack(spacing: 12) {
            if p.reference != nil {
                Button { go(p, .shadow) } label: { Label(L("跟读", "Shadow"), systemImage: "waveform") }.primaryGlass()
                Button { go(p, .retell) } label: { Label(L("听完复述", "Listen and retell"), systemImage: "ear") }.buttonStyle(.glass).controlSize(.large)
                Button { go(p, .free) } label: { Label(L("自己讲一遍", "Say it yourself"), systemImage: "mic") }.buttonStyle(.glass).controlSize(.large)
            } else {
                Button { go(p, .free) } label: { Label(L("讲一遍", "Run it"), systemImage: "mic.fill") }.primaryGlass()
            }
            Text(L("第 \(p.sessions.count + 1) 遍会自动归入这里", "Take \(p.sessions.count + 1) is filed here automatically")).font(Typeface.ui(12)).foregroundStyle(Palette.ink3)
        }
    }

    private func go(_ p: Practice, _ m: StageModel.Mode) {
        state.closeTray()
        stage.present(practice: p, mode: m)
    }
}

/// Attempts at one practice, oldest at the left of the charts, newest first in the list.
struct AttemptsSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("每一遍", "Every take")).font(Typeface.display(19)).foregroundStyle(Palette.ink)
            if state.sessions.isEmpty {
                Text(L("还没有练过。", "Not practiced yet.")).font(Typeface.ui(13)).foregroundStyle(Palette.ink3)
            } else {
                TrendCharts(sessions: state.sessions, inPractice: true, reference: state.practice?.reference?.metrics)
                VStack(spacing: 0) {
                    ForEach(Array(state.sessions.enumerated().reversed()), id: \.element.id) { i, s in
                        if i < state.sessions.count - 1 { Hairline() }
                        AttemptRow(index: s.attempt ?? i + 1, session: s)
                    }
                }
            }
        }
    }
}

struct AttemptRow: View {
    let index: Int
    let session: SessionSummary
    @Environment(AppState.self) private var state
    @State private var hover = false

    var body: some View {
        Button { Task { await state.openTray(.session(session.id)) } } label: {
            HStack(spacing: 16) {
                Text(L("第 \(index) 遍", "Take \(index)")).font(Typeface.display(15)).foregroundStyle(Palette.ink).frame(width: 64, alignment: .leading)
                Text("\(relativeDay(session.createdAt)) \(String(session.createdAt.dropFirst(11).prefix(5)))")
                    .font(Typeface.ui(12)).monospacedDigit().foregroundStyle(Palette.ink3).frame(width: 110, alignment: .leading)
                metric("\(Int(session.wpm.rounded()))", L("词/分", "wpm"))
                metric(fmt1(session.fillersPerMinute), L("填充词/分", "fillers/min"))
                if let c = session.coverage { metric("\(Int((c * 100).rounded()))%", L("要点", "points")) }
                Spacer()
                Text(formatClock(session.durationSec)).font(Typeface.ui(12)).monospacedDigit().foregroundStyle(Palette.ink3)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(hover ? Palette.kyanos : Palette.ink3)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(hover ? Palette.well.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.ticker) { hover = h } }
    }

    private func metric(_ v: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(v).font(Typeface.display(16)).monospacedDigit().foregroundStyle(Palette.ink)
            Text(unit).font(Typeface.ui(10)).foregroundStyle(Palette.ink3)
        }
        .frame(width: 96, alignment: .leading)
    }
}

// MARK: - The whole record

struct HistoryTray: View {
    @Environment(AppState.self) private var state

    private var byDay: [(String, [RecentSession])] {
        var order: [String] = []
        var by: [String: [RecentSession]] = [:]
        for r in state.history {
            let d = String(r.createdAt.prefix(10))
            if by[d] == nil { order.append(d) }
            by[d, default: []].append(r)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            if let ins = state.insights {
                let t = ins.totals
                LazyVGrid(columns: tileColumns, spacing: 10) {
                    Tile(value: formatDuration(t.recordSec), label: L("总录音时长", "Time recorded"), note: L("\(t.recordCount) 次录音", plural(t.recordCount, "recording")))
                    Tile(value: formatDuration(t.listenRefSec + t.listenSelfSec), label: L("总听音时长", "Time listened"),
                         note: L("听参照 \(formatDuration(t.listenRefSec))，回听自己 \(formatDuration(t.listenSelfSec))",
                                 "Originals \(formatDuration(t.listenRefSec)), yourself \(formatDuration(t.listenSelfSec))"))
                    Tile(value: "\(t.activeDays)", unit: L("天", t.activeDays == 1 ? "day" : "days"), label: L("练过的天数", "Days practiced"),
                         note: t.firstDay.map { L("从 \(shortDay($0)) 开始", "Since \(shortDay($0))") } ?? "")
                    Tile(value: "\(t.currentStreak)", unit: L("天", t.currentStreak == 1 ? "day" : "days"), label: L("连续练习", "Current streak"),
                         note: L("最长 \(t.longestStreak) 天", "Longest \(plural(t.longestStreak, "day"))"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("最近十二周，每天几分钟", "Minutes a day, last twelve weeks")).font(Typeface.display(17)).foregroundStyle(Palette.ink)
                    WeeklyChart(days: Array(ins.days.suffix(84)))
                }
            }
            ForEach(byDay, id: \.0) { day, rows in
                VStack(alignment: .leading, spacing: 4) {
                    Text(dayTitle(day)).font(Typeface.display(16)).foregroundStyle(Palette.ink2).padding(.leading, 10)
                    RecentList(rows: rows, showDay: false)
                }
            }
        }
    }
}

// MARK: - Forms

struct NewTopicForm: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage
    @State private var title = ""
    @State private var scenario = Scenario.presentation
    @State private var script = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TextField(L("讲什么，比如 数据管道选型", "What about? e.g. choosing a data pipeline"), text: $title)
                .textFieldStyle(.plain).font(Typeface.display(26)).foregroundStyle(Palette.ink)
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: L("场合", "Occasion"))
                ChoiceChips(options: Scenario.allCases, selection: $scenario) { $0.label }
            }
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: L("要点或讲稿", "Key points or script"),
                           detail: L("当提纲用，不必逐字读。每讲完一遍，会算出讲到了哪几个要点。对话稿里的角色名会自动忽略。",
                                     "Used as an outline, not read word for word. After each take you see which points you covered. Speaker names in a dialogue are ignored."))
                PaperEditor(text: $script, placeholder: L("一行一个要点，或者整段讲稿", "One point per line, or a whole script"), minHeight: 260)
            }
            HStack(spacing: 12) {
                Spacer()
                Button(L("取消", "Cancel")) { state.closeTray() }.buttonStyle(InkButtonStyle(color: Palette.ink2))
                Button { create() } label: { Text(L("创建，放上讲台", "Create and put on stage")).padding(.horizontal, 6) }
                    .primaryGlass()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                Text("⌘↩").font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func create() {
        saving = true
        Task {
            if let id = await state.createPractice(title: title, scenario: scenario.rawValue, script: script),
               let p = await state.fetchPractice(id) {
                state.closeTray()
                stage.present(practice: p, mode: .free, autoStart: false)
            }
            saving = false
        }
    }
}

struct NewEventForm: View {
    @Environment(AppState.self) private var state
    @State private var title = ""
    @State private var date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var kind = "review"
    @State private var minutes = 10
    @State private var notes = ""
    @State private var saving = false

    private var kinds: [String] { (state.agenda?.kinds ?? [:]).keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let templates = state.agenda?.templates, !templates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(title: L("从常见的场合开始", "Start from a common one"))
                    FlowLayout(spacing: 8) {
                        ForEach(templates, id: \.title) { t in
                            Button(t.title) { title = t.title; kind = t.kind; minutes = t.minutes }
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
            TextField(L("讲什么，比如 Architecture Review：semantic layer", "What is it? e.g. Architecture Review: semantic layer"), text: $title)
                .textFieldStyle(.plain).font(Typeface.display(24)).foregroundStyle(Palette.ink)
            Hairline()
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(title: L("哪天", "When"))
                    HStack(spacing: 10) {
                        DatePicker("", selection: $date, in: Date()..., displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.field)
                        Text(relative).font(Typeface.ui(12)).foregroundStyle(Palette.kyanos)
                    }
                    HStack(spacing: 6) {
                        quick(L("明天", "Tomorrow"), 1); quick(L("三天后", "In 3 days"), 3); quick(L("一周后", "In a week"), 7); quick(L("两周后", "In 2 weeks"), 14)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(title: L("讲多久", "How long"))
                    NumberStepper(value: $minutes, range: 1...60, unit: L("分钟", "min"))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: L("场合", "Occasion"))
                ChoiceChips(options: kinds, selection: $kind) { state.agenda?.kinds[$0] ?? $0 }
            }
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: L("要点（可选）", "Key points (optional)"), detail: L("会成为这一场的原文，用来算要点覆盖。", "They become this talk's text, used to measure coverage."))
                PaperEditor(text: $notes, placeholder: L("一行一个要点", "One point per line"), minHeight: 160)
            }
            HStack(spacing: 12) {
                Spacer()
                Button(L("取消", "Cancel")) { state.closeTray() }.buttonStyle(InkButtonStyle(color: Palette.ink2))
                Button { create() } label: { Text(L("加上", "Add")).padding(.horizontal, 10) }
                    .primaryGlass()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                Text("⌘↩").font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task { if state.agenda == nil { await state.loadAgenda() } }
    }

    private var relative: String {
        let d = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day ?? 0
        return d == 0 ? L("今天", "Today") : L("\(d) 天后", "In \(plural(d, "day"))")
    }

    private func quick(_ label: String, _ days: Int) -> some View {
        Button(label) { date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? date }
            .buttonStyle(InkButtonStyle())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Palette.kyanos.opacity(0.08), in: Capsule())
    }

    private func create() {
        saving = true
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        Task {
            await state.createEvent(["title": title, "date": f.string(from: date), "kind": kind, "minutes": minutes, "notes": notes])
            saving = false
            if state.errorMessage == nil { await state.openTray(.agenda) }
        }
    }
}

struct AddLinkForm: View {
    @Environment(AppState.self) private var state
    @State private var link = ""
    @State private var role = "story"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: L("链接", "Link"), detail: L("YouTube 链接。带上 &t= 就从那个时间开始截。", "A YouTube link. With &t= the clip starts from that time."))
                TextField("https://www.youtube.com/watch?v=", text: $link).fieldBox().onSubmit(add)
            }
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: L("用来练什么", "Practice it as"))
                ChoiceChips(options: ["story", "explain"], selection: $role) { $0 == "story" ? L("跟读", "Shadow") : L("复述", "Retell") }
                Text(role == "story" ? L("跟读：挑一个人连续讲故事的段落，戴耳机跟着他说，学节奏、停顿和重音。",
                                         "Shadow: a passage where one person tells a story. Speak along in headphones to learn their rhythm, pauses and stress.")
                                     : L("复述：挑一段讲道理的，听完用自己的话讲：核心观点、一个例子、你怎么看。",
                                         "Retell: a passage that explains or argues. Listen, then say it in your own words: the main point, one example, your view."))
                    .font(Typeface.italic(14)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button { add() } label: { Text(L("做成片段", "Make a clip")).padding(.horizontal, 8) }
                    .primaryGlass()
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(L("在后台下载和切段，大约一分钟。好了会出现在跟读的素材架上。", "Downloads and cuts in the background, about a minute. It appears on the Shadowing shelf when ready.")).font(Typeface.ui(12)).foregroundStyle(Palette.ink3)
            }
            Hairline()
            DailyStatusBlock()
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func add() {
        let url = link.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        link = ""
        Task {
            await state.addClip(url: url, role: role)
            state.closeTray()
        }
    }
}

/// Where today's automatic clips stand, and the two ways to nudge them.
struct DailyStatusBlock: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("每天的片段", "Daily clips")).font(Typeface.display(17)).foregroundStyle(Palette.ink)
            if let d = state.today?.daily {
                HStack(spacing: 10) {
                    if d.state == "running" { ProgressView(value: max(0.05, d.progress)).frame(width: 120).tint(Palette.kyanos) }
                    Text(line(d)).font(Typeface.ui(13)).foregroundStyle(d.state == "failed" ? Palette.cinnabar : Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button(L("现在就挑", "Pick now")) { Task { await state.refreshClips(force: false) } }.buttonStyle(.glass).disabled(d.state == "running")
                    Button(L("重新挑今天的", "Pick today's again")) { Task { await state.refreshClips(force: true) } }.buttonStyle(InkButtonStyle()).disabled(d.state == "running")
                }
            }
        }
    }

    private func line(_ d: DailyInfo) -> String {
        switch d.state {
        case "running": return d.message?.isEmpty == false ? d.message! : L("正在准备今天的片段", "Preparing today's clips")
        case "waiting": return L("今天的还没准备。每天清晨自动挑，也可以现在就挑，大约三分钟。", "Today's aren't ready yet. They're picked every morning, or pick now; it takes about three minutes.")
        case "failed": return L("没挑到片段：", "No clips picked: ") + (d.errors.last ?? d.message ?? L("原因不明", "unknown reason"))
        case "off": return L("每日片段关着，可以在设置里打开。", "Daily clips are off. Turn them on in Settings.")
        default: return L("今天的 \(d.want) 段已经备好。", d.want == 1 ? "Today's clip is ready." : "Today's \(d.want) clips are ready.")
        }
    }
}
