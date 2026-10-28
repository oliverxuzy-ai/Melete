import SwiftUI
import AppKit

/// Edge cases from real use, driven the way a person would: real key presses sent to the
/// window, trays opened over a result, the window closed mid recording, the service failing
/// mid upload, and a long random walk through the app checking after every step that the
/// window still draws.
@MainActor
extension E2E {
    static var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.frame.width > 400 } }

    /// Each studio's two buttons, step by step: the left one only plays the original (听原文,
    /// 暂停, 继续听), the main one only records you (开始跟读 or 开始复述, 现在开始, 停止), and
    /// the end of the original hands back to you instead of starting anything.
    static func buttonFlows(state: AppState, stage: StageModel) async {
        let kinds: [(String, String)] = [("shadow", "跟读"), ("retell", "复述")]
        for (kind, verb) in kinds {
            guard let it = state.today?.items.first(where: { $0.kind == kind }) else { continue }
            stage.present(item: it, autoStart: false)
            _ = await waitFor(8) { stage.practice?.reference != nil && stage.phase == .ready }
            func line(_ step: String) -> String { "\(step): \(stage.listenLabel) | \(stage.mainLabel)" }
            var seen = [line("ready")]
            stage.listen()
            _ = await waitFor(6) { stage.player.playing }
            seen.append(line("listening"))
            stage.player.toggle()
            try? await Task.sleep(for: .milliseconds(200))
            seen.append(line("paused"))
            stage.player.toggle()
            _ = await waitFor(3) { stage.player.playing }
            stage.player.pause()
            stage.player.onFinish?()   // as if the original reached its end
            seen.append(line("heard") + " | " + stage.readyPrompt.replacingOccurrences(of: "\n", with: " "))
            try? await Task.sleep(for: .milliseconds(500))
            stage.start("button")
            _ = await waitFor(3) { stage.phase == .countdown }
            seen.append("countdown: \(stage.mainLabel), original \(stage.player.playing ? "playing" : "quiet")")
            stage.cancel()
            _ = await waitFor(2) { stage.phase == .ready }
            let expected = ["ready: 听原文 | 开始\(verb)", "listening: 暂停 | 开始\(verb)", "paused: 继续听 | 开始\(verb)",
                            "heard: 听原文 | 开始\(verb) | 听完了 回车开始\(verb)", "countdown: 现在开始, original quiet"]
            check("buttons: \(verb) goes 听原文 then 开始\(verb), and nothing records by itself", seen == expected, seen.joined(separator: " → "))
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Sends a key press to the window, as the keyboard would.
    static func key(_ code: UInt16, _ chars: String, repeating: Bool = false) {
        guard let w = mainWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: repeating, keyCode: code) {
                NSApp.sendEvent(e)
            }
        }
    }
    static func space(repeating: Bool = false) { key(49, " ", repeating: repeating) }
    static func returnKey() { key(36, "\r") }
    static func escape() { key(53, "\u{1b}") }

    static func bringToFront() async {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// True when the studio view has drawn `space` and its water clock is producing frames.
    static func studioDrawing(_ space: Space) async -> (Bool, String) {
        try? await Task.sleep(for: .milliseconds(700))
        FrameProbe.begin()
        try? await Task.sleep(for: .milliseconds(450))
        let r = FrameProbe.end()
        return (FrameProbe.drawnStudio == space.rawValue && r.frames > 8, "drawn \(FrameProbe.drawnStudio), \(r.frames) frames")
    }

    static func edgeCases(state: AppState, recorder: Recorder, stage: StageModel, api: API) async {
        log("-- edge cases")
        await state.refreshToday()
        guard let today = state.today else { return }
        let shadowItem = today.items.first { $0.kind == "shadow" }
        let topicItem = today.items.first { Space.of(kind: $0.kind) == .topic }

        // ---------- keyboard
        await bringToFront()
        state.closeTray()
        state.go(.home)
        try? await Task.sleep(for: .milliseconds(500))
        let before = (stage.item?.id, stage.phase)
        space()
        try? await Task.sleep(for: .milliseconds(500))
        check("keys: Space on 今天 leaves the stage alone", stage.item?.id == before.0 && stage.phase == before.1, "\(stage.phase)")

        returnKey()
        let started = await waitFor(4) { state.space != .home && (stage.phase == .countdown || stage.phase == .listening) }
        check("keys: Return on 今天 starts today's next item", started, "space \(state.space), phase \(stage.phase)")
        try? await Task.sleep(for: .milliseconds(300))   // a person needs longer than this to reach Esc
        escape()
        let backToReady = await waitFor(2) { stage.phase == .ready }
        check("keys: Esc steps back from the countdown", backToReady, "\(stage.phase)")

        if let shadowItem {
            stage.present(item: shadowItem, autoStart: false)
            _ = await waitFor(5) { stage.phase == .ready && stage.practice?.reference != nil }
            try? await Task.sleep(for: .milliseconds(600))
            let arms = recorder.armCount
            space(); space(repeating: true); space(repeating: true); space(repeating: true)
            try? await Task.sleep(for: .milliseconds(300))
            check("keys: holding Space takes one step", stage.phase == .countdown, "\(stage.phase)")
            try? await Task.sleep(for: .milliseconds(600))
            space()   // 现在开始: skip the rest of the countdown
            let rec = await waitFor(3) { stage.phase == .recording }
            check("keys: Space in the countdown starts recording at once, with one microphone", rec && recorder.armCount == arms + 1,
                  "phase \(stage.phase), \(recorder.armCount - arms) microphone setups")
            try? await Task.sleep(for: .milliseconds(700))
            space()   // stop after about a second: too short to keep
            let short = await waitFor(4) { stage.phase == .ready }
            check("keys: Space stops, and a one second take is not kept", short && stage.notice != nil, stage.notice ?? "no notice")
        }

        // A tray owns the keyboard while it is open.
        await state.openTray(.settings)
        try? await Task.sleep(for: .milliseconds(400))
        let underTray = (stage.item?.id, stage.phase)
        space(); returnKey()
        try? await Task.sleep(for: .milliseconds(500))
        check("keys: Space and Return do not reach the stage under a tray", stage.phase == underTray.1 && stage.item?.id == underTray.0, "\(stage.phase)")
        escape()
        let trayClosed = await waitFor(2) { state.tray == nil }
        check("keys: Esc closes the tray", trayClosed)

        // ---------- navigation while busy
        if let topicItem {
            stage.present(item: topicItem)
            _ = await waitFor(8) { stage.phase == .recording }
            let recordingItem = stage.item?.id
            NotificationCenter.default.post(name: .startToday, object: nil)
            NotificationCenter.default.post(name: .newPractice, object: nil)
            NotificationCenter.default.post(name: .openSettings, object: nil)
            try? await Task.sleep(for: .milliseconds(500))
            check("busy: the shortcut, 新讲稿 and settings wait while recording",
                  stage.phase == .recording && stage.item?.id == recordingItem && state.tray == nil, "phase \(stage.phase), tray \(state.tray?.id ?? "none")")
            stage.prepare(for: stage.studio, force: true)   // what a new day does
            check("busy: a new day does not interrupt a recording", stage.phase == .recording && stage.item?.id == recordingItem)

            // Walk away while it is analysed; the verdict waits on stage.
            try? await Task.sleep(for: .seconds(2.5))
            Task { await stage.stopRecording() }
            _ = await waitFor(2) { stage.phase == .analyzing }
            state.go(.home)
            check("busy: you can leave while it is analysed", state.space == .home)
            let verdict = await waitFor(120) { stage.phase == .result }
            check("busy: the verdict waits on stage for your return", verdict && stage.result != nil, stage.result?.review?.headline ?? "none")

            // Delete the recording the verdict is about: the verdict goes with it.
            if let sid = stage.result?.id {
                await state.openTray(.session(sid))
                await state.deleteSession()
                check("data: deleting the recording on the verdict clears the verdict", stage.result == nil && stage.phase == .ready)
            }
        }

        // Put something else on stage while one is analysed: the verdict becomes a notice.
        if let topicItem, let shadowItem {
            stage.present(item: topicItem)
            _ = await waitFor(8) { stage.phase == .recording }
            try? await Task.sleep(for: .seconds(2.5))
            Task { await stage.stopRecording() }
            _ = await waitFor(2) { stage.phase == .analyzing }
            stage.present(item: shadowItem, autoStart: false)
            let landed = await waitFor(120) { stage.notice?.hasPrefix("刚才那一段") == true }
            check("busy: a verdict for material no longer on stage arrives as a note", landed && stage.item?.id == shadowItem.id && stage.phase == .ready,
                  stage.notice ?? "no note")
        }

        // ---------- abandon: 放弃这段 and Esc throw a take away, and the next take still works
        if let it = state.today?.items.first(where: { $0.kind == "impromptu" }) {
            let before = (try? await api.sessions(filter: "all"))?.count ?? -1
            let ways: [(String, () -> Void)] = [("放弃这段", { stage.discard("button") }), ("Esc", { escape() })]
            for (how, act) in ways {
                stage.present(item: it)
                _ = await waitFor(10) { stage.phase == .recording }
                try? await Task.sleep(for: .seconds(2))
                let file = recorder.fileURL
                act()
                let back = await waitFor(2) { stage.phase == .ready }
                let gone = file.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
                check("abandon: \(how) while recording throws the take away", back && !recorder.isRecording && gone,
                      "\(stage.phase), recording \(recorder.isRecording), file gone \(gone), note \(stage.notice ?? "none")")
                try? await Task.sleep(for: .milliseconds(700))
            }
            try? await Task.sleep(for: .seconds(2))
            let after = (try? await api.sessions(filter: "all"))?.count ?? -2
            check("abandon: nothing reaches the record", after == before, "\(before) then \(after)")
            stage.start("button")
            let rec = await waitFor(10) { stage.phase == .recording }
            try? await Task.sleep(for: .seconds(3))
            stage.start("button")
            let judged = await waitFor(120) { stage.phase == .result }
            check("abandon: the next take records and gets a verdict", rec && judged, "\(stage.phase)")
            stage.cancel()
            _ = await waitFor(2) { stage.phase == .ready }
        }

        // ---------- retell: the original never starts your turn by itself
        if let retell = today.items.first(where: { $0.kind == "retell" }) {
            stage.present(item: retell)
            _ = await waitFor(8) { stage.phase == .listening }
            stage.player.pause()
            stage.player.onFinish?()   // as if the original reached its end
            check("retell: when the original ends, the stage waits for 开始复述", stage.phase == .ready && stage.heardThrough,
                  "\(stage.phase), \(stage.readyPrompt.replacingOccurrences(of: "\n", with: " "))")
            try? await Task.sleep(for: .milliseconds(500))
            stage.start("button")
            let turn = await waitFor(3) { stage.phase == .countdown }
            check("retell: 开始复述 starts your turn without replaying the original", turn && !stage.player.playing,
                  "\(stage.phase), playing \(stage.player.playing)")
            stage.cancel()
            _ = await waitFor(2) { stage.phase == .ready }
        }
        await buttonFlows(state: state, stage: stage)

        // ---------- data
        // A script on stage that gets deleted leaves the stage.
        if let id = await state.createPractice(title: "E2E temporary script", scenario: "presentation", script: "Point one. Point two."),
           let p = await state.fetchPractice(id) {
            stage.present(practice: p, mode: .free, autoStart: false)
            await state.openTray(.practice(id))
            await state.deletePractice()
            try? await Task.sleep(for: .milliseconds(500))
            check("data: deleting the script on stage takes it off the stage", stage.practice?.id != id && state.tray == nil, stage.title)
        }

        // The service failing mid upload keeps the recording, and it goes up once the service is back.
        if let topicItem, let real = state.server.baseURL {
            let pendingBefore = state.pending.count
            stage.present(item: topicItem)
            _ = await waitFor(8) { stage.phase == .recording }
            try? await Task.sleep(for: .seconds(2.5))
            state.server.baseURL = URL(string: "http://127.0.0.1:9")   // nothing listens there
            await stage.stopRecording()
            check("data: a failed upload keeps the recording for later", state.pending.count == pendingBefore + 1 && stage.notice?.contains("录音已经存好") == true,
                  stage.notice ?? "no note")
            state.server.baseURL = real
            await state.flushPending()
            check("data: kept recordings go up when the service is back", state.pending.count == pendingBefore, "\(state.pending.count) still waiting")
        }

        // Quitting mid recording keeps what was said.
        if let topicItem {
            let pendingBefore = state.pending.count
            stage.present(item: topicItem)
            _ = await waitFor(8) { stage.phase == .recording }
            try? await Task.sleep(for: .seconds(2))
            stage.saveForQuit()
            check("data: quitting mid recording keeps it for the next launch", state.pending.count == pendingBefore + 1 && !recorder.isRecording)
            stage.cancel(); stage.phase = .ready
            await state.flushPending()
            check("data: and it is analysed after relaunch", state.pending.count == pendingBefore)
        }

        // ---------- the window
        if let topicItem {
            stage.present(item: topicItem)
            _ = await waitFor(8) { stage.phase == .recording }
            try? await Task.sleep(for: .seconds(2.5))
            mainWindow?.performClose(nil)
            let saved = await waitFor(120) { stage.phase == .result || stage.phase == .ready }
            check("window: closing it mid recording stops and keeps the take", saved && !recorder.isRecording, "\(stage.phase)")
            state.requestStart()   // the shortcut with no window open
            let reopened = await waitFor(8) { mainWindow != nil }
            let began = await waitFor(8) { stage.phase == .countdown || stage.phase == .listening }
            check("window: the shortcut with no window opens one and starts", reopened && began, "window \(reopened), phase \(stage.phase)")
            stage.cancel()
            _ = await waitFor(2) { stage.phase == .ready }
        }

        await stress(state: state, recorder: recorder, stage: stage)
    }

    /// A long random walk through the app; after every step the window must still draw.
    static func stress(state: AppState, recorder: Recorder, stage: StageModel) async {
        var rng = SystemRandomNumberGenerator()
        let trays: [Tray] = [.progress, .settings, .history, .clips, .agenda, .newTopic, .addLink]
        var failures: [String] = []
        let steps = 40
        for step in 1...steps {
            let roll = Int.random(in: 0..<8, using: &rng)
            var label = ""
            switch roll {
            case 0: state.go(.home); label = "home"
            case 1: state.go(.shadow); label = "跟读"
            case 2: state.go(.topic); label = "主题"
            case 3:
                let t = trays.randomElement(using: &rng)!
                await state.openTray(t); label = "tray \(t.id)"
                try? await Task.sleep(for: .milliseconds(250))
                state.closeTray()
            case 4:
                if state.space != .home, stage.practice?.reference != nil { stage.listen(); label = "listen" }
                try? await Task.sleep(for: .milliseconds(400))
                state.go(state.space == .shadow ? .topic : .shadow); label += " then switch"
            case 5:
                if state.space != .home, stage.hasMaterial, stage.phase == .ready {
                    stage.start(); label = "countdown"
                    try? await Task.sleep(for: .milliseconds(500))
                    stage.cancel()
                } else { state.go(.topic); label = "主题" }
            case 6:
                if let item = state.today?.items.randomElement(using: &rng) { stage.present(item: item, autoStart: false); label = "present \(item.kind)" }
            default:
                state.go(state.space == .home ? .shadow : .home); label = "toggle"
            }
            if state.space != .home {
                let (ok, d) = await studioDrawing(state.studio)
                if !ok {
                    let wins = NSApp.windows.filter { $0.frame.width > 400 }.map {
                        "visible \($0.isVisible) occl \($0.occlusionState.contains(.visible)) key \($0.isKeyWindow) mini \($0.isMiniaturized) frame \($0.frame.integral)"
                    }
                    try? await Task.sleep(for: .seconds(2))
                    FrameProbe.begin()
                    try? await Task.sleep(for: .milliseconds(800))
                    let later = FrameProbe.end()
                    failures.append("step \(step) (\(label)): \(d); windows \(wins); 2 s later \(later.frames) frames")
                    break
                }
            } else {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        check("stress: \(steps) random moves, the window draws after every one", failures.isEmpty, failures.first ?? "")
        stage.cancel()
        state.closeTray()
    }

    /// A first day: no clips, no scripts, no recordings. Every place must still make sense and
    /// the very first recording must get a verdict.
    static func emptyDay(state: AppState, recorder: Recorder, stage: StageModel) async {
        log("-- a first day: no clips, no scripts, no recordings")
        await state.refreshToday()
        check("first day: today's plan loads", state.today != nil, state.today?.items.map(\.kind).joined(separator: ", ") ?? "none")
        await state.loadRecent()
        check("first day: the record is empty", state.recent.isEmpty, "\(state.recent.count) rows")
        state.go(.shadow)
        try? await Task.sleep(for: .milliseconds(900))
        check("first day: 跟读 shows its empty state", !(stage.studio == .shadow && stage.hasMaterial) && FrameProbe.drawnStudio == "shadow",
              "studio \(stage.studio), material \(stage.hasMaterial)")
        await state.openTray(.addLink)
        check("first day: 贴一个链接 opens", state.tray == .addLink)
        state.closeTray()
        await state.openTray(.newTopic)
        check("first day: 新讲稿 opens", state.tray == .newTopic)
        state.closeTray()
        state.go(.topic)
        let topicReady = await waitFor(4) { stage.studio == .topic && stage.hasMaterial }
        check("first day: 主题 still offers something to say", topicReady, stage.title)
        // The very first recording, with no baseline to compare against.
        stage.start()
        let rec = await waitFor(8) { stage.phase == .recording }
        try? await Task.sleep(for: .seconds(3))
        await stage.stopRecording()
        let judged = await waitFor(120) { stage.phase == .result }
        check("first day: the first recording gets a verdict", rec && judged && stage.result?.review != nil, stage.result?.review?.headline ?? stage.notice ?? "none")
        await state.openTray(.history)
        check("first day: 全部记录 lists it", state.tray == .history && state.history.count == 1, "\(state.history.count) rows")
        state.closeTray()
        await state.openTray(.progress)
        check("first day: 进展 opens with its numbers", state.tray == .progress && state.insights != nil && state.recap != nil && state.recent.count == 1,
              "insights \(state.insights != nil), recap \(state.recap != nil), \(state.recent.count) rows")
        state.closeTray()
        state.go(.home)
        try? await Task.sleep(for: .milliseconds(500))
        check("first day: back on 今天", state.space == .home)
    }
}
