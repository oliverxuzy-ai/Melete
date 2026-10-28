import SwiftUI

/// The speaking stage (the Athenian bema). One place where every drill happens:
/// read the prompt, the water clock fills, you speak, the verdict is set in stone.
@Observable
@MainActor
final class StageModel {
    enum Mode: String { case shadow, retell, impromptu, agenda, free }
    enum Phase: Equatable { case ready, countdown, listening, recording, analyzing, result, queued }

    /// Changes are plain assignments; each view animates them itself. Wrapping a change in
    /// `withAnimation` right after other changes made SwiftUI draw the earlier ones first and
    /// then drop this one for views that had just been drawn: the button kept saying 现在开始
    /// while recording. The same holds for every other state the views watch.
    var phase: Phase = .ready
    var mode: Mode = .free
    var item: PlanItem?
    var practice: Practice?
    var title = ""
    var eyebrow = ""
    var prompt: String?
    var hint: String?
    var targetSeconds: Double?
    var result: Session?
    var countdownFill: Double = 0
    @ObservationIgnored var countdownStartedAt: Date?
    var rate: Double = 1.0
    var activeSentence = -1
    let player = PlayerModel()
    var teleprompter = Teleprompter()
    /// The language you speak in this take: it picks the live recognizer and the server's
    /// Whisper model. It follows the material on stage (a Chinese script is spoken in Chinese).
    var language = "en"
    var startedAt: Date?
    /// A short line under the button when something did not go as asked (a recording too short
    /// to keep, a microphone that dropped out). Clears itself.
    var notice: String?
    /// The original was heard to its end since this material went on stage.
    var heardThrough = false
    /// Sound goes to headphones, so the original can play while you record.
    var routeIsPrivate = false
    /// Shadowing on speakers: the original stays silent and the subtitles follow your voice
    /// through the live transcript, at your pace rather than the original's.
    private(set) var followsVoice = false
    @ObservationIgnored private(set) var follower = VoiceFollower()
    /// Words of a line still to come when the subtitles move on to the next one: the live
    /// transcript runs a little behind the voice, so the next line is in place when you reach it.
    /// One word with the dictation recognizer (about 0.3 s behind), two with the transcriber
    /// (about 0.65 s behind). Replayed against real speech, both lit every line before the voice
    /// reached it, and left the line being read at most about a second before its end.
    @ObservationIgnored private(set) var followLead = 1
    /// Shadowing that will be on speakers: the microphone is set up for following a text.
    private var wantsFollow: Bool { mode == .shadow && practice?.reference != nil && !AudioRoute.isPrivate }
    @ObservationIgnored private var lastPress = Date.distantPast
    /// Bumped whenever new material goes on stage; loads started for older material check it.
    @ObservationIgnored private var presentID = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Recordings shorter than this are almost always a slip of the key, not practice.
    static let minimumSeconds = 2.0

    weak var state: AppState?
    weak var recorder: Recorder?
    /// What happened on stage, in order; recorded only while a probe sets `tracing`.
    @ObservationIgnored static var trace: [String] = []
    @ObservationIgnored static var tracing = false
    static func note(_ s: @autoclosure () -> String) {
        guard tracing, trace.count < 400 else { return }
        trace.append(String(format: "%.3f ", CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)) + s())
    }
    private var countdownTask: Task<Void, Never>?

    var autoStart: Bool { UserDefaults.standard.object(forKey: "stageCountdown") as? Bool ?? true }

    func attach(state: AppState, recorder: Recorder) {
        self.state = state
        self.recorder = recorder
        state.stage = self
    }

    /// Which studio the current material belongs to.
    var studio: Space { mode == .shadow || mode == .retell ? .shadow : .topic }
    /// While you are about to speak or speaking, the rest of the app steps back. Listening and
    /// waiting for the verdict are not on that list: you can always walk away, and a verdict
    /// that arrives after you left is not lost (it waits on stage or goes to the record).
    var isActive: Bool { phase == .countdown || phase == .recording }
    var hasMaterial: Bool { item != nil || practice != nil || mode == .free }

    // MARK: what the controls say

    /// The left button only ever plays the original; the main button only ever records you.
    var listenLabel: String { phase == .listening ? (player.playing ? L("暂停", "Pause") : L("继续听", "Resume")) : L("听原文", "Hear original") }
    var startLabel: String { mode == .shadow ? L("开始跟读", "Start shadowing") : mode == .retell ? L("开始复述", "Start retelling") : L("开始", "Start") }
    var mainLabel: String {
        switch phase {
        case .countdown: return L("现在开始", "Start now")
        case .recording: return L("停止", "Stop")
        case .analyzing: return L("分析中", "Analyzing")
        case .queued: return L("再录一段", "Record another")
        default: return startLabel
        }
    }
    var againLabel: String { mode == .shadow ? L("再跟一遍", "Shadow again") : mode == .retell ? L("再复述一遍", "Retell again") : L("再来一遍", "Go again") }
    /// What the water clock says while it waits for you.
    var readyPrompt: String {
        switch mode {
        case .shadow: return heardThrough ? L("听完了\n回车开始跟读", "Heard it\nReturn to shadow") : L("回车开始跟读", "Return to shadow")
        case .retell where practice?.reference != nil: return heardThrough ? L("听完了\n回车开始复述", "Heard it\nReturn to retell") : L("先听原文\n再复述", "Listen first\nthen retell")
        case .retell: return L("回车开始复述", "Return to retell")
        default: return L("回车开始", "Return to start")
        }
    }
    /// Names and terms from what is on stage, so the live captions catch them.
    var vocabulary: [String] {
        Recorder.vocabulary(from: [title, prompt ?? "", hint ?? "", practice?.script ?? "",
                                   practice?.reference?.sentences.prefix(80).map(\.text).joined(separator: " ") ?? ""])
    }

    // MARK: entry points

    /// Return or the global shortcut: today's next unfinished item, in its studio, at once.
    func presentNext() {
        if let next = state?.today?.nextItem { present(item: next) } else { presentFree() }
    }

    /// Puts a plan item on stage, then brings its studio forward. The order matters: the studio
    /// that appears asks the stage what it holds, so the stage must already hold the new item.
    /// `speakNow` skips straight to your turn (再复述一遍) instead of opening with the original.
    func present(item: PlanItem, autoStart: Bool = true, navigate: Bool = true, speakNow: Bool = false) {
        StageModel.note("present item \(item.kind) auto \(autoStart) space \(state?.space.rawValue ?? "")")
        reset()
        let token = presentID
        self.item = item
        mode = Mode(rawValue: item.kind) ?? .impromptu
        title = item.title
        prompt = item.prompt
        if let p = item.prompt { language = StageModel.language(of: p) }
        hint = item.detail
        targetSeconds = Double(item.seconds)
        eyebrow = StageModel.eyebrow(for: item)
        if navigate { state?.go(Space.of(kind: item.kind)) }
        Task {
            if let pid = item.practiceId, let p = await state?.fetchPractice(pid) {
                // Something else went on stage while this loaded; it is no longer wanted.
                guard token == presentID else { return }
                attachPractice(p)
            }
            guard token == presentID else { return }
            if mode == .shadow, let r = practice?.reference { targetSeconds = r.durationSec / rate }
            if autoStart { begin(force: speakNow) }
        }
    }

    func present(practice p: Practice, mode m: Mode, autoStart: Bool = true, navigate: Bool = true, speakNow: Bool = false) {
        StageModel.note("present practice \(m.rawValue) auto \(autoStart)")
        reset()
        mode = m
        title = p.title
        eyebrow = StageModel.eyebrow(for: p, mode: m)
        hint = m == .shadow ? L("戴耳机，跟着原声说。", "Put on headphones and speak along with the original.")
            : m == .retell ? L("听完一遍，用自己的话讲。", "Listen once, then say it in your own words.") : (p.notes.isEmpty ? nil : p.notes)
        attachPractice(p)
        targetSeconds = m == .retell ? 90 : (m == .shadow ? (p.reference?.durationSec ?? 90) / rate : nil)
        if navigate { state?.go(m == .shadow || m == .retell ? .shadow : .topic) }
        if autoStart { begin(force: speakNow) }
    }

    func presentFree(autoStart: Bool = true, navigate: Bool = true) {
        StageModel.note("present free auto \(autoStart)")
        reset()
        mode = .free
        title = L("随便说一段", "Say anything")
        eyebrow = L("自由讲", "Free talk")
        hint = L("想到什么说什么。一分钟就够。", "Say whatever comes to mind. A minute is enough.")
        if navigate { state?.go(.topic) }
        if autoStart { begin() }
    }

    static func eyebrow(for item: PlanItem) -> String {
        item.kind == "impromptu" ? L("\(item.kindLabel)，讲给\(item.subtitle)", "\(item.kindLabel) · \(item.subtitle)") : item.kindLabel
    }

    static func eyebrow(for p: Practice, mode m: Mode) -> String {
        m == .shadow ? L("跟读", "Shadow") : m == .retell ? L("复述", "Retell") : (p.kind == "agenda" ? L("备讲", "Prep") : L("讲稿", "Script"))
    }

    /// The interface language changed: the same material goes back on stage so its labels
    /// (and the plan item's text, which the server writes) follow. A verdict only renames its eyebrow.
    func relabel() {
        switch phase {
        case .ready:
            if let it = item {
                let fresh = state?.today?.items.first(where: { $0.id == it.id }) ?? it
                present(item: fresh, autoStart: false, navigate: false)
            } else if let p = practice {
                present(practice: p, mode: mode, autoStart: false, navigate: false)
            } else if mode == .free {
                presentFree(autoStart: false, navigate: false)
            }
        case .result:
            if let it = item { eyebrow = StageModel.eyebrow(for: it) }
            else if let p = practice { eyebrow = StageModel.eyebrow(for: p, mode: mode) }
            else if mode == .free { eyebrow = L("自由讲", "Free talk") }
        default:
            break
        }
    }

    /// What a studio shows when you arrive: its part of today's plan, without starting.
    /// Material already on this studio's stage stays, unless `force` (a new day).
    func prepare(for space: Space, force: Bool = false) {
        StageModel.note("prepare \(space.rawValue) phase \(phase) studio \(studio.rawValue) material \(hasMaterial) mode \(mode.rawValue)")
        guard !isActive else { return }
        if !force {
            if phase == .result && studio == space { return }
            if studio == space && hasMaterial && (phase == .ready || phase == .listening) { return }
        }
        let items = state?.today?.items ?? []
        let mine = items.filter { Space.of(kind: $0.kind) == space }
        // Filling a studio never moves you: it may be the one waiting behind 今天.
        if let it = mine.first(where: { !$0.done }) ?? mine.first {
            present(item: it, autoStart: false, navigate: false)
        } else if space == .shadow, let c = state?.clipPractices.max(by: { ($0.clip?.date ?? "") < ($1.clip?.date ?? "") }) {
            let m: Mode = c.clip?.role == "explain" ? .retell : .shadow
            let token = presentID
            Task {
                // You may have moved on while it loaded; only fill the studio you are still in,
                // and only if nothing else went on stage meanwhile.
                if let p = await state?.fetchPractice(c.id), state?.studio == space, !isActive, token == presentID {
                    present(practice: p, mode: m, autoStart: false, navigate: false)
                }
            }
        } else if space == .topic {
            presentFree(autoStart: false, navigate: false)
        }
    }

    /// Return or Space in a studio. Held keys repeat and hands double press, so presses closer
    /// than half a second count once: one press is one step, never start and stop together.
    /// `source` says which control pressed (button, space, menu); it goes into the capture
    /// log, so a take that ended early can be explained afterwards.
    func start(_ source: String = "button") {
        guard Date().timeIntervalSince(lastPress) > 0.45 else { return }
        lastPress = Date()
        if mode == .shadow, phase == .ready { routeIsPrivate = AudioRoute.isPrivate }
        StageModel.note("start \(source) in \(phase)")
        CaptureLog.write("press \(source) in \(phase) (\(mode.rawValue))")
        switch phase {
        case .ready: begin(force: true)
        case .result, .queued: again()
        default: toggle(source)
        }
    }

    /// "zh" when a text is mostly Chinese, else "en" (the same test the server's coverage uses:
    /// more CJK characters than Latin words).
    static func language(of text: String) -> String {
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let latin = text.split(whereSeparator: { !($0.isASCII && $0.isLetter) }).count
        return cjk > latin ? "zh" : "en"
    }

    /// What you will say decides the language: the clip's own language, else the script,
    /// else the title of a script that is only a title.
    private func adoptLanguage(of p: Practice) {
        if let r = p.reference {
            language = r.language.hasPrefix("zh") ? "zh" : "en"
        } else if !p.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            language = StageModel.language(of: p.script)
        } else if p.kind == nil || p.kind == "user" {
            language = StageModel.language(of: p.title)
        }
    }

    /// The script on stage was edited and saved: the stage shows the new text at once.
    func practiceEdited(_ p: Practice) {
        guard practice?.id == p.id, phase == .ready || phase == .result else { return }
        practice = p
        teleprompter.load(p.script)
        adoptLanguage(of: p)
        if item == nil { title = p.title }
    }

    private func attachPractice(_ p: Practice) {
        StageModel.note("attach \(p.title.prefix(20)) mode \(mode.rawValue) phase \(phase)")
        practice = p
        adoptLanguage(of: p)
        routeIsPrivate = AudioRoute.isPrivate
        teleprompter.load(p.script)
        if let api = state?.api, p.reference != nil {
            player.load(api.url("api/practices/\(p.id)/reference/audio"))
            player.setRate(Float(rate))
            player.listenHandler = { [weak state] wall, media, r in
                state?.activity.add(kind: "listen_reference", practiceId: p.id, sessionId: nil, wall: wall, media: media, rate: r)
            }
            player.flushHandler = { [weak state] in state?.activity.flush() }
        }
    }

    private func reset() {
        presentID += 1   // anything still loading for the previous material is dropped
        countdownTask?.cancel()
        recorder?.disarm()
        player.stop()
        player.onFinish = nil
        player.setSilenced(false)
        followsVoice = false
        heardThrough = false
        item = nil; practice = nil; prompt = nil; hint = nil; result = nil
        language = "en"
        targetSeconds = nil; countdownFill = 0; activeSentence = -1
        phase = .ready
        teleprompter.load("")
    }

    // MARK: flow

    /// Started from 今天, retelling opens with the original; a press of 开始复述 or
    /// 再复述一遍 (`force`) goes straight to your turn. Everything else fills the water clock.
    private func begin(force: Bool = false) {
        if mode == .retell, practice?.reference != nil, !force {
            listen()
        } else if autoStart || force {
            countdown()
        }
    }

    /// 听原文: plays the original from the top. It never leads into recording by itself: when it
    /// ends, the stage waits for 开始跟读 or 开始复述.
    func listen(from sentence: Int? = nil) {
        StageModel.note("listen" + (sentence.map { " from \($0)" } ?? ""))
        routeIsPrivate = AudioRoute.isPrivate
        player.setSilenced(false)
        followsVoice = false
        phase = .listening
        player.seek(to: sentence.map(startOf) ?? 0)
        if let sentence { activeSentence = sentence }
        player.onFinish = { [weak self] in
            guard let self, self.phase == .listening else { return }
            self.heardThrough = true
            self.phase = .ready
        }
        player.play()
    }

    /// Where a line of the original begins, a moment early so its first word is not clipped.
    private func startOf(_ sentence: Int) -> Double {
        max(0, (practice?.reference?.sentences.first { $0.i == sentence }?.start ?? 0) - 0.2)
    }

    /// A tapped line of the original. Before you speak it plays the original from that line;
    /// while you read along on speakers it tells the subtitles where you are.
    func jump(to sentence: Int) {
        switch phase {
        case .listening:
            StageModel.note("jump to \(sentence)")
            player.seek(to: startOf(sentence))
            activeSentence = sentence
            player.play()
        case .ready:
            listen(from: sentence)
        case .recording where followsVoice:
            StageModel.note("anchor at \(sentence)")
            follower.anchor(sentence: sentence)
            activeSentence = sentence
        default:
            break
        }
    }

    var canJump: Bool { phase == .ready || phase == .listening || (phase == .recording && followsVoice) }

    /// The live transcript moved on: in a read-along on speakers, the subtitles follow it.
    func heard(finals: [String], volatile: String) {
        guard followsVoice, phase == .recording, follower.hear(finals: finals, volatile: volatile) else { return }
        let s = follower.sentence(lead: followLead)
        if s != activeSentence {
            StageModel.note("follow to \(s) at word \(follower.position)")
            activeSentence = s
        }
    }

    /// The water clock fills for 2.6 s. Meanwhile the microphone and live captions are set
    /// up, so when it is full, recording opens instantly.
    func countdown() {
        countdownTask?.cancel()
        countdownStartedAt = Date()
        player.pause()
        // Shadowing starts the reference with the recording; seek now so that moment only presses play.
        if mode == .shadow, practice?.reference != nil { player.seek(to: 0) }
        phase = .countdown
        let armTask = Task { [weak self] () -> Bool in
            guard let self, let recorder = self.recorder else { return false }
            do { try await recorder.arm(language: SpeechLanguage(rawValue: self.language) ?? .en, vocabulary: self.vocabulary, follow: self.wantsFollow); return true }
            catch { self.state?.report(error); return false }
        }
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            let armed = await armTask.value
            guard let self, !Task.isCancelled, self.phase == .countdown else { return }
            if armed { await self.startRecording() } else { self.phase = .ready }
        }
    }

    /// Water left in the clock at a moment in time; read by the orb every frame.
    func remaining(at t: Date) -> Double? {
        switch phase {
        case .countdown:
            guard let c = countdownStartedAt else { return 0 }
            return min(1, max(0, t.timeIntervalSince(c) / 2.6))
        case .recording:
            guard let target = targetSeconds, target > 0, let s = recorder?.startDate else { return 1 }
            return max(0, 1 - t.timeIntervalSince(s) / target)
        case .analyzing, .queued, .result: return 0.1
        case .listening: return 0
        case .ready: return targetSeconds == nil ? 1 : 0
        }
    }

    func toggle(_ source: String = "button") {
        switch phase {
        case .ready, .listening: player.pause(); countdown()
        case .countdown:
            // skip the rest of the countdown; the arm task may still be finishing
            countdownTask?.cancel()
            Task {
                if let recorder, !recorder.isArmed { try? await recorder.arm(language: SpeechLanguage(rawValue: language) ?? .en, vocabulary: vocabulary, follow: wantsFollow) }
                await startRecording()
            }
        case .recording:
            StageModel.note("stop by \(source)")
            Task { await stopRecording() }
        case .result: again()
        default: break
        }
    }

    func startRecording() async {
        guard let recorder, let state else { return }
        do {
            if !recorder.isArmed { try await recorder.arm(language: SpeechLanguage(rawValue: language) ?? .en, vocabulary: vocabulary, follow: wantsFollow) }
            recorder.beginCapture()
            startedAt = Date()
            StageModel.note("recording \(mode.rawValue)")
            phase = .recording
            if mode == .shadow, let r = practice?.reference {
                // Out of speakers the microphone would record the original along with you and
                // the analysis would be of the original, so there it does not play: the subtitles
                // follow your voice instead, at your own pace. Without a live transcript they
                // fall back to the original's clock, played silently. In headphones the
                // original plays in your ears and the subtitles keep to it.
                routeIsPrivate = AudioRoute.isPrivate
                player.setSilenced(!routeIsPrivate)
                if !routeIsPrivate, recorder.liveAvailable, !r.sentences.isEmpty {
                    follower = VoiceFollower(sentences: r.sentences.map(\.text))
                    followLead = recorder.liveModel == .dictation ? 1 : 2
                    followsVoice = true
                    player.pause()
                    activeSentence = 0
                    CaptureLog.write("shadowing on \(AudioRoute.outputName): the original silent, the subtitles follow the voice (\(recorder.liveModel))")
                } else {
                    CaptureLog.write("shadowing, the original \(routeIsPrivate ? "in headphones" : "silent") on \(AudioRoute.outputName)")
                    if player.time > 0.05 { player.seek(to: 0) }
                    player.play()
                }
            } else {
                player.pause()
            }
        } catch {
            state.report(error)
            phase = .ready
        }
    }

    func showNotice(_ text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func stopRecording() async {
        guard let recorder, let state else { return }
        StageModel.note("stopRecording after \(String(format: "%.1f", startedAt.map { Date().timeIntervalSince($0) } ?? 0)) s")
        // The page answers the press at once; the recorder winds down behind it.
        phase = .analyzing
        player.pause()
        player.setSilenced(false)
        followsVoice = false
        // You may put something else on stage while this one is analysed; then the verdict
        // must not land on the new material.
        let token = presentID
        let clock = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard let url = await recorder.stop() else { if token == presentID { phase = .ready }; return }
        let captured = recorder.capturedSeconds
        if captured < StageModel.minimumSeconds {
            try? FileManager.default.removeItem(at: url)
            if token == presentID { phase = .ready }
            showNotice(clock >= 4
                       ? L("麦克风只录到 \(Int(captured.rounded())) 秒就断了，这一段没有保存。看看 系统设置 > 声音 > 输入 选的是哪个麦克风。",
                           "The microphone cut out after \(Int(captured.rounded())) s, so this take wasn't saved. Check which microphone is selected under System Settings > Sound > Input.")
                       : L("录音不到两秒，没有保存。", "Under two seconds, so it wasn't saved."))
            return
        }
        if clock > 8, captured < clock * 0.7 {
            showNotice(L("麦克风中途断开过，录到 \(Int(captured.rounded())) 秒，比实际讲的短。",
                         "The microphone dropped out partway: \(Int(captured.rounded())) s recorded, shorter than you spoke."))
        }
        let drill: Drill? = item.map { Drill(item: $0.id, kind: $0.kind, promptId: $0.promptId, date: state.today?.date) }
            ?? (mode == .free ? nil : Drill(item: nil, kind: mode.rawValue, promptId: nil, date: nil))
        let session = await state.submit(fileURL: url, language: language, title: sessionTitle,
                                         scenario: scenario, practiceId: practice?.id, drill: drill,
                                         onError: { [weak self] message in self?.showNotice(message) })
        guard token == presentID else {
            if let r = session?.review { showNotice(L("刚才那一段：\(r.headline)。完整分析在「进展」的记录里。",
                                                      "That last take: \(r.headline). The full analysis is in the record under Progress.")) }
            return
        }
        if let session {
            result = session
            phase = .result
            if session.listen?.isPending == true {   // the listening notes land a little later
                let id = session.id
                Task { [weak self] in
                    guard let notes = await state.awaitListen(id) else { return }
                    if self?.result?.id == id { self?.result?.listen = notes }
                }
            }
        } else {
            phase = state.isReady ? .ready : .queued
        }
    }

    /// A practice was deleted; if it is on stage, the studio takes its next material.
    func practiceRemoved(_ id: String) {
        guard practice?.id == id, !isActive else { return }
        prepare(for: studio, force: true)
    }

    /// A recording was deleted; a verdict about it no longer has anything to open.
    func sessionRemoved(_ id: String) {
        guard result?.id == id else { return }
        result = nil; phase = .ready
    }

    /// The app is quitting mid recording: keep what was said for the next launch.
    func saveForQuit() {
        guard phase == .recording, let recorder, let state, let url = recorder.stopNow() else { return }
        let drill: Drill? = item.map { Drill(item: $0.id, kind: $0.kind, promptId: $0.promptId, date: state.today?.date) }
            ?? (mode == .free ? nil : Drill(item: nil, kind: mode.rawValue, promptId: nil, date: nil))
        state.keepForLater(url, language: language, title: sessionTitle, scenario: scenario, practiceId: practice?.id, drill: drill)
    }

    private var sessionTitle: String {
        switch mode {
        case .impromptu: return item.map { L("\($0.kindLabel)：\(String(($0.prompt ?? $0.title).prefix(40)))", "\($0.kindLabel): \(String(($0.prompt ?? $0.title).prefix(40)))") } ?? title
        case .shadow: return L("跟读 · \(title)", "Shadow · \(title)")
        case .retell: return L("复述 · \(title)", "Retell · \(title)")
        default: return title
        }
    }

    private var scenario: String {
        switch mode {
        case .impromptu: return "meeting"
        case .agenda: return practice?.scenario ?? "presentation"
        default: return "presentation"
        }
    }

    func again() {
        StageModel.note("again")
        result = nil
        if let item { present(item: item, speakNow: true) }
        else if let p = practice { present(practice: p, mode: mode == .free ? .free : mode, speakNow: true) }
        else { presentFree() }
    }

    var nextItem: PlanItem? {
        guard let items = state?.today?.items else { return nil }
        return items.first { !$0.done && $0.id != item?.id }
    }

    func goNext() {
        guard let n = nextItem else { return }
        present(item: n)
    }

    func openDetails() {
        guard let s = result, let state else { return }
        Task { await state.openTray(.session(s.id)) }
    }

    /// 放弃这段 (the button, or Esc while recording): the take stops and is thrown away, not kept
    /// and not analysed, and the same material waits on stage.
    func discard(_ source: String = "button") {
        guard phase == .recording, let recorder else { return }
        StageModel.note("discard by \(source)")
        CaptureLog.write("discard \(source) (\(mode.rawValue))")
        recorder.discard()
        player.pause()
        player.setSilenced(false)
        followsVoice = false
        startedAt = nil
        phase = .ready
        showNotice(L("这一段放弃了，没有保存。", "Take discarded, nothing saved."))
    }

    /// Esc: back to ready with the same material (stops listening or the countdown); while
    /// recording it throws the take away.
    func cancel() {
        if phase == .recording { discard("esc"); return }
        guard phase == .countdown || phase == .listening || phase == .result || phase == .queued else { return }
        StageModel.note("cancel in \(phase)")
        countdownTask?.cancel()
        recorder?.disarm()
        player.pause()
        player.setSilenced(false)
        followsVoice = false
        phase = .ready; result = nil
    }

    func setRate(_ r: Double) {
        rate = r
        player.setRate(Float(r))
        if mode == .shadow, let d = practice?.reference?.durationSec { targetSeconds = d / r }
    }
}

/// Reference subtitles; the sentence being spoken is lifted out, the rest recede.
struct ReferenceLines: View {
    let sentences: [RefSentence]
    let active: Int
    /// A tapped line, when lines can be tapped (see `StageModel.jump`).
    var onTap: ((Int) -> Void)?
    var tapHelp = ""
    @Environment(\.renderMode) private var renderMode
    @Environment(\.renderLine) private var renderLine

    var body: some View {
        if renderMode {
            // Offscreen a scroll view draws blank, so the render harness stacks the lines itself,
            // where scrolling to the active line would put them.
            CenteredLines(position: renderLine ?? Double(active)) {
                ForEach(sentences) { s in
                    ReferenceLine(sentence: s, active: active, onTap: onTap, help: tapHelp)
                }
            }
            .frame(height: 360)
            .clipped()
            .mask(fade)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sentences) { s in
                            ReferenceLine(sentence: s, active: active, onTap: onTap, help: tapHelp)
                                .id(s.i)
                        }
                    }
                    .padding(.vertical, 120)
                }
                .frame(height: 360)
                .mask(fade)
                .onChange(of: active) { _, i in withAnimation(Motion.paper) { proxy.scrollTo(i, anchor: .center) } }
            }
        }
    }

    private var fade: LinearGradient {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                               .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Stacks lines so that `position`, a line index (between two while moving), sits in the
/// middle, as scrolling to it with a centre anchor does.
private struct CenteredLines: Layout {
    var position: Double
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 360))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height }
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for h in heights { tops.append(y); y += h + spacing }
        let lo = min(max(Int(position.rounded(.down)), 0), subviews.count - 1)
        let hi = min(lo + 1, subviews.count - 1)
        let f = CGFloat(min(max(position - Double(lo), 0), 1))
        let middle = (tops[lo] + heights[lo] / 2) * (1 - f) + (tops[hi] + heights[hi] / 2) * f
        for (i, line) in subviews.enumerated() {
            line.place(at: CGPoint(x: bounds.minX, y: bounds.midY - middle + tops[i]), anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: heights[i]))
        }
    }
}

/// One line of the original. Tappable lines tint under the pointer.
private struct ReferenceLine: View {
    let sentence: RefSentence
    let active: Int
    let onTap: ((Int) -> Void)?
    let help: String
    @State private var hover = false

    var body: some View {
        let s = sentence
        let text = Text(s.text)
            .font(s.i == active ? Typeface.display(19) : Typeface.display(15))
            .foregroundStyle(s.i == active ? Palette.ink : (s.i < active ? Palette.ink3 : Palette.ink2))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .animation(Motion.paper, value: active)
        if let onTap {
            Button { onTap(s.i) } label: {
                text
                    .background(hover ? Palette.kyanos.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .pointerStyle(.link)
            .help(help)
        } else {
            text
        }
    }
}

/// A script used as talking points; the line you are on is highlighted.
struct ScriptLines: View {
    let teleprompter: Teleprompter
    let live: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(teleprompter.sentences.enumerated()), id: \.offset) { i, s in
                        Text(s)
                            .font(Typeface.display(15))
                            .foregroundStyle(live && i < teleprompter.cursor ? Palette.ink3 : Palette.ink)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(live && i == teleprompter.cursor ? Palette.kyanos.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .id(i)
                    }
                }
            }
            .frame(height: 360)
            .onChange(of: teleprompter.cursor) { _, c in withAnimation(Motion.paper) { proxy.scrollTo(c, anchor: .center) } }
        }
    }
}

/// The last lines the live recognizer heard.
struct LiveLines: View {
    let sentences: [String]
    let volatile: String
    let recording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("实时字幕", "Live captions")).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
            let said = sentences.suffix(8).joined(separator: " ")
            if said.isEmpty && volatile.isEmpty {
                Text(recording ? L("开始说话……", "Start speaking…") : L("录音时这里会出现你说的话。", "What you say shows up here while recording.")).font(Typeface.ui(13)).foregroundStyle(Palette.ink3)
            } else {
                // One running paragraph with the newest words at the bottom, never cut off;
                // older lines slide up under a fade. Words still being recognised are lighter.
                let gap = said.isEmpty || volatile.isEmpty ? "" : " "
                Text("\(Text(said).foregroundStyle(Palette.ink))\(gap)\(Text(volatile).foregroundStyle(Palette.ink3))")
                    .font(Typeface.ui(14)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 140, alignment: .bottom)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.28)],
                                         startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Verdict

/// The result, set like an inscription: one headline, the numbers that matter this block,
/// and at most three things to do next time.
struct VerdictCard: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let r = session.review {
                VStack(alignment: .leading, spacing: 8) {
                    Text(stage.eyebrow).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                    Text(r.headline).font(Typeface.display(38)).tracking(-0.4).foregroundStyle(Palette.ink)
                }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(r.focus.prefix(4).enumerated()), id: \.element.id) { i, f in
                        if i > 0 { Rectangle().fill(Palette.vein).frame(width: 1).padding(.vertical, 4) }
                        FocusCell(metric: f).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, i == 0 ? 0 : 18)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                MeanderRule()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(r.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Palette.ochre).frame(width: 5, height: 5).offset(y: -3)
                            Text(line).font(Typeface.ui(14)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let l = session.listen { VerdictListenLine(listen: l) }
                }
            } else {
                Text(L("录好了", "Recorded")).font(Typeface.display(38))
            }
            HStack(spacing: 12) {
                // Return belongs to a tray's form while one is open.
                if stage.nextItem != nil {
                    Button(L("下一项", "Next")) { stage.goNext() }.primaryGlass().keyboardShortcut(state.tray == nil && state.space != .home ? .defaultAction : nil)
                    Button(stage.againLabel) { stage.again() }.buttonStyle(.glass).controlSize(.large)
                } else {
                    Button(stage.againLabel) { stage.again() }.primaryGlass().keyboardShortcut(state.tray == nil && state.space != .home ? .defaultAction : nil)
                }
                Button(L("看完整分析", "Full analysis")) { stage.openDetails() }.buttonStyle(.glass).controlSize(.large)
                Spacer()
                Button(L("收起", "Close")) { stage.cancel() }.buttonStyle(InkButtonStyle())
            }
        }
        .padding(34)
        .frame(maxWidth: 760, alignment: .leading)
        .paper(radius: Radius.stage)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { FrameProbe.verdictFrame = $0 }
    }
}

/// One line from the listening notes under the verdict: a spinner while the model listens,
/// then its impression of the take. Failures stay in the full analysis.
struct VerdictListenLine: View {
    let listen: ListenNotes

    var body: some View {
        if listen.isPending {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(L("正在听语气…", "Listening to how it sounds…")).font(Typeface.ui(13)).foregroundStyle(Palette.ink2)
            }
        } else if let o = listen.overall, listen.isDone {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(Palette.kyanos).frame(width: 5, height: 5).offset(y: -3)
                Text(L("听感：", "How it sounds: ") + o.tone + L("。", ". ") + o.summary)
                    .font(Typeface.italic(14)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FocusCell: View {
    let metric: FocusMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.label).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                RollingNumber(value: metric.value, font: Typeface.display(30), color: metric.inTarget ? Palette.malachite : Palette.ink,
                              format: { v in v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) })
                Text(metric.unit).font(Typeface.ui(11)).foregroundStyle(Palette.ink2)
            }
            HStack(spacing: 6) {
                Text(L("目标 \(metric.target)", "Target \(metric.target)")).font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
                // Change since the last take, said so: next to the target it read as the gap to it.
                if let d = metric.delta, d != 0 {
                    Text(L("比上次 \(d > 0 ? "↑" : "↓")\(fmt1(abs(d)))", "vs last \(d > 0 ? "↑" : "↓")\(fmt1(abs(d)))"))
                        .font(Typeface.ui(11, .medium)).foregroundStyle(Palette.ink2)
                }
            }
        }
    }
}
