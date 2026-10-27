import SwiftUI

/// A practice studio. 跟读 listens to someone else first; 主题 is you, on a topic.
/// The stage sits in the middle and the material for this studio lies on a shelf below it.
/// Nothing moves when you start: the shelf only fades, so the button stays under your hand.
struct StudioView: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage

    /// 跟读 or 主题: the studio is one view whose material changes, never two views swapped.
    private var space: Space { state.studio }
    private var mine: Bool { stage.studio == space }
    private var front: Bool { state.space != .home }

    var body: some View {
        let _ = FrameProbe.drawnStudio = space.rawValue
        // The verdict takes the room of the controls and the shelf, so it fits a short window.
        let showsResult = mine && stage.phase == .result && stage.result != nil
        ZStack {
            RadialGradient(colors: [Palette.kyanos.opacity(0.10), .clear], center: .center, startRadius: 40, endRadius: 560)
                .opacity(stage.phase == .recording ? 1 : 0.4)
                .animation(Motion.paper, value: stage.phase == .recording)
                .allowsHitTesting(false)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                StudioHeader(space: space)
                Spacer(minLength: 6)
                let _ = FrameProbe.drawnVerdict = mine && stage.phase == .result && stage.result != nil
                Group {
                    if mine, stage.phase == .result, let s = stage.result {
                        VerdictCard(session: s)
                            .transition(.asymmetric(insertion: .scale(scale: 1.03).combined(with: .opacity), removal: .opacity))
                    } else if mine && stage.hasMaterial {
                        StagePanel()
                            .transition(.opacity)
                    } else {
                        StudioEmpty(space: space)
                    }
                }
                .animation(Motion.stone, value: stage.phase)
                Spacer(minLength: 6)
                // Hidden from VoiceOver button by button, never with a false on a container: an
                // outer accessibilityHidden(false) overrides the hiding inside it.
                StageControls(shown: mine && stage.hasMaterial && stage.phase != .result)
                    .opacity(mine && stage.hasMaterial && stage.phase != .result ? 1 : 0)
                    .disabled(!(mine && stage.hasMaterial && stage.phase != .result))
                    .padding(.bottom, 16)
                    .frame(height: showsResult ? 0 : nil, alignment: .top)
                ShelfView(space: space)
                    .frame(height: showsResult ? 0 : 124, alignment: .top)
                    .opacity(stage.isActive || showsResult ? 0 : 1)
                    .disabled(stage.isActive || showsResult)
                    .accessibilityHidden(stage.isActive || showsResult)
                    .animation(Motion.paper, value: stage.isActive)
                    .animation(Motion.paper, value: showsResult)
            }
            .padding(.horizontal, 36).padding(.bottom, 12)
            // Keys belong to the studio only while it is in front and no tray is open.
            if state.tray == nil && front { StageShortcuts() }
            StageTracker()
        }
        .onAppear { stage.prepare(for: space) }
        .onChange(of: state.studio) { _, s in stage.prepare(for: s) }
        .onChange(of: state.today?.date) { _, _ in stage.prepare(for: space, force: true) }
    }
}

/// Follows playback and the live transcript without making the studio re-render.
struct StageTracker: View {
    @Environment(StageModel.self) private var stage
    @Environment(Recorder.self) private var recorder

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: stage.player.time) { _, t in
                // A line lights up a moment before it is spoken, so the eye is there first.
                guard !stage.followsVoice, let r = stage.practice?.reference else { return }
                let idx = r.sentences.lastIndex { t >= $0.start - 0.25 } ?? -1
                if idx != stage.activeSentence { stage.activeSentence = idx }
            }
            .onChange(of: recorder.lastFinalChunk) { _, chunk in stage.teleprompter.advance(with: chunk) }
            .onChange(of: recorder.liveVolatile) { _, v in stage.heard(finals: recorder.liveSentences, volatile: v) }
            .onChange(of: recorder.liveSentences.count) { _, _ in stage.heard(finals: recorder.liveSentences, volatile: recorder.liveVolatile) }
    }
}

struct StudioHeader: View {
    let space: Space
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage

    private var mine: Bool { stage.studio == space }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mine && !stage.eyebrow.isEmpty ? stage.eyebrow : space.label)
                    .font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                Text(mine && !stage.title.isEmpty ? stage.title : space.greek)
                    .font(Typeface.display(26)).foregroundStyle(mine ? Palette.ink : Palette.ink3).lineLimit(1)
            }
            Spacer()
            // The pulse is a symbol effect, run by Core Animation rather than redrawn each frame.
            // The same corner says when a recording could not be kept.
            ZStack(alignment: .trailing) {
                if stage.phase == .recording && mine {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Palette.cinnabar)
                            .symbolEffect(.pulse, options: .repeating)
                        Text(L("录音中", "Recording")).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.cinnabar)
                    }
                    .transition(.opacity)
                } else if let note = stage.notice, mine {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.ochre)
                        Text(note).font(Typeface.ui(12)).foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                } else if mine, !stage.isActive, let p = stage.practice {
                    // The way into what is on stage: its text, its attempts, editing and deleting.
                    Button(p.reference != nil ? L("原文和记录", "Original and takes") : L("编辑讲稿，看记录", "Edit script, see takes")) { Task { await state.openTray(.practice(p.id)) } }
                        .buttonStyle(InkButtonStyle())
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 520, alignment: .trailing)
            .animation(Motion.paper, value: stage.phase == .recording)
            .animation(Motion.paper, value: stage.notice)
        }
        .frame(height: 56)
    }
}

/// The three columns: material on the left, the water clock in the middle, your pace on the right.
/// Each column observes only what it shows.
struct StagePanel: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage
    @Environment(Recorder.self) private var recorder

    var body: some View {
        // Side columns give way down to 240 so the stage fits the smallest window (1040 wide).
        HStack(alignment: .center, spacing: 40) {
            StageLeft().frame(minWidth: 240, idealWidth: 300, maxWidth: 300, alignment: .leading)
            VStack(spacing: 14) {
                VoiceOrb(level: { [meter = recorder.meter] in meter.read() },
                         remaining: { [stage] t in stage.remaining(at: t) },
                         live: stage.phase == .recording || stage.phase == .countdown,
                         visible: state.space != .home,
                         size: 240)
                    .overlay { OrbCaption() }
                    .frame(height: 300)
                ClockLine()
            }
            .frame(maxWidth: .infinity)
            StageRight().frame(minWidth: 240, idealWidth: 300, maxWidth: 300, alignment: .leading)
        }
    }
}

struct OrbCaption: View {
    @Environment(StageModel.self) private var stage

    var body: some View {
        ZStack {
            switch stage.phase {
            case .countdown:
                Text(L("准备", "Ready")).font(Typeface.display(26)).foregroundStyle(.white.opacity(0.92)).shadow(radius: 6)
            case .listening:
                VStack(spacing: 8) {
                    Image(systemName: "ear").font(.system(size: 26, weight: .light))
                    Text(stage.player.playing ? L("原文播放中", "Original playing") : L("原文已暂停", "Original paused")).font(Typeface.display(20))
                    Button(L("停止播放", "Stop playback")) { stage.cancel() }
                        .buttonStyle(InkButtonStyle(color: Palette.ink2))
                        .help(L("停下原文，回到准备（Esc）", "Stop the original and go back to ready (Esc)"))
                }
                .foregroundStyle(Palette.kyanos)
            case .analyzing:
                Text(L("正在听你说的", "Listening to your take")).font(Typeface.display(18)).foregroundStyle(Palette.kyanos)
            case .queued:
                Text(L("已保存", "Saved")).font(Typeface.display(20)).foregroundStyle(Palette.kyanos)
            case .ready:
                Text(stage.readyPrompt)
                    .font(Typeface.display(19)).multilineTextAlignment(.center).lineSpacing(4)
                    .foregroundStyle(stage.targetSeconds == nil ? Color.white.opacity(0.95) : Palette.kyanos)
            default:
                EmptyView()
            }
        }
        .transition(.opacity)
        .animation(Motion.paper, value: stage.phase)
    }
}

struct StageLeft: View {
    @Environment(StageModel.self) private var stage

    var body: some View {
        if let r = stage.practice?.reference, stage.mode == .shadow || stage.phase == .listening {
            ReferenceLines(sentences: r.sentences, active: stage.activeSentence,
                           onTap: stage.canJump ? { stage.jump(to: $0) } : nil,
                           tapHelp: stage.phase == .recording ? L("读到这一句了：字幕从这里接着跟你", "I'm here: the subtitles follow you from this line")
                                                              : L("从这一句开始听原文", "Play the original from this line"))
        } else if stage.mode == .retell {
            // After listening, the transcript stays away: retelling means your own words.
            VStack(alignment: .leading, spacing: 12) {
                Text(L("用自己的话讲一遍", "Say it in your own words")).font(Typeface.display(21)).foregroundStyle(Palette.ink)
                Text(L("不用逐句复原。先说他的核心观点，再讲他用的一个例子，最后说你怎么看。",
                       "No need to recall it line by line. Give the speaker's main point, then one example they used, then what you think."))
                    .font(Typeface.italic(15)).foregroundStyle(Palette.ink2).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let notes = stage.practice?.notes, !notes.isEmpty {
                    Text(notes).font(Typeface.ui(13)).foregroundStyle(Palette.ink2).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let prompt = stage.prompt {
            VStack(alignment: .leading, spacing: 12) {
                Text(prompt).font(Typeface.display(19)).foregroundStyle(Palette.ink).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = stage.hint {
                    Text(hint).font(Typeface.italic(14)).foregroundStyle(Palette.ink2).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if !stage.teleprompter.sentences.isEmpty {
            ScriptLines(teleprompter: stage.teleprompter, live: stage.phase == .recording)
        } else if let hint = stage.hint {
            Text(hint).font(Typeface.italic(16)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StageRight: View {
    @Environment(StageModel.self) private var stage
    @Environment(Recorder.self) private var recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LivePace()
            if stage.mode != .shadow {
                LiveLines(sentences: recorder.liveSentences, volatile: recorder.liveVolatile, recording: stage.phase == .recording)
            } else if stage.phase == .recording {
                if stage.followsVoice {
                    Text(L("外放时不放原声，免得录进去。按你自己的速度读，字幕跟着你走；跟丢了就点你读到的那一句。",
                           "On speakers the original stays silent so it isn't recorded. Read at your own pace and the subtitles follow you; if they lose you, click the line you're on."))
                        .font(Typeface.ui(12)).foregroundStyle(Palette.ink2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if stage.player.silenced {
                    Text(L("外放时不放原声，免得录进去。跟着左边字幕的节奏读。",
                           "On speakers the original stays silent so it isn't recorded. Read along with the subtitles on the left."))
                        .font(Typeface.ui(12)).foregroundStyle(Palette.ink2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if let notes = stage.practice?.notes, !notes.isEmpty {
                    Text(notes).font(Typeface.italic(13)).foregroundStyle(Palette.ink2).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(stage.routeIsPrivate
                     ? L("戴着耳机：录音时原声在耳机里同步播放，你跟着说。",
                         "Headphones on: while you record, the original plays in your ears and you speak along.")
                     : L("现在是外放：录音时不放原声，字幕跟着你读到哪里往下走。戴耳机可以边听原声边跟。",
                         "On speakers: the original stays silent while you record and the subtitles move with your reading. With headphones you can hear it as you go."))
                    .font(Typeface.ui(12)).foregroundStyle(Palette.ink3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Elapsed and target time. Reads the recorder on its own so the rest of the panel does not
/// re-render five times a second. The digits change like a clock's, with no rolling: a
/// numeric text transition every second cost more per frame than the whole water clock.
struct ClockLine: View {
    @Environment(StageModel.self) private var stage
    @Environment(Recorder.self) private var recorder

    var body: some View {
        let _ = FrameProbe.drawnClock = formatClock(stage.phase == .recording ? recorder.elapsed : 0)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(formatClock(stage.phase == .recording ? recorder.elapsed : 0))
                .font(Typeface.display(30)).monospacedDigit().foregroundStyle(Palette.ink)
            if let t = stage.targetSeconds {
                Text("/ \(formatClock(t))").font(Typeface.ui(14)).foregroundStyle(Palette.ink3)
            }
        }
    }
}

/// Live pace against this week's band, refreshed once a second. Plain digits, for the same
/// reason as the clock.
struct LivePace: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage
    @Environment(Recorder.self) private var recorder

    private var band: ClosedRange<Double> { state.today?.targets.band ?? 140...165 }
    private var live: Bool { stage.phase == .recording && recorder.liveWPM > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("语速", "Pace")).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(live ? recorder.liveWPM : 0))").font(Typeface.display(44)).monospacedDigit()
                    .foregroundStyle(live && band.contains(recorder.liveWPM) ? Palette.malachite : Palette.ink)
                Text(L("词/分", "wpm")).font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
            }
            PaceGauge(wpm: live ? recorder.liveWPM : nil, band: band, reference: stage.practice?.reference?.metrics.wpm)
            Text(caption).font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
        }
    }

    private var caption: String {
        var s = L("绿色是本周目标 \(Int(band.lowerBound)) 到 \(Int(band.upperBound))", "Green is this week's target, \(Int(band.lowerBound))–\(Int(band.upperBound))")
        if let w = stage.practice?.reference?.metrics.wpm { s += L("，金色刻度是原声 \(Int(w))", "; the gold tick is the original, \(Int(w))") }
        return s
    }
}

/// One primary button that changes in place (start, start now, stop, analysing), flanked by
/// two fixed slots. Pieces fade in their slots instead of reflowing, so the button never
/// slides out from under the pointer.
struct StageControls: View {
    /// False while the controls are faded out (a verdict, or nothing on stage).
    var shown = true
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage

    private var canListen: Bool { stage.practice?.reference != nil && (stage.phase == .ready || stage.phase == .listening) }
    private var canDiscard: Bool { stage.phase == .recording }
    private var showsRate: Bool { stage.mode == .shadow && [.ready, .countdown, .recording, .listening].contains(stage.phase) }

    var body: some View {
        HStack(spacing: 16) {
            // Fixed slots, so the main button never moves. The left one holds 听原文 before a
            // take and 放弃这段 during one; a button that does not apply is not there at all
            // (hidden by opacity it would still be read out and pressable by VoiceOver).
            ZStack(alignment: .trailing) {
                if shown && canListen { listenButton.transition(.opacity) }
                if shown && canDiscard { discardButton.transition(.opacity) }
            }
            .frame(width: 170, height: 44, alignment: .trailing)
            // While the controls are faded out the button is not there for VoiceOver either;
            // a clear block of the same size keeps the row in place.
            if shown { mainButton } else { Color.clear.frame(width: 150, height: 44) }
            ZStack(alignment: .leading) {
                if shown && showsRate { rateChips.transition(.opacity) }
            }
            .frame(width: 170, height: 44, alignment: .leading)
        }
        .animation(Motion.paper, value: stage.phase)
    }

    /// Throws the take away: nothing saved, nothing analysed.
    private var discardButton: some View {
        Button { stage.discard("button") } label: {
            Label(L("放弃这段", "Discard take"), systemImage: "xmark")
                .font(Typeface.ui(13, .medium)).foregroundStyle(Palette.ink2)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("不保存，不分析（Esc）", "Not saved, not analyzed (Esc)"))
    }

    /// Only ever plays the original: 听原文, then 暂停 and 继续听 while it plays.
    private var listenButton: some View {
        Button { stage.phase == .listening ? stage.player.toggle() : stage.listen() } label: {
            Label(stage.listenLabel, systemImage: stage.phase != .listening ? "ear" : (stage.player.playing ? "pause.fill" : "play.fill"))
                .font(Typeface.ui(13, .medium)).foregroundStyle(Palette.ink)
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassEffect(canListen ? .regular.interactive() : .identity, in: .capsule)
    }

    private var rateChips: some View {
        HStack(spacing: 2) {
            ForEach([0.8, 0.9, 1.0], id: \.self) { r in
                Button { stage.setRate(r) } label: {
                    Text(String(format: "%.1f×", r)).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .foregroundStyle(stage.rate == r ? .white : Palette.ink2)
                        .background(stage.rate == r ? Palette.kyanos : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(showsRate ? .regular : .identity, in: .capsule)
    }

    private var mainButton: some View {
        let recording = stage.phase == .recording
        let busy = stage.phase == .analyzing
        return Button { stage.start("button") } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(stage.mainLabel).contentTransition(.opacity)
                let _ = FrameProbe.drawnMainLabel = stage.mainLabel
            }
            .font(Typeface.ui(14, .semibold))
            .foregroundStyle(.white)
            .frame(width: 150, height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(recording ? Palette.cinnabar : Palette.kyanos).interactive(), in: .capsule)
        .disabled(busy)
        .accessibilityHidden(!shown)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { FrameProbe.mainButton = $0 }
        .keyboardShortcut((stage.phase == .ready || stage.phase == .listening) && state.tray == nil && state.space != .home ? .defaultAction : nil)
        .help(L("回车开始，空格开始或停止，Esc 退回或放弃这段", "Return starts, Space starts or stops, Esc steps back or discards the take"))
    }
}

/// Space starts or stops; Esc steps back to ready. Only present while no tray is open,
/// so typing in a tray never reaches the stage.
struct StageShortcuts: View {
    @Environment(StageModel.self) private var stage

    var body: some View {
        ZStack {
            Button("") { stage.start("space") }.keyboardShortcut(.space, modifiers: [])
            Button("") { stage.cancel() }.keyboardShortcut(.cancelAction)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
        .accessibilityHidden(true)   // keys only; VoiceOver should not find two unnamed buttons
    }
}

/// When a studio has nothing on its stage yet.
struct StudioEmpty: View {
    let space: Space
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 14) {
            Text(space == .shadow ? L("今天的片段还在路上", "Today's clips are on their way") : L("还没有要讲的主题", "Nothing to talk about yet"))
                .font(Typeface.display(26)).foregroundStyle(Palette.ink)
            Text(message)
                .font(Typeface.ui(14)).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if space == .shadow {
                    Button(L("贴一个链接", "Paste a link")) { Task { await state.openTray(.addLink) } }.primaryGlass()
                    Button(L("现在就挑", "Pick now")) { Task { await state.refreshClips(force: false) } }.buttonStyle(.glass).controlSize(.large)
                } else {
                    Button(L("新讲稿", "New script")) { Task { await state.openTray(.newTopic) } }.primaryGlass()
                    Button(L("加一场", "Add a talk")) { Task { await state.openTray(.newEvent) } }.buttonStyle(.glass).controlSize(.large)
                }
            }
        }
        .frame(maxWidth: 520)
    }

    private var message: String {
        guard space == .shadow else { return L("写一份讲稿或要点，或者加一场要讲的会。", "Write a script or a few points, or add a talk you have coming up.") }
        if let m = state.today?.daily.message, !m.isEmpty { return m }
        return L("每天清晨会从演讲里挑一两段。也可以现在贴一个链接。", "Every morning one or two passages are picked from talks. You can also paste a link now.")
    }
}

// MARK: - Shelf

/// The material for a studio, left to right: today first, then what you saved, then the library.
struct ShelfView: View {
    let space: Space
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if space == .shadow { shadowCards } else { topicCards }
            }
            .padding(.horizontal, 2).padding(.vertical, 6)
        }
        .scrollClipDisabled()
        .task(id: space) { if space == .topic && state.agenda == nil { await state.loadAgenda() } }
    }

    private var todayItems: [PlanItem] { (state.today?.items ?? []).filter { Space.of(kind: $0.kind) == space } }

    @ViewBuilder private var shadowCards: some View {
        let todays = todayItems
        let todayIDs = Set(todays.compactMap(\.practiceId))
        ForEach(todays) { item in
            ShelfCard(kind: item.kindLabel, title: item.title, meta: L("今天，\(durationLabel(item.seconds))", "Today, \(durationLabel(item.seconds))"),
                      done: item.done, selected: stage.item?.id == item.id) {
                stage.present(item: item, autoStart: false)
            }
        }
        // The daily clips and the ones you brought in yourself, most recent first.
        ForEach(state.shadowPractices.filter { !todayIDs.contains($0.id) }
                    .sorted { String(($0.clip?.date ?? $0.lastAt ?? $0.createdAt).prefix(10)) > String(($1.clip?.date ?? $1.lastAt ?? $1.createdAt).prefix(10)) }
                    .prefix(16)) { c in
            let when = c.isClip ? c.clip?.date.map { relativeDay($0) } : (c.sessionCount > 0 ? L("练过 \(c.sessionCount) 遍", "Practiced \(plural(c.sessionCount, "time"))") : L("自己导入", "Imported"))
            ShelfCard(kind: c.clip?.role == "explain" ? L("复述", "Retell") : L("跟读", "Shadow"), title: c.title,
                      meta: [when, c.refDuration.map { durationLabel(Int($0.rounded())) }].compactMap { $0 }.joined(separator: L("，", ", ")),
                      done: c.sessionCount > 0, selected: stage.item == nil && stage.practice?.id == c.id) {
                Task {
                    if let p = await state.fetchPractice(c.id) {
                        stage.present(practice: p, mode: c.clip?.role == "explain" ? .retell : .shadow, autoStart: false)
                    }
                }
            }
        }
        AddCard(title: L("全部片段", "All clips"), detail: L("按天看挑过的片段和听点", "Every clip picked, by day, with notes"), symbol: "square.stack") { Task { await state.openTray(.clips) } }
        AddCard(title: L("贴链接", "Paste a link"), detail: L("把一段演讲做成片段", "Turn part of a talk into a clip"), symbol: "link") { Task { await state.openTray(.addLink) } }
    }

    @ViewBuilder private var topicCards: some View {
        ForEach(todayItems) { item in
            ShelfCard(kind: item.kindLabel, title: item.kind == "impromptu" ? (item.prompt ?? item.title) : item.title,
                      meta: L("今天，\(item.subtitle)", "Today, \(item.subtitle)"),
                      done: item.done, selected: stage.item?.id == item.id) {
                stage.present(item: item, autoStart: false)
            }
        }
        if todayItems.contains(where: { $0.kind == "impromptu" && !$0.done }) {
            AddCard(title: L("换一个题", "Another prompt"), detail: L("同一种练法，换个题目", "Same exercise, a different prompt"), symbol: "arrow.triangle.2.circlepath") {
                Task {
                    await state.shufflePrompt()
                    if let it = state.today?.items.first(where: { $0.kind == "impromptu" }) { stage.present(item: it, autoStart: false) }
                }
            }
        }
        ForEach((state.agenda?.events ?? []).filter { !$0.past && $0.daysLeft > 10 }) { ev in
            ShelfCard(kind: L("议程", "Agenda"), title: ev.title, meta: L("\(ev.daysLeft) 天后，\(ev.kindLabel)", "In \(plural(ev.daysLeft, "day")), \(ev.kindLabel)"), done: false,
                      selected: stage.item == nil && stage.practice?.id == ev.practiceId) {
                Task {
                    if let pid = ev.practiceId, let p = await state.fetchPractice(pid) { stage.present(practice: p, mode: .free, autoStart: false) }
                }
            }
        }
        ForEach(state.userPractices.filter { $0.kind != "agenda" }) { p in
            ShelfCard(kind: L("讲稿", "Script"), title: p.title, meta: p.sessionCount > 0 ? L("练过 \(p.sessionCount) 遍", "Practiced \(plural(p.sessionCount, "time"))") : L("还没练过", "Not practiced yet"),
                      done: false, selected: stage.item == nil && stage.practice?.id == p.id) {
                Task {
                    if let full = await state.fetchPractice(p.id) { stage.present(practice: full, mode: full.reference != nil ? .shadow : .free, autoStart: false) }
                }
            }
            .contextMenu {
                Button(L("编辑讲稿，看记录", "Edit script, see takes")) { Task { await state.openTray(.practice(p.id)) } }
            }
        }
        AddCard(title: L("新讲稿", "New script"), detail: L("写下要点，练到熟", "Write the points, practice until they flow")) { Task { await state.openTray(.newTopic) } }
        AddCard(title: L("议程", "Agenda"), detail: L("评审、1:1、面试，倒排备讲", "Reviews, 1:1s, interviews, prepped backwards"), symbol: "calendar") { Task { await state.openTray(.agenda) } }
    }
}

struct ShelfCard: View {
    let kind: String
    let title: String
    let meta: String
    let done: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(kind).font(Typeface.ui(11, .medium)).foregroundStyle(selected ? Palette.kyanos : Palette.ink2)
                    Spacer()
                    if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ochre) }
                }
                Text(title).font(Typeface.display(14)).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(meta).font(Typeface.ui(11)).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            .padding(12)
            .frame(width: 210, height: 104, alignment: .topLeading)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .strokeBorder(selected ? Palette.kyanos : Palette.vein, lineWidth: selected ? 1.5 : 1))
            .offset(y: hover && !selected ? -2 : 0)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.ticker) { hover = h } }
    }
}

struct AddCard: View {
    let title: String
    let detail: String
    var symbol = "plus"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.kyanos)
                Text(title).font(Typeface.display(14)).foregroundStyle(Palette.ink)
                Text(detail).font(Typeface.ui(11)).foregroundStyle(Palette.ink3).lineLimit(2)
            }
            .padding(12)
            .frame(width: 150, height: 104, alignment: .topLeading)
            .background(Palette.marble, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .strokeBorder(Palette.vein, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .buttonStyle(.plain)
    }
}
