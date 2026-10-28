import SwiftUI
import AppKit

/// Design review without screen recording permission: `--render <dir>` connects to
/// SPEECH_SERVER_URL, draws each place's content with ImageRenderer in light and dark,
/// writes PNGs and quits. Liquid Glass and AppKit-backed controls have no backdrop offscreen
/// and draw flat; layout, type and color are what this is for.
@MainActor
enum RenderHarness {
    static func run(state: AppState, recorder: Recorder, stage: StageModel) async {
        guard let i = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > i + 1 else { exit(1) }
        let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log("render: boot")
        await state.boot()
        log("render: booted, loading data")
        await state.loadDaily()
        await state.loadAgenda()
        await state.loadInsights()
        await state.loadRecap()
        await state.loadSettings()
        await state.reloadAllHistory()
        if let last = state.allSessions.last { await state.open(sessionID: last.id) }
        let only = ProcessInfo.processInfo.environment["RENDER_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        log("render: data loaded")

        var pages: [(String, CGFloat, CGFloat?, () -> AnyView)] = [
            ("home", 1200, nil, { AnyView(HomeContent().padding(.horizontal, 36).padding(.vertical, 20)) }),
            ("progress", 1000, nil, { AnyView(ProgressTray().padding(28)) }),
            ("topbar", 1200, 70, { AnyView(topBar()) }),
            ("settings", 900, nil, { AnyView(settingsSheet().padding(28)) }),
            ("history", 1000, nil, { AnyView(HistoryTray().padding(28)) }),
            ("clips", 1000, nil, { AnyView(ClipsContent().padding(28)) }),
            ("agenda", 1000, nil, { AnyView(AgendaContent().padding(28)) }),
            ("newtopic", 900, nil, { AnyView(NewTopicForm().padding(28)) }),
            ("addlink", 900, nil, { AnyView(AddLinkForm().padding(28)) }),
            ("wreaths", 700, nil, { AnyView(wreathSheet()) }),
            ("menubar", 320, nil, { AnyView(MenuBarContent()) }),
            ("window-home", 1200, 840, { AnyView(window(state: state, space: .home, height: 840)) }),
            ("window-home-min", 1040, 700, { AnyView(window(state: state, space: .home, height: 700)) }),
            ("window-progress-min", 1040, 700, { AnyView(window(state: state, space: .home, height: 700, tray: .progress)) }),
        ]
        if let s = await shadowStage(stage: stage, recorder: recorder, state: state) {
            pages.append(("studio-shadow", 1200, 780, { AnyView(s) }))
            pages.append(("window-shadow", 1200, 840, { AnyView(window(state: state, space: .shadow, height: 840)) }))
            pages.append(("window-shadow-min", 1040, 700, { AnyView(window(state: state, space: .shadow, height: 700)) }))
            pages.append(("window-shadow-ready-min", 1040, 700, {
                stage.phase = .ready
                return AnyView(window(state: state, space: .shadow, height: 700))
            }))
        }
        if let retell = state.today?.items.first(where: { $0.kind == "retell" }), let pid = retell.practiceId,
           let rp = await state.fetchPractice(pid) {
            pages.append(("window-retell-min", 1040, 700, {
                stage.item = retell; stage.practice = rp; stage.mode = .retell
                stage.title = retell.title; stage.eyebrow = retell.kindLabel; stage.prompt = nil; stage.hint = retell.detail
                stage.targetSeconds = 90; stage.phase = .ready; stage.heardThrough = true
                return AnyView(window(state: state, space: .shadow, height: 700))
            }))
            pages.append(("window-retell-listen-min", 1040, 700, {
                stage.item = retell; stage.practice = rp; stage.mode = .retell
                stage.title = retell.title; stage.eyebrow = retell.kindLabel; stage.prompt = nil; stage.hint = retell.detail
                stage.targetSeconds = 90; stage.heardThrough = false
                stage.phase = .listening; stage.activeSentence = 2
                return AnyView(window(state: state, space: .shadow, height: 700))
            }))
        }
        pages.append(("window-topic-min", 1040, 700, {
            _ = topicStage(stage: stage, recorder: recorder, state: state)
            return AnyView(window(state: state, space: .topic, height: 700))
        }))
        pages.append(("window-verdict-min", 1040, 700, {
            _ = verdictStage(stage: stage, state: state)
            return AnyView(window(state: state, space: .topic, height: 700))
        }))
        pages.append(("studio-topic", 1200, 780, { AnyView(topicStage(stage: stage, recorder: recorder, state: state)) }))
        pages.append(("verdict", 1200, 780, { AnyView(verdictStage(stage: stage, state: state)) }))

        for (name, width, height, make) in pages {
            if let only, !only.contains(name) { continue }
            for scheme in schemes {
                log("render: \(name) \(scheme)")
                draw(make(), width: width, height: height, scheme: scheme, scale: 2,
                     state: state, recorder: recorder, stage: stage,
                     to: dir.appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
            }
        }
        // Moving pictures are a few hundred frames each, so they are drawn only when named.
        if let only, only.contains("window-shadow-live") {
            await shadowLoop(name: "window-shadow-live", stage: stage, recorder: recorder, state: state, into: dir)
        }
        exit(0)
    }

    static func draw(_ view: AnyView, width: CGFloat, height: CGFloat?, scheme: ColorScheme, scale: CGFloat,
                     clock: Date? = nil, line: Double? = nil, hold: FrameHold? = nil,
                     state: AppState, recorder: Recorder, stage: StageModel, to url: URL) {
        let content = view
            .environment(state).environment(recorder).environment(stage)
            .frame(width: width, height: height)
            .background(Palette.marble)
            .environment(\.colorScheme, scheme)
            .environment(\.renderMode, true)
            .environment(\.renderClock, clock)
            .environment(\.renderLine, line)
        let r = ImageRenderer(content: content)
        r.scale = scale
        r.proposedSize = ProposedViewSize(width: width, height: height)
        if let hold {
            try? pngData(r.cgImage, holding: hold)?.write(to: url)
        } else if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    /// A frame of a moving picture as sRGB PNG data, after `hold` has held back its small changes.
    static func pngData(_ image: CGImage?, holding hold: FrameHold) -> Data? {
        guard let image, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        hold.apply(data.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * ctx.height)
        guard let held = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: held).representation(using: .png, properties: [:])
    }

    /// Keeps the frames of a moving picture in step with what the WebP encoder will show.
    /// img2webp (quality 92 in render.sh) treats a pixel whose channels all moved by 2 or less
    /// since the previous frame as unchanged and leaves the old one on screen. The halo fades
    /// in and out a level or two per frame at its edge, so those old pixels piled up behind
    /// faint rectangles. Here such a pixel keeps the value it had in the frame before, so the
    /// encoder and the viewer agree on it; no pixel is more than 2 levels behind.
    final class FrameHold {
        let threshold: Int
        private var shown: [UInt8] = []

        init(threshold: Int) { self.threshold = threshold }

        /// `px` holds `count` bytes, four per pixel; small changes from the last frame are undone in place.
        func apply(_ px: UnsafeMutablePointer<UInt8>, count: Int) {
            guard shown.count == count else {
                shown = Array(UnsafeBufferPointer(start: px, count: count))
                return
            }
            let t = threshold
            shown.withUnsafeMutableBufferPointer { s in
                var i = 0
                while i + 3 < count {
                    if abs(Int(px[i]) - Int(s[i])) > t || abs(Int(px[i + 1]) - Int(s[i + 1])) > t
                        || abs(Int(px[i + 2]) - Int(s[i + 2])) > t || abs(Int(px[i + 3]) - Int(s[i + 3])) > t {
                        for k in i..<(i + 4) { s[k] = px[k] }
                    } else {
                        for k in i..<(i + 4) { px[k] = s[k] }
                    }
                    i += 4
                }
            }
        }
    }

    /// The shadow studio mid-take as a loop of frames, for the README: a voice swells the halo
    /// and raises waves on the water, and the subtitles move along with it. The halo turns once
    /// in 15 s and every rhythm of the voice divides 15 s, so the loop closes on itself; only
    /// the clock and the subtitles start over. Frames go to `<name>-light/0000.png` (and
    /// `<name>-dark/`); render.sh joins them into an animated WebP.
    static func shadowLoop(name: String, stage: StageModel, recorder: Recorder, state: AppState, into dir: URL) async {
        guard await shadowStage(stage: stage, recorder: recorder, state: state) != nil,
              let sentences = stage.practice?.reference?.sentences, !sentences.isEmpty else {
            log("render: \(name) skipped, no shadow clip today")
            return
        }
        let fps = 12.0, seconds = 15.0, phrase = 2.5, wordsPerSecond = 2.5
        let first = min(stage.activeSentence, sentences.count - 1)
        let startElapsed = recorder.elapsed

        // Phrases of about two seconds with a breath between them, each a little louder or
        // softer, and syllables on top.
        let loudness = [0.85, 1.0, 0.75, 0.95, 0.8, 1.0]
        func rms(_ t: Double) -> Float {
            let u = (t.truncatingRemainder(dividingBy: seconds) + seconds).truncatingRemainder(dividingBy: seconds)
            let voice = min(1, max(0, (0.6 - cos(2 * .pi * u / phrase)) / 1.6))
            let syllables = 0.65 + 0.35 * sin(2 * .pi * 3.6 * u)
            return Float(0.012 + 0.085 * loudness[Int(u / phrase) % loudness.count] * voice * syllables)
        }

        // When each later line becomes the active one: read at about 2.5 words a second from
        // partway into the first line, each change falling in a breath between phrases.
        func words(_ i: Int) -> Double { Double(sentences[i].text.split(separator: " ").count) }
        var changes: [Double] = []
        var reached = 0.6 * words(first) / wordsPerSecond
        var next = first + 1
        while next < sentences.count {
            var at = max(phrase, (reached / phrase).rounded() * phrase)
            if let last = changes.last, at <= last { at = last + phrase }
            if at >= seconds { break }
            changes.append(at)
            reached = at + words(next) / wordsPerSecond
            next += 1
        }
        func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

        let origin = Date(timeIntervalSinceReferenceDate: 0)
        let pace = [2.0, 3, 5, 4, 1, 0, 2, 4, 6, 5, 3, 1, 0, 2, 3]
        for scheme in schemes {
            let out = dir.appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark")")
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            log("render: \(name) \(scheme), \(Int(fps * seconds)) frames")
            let hold = FrameHold(threshold: 2)
            // The meter runs one loop ahead of the first frame, so the last frame leads into it.
            recorder.meter.reset()
            var metered = -seconds
            for i in 0..<Int(fps * seconds) {
                let t = Double(i) / fps
                while metered <= t { recorder.meter.push(rms(metered)); metered += 0.02 }
                let now = origin.addingTimeInterval(t)
                recorder.elapsed = startElapsed + t
                recorder.liveWPM = 150 + pace[Int(t) % pace.count]
                // The water stays where it is, so it doesn't jump back when the loop starts over.
                recorder.pretendStarted(at: now.addingTimeInterval(-startElapsed))
                stage.activeSentence = first + changes.filter { $0 <= t }.count
                let line = Double(first) + changes.reduce(0) { $0 + ease((t - $1) / 0.6) }
                draw(AnyView(window(state: state, space: .shadow, height: 840)), width: 1200, height: 840,
                     scheme: scheme, scale: 4.0 / 3, clock: now, line: line, hold: hold,
                     state: state, recorder: recorder, stage: stage,
                     to: out.appendingPathComponent(String(format: "%04d.png", i)))
            }
        }
        recorder.meter.reset()
        recorder.elapsed = startElapsed
        stage.activeSentence = first
    }

    /// Light and dark, or only what RENDER_SCHEMES names (`light`, `dark`).
    static var schemes: [ColorScheme] {
        let named = ProcessInfo.processInfo.environment["RENDER_SCHEMES"].map { Set($0.split(separator: ",").map(String.init)) }
        return [ColorScheme.light, .dark].filter { named?.contains($0 == .light ? "light" : "dark") ?? true }
    }

    static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    static func topBar() -> some View {
        ZStack(alignment: .topLeading) {
            TopBarView(chrome: WindowChrome())
            trafficLights()
        }
    }

    /// The window's own buttons, drawn where macOS puts them, as a reference in renders.
    static func trafficLights() -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
            Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
            Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25))
        }
        .frame(width: 60, height: 14)
        .padding(.leading, 9).padding(.top, 9)
    }

    /// The whole window as it is laid out: the top bar over the place, both under the lights,
    /// and a tray over them when one is named. The page is cut at the window's height, as the
    /// real one scrolls (a ScrollView draws blank here).
    static func window(state: AppState, space: Space, height: CGFloat, tray: Tray? = nil) -> some View {
        let chrome = WindowChrome()
        state.space = space
        state.tray = tray
        if space != .home { state.studio = space }
        return ZStack(alignment: .topLeading) {
            Group {
                if space == .home {
                    // Laid out at its full height, as in the scroll view, then cut. A fixed
                    // height alone squeezes the page and its cards draw over their footers.
                    HomeContent().padding(.horizontal, 36).padding(.top, 22)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(height: height - chrome.barHeight - 6, alignment: .top)
                        .clipped()
                } else {
                    StudioView()
                }
            }
            .padding(.top, chrome.barHeight + 6)
            TrayHost(topInset: chrome.barHeight)
            TopBarView(chrome: chrome)
            trafficLights()
        }
        .clipped()
    }

    static func settingsSheet() -> some View {
        VStack(alignment: .leading, spacing: 36) {
            StartSettings()
            ReminderSettings()
            ClipSettings()
            CycleSettings()
            ClaudeSettings()
            DataSettings()
        }
        .frame(maxWidth: 820, alignment: .leading)
    }

    /// A shadowing clip mid-recording: subtitles on the left, the orb, pace on the right.
    static func shadowStage(stage: StageModel, recorder: Recorder, state: AppState) async -> AnyView? {
        guard let item = state.today?.items.first(where: { $0.kind == "shadow" }),
              let pid = item.practiceId, let p = await state.fetchPractice(pid) else { return nil }
        stage.item = item
        stage.practice = p
        stage.mode = .shadow
        stage.title = item.title
        stage.eyebrow = item.kindLabel
        stage.targetSeconds = p.reference?.durationSec
        stage.activeSentence = 3
        stage.phase = .recording
        recorder.elapsed = 31
        recorder.pretendStarted(at: Date().addingTimeInterval(-31))
        recorder.liveWPM = 152
        state.studio = .shadow
        state.space = .shadow
        return AnyView(StudioView().padding(.top, 10))
    }

    /// An impromptu prompt mid-recording, with live captions.
    static func topicStage(stage: StageModel, recorder: Recorder, state: AppState) -> some View {
        stage.practice = nil
        if let item = state.today?.items.first(where: { $0.kind == "impromptu" }) {
            stage.item = item
            stage.prompt = item.prompt
            stage.hint = item.detail
            stage.title = item.title
            stage.eyebrow = L("\(item.subtitle)，\(item.kindLabel)", "\(item.kindLabel) · \(item.subtitle)")
        } else {
            stage.item = nil
            stage.title = L("随便说一段", "Say anything")
            stage.eyebrow = L("自由讲", "Free talk")
            stage.prompt = "Give your team a forty five second update: what shipped, what is blocked, and what you need from them."
        }
        stage.mode = stage.item == nil ? .free : .impromptu
        stage.targetSeconds = 60
        stage.activeSentence = -1
        stage.phase = .recording
        recorder.elapsed = 42
        recorder.liveWordCount = 104
        recorder.liveWPM = 149
        recorder.liveSentences = ["So the short version is we shipped the Gong pipeline on Tuesday.",
                                  "What is blocked is the Salesforce sync, because the vendor has no update only mode."]
        recorder.liveVolatile = "What I need from you is a call on"
        state.studio = .topic
        state.space = .topic
        return StudioView().padding(.top, 10)
    }

    static func verdictStage(stage: StageModel, state: AppState) -> some View {
        // Fill the topic studio first, as opening it does. Otherwise the studio's own
        // prepare(for:) on appear swaps the verdict for a ready stage whenever the page drawn
        // before was the shadow studio, and only the second (dark) drawing showed the verdict.
        stage.phase = .ready
        stage.prepare(for: .topic)
        stage.eyebrow = L("即兴，汇报", "Impromptu · Update")
        stage.result = state.currentSession
        stage.phase = state.currentSession == nil ? .ready : .result
        state.studio = .topic
        state.space = .topic
        return StudioView().padding(.top, 10)
    }

    static func wreathSheet() -> some View {
        HStack(spacing: 30) {
            LaurelWreath(days: [.done, .done, .missed, .done, .today, .future, .future], target: 5, size: 150)
            LaurelWreath(days: [.done, .done, .done, .done, .done, .future, .future], target: 5, size: 150)
            VoiceOrb(level: { 0.6 }, remaining: { _ in 0.55 }, live: true, size: 160)
        }
        .padding(30)
    }
}
