import SwiftUI
import Charts

/// The weekly recap, written like a short letter to yourself: what happened, what changed, what is next.
struct RecapCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let r = state.recap {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.recapOffset == 0 ? "本周小结" : "\(state.recapOffset) 周前").font(Typeface.display(26)).foregroundStyle(Palette.ink)
                        Text("\(shortDay(r.start)) 到 \(shortDay(r.end))，\(r.block.greek) \(r.block.name)").font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
                    }
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.glass)
                    Button { shift(-1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.glass).disabled(state.recapOffset == 0)
                }
                section("I", "练了几天") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ForEach(Array(r.days.enumerated()), id: \.element.id) { i, d in
                                VStack(spacing: 4) {
                                    Circle().fill(d.practiced ? Palette.ochre : Palette.vein.opacity(0.6)).frame(width: 16, height: 16)
                                    Text(["一", "二", "三", "四", "五", "六", "日"][i]).font(Typeface.ui(10)).foregroundStyle(Palette.ink3)
                                }
                            }
                        }
                        Text("\(r.practiced) / \(r.target) 天，说了 \(fmt1(r.recordMinutes)) 分钟，听了 \(fmt1(r.listenMinutes)) 分钟，共 \(r.sessions) 次")
                            .font(Typeface.ui(13)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                section("II", "变化") {
                    HStack(alignment: .top, spacing: 30) {
                        change("语速", r.metrics["wpm"], unit: "词/分", higherIsBetter: true)
                        change("音高起伏", r.metrics["pitch"], unit: "半音", higherIsBetter: true)
                        change("填充词", r.metrics["fillers"], unit: "次/分", higherIsBetter: false)
                    }
                }
                section("III", "下周") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(r.next.greek)  \(r.next.name)").font(Typeface.display(17)).foregroundStyle(Palette.kyanos)
                        if let why = r.next.why { Text(why).font(Typeface.ui(13)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .padding(24)
        .paper()
    }

    private func shift(_ d: Int) {
        state.recapOffset = max(0, state.recapOffset + d)
        Task { await state.loadRecap() }
    }

    private func section<C: View>(_ numeral: String, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(numeral).font(Typeface.display(15)).foregroundStyle(Palette.ochre).frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                content()
            }
        }
    }

    private func change(_ label: String, _ m: RecapMetric?, unit: String, higherIsBetter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
            if let v = m?.this {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(fmt1(v)).font(Typeface.display(24)).foregroundStyle(Palette.ink).monospacedDigit()
                    Text(unit).font(Typeface.ui(11)).foregroundStyle(Palette.ink2)
                }
            } else {
                Text(state.recapOffset == 0 ? "这周还没有" : "那周没有录音").font(Typeface.ui(13)).foregroundStyle(Palette.ink3).padding(.vertical, 6)
            }
            if let a = m?.this, let b = m?.last {
                let up = a > b
                let good = up == higherIsBetter
                Text("上周 \(fmt1(b))，\(up ? "↑" : "↓")\(fmt1(abs(a - b)))").font(Typeface.ui(11)).foregroundStyle(good ? Palette.malachite : Palette.ink2)
            } else if let b = m?.last {
                Text("上周 \(fmt1(b))").font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
            }
        }
    }
}

/// A year of practice as a field of dots. The dot under the pointer swells.
struct Heatmap: View {
    let days: [InsightDay]
    @Binding var hovered: InsightDay?
    private let cell: CGFloat = 12, gap: CGFloat = 3

    /// Columns are weeks (Monday first), rows are weekdays.
    private var weeks: [[InsightDay?]] {
        guard let first = days.first, let firstDate = Heatmap.parse(first.date) else { return [] }
        let weekday = (Calendar.current.component(.weekday, from: firstDate) + 5) % 7  // Monday = 0
        var cols: [[InsightDay?]] = [Array(repeating: nil, count: weekday)]
        for d in days {
            if cols[cols.count - 1].count == 7 { cols.append([]) }
            cols[cols.count - 1].append(d)
        }
        while cols[cols.count - 1].count < 7 { cols[cols.count - 1].append(nil) }
        return cols
    }

    private var maxSec: Double { max(60, days.map(\.totalSec).max() ?? 60) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                monthLabels
                HStack(alignment: .top, spacing: gap) {
                    VStack(spacing: gap) {
                        // Keyed by position: the blank labels would otherwise share one ID, which SwiftUI reports
                        // as invalid and which can leave the whole window unable to update.
                        ForEach(Array(["一", "", "三", "", "五", "", "日"].enumerated()), id: \.offset) { Text($0.element).font(.system(size: 9)).foregroundStyle(Palette.ink3).frame(width: 12, height: cell) }
                    }
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, col in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                let d = col[row]
                                Circle()
                                    .fill(color(d))
                                    .frame(width: cell, height: cell)
                                    .scaleEffect(hovered != nil && hovered?.id == d?.id ? 1.45 : 1)
                                    .animation(Motion.ticker, value: hovered?.id)
                                    .onHover { inside in if inside { hovered = d } else if hovered?.id == d?.id { hovered = nil } }
                                    .help(d.map { "\($0.date)  \(formatDuration($0.totalSec))" } ?? "")
                            }
                        }
                    }
                }
                HStack(spacing: 4) {
                    Spacer()
                    Text("少").font(.caption2).foregroundStyle(Palette.ink3)
                    ForEach(0..<5, id: \.self) { i in Circle().fill(level(i)).frame(width: cell, height: cell) }
                    Text("多").font(.caption2).foregroundStyle(Palette.ink3)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var monthLabels: some View {
        HStack(spacing: gap) {
            Spacer().frame(width: 12)
            ForEach(Array(weeks.enumerated()), id: \.offset) { i, col in
                let label: String = {
                    guard let d = col.compactMap({ $0 }).first, let date = Heatmap.parse(d.date) else { return "" }
                    let day = Calendar.current.component(.day, from: date)
                    return day <= 7 || i == 0 ? "\(Calendar.current.component(.month, from: date))月" : ""
                }()
                Text(label).font(.system(size: 9)).foregroundStyle(Palette.ink3).lineLimit(1).fixedSize().frame(width: cell, alignment: .leading)
            }
        }
    }

    private func color(_ d: InsightDay?) -> Color {
        guard let d, d.totalSec > 0 else { return Palette.ink.opacity(0.07) }
        let ratio = d.totalSec / maxSec
        let lvl = ratio > 0.75 ? 4 : ratio > 0.5 ? 3 : ratio > 0.25 ? 2 : 1
        return level(lvl)
    }

    private func level(_ i: Int) -> Color {
        [Palette.ink.opacity(0.07), Palette.kyanos.opacity(0.28), Palette.kyanos.opacity(0.5), Palette.kyanos.opacity(0.75), Palette.kyanos][i]
    }

    static func parse(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
}

struct WeeklyChart: View {
    let days: [InsightDay]
    var body: some View {
        Chart {
            ForEach(days) { d in
                let date = Heatmap.parse(d.date) ?? Date()
                BarMark(x: .value("日期", date, unit: .day), y: .value("录音", d.recordSec / 60)).foregroundStyle(by: .value("类型", "录音"))
                BarMark(x: .value("日期", date, unit: .day), y: .value("听参照", d.listenRefSec / 60)).foregroundStyle(by: .value("类型", "听参照"))
                BarMark(x: .value("日期", date, unit: .day), y: .value("回听", d.listenSelfSec / 60)).foregroundStyle(by: .value("类型", "回听自己"))
            }
        }
        .chartForegroundStyleScale(["录音": Palette.kyanos, "听参照": Palette.ochre, "回听自己": Palette.malachite])
        .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
        .chartYAxisLabel("分钟")
        .frame(height: 180)
    }
}
