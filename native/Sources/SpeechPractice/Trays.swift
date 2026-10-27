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
                    Label("返回", systemImage: "chevron.left").font(Typeface.ui(13, .medium))
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
            .help("关闭（Esc）")
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 14)
    }

    private var title: String {
        switch tray {
        case .settings: return "设置"
        case .session: return state.currentSession.map { $0.title.isEmpty ? "这一次" : $0.title } ?? "这一次"
        case .practice: return state.practice?.title ?? "讲稿"
        case .newTopic: return "新讲稿"
        case .newEvent: return "加一场要讲的"
        case .addLink: return "贴一个链接"
        case .history: return "全部记录"
        case .clips: return "全部片段"
        case .agenda: return "议程"
        }
    }

    private var subtitle: String {
        switch tray {
        case .settings: return "开始练习的方式、提醒、片段来源和训练周期"
        case .session: return state.currentSession.map { "\(relativeDay($0.createdAt)) \(String($0.createdAt.dropFirst(11).prefix(5)))" } ?? ""
        case .practice: return state.practice.map { $0.isClip ? "片段，练过 \($0.sessions.count) 遍" : "讲稿，练过 \($0.sessions.count) 遍" } ?? ""
        case .newTopic: return "写下要点，当提纲用。讲完会算覆盖了几个"
        case .newEvent: return "离那天十天以内，今天的计划会换成备讲"
        case .addLink: return "把一段演讲做成跟读或复述的片段"
        case .history: return "\(state.history.count) 次录音"
        case .clips: return "每天从演讲里挑一到两段"
        case .agenda: return "要讲的场合，每一场倒排六步准备"
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
        }
    }
}

/// Scrolling body of a tray, with the page margins every tray shares.
struct TrayScroll<C: View>: View {
    @ViewBuilder var content: C

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                Button { go(p, .shadow) } label: { Label("跟读", systemImage: "waveform") }.primaryGlass()
                Button { go(p, .retell) } label: { Label("听完复述", systemImage: "ear") }.buttonStyle(.glass).controlSize(.large)
                Button { go(p, .free) } label: { Label("自己讲一遍", systemImage: "mic") }.buttonStyle(.glass).controlSize(.large)
            } else {
                Button { go(p, .free) } label: { Label("讲一遍", systemImage: "mic.fill") }.primaryGlass()
            }
            Text("第 \(p.sessions.count + 1) 遍会自动归入这里").font(Typeface.ui(12)).foregroundStyle(Palette.ink3)
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
            Text("每一遍").font(Typeface.display(19)).foregroundStyle(Palette.ink)
            if state.sessions.isEmpty {
                Text("还没有练过。").font(Typeface.ui(13)).foregroundStyle(Palette.ink3)
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
                Text("第 \(index) 遍").font(Typeface.display(15)).foregroundStyle(Palette.ink).frame(width: 64, alignment: .leading)
                Text("\(relativeDay(session.createdAt)) \(String(session.createdAt.dropFirst(11).prefix(5)))")
                    .font(Typeface.ui(12)).monospacedDigit().foregroundStyle(Palette.ink3).frame(width: 110, alignment: .leading)
                metric("\(Int(session.wpm.rounded()))", "词/分")
                metric(fmt1(session.fillersPerMinute), "填充词/分")
                if let c = session.coverage { metric("\(Int((c * 100).rounded()))%", "要点") }
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
                    Tile(value: formatDuration(t.recordSec), label: "总录音时长", note: "\(t.recordCount) 次录音")
                    Tile(value: formatDuration(t.listenRefSec + t.listenSelfSec), label: "总听音时长", note: "听参照 \(formatDuration(t.listenRefSec))，回听自己 \(formatDuration(t.listenSelfSec))")
                    Tile(value: "\(t.activeDays)", unit: "天", label: "练过的天数", note: t.firstDay.map { "从 \(shortDay($0)) 开始" } ?? "")
                    Tile(value: "\(t.currentStreak)", unit: "天", label: "连续练习", note: "最长 \(t.longestStreak) 天")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近十二周，每天几分钟").font(Typeface.display(17)).foregroundStyle(Palette.ink)
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

    private func dayTitle(_ iso: String) -> String {
        let rel = relativeDay(iso)
        return rel == "今天" || rel == "昨天" ? "\(rel)，\(chineseDate(iso))" : chineseDate(iso)
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
            TextField("讲什么，比如 数据管道选型", text: $title)
                .textFieldStyle(.plain).font(Typeface.display(26)).foregroundStyle(Palette.ink)
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: "场合")
                ChoiceChips(options: Scenario.allCases, selection: $scenario) { $0.label }
            }
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: "要点或讲稿", detail: "当提纲用，不必逐字读。每讲完一遍，会算出讲到了哪几个要点。对话稿里的角色名会自动忽略。")
                PaperEditor(text: $script, placeholder: "一行一个要点，或者整段讲稿", minHeight: 260)
            }
            HStack(spacing: 12) {
                Spacer()
                Button("取消") { state.closeTray() }.buttonStyle(InkButtonStyle(color: Palette.ink2))
                Button { create() } label: { Text("创建，放上讲台").padding(.horizontal, 6) }
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
                    FieldLabel(title: "从常见的场合开始")
                    FlowLayout(spacing: 8) {
                        ForEach(templates, id: \.title) { t in
                            Button(t.title) { title = t.title; kind = t.kind; minutes = t.minutes }
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
            TextField("讲什么，比如 Architecture Review：semantic layer", text: $title)
                .textFieldStyle(.plain).font(Typeface.display(24)).foregroundStyle(Palette.ink)
            Hairline()
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(title: "哪天")
                    HStack(spacing: 10) {
                        DatePicker("", selection: $date, in: Date()..., displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.field)
                        Text(relative).font(Typeface.ui(12)).foregroundStyle(Palette.kyanos)
                    }
                    HStack(spacing: 6) {
                        quick("明天", 1); quick("三天后", 3); quick("一周后", 7); quick("两周后", 14)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(title: "讲多久")
                    NumberStepper(value: $minutes, range: 1...60, unit: "分钟")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: "场合")
                ChoiceChips(options: kinds, selection: $kind) { state.agenda?.kinds[$0] ?? $0 }
            }
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: "要点（可选）", detail: "会成为这一场的原文，用来算要点覆盖。")
                PaperEditor(text: $notes, placeholder: "一行一个要点", minHeight: 160)
            }
            HStack(spacing: 12) {
                Spacer()
                Button("取消") { state.closeTray() }.buttonStyle(InkButtonStyle(color: Palette.ink2))
                Button { create() } label: { Text("加上").padding(.horizontal, 10) }
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
        return d == 0 ? "今天" : "\(d) 天后"
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
                FieldLabel(title: "链接", detail: "YouTube 链接。带上 &t= 就从那个时间开始截。")
                TextField("https://www.youtube.com/watch?v=", text: $link).fieldBox().onSubmit(add)
            }
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: "用来练什么")
                ChoiceChips(options: ["story", "explain"], selection: $role) { $0 == "story" ? "跟读" : "复述" }
                Text(role == "story" ? "跟读：挑一个人连续讲故事的段落，戴耳机跟着他说，学节奏、停顿和重音。"
                                     : "复述：挑一段讲道理的，听完用自己的话讲：核心观点、一个例子、你怎么看。")
                    .font(Typeface.italic(14)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button { add() } label: { Text("做成片段").padding(.horizontal, 8) }
                    .primaryGlass()
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("在后台下载和切段，大约一分钟。好了会出现在跟读的素材架上。").font(Typeface.ui(12)).foregroundStyle(Palette.ink3)
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
            Text("每天的片段").font(Typeface.display(17)).foregroundStyle(Palette.ink)
            if let d = state.today?.daily {
                HStack(spacing: 10) {
                    if d.state == "running" { ProgressView(value: max(0.05, d.progress)).frame(width: 120).tint(Palette.kyanos) }
                    Text(line(d)).font(Typeface.ui(13)).foregroundStyle(d.state == "failed" ? Palette.cinnabar : Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button("现在就挑") { Task { await state.refreshClips(force: false) } }.buttonStyle(.glass).disabled(d.state == "running")
                    Button("重新挑今天的") { Task { await state.refreshClips(force: true) } }.buttonStyle(InkButtonStyle()).disabled(d.state == "running")
                }
            }
        }
    }

    private func line(_ d: DailyInfo) -> String {
        switch d.state {
        case "running": return d.message?.isEmpty == false ? d.message! : "正在准备今天的片段"
        case "waiting": return "今天的还没准备。每天清晨自动挑，也可以现在就挑，大约三分钟。"
        case "failed": return "没挑到片段：\(d.errors.last ?? d.message ?? "原因不明")"
        case "off": return "每日片段关着，可以在设置里打开。"
        default: return "今天的 \(d.want) 段已经备好。"
        }
    }
}
