import SwiftUI
import UniformTypeIdentifiers

let SHADOW_RATES: [Float] = [0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1.0]

/// Reference audio for a practice: upload form, or the player with subtitles and speed.
struct ShadowingView: View {
    @Environment(AppState.self) private var state
    @State private var player = PlayerModel()
    @AppStorage("shadowRate") private var rate: Double = 1.0
    @State private var activeIndex: Int = -1
    @State private var showImporter = false
    @State private var pickedFile: URL?
    @State private var transcript = ""
    @State private var language = "en"

    var body: some View {
        if let p = state.practice {
            SectionCard(title: p.isClip ? "原声" : "跟读", trailing: p.reference.map { "\($0.originalName ?? $0.audioFile) · \($0.language) · 字幕来自\($0.subtitlesFrom == "transcript" ? "文稿" : "自动转写")" } ?? "") {
                if let r = p.reference { playerView(p, r) } else { uploadForm(p) }
            }
        }
    }

    // MARK: player
    @ViewBuilder
    private func playerView(_ p: Practice, _ r: Reference) -> some View {
        let m = r.metrics, unit = m.unitLabel
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: tileColumns, spacing: 10) {
                Tile(value: fmt1(m.wpm), unit: "\(unit)/分", label: "参照语速", note: "参考区间 \(Int(paceBand(for: m.language).lowerBound)) 到 \(Int(paceBand(for: m.language).upperBound))")
                Tile(value: fmt1(m.articulationWpm), unit: "\(unit)/分", label: "去掉停顿后的语速")
                Tile(value: formatClock(m.durationSec), label: "时长", note: "\(m.wordCount) \(unit)，开口 \(Int(m.speakingSec.rounded()))s")
                Tile(value: "\(m.pauses.count)", unit: "次", label: "停顿 ≥0.5s", note: "最长 \(fmt1(m.pauses.longestSec))s · 静音占 \(Int(m.pauses.silenceRatio * 100))%")
                Tile(value: fmt1(m.fillers.perMinute), unit: "次/分", label: "填充词", note: "共 \(m.fillers.count) 次")
                if let pr = m.pitch?.rangeSemitones { Tile(value: fmt1(pr), unit: "半音", label: "音高起伏（粗略）", note: "中位 \(fmt1(m.pitch?.medianHz ?? 0)) Hz") }
            }
            PlayerBar(model: player)
            HStack(spacing: 8) {
                Text("速度").foregroundStyle(.secondary)
                Picker("", selection: $rate) {
                    ForEach(SHADOW_RATES, id: \.self) { r in Text(String(format: "%.2f×", r)).tag(Double(r)) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                Spacer()
                Text("戴耳机跟着读，录音只会录到你的声音。点任意一句从该句开始播放。").font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(r.sentences) { s in
                            HStack(alignment: .top, spacing: 10) {
                                Text(formatClock(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 40, alignment: .leading).padding(.top, 2)
                                Text(s.text).foregroundStyle(s.matched == false ? .secondary : .primary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(s.i == activeIndex ? Palette.kyanos.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: s.start, andPlay: true) }
                            .id(s.i)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 360)
                .paper(radius: Radius.tile, fill: Palette.marble)
                .onChange(of: player.time) { _, t in
                    let idx = r.sentences.lastIndex { t >= $0.start - 0.05 } ?? -1
                    if idx != activeIndex { activeIndex = idx; if idx >= 0 { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(idx, anchor: .center) } } }
                }
            }
            HStack {
                Button("用当前原文重新对齐字幕") { Task { await state.retimeReference(transcript: p.script) } }
                Spacer()
                ConfirmButton(title: "删除参照", question: "练习和录音都保留。") {
                    Task { await state.deleteReference() }
                }
            }
        }
        .onChange(of: r.uploadedAt, initial: true) { _, _ in
            if let api = state.api { player.load(api.url("api/practices/\(p.id)/reference/audio")); player.setRate(Float(rate)) }
            player.listenTarget = .reference(p.id)
            player.listenHandler = { [weak state] wall, media, rate in state?.activity.add(kind: "listen_reference", practiceId: p.id, sessionId: nil, wall: wall, media: media, rate: rate) }
            player.flushHandler = { [weak state] in state?.activity.flush() }
        }
        .onChange(of: rate) { _, r in player.setRate(Float(r)) }
        .onDisappear { player.stop() }
    }

    // MARK: upload
    @ViewBuilder
    private func uploadForm(_ p: Practice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("上传一段参照音频（视频文件也行），会转写并按句对齐，然后可以调速、逐句跟读。").foregroundStyle(.secondary)
            HStack {
                Button("选择文件…") { showImporter = true }
                Text(pickedFile?.lastPathComponent ?? "还没选").foregroundStyle(.secondary)
                Picker("语言", selection: $language) { ForEach(SpeechLanguage.allCases) { Text($0.label).tag($0.rawValue) } }.frame(width: 160)
            }
            Text("文稿（可选）。填了就用它做字幕，并且在原文为空时自动填入原文；不填就用转写做字幕。").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $transcript).frame(minHeight: 80, maxHeight: 160).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("上传并分析") {
                    guard let f = pickedFile else { return }
                    Task { await state.uploadReference(fileURL: f, transcript: transcript, language: language); pickedFile = nil; transcript = "" }
                }
                .primaryGlass().disabled(pickedFile == nil || state.busy)
                if state.busy { ProgressView().controlSize(.small); Text("转写分析中，长音频要等一会…").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff, .quickTimeMovie]) { result in
            if case .success(let url) = result { pickedFile = url }
        }
    }
}
