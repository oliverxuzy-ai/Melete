import Foundation
import Observation

/// Accumulates listening time locally and posts it to the server in batches.
/// Playback ticks add tiny wall-clock deltas; nothing is sent on seek, and a batch goes out
/// every ~20 s of listening, on pause/stop, and when the app quits (backlog restored on next launch).
@Observable
@MainActor
final class ActivityTracker {
    struct Event: Codable {
        var kind: String
        var practiceId: String?
        var sessionId: String?
        var wallSec: Double
        var mediaSec: Double
        var rate: Float
        var at: String
    }

    var api: API?
    private var pending: [String: Event] = [:]
    private var pendingWall: Double = 0
    private static let backlogKey = "activityBacklog"

    func add(kind: String, practiceId: String?, sessionId: String?, wall: Double, media: Double, rate: Float) {
        guard wall > 0 else { return }
        let key = "\(kind)|\(practiceId ?? "")|\(sessionId ?? "")"
        var e = pending[key] ?? Event(kind: kind, practiceId: practiceId, sessionId: sessionId, wallSec: 0, mediaSec: 0, rate: rate, at: ActivityTracker.now())
        e.wallSec += wall; e.mediaSec += media; e.rate = rate
        pending[key] = e
        pendingWall += wall
        if pendingWall >= 20 { flush() }
    }

    func flush() {
        guard !pending.isEmpty else { return }
        let events = Array(pending.values)
        pending = [:]; pendingWall = 0
        guard let api else { queueBacklog(events); return }
        Task {
            do {
                let payload = events.map { ["kind": $0.kind, "practice_id": $0.practiceId as Any?, "session_id": $0.sessionId as Any?,
                                            "wall_sec": $0.wallSec, "media_sec": $0.mediaSec, "rate": Double($0.rate), "at": $0.at] }
                let body = try JSONSerialization.data(withJSONObject: ["events": payload.map { $0.mapValues { $0 ?? NSNull() } }])
                var req = URLRequest(url: api.url("api/activity"))
                req.httpMethod = "POST"; req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (_, resp) = try await URLSession.shared.data(for: req)
                if ((resp as? HTTPURLResponse)?.statusCode ?? 500) >= 300 { queueBacklog(events) }
            } catch { queueBacklog(events) }
        }
    }

    /// Kept in UserDefaults if the server is unreachable or the app is quitting mid-flush.
    private func queueBacklog(_ events: [Event]) {
        var all = loadBacklog()
        all.append(contentsOf: events)
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: ActivityTracker.backlogKey)
    }

    private func loadBacklog() -> [Event] {
        guard let data = UserDefaults.standard.data(forKey: ActivityTracker.backlogKey) else { return [] }
        return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }

    func saveBacklog() {
        guard !pending.isEmpty else { return }
        queueBacklog(Array(pending.values))
        pending = [:]; pendingWall = 0
    }

    func restoreBacklog() {
        let events = loadBacklog()
        guard !events.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: ActivityTracker.backlogKey)
        for e in events { pending["\(e.kind)|\(e.practiceId ?? "")|\(e.sessionId ?? "")|\(e.at)"] = e }
        flush()
    }

    static func now() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

struct InsightDay: Codable, Hashable, Identifiable {
    let date: String
    let recordSec: Double
    let recordCount: Int
    let listenRefSec: Double
    let listenRefMediaSec: Double
    let listenSelfSec: Double
    let listenSelfMediaSec: Double
    let totalSec: Double
    var id: String { date }
}

struct InsightTotals: Codable, Hashable {
    let recordSec: Double
    let recordCount: Int
    let listenRefSec: Double
    let listenRefMediaSec: Double
    let listenSelfSec: Double
    let listenPasses: Double
    let activeDays: Int
    let currentStreak: Int
    let longestStreak: Int
    let firstDay: String?
    let thisWeekSec: Double
    let lastWeekSec: Double
}

struct InsightPractice: Codable, Hashable, Identifiable {
    let practiceId: String?
    let title: String
    let recordCount: Int
    let recordSec: Double
    let listenRefSec: Double
    let listenRefMediaSec: Double
    let listenSelfSec: Double
    let referenceSec: Double?
    let listenRefPasses: Double?
    var id: String { practiceId ?? "none" }
}

struct Insights: Codable, Hashable {
    let days: [InsightDay]
    let totals: InsightTotals
    let practices: [InsightPractice]
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) 秒" }
    if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
    return String(format: "%d 小时 %d 分", s / 3600, (s % 3600) / 60)
}
