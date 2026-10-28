import SwiftUI

/// 进展: how practice is going, kept off the 今天 page. Four parts, read top to bottom:
/// I this week (the laurel, minutes, streak, the weekly commitment, the recap), II the trends
/// in your own speaking (what the current block works on first), III the latest takes, IV the
/// year. On a Monday the recap opens on last week, the one worth reading then (AppState.loadProgress).
struct ProgressTray: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            if let t = state.today {
                ProgressPart(numeral: "I", title: L("本周", "This week")) {
                    HStack(alignment: .top, spacing: 32) {
                        WeekPanel(today: t).frame(width: 330)
                        RecapCard().frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                ProgressPart(numeral: "II", title: L("走势", "Trends"),
                             note: L("自己讲的录音，跟读不算在内", "Your own takes; shadowing follows someone else's pace, so it's left out")) {
                    Trends(today: t)
                }
                ProgressPart(numeral: "III", title: L("记录", "Record"),
                             note: L("每一次的结论，点开看完整分析", "The verdict on every take; click one for the full analysis"),
                             action: (L("全部记录", "All takes"), { Task { await state.openTray(.history) } })) {
                    RecentList(rows: Array(state.recent.prefix(8)))
                }
                ProgressPart(numeral: "IV", title: L("这一年", "The year")) {
                    YearPanel()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }
}

/// A numbered part of the tray, set like the recap's sections.
struct ProgressPart<Content: View>: View {
    let numeral: String
    let title: String
    var note: String = ""
    var action: (String, () -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(numeral).font(Typeface.display(17)).foregroundStyle(Palette.ochre)
                Text(title).font(Typeface.display(24)).foregroundStyle(Palette.ink)
                if !note.isEmpty { Text(note).font(Typeface.ui(12)).foregroundStyle(Palette.ink3).lineLimit(1) }
                Spacer()
                if let action { Button(action.0, action: action.1).buttonStyle(InkButtonStyle()) }
            }
            content
        }
    }
}

// MARK: - I. This week

/// The laurel, the week day by day, and the week's numbers: one count of minutes (Monday to
/// today, all recording and listening) and the streak, both by the laurel's rule for a day.
struct WeekPanel: View {
    let today: TodayPayload
    @Environment(AppState.self) private var state

    var body: some View {
        let w = today.week
        VStack(alignment: .center, spacing: 16) {
            LaurelWreath(days: w.laurel, target: w.target, size: 190)
                .help(L("一片叶子是一天：录满 20 秒（听原文算一半）就算练过，一周 \(w.target) 天就算达标。",
                        "One leaf is one day: 20 seconds of recording counts it (listening to an original counts half); \(w.target) days makes the week."))
            Text(weekCaption(w)).font(Typeface.italic(15)).foregroundStyle(weekCaptionColor(w))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            WeekStrip(days: w.days).padding(.top, 4)
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                stat("\(Int(w.days.map(\.minutes).reduce(0, +).rounded()))", L("分钟", "min"), L("本周", "This week"))
                if let t = state.insights?.totals {
                    stat("\(t.currentStreak)", L("天", t.currentStreak == 1 ? "day" : "days"), L("连续", "Streak"))
                    stat("\(t.longestStreak)", L("天", t.longestStreak == 1 ? "day" : "days"), L("最长", "Longest"))
                }
            }
            if !w.committed {
                HoldToCommit(title: L("按住，承诺本周练 \(w.target) 天", "Hold to commit to \(w.target) days this week")) {
                    Task { await state.commitWeek() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ v: String, _ unit: String, _ label: String) -> some View {
        VStack(alignment: .center, spacing: 1) {
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
    var body: some View {
        let names = weekdayInitials
        let top = max(15, days.map(\.minutes).max() ?? 15)
        HStack(alignment: .bottom, spacing: 10) {
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
                .help(L("\(shortDay(d.date))：\(Int(d.minutes.rounded())) 分钟", "\(shortDay(d.date)): \(Int(d.minutes.rounded())) min"))
            }
        }
    }

    private func fill(_ d: WeekDay) -> Color {
        switch d.state {
        case "done": return Palette.ochre
        case "today": return Palette.kyanos.opacity(0.35)   // time spent, but not yet a day that counts
        default: return Palette.ink.opacity(0.18)
        }
    }
}

// MARK: - II. Trends

/// Your own speaking only. Shadowing follows someone else's pace, so it would blur the trend;
/// the rule matches the server's baseline (older recordings without a drill tag count as
/// shadowing when their practice has a reference recording). What the current training block
/// works on comes first.
struct Trends: View {
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
            if recent.count < 2 {
                Text(L("自己讲两次以后，这里会画出语速、填充词和音高的走势。", "After two takes of your own, this shows how your pace, fillers and pitch are trending.")).font(Typeface.italic(14)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("最近 \(recent.count) 次", "Your last \(plural(recent.count, "take"))")).font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 36), GridItem(.flexible())], alignment: .leading, spacing: 18) {
                    ForEach(metrics(recent)) { m in m.view }
                }
            }
        }
    }

    private func metrics(_ recent: [SessionSummary]) -> [TrendItem] {
        let tg = today.targets
        let focus = today.block.focus ?? []
        var out: [TrendItem] = [
            TrendItem(id: "wpm", view: MetricTrend(label: L("语速", "Pace"), unit: L("词/分", "wpm"), values: recent.map(\.wpm),
                                band: tg.band, target: L("目标 \(Int(tg.wpmLow)) 到 \(Int(tg.wpmHigh))", "Target \(Int(tg.wpmLow))–\(Int(tg.wpmHigh))"),
                                better: .inBand(tg.band), format: { String(Int($0.rounded())) }, focus: focus.contains("wpm"))),
            TrendItem(id: "fillers", view: MetricTrend(label: L("填充词", "Fillers"), unit: L("次/分", "/min"), values: recent.map(\.fillersPerMinute),
                                    band: nil, target: L("目标 \(fmt1(tg.fillers)) 以下", "Target \(fmt1(tg.fillers)) or fewer"),
                                    better: .lower(tg.fillers), format: fmt1, focus: focus.contains("fillers"))),
        ]
        let pitch = recent.compactMap(\.pitchRange)
        if pitch.count >= 2 {
            out.append(TrendItem(id: "pitch", view: MetricTrend(label: L("音高起伏", "Pitch range"), unit: L("半音", "semitones"), values: pitch,
                                             band: nil, target: L("目标 \(fmt1(tg.pitch)) 以上", "Target \(fmt1(tg.pitch)) or more"),
                                             better: .higher(tg.pitch), format: fmt1, focus: focus.contains("pitch"))))
        }
        let cov = own.compactMap(\.coverage).suffix(12)
        if cov.count >= 2 {
            out.append(TrendItem(id: "coverage", view: MetricTrend(label: L("要点覆盖", "Coverage"), unit: "%", values: cov.map { $0 * 100 },
                                                band: nil, target: L("讲稿和备讲里讲到的要点", "Key points covered in scripts and prep"),
                                                better: .higher(80), format: { String(Int($0.rounded())) }, focus: focus.contains("coverage"))))
        }
        // Stable: the block's focus first, the rest in their usual order.
        return out.enumerated()
            .sorted { a, b in
                let fa = focus.firstIndex(of: a.element.id) ?? Int.max, fb = focus.firstIndex(of: b.element.id) ?? Int.max
                return fa != fb ? fa < fb : a.offset < b.offset
            }
            .map { $0.element }
    }
}

struct TrendItem: Identifiable {
    let id: String
    let view: MetricTrend
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
    /// What the current training block works on.
    var focus = false

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
                HStack(spacing: 6) {
                    Text(label).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                    if focus {
                        Text(L("本块重点", "Focus")).font(Typeface.ui(10, .semibold)).foregroundStyle(Palette.kyanos)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Palette.kyanos.opacity(0.1), in: Capsule())
                    }
                }
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
                .frame(width: 170, height: 36)
        }
    }

    private var deltaText: String {
        guard let b = before else { return target }
        let d = last - b
        if abs(d) < 0.05 { return L("和前几次持平", "Level with recent takes") }
        return L("比前几次 \(d > 0 ? "↑" : "↓")\(format(abs(d)))", "\(d > 0 ? "↑" : "↓")\(format(abs(d))) vs. recent takes")
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

// MARK: - III. The record

/// Recordings as lines in a ledger: when, what kind, the verdict, the pace.
struct RecentList: View {
    let rows: [RecentSession]
    var showDay = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text(L("还没有录音。录完第一段，结论会记在这里。", "No recordings yet. After your first take, its verdict lands here.")).font(Typeface.ui(13)).foregroundStyle(Palette.ink3).padding(.vertical, 14)
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
                .frame(width: showDay ? (isEnglishUI ? 76 : 64) : 48, alignment: .leading)
                Text(row.kindLabel).font(Typeface.ui(11, .medium)).foregroundStyle(row.space == "shadow" ? Palette.ochre : Palette.kyanos)
                    .frame(width: isEnglishUI ? 62 : 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.headline).font(Typeface.display(15)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(row.practiceTitle ?? row.title).font(Typeface.ui(11)).foregroundStyle(Palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 10)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(row.wpm.rounded()))").font(Typeface.display(18)).monospacedDigit().foregroundStyle(Palette.ink)
                    Text(L("词/分", "wpm")).font(Typeface.ui(10)).foregroundStyle(Palette.ink3)
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

// MARK: - IV. The year

struct YearPanel: View {
    @Environment(AppState.self) private var state
    @State private var hovered: InsightDay?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hovered.map { L("\(shortDay($0.date))：录音 \(formatDuration($0.recordSec))，听 \(formatDuration($0.listenRefSec + $0.listenSelfSec))",
                                 "\(shortDay($0.date)): recorded \(formatDuration($0.recordSec)), listened \(formatDuration($0.listenRefSec + $0.listenSelfSec))") }
                 ?? L("颜色越深，那天练得越多", "The darker the dot, the more practice that day"))
                .font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
            if let ins = state.insights {
                Heatmap(days: ins.days, hovered: $hovered)
            } else {
                ProgressView()
            }
        }
    }
}
