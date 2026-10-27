import SwiftUI
import Charts

let FILLERS_EN = ["um","uh","uhm","umm","hmm","mm","er","ah","eh","like","actually","basically","literally","okay","you know","i mean","kind of","sort of","i guess"]
let HEDGES_EN = ["maybe","perhaps","probably","possibly","hopefully","somewhat","a little","a bit","just","i think","i feel like","i believe","i guess","kind of","sort of","not sure","might","seems like"]
let FILLERS_ZH_PLAIN = ["嗯","呃","怎么说","对吧"]
let FILLERS_ZH_CONTEXT = ["那个","然后","就是","其实","这个","啊"]
let HEDGES_ZH = ["可能","大概","也许","应该","好像","我觉得","我感觉","差不多","有点"]

struct SessionDetailView: View {
    @Environment(AppState.self) private var state
    @State private var player = PlayerModel()
    @State private var title = ""
    @State private var notes = ""
    @State private var rating: Int?
    @State private var practiceId: String?

    var body: some View {
        if let s = state.currentSession {
            let m = s.metrics
            VStack(alignment: .leading, spacing: 16) {
                SectionCard(title: s.title.isEmpty ? "录音结果" : s.title, trailing: meta(s)) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let r = s.review {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(r.headline).font(Typeface.display(24)).foregroundStyle(Palette.ink)
                                ForEach(Array(r.lines.enumerated()), id: \.offset) { _, line in
                                    Text(line).font(Typeface.ui(13)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            MeanderRule()
                        }
                        LazyVGrid(columns: tileColumns, spacing: 10) { metricTiles(m) }
                    }
                }
                if let cov = m.coverage {
                    CoverageSection(coverage: cov)
                } else if s.practiceId != nil {
                    SectionCard(title: "要点覆盖") { Text("这个练习还没有原文。填上原文并保存后，这里会显示要点覆盖。").foregroundStyle(.secondary) }
                }
                HStack(alignment: .top, spacing: 16) {
                    SectionCard(title: "语速随时间（每 30 秒）") { PaceChart(points: m.paceTimeline, band: paceBand(for: m.language), unit: m.unitLabel) }
                    SectionCard(title: "用词") { WordsSection(metrics: m) }
                }
                SectionCard(title: "转写") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Chip(text: "填充词", style: .filler); Chip(text: "弱化 / 犹豫用语", style: .hedge)
                            Text("停顿 ≥ 0.5 秒标在句中").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(highlightedTranscript(m)).lineSpacing(5).textSelection(.enabled)
                        PlayerBar(model: player)
                    }
                }
                SectionCard(title: "我的记录") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            HStack(spacing: 2) {
                                Text("自评").foregroundStyle(.secondary)
                                ForEach(1...5, id: \.self) { i in
                                    Button { rating = (rating == i) ? nil : i } label: {
                                        Image(systemName: (rating ?? 0) >= i ? "star.fill" : "star").foregroundStyle(Palette.ochre)
                                    }.buttonStyle(.plain)
                                }
                            }
                            TextField("标题", text: $title).frame(maxWidth: 260)
                            Picker("归属练习", selection: Binding(get: { practiceId ?? "" }, set: { practiceId = $0.isEmpty ? nil : $0 })) {
                                Text("未分组").tag("")
                                ForEach(state.practices) { Text($0.title).tag($0.id) }
                            }.frame(maxWidth: 320)
                        }
                        TextEditor(text: $notes).frame(minHeight: 70).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            .overlay(alignment: .topLeading) {
                                if notes.isEmpty { Text("这次想练什么？哪里卡住了？下次改什么？").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) }
                            }
                        HStack {
                            Button("保存记录") { Task { await state.saveSession(title: title, notes: notes, rating: rating, practiceId: practiceId) } }
                                .primaryGlass()
                            Button("重新分析") { Task { await state.reanalyzeSession(language: s.language) } }.disabled(state.busy)
                            Text("重新分析会用当前模型和设置重跑转写，笔记和归属不变").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            ConfirmButton(title: "删除这次录音", question: "录音和分析都会删掉。") {
                                Task { await state.deleteSession() }
                            }
                        }
                    }
                }
            }
            .onChange(of: s.id, initial: true) { _, _ in load(s) }
            .onDisappear { player.stop() }
        }
    }

    private func load(_ s: Session) {
        title = s.title; notes = s.notes ?? ""; rating = s.selfRating; practiceId = s.practiceId
        if let api = state.api { player.load(api.url("api/sessions/\(s.id)/audio")) }
        let pid = s.practiceId, sid = s.id
        player.listenHandler = { [weak state] wall, media, rate in state?.activity.add(kind: "listen_session", practiceId: pid, sessionId: sid, wall: wall, media: media, rate: rate) }
        player.flushHandler = { [weak state] in state?.activity.flush() }
    }

    private func meta(_ s: Session) -> String {
        var parts = [shortDate(s.createdAt), Scenario.label(for: s.scenario), s.language]
        if let pid = s.practiceId { parts.append("练习「\(state.practiceTitle(pid))」") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func metricTiles(_ m: Metrics) -> some View {
        let unit = m.unitLabel, band = paceBand(for: m.language)
        let paceNote = m.wpm < band.lowerBound ? "偏慢（参考 \(Int(band.lowerBound)) 到 \(Int(band.upperBound))）" : m.wpm > band.upperBound ? "偏快（参考 \(Int(band.lowerBound)) 到 \(Int(band.upperBound))）" : "在参考区间 \(Int(band.lowerBound)) 到 \(Int(band.upperBound)) 内"
        Tile(value: fmt1(m.wpm), unit: "\(unit)/分", label: "语速", note: paceNote)
        Tile(value: fmt1(m.articulationWpm), unit: "\(unit)/分", label: "去掉停顿后的语速", note: "反映说话时本身的快慢")
        Tile(value: formatClock(m.durationSec), label: "时长", note: "\(m.wordCount) \(unit)，开口 \(Int(m.speakingSec.rounded()))s")
        Tile(value: fmt1(m.fillers.perMinute), unit: "次/分", label: "填充词", note: "共 \(m.fillers.count) 次，占 \(String(format: "%.1f", m.fillers.ratio * 100))%")
        Tile(value: "\(m.pauses.count)", unit: "次", label: "停顿 ≥0.5s", note: "最长 \(fmt1(m.pauses.longestSec))s · ≥2s 的 \(m.pauses.longCount) 次 · 静音占 \(Int(m.pauses.silenceRatio * 100))%")
        Tile(value: "\(m.hedges.count)", unit: "次", label: "弱化 / 犹豫用语", note: m.hedges.breakdown.keys.sorted().prefix(3).joined(separator: ", "))
        Tile(value: "\(m.repeats)", unit: "次", label: "重复 / 卡壳", note: "连续重复的词或短语")
        Tile(value: "\(Int(m.vocabulary.typeTokenRatio * 100))", unit: "%", label: "词汇多样性", note: "\(m.vocabulary.unique) 个不同的\(unit)")
        Tile(value: fmt1(m.sentences.avgLen), unit: unit, label: "平均句长", note: "最长一句 \(m.sentences.maxLen) \(unit)")
        if let l = m.loudness, let std = l.stdDb { Tile(value: String(format: "%.2f", std), unit: "dB", label: "音量起伏", note: "平均 \(fmt1(l.meanDb ?? 0)) dBFS") }
        if let p = m.pitch, let r = p.rangeSemitones { Tile(value: fmt1(r), unit: "半音", label: "音高起伏（粗略）", note: "中位 \(fmt1(p.medianHz ?? 0)) Hz，越小越像平铺直叙") }
        Tile(value: "\(m.lowConfidenceWords)", unit: unit, label: "转写没把握的词", note: "可能是吐字不清或专有名词")
    }
}

func fmt1(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

struct CoverageSection: View {
    let coverage: Coverage
    var body: some View {
        SectionCard(title: "要点覆盖") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: tileColumns, spacing: 10) {
                    let k = coverage.counts
                    Tile(value: "\(Int(coverage.coverage * 100))%", label: "要点覆盖率", note: "讲到 \(k.covered) · 部分 \(k.partial) · 没讲 \(k.missed)，共 \(coverage.points.count) 个要点")
                    Tile(value: coverage.terms.isEmpty ? "无" : "\(coverage.termsSaid)/\(coverage.terms.count)", label: "术语说到", note: coverage.terms.isEmpty ? "原文里没有名字、缩写或数字" : "名字、缩写、数字这类不该被换掉的词")
                    Tile(value: coverage.expansion.map { String(format: "%.2f×", $0) } ?? "无", label: "发散度", note: "原文 \(coverage.scriptWords) 词，你说了 \(coverage.transcriptWords) 词")
                    Tile(value: coverage.order.map { "\(Int($0 * 100))%" } ?? "无", label: "顺序一致", note: "讲到的要点按原文顺序出现的比例")
                }
                HStack(spacing: 8) {
                    Chip(text: "讲到了", style: .good); Chip(text: "部分讲到", style: .filler); Chip(text: "没讲", style: .bad)
                    Text("判断看意思不看措辞").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(coverage.points) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.text)
                            if p.status != "covered", !p.misses.isEmpty {
                                Text("没提到：" + p.misses.joined(separator: "，")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(color(p.status), in: RoundedRectangle(cornerRadius: 6))
                        .help("\(p.status == "covered" ? "讲到了" : p.status == "partial" ? "部分讲到" : "没讲") \(Int(p.score * 100))%")
                    }
                }
                if !coverage.terms.isEmpty {
                    Text("术语").font(.caption).foregroundStyle(.secondary)
                    FlowLayout { ForEach(coverage.terms, id: \.term) { t in Chip(text: t.said ? t.term : "\(t.term) ✕", style: t.said ? .good : .bad) } }
                }
                if !coverage.extra.isEmpty {
                    Text("原文之外的内容（发散的部分，不评好坏）").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(coverage.extra.enumerated()), id: \.offset) { Text("· " + $0.element).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private func color(_ status: String) -> Color {
        status == "covered" ? Palette.malachite.opacity(0.13) : status == "partial" ? Palette.ochre.opacity(0.16) : Palette.cinnabar.opacity(0.11)
    }
}

struct PaceChart: View {
    let points: [PacePoint]
    let band: ClosedRange<Double>
    let unit: String
    var body: some View {
        if points.isEmpty {
            Text("录音太短。").foregroundStyle(.secondary)
        } else {
            Chart {
                RectangleMark(yStart: .value("low", band.lowerBound), yEnd: .value("high", band.upperBound)).foregroundStyle(Palette.malachite.opacity(0.12))
                ForEach(points, id: \.t) { p in
                    BarMark(x: .value("时间", formatClock(p.t)), y: .value("语速", p.wpm)).foregroundStyle(Palette.kyanos).cornerRadius(3)
                }
            }
            .chartYAxisLabel("\(unit)/分")
            .frame(height: 180)
            Text("绿色底为参考区间 \(Int(band.lowerBound)) 到 \(Int(band.upperBound))。同一段里忽快忽慢，通常是内容不熟或紧张。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WordsSection: View {
    let metrics: Metrics
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("填充词分布").font(.caption).foregroundStyle(.secondary)
            chips(metrics.fillers.breakdown, style: .filler)
            Text("弱化 / 犹豫用语").font(.caption).foregroundStyle(.secondary)
            chips(metrics.hedges.breakdown, style: .hedge)
            Text("高频实词").font(.caption).foregroundStyle(.secondary)
            FlowLayout { ForEach(metrics.vocabulary.topWords, id: \.word) { Chip(text: "\($0.word) ×\($0.count)") } }
        }
    }
    @ViewBuilder private func chips(_ d: [String: Int], style: Chip.Style) -> some View {
        if d.isEmpty { Text("无").foregroundStyle(.tertiary).font(.callout) }
        else { FlowLayout { ForEach(d.sorted { $0.value > $1.value }, id: \.key) { Chip(text: "\($0.key) ×\($0.value)", style: style) } } }
    }
}

/// Transcript with fillers, hedges and pauses marked, built from the timed words.
func highlightedTranscript(_ m: Metrics) -> AttributedString {
    guard let words = m.words, !words.isEmpty else { return AttributedString(m.transcript) }
    let zh = m.isChinese
    var text = ""
    for (i, w) in words.enumerated() {
        if i > 0 {
            let gap = w.start - words[i - 1].end
            if gap >= 0.5 { text += " ⏸\(String(format: "%.1f", gap))s " }
            else if !zh && !w.text.hasPrefix("-") { text += " " }
        }
        text += w.text
    }
    var attr = AttributedString(text)
    func mark(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive], _ apply: (inout AttributedSubstring) -> Void) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let group = match.numberOfRanges > 1 ? match.range(at: match.numberOfRanges - 1) : match.range
            if let r = Range(group, in: text), let ar = Range(r, in: attr) { apply(&attr[ar]) }
        }
    }
    let esc = { (s: String) in NSRegularExpression.escapedPattern(for: s) }
    if zh {
        mark("(" + HEDGES_ZH.map(esc).joined(separator: "|") + ")") { $0.backgroundColor = Palette.kyanos.opacity(0.14) }
        mark("(" + FILLERS_ZH_PLAIN.map(esc).joined(separator: "|") + ")") { $0.backgroundColor = Palette.ochre.opacity(0.26) }
        mark("(" + FILLERS_ZH_CONTEXT.map(esc).joined(separator: "|") + ")(?=[，。、？！,.!?;；:：\\s]|$)") { $0.backgroundColor = Palette.ochre.opacity(0.26) }
    } else {
        mark("\\b(" + HEDGES_EN.map(esc).joined(separator: "|") + ")\\b") { $0.backgroundColor = Palette.kyanos.opacity(0.14) }
        mark("\\b(" + FILLERS_EN.map(esc).joined(separator: "|") + ")\\b") { $0.backgroundColor = Palette.ochre.opacity(0.26) }
        mark("(?:^|[.!?,;:]\\s*)(so)\\b") { $0.backgroundColor = Palette.ochre.opacity(0.26) }
    }
    mark("⏸[0-9.]+s", options: []) { $0.foregroundColor = Palette.ink3; $0.font = .caption }
    return attr
}
