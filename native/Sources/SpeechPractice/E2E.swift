import SwiftUI
import AppKit
import AVFoundation
import UserNotifications
import QuartzCore

/// Frame timestamps from the orb's display-synced timeline. Gaps mean dropped frames.
@MainActor
enum FrameProbe {
    static var enabled = false
    static var stamps: [CFTimeInterval] = []

    static func mark() { if enabled { stamps.append(CACurrentMediaTime()) } }
    /// The studio the studio view last drew (probe only).
    static var drawnStudio = ""
    /// Where the stage's main button is, in window points from the top left (probes click it).
    static var mainButton = CGRect.zero
    /// What the main button and the clock last drew (probes compare them with the model).
    static var drawnMainLabel = ""
    static var drawnClock = ""
    static var drawnVerdict = false
    static var navFrames: [String: CGRect] = [:]
    static var verdictFrame = CGRect.zero
    static var drawnTray = ""
    static var drawnSpace = ""
    static func begin() { stamps = []; enabled = true }

    /// p95 and worst gap between frames in milliseconds, and how many gaps exceeded 33 ms.
    static func end() -> (frames: Int, p95: Double, worst: Double, over33: Int) {
        enabled = false
        let gaps = zip(stamps, stamps.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
        lastGaps = gaps
        guard !gaps.isEmpty else { return (stamps.count, 0, 0, 0) }
        let p95 = gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))]
        return (stamps.count, p95, gaps.last ?? 0, gaps.filter { $0 > 33 }.count)
    }

    static var lastGaps: [Double] = []

    /// Median gap and the share of frames that missed a 120 Hz deadline.
    static func detail() -> String {
        guard !lastGaps.isEmpty else { return "" }
        let med = lastGaps[lastGaps.count / 2]
        let missed = Double(lastGaps.filter { $0 > 12 }.count) / Double(lastGaps.count) * 100
        return String(format: "median %.1f ms, %.0f%% over 12 ms", med, missed)
    }
}

/// `--e2e <report.txt>`: drives the real flows through StageModel and AppState, the same
/// calls the buttons make, against SPEECH_SERVER_URL. MELETE_FAKE_MIC stands in for the
/// microphone; the recording still goes through upload, Whisper and the review.
/// One PASS or FAIL line per check; exits 1 if anything failed.
@MainActor
enum E2E {
    static var lines: [String] = []
    /// A harness is running in this process.
    static var started = false
    static var failures = 0
    static var reportURL: URL?

    static func log(_ s: String) {
        lines.append(s)
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
        if let reportURL { try? lines.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8) }
    }

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
    }

    static func note(_ name: String, _ detail: String) { log("INFO  \(name)  (\(detail))") }

    static func waitFor(_ seconds: Double, _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    static func frames(_ name: String, _ r: (frames: Int, p95: Double, worst: Double, over33: Int)) {
        let detail = String(format: "%d frames, p95 %.1f ms, worst %.1f ms, %d gaps over 33 ms", r.frames, r.p95, r.worst, r.over33)
        // No frames while the app says the water clock is on stage means the system was not
        // drawing this window (covered, on another desktop, display off): that says nothing about
        // smoothness. No frames when the clock should not be showing is a real failure.
        if r.frames < 20 {
            if let st = stateRef, let s = stageRef, st.space == s.studio, s.hasMaterial, s.phase != .ready, s.phase != .result {
                note("smooth: \(name)", "the water clock was on stage but the window was not being drawn; \(detail)")
            } else {
                check("smooth: \(name)", false, "the water clock was not on stage; \(detail)")
            }
            return
        }
        let ok = r.frames > 20 && r.p95 <= 20 && r.worst <= 60
        check("smooth: \(name)", ok, detail)
    }

    /// `--perf <report>`: only the frame pacing of speaking, three times, no uploads.
    static func perf(state: AppState, recorder: Recorder, stage: StageModel) async {
        holdFullSpeed()
        stateRef = state
        stageRef = stage
        if ProcessInfo.processInfo.environment["MELETE_DEACTIVATE"] != nil {
            try? await Task.sleep(for: .seconds(1.5))
            NSApp.deactivate()   // as when you work in another app with this window still in view
        }
        if let i = CommandLine.arguments.firstIndex(of: "--perf"), CommandLine.arguments.count > i + 1 {
            reportURL = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        PlayerModel.muted = true
        log("Melete frame pacing, env: " + ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("MELETE_") && $0.key != "MELETE_FAKE_MIC" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        await state.boot()
        await state.refreshToday()
        let kinds = (ProcessInfo.processInfo.environment["PERF_KINDS"] ?? "impromptu,shadow").split(separator: ",").map(String.init)
        for kind in kinds {
            guard let item = state.today?.items.first(where: { $0.kind == kind }) else { continue }
            for round in 1...2 {
                stage.present(item: item)
                _ = await waitFor(10) { stage.phase == .countdown || stage.phase == .listening }
                if stage.phase == .listening { stage.toggle() }
                FrameProbe.begin()
                _ = await waitFor(10) { stage.phase == .recording }
                frames("\(kind) \(round) countdown into recording", FrameProbe.end()); log("      " + FrameProbe.detail())
                let win = NSApp.windows.filter { $0.frame.width > 400 }.map { "visible \($0.isVisible) occl \($0.occlusionState.contains(.visible)) key \($0.isKeyWindow)" }
                log("      space \(state.space), studio \(stage.studio), phase \(stage.phase), drawn \(FrameProbe.drawnStudio), windows \(win)")
                try? await Task.sleep(for: .milliseconds(500))
                FrameProbe.begin()
                try? await Task.sleep(for: .seconds(4))
                frames("\(kind) \(round) speaking", FrameProbe.end()); log("      " + FrameProbe.detail())
                _ = await recorder.stop()
                stage.cancel()
                stage.phase = .ready
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        finish()
    }

    /// `--freezeprobe <report>`: records, stops, and walks between the studios twelve times with
    /// the app in the background, checking after each move that the new studio is really on
    /// screen and still drawing. Reports the first move after which the window stopped updating.
    static func freezeProbe(state: AppState, recorder: Recorder, stage: StageModel) async {
        holdFullSpeed()
        stateRef = state
        stageRef = stage
        if let i = CommandLine.arguments.firstIndex(of: "--freezeprobe"), CommandLine.arguments.count > i + 1 {
            reportURL = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        PlayerModel.muted = true
        log("freeze probe, env: " + ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("MELETE_") && $0.key != "MELETE_FAKE_MIC" }.map { "\($0.key)" }.sorted().joined(separator: " "))
        await state.boot()
        await state.refreshToday()
        guard let shadowItem = state.today?.items.first(where: { $0.kind == "shadow" }),
              let topicItem = state.today?.items.first(where: { Space.of(kind: $0.kind) == .topic }) else { log("plan lacks items"); finish(); return }
        try? await Task.sleep(for: .seconds(1))
        if let want = ProcessInfo.processInfo.environment["MELETE_SCREEN"],
           let w = NSApp.windows.first(where: { $0.frame.width > 400 }) {
            // Put the window on the built-in screen or the external one, to see whether it matters.
            let screens = NSScreen.screens
            let target = want == "builtin" ? screens.first { $0.maximumFramesPerSecond >= 120 } : screens.first { $0.maximumFramesPerSecond < 120 }
            if let t = target {
                w.setFrameOrigin(NSPoint(x: t.visibleFrame.minX + 40, y: t.visibleFrame.maxY - w.frame.height - 20))
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
        let screenName = NSApp.windows.first(where: { $0.frame.width > 400 })?.screen?.localizedName ?? "none"
        log("      window on \(screenName)")
        if ProcessInfo.processInfo.environment["MELETE_NODEACTIVATE"] == nil { NSApp.deactivate() }
        func drawing(_ space: Space) async -> (Bool, String) {
            try? await Task.sleep(for: .milliseconds(900))
            FrameProbe.begin()
            try? await Task.sleep(for: .milliseconds(500))
            let r = FrameProbe.end()
            let drawn = FrameProbe.drawnStudio == space.rawValue
            return (drawn && r.frames > 10, "drawn \(FrameProbe.drawnStudio), \(r.frames) frames")
        }
        for cycle in 1...12 {
            stage.present(item: shadowItem)
            _ = await waitFor(10) { stage.phase == .recording }
            try? await Task.sleep(for: .milliseconds(800))
            _ = await recorder.stop()
            stage.cancel()
            stage.phase = .ready
            stage.present(item: topicItem, autoStart: false)
            let (okTopic, dTopic) = await drawing(.topic)
            if !okTopic {
                let w = NSApp.windows.first { $0.frame.width > 400 }
                log("      app active \(NSApp.isActive), window on active space \(w?.isOnActiveSpace ?? false), occl \(w?.occlusionState.rawValue ?? 0), fps \(w?.screen?.maximumFramesPerSecond ?? 0), visible \(w?.isVisible ?? false)")
                check("cycle \(cycle): 跟读 to 主题", false, dTopic)
                // Which nudge brings a frozen window back?
                let attempts: [(String, () -> Void)] = [
                    ("needsLayout", { w?.contentView?.needsLayout = true }),
                    ("layoutSubtreeIfNeeded", { w?.contentView?.layoutSubtreeIfNeeded() }),
                    ("display", { w?.contentView?.needsDisplay = true; w?.displayIfNeeded() }),
                    ("activate", { NSApp.activate(ignoringOtherApps: true); w?.makeKeyAndOrderFront(nil) }),
                ]
                for (name, nudge) in attempts {
                    nudge()
                    try? await Task.sleep(for: .milliseconds(800))
                    FrameProbe.begin()
                    try? await Task.sleep(for: .milliseconds(500))
                    let r = FrameProbe.end()
                    log("      after \(name): \(r.frames) frames, drawn \(FrameProbe.drawnStudio)")
                }
                finish(); return
            }
            state.go(.shadow)
            let (okShadow, dShadow) = await drawing(.shadow)
            if !okShadow { check("cycle \(cycle): 主题 to 跟读", false, dShadow); finish(); return }
        }
        check("twelve cycles without the window freezing", true)
        finish()
    }

    /// `--listenprobe <report>`: puts the retell clip on stage eight times and records what the
    /// player is doing each time, to find why listening sometimes never starts.
    static func listenProbe(state: AppState, recorder: Recorder, stage: StageModel) async {
        holdFullSpeed()
        if let i = CommandLine.arguments.firstIndex(of: "--listenprobe"), CommandLine.arguments.count > i + 1 {
            reportURL = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        PlayerModel.muted = true
        await state.boot()
        await state.refreshToday()
        guard let retell = state.today?.items.first(where: { $0.kind == "retell" }) else { log("no retell item"); finish(); return }
        StageModel.tracing = true
        state.go(.topic)
        try? await Task.sleep(for: .milliseconds(400))
        for round in 1...8 {
            stage.present(item: retell)
            let ok = await waitFor(8) { stage.phase == .listening && stage.player.time > 0.6 }
            let p = stage.player.player
            let item = p?.currentItem
            let detail = String(format: "phase %@, time %.2f, model playing %@, rate %.1f, control %d, waiting %@, item status %d, error %@, url %@",
                                "\(stage.phase)", stage.player.time, "\(stage.player.playing)", p?.rate ?? -1,
                                p?.timeControlStatus.rawValue ?? -1, p?.reasonForWaitingToPlay?.rawValue ?? "none",
                                item?.status.rawValue ?? -1, item?.error?.localizedDescription ?? "none",
                                (item?.asset as? AVURLAsset)?.url.lastPathComponent ?? "none")
            check("listen round \(round)", ok, detail)
            if !ok { for line in StageModel.trace { log("      " + line) } }
            StageModel.trace = []
            stage.cancel()
            try? await Task.sleep(for: .milliseconds(300))
            state.go(round % 2 == 0 ? .topic : .home)
            try? await Task.sleep(for: .milliseconds(300))
        }
        finish()
    }

    /// Shadowing the way it is used: 开始跟读 straight away, 听原文 then 开始跟读 (while it plays, and
    /// after it ends), and 再来一遍 from the verdict. Every take must keep recording until it is
    /// stopped, and when sound comes out of speakers the clip must not be heard while the
    /// microphone is open (it would be recorded and analysed as you).
    static func shadowProbe(state: AppState, recorder: Recorder, stage: StageModel) async {
        holdFullSpeed()
        if let i = CommandLine.arguments.firstIndex(of: "--shadowprobe"), CommandLine.arguments.count > i + 1 {
            reportURL = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        PlayerModel.muted = true
        StageModel.tracing = true
        log("Melete shadow probe, \(Date())")
        await state.boot()
        await state.refreshToday()
        guard let item = state.today?.items.first(where: { $0.kind == "shadow" }) else { log("no shadow item"); finish(); return }
        let speakers = ProcessInfo.processInfo.environment["MELETE_ROUTE"] != "headphones"
        log("route: \(speakers ? "speakers" : "headphones")")

        func dump() { for line in StageModel.trace { log("      " + line) } }
        func take(_ name: String, open: () async -> Void) async {
            StageModel.trace = []
            await open()
            let rec = await waitFor(10) { stage.phase == .recording }
            check("\(name): recording opens", rec, "\(stage.phase)")
            guard rec else { dump(); return }
            try? await Task.sleep(for: .seconds(2))
            let audible = stage.player.playing && !stage.player.silenced
            check("\(name): " + (speakers ? "the clip is not heard while the microphone is open" : "the clip plays in your ears"),
                  speakers ? !audible : audible,
                  String(format: "playing %@, silenced %@, clip at %.1f s", "\(stage.player.playing)", "\(stage.player.silenced)", stage.player.time))
            check("\(name): the subtitles follow " + (speakers ? "your voice" : "the original in your ears"),
                  stage.followsVoice == speakers, "follows voice \(stage.followsVoice)")
            let held = await holds(6) { stage.phase == .recording }
            check("\(name): keeps recording until you stop", held, String(format: "%@ after %.1f s", "\(stage.phase)", recorder.elapsed))
            if !held { dump() }
            if stage.phase == .recording { stage.start("button") }
            let done = await waitFor(120) { stage.phase == .result || stage.phase == .ready }
            check("\(name): stopping gives a verdict", done && stage.phase == .result, "\(stage.phase)")
            check("\(name): the clip is audible again afterwards", !stage.player.silenced)
        }
        await buttonFlows(state: state, stage: stage)
        func ready() async {
            stage.cancel()
            _ = await waitFor(5) { stage.phase == .ready }
            try? await Task.sleep(for: .milliseconds(600))   // past the press debounce
        }

        state.go(.shadow)
        stage.present(item: item, autoStart: false)
        _ = await waitFor(8) { stage.practice != nil && stage.phase == .ready }
        try? await Task.sleep(for: .milliseconds(600))
        await take("A 开始跟读") { stage.start("button") }

        await ready()
        await take("B 听原文, then 开始跟读 while it plays") {
            stage.listen()
            _ = await waitFor(8) { stage.phase == .listening && stage.player.time > 1 }
            try? await Task.sleep(for: .seconds(2))
            stage.start("button")
        }

        await ready()
        await take("C 听原文 to the end, then 开始跟读") {
            stage.listen()
            _ = await waitFor(8) { stage.phase == .listening && stage.player.time > 0.5 }
            stage.player.seek(to: max(0, stage.player.duration - 1.2))
            _ = await waitFor(12) { stage.phase == .ready }
            try? await Task.sleep(for: .milliseconds(600))
            stage.start("button")
        }

        await take("D 再跟一遍 from the verdict") { stage.again() }

        await ready()
        await take("E 听原文, pause, then 开始跟读") {
            stage.listen()
            _ = await waitFor(8) { stage.phase == .listening && stage.player.time > 1 }
            stage.player.toggle()
            try? await Task.sleep(for: .seconds(1))
            stage.start("button")
        }
        finish()
    }

    /// `--clickprobe <report>`: presses the studio's main button with mouse events (hover, press,
    /// release), the way a hand does, then marks two moments for an outside window capture
    /// (`<report>.mark1`, `.mark2`), so what the window really shows can be compared.
    static func clickProbe(state: AppState, recorder: Recorder, stage: StageModel) async {
        holdFullSpeed()
        if let i = CommandLine.arguments.firstIndex(of: "--clickprobe"), CommandLine.arguments.count > i + 1 {
            reportURL = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        PlayerModel.muted = true
        StageModel.tracing = true
        log("Melete click probe, \(Date())")
        await state.boot()
        await state.refreshToday()
        let kind = ProcessInfo.processInfo.environment["CLICK_KIND"] ?? "impromptu"
        guard let item = state.today?.items.first(where: { $0.kind == kind }) else { log("no \(kind) item"); finish(); return }
        stage.present(item: item, autoStart: false)
        _ = await waitFor(8) { stage.phase == .ready && (item.practiceId == nil || stage.practice != nil) }
        try? await Task.sleep(for: .seconds(1.5))
        log("main button at \(FrameProbe.mainButton)")
        await click(FrameProbe.mainButton)
        let rec = await waitFor(8) { stage.phase == .recording }
        check("click: recording opens", rec, "\(stage.phase)")
        FrameProbe.begin()
        try? await Task.sleep(for: .seconds(1.5))
        mark("1")
        let clockA = FrameProbe.drawnClock
        try? await Task.sleep(for: .seconds(3))
        mark("2")
        check("click: the button drew 停止", FrameProbe.drawnMainLabel == "停止", "drew \(FrameProbe.drawnMainLabel)")
        check("click: the clock keeps drawing", FrameProbe.drawnClock != clockA, "\(clockA) then \(FrameProbe.drawnClock)")
        try? await Task.sleep(for: .seconds(1.5))
        let f = FrameProbe.end()
        check("click: the window keeps drawing while recording", f.frames > 120, String(format: "%d frames, worst %.0f ms", f.frames, f.worst))
        check("click: the model says 停止", stage.mainLabel == "停止", stage.mainLabel)
        await click(FrameProbe.mainButton)
        let stopped = await waitFor(120) { stage.phase == .result || stage.phase == .ready }
        check("click: a second click stops", stopped, "\(stage.phase)")
        try? await Task.sleep(for: .milliseconds(800))
        check("click: the verdict is drawn", FrameProbe.drawnVerdict, "phase \(stage.phase)")

        // The same class of change elsewhere: what the window draws must follow the model.
        stage.cancel()
        try? await Task.sleep(for: .milliseconds(800))
        check("drawn: 收起 draws the start button again", FrameProbe.drawnMainLabel == stage.startLabel && !FrameProbe.drawnVerdict,
              "drew \(FrameProbe.drawnMainLabel), verdict \(FrameProbe.drawnVerdict)")
        if stage.practice?.reference != nil {
            stage.listen()
            _ = await waitFor(6) { stage.player.playing }
            try? await Task.sleep(for: .milliseconds(600))
            check("drawn: 听原文 draws the start button beside 暂停", FrameProbe.drawnMainLabel == stage.startLabel, "drew \(FrameProbe.drawnMainLabel)")
            await click(FrameProbe.mainButton)
            _ = await waitFor(8) { stage.phase == .recording }
            try? await Task.sleep(for: .milliseconds(800))
            check("drawn: 开始 while the original plays draws 停止 once recording", FrameProbe.drawnMainLabel == "停止", "drew \(FrameProbe.drawnMainLabel)")
            await click(FrameProbe.mainButton)
            _ = await waitFor(120) { stage.phase == .result || stage.phase == .ready }
            stage.cancel()
            try? await Task.sleep(for: .milliseconds(600))
        }
        await state.openTray(.settings)
        try? await Task.sleep(for: .milliseconds(800))
        check("drawn: settings rise", FrameProbe.drawnTray == "settings", "drew \(FrameProbe.drawnTray)")
        state.closeTray()
        try? await Task.sleep(for: .milliseconds(800))
        check("drawn: settings close", FrameProbe.drawnTray == "", "drew \(FrameProbe.drawnTray)")
        let studio = state.space
        state.closeTray(); state.go(.home)
        try? await Task.sleep(for: .milliseconds(800))
        check("drawn: 今天 comes forward", FrameProbe.drawnSpace == "home", "drew \(FrameProbe.drawnSpace)")
        state.closeTray(); state.go(studio)
        try? await Task.sleep(for: .milliseconds(800))
        check("drawn: back to the studio", FrameProbe.drawnSpace == studio.rawValue, "drew \(FrameProbe.drawnSpace)")
        stage.cancel()
        _ = await waitFor(2) { stage.phase == .ready }
        try? await Task.sleep(for: .milliseconds(600))
        await click(FrameProbe.mainButton)
        _ = await waitFor(8) { stage.phase == .recording }
        try? await Task.sleep(for: .milliseconds(800))
        stage.discard("button")
        try? await Task.sleep(for: .milliseconds(800))
        check("drawn: 放弃这段 draws the start button again", FrameProbe.drawnMainLabel == stage.startLabel && stage.phase == .ready,
              "drew \(FrameProbe.drawnMainLabel), phase \(stage.phase)")
        for line in StageModel.trace { log("      " + line) }
        finish()
    }

    /// Hovers, presses and releases the mouse at the middle of a rect given in window points.
    /// `CLICK_VIA=cg` posts system mouse events to this process (through the app's event queue,
    /// like a real mouse, without moving the pointer); otherwise they go straight to the window.
    static func click(_ r: CGRect, hold: Double = 0.12) async {
        guard let w = mainWindow, r != .zero else { log("nothing to click"); return }
        if ProcessInfo.processInfo.environment["CLICK_VIA"] == "cg" {
            // Screen points, top left origin, as Quartz events use.
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            let p = CGPoint(x: w.frame.minX + r.midX, y: screenH - (w.frame.maxY - r.midY))
            let src = CGEventSource(stateID: .privateState)
            for (type, pause) in [(CGEventType.mouseMoved, 0.25), (.leftMouseDown, hold), (.leftMouseUp, 0.05)] {
                CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.postToPid(getpid())
                try? await Task.sleep(for: .seconds(pause))
            }
            return
        }
        let at = CGPoint(x: r.midX, y: w.frame.height - r.midY)
        for (type, pause) in [(NSEvent.EventType.mouseMoved, 0.2), (.leftMouseDown, hold), (.leftMouseUp, 0.05)] {
            if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.sendEvent(e)
            }
            try? await Task.sleep(for: .seconds(pause))
        }
    }

    static func mark(_ n: String) {
        guard let url = reportURL else { return }
        try? Data().write(to: URL(fileURLWithPath: url.path + ".mark" + n))
        log("mark \(n): phase \(stage(n)), label \(stageRef?.mainLabel ?? "")")
    }
    private static func stage(_ n: String) -> String { "\(stageRef?.phase ?? .ready)" }

    /// `--pointerprobe <report>`: what a hand does with a mouse, sent as mouse events through
    /// the window: resting on 开始 without clicking, a slow press, resting on the button while
    /// it turns into 停止, stopping and leaving at once, a double press, the switch at the top
    /// pressed thirty times, dragging the window by its background, and the smallest window in
    /// each stage state.
    static func pointerProbe(state: AppState, recorder: Recorder, stage: StageModel) async {
        holdFullSpeed()
        if let i = CommandLine.arguments.firstIndex(of: "--pointerprobe"), CommandLine.arguments.count > i + 1 {
            reportURL = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        PlayerModel.muted = true
        StageModel.tracing = true
        log("Melete pointer probe, \(Date())")
        await state.boot()
        await state.refreshToday()
        guard let item = state.today?.items.first(where: { $0.kind == "impromptu" }), let w = mainWindow else { log("no item or window"); finish(); return }
        stage.present(item: item, autoStart: false)
        _ = await waitFor(8) { stage.phase == .ready }
        try? await Task.sleep(for: .seconds(1.2))
        let b = FrameProbe.mainButton

        await mouse(.mouseMoved, at: b)
        try? await Task.sleep(for: .seconds(5))
        check("pointer: resting on 开始 without clicking starts nothing", stage.phase == .ready, "\(stage.phase)")

        await click(b, hold: 0.7)
        let cd = await waitFor(2) { stage.phase == .countdown }
        check("pointer: a slow press (0.7 s) starts the countdown once", cd, "\(stage.phase)")
        let rec = await waitFor(8) { stage.phase == .recording }
        try? await Task.sleep(for: .seconds(1))
        let c1 = FrameProbe.drawnClock, l1 = FrameProbe.drawnMainLabel
        try? await Task.sleep(for: .seconds(3))
        check("pointer: resting on the button, it turns to 停止 and the clock runs",
              rec && l1 == "停止" && FrameProbe.drawnMainLabel == "停止" && FrameProbe.drawnClock != c1,
              "\(l1) then \(FrameProbe.drawnMainLabel), \(c1) then \(FrameProbe.drawnClock)")

        await click(b, hold: 0.08)
        await mouse(.mouseMoved, at: b.offsetBy(dx: 0, dy: -260))
        let judged = await waitFor(120) { stage.phase == .result }
        try? await Task.sleep(for: .milliseconds(800))
        check("pointer: stop and move away at once, the verdict is drawn", judged && FrameProbe.drawnVerdict, "\(stage.phase)")
        stage.cancel()
        _ = await waitFor(2) { stage.phase == .ready }
        try? await Task.sleep(for: .milliseconds(900))

        await click(b, hold: 0.05)
        try? await Task.sleep(for: .milliseconds(90))
        await click(b, hold: 0.05)
        try? await Task.sleep(for: .seconds(1))
        check("pointer: a double press counts once (still counting down)", stage.phase == .countdown, "\(stage.phase)")
        stage.cancel()
        _ = await waitFor(2) { stage.phase == .ready }

        var wrong: [String] = []
        for i in 0..<10 {
            for s in [Space.home, .shadow, .topic] {
                guard let r = FrameProbe.navFrames[s.rawValue] else { wrong.append("no frame for \(s.rawValue)"); continue }
                await click(r, hold: 0.06)
                try? await Task.sleep(for: .milliseconds(450))
                if state.space != s || FrameProbe.drawnSpace != s.rawValue { wrong.append("\(i) \(s.rawValue): drew \(FrameProbe.drawnSpace)") }
            }
        }
        check("pointer: the switch at the top, 30 presses, each one drawn", wrong.isEmpty, wrong.prefix(3).joined(separator: "; "))

        let before = w.frame.origin
        await drag(from: CGPoint(x: 330, y: 44), by: CGSize(width: 60, height: -40))
        try? await Task.sleep(for: .milliseconds(500))
        // Window moves belong to the window server; events made in the app cannot drive one, so
        // this is reported, not judged.
        log("INFO  pointer: dragging the top bar with app-made events \(w.frame.origin != before ? "moved" : "did not move") the window (needs a real mouse to judge)")

        // The smallest window, in ready, recording and verdict: everything stays inside it.
        w.setFrame(NSRect(origin: w.frame.origin, size: NSSize(width: 1040, height: 700)), display: true)
        state.go(.topic)
        stage.present(item: item, autoStart: false)
        _ = await waitFor(8) { stage.phase == .ready }
        try? await Task.sleep(for: .seconds(1))
        let size = w.frame.size
        func inside(_ r: CGRect) -> Bool { r.minX >= 0 && r.maxX <= size.width && r.minY >= 60 && r.maxY <= size.height }
        check("small window: ready fits", inside(FrameProbe.mainButton), "button \(FrameProbe.mainButton) in \(size)")
        stage.start("button")
        _ = await waitFor(8) { stage.phase == .recording }
        try? await Task.sleep(for: .seconds(3))   // past the two second minimum, so it is kept
        check("small window: recording fits", inside(FrameProbe.mainButton) && FrameProbe.drawnMainLabel == "停止", "button \(FrameProbe.mainButton)")
        stage.start("button")
        _ = await waitFor(60) { stage.phase == .result }
        try? await Task.sleep(for: .seconds(1))
        check("small window: the verdict fits", inside(FrameProbe.verdictFrame), "verdict \(FrameProbe.verdictFrame) in \(size)")
        stage.cancel()

        // The menu bar icon follows its setting (菜单栏显示今天的计划), and comes back.
        func statusItems() -> Int { NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") && $0.isVisible }.count }
        let shown = statusItems()
        UserDefaults.standard.set(false, forKey: "menuBarExtra")
        try? await Task.sleep(for: .seconds(1))
        let off = statusItems()
        UserDefaults.standard.set(true, forKey: "menuBarExtra")
        try? await Task.sleep(for: .seconds(1))
        let on = statusItems()
        check("menu bar: the icon goes with the setting and comes back", shown >= 1 && off == shown - 1 && on == shown, "\(shown) then \(off) then \(on)")
        finish()
    }

    /// A mouse event at the middle of a rect given in window points from the top left.
    static func mouse(_ type: NSEvent.EventType, at r: CGRect) async {
        guard let w = mainWindow else { return }
        let at = CGPoint(x: r.midX, y: w.frame.height - r.midY)
        if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            NSApp.sendEvent(e)
        }
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// Presses at a point (window points from the top left), moves by an offset and lets go,
    /// posting the moves to the event queue where a window drag reads them.
    static func drag(from p: CGPoint, by d: CGSize) async {
        guard let w = mainWindow else { return }
        func ev(_ t: NSEvent.EventType, _ q: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: CGPoint(x: q.x, y: w.frame.height - q.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)
        }
        let steps = 6
        for i in 1...steps {
            let q = CGPoint(x: p.x + d.width * CGFloat(i) / CGFloat(steps), y: p.y + d.height * CGFloat(i) / CGFloat(steps))
            if let e = ev(.leftMouseDragged, q) { NSApp.postEvent(e, atStart: false) }
        }
        if let e = ev(.leftMouseUp, CGPoint(x: p.x + d.width, y: p.y + d.height)) { NSApp.postEvent(e, atStart: false) }
        if let down = ev(.leftMouseDown, p) { NSApp.sendEvent(down) }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// True if `cond` stays true for the whole time.
    static func holds(_ seconds: Double, _ cond: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if !cond() { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    /// Keeps a test run at full speed when its window is not in front (no App Nap or timer
    /// coalescing), so timings measure the app, not the power manager.
    static var activity: NSObjectProtocol?
    static func holdFullSpeed() {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Melete end to end test")
    }

    static weak var stateRef: AppState?

    static func run(state: AppState, recorder: Recorder, stage: StageModel) async {
        holdFullSpeed()
        stateRef = state
        StageModel.tracing = true
        if let i = CommandLine.arguments.firstIndex(of: "--e2e"), CommandLine.arguments.count > i + 1 {
            reportURL = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        PlayerModel.muted = true
        log("Melete end to end, \(Date())")
        check("fake microphone configured", ProcessInfo.processInfo.environment["MELETE_FAKE_MIC"] != nil)
        await state.boot()
        check("analysis service ready", state.isReady)
        check("opens on 今天", state.space == .home, "\(state.space)")
        await state.refreshToday()
        guard let today = state.today, let api = state.api else { check("today loads", false); finish() ; return }
        if ProcessInfo.processInfo.environment["E2E_EMPTY"] == nil {
            check("today loads", !today.items.isEmpty, today.items.map(\.kind).joined(separator: ", "))
        }

        if ProcessInfo.processInfo.environment["E2E_EMPTY"] != nil {
            await emptyDay(state: state, recorder: recorder, stage: stage)
            finish(); return
        }
        if ProcessInfo.processInfo.environment["E2E_EDGE_ONLY"] != nil {
            await edgeCases(state: state, recorder: recorder, stage: stage, api: api)
            await state.loadSettings()
            let original = state.settings?.coach.weekTargetDays ?? 5
            await state.saveSettings(["coach": ["week_target_days": original == 4 ? 5 : 4]])
            let changed = state.settings?.coach.weekTargetDays
            await state.saveSettings(["coach": ["week_target_days": original]])
            check("settings save and read back", changed != nil && changed != original && state.settings?.coach.weekTargetDays == original,
                  "original \(original), changed \(String(describing: changed)), now \(String(describing: state.settings?.coach.weekTargetDays)), error \(state.errorMessage ?? "none")")
            finish(); return
        }

        // 0. Nothing addressed to a manager anywhere in what the server says.
        for path in ["api/today", "api/recap", "api/prompts", "api/recent?limit=200", "api/settings"] {
            let text = (try? await URLSession.shared.data(from: api.url(path))).flatMap { String(data: $0.0, encoding: .utf8) } ?? ""
            let hits = ["Chien", "经理", "manager", "Manager"].filter { text.contains($0) }
            check("no manager copy in \(path)", !text.isEmpty && hits.isEmpty, hits.isEmpty ? "\(text.count) bytes" : hits.joined(separator: ", "))
        }
        await state.loadRecent()
        check("recent recordings carry a verdict", !state.recent.isEmpty && state.recent.allSatisfy { !$0.headline.isEmpty }, "\(state.recent.count) rows")

        // 0a. The real capture path, without a microphone: buffers in three formats, switched
        //     mid-recording the way AirPods or an iPhone microphone would, must all land in the file.
        let cap = captureCheck()
        check("capture keeps writing when the input format changes", cap.ok, cap.detail)

        // 0b. Each studio fills its own stage when you walk in, without starting.
        state.go(.topic)
        let topicReady = await waitFor(4) { stage.studio == .topic && stage.hasMaterial && stage.phase == .ready }
        check("主题 studio shows its material on arrival", topicReady, stage.title)
        state.go(.shadow)
        let shadowReady = await waitFor(6) { stage.studio == .shadow && stage.hasMaterial && stage.phase == .ready }
        check("跟读 studio shows its material on arrival", shadowReady, stage.title)
        state.go(.home)
        if let next = state.today?.nextItem {
            stage.presentNext()
            let moved = await waitFor(3) { state.space == Space.of(kind: next.kind) }
            check("starting from 今天 lands in that item's studio", moved, "\(next.kind) in \(state.space)")
            _ = await waitFor(6) { stage.phase == .countdown || stage.phase == .listening }
            stage.cancel()
            let back = await waitFor(2) { stage.phase == .ready }
            check("Esc steps back from the countdown", back, "\(stage.phase)")
        }

        // 0. Material is sorted by what it is: anything with someone else's recording under 跟读
        //    (daily clips and the ones brought in by hand), scripts without audio under 主题.
        let withAudio = state.practices.filter { $0.refDuration != nil }
        check("shelves: everything with original audio is under 跟读, none under 主题",
              state.userPractices.allSatisfy { $0.refDuration == nil } && withAudio.allSatisfy { p in state.shadowPractices.contains { $0.id == p.id } },
              "\(withAudio.count) with audio, \(state.importedClips.count) brought in by hand, \(state.userPractices.count) scripts and outlines")
        check("shelves: the test data has clips brought in by hand", !state.importedClips.isEmpty, "\(state.importedClips.map(\.title).prefix(2))")

        // 1. Every clip plays through the same player the stage uses.
        for item in today.items where item.practiceId != nil && (item.kind == "shadow" || item.kind == "retell") {
            let pm = PlayerModel()
            pm.load(api.url("api/practices/\(item.practiceId!)/reference/audio"))
            pm.play()
            let ok = await waitFor(8) { pm.time > 0.6 }
            check("clip audio plays: \(item.title.prefix(32))", ok, String(format: "reached %.2f s", pm.time))
            pm.stop()
        }

        // 1b. Listening is never a trap: the app stays usable, a paused clip stays on stage, a
        //     shadowing preview ends back at ready, and walking away stops the sound.
        if let shadowItem = state.today?.items.first(where: { $0.kind == "shadow" }) {
            stage.present(item: shadowItem, autoStart: false)
            _ = await waitFor(6) { stage.practice?.reference != nil && stage.phase == .ready }
            stage.listen()
            let playing = await waitFor(8) { stage.phase == .listening && stage.player.time > 0.3 }
            check("听原文 plays the clip and leaves the app usable", playing && !stage.isActive, "phase \(stage.phase), active \(stage.isActive)")
            stage.player.pause()
            try? await Task.sleep(for: .milliseconds(300))
            check("a paused clip stays on stage, ready to resume", stage.phase == .listening && !stage.player.playing)
            stage.player.toggle()
            stage.player.onFinish?()   // as if the clip reached its end
            check("a shadowing preview ends back at ready, not recording", stage.phase == .ready, "\(stage.phase)")
            stage.listen()
            _ = await waitFor(6) { stage.player.playing }
            state.go(.home)
            let stopped = await waitFor(3) { stage.phase == .ready && !stage.player.playing }
            check("leaving the studio stops the clip", stopped, "phase \(stage.phase), playing \(stage.player.playing)")
        }

        // 2. Retell: listen first, then speak.
        if let retell = today.items.first(where: { $0.kind == "retell" }) {
            stage.present(item: retell)
            let listening = await waitFor(10) { stage.phase == .listening && stage.player.time > 0.6 }
            check("retell: started from 今天, the original plays first", listening, String(format: "phase %@, %.2f s", "\(stage.phase)", stage.player.time))
            FrameProbe.begin()
            stage.toggle()   // stop listening, fill the clock
            let rec = await waitFor(10) { stage.phase == .recording }
            frames("countdown into recording", FrameProbe.end())
            check("retell: countdown opens recording", rec)
            await recordAndJudge("retell")
            check("retell: the verdict offers 再复述一遍", stage.againLabel == "再复述一遍", stage.againLabel)
            stage.again()
            let straight = await waitFor(8) { stage.phase == .countdown }
            check("retell: 再复述一遍 goes straight to your turn, without replaying the original", straight && !stage.player.playing,
                  "\(stage.phase), playing \(stage.player.playing)")
            stage.cancel()
            _ = await waitFor(2) { stage.phase == .ready }
        }

        // 3. Shadow: the reference plays while you speak.
        await state.refreshToday()
        if let shadow = state.today?.items.first(where: { $0.kind == "shadow" }) {
            stage.present(item: shadow)
            _ = await waitFor(8) { stage.phase == .countdown }
            FrameProbe.begin()
            let rec = await waitFor(12) { stage.phase == .recording }
            try? await Task.sleep(for: .milliseconds(700))
            frames("shadow countdown into recording", FrameProbe.end())
            check("shadow: countdown opens recording on its own", rec)
            if AudioRoute.isPrivate {
                let along = await waitFor(4) { stage.player.playing && stage.player.time > 0.5 }
                check("shadow: in headphones the original plays along", along && !stage.player.silenced, String(format: "%.2f s", stage.player.time))
            } else {
                // Out of speakers the original would be recorded with you: it does not play, and the
                // subtitles follow your voice (see --followprobe for how closely).
                let quiet = await holds(1.5) { !stage.player.playing || stage.player.silenced }
                check("shadow: on speakers the original is not heard and the subtitles follow your voice",
                      quiet && stage.followsVoice, "playing \(stage.player.playing), silenced \(stage.player.silenced), follows \(stage.followsVoice)")
            }
            await recordAndJudge("shadow")
        }

        // 4. Impromptu prompt.
        await state.refreshToday()
        if let imp = state.today?.items.first(where: { $0.kind == "impromptu" }) {
            let before = imp.promptId
            await state.shufflePrompt()
            let after = state.today?.items.first(where: { $0.kind == "impromptu" })?.promptId
            check("impromptu: 换一个题目 changes the prompt", before != after, "\(before ?? "") to \(after ?? "")")
            if let imp2 = state.today?.items.first(where: { $0.kind == "impromptu" }) {
                stage.present(item: imp2)
                let rec = await waitFor(12) { stage.phase == .recording }
                check("impromptu: countdown opens recording", rec)
                await recordAndJudge("impromptu")
            }
        } else {
            note("impromptu", "not in today's plan (a talk within ten days replaces it)")
        }

        // 4b. One press is one step: a repeated key must not skip the countdown or stop.
        if let imp = state.today?.items.first(where: { $0.kind == "impromptu" }) {
            stage.present(item: imp, autoStart: false)
            _ = await waitFor(4) { stage.hasMaterial && stage.phase == .ready && stage.item?.id == imp.id }
            try? await Task.sleep(for: .milliseconds(500))
            stage.start(); stage.start(); stage.start()
            try? await Task.sleep(for: .milliseconds(200))
            check("a held key starts once and does not skip ahead", stage.phase == .countdown, "\(stage.phase)")
            stage.cancel()
            _ = await waitFor(2) { stage.phase == .ready }

            // 4c. A slip of a second is not kept, and the stage says so.
            let newest: [RecentSession] = (try? await api.get("api/recent?limit=1")) ?? []
            stage.present(item: imp)
            _ = await waitFor(12) { stage.phase == .recording }
            try? await Task.sleep(for: .milliseconds(900))
            await stage.stopRecording()
            let after: [RecentSession] = (try? await api.get("api/recent?limit=1")) ?? []
            check("a recording under two seconds is not saved", stage.phase == .ready && after.first?.id == newest.first?.id && stage.notice != nil,
                  stage.notice ?? "no notice")
        }

        // 4d. The server refuses a recording with no speech in it, with a reason.
        let silence = FileManager.default.temporaryDirectory.appendingPathComponent("melete-silence.wav")
        if let f = try? CaptureSink.makeFile(at: silence), let b = AVAudioPCMBuffer(pcmFormat: CaptureSink.fileFormat, frameCapacity: 48_000) {
            b.frameLength = 48_000
            try? f.write(from: b)
        }
        do {
            let data = try Data(contentsOf: silence)
            let _: Session = try await api.upload("api/sessions", fields: ["language": "en", "title": "E2E silence"], fileField: "audio", filename: "silence.wav", data: data)
            check("a silent recording is refused", false, "it was saved")
        } catch {
            check("a silent recording is refused", error.localizedDescription.contains("没有听到"), error.localizedDescription)
        }

        // 5. The plan remembers what was done, and the week counts today.
        await state.refreshToday()
        if let t = state.today {
            let done = t.items.filter(\.done).count
            check("plan marks finished items", done >= 2, "\(done) of \(t.items.count) done")
            check("week counts today", t.week.todayDone, "\(t.week.done) of \(t.week.target) days")
        }

        // 6. A talk within ten days takes the impromptu slot.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let inTwo = f.string(from: Calendar.current.date(byAdding: .day, value: 2, to: Date())!)
        await state.createEvent(["title": "E2E review", "date": inTwo, "kind": "review", "minutes": 5, "notes": "Point one. Point two."])
        await state.refreshToday()
        let agendaItem = state.today?.items.first(where: { $0.kind == "agenda" })
        check("agenda: a talk in two days adds its prep step", agendaItem != nil, agendaItem?.title ?? "none")
        if let ev = state.agenda?.events.first(where: { $0.title == "E2E review" }) {
            await state.deleteEvent(ev.id)
            await state.refreshToday()
            check("agenda: deleting the talk restores the prompt", state.today?.items.contains(where: { $0.kind == "agenda" }) == false)
        }

        // 6b. Trays: a recording, 进展 and the full record from it, a practice and back, settings.
        await state.loadRecent()
        if let sid = state.recent.first?.id {
            await state.openTray(.session(sid))
            check("a recording opens in a tray", state.tray == .session(sid) && state.currentSession?.id == sid)
            state.closeTray()
        }
        await state.openTray(.progress)
        check("进展 opens with the week, the record and the year", state.tray == .progress && state.insights != nil && state.recap != nil && !state.recent.isEmpty,
              "insights \(state.insights != nil), recap \(state.recap != nil), \(state.recent.count) rows")
        await state.refreshToday()
        if let t = state.insights?.totals, let w = state.today?.week {
            // One rule for a day: the run of gold leaves up to yesterday (or today, once it counts)
            // is the streak, or the start of it when the run reaches back past Monday.
            var run = Array(w.days.prefix { $0.state != "future" })
            if run.last?.state == "today" { run.removeLast() }
            let tail = run.reversed().prefix { $0.state == "done" }.count
            check("进展: the streak counts days by the laurel's rule", tail == run.count ? t.currentStreak >= tail : t.currentStreak == tail,
                  "leaves in a row \(tail), streak \(t.currentStreak)")
            let weekMinutes = w.days.map(\.minutes).reduce(0, +)
            check("进展: one count of the week's minutes", abs(weekMinutes - t.thisWeekSec / 60) < 1,
                  String(format: "week %.1f min, insights %.1f min", weekMinutes, t.thisWeekSec / 60))
        }
        await state.openTray(.history)
        check("全部记录 lists every recording", state.tray == .history && !state.history.isEmpty, "\(state.history.count) rows")
        check("全部记录 opened from 进展 can step back", state.trayBack == .progress)
        await state.trayGoBack()
        check("返回 steps back to 进展", state.tray == .progress && state.trayBack == nil)
        state.closeTray()
        if let clip = state.clipPractices.first(where: { $0.sessionCount > 0 }) {
            await state.openTray(.practice(clip.id))
            check("a clip opens with its attempts", state.tray == .practice(clip.id) && state.practice?.id == clip.id && !state.sessions.isEmpty,
                  "\(state.sessions.count) attempts")
            if let s = state.sessions.last {
                await state.openTray(.session(s.id))
                check("a recording opened from its practice remembers it", state.trayBack == .practice(clip.id))
                await state.trayGoBack()
                check("返回 steps back to the practice", state.tray == .practice(clip.id) && state.trayBack == nil)
            }
        }
        await state.openTray(.agenda)
        await state.openTray(.newEvent)
        check("加一场 opened from the agenda can step back", state.trayBack == .agenda)
        await state.openTray(.agenda)   // what the form does once it has saved
        check("after saving, the agenda offers no 返回 to the spent form", state.tray == .agenda && state.trayBack == nil)
        // Deleting a recording from its own tray closes the tray and removes the row.
        await state.loadRecent()
        state.closeTray()
        if let victim = state.recent.first(where: { $0.title.hasPrefix("即兴") }) ?? state.recent.first {
            await state.openTray(.session(victim.id))
            await state.deleteSession()
            await state.loadRecent()
            check("deleting a recording closes its tray", state.tray == nil && !state.recent.contains(where: { $0.id == victim.id }),
                  "tray \(state.tray.map(\.id) ?? "closed")")
        }
        state.closeTray()   // closing with nothing open must stay harmless
        check("closing twice is harmless", state.tray == nil)

        await state.openTray(.settings)
        check("settings open as a tray", state.tray == .settings && state.settings != nil)
        state.closeTray()
        check("trays close", state.tray == nil && state.trayBack == nil)

        // 6c. Edge cases from real use, then a long random walk.
        if let api = state.api { await edgeCases(state: state, recorder: recorder, stage: stage, api: api) }

        // 7. Settings round trip.
        await state.loadSettings()
        let original = state.settings?.coach.weekTargetDays ?? 5
        await state.saveSettings(["coach": ["week_target_days": original == 4 ? 5 : 4]])
        let changed = state.settings?.coach.weekTargetDays
        await state.saveSettings(["coach": ["week_target_days": original]])
        check("settings save and read back", changed != nil && changed != original && state.settings?.coach.weekTargetDays == original,
              "original \(original), changed \(String(describing: changed)), now \(String(describing: state.settings?.coach.weekTargetDays)), error \(state.errorMessage ?? "none")")

        // 8. System hooks that can be checked without asking for permission.
        check("global shortcut registered", GlobalHotkey.shared.status == noErr, "OSStatus \(GlobalHotkey.shared.status)")
        Reminders.shared.schedule(at: "21:30")
        try? await Task.sleep(for: .milliseconds(300))
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let auth = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if pending.contains(where: { $0.identifier == "melete.daily" }) {
            check("daily reminder scheduled", true)
        } else {
            note("daily reminder", "not scheduled without permission (status \(auth.rawValue)); needs the system prompt once")
        }
        Reminders.shared.disable()
        finish()
    }

    /// Speak for three seconds (fake microphone), stop, and wait for the verdict.
    static func recordAndJudge(_ label: String) async {
        guard let s = stageRef else { return }
        StageModel.trace = []
        FrameProbe.begin()
        try? await Task.sleep(for: .seconds(3))
        let speaking = FrameProbe.end()
        frames("\(label) while speaking", speaking)
        if speaking.frames < 20, let st = stateRef {
            log("      space \(st.space), studio \(s.studio), phase \(s.phase), material \(s.hasMaterial), tray \(st.tray.map(\.id) ?? "none")")
            for line in StageModel.trace { log("      " + line) }
        }
        FrameProbe.begin()
        let pressed = Date()
        Task { await s.stopRecording() }
        let answered = await waitFor(1) { s.phase == .analyzing }
        let latency = Date().timeIntervalSince(pressed) * 1000
        check("\(label): stop answers at once", answered && latency < 150, String(format: "%.0f ms", latency))
        try? await Task.sleep(for: .milliseconds(1200))
        frames("\(label) stop transition", FrameProbe.end())
        let judged = await waitFor(120) { s.phase == .result }
        check("\(label): verdict arrives", judged && s.result?.review != nil, s.result?.review?.headline ?? "no review")
    }

    static weak var stageRef: StageModel?

    /// Writes three seconds of tone through a capture sink in three input formats and reads the
    /// file back: it must be three seconds long and not silent.
    static func captureCheck() -> (ok: Bool, detail: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("melete-captest.wav")
        try? FileManager.default.removeItem(at: url)
        var report: (seconds: Double, failures: Int, formats: [String]) = (0, 0, [])
        do {
            var sink: CaptureSink? = CaptureSink(file: try CaptureSink.makeFile(at: url), liveFormat: nil, continuation: nil, meter: LevelMeter())
            sink?.setOpen(true)
            for (rate, channels) in [(48_000.0, 2), (16_000.0, 1), (44_100.0, 1)] {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
                var done = 0
                while done < Int(rate) {
                    let n = min(1024, Int(rate) - done)
                    guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
                    b.frameLength = AVAudioFrameCount(n)
                    for c in 0..<channels {
                        for i in 0..<n { b.floatChannelData![c][i] = Float(0.3 * sin(2 * .pi * 220 * Double(done + i) / rate)) }
                    }
                    sink?.handle(b)
                    done += n
                }
            }
            sink?.setOpen(false)
            report = sink?.report ?? report
            sink = nil   // closes the file
            let f = try AVAudioFile(forReading: url)
            let seconds = Double(f.length) / f.fileFormat.sampleRate
            guard let back = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return (false, "cannot read back") }
            try f.read(into: back)
            let level = CaptureSink.rms(back)
            let ok = abs(seconds - 3) < 0.1 && level > 0.1 && report.failures == 0 && f.fileFormat.channelCount == 1
            return (ok, String(format: "%.2f s in the file, level %.2f, %d failures, formats %@", seconds, level, report.failures, report.formats.joined(separator: ", ")))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    static func finish() {
        log(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
