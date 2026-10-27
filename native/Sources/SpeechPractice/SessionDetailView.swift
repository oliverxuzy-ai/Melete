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
                SectionCard(title: s.title.isEmpty ? L("录音结果", "Recording") : s.title, trailing: meta(s)) {
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
                    SectionCard(title: L("要点覆盖", "Key-point coverage")) { Text(L("这个练习还没有原文。填上原文并保存后，这里会显示要点覆盖。", "This practice has no text yet. Add it and save, and coverage shows here.")).foregroundStyle(.secondary) }
                }
                HStack(alignment: .top, spacing: 16) {
                    SectionCard(title: L("语速随时间（每 30 秒）", "Pace over time (every 30 s)")) { PaceChart(points: m.paceTimeline, band: paceBand(for: m.language), unit: m.rateUnit) }
                    SectionCard(title: L("用词", "Words")) { WordsSection(metrics: m) }
                }
                SectionCard(title: L("转写", "Transcript")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Chip(text: L("填充词", "Fillers"), style: .filler); Chip(text: L("弱化 / 犹豫用语", "Hedges"), style: .hedge)
                            Text(L("停顿 ≥ 0.5 秒标在句中", "Pauses ≥ 0.5 s are marked inline")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(highlightedTranscript(m)).lineSpacing(5).textSelection(.enabled)
                        PlayerBar(model: player)
                    }
                }
                SectionCard(title: L("我的记录", "My notes")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            HStack(spacing: 2) {
                                Text(L("自评", "Self-rating")).foregroundStyle(.secondary)
                                ForEach(1...5, id: \.self) { i in
                                    Button { rating = (rating == i) ? nil : i } label: {
                                        Image(systemName: (rating ?? 0) >= i ? "star.fill" : "star").foregroundStyle(Palette.ochre)
                                    }.buttonStyle(.plain)
                                }
                            }
                            TextField(L("标题", "Title"), text: $title).frame(maxWidth: 260)
                            Picker(L("归属练习", "Practice"), selection: Binding(get: { practiceId ?? "" }, set: { practiceId = $0.isEmpty ? nil : $0 })) {
                                Text(L("未分组", "Ungrouped")).tag("")
                                ForEach(state.practices) { Text($0.title).tag($0.id) }
                            }.frame(maxWidth: 320)
                        }
                        TextEditor(text: $notes).frame(minHeight: 70).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            .overlay(alignment: .topLeading) {
                                if notes.isEmpty { Text(L("这次想练什么？哪里卡住了？下次改什么？", "What were you working on? Where did you get stuck? What will you change next time?")).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) }
                            }
                        HStack {
                            Button(L("保存记录", "Save notes")) { Task { await state.saveSession(title: title, notes: notes, rating: rating, practiceId: practiceId) } }
                                .primaryGlass()
                            Button(L("重新分析", "Reanalyze")) { Task { await state.reanalyzeSession(language: s.language) } }.disabled(state.busy)
                            Text(L("重新分析会用当前模型和设置重跑转写，笔记和归属不变", "Reruns transcription with the current model and settings; notes and practice stay")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            ConfirmButton(title: L("删除这次录音", "Delete this recording"), question: L("录音和分析都会删掉。", "The recording and its analysis will be deleted.")) {
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
        if let pid = s.practiceId { parts.append(L("练习「\(state.practiceTitle(pid))」", "practice “\(state.practiceTitle(pid))”")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func metricTiles(_ m: Metrics) -> some View {
        let unit = m.unitLabel, band = paceBand(for: m.language)
        let range = L("\(Int(band.lowerBound)) 到 \(Int(band.upperBound))", "\(Int(band.lowerBound))–\(Int(band.upperBound))")
        let paceNote = m.wpm < band.lowerBound ? L("偏慢（参考 \(range)）", "On the slow side (reference \(range))")
            : m.wpm > band.upperBound ? L("偏快（参考 \(range)）", "On the fast side (reference \(range))")
            : L("在参考区间 \(range) 内", "Inside the reference range \(range)")
        Tile(value: fmt1(m.wpm), unit: m.rateUnit, label: L("语速", "Pace"), note: paceNote)
        Tile(value: fmt1(m.articulationWpm), unit: m.rateUnit, label: L("去掉停顿后的语速", "Pace without pauses"), note: L("反映说话时本身的快慢", "How fast you talk while talking"))
        Tile(value: formatClock(m.durationSec), label: L("时长", "Length"), note: L("\(m.wordCount) \(unit)，开口 \(Int(m.speakingSec.rounded()))s", "\(m.wordCount) \(unit), \(Int(m.speakingSec.rounded())) s speaking"))
        Tile(value: fmt1(m.fillers.perMinute), unit: L("次/分", "/min"), label: L("填充词", "Fillers"),
             note: L("共 \(m.fillers.count) 次，占 \(String(format: "%.1f", m.fillers.ratio * 100))%", "\(m.fillers.count) in all, \(String(format: "%.1f", m.fillers.ratio * 100))% of words"))
        Tile(value: "\(m.pauses.count)", unit: L("次", ""), label: L("停顿 ≥0.5s", "Pauses ≥0.5s"),
             note: L("最长 \(fmt1(m.pauses.longestSec))s · ≥2s 的 \(m.pauses.longCount) 次 · 静音占 \(Int(m.pauses.silenceRatio * 100))%",
                     "Longest \(fmt1(m.pauses.longestSec))s · \(m.pauses.longCount) of ≥2s · \(Int(m.pauses.silenceRatio * 100))% silence"))
        Tile(value: "\(m.hedges.count)", unit: L("次", ""), label: L("弱化 / 犹豫用语", "Hedges"), note: m.hedges.breakdown.keys.sorted().prefix(3).joined(separator: ", "))
        Tile(value: "\(m.repeats)", unit: L("次", ""), label: L("重复 / 卡壳", "Repeats / stumbles"), note: L("连续重复的词或短语", "Words or phrases said twice in a row"))
        Tile(value: "\(Int(m.vocabulary.typeTokenRatio * 100))", unit: "%", label: L("词汇多样性", "Vocabulary variety"), note: L("\(m.vocabulary.unique) 个不同的\(unit)", "\(m.vocabulary.unique) different \(unit)"))
        Tile(value: fmt1(m.sentences.avgLen), unit: unit, label: L("平均句长", "Average sentence"), note: L("最长一句 \(m.sentences.maxLen) \(unit)", "Longest \(m.sentences.maxLen) \(unit)"))
        if let l = m.loudness, let std = l.stdDb { Tile(value: String(format: "%.2f", std), unit: "dB", label: L("音量起伏", "Volume variation"), note: L("平均 \(fmt1(l.meanDb ?? 0)) dBFS", "Average \(fmt1(l.meanDb ?? 0)) dBFS")) }
        if let p = m.pitch, let r = p.rangeSemitones { Tile(value: fmt1(r), unit: L("半音", "semitones"), label: L("音高起伏（粗略）", "Pitch range (rough)"), note: L("中位 \(fmt1(p.medianHz ?? 0)) Hz，越小越像平铺直叙", "Median \(fmt1(p.medianHz ?? 0)) Hz; the smaller, the flatter it sounds")) }
        Tile(value: "\(m.lowConfidenceWords)", unit: unit, label: L("转写没把握的词", "Unsure words"), note: L("可能是吐字不清或专有名词", "Maybe unclear speech or proper names"))
    }
}

func fmt1(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

struct CoverageSection: View {
    let coverage: Coverage
    var body: some View {
        SectionCard(title: L("要点覆盖", "Key-point coverage")) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: tileColumns, spacing: 10) {
                    let k = coverage.counts
                    let none = L("无", "None")
                    Tile(value: "\(Int(coverage.coverage * 100))%", label: L("要点覆盖率", "Coverage"),
                         note: L("讲到 \(k.covered) · 部分 \(k.partial) · 没讲 \(k.missed)，共 \(coverage.points.count) 个要点",
                                 "Covered \(k.covered) · partly \(k.partial) · missed \(k.missed), of \(plural(coverage.points.count, "point"))"))
                    Tile(value: coverage.terms.isEmpty ? none : "\(coverage.termsSaid)/\(coverage.terms.count)", label: L("术语说到", "Terms said"),
                         note: coverage.terms.isEmpty ? L("原文里没有名字、缩写或数字", "No names, acronyms or numbers in the text") : L("名字、缩写、数字这类不该被换掉的词", "Names, acronyms, numbers: words that shouldn't change"))
                    Tile(value: coverage.expansion.map { String(format: "%.2f×", $0) } ?? none, label: L("发散度", "Expansion"),
                         note: L("原文 \(coverage.scriptWords) 词，你说了 \(coverage.transcriptWords) 词", "Text \(coverage.scriptWords) words, you said \(coverage.transcriptWords)"))
                    Tile(value: coverage.order.map { "\(Int($0 * 100))%" } ?? none, label: L("顺序一致", "Same order"), note: L("讲到的要点按原文顺序出现的比例", "Share of covered points said in the text's order"))
                }
                HStack(spacing: 8) {
                    Chip(text: L("讲到了", "Covered"), style: .good); Chip(text: L("部分讲到", "Partly"), style: .filler); Chip(text: L("没讲", "Missed"), style: .bad)
                    Text(L("判断看意思不看措辞", "Judged by meaning, not wording")).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(coverage.points) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.text)
                            if p.status != "covered", !p.misses.isEmpty {
                                Text(L("没提到：", "Not mentioned: ") + p.misses.joined(separator: L("，", ", "))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(color(p.status), in: RoundedRectangle(cornerRadius: 6))
                        .help("\(p.status == "covered" ? L("讲到了", "Covered") : p.status == "partial" ? L("部分讲到", "Partly") : L("没讲", "Missed")) \(Int(p.score * 100))%")
                    }
                }
                if !coverage.terms.isEmpty {
                    Text(L("术语", "Terms")).font(.caption).foregroundStyle(.secondary)
                    FlowLayout { ForEach(coverage.terms, id: \.term) { t in Chip(text: t.said ? t.term : "\(t.term) ✕", style: t.said ? .good : .bad) } }
                }
                if !coverage.extra.isEmpty {
                    Text(L("原文之外的内容（发散的部分，不评好坏）", "Beyond the text (where you expanded; not judged)")).font(.caption).foregroundStyle(.secondary)
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
            Text(L("录音太短。", "Too short to chart.")).foregroundStyle(.secondary)
        } else {
            Chart {
                RectangleMark(yStart: .value("low", band.lowerBound), yEnd: .value("high", band.upperBound)).foregroundStyle(Palette.malachite.opacity(0.12))
                ForEach(points, id: \.t) { p in
                    BarMark(x: .value(L("时间", "Time"), formatClock(p.t)), y: .value(L("语速", "Pace"), p.wpm)).foregroundStyle(Palette.kyanos).cornerRadius(3)
                }
            }
            .chartYAxisLabel(unit)
            .frame(height: 180)
            Text(L("绿色底为参考区间 \(Int(band.lowerBound)) 到 \(Int(band.upperBound))。同一段里忽快忽慢，通常是内容不熟或紧张。",
                   "Green is the reference range, \(Int(band.lowerBound))–\(Int(band.upperBound)). Speeding up and slowing down within one take usually means the material isn't familiar yet, or nerves.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WordsSection: View {
    let metrics: Metrics
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("填充词分布", "Fillers")).font(.caption).foregroundStyle(.secondary)
            chips(metrics.fillers.breakdown, style: .filler)
            Text(L("弱化 / 犹豫用语", "Hedges")).font(.caption).foregroundStyle(.secondary)
            chips(metrics.hedges.breakdown, style: .hedge)
            Text(L("高频实词", "Most used words")).font(.caption).foregroundStyle(.secondary)
            FlowLayout { ForEach(metrics.vocabulary.topWords, id: \.word) { Chip(text: "\($0.word) ×\($0.count)") } }
        }
    }
    @ViewBuilder private func chips(_ d: [String: Int], style: Chip.Style) -> some View {
        if d.isEmpty { Text(L("无", "None")).foregroundStyle(.tertiary).font(.callout) }
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
