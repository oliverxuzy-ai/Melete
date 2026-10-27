import SwiftUI
import Charts

/// Sentence by sentence: how each one ends, which word stood out, where the pitch went flat,
/// and, when a cloud model listened, how each sentence sounded.
struct ProsodySection: View {
    let prosody: Prosody
    var listen: ListenNotes?

    var body: some View {
        let sum = prosody.summary
        SectionCard(title: L("语调（逐句）", "Intonation, sentence by sentence")) {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: tileColumns, spacing: 10) {
                    if let share = sum.stressShare, sum.stressJudged > 0 {
                        Tile(value: "\(Int(share))", unit: "%", label: L("有重读的句子", "Sentences with stress"),
                             note: L("\(sum.stressJudged) 句里有一个词比别的词更高、更响或更长", "Of \(sum.stressJudged): one word higher, louder or longer than the rest"))
                    }
                    Tile(value: "\(sum.endings["fall"] ?? 0) ↘ \(sum.endings["rise"] ?? 0) ↗ \(sum.endings["level"] ?? 0) →",
                         label: L("句尾走向", "Sentence endings"),
                         note: L("下沉 · 上扬 · 拖平", "Falls · rises · stays level"))
                    Tile(value: "\(sum.fades)", unit: L("句", ""), label: L("句尾音量掉下去", "Endings that fade"),
                         note: L("最后一个词比整句轻 6 dB 以上", "Last word 6 dB or more below the sentence"))
                    Tile(value: fmt1(sum.monotoneSec), unit: "s", label: L("单调段", "Monotone stretches"),
                         note: sum.monotone.isEmpty ? L("没有连续 4 秒以上的平调", "No flat stretch of 4 s or more")
                                                    : L("共 \(sum.monotone.count) 段，图上用金色标出", "\(sum.monotone.count) in all, shaded gold in the chart"))
                    if let cv = sum.paceCv {
                        Tile(value: "\(Int((cv * 100).rounded()))", unit: "%", label: L("句间快慢变化", "Pace change between sentences"),
                             note: L("越大越有快慢起伏；太大是忽快忽慢", "Higher means more variety; very high means uneven"))
                    }
                }
                PitchChart(track: prosody.track, monotone: sum.monotone)
                if let l = listen { ListenSummary(listen: l) }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(prosody.sentences) { s in
                        SentenceRow(sentence: s, note: listen?.sentences?.first(where: { $0.i == s.i }))
                        if s.i != prosody.sentences.last?.i { Hairline() }
                    }
                }
                Text(L("音高按你自己的中位音高换算成半音，所以不同嗓音可以比较。阈值是第一版，会按你的录音再调。",
                       "Pitch is in semitones from your own median, so different voices compare. The thresholds are a first version and will be tuned on your takes."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Pitch over the whole take, broken where there was no voice, with monotone stretches shaded.
struct PitchChart: View {
    let track: ProsodyTrack
    let monotone: [MonotoneStretch]

    private struct Point: Identifiable {
        let id: Int
        let t: Double
        let st: Double
        let run: Int
    }

    private var points: [Point] {
        var out: [Point] = []
        var run = 0, gap = true
        for (k, v) in track.pitch.enumerated() {
            guard let v else { gap = true; continue }
            if gap { run += 1; gap = false }
            out.append(Point(id: k, t: (Double(k) + 0.5) * track.step, st: max(-12, min(12, v)), run: run))
        }
        return out
    }

    var body: some View {
        let pts = points
        let limit = max(6, (pts.map { abs($0.st) }.max() ?? 6).rounded(.up))
        if pts.count < 10 {
            Text(L("录音里能测到音高的部分太少。", "Too little voiced sound to chart the pitch.")).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(Array(monotone.enumerated()), id: \.offset) { _, m in
                    RectangleMark(xStart: .value("start", m.start), xEnd: .value("end", m.end),
                                  yStart: .value("low", -limit), yEnd: .value("high", limit))
                        .foregroundStyle(Palette.ochre.opacity(0.14))
                }
                ForEach(pts) { p in
                    LineMark(x: .value(L("时间", "Time"), p.t), y: .value(L("音高", "Pitch"), p.st), series: .value("run", p.run))
                        .foregroundStyle(Palette.kyanos)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
            }
            .chartYScale(domain: -limit...limit)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(formatClock(d)) } }
                }
            }
            .chartYAxisLabel(L("半音", "semitones"))
            .frame(height: 190)
        }
    }
}

struct SentenceRow: View {
    let sentence: ProsodySentence
    var note: ListenSentence?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(formatClock(sentence.start)).font(Typeface.ui(11)).foregroundStyle(Palette.ink3).monospacedDigit()
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(Typeface.ui(14)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let e = sentence.ending { Text(endingLabel(e.dir)).font(Typeface.ui(11)).foregroundStyle(Palette.ink2) }
                    if sentence.fades == true { Text(L("句尾变轻", "fades at the end")).font(Typeface.ui(11)).foregroundStyle(Palette.cinnabar) }
                    if let st = sentence.stress, !st.clear { Text(L("没有明显重读", "no clear stress")).font(Typeface.ui(11)).foregroundStyle(Palette.ochre) }
                    if let p = sentence.pace { Text("\(Int(p)) \(L("/分", "/min"))").font(Typeface.ui(11)).foregroundStyle(Palette.ink3) }
                    if let n = note, !n.tone.isEmpty { Chip(text: n.tone, style: .hedge) }
                }
                if let n = note, !n.note.isEmpty {
                    Text(n.note).font(Typeface.italic(13)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// The sentence with its stressed word set in blue.
    private var text: AttributedString {
        var a = AttributedString(sentence.text)
        if let st = sentence.stress, st.clear {
            let word = st.word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if !word.isEmpty, let r = a.range(of: word) {
                a[r].foregroundColor = Palette.kyanos
                a[r].font = Typeface.ui(14, .semibold)
            }
        }
        return a
    }
}

func endingLabel(_ dir: String) -> String {
    switch dir {
    case "fall": return L("↘ 句尾下沉", "↘ falls")
    case "rise": return L("↗ 句尾上扬", "↗ rises")
    default: return L("→ 句尾拖平", "→ stays level")
    }
}

// MARK: - Listening notes

/// The cloud model's overall impression: tone, confidence and energy, one tip.
struct ListenSummary: View {
    @Environment(AppState.self) private var state
    let listen: ListenNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("听感", "How it sounds")).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                if let m = listen.model { Text(modelName(m)).font(Typeface.ui(11)).foregroundStyle(Palette.ink3) }
                Spacer()
                if !listen.isPending, let id = state.currentSession?.id {
                    Button(L("再听一次", "Listen again")) { Task { await state.relisten(id) } }.buttonStyle(InkButtonStyle())
                }
            }
            switch listen.status {
            case "pending":
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("正在听这段录音，通常十几秒到半分钟。", "Listening to this take; usually 15 to 30 seconds.")).font(Typeface.ui(13)).foregroundStyle(Palette.ink2)
                }
            case "done":
                if let o = listen.overall {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(o.tone).font(Typeface.display(22)).foregroundStyle(Palette.ink)
                        if let c = o.confidence { LevelDots(label: L("自信", "Confidence"), value: c) }
                        if let e = o.energy { LevelDots(label: L("能量", "Energy"), value: e) }
                    }
                    if !o.summary.isEmpty { Text(o.summary).font(Typeface.ui(14)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true) }
                    if !o.tip.isEmpty {
                        Text(L("下次试试：", "Next time: ") + o.tip).font(Typeface.italic(14)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            case "skipped":
                Text(L("超过 10 分钟的录音不发送。", "Takes over 10 minutes are not sent.")).font(Typeface.ui(13)).foregroundStyle(Palette.ink2)
            default:
                Text(listenErrorText(listen.error)).font(Typeface.ui(13)).foregroundStyle(Palette.cinnabar).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Palette.kyanos.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.tile))
    }
}

struct LevelDots: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(Typeface.ui(11)).foregroundStyle(Palette.ink2)
            ForEach(1...5, id: \.self) { k in
                Circle().fill(k <= value ? Palette.kyanos : Palette.ink.opacity(0.12)).frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)/5")
    }
}

func modelName(_ id: String) -> String {
    let name = id.split(separator: "/").last.map(String.init) ?? id
    return name.replacingOccurrences(of: "gemini-", with: "Gemini ").replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "flash", with: "Flash").replacingOccurrences(of: "lite", with: "Lite")
}

func listenErrorText(_ error: String?) -> String {
    let e = error ?? ""
    if e.contains("invalid_key") { return L("OpenRouter key 无效，在 设置 > 听感 里重新填。", "The OpenRouter key was refused; enter it again in Settings > Listening.") }
    if e.contains("no_credit") { return L("OpenRouter 余额不足，充值后点“再听一次”。", "OpenRouter is out of credit; top up, then Listen again.") }
    if e.contains("model_not_found") { return L("OpenRouter 上找不到这个模型，在设置里换一个。", "OpenRouter doesn't have this model; pick another in Settings.") }
    if e.contains("rate_limited") { return L("请求太频繁，过一会儿点“再听一次”。", "Too many requests; Listen again in a little while.") }
    if e.contains("interrupted") { return L("上次没听完（App 中途退出了）。", "The last request didn't finish (the app quit).") }
    if e.hasPrefix("network") { return L("连不上 OpenRouter，检查网络后点“再听一次”。", "Couldn't reach OpenRouter; check the network, then Listen again.") }
    return L("这次没听成（\(e.isEmpty ? "未知错误" : e)），本机的分析不受影响。", "Listening failed this time (\(e.isEmpty ? "unknown error" : e)); the local analysis is unaffected.")
}

// MARK: - Shadowing

/// Your tune against the reference speaker's, sentence by sentence.
struct ShadowProsodySection: View {
    let shadow: ShadowProsody

    var body: some View {
        let s = shadow.summary
        SectionCard(title: L("跟原声比语调", "Your tune against the speaker's")) {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: tileColumns, spacing: 10) {
                    if let v = s.similarity {
                        Tile(value: "\(Int(v))", unit: "%", label: L("语调贴合", "Tune match"),
                             note: L("比了 \(s.compared)/\(s.of) 句的音高走向", "Pitch shape of \(s.compared) of \(s.of) sentences"),
                             tone: v >= 60 ? Palette.malachite : nil)
                    }
                    if let r = s.rangeRatio {
                        Tile(value: String(format: "%.2f×", r), label: L("起伏幅度", "Pitch movement"),
                             note: r < 0.8 ? L("比原声平", "Flatter than the speaker") : r > 1.25 ? L("比原声起伏大", "More movement than the speaker") : L("和原声接近", "Close to the speaker"))
                    }
                    if let f = s.sameFinal {
                        Tile(value: "\(Int(f))", unit: "%", label: L("句尾一致", "Same endings"), note: L("句尾下沉、上扬、拖平和原声一样", "Falls, rises and level endings like the speaker's"))
                    }
                    if let st = s.sameStress {
                        Tile(value: "\(Int(st))", unit: "%", label: L("重读一致", "Same stress"), note: L("原声重读的词你也重读了", "You stressed the word the speaker stressed"))
                    }
                }
                let worst = s.worst.compactMap { i in shadow.sentences.first(where: { $0.i == i }) }
                if !worst.isEmpty {
                    Text(L("差得最多的几句（金色是原声，蓝色是你）", "Furthest off (gold is the speaker, blue is you)")).font(.caption).foregroundStyle(.secondary)
                    ForEach(worst) { row in ShadowRowView(row: row) }
                }
            }
        }
    }
}

struct ShadowRowView: View {
    let row: ShadowRow

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.text).font(Typeface.ui(14)).foregroundStyle(Palette.ink).lineLimit(2)
                Text(detail).font(Typeface.ui(11)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Chart {
                ForEach(Array(row.refContour.enumerated()), id: \.offset) { k, v in
                    LineMark(x: .value("k", k), y: .value("st", v), series: .value("who", "ref")).foregroundStyle(Palette.ochre)
                }
                ForEach(Array(row.yourContour.enumerated()), id: \.offset) { k, v in
                    LineMark(x: .value("k", k), y: .value("st", v), series: .value("who", "you")).foregroundStyle(Palette.kyanos)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(width: 140, height: 44)
        }
        .padding(10)
        .paper(radius: Radius.tile)
    }

    private var detail: String {
        var parts: [String] = []
        if let s = row.similarity { parts.append(L("贴合 \(Int(s))%", "match \(Int(s))%")) }
        if let r = row.refFinal, let y = row.yourFinal, r != y {
            parts.append(L("原声\(endingLabel(r))，你\(endingLabel(y))", "speaker \(endingLabel(r)), you \(endingLabel(y))"))
        }
        if let r = row.refStress, (row.yourStress ?? "").lowercased() != r.lowercased() {
            parts.append(L("原声重读「\(r)」", "speaker stresses “\(r)”") + (row.yourStress.map { L("，你重读「\($0)」", ", you “\($0)”") } ?? L("，你没有明显重读", ", you stress nothing in particular")))
        }
        return parts.joined(separator: " · ")
    }
}
