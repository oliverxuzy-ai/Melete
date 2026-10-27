import Foundation

// Mirrors the JSON the Python server returns (snake_case → camelCase via the decoder).

struct PracticeListItem: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var scenario: String
    let createdAt: String
    var updatedAt: String?
    var hasScript: Bool
    var sessionCount: Int
    var lastAt: String?
    var lastCoverage: Double?
    var kind: String?
    var clip: ClipMeta?
    var refDuration: Double?
    var refWpm: Double?

    var isClip: Bool { kind == "clip" }
}

/// Where a daily clip came from.
struct ClipMeta: Codable, Hashable {
    var date: String?
    var role: String?
    var sourceId: String?
    var videoId: String?
    var videoTitle: String?
    var channel: String?
    var start: Double?
    var end: Double?
    var url: String?
    var pickedBy: String?
    var wpm: Double?
}

/// Which plan item a recording belongs to.
struct Drill: Codable, Hashable {
    var item: String?
    var kind: String?
    var promptId: String?
    var date: String?
}

struct SessionSummary: Codable, Identifiable, Hashable {
    let id: String
    let createdAt: String
    var title: String
    var scenario: String?
    var language: String?
    var durationSec: Double
    var wordCount: Int
    var wpm: Double
    var articulationWpm: Double
    var selfRating: Int?
    var practiceId: String?
    var fillersPerMinute: Double
    var fillerCount: Int
    var pauseCount: Int
    var pausesPerMinute: Double
    var longestPauseSec: Double
    var hedgeCount: Int
    var coverage: Double?
    var attempt: Int?
    var drill: Drill?
    var pitchRange: Double?
}

struct PacePoint: Codable, Hashable { let t: Double; let wpm: Double }
struct PauseItem: Codable, Hashable { let start: Double; let end: Double; let dur: Double }

struct Pauses: Codable, Hashable {
    let count: Int
    let longCount: Int
    let totalSec: Double
    let longestSec: Double
    let perMinute: Double
    let silenceRatio: Double
    let list: [PauseItem]?
}

struct Fillers: Codable, Hashable {
    let count: Int
    let perMinute: Double
    let ratio: Double
    let breakdown: [String: Int]
}

struct Hedges: Codable, Hashable {
    let count: Int
    let breakdown: [String: Int]
}

/// Server sends `top_words` as `[["word", 3], ...]`.
struct TopWord: Codable, Hashable {
    let word: String
    let count: Int
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        word = try c.decode(String.self)
        count = try c.decode(Int.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(word); try c.encode(count)
    }
}

struct Vocabulary: Codable, Hashable {
    let unique: Int
    let typeTokenRatio: Double
    let topWords: [TopWord]
}

struct SentenceStats: Codable, Hashable { let count: Int; let avgLen: Double; let maxLen: Int }

struct Loudness: Codable, Hashable {
    var meanDb: Double?
    var stdDb: Double?
    var peakDb: Double?
    var noiseFloorDb: Double?
}

struct Pitch: Codable, Hashable {
    var medianHz: Double?
    var p10Hz: Double?
    var p90Hz: Double?
    var rangeSemitones: Double?
    var stdSemitones: Double?
}

struct Word: Codable, Hashable {
    let text: String
    let start: Double
    let end: Double
    let prob: Double
}

struct CoveragePoint: Codable, Hashable, Identifiable {
    let i: Int
    let text: String
    let score: Double
    let status: String   // covered | partial | missed
    let hits: [String]
    let misses: [String]
    let pos: Int?
    var id: Int { i }
}

struct CoverageTerm: Codable, Hashable { let term: String; let said: Bool }
struct CoverageCounts: Codable, Hashable { let covered: Int; let partial: Int; let missed: Int }

struct Coverage: Codable, Hashable {
    let coverage: Double
    let counts: CoverageCounts
    let points: [CoveragePoint]
    let terms: [CoverageTerm]
    let termsSaid: Int
    let order: Double?
    let scriptWords: Int
    let transcriptWords: Int
    let expansion: Double?
    let extra: [String]
}

struct Metrics: Codable, Hashable {
    let language: String
    let unit: String
    let durationSec: Double
    let speakingSec: Double
    let wordCount: Int
    let wpm: Double
    let articulationWpm: Double
    let paceTimeline: [PacePoint]
    let pauses: Pauses
    let fillers: Fillers
    let hedges: Hedges
    let repeats: Int
    let vocabulary: Vocabulary
    let sentences: SentenceStats
    let loudness: Loudness?
    let pitch: Pitch?
    let lowConfidenceWords: Int
    let transcript: String
    let words: [Word]?
    let coverage: Coverage?

    var isChinese: Bool { language.hasPrefix("zh") }
    var unitLabel: String { isChinese ? "字" : "词" }
}

struct Session: Codable, Hashable, Identifiable {
    let id: String
    let createdAt: String
    var title: String
    var scenario: String?
    var notes: String?
    var selfRating: Int?
    var practiceId: String?
    let audioFile: String?
    let language: String
    let durationSec: Double
    let wordCount: Int
    let wpm: Double
    let articulationWpm: Double
    var drill: Drill?
    let metrics: Metrics
    var review: Review?
}

struct RefSentence: Codable, Hashable, Identifiable {
    let i: Int
    let text: String
    let start: Double
    let end: Double
    let matched: Bool?
    var id: Int { i }
}

struct Reference: Codable, Hashable {
    let audioFile: String
    let originalName: String?
    let uploadedAt: String
    let language: String
    let durationSec: Double
    let transcript: String?
    let subtitlesFrom: String?
    let sentences: [RefSentence]
    let metrics: Metrics
}

struct Practice: Codable, Hashable, Identifiable {
    let id: String
    let createdAt: String
    var updatedAt: String?
    var title: String
    var script: String
    var scenario: String
    var notes: String
    var sessions: [SessionSummary]
    var points: [String]
    var terms: [String]
    var reference: Reference?
    var kind: String?
    var clip: ClipMeta?
    var agendaId: String?

    var isClip: Bool { kind == "clip" }
}

struct ServerConfig: Codable {
    let model: String
    let modelLoaded: Bool
    let models: [String: Bool]
    let modelZh: String
}

enum Scenario: String, CaseIterable, Identifiable {
    case presentation, meeting, interview, pitch, smalltalk, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .presentation: return "演示 / 汇报"
        case .meeting: return "会议发言"
        case .interview: return "面试"
        case .pitch: return "电梯演讲"
        case .smalltalk: return "闲聊 / 寒暄"
        case .other: return "其他"
        }
    }
    static func label(for raw: String?) -> String { Scenario(rawValue: raw ?? "")?.label ?? (raw ?? "") }
}

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case en, zh, auto
    var id: String { rawValue }
    var label: String { self == .en ? "English" : self == .zh ? "中文" : "自动" }
    var localeIdentifier: String { self == .zh ? "zh-CN" : "en-US" }
}

/// Reference pace bands shown behind charts, per language.
func paceBand(for language: String) -> ClosedRange<Double> { language.hasPrefix("zh") ? 180...260 : 130...160 }

func formatClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

func shortDate(_ iso: String) -> String {
    // "2026-09-05T17:18:03" → "09-05 17:18"
    guard iso.count >= 16 else { return iso }
    let s = iso.replacingOccurrences(of: "T", with: " ")
    let start = s.index(s.startIndex, offsetBy: 5)
    let end = s.index(s.startIndex, offsetBy: 16)
    return String(s[start..<end])
}


// MARK: - Coaching

struct FocusMetric: Codable, Hashable, Identifiable {
    let key: String
    let label: String
    let value: Double
    let unit: String
    let target: String
    let state: String          // in | low | high
    let delta: Double?
    var id: String { key }
    var inTarget: Bool { state == "in" }
}

struct Review: Codable, Hashable {
    let headline: String
    let lines: [String]
    let focus: [FocusMetric]
    let block: String
}

struct BlockInfo: Codable, Hashable {
    let key: String
    let greek: String
    let name: String
    let why: String
    var tip: String?
    var week: Int?
    var weeks: Int
    var cycleWeek: Int?
    var focus: [String]?
    var pinned: Bool?
}

struct Baseline: Codable, Hashable {
    let wpm: Double
    let pitch: Double
    let loudness: Double
    let fillers: Double
    let count: Int
}

struct Targets: Codable, Hashable {
    let wpmLow: Double
    let wpmHigh: Double
    let pitch: Double
    let loudness: Double
    let fillers: Double
    var band: ClosedRange<Double> { wpmLow...wpmHigh }
}

struct WeekDay: Codable, Hashable, Identifiable {
    let date: String
    let state: String          // done | missed | today | future
    let minutes: Double
    var id: String { date }
}

struct WeekInfo: Codable, Hashable {
    let start: String
    let days: [WeekDay]
    var daysSince: Int?
    let done: Int
    let target: Int
    let committed: Bool
    let missedYesterday: Bool
    let missedTwo: Bool
    let todayDone: Bool

    var laurel: [LaurelWreath.Day] {
        days.map { d in
            switch d.state {
            case "done": return .done
            case "missed": return .missed
            case "today": return .today
            default: return .future
            }
        }
    }
}

struct PlanItem: Codable, Hashable, Identifiable {
    let id: String
    let kind: String            // shadow | retell | impromptu | agenda
    var practiceId: String?
    var promptId: String?
    let title: String
    let subtitle: String
    var prompt: String?
    let seconds: Int
    let detail: String
    var sessionId: String?

    var done: Bool { sessionId != nil }
    var kindLabel: String {
        switch kind {
        case "shadow": return "跟读"
        case "retell": return "复述"
        case "agenda": return "备讲"
        default: return "即兴"
        }
    }
}

struct DailyInfo: Codable, Hashable {
    let state: String           // ready | running | waiting | failed | off
    let message: String?
    let progress: Double
    let errors: [String]
    let want: Int
}

struct PrepStep: Codable, Hashable, Identifiable {
    let id: String
    let key: String
    let title: String
    let detail: String
    let date: String
    let offset: Int
    let state: String           // done | today | missed | upcoming
}

struct AgendaEvent: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var date: String
    var kind: String
    var minutes: Int
    var notes: String
    var practiceId: String?
    var createdAt: String?
    var hasScript: Bool?
    var daysLeft: Int
    var kindLabel: String
    var steps: [PrepStep]
    var past: Bool
}

struct AgendaTemplate: Codable, Hashable {
    let title: String
    let kind: String
    let minutes: Int
}

struct AgendaPayload: Codable {
    let events: [AgendaEvent]
    let templates: [AgendaTemplate]
    let kinds: [String: String]
}

struct LastSessionInfo: Codable, Hashable {
    let id: String
    let title: String?
    let createdAt: String
    let wpm: Double
    let durationSec: Double
    let headline: String
    let focus: [FocusMetric]
}

struct TodayPayload: Codable {
    let date: String
    let weekday: String
    let block: BlockInfo
    let baseline: Baseline
    let targets: Targets
    let week: WeekInfo
    let items: [PlanItem]
    let daily: DailyInfo
    let nextEvent: AgendaEvent?
    let last: LastSessionInfo?
    let sessionCount: Int

    var nextItem: PlanItem? { items.first { !$0.done } }
}

struct RecapDay: Codable, Hashable, Identifiable {
    let date: String
    let practiced: Bool
    let minutes: Double
    var id: String { date }
}

struct RecapMetric: Codable, Hashable {
    let this: Double?
    let last: Double?
}

struct RecapBlock: Codable, Hashable {
    let key: String
    let name: String
    let greek: String
    var why: String?
}

struct RecapBest: Codable, Hashable {
    let id: String
    let title: String?
    let wpm: Double?
    let pitch: Double?
}

struct Recap: Codable, Hashable {
    let start: String
    let end: String
    let days: [RecapDay]
    let practiced: Int
    let target: Int
    let recordMinutes: Double
    let listenMinutes: Double
    let sessions: Int
    let metrics: [String: RecapMetric]
    let best: RecapBest?
    let block: RecapBlock
    let next: RecapBlock
}

struct DailySettings: Codable, Hashable {
    var enabled: Bool
    var clipsPerDay: Int
    var notifyTime: String
    var prepHour: Int
    var ntfyTopic: String
    var useClaude: Bool
    var claudeModel: String
    var hasClaudeKey: Bool?
}

struct CoachSettings: Codable, Hashable {
    var cycleStart: String?
    var weekTargetDays: Int
    var blockOverride: String?
    var committedWeek: String?
}

struct ToolsInfo: Codable, Hashable {
    let ytDlp: String?
    let ffmpeg: String?
}

struct SettingsPayload: Codable {
    var daily: DailySettings
    var coach: CoachSettings
    let tools: ToolsInfo
    let blocks: [BlockInfo]
}

struct ClipCard: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let duration: Double?
    let wpm: Double?
}

struct DailyDay: Codable, Hashable, Identifiable {
    let date: String
    let items: [ClipCard]
    let errors: [String]
    var id: String { date }
}

struct DailyJob: Codable, Hashable {
    let state: String
    let message: String
    let date: String?
    let progress: Double
    let updatedAt: String?
}

struct DailyPayload: Codable {
    let status: DailyJob
    let tools: ToolsInfo
    let days: [DailyDay]
    let tomorrowReady: Int
}

struct SourceItem: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var url: String?
    var query: String?
    var video: String?
    var kind: String
    var role: String
    var enabled: Bool
    var weight: Int?
}

/// A recent recording with its one-line verdict and the space it belongs to.
struct RecentSession: Codable, Hashable, Identifiable {
    let id: String
    let createdAt: String
    var title: String
    var language: String?
    var durationSec: Double
    var wpm: Double
    var fillersPerMinute: Double
    var pitchRange: Double?
    var coverage: Double?
    var practiceId: String?
    var headline: String
    var kind: String
    var space: String
    var practiceTitle: String?

    var kindLabel: String {
        switch kind {
        case "shadow": return "跟读"
        case "retell": return "复述"
        case "agenda": return "备讲"
        case "impromptu": return "即兴"
        case "topic": return "讲稿"
        default: return "自由"
        }
    }
}
