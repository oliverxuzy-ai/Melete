import AppKit
import CryptoKit
import Darwin
import Foundation

// Updates come from the project's GitHub releases. Each release carries latest.json
// (.github/scripts/update-manifest.sh): the version, the zip's address and its SHA-256.
// Melete reads it at launch and every 12 hours, offers a newer version at the top of the
// window, and when asked downloads the zip, checks it, unpacks it next to the caches and swaps
// it with the running copy in one step. The swap happens as the app quits; macOS keeps the
// running copy's files open, so nothing breaks underneath it.
//
// The app is ad-hoc signed and not notarized. A file the app downloads itself carries no
// quarantine flag, so Gatekeeper does not stop the new copy, and the App Management guard
// only covers notarized apps, so replacing this copy in /Applications needs no permission.

// MARK: - Versions

enum AppVersion {
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    /// True when `a` is a strictly higher version than `b`: "2.10.0" is newer than "2.9.3".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}

// MARK: - The feed

/// latest.json, as CI writes it.
struct UpdateManifest: Codable, Equatable {
    let version: String
    var build: String?
    let url: URL
    let sha256: String
    var size: Int64?
    var minimumSystemVersion: String?
    var releaseURL: URL?
    var notes: [String]?

    /// The commit subjects, without their "feat:" or "fix(scope):" prefixes.
    var cleanNotes: [String] {
        (notes ?? []).compactMap { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            if let r = s.range(of: #"^[A-Za-z]+(\([^)]*\))?!?:\s*"#, options: .regularExpression) { s.removeSubrange(r) }
            guard let first = s.first else { return nil }
            return first.uppercased() + s.dropFirst()
        }
    }

    /// This Mac's macOS is recent enough for the new version.
    var runsHere: Bool {
        guard let min = minimumSystemVersion else { return true }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return !AppVersion.isNewer(min, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}

enum UpdateError: LocalizedError {
    case http(Int), insecure, checksum, unpack, notMelete, replace(String)

    var errorDescription: String? {
        switch self {
        case .http(404): return L("GitHub 上还没有更新信息。", "GitHub has no update information yet.")
        case .http(let code): return L("GitHub 返回了 \(code)。", "GitHub answered \(code).")
        case .insecure: return L("更新地址不是 https，没有下载。", "The update address isn't https, so nothing was downloaded.")
        case .checksum: return L("下载的文件和发布时的校验和对不上，已经删掉。", "The download doesn't match the published checksum and was deleted.")
        case .unpack: return L("解压失败。", "Couldn't unpack the download.")
        case .notMelete: return L("下载里不是这个版本的 Melete。", "The download doesn't hold the expected version of Melete.")
        case .replace(let why): return L("替换旧版本失败：\(why)", "Couldn't replace the old version: \(why)")
        }
    }
}

// MARK: - The steps

/// Each step of an update, free of the interface, so the CI probe runs the same code.
enum UpdateEngine {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.zhengyangxu.speechpractice" }

    /// ~/Library/Caches/<bundle id>/Updates: the download, the unpacked app, and after a swap
    /// the old copy, which the next launch deletes.
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    /// Left in `folder` by a swap, so the new version can say it was just installed.
    private static var marker: URL { folder.appendingPathComponent("installed.json") }

    /// This user may change `url` (the folder holding the app, or the app itself).
    /// Here rather than in Updater, where @Observable's own `access` would hide the C call.
    static func canWrite(_ url: URL) -> Bool { access(url.path, W_OK) == 0 }

    /// https only, except a feed on this Mac (the CI probe serves one on 127.0.0.1).
    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost"))
    }

    static func fetchManifest(_ feed: URL) async throws -> UpdateManifest {
        guard allowed(feed) else { throw UpdateError.insecure }
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Melete/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.http(http.statusCode) }
        return try JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    /// Downloads the zip into `folder`. `progress` gets 0...1, at most every half percent.
    static func download(_ m: UpdateManifest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard allowed(m.url) else { throw UpdateError.insecure }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("Melete-\(m.version).zip")
        try? fm.removeItem(at: dest)
        let delegate = DownloadDelegate(destination: dest, expected: m.size ?? 0, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: m.url, timeoutInterval: 60)
        request.setValue("Melete/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                delegate.continuation = c
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// Throws, and deletes the file, unless its SHA-256 is `expected`.
    static func verify(_ file: URL, sha256 expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError.checksum
        }
    }

    /// Unpacks the zip into `folder/<version>/` and returns the app inside, once it is shown
    /// to be Melete at that version.
    static func unpack(_ zip: URL, version: String) async throws -> URL {
        let fm = FileManager.default
        let dir = folder.appendingPathComponent(version, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard await run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) == 0 else { throw UpdateError.unpack }
        try? fm.removeItem(at: zip)
        guard let app = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let plist = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version,
              let exe = info["CFBundleExecutable"] as? String,
              fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(exe)").path)
        else { throw UpdateError.notMelete }
        // A download made by the app has no quarantine flag; clear one anyway, as the README
        // asks people to do by hand for the first install.
        _ = await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Puts `new` where `installed` is. On the same disk this is one atomic swap and the old
    /// copy ends up at `new`'s path; otherwise the new copy is first copied next to the old one.
    static func replace(_ installed: URL, with new: URL) throws {
        let parent = installed.deletingLastPathComponent()
        if renamex_np(new.path, installed.path, renameSwap) == 0 { return }
        let e = errno
        if e == EXDEV {
            let near = nearCopy(of: installed)
            try? FileManager.default.removeItem(at: near)
            guard Process.runAndWait("/usr/bin/ditto", [new.path, near.path]) == 0 else {
                try? FileManager.default.removeItem(at: near)
                throw UpdateError.replace(L("复制到 \(parent.path) 失败", "copying into \(parent.path) failed"))
            }
            if renamex_np(near.path, installed.path, renameSwap) == 0 { return }
            try moveAside(installed, new: near)
            return
        }
        guard e == ENOTSUP || e == EINVAL else { throw UpdateError.replace(String(cString: strerror(e))) }
        try moveAside(installed, new: new)
    }

    /// For disks that cannot swap: the old copy steps aside, the new one moves in, and the old
    /// one comes back if that fails.
    private static func moveAside(_ installed: URL, new: URL) throws {
        let aside = oldCopy(of: installed)
        try? FileManager.default.removeItem(at: aside)
        guard rename(installed.path, aside.path) == 0 else { throw UpdateError.replace(String(cString: strerror(errno))) }
        guard rename(new.path, installed.path) == 0 else {
            let why = String(cString: strerror(errno))
            _ = rename(aside.path, installed.path)
            throw UpdateError.replace(why)
        }
    }

    /// `renamex_np`'s RENAME_SWAP.
    private static let renameSwap: UInt32 = 0x2
    private static func nearCopy(of app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent(".\(app.deletingPathExtension().lastPathComponent)-update.app")
    }
    private static func oldCopy(of app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent(".\(app.deletingPathExtension().lastPathComponent)-old.app")
    }

    struct Installed: Codable { let from: String; let to: String }

    static func noteInstalled(from: String, to: String) {
        try? JSONEncoder().encode(Installed(from: from, to: to)).write(to: marker)
    }

    /// At launch: what the last update installed, if anything, and every leftover (the old
    /// copy, an unfinished download) cleared away in the background.
    static func tidy(app: URL) -> Installed? {
        let fm = FileManager.default
        let done = (try? Data(contentsOf: marker)).flatMap { try? JSONDecoder().decode(Installed.self, from: $0) }
        var leftovers = [nearCopy(of: app), oldCopy(of: app)].filter { fm.fileExists(atPath: $0.path) }
        if fm.fileExists(atPath: folder.path) {
            // Renamed first, so a download that starts right away gets a clean folder.
            let trash = folder.deletingLastPathComponent().appendingPathComponent("Updates-old-\(UUID().uuidString)")
            leftovers.append((try? fm.moveItem(at: folder, to: trash)) != nil ? trash : folder)
        }
        if !leftovers.isEmpty {
            let all = leftovers
            Task.detached(priority: .utility) { for url in all { try? FileManager.default.removeItem(at: url) } }
        }
        return done
    }

    /// Opens `app` once this process has quit (or after two minutes, whichever comes first).
    static func relaunchAfterQuit(_ app: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.2; i=$((i + 1)); done; exec /usr/bin/open "$2""#,
                       "sh", String(getpid()), app.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    private static func run(_ tool: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { c.resume(returning: -1) }
        }
    }
}

extension Process {
    /// Runs a tool to the end, output discarded; -1 if it could not start.
    static func runAndWait(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Moves the finished download into place and reports progress, then resumes the waiting task once.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let expected: Int64
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()
    private var finished = false
    private var moveError: Error?
    private var reported = -1.0

    init(destination: URL, expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expected = expected
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        guard total > 0 else { return }
        let p = min(1, Double(totalBytesWritten) / Double(total))
        if p - reported >= 0.005 { reported = p; progress(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 { moveError = UpdateError.http(http.statusCode); return }
        do { try FileManager.default.moveItem(at: location, to: destination) } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        guard first else { return }
        if let e = error ?? moveError { continuation?.resume(throwing: e) } else { continuation?.resume(returning: destination) }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        // Cancelled before the task reported back.
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        if first { continuation?.resume(throwing: error ?? CancellationError()) }
    }
}

// MARK: - The app's side

/// What the window and Settings show about updates, and the two ways an update goes in:
/// restart now, or quietly when Melete quits.
@Observable
@MainActor
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle, checking, upToDate, available
        case downloading(Double)
        case unpacking
        /// Unpacked and checked; goes in at the next restart or quit.
        case ready(URL)
        /// Swapped in; the app is on its way out.
        case installed
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var latest: UpdateManifest?
    private(set) var lastChecked: Date?
    /// Why the last automatic check failed; shown in Settings only, never as a toast.
    private(set) var lastError: String?
    /// The version this launch was just updated to, shown once at the top.
    var justUpdated: String?
    /// The toast was closed for this version.
    var dismissed: String?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var started = false

    static let releasesPage = URL(string: "https://github.com/oliverxuzy-ai/Melete/releases/latest")!

    /// Where to look. CI writes MeleteUpdateFeed into the builds it publishes; a build made on
    /// this Mac has none and never looks, unless told to with
    /// `defaults write com.zhengyangxu.speechpractice updateFeedURL <url>`.
    let feed: URL? = {
        let s = UserDefaults.standard.string(forKey: "updateFeedURL") ?? Bundle.main.infoDictionary?["MeleteUpdateFeed"] as? String
        return s.flatMap { URL(string: $0) }
    }()

    var isEnabled: Bool { feed != nil }
    var autoCheck: Bool { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
    /// The feed has a higher version than this one, and it runs on this Mac.
    var hasUpdate: Bool { latest.map { AppVersion.isNewer($0.version, than: AppVersion.current) && $0.runsHere } ?? false }

    /// Why this copy cannot be replaced where it is, if it cannot.
    var installBlocker: String? {
        let app = Bundle.main.bundleURL, parent = app.deletingLastPathComponent()
        let writable = UpdateEngine.canWrite(parent) && UpdateEngine.canWrite(app)
        // Opened straight from the download (macOS runs it from a hidden read-only copy) or from the disk image.
        if app.path.contains("/AppTranslocation/") || (!writable && app.path.hasPrefix("/Volumes/")) {
            return L("Melete 是从下载的位置直接打开的。先把它拖进“应用程序”文件夹，再更新。",
                     "Melete was opened from where it was downloaded. Move it to the Applications folder first, then update.")
        }
        if !writable {
            return L("没有权限替换 \(parent.path) 里的 Melete。", "No permission to replace Melete in \(parent.path).")
        }
        return nil
    }

    /// Restarting now would cut into practice: counting down, recording, or waiting for a verdict.
    var practiceUnderWay: Bool {
        guard let p = AppState.shared?.stage?.phase else { return false }
        return p == .countdown || p == .recording || p == .analyzing
    }

    /// Nothing would be interrupted: no take on its way, no clip playing, no form half filled.
    private var quiet: Bool {
        if AppState.shared?.tray?.isForm == true { return false }
        guard let p = AppState.shared?.stage?.phase else { return true }
        return p == .ready || p == .result || p == .queued
    }

    /// At launch: finish what the last update left, then check now and every 12 hours.
    func start() {
        guard !started else { return }
        started = true
        if let done = UpdateEngine.tidy(app: Bundle.main.bundleURL), done.to == AppVersion.current {
            justUpdated = done.to
            Task { try? await Task.sleep(for: .seconds(10)); justUpdated = nil }
        }
        guard isEnabled else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            while true {
                if autoCheck { await check(manual: false) }
                try? await Task.sleep(for: .seconds(12 * 3600))
            }
        }
    }

    func check(manual: Bool) async {
        guard let feed else { return }
        switch phase {
        case .checking, .downloading, .unpacking, .ready, .installed: return
        default: break
        }
        if job != nil { return }
        phase = .checking
        do {
            let m = try await UpdateEngine.fetchManifest(feed)
            latest = m
            lastChecked = Date()
            lastError = nil
            phase = hasUpdate ? .available : .upToDate
        } catch {
            lastError = Updater.describe(error)
            phase = manual ? .failed(lastError ?? "") : (hasUpdate ? .available : .idle)
        }
    }

    /// Download, check and unpack the new version, then restart into it if nothing would be
    /// interrupted; otherwise it waits for "Restart now" or for Melete to quit.
    func update() {
        guard let m = latest, hasUpdate, job == nil else { return }
        if let why = installBlocker { phase = .failed(why); return }
        dismissed = nil
        phase = .downloading(0)
        job = Task {
            defer { job = nil }
            do {
                let zip = try await UpdateEngine.download(m) { p in
                    Task { @MainActor in
                        if case .downloading = Updater.shared.phase { Updater.shared.phase = .downloading(p) }
                    }
                }
                try Task.checkCancellation()
                phase = .unpacking
                try await Task.detached(priority: .userInitiated) { try UpdateEngine.verify(zip, sha256: m.sha256) }.value
                let app = try await UpdateEngine.unpack(zip, version: m.version)
                try Task.checkCancellation()
                phase = .ready(app)
                if quiet { restartNow() }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { phase = .available }
                else { phase = .failed(Updater.describe(error)) }
            }
        }
    }

    func cancel() { job?.cancel() }

    /// Swap the new version in and open it once this copy has quit.
    func restartNow() {
        guard case .ready(let app) = phase, !practiceUnderWay else { return }
        do { try install(app) } catch { phase = .failed(Updater.describe(error)); return }
        // The new copy is in place either way; if the reopen cannot be arranged, it opens next time.
        try? UpdateEngine.relaunchAfterQuit(Bundle.main.bundleURL)
        NSApp.terminate(nil)
    }

    /// Melete is quitting with an update ready: put it in place for the next launch.
    func installOnQuit() {
        guard case .ready(let app) = phase else { return }
        try? install(app)
    }

    private func install(_ app: URL) throws {
        guard let m = latest else { return }
        try UpdateEngine.replace(Bundle.main.bundleURL, with: app)
        UpdateEngine.noteInstalled(from: AppVersion.current, to: m.version)
        phase = .installed
    }

    nonisolated static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - CI probe

/// `SpeechPractice --updateprobe <feed> <pretend-version>` runs every step of an update short of
/// restarting, against this copy of the app, posing as `pretend-version`: read the feed,
/// download, refuse a wrong checksum, accept the right one, unpack, and swap the new copy in.
/// The release workflow runs it on each build, then runs the copy that was swapped in.
enum UpdateProbe {
    static func run(feed: String, pretend: String) -> Never {
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) { print("UPDATE PROBE FAILED: timed out"); exit(3) }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            func fail(_ why: String) -> Never { print("UPDATE PROBE FAILED:", why); exit(1) }
            for (a, b, newer) in [("2.10.0", "2.9.9", true), ("2.1.0", "2.1.0", false), ("2.1", "2.1.1", false), ("v3.0.0", "2.99.99", true)]
            where AppVersion.isNewer(a, than: b) != newer { fail("version order \(a) vs \(b)") }
            do {
                guard let url = URL(string: feed) else { fail("bad feed \(feed)") }
                let m = try await UpdateEngine.fetchManifest(url)
                print("feed ok:", m.version, "build", m.build ?? "-", "size", m.size ?? 0, m.url.absoluteString)
                guard AppVersion.isNewer(m.version, than: pretend) else { fail("\(m.version) is not newer than \(pretend)") }
                guard m.runsHere else { fail("needs macOS \(m.minimumSystemVersion ?? "?")") }
                let zip = try await UpdateEngine.download(m) { _ in }
                print("download ok:", (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, "bytes")
                // A copy with one byte changed must be refused.
                let bad = zip.deletingLastPathComponent().appendingPathComponent("tampered.zip")
                try? FileManager.default.removeItem(at: bad)
                try FileManager.default.copyItem(at: zip, to: bad)
                let h = try FileHandle(forUpdating: bad)
                try h.seek(toOffset: 1000)
                let byte = try h.read(upToCount: 1)?.first ?? 0
                try h.seek(toOffset: 1000)
                try h.write(contentsOf: Data([byte ^ 0xFF]))
                try h.close()
                do { try UpdateEngine.verify(bad, sha256: m.sha256); fail("a changed download passed the checksum") } catch UpdateError.checksum {}
                try UpdateEngine.verify(zip, sha256: m.sha256)
                print("checksum ok")
                let app = try await UpdateEngine.unpack(zip, version: m.version)
                print("unpack ok:", app.path)
                try UpdateEngine.replace(Bundle.main.bundleURL, with: app)
                print("replace ok:", Bundle.main.bundleURL.path, "now holds", m.version)
                print("UPDATE PROBE PASSED")
                exit(0)
            } catch { fail(Updater.describe(error)) }
        }
        done.wait()
        exit(1)
    }
}
