import Foundation
import SwiftUI

/// Which recordings `sessions` holds: everything, the ungrouped ones, or one practice.
enum HistoryScope: Hashable {
    case all, ungrouped, practice(String)

    var filter: String {
        switch self {
        case .all: return "all"
        case .ungrouped: return "none"
        case .practice(let id): return id
        }
    }
}

/// The three places in the app. Practice happens in the two studios; the overview is where
/// history, progress and rhythm live.
enum Space: String, CaseIterable, Identifiable {
    case home, shadow, topic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: return L("总览", "Overview")
        case .shadow: return L("跟读", "Shadowing")
        case .topic: return L("主题", "Topics")
        }
    }
    /// The Greek word each space is named after, shown when a studio is empty.
    var greek: String {
        switch self {
        case .home: return "Σύνοψις"
        case .shadow: return "Μίμησις"
        case .topic: return "Θέμα"
        }
    }
    static func of(kind: String) -> Space { kind == "shadow" || kind == "retell" ? .shadow : .topic }
}

/// Panels that rise over the current space instead of navigating away from it.
enum Tray: Identifiable, Equatable {
    case settings, session(String), practice(String), newTopic, newEvent, addLink, history, clips, agenda
    var id: String {
        switch self {
        case .settings: return "settings"
        case .clips: return "clips"
        case .agenda: return "agenda"
        case .session(let s): return "session-\(s)"
        case .practice(let p): return "practice-\(p)"
        case .newTopic: return "newTopic"
        case .newEvent: return "newEvent"
        case .addLink: return "addLink"
        case .history: return "history"
        }
    }

    var isForm: Bool {
        switch self {
        case .newTopic, .newEvent, .addLink: return true
        default: return false
        }
    }
}

/// A recording made before the analysis service was ready. It is analysed as soon as it is.
struct PendingUpload: Codable, Hashable {
    let path: String
    let language: String
    let title: String
    let scenario: String
    let practiceId: String?
    let drill: Drill?
}

/// Everything the views read. One instance for the app.
@Observable
@MainActor
final class AppState {
    let server = ServerManager()
    let activity = ActivityTracker()
    var config: ServerConfig?
    var insights: Insights?

    var practices: [PracticeListItem] = []
    var allSessions: [SessionSummary] = []
    var scope: HistoryScope = .all
    var practice: Practice?              // loaded when a practice tray is open
    var sessions: [SessionSummary] = []   // history for the current view
    var currentSession: Session?
    var errorMessage: String?
    var busy = false

    // coaching
    var today: TodayPayload?
    var settings: SettingsPayload?
    var daily: DailyPayload?
    var agenda: AgendaPayload?
    var recap: Recap?
    var recapOffset = 0
    var pending: [PendingUpload] = []

    var space: Space = .home
    /// The studio the studio view shows: the last of 跟读 and 主题 you were in. It stays mounted
    /// behind the overview, so walking between places never tears a view down.
    var studio: Space = .shadow
    var tray: Tray?
    /// Bumped to rebuild the tray layer from scratch; see `closeTray`.
    var trayEpoch = 0
    /// The tray to return to when one tray opened another (a practice opening one of its recordings).
    var trayBack: Tray?
    var recent: [RecentSession] = []
    /// Every recording with its verdict, for the full history tray.
    var history: [RecentSession] = []

    /// The stage, so leaving a studio can stop what it is playing.
    weak var stage: StageModel?
    /// The one instance, for system callbacks (global shortcut, notifications) that live
    /// outside SwiftUI.
    static weak var shared: AppState?
    /// Opens the main window; captured from SwiftUI so it can be called when no window is open.
    var openMain: (() -> Void)?
    /// A start asked for while no window was open; the window takes it when it appears.
    var pendingStart = false

    var api: API? { server.api }
    var isReady: Bool { server.status == .ready }
    var ungroupedCount: Int { allSessions.filter { $0.practiceId == nil }.count }
    /// Sorting is by what the material is, not who made it: anything with someone else's
    /// recording belongs to 跟读 (the daily clips and the ones brought in by hand, like the
    /// Paul Graham and Jensen Huang clips from the first version); your own scripts and
    /// outlines, with no original audio, belong to 主题.
    var shadowPractices: [PracticeListItem] { practices.filter { $0.isClip || $0.refDuration != nil } }
    var userPractices: [PracticeListItem] { practices.filter { !$0.isClip && $0.refDuration == nil } }
    var clipPractices: [PracticeListItem] { practices.filter(\.isClip) }
    /// Clips brought in by hand rather than picked each morning.
    var importedClips: [PracticeListItem] { practices.filter { !$0.isClip && $0.refDuration != nil } }

    private static let pendingKey = "pendingUploads"

    private var booted = false

    func boot() async {
        // One server per app, even with several windows; retry only after a failure.
        if booted, case .failed = server.status {} else if booted { return }
        booted = true
        pending = (UserDefaults.standard.data(forKey: AppState.pendingKey)).flatMap { try? JSONDecoder().decode([PendingUpload].self, from: $0) } ?? []
        await server.start()
        guard server.status == .ready else { return }
        activity.api = api
        activity.restoreBacklog()
        await refreshAll()
        await refreshToday()
        await loadRecent()
        await loadInsights()
        await loadRecap()
        // `--space home|shadow|topic` and `--tray settings|history|clips|agenda|newTopic|newEvent|addLink`
        // open a place directly (used for testing and design review).
        if let i = CommandLine.arguments.firstIndex(of: "--space"), CommandLine.arguments.count > i + 1,
           let sp = Space(rawValue: CommandLine.arguments[i + 1]) { go(sp) }
        if let i = CommandLine.arguments.firstIndex(of: "--tray"), CommandLine.arguments.count > i + 1 {
            let named: [String: Tray] = ["settings": .settings, "history": .history, "clips": .clips, "agenda": .agenda,
                                         "newTopic": .newTopic, "newEvent": .newEvent, "addLink": .addLink]
            if let t = named[CommandLine.arguments[i + 1]] { await openTray(t) }
        }
        await flushPending()
        pollConfig()
        pollDaily()
    }

    private func pollConfig() {
        Task {
            while true {
                if let api { config = try? await api.config() }
                if config?.models.values.contains(true) == true { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// While clips are being prepared, keep Today's status line current.
    private func pollDaily() {
        Task {
            while true {
                try? await Task.sleep(for: .seconds(8))
                guard let state = today?.daily.state else { continue }
                if state == "running" || state == "waiting" { await refreshToday(quiet: true) }
            }
        }
    }

    func refreshAll() async {
        guard let api else { return }
        do {
            async let p = api.practices()
            async let s = api.sessions(filter: "all")
            practices = try await p
            allSessions = try await s
        } catch { report(error) }
    }

    func refreshToday(quiet: Bool = false) async {
        guard let api else { return }
        do {
            let t = try await api.today()
            if quiet, let old = today, old.daily.state != t.daily.state, t.daily.state == "ready" { await refreshAll() }
            today = t
        } catch { if !quiet { report(error) } }
    }

    func loadRecent() async {
        guard let api else { return }
        do { recent = try await api.get("api/recent?limit=12") } catch { report(error) }
    }

    func go(_ s: Space) {
        // Walking away from a clip that is playing stops it. Decided here, not when the studio
        // leaves the screen, so it holds even while the window is not being drawn.
        if let stage, stage.phase == .listening, stage.studio != s { stage.cancel() }
        // Plain assignments; the views animate (see StageModel.phase).
        if s != .home { studio = s }
        space = s
    }

    /// Opens a tray over the current space. A tray opened from another tray remembers it,
    /// so its header can step back.
    func openTray(_ t: Tray) async {
        // Nothing rises over a take that is counting down or recording.
        if let stage, stage.isActive { return }
        switch t {
        case .session(let id): await open(sessionID: id)
        case .practice(let id): await loadPractice(id)
        case .history: await reloadAllHistory()
        case .newEvent, .agenda: await loadAgenda()
        case .clips: await loadDaily()
        case .settings: if settings == nil { await loadSettings() }
        default: break
        }
        // A finished form is never somewhere to go back to.
        if let current = tray, current != t, !current.isForm { trayBack = current } else { trayBack = nil }
        tray = t
    }

    func closeTray() {
        // Closing when nothing is open means a tray is still drawn after it was dismissed;
        // rebuilding the layer clears it, so the close button can never be a dead end.
        if tray == nil { trayEpoch += 1 }
        tray = nil
        trayBack = nil
    }

    /// Back to the tray this one was opened from.
    func trayGoBack() async {
        guard let back = trayBack else { closeTray(); return }
        trayBack = nil
        switch back {
        case .practice(let id): await loadPractice(id)
        case .history: await reloadAllHistory()
        default: break
        }
        tray = back
    }

    func loadPractice(_ id: String) async {
        guard let api else { return }
        scope = .practice(id)
        currentSession = nil
        do {
            practice = try await api.practice(id)
            sessions = try await api.sessions(filter: id)
        } catch { report(error) }
    }

    func reloadAllHistory() async {
        guard let api else { return }
        scope = .all
        do {
            sessions = try await api.sessions(filter: "all")
            history = try await api.get("api/recent?limit=1000")
        } catch { report(error) }
    }

    func loadInsights() async {
        guard let api else { return }
        activity.flush()
        try? await Task.sleep(for: .milliseconds(150))
        do { insights = try await api.get("api/insights?days=371") } catch { report(error) }
    }

    func loadRecap() async {
        guard let api else { return }
        do { recap = try await api.recap(offset: recapOffset) } catch { report(error) }
    }

    func loadDaily() async {
        guard let api else { return }
        do { daily = try await api.daily() } catch { report(error) }
    }

    func loadAgenda() async {
        guard let api else { return }
        do { agenda = try await api.agenda() } catch { report(error) }
    }

    func loadSettings() async {
        guard let api else { return }
        do { settings = try await api.settings() } catch { report(error) }
    }

    func saveSettings(_ patch: [String: Any]) async {
        guard let api else { return }
        do {
            let body = try JSONSerialization.data(withJSONObject: patch)
            var req = URLRequest(url: api.url("api/settings"))
            req.httpMethod = "PUT"; req.httpBody = body
            API.stamp(&req)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, _) = try await URLSession.shared.data(for: req)
            settings = try API.decoder.decode(SettingsPayload.self, from: data)
            await refreshToday(quiet: true)
        } catch { report(error) }
    }

    /// The interface language changed: everything the server wrote (the plan, verdicts, the
    /// recap, training blocks) is fetched again in the new language, and an idle stage takes
    /// its material again so its labels follow.
    func languageChanged() async {
        // Notification buttons and texts are fixed when registered, so register them again in the new language.
        Reminders.shared.setup()
        let remindersOn = UserDefaults.standard.bool(forKey: "remindersOn")
        guard api != nil else { return }
        await refreshToday(quiet: true)
        await loadRecent()
        await loadRecap()
        await loadSettings()
        if remindersOn { Reminders.shared.schedule(at: settings?.daily.notifyTime ?? "21:30") }
        if agenda != nil { await loadAgenda() }
        if daily != nil { await loadDaily() }
        if !history.isEmpty, let api, let h: [RecentSession] = try? await api.get("api/recent?limit=1000") { history = h }
        if let s = currentSession { await open(sessionID: s.id) }
        stage?.relabel()
    }

    func reloadPractice() async {
        guard let api, case .practice(let id) = scope else { return }
        do {
            practice = try await api.practice(id)
            sessions = try await api.sessions(filter: id)
        } catch { report(error) }
    }

    func reloadHistory() async {
        guard let api else { return }
        do { sessions = try await api.sessions(filter: scope.filter) } catch { report(error) }
    }

    func open(sessionID: String) async {
        guard let api else { return }
        do { currentSession = try await api.session(sessionID) } catch { report(error) }
    }

    func fetchPractice(_ id: String) async -> Practice? {
        guard let api else { return nil }
        return try? await api.practice(id)
    }

    func practiceTitle(_ id: String?) -> String {
        guard let id else { return "" }
        return practices.first { $0.id == id }?.title ?? ""
    }

    // ---- plan actions
    func shufflePrompt() async {
        guard let api else { return }
        do { let t = try await api.shuffle(); today = t } catch { report(error) }
    }

    func commitWeek() async {
        guard let api else { return }
        do { let t = try await api.commitWeek(); today = t } catch { report(error) }
    }

    func refreshClips(force: Bool) async {
        guard let api else { return }
        do {
            let _: Data = try await rawSend("POST", "api/daily/refresh", ["force": force])
            try? await Task.sleep(for: .milliseconds(400))
            await refreshToday(quiet: true)
            await loadDaily()
            _ = api
        } catch { report(error) }
    }

    func addClip(url: String, role: String) async {
        do {
            let _: Data = try await rawSend("POST", "api/daily/add", ["url": url, "role": role])
            try? await Task.sleep(for: .milliseconds(400))
            await refreshToday(quiet: true)
        } catch { report(error) }
    }

    func createEvent(_ body: [String: Any]) async {
        guard let api else { return }
        do {
            let data: Data = try await rawSend("POST", "api/agenda", body)
            agenda = try API.decoder.decode(AgendaPayload.self, from: data)
            await refreshAll()
            await refreshToday(quiet: true)
            _ = api
        } catch { report(error) }
    }

    func updateEvent(_ id: String, _ body: [String: Any]) async {
        do {
            let data: Data = try await rawSend("PATCH", "api/agenda/\(id)", body)
            agenda = try API.decoder.decode(AgendaPayload.self, from: data)
            await refreshToday(quiet: true)
        } catch { report(error) }
    }

    func deleteEvent(_ id: String) async {
        do {
            let data: Data = try await rawSend("DELETE", "api/agenda/\(id)", nil)
            agenda = try API.decoder.decode(AgendaPayload.self, from: data)
            await refreshToday(quiet: true)
        } catch { report(error) }
    }

    func saveSources(_ items: [SourceItem]) async {
        guard let api else { return }
        do {
            let enc = JSONEncoder(); enc.keyEncodingStrategy = .convertToSnakeCase
            var req = URLRequest(url: api.url("api/sources"))
            req.httpMethod = "PUT"; req.httpBody = try enc.encode(items)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try await URLSession.shared.data(for: req)
        } catch { report(error) }
    }

    private func rawSend(_ method: String, _ path: String, _ json: [String: Any]?) async throws -> Data {
        guard let api else { throw APIError(message: L("分析服务还没启动", "The analysis service hasn't started yet")) }
        var req = URLRequest(url: api.url(path))
        req.httpMethod = method
        API.stamp(&req)
        req.timeoutInterval = 600
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw APIError(message: detail ?? "HTTP \(code)")
        }
        return data
    }

    // ---- mutations
    func createPractice(title: String, scenario: String, script: String) async -> String? {
        guard let api else { return nil }
        do {
            let p: Practice = try await api.send("POST", "api/practices", json: ["title": title, "scenario": scenario, "script": script])
            await refreshAll()
            return p.id
        } catch { report(error); return nil }
    }

    func savePractice(title: String, scenario: String, script: String, notes: String) async {
        guard let api, let p = practice else { return }
        do {
            practice = try await api.send("PATCH", "api/practices/\(p.id)", json: ["title": title, "scenario": scenario, "script": script, "notes": notes])
            await refreshAll()
            await reloadHistory()
            if let cur = currentSession { currentSession = try await api.session(cur.id) }
        } catch { report(error) }
    }

    func deletePractice() async {
        guard let api, let p = practice else { return }
        do {
            try await api.delete("api/practices/\(p.id)")
            // Leave first, with the page intact; clearing it under a closing tray can strand it.
            closeTray()
            await refreshAll()
            await refreshToday(quiet: true)
            stage?.practiceRemoved(p.id)
        } catch { report(error) }
    }

    func saveSession(title: String, notes: String, rating: Int?, practiceId: String?) async {
        guard let api, let s = currentSession else { return }
        do {
            currentSession = try await api.send("PATCH", "api/sessions/\(s.id)", json: ["title": title, "notes": notes, "self_rating": rating, "practice_id": practiceId])
            await refreshAll()
            if practiceId != s.practiceId, case .practice = scope { await reloadPractice() } else { await reloadHistory() }
            await loadRecent()
        } catch { report(error) }
    }

    func reanalyzeSession(language: String) async {
        guard let api, let s = currentSession else { return }
        busy = true; defer { busy = false }
        do {
            currentSession = try await api.send("POST", "api/sessions/\(s.id)/reanalyze", json: ["language": language])
            await reloadHistory()
        } catch { report(error) }
    }

    /// The listening notes arrive a little after the local analysis; ask until they have.
    /// nil when listening is off, still running after four minutes, or the task was cancelled.
    func awaitListen(_ id: String) async -> ListenNotes? {
        guard let api else { return nil }
        for _ in 0..<80 {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return nil }
            do {
                let notes: ListenNotes? = try await api.get("api/sessions/\(id)/listen")
                guard let notes else { return nil }
                if !notes.isPending { return notes }
            } catch {
                continue
            }
        }
        return nil
    }

    /// Keeps the open recording's listening notes current while the model is listening.
    func followListen(_ id: String) async {
        guard currentSession?.id == id, currentSession?.listen?.isPending == true else { return }
        if let notes = await awaitListen(id), currentSession?.id == id { currentSession?.listen = notes }
    }

    /// Asks the model to listen to a recording again (after an error, or with another model).
    func relisten(_ id: String) async {
        guard let api else { return }
        do {
            let notes: ListenNotes? = try await api.send("POST", "api/sessions/\(id)/listen")
            if currentSession?.id == id { currentSession?.listen = notes }   // the detail view follows it from here
        } catch { report(error) }
    }

    func deleteSession() async {
        guard let api, let s = currentSession else { return }
        do {
            try await api.delete("api/sessions/\(s.id)")
            // Step away first, with the page intact; clearing it under a closing tray can strand it.
            if case .session = tray { if trayBack != nil { await trayGoBack() } else { closeTray() } }
            stage?.sessionRemoved(s.id)
            await refreshAll()
            if case .practice = scope { await reloadPractice() } else { await reloadHistory() }
            await refreshToday(quiet: true)
            await loadRecent()
        } catch { report(error) }
    }

    /// Sends a finished recording for analysis. If the service is still starting, the file is
    /// kept and analysed later; nothing you said is lost. Returns nil in that case.
    /// `onError` takes the server's message instead of the alert (the stage shows it in place).
    func submit(fileURL: URL, language: String, title: String, scenario: String, practiceId: String?, drill: Drill?,
                onError: ((String) -> Void)? = nil) async -> Session? {
        guard let api, isReady else {
            let keep = keepRecording(fileURL)
            pending.append(PendingUpload(path: keep.path, language: language, title: title, scenario: scenario, practiceId: practiceId, drill: drill))
            savePending()
            return nil
        }
        busy = true; defer { busy = false }
        do {
            let data = try await Task.detached { try Data(contentsOf: fileURL) }.value   // off the main thread
            var fields = ["language": language, "title": title, "scenario": scenario, "practice_id": practiceId ?? ""]
            if let drill, let d = try? JSONEncoder.snake.encode(drill) { fields["drill"] = String(data: d, encoding: .utf8) }
            let s: Session = try await api.upload("api/sessions", fields: fields, fileField: "audio", filename: fileURL.lastPathComponent, data: data)
            try? FileManager.default.removeItem(at: fileURL)
            await refreshAll()
            await refreshToday(quiet: true)
            await loadRecent()
            if !pending.isEmpty { Task { await flushPending() } }   // the service works again
            return s
        } catch {
            // The server refusing a recording on its merits (no speech in it) is final. Anything
            // else (the service went away, a timeout, a crash in analysis) is not the recording's
            // fault, so it is kept and tried again.
            let final = (error as? APIError)?.status == 422
            var message = error.localizedDescription
            if final {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                keepForLater(fileURL, language: language, title: title, scenario: scenario, practiceId: practiceId, drill: drill)
                message = L("这一段没分析成功（\(message)）。录音已经存好，分析服务恢复后会自动补上。",
                            "This take couldn't be analyzed (\(message)). The recording is saved and will be analyzed once the service is back.")
            }
            if let onError { onError(message) } else { errorMessage = message }
            return nil
        }
    }

    /// Legacy path used by the practice page recorder.
    func uploadRecording(fileURL: URL, language: String, title: String, scenario: String) async {
        if let s = await submit(fileURL: fileURL, language: language, title: title, scenario: scenario, practiceId: practice?.id, drill: nil) {
            currentSession = s
        }
    }

    private func keepRecording(_ url: URL) -> URL {
        // The installed app keeps its pending recordings beside its data; a test build keeps its
        // own, so tests never write into the real folder.
        let id = Bundle.main.bundleIdentifier ?? "Melete"
        let folder = id == "com.zhengyangxu.speechpractice" ? "SpeechPractice" : id
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(folder)/pending")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    private func savePending() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: AppState.pendingKey)
    }

    func flushPending() async {
        guard isReady, !pending.isEmpty else { return }
        let items = pending
        pending = []
        savePending()
        for p in items {
            let url = URL(fileURLWithPath: p.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            _ = await submit(fileURL: url, language: p.language, title: p.title, scenario: p.scenario, practiceId: p.practiceId, drill: p.drill)
        }
    }

    func uploadReference(fileURL: URL, transcript: String, language: String) async {
        guard let api, let p = practice else { return }
        busy = true; defer { busy = false }
        do {
            let data = try Data(contentsOf: fileURL)
            practice = try await api.upload("api/practices/\(p.id)/reference", fields: ["transcript": transcript, "language": language], fileField: "audio", filename: fileURL.lastPathComponent, data: data)
            await refreshAll()
            await reloadHistory()
        } catch { report(error) }
    }

    func retimeReference(transcript: String) async {
        guard let api, let p = practice else { return }
        do { practice = try await api.send("PUT", "api/practices/\(p.id)/reference/transcript", json: ["transcript": transcript]) } catch { report(error) }
    }

    func deleteReference() async {
        guard let api, let p = practice else { return }
        do {
            let _: Data = try await withCheckedThrowingContinuation { cont in
                Task { do { try await api.delete("api/practices/\(p.id)/reference"); cont.resume(returning: Data()) } catch { cont.resume(throwing: error) } }
            }
            await reloadPractice()
        } catch { report(error) }
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    /// The global shortcut, the menu bar and a reminder all mean the same thing: open Melete
    /// and start today's next item. With no window open, the window is opened first and picks
    /// the request up when it appears.
    func requestStart() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.windows.contains(where: { $0.isVisible && $0.frame.width > 400 }) {
            NotificationCenter.default.post(name: .startToday, object: nil)
        } else {
            pendingStart = true
            openMain?()
        }
    }

    /// A recording that could not be analysed now is kept and tried again later.
    func keepForLater(_ url: URL, language: String, title: String, scenario: String, practiceId: String?, drill: Drill?) {
        let keep = keepRecording(url)
        pending.append(PendingUpload(path: keep.path, language: language, title: title, scenario: scenario, practiceId: practiceId, drill: drill))
        savePending()
    }
}

extension JSONEncoder {
    static let snake: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}
