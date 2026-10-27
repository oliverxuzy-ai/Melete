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
            for scheme in [ColorScheme.light, .dark] {
                log("render: \(name) \(scheme)")
                let content = make()
                    .environment(state).environment(recorder).environment(stage)
                    .frame(width: width, height: height)
                    .background(Palette.marble)
                    .environment(\.colorScheme, scheme)
                    .environment(\.renderMode, true)
                let r = ImageRenderer(content: content)
                r.scale = 2
                r.proposedSize = ProposedViewSize(width: width, height: height)
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
                }
            }
        }
        exit(0)
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

    /// The whole window as it is laid out: the top bar over the place, both under the lights.
    /// The page is cut at the window's height, as the real one scrolls (a ScrollView draws
    /// blank here).
    static func window(state: AppState, space: Space, height: CGFloat) -> some View {
        let chrome = WindowChrome()
        state.space = space
        if space != .home { state.studio = space }
        return ZStack(alignment: .topLeading) {
            Group {
                if space == .home {
                    // Laid out at its full height, as in the scroll view, then cut. A fixed
                    // height alone squeezes the page and its cards draw over their footers.
                    HomeContent().padding(.horizontal, 36)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(height: height - chrome.barHeight - 6, alignment: .top)
                        .clipped()
                } else {
                    StudioView()
                }
            }
            .padding(.top, chrome.barHeight + 6)
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
