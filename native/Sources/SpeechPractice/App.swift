import SwiftUI
import AppKit

/// System hooks that must wait until AppKit has finished launching, and quitting, which must
/// work whether or not a window is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    weak var stage: StageModel?
    /// Set once quitting has begun, so closing windows does not race the save in
    /// `applicationWillTerminate`.
    nonisolated(unsafe) static var quitting = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.quitting = true
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Reminders.shared.setup()
            if UserDefaults.standard.object(forKey: "globalHotkey") as? Bool ?? true { GlobalHotkey.shared.register() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            stage?.saveForQuit()
            state?.activity.saveBacklog()
            state?.server.stop()
        }
    }
}

@main
struct SpeechPracticeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()
    @State private var recorder = Recorder()
    @State private var stage = StageModel()
    @AppStorage("menuBarExtra") private var showMenuBar = true
    @AppStorage("globalHotkey") private var hotkey = true

    init() {
        if CommandLine.arguments.contains("--selftest") { SpeechPracticeApp.selftest() }
        // `--lang en|zh` shows one language for this run without changing the setting.
        if let i = CommandLine.arguments.firstIndex(of: "--lang"), CommandLine.arguments.count > i + 1,
           let lang = AppLanguage(rawValue: CommandLine.arguments[i + 1]) {
            LanguageSetting.shared.current = lang
        } else {
            // AppKit's own menus follow the chosen language (read at launch).
            LanguageSetting.syncSystemMenus(LanguageSetting.shared.current)
        }
    }

    /// `SpeechPractice --selftest` decodes every endpoint against SPEECH_SERVER_URL and exits.
    static func selftest() {
        let url = URL(string: ProcessInfo.processInfo.environment["SPEECH_SERVER_URL"] ?? "http://127.0.0.1:8765")!
        let api = API(base: url)
        let done = DispatchSemaphore(value: 0)
        Task.detached {   // detached: the App initializer is main-actor bound and we block it below
            do {
                let c = try await api.config(); print("config ok:", c.models)
                let p = try await api.practices(); print("practices ok:", p.count, "clips:", p.filter(\.isClip).count)
                let s = try await api.sessions(filter: "all"); print("sessions ok:", s.count)
                for item in p {
                    let pr = try await api.practice(item.id)
                    print("practice ok:", pr.title, "sessions", pr.sessions.count, "reference sentences", pr.reference?.sentences.count ?? -1, "kind", pr.kind ?? "user")
                }
                for sid in s.suffix(20).map(\.id) {
                    let se = try await api.session(sid)
                    print("session ok:", se.id, "wpm", se.metrics.wpm, "review", se.review?.headline ?? "none")
                }
                let ins: Insights = try await api.get("api/insights?days=30"); print("insights ok:", ins.days.count, "days,", ins.practices.count, "practices")
                let t = try await api.today(); print("today ok:", t.block.name, "items", t.items.map(\.kind), "daily", t.daily.state, "week", t.week.done)
                let st = try await api.settings(); print("settings ok:", st.daily.notifyTime, st.blocks.count, "blocks")
                let d = try await api.daily(); print("daily ok:", d.days.count, "days", d.status.state)
                let a = try await api.agenda(); print("agenda ok:", a.events.count, "events", a.templates.count, "templates")
                let r = try await api.recap(offset: 0); print("recap ok:", r.practiced, "of", r.target, "days")
                let src = try await api.sources(); print("sources ok:", src.count)
            } catch { print("SELFTEST FAILED:", error) }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// Draws the main window, toolbar included, into a PNG and quits.
    static func snapshot(to path: String, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let wins = NSApp.windows.filter { $0.isVisible && $0.frame.width > 400 }
            guard let win = wins.first, let view = win.contentView?.superview ?? win.contentView else { exit(2) }
            let rect = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { exit(3) }
            view.cacheDisplay(in: rect, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Melete", id: "main") {
            RootView()
                .environment(state)
                .environment(recorder)
                .environment(stage)
                .frame(minWidth: 1040, minHeight: 700)
                .task {
                    stage.attach(state: state, recorder: recorder)
                    AppState.shared = state
                    delegate.state = state
                    delegate.stage = stage
                    // Its own task: closing the window must not cancel booting (or a test run)
                    // halfway, which a window's .task would.
                    Task { @MainActor in await launch() }
                }
        }
        .defaultSize(width: 1200, height: 840)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("设置…", "Settings…")) { NotificationCenter.default.post(name: .openSettings, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // One window: its places are spaces and trays, so ⌘N makes a script, not a window.
            CommandGroup(replacing: .newItem) {
                Button(recorder.isRecording ? L("停止录音", "Stop Recording") : L("开始练习", "Start Practice")) {
                    NotificationCenter.default.post(name: .toggleRecording, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                Button(L("新讲稿…", "New Script…")) { NotificationCenter.default.post(name: .newPractice, object: nil) }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu(L("前往", "Go")) {
                ForEach(Array(Space.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.label) { state.closeTray(); state.go(s) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                        .disabled(stage.isActive)
                }
                Divider()
                Button(L("全部记录", "All Takes")) { Task { await state.openTray(.history) } }
                    .keyboardShortcut("4", modifiers: .command)
                    .disabled(stage.isActive)
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent()
                .environment(state)
                .environment(stage)
        } label: {
            Image(systemName: "laurel.leading")
        }
        .menuBarExtraStyle(.window)
    }

    /// Starts the analysis service and today's data, or one of the test harnesses (once per
    /// process, however many times the window is opened).
    @MainActor private func launch() async {
        let harnesses = ["--render", "--freezeprobe", "--listenprobe", "--shadowprobe", "--followprobe", "--clickprobe", "--pointerprobe", "--perf", "--e2e"]
        if harnesses.contains(where: CommandLine.arguments.contains) {
            // The checks compare against the Chinese labels; `--lang en` renders the English ones.
            if !CommandLine.arguments.contains("--lang") { LanguageSetting.shared.current = .zh }
            guard !E2E.started else { return }
            E2E.started = true
            E2E.stageRef = stage
            if CommandLine.arguments.contains("--render") { await RenderHarness.run(state: state, recorder: recorder, stage: stage) }
            else if CommandLine.arguments.contains("--freezeprobe") { await E2E.freezeProbe(state: state, recorder: recorder, stage: stage) }
            else if CommandLine.arguments.contains("--listenprobe") { await E2E.listenProbe(state: state, recorder: recorder, stage: stage) }
            else if CommandLine.arguments.contains("--shadowprobe") { await E2E.shadowProbe(state: state, recorder: recorder, stage: stage) }
            else if CommandLine.arguments.contains("--followprobe") { await E2E.followProbe(state: state, recorder: recorder, stage: stage) }
            else if CommandLine.arguments.contains("--clickprobe") { await E2E.clickProbe(state: state, recorder: recorder, stage: stage) }
            else if CommandLine.arguments.contains("--pointerprobe") { await E2E.pointerProbe(state: state, recorder: recorder, stage: stage) }
            else if CommandLine.arguments.contains("--perf") { await E2E.perf(state: state, recorder: recorder, stage: stage) }
            else { await E2E.run(state: state, recorder: recorder, stage: stage) }
            return
        }
        await state.boot()
        await restoreReminder()
        // `--snapshot <png>` draws the real window and quits.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
            let delay = Double(ProcessInfo.processInfo.environment["SNAPSHOT_DELAY"] ?? "") ?? 3
            SpeechPracticeApp.snapshot(to: CommandLine.arguments[i + 1], after: delay)
        }
    }

    /// Re-arms the daily reminder on launch if it was turned on before.
    private func restoreReminder() async {
        guard UserDefaults.standard.bool(forKey: "remindersOn") else { return }
        if state.settings == nil { await state.loadSettings() }
        Reminders.shared.schedule(at: state.settings?.daily.notifyTime ?? "21:30")
    }
}
