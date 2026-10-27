import SwiftUI

/// 总览: the one place to see how practice is going. It has the same anatomy as a studio
/// (heading, three columns around a centrepiece, one button, then the way in), so moving
/// between them never feels like changing apps. Here the centrepiece is this week's laurel:
/// performance on its left, rhythm on its right. Scroll down for the record.
struct HomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            HomeContent()
                .padding(.horizontal, 36).padding(.bottom, 44)
                .frame(maxWidth: 1240)
                .frame(maxWidth: .infinity)
        }
        .task { await refresh() }
        .onChange(of: state.space) { _, s in if s == .home { Task { await refresh() } } }
    }

    private func refresh() async {
        await state.refreshToday(quiet: true)
        await state.loadRecent()
        if state.insights == nil { await state.loadInsights() }
        if state.recap == nil { await state.loadRecap() }
    }
}

struct HomeContent: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            if let t = state.today {
                HomeHeader(today: t)
                HStack(alignment: .top, spacing: 40) {
                    PerformanceColumn(today: t).frame(width: 300, alignment: .leading)
                    WeekCentre(today: t).frame(maxWidth: .infinity)
                    RhythmColumn(today: t).frame(width: 300, alignment: .leading)
                }
                .padding(.top, 22)
                StartBlock(today: t).padding(.top, 18)
                Doors(today: t).padding(.top, 26)
                RecordSection().padding(.top, 44)
            } else {
                HomeBooting().frame(minHeight: 520)
            }
        }
    }
}

struct HomeBooting: View {
    @Environment(StageModel.self) private var stage

    var body: some View {
        VStack(spacing: 14) {
            Text(chineseDate(Date())).font(Typeface.display(34)).foregroundStyle(Palette.ink)
            Text("分析服务在后台启动。现在就可以录，录完会自动分析。").font(Typeface.ui(14)).foregroundStyle(Palette.ink2)
            Button { stage.presentFree() } label: { Label("随便说一段", systemImage: "mic.fill") }
                .primaryGlass()
        }
    }
}

// MARK: - Heading

struct HomeHeader: View {
    let today: TodayPayload

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(today.weekday).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                    Text(today.block.greek).font(Typeface.italic(13)).foregroundStyle(Palette.kyanos)
                    Text("\(today.block.name)，第 \(today.block.week ?? 1) / \(today.block.weeks) 周").font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
                }
                Text(chineseDate(today.date)).font(Typeface.display(26)).foregroundStyle(Palette.ink)
            }
            Spacer()
            Text(today.block.why).font(Typeface.italic(14)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.trailing).lineSpacing(3)
                .frame(maxWidth: 420, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 56)
    }
}

// MARK: - Performance (left)

/// Your own speaking only. Shadowing follows someone else's pace, so it would blur the trend;
/// the rule matches the server's baseline (older recordings without a drill tag count as
/// shadowing when their practice has a reference recording).
struct PerformanceColumn: View {
    let today: TodayPayload
    @Environment(AppState.self) private var state

    private var own: [SessionSummary] {
        let withReference = Set(state.practices.filter { $0.refDuration != nil }.map(\.id))
        return state.allSessions
            .filter { s in
                guard s.durationSec >= 15 else { return false }
                if let k = s.drill?.kind { return k != "shadow" }
                if let pid = s.practiceId, withReference.contains(pid) { return false }
                return true
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        let recent = Array(own.suffix(12))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("表现").font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                Spacer()
                Text(recent.isEmpty ? "还没有自己讲的录音" : "自己讲的最近 \(recent.count) 次").font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
            }
            if recent.count < 2 {
                Text("自己讲两次以后，这里会画出语速、填充词和音高的走势。").font(Typeface.italic(14)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                MetricTrend(label: "语速", unit: "词/分", values: recent.map(\.wpm),
                            band: today.targets.band, target: "目标 \(Int(today.targets.wpmLow)) 到 \(Int(today.targets.wpmHigh))",
                            better: .inBand(today.targets.band), format: { String(Int($0.rounded())) })
                MetricTrend(label: "填充词", unit: "次/分", values: recent.map(\.fillersPerMinute),
                            band: nil, target: "目标 \(fmt1(today.targets.fillers)) 以下",
                            better: .lower(today.targets.fillers), format: fmt1)
                let pitch = recent.compactMap(\.pitchRange)
                if pitch.count >= 2 {
                    MetricTrend(label: "音高起伏", unit: "半音", values: pitch,
                                band: nil, target: "目标 \(fmt1(today.targets.pitch)) 以上",
                                better: .higher(today.targets.pitch), format: fmt1)
                }
                let cov = own.compactMap(\.coverage).suffix(12)
                if cov.count >= 2 {
                    MetricTrend(label: "要点覆盖", unit: "%", values: cov.map { $0 * 100 },
                                band: nil, target: "讲稿和备讲里讲到的要点",
                                better: .higher(80), format: { String(Int($0.rounded())) })
                }
            }
        }
    }
}

/// One number, how it moved against the attempts before it, and its line.
struct MetricTrend: View {
    enum Better { case inBand(ClosedRange<Double>), lower(Double), higher(Double) }
    let label: String
    let unit: String
    let values: [Double]
    let band: ClosedRange<Double>?
    let target: String
    let better: Better
    let format: (Double) -> String

    private var last: Double { values.last ?? 0 }
    private var before: Double? {
        let prev = values.dropLast().suffix(5)
        return prev.isEmpty ? nil : prev.reduce(0, +) / Double(prev.count)
    }

    private var good: Bool {
        switch better {
        case .inBand(let b): return b.contains(last)
        case .lower(let t): return last <= t
        case .higher(let t): return last >= t
        }
    }

    /// Whether the move since the earlier attempts went the right way.
    private var improving: Bool? {
        guard let b = before, abs(last - b) >= 0.05 else { return nil }
        switch better {
        case .inBand(let band):
            let mid = (band.lowerBound + band.upperBound) / 2
            return abs(last - mid) < abs(b - mid)
        case .lower: return last < b
        case .higher: return last > b
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(format(last)).font(Typeface.display(25)).monospacedDigit()
                        .foregroundStyle(good ? Palette.malachite : Palette.ink)
                    Text(unit).font(Typeface.ui(11)).foregroundStyle(Palette.ink2)
                }
                Text(deltaText).font(Typeface.ui(11))
                    .foregroundStyle(improving == true ? Palette.malachite : Palette.ink3)
                    .help(target)
            }
            Spacer(minLength: 8)
            Sparkline(values: values, band: band)
                .frame(width: 118, height: 32)
        }
    }

    private var deltaText: String {
        guard let b = before else { return target }
        let d = last - b
        if abs(d) < 0.05 { return "和前几次持平" }
        return "比前几次 \(d > 0 ? "↑" : "↓")\(format(abs(d)))"
    }
}

/// A small line drawn in place, with the target band behind it.
struct Sparkline: View {
    let values: [Double]
    var band: ClosedRange<Double>? = nil

    var body: some View {
        Canvas { gc, size in
            guard values.count >= 2, var lo = values.min(), var hi = values.max() else { return }
            if let b = band { lo = min(lo, b.lowerBound); hi = max(hi, b.upperBound) }
            let pad = max((hi - lo) * 0.15, 0.5)
            lo -= pad; hi += pad
            let y: (Double) -> CGFloat = { v in size.height * CGFloat(1 - (v - lo) / (hi - lo)) }
            let x: (Int) -> CGFloat = { i in size.width * CGFloat(i) / CGFloat(values.count - 1) }
            if let b = band {
                let r = CGRect(x: 0, y: y(b.upperBound), width: size.width, height: y(b.lowerBound) - y(b.upperBound))
                gc.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Palette.malachite.opacity(0.14)))
            }
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: x(i), y: y(v))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            gc.stroke(line, with: .color(Palette.kyanos.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let lp = CGPoint(x: x(values.count - 1), y: y(values[values.count - 1]))
            gc.fill(Path(ellipseIn: CGRect(x: lp.x - 3, y: lp.y - 3, width: 6, height: 6)), with: .color(Palette.kyanos))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The week (centre)

struct WeekCentre: View {
    let today: TodayPayload
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 14) {
            LaurelWreath(days: today.week.laurel, target: today.week.target, size: 230)
                .help("一片叶子是一天。完成任意一项就算练过，一周 \(today.week.target) 天就算达标。")
            Text(caption).font(Typeface.italic(15)).foregroundStyle(captionColor)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
    }

    private var caption: String {
        let w = today.week
        if w.todayDone { return w.done >= w.target ? "本周的目标已经达到。" : "今天练过了。还差 \(max(0, w.target - w.done)) 天。" }
        if let d = w.daysSince, d > 2 { return "上次练是 \(d) 天前。今天录一段一分钟的，先把节奏接上。" }
        if w.missedTwo { return "已经两天没练了。今天录一段一分钟的就行。" }
        if w.missedYesterday { return "昨天没练。今天录一段，就不会连着断两天。" }
        return "今天还没练。完成任意一项就算数。"
    }

    private var captionColor: Color {
        if today.week.todayDone { return Palette.malachite }
        return today.week.missedYesterday ? Palette.ochre : Palette.ink2
    }
}

// MARK: - Rhythm (right)

struct RhythmColumn: View {
    let today: TodayPayload
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("节奏").font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                Spacer()
                Text("本周 \(Int(today.week.days.map(\.minutes).reduce(0, +).rounded())) 分钟").font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
            }
            WeekStrip(days: today.week.days)
            if !today.week.committed {
                HoldToCommit(title: "按住，承诺本周练 \(today.week.target) 天") {
                    Task { await state.commitWeek() }
                }
            }
            if let t = state.insights?.totals {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    stat("\(t.currentStreak)", "天", "连续")
                    stat("\(t.longestStreak)", "天", "最长")
                    stat("\(Int((t.thisWeekSec / 60).rounded()))", "分", "近 7 天")
                }
            }
            if let ev = today.nextEvent { NextTalk(event: ev) }
        }
    }

    private func stat(_ v: String, _ unit: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(v).font(Typeface.display(22)).monospacedDigit().foregroundStyle(Palette.ink)
                Text(unit).font(Typeface.ui(11)).foregroundStyle(Palette.ink2)
            }
        }
    }
}

/// Seven columns, Monday first. Height is minutes spoken and listened; gold is a day that counts.
struct WeekStrip: View {
    let days: [WeekDay]
    private let names = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        let top = max(15, days.map(\.minutes).max() ?? 15)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(days.prefix(7).enumerated()), id: \.element.id) { i, d in
                VStack(spacing: 5) {
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Palette.well).frame(width: 14, height: 56)
                        Capsule().fill(fill(d))
                            .frame(width: 14, height: max(d.minutes > 0 ? 8 : 0, 56 * CGFloat(min(d.minutes / top, 1))))
                    }
                    .overlay {
                        if d.state == "today" { Capsule().strokeBorder(Palette.kyanos, lineWidth: 1.2).frame(width: 18, height: 60) }
                    }
                    Text(names[i]).font(Typeface.ui(10, d.state == "today" ? .semibold : .regular))
                        .foregroundStyle(d.state == "today" ? Palette.kyanos : Palette.ink3)
                }
                .help("\(shortDay(d.date))：\(Int(d.minutes.rounded())) 分钟")
            }
        }
    }

    private func fill(_ d: WeekDay) -> Color {
        switch d.state {
        case "done": return Palette.ochre
        case "today": return d.minutes > 0 ? Palette.ochre : Palette.kyanos.opacity(0.3)
        default: return Palette.ink.opacity(0.18)
        }
    }
}

struct NextTalk: View {
    let event: AgendaEvent
    @Environment(AppState.self) private var state

    var body: some View {
        Button { Task { await state.openTray(.agenda) } } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.daysLeft == 0 ? "今天" : "\(event.daysLeft)").font(Typeface.display(28))
                        .foregroundStyle(event.daysLeft <= 2 ? Palette.cinnabar : Palette.kyanos)
                    if event.daysLeft > 0 { Text("天后").font(Typeface.ui(10)).foregroundStyle(Palette.ink3) }
                }
                .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text("下一场，\(event.kindLabel)").font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
                    Text(event.title).font(Typeface.display(15)).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let step = event.steps.first(where: { $0.state == "today" }) ?? event.steps.first(where: { $0.state == "upcoming" }) {
                        Text("\(step.state == "today" ? "今天" : shortDay(step.date))：\(step.title)").font(Typeface.ui(11)).foregroundStyle(Palette.ink2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.vein))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Start

/// The same button as on stage: one press goes to the right studio and starts.
struct StartBlock: View {
    let today: TodayPayload
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage

    var body: some View {
        VStack(spacing: 10) {
            Button { stage.presentNext() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                    Text(title)
                }
                .font(Typeface.ui(15, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 30).frame(height: 46)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Palette.kyanos).interactive(), in: .capsule)
            .keyboardShortcut(state.tray == nil && state.space == .home ? .defaultAction : nil)
            Text(caption).font(Typeface.ui(12)).foregroundStyle(Palette.ink3)
        }
    }

    private var title: String {
        if today.items.isEmpty { return "自由练一段" }
        return today.nextItem == nil ? "今天都练完了，再来一段" : "开始今天的练习"
    }

    private var caption: String {
        guard let n = today.nextItem else { return "回车开始。三秒后自动录音。" }
        let what = n.kind == "impromptu" ? "，讲给\(n.subtitle)" : "「\(n.title)」"
        return "回车开始：\(n.kindLabel)\(what)，\(durationLabel(n.seconds))"
    }
}

// MARK: - Doors

/// The two ways in, side by side, each with what it holds for today.
struct Doors: View {
    let today: TodayPayload
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Door(space: .shadow, shortcut: "⌘2",
                 summary: "听别人怎么讲，再跟着讲或用自己的话复述",
                 items: today.items.filter { Space.of(kind: $0.kind) == .shadow },
                 footer: shadowFooter, status: shadowStatus)
            Door(space: .topic, shortcut: "⌘3",
                 summary: "围绕一个题目、讲稿或要讲的会，自己讲",
                 items: today.items.filter { Space.of(kind: $0.kind) == .topic },
                 footer: topicFooter, status: nil)
        }
    }

    private var shadowFooter: String {
        let withReference = Set(state.practices.filter { $0.refDuration != nil }.map(\.id))
        let times = state.allSessions.filter { s in
            if let k = s.drill?.kind { return k == "shadow" || k == "retell" }
            return s.practiceId.map { withReference.contains($0) } ?? false
        }.count
        let n = state.shadowPractices.count
        let library = n == 0 ? "片段库还是空的" : "片段库 \(n) 段"
        return times == 0 ? library : "\(library)，跟读和复述练过 \(times) 次"
    }

    private var topicFooter: String {
        let scripts = state.userPractices.filter { $0.kind != "agenda" }.count
        let talks = (state.agenda?.events ?? []).filter { !$0.past }.count
        return "讲稿 \(scripts) 份，议程 \(talks) 场"
    }

    private var shadowStatus: String? {
        switch today.daily.state {
        case "running": return today.daily.message?.isEmpty == false ? today.daily.message : "正在准备今天的片段"
        case "waiting": return "今天的片段还没准备，进去可以现在就挑"
        case "failed": return "没挑到片段：\(today.daily.errors.last ?? today.daily.message ?? "原因不明")"
        default: return nil
        }
    }
}

struct Door: View {
    let space: Space
    let shortcut: String
    let summary: String
    let items: [PlanItem]
    let footer: String
    let status: String?
    @Environment(AppState.self) private var state
    @State private var hover = false

    var body: some View {
        Button { state.go(space) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(space.label).font(Typeface.display(22)).foregroundStyle(Palette.ink)
                    Text(space.greek).font(Typeface.italic(14)).foregroundStyle(Palette.kyanos)
                    Spacer()
                    Text(shortcut).font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hover ? Palette.kyanos : Palette.ink3)
                        .offset(x: hover ? 3 : 0)
                }
                Text(summary).font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
                VStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        Text(space == .shadow ? "今天没有安排跟读" : "今天没有安排题目").font(Typeface.ui(13)).foregroundStyle(Palette.ink3)
                    }
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12)).foregroundStyle(item.done ? Palette.ochre : Palette.ink3)
                            Text(item.kindLabel).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                            Text(item.kind == "impromptu" ? (item.prompt ?? item.title) : item.title)
                                .font(Typeface.display(15)).foregroundStyle(item.done ? Palette.ink2 : Palette.ink)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text(footer).font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
                    if let status { Text(status).font(Typeface.ui(11)).foregroundStyle(Palette.ochre).lineLimit(1) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(hover ? Palette.kyanos.opacity(0.5) : Palette.vein, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.ticker) { hover = h } }
    }
}

// MARK: - The record (below the fold)

struct RecordSection: View {
    @Environment(AppState.self) private var state
    @State private var hovered: InsightDay?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("记录").font(Typeface.display(24)).foregroundStyle(Palette.ink)
                Text("每一次的结论，点开看完整分析").font(Typeface.ui(12)).foregroundStyle(Palette.ink3)
                Spacer()
                Button("全部记录") { Task { await state.openTray(.history) } }.buttonStyle(InkButtonStyle())
            }
            HStack(alignment: .top, spacing: 28) {
                RecentList(rows: Array(state.recent.prefix(8)))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                RecapCard().frame(width: 420)
            }
            if let ins = state.insights {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("这一年").font(Typeface.display(19)).foregroundStyle(Palette.ink)
                        Spacer()
                        Text(hovered.map { "\(shortDay($0.date))：录音 \(formatDuration($0.recordSec))，听参照 \(formatDuration($0.listenRefSec))" } ?? "颜色越深，那天练得越多")
                            .font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
                    }
                    Heatmap(days: ins.days, hovered: $hovered)
                }
                .padding(.top, 10)
            }
        }
    }
}

/// Recordings as lines in a ledger: when, what kind, the verdict, the pace.
struct RecentList: View {
    let rows: [RecentSession]
    var showDay = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("还没有录音。录完第一段，结论会记在这里。").font(Typeface.ui(13)).foregroundStyle(Palette.ink3).padding(.vertical, 14)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Hairline() }
                RecentRow(row: r, showDay: showDay)
            }
        }
    }
}

struct RecentRow: View {
    let row: RecentSession
    var showDay = true
    @Environment(AppState.self) private var state
    @State private var hover = false

    var body: some View {
        Button { Task { await state.openTray(.session(row.id)) } } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    if showDay { Text(relativeDay(row.createdAt)).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2) }
                    Text(String(row.createdAt.dropFirst(11).prefix(5))).font(Typeface.ui(showDay ? 11 : 12)).monospacedDigit()
                        .foregroundStyle(showDay ? Palette.ink3 : Palette.ink2)
                }
                .frame(width: showDay ? 64 : 48, alignment: .leading)
                Text(row.kindLabel).font(Typeface.ui(11, .medium)).foregroundStyle(row.space == "shadow" ? Palette.ochre : Palette.kyanos)
                    .frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.headline).font(Typeface.display(15)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(row.practiceTitle ?? row.title).font(Typeface.ui(11)).foregroundStyle(Palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 10)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(row.wpm.rounded()))").font(Typeface.display(18)).monospacedDigit().foregroundStyle(Palette.ink)
                    Text("词/分").font(Typeface.ui(10)).foregroundStyle(Palette.ink3)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(hover ? Palette.kyanos : Palette.ink3)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(hover ? Palette.well.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.ticker) { hover = h } }
    }
}
