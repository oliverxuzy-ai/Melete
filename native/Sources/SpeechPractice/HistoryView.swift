import SwiftUI
import Charts

struct TrendCharts: View {
    let sessions: [SessionSummary]
    let inPractice: Bool
    let reference: Metrics?

    var body: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, spacing: 14) {
            TrendChart(title: "语速趋势", unit: "/分", values: sessions.map { $0.wpm }, labels: labels, reference: reference?.wpm)
            TrendChart(title: "填充词/分钟趋势", unit: "次/分", values: sessions.map { $0.fillersPerMinute }, labels: labels, reference: reference?.fillers.perMinute)
            if inPractice {
                TrendChart(title: "停顿/分钟趋势", unit: "次/分", values: sessions.map { $0.pausesPerMinute }, labels: labels, reference: reference?.pauses.perMinute)
                if sessions.contains(where: { $0.coverage != nil }) {
                    TrendChart(title: "要点覆盖率趋势", unit: "%", values: sessions.map { ($0.coverage ?? 0) * 100 }, labels: labels, reference: nil)
                }
            }
        }
    }

    private var labels: [String] {
        sessions.enumerated().map { i, s in inPractice ? "第\(i + 1)遍" : String(s.createdAt.dropFirst(5).prefix(5)) }
    }
}

struct TrendChart: View {
    let title: String
    let unit: String
    let values: [Double]
    let labels: [String]
    let reference: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("x", i), y: .value(unit, v)).interpolationMethod(.monotone).foregroundStyle(Palette.kyanos)
                    PointMark(x: .value("x", i), y: .value(unit, v)).foregroundStyle(Palette.kyanos)
                }
                if let reference {
                    RuleMark(y: .value("参照", reference))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Palette.ochre)
                        .annotation(position: .top, alignment: .trailing) { Text("参照 \(fmt1(reference))").font(.caption2).foregroundStyle(Palette.ochre) }
                }
            }
            .chartXAxis {
                AxisMarks(values: Array(values.indices)) { v in
                    let step = max(1, Int((Double(values.count) / 6).rounded(.up)))
                    if let i = v.as(Int.self), labels.indices.contains(i), i % step == 0 || i == values.count - 1 {
                        AxisValueLabel { Text(labels[i]).font(.caption2) }
                    }
                }
            }
            .chartYScale(domain: 0...max(1, (values.max() ?? 1), reference ?? 0) * 1.15)
            .frame(height: 130)
        }
    }
}
