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
    /// Sentence-level intonation (prosody.py); missing on recordings analysed before it.
    @Lossy var prosody: Prosody?
    let lowConfidenceWords: Int
    let transcript: String
    let words: [Word]?
    let coverage: Coverage?

    var isChinese: Bool { language.hasPrefix("zh") }
    /// What a "word" is in this recording: a character in Chinese, a word in English.
    var unitLabel: String { isChinese ? L("字", "chars") : L("词", "words") }
    /// The pace unit: 词/分, 字/分, wpm.
    var rateUnit: String { isChinese ? L("字/分", "chars/min") : L("词/分", "wpm") }
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
    /// Notes on how the take sounds, from a cloud audio model; nil when that is off.
    @Lossy var listen: ListenNotes?
}

// MARK: - Prosody and listening notes

/// Decodes a value, or nil when it is missing or shaped differently than expected, so a new
/// or changed field never stops a whole recording from loading.
@propertyWrapper
struct Lossy<T: Codable & Hashable>: Codable, Hashable {
    var wrappedValue: T?
    init(wrappedValue: T?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try? T(from: decoder) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode<T: Codable & Hashable>(_ type: Lossy<T>.Type, forKey key: Key) throws -> Lossy<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? Lossy(wrappedValue: nil)
    }
}

struct ProsodyEnding: Codable, Hashable {
    let dir: String            // fall | rise | level
    let change: Double         // semitones over the sentence's last half second
}

struct ProsodyStress: Codable, Hashable {
    let w: Int                 // index into the recording's words
    let word: String
    let score: Double
    let clear: Bool
}

struct ProsodySentence: Codable, Hashable, Identifiable {
    let i: Int
    let text: String
    let start: Double
    let end: Double
    let pace: Double?
    let range: Double?
    let ending: ProsodyEnding?
    let fades: Bool?
    let stress: ProsodyStress?
    var id: Int { i }

    enum CodingKeys: String, CodingKey { case i, text, start, end, pace, range, ending = "final", fades, stress }
}

struct MonotoneStretch: Codable, Hashable {
    let start: Double
    let end: Double
    let range: Double
}

struct ProsodySummary: Codable, Hashable {
    let sentences: Int
    let endings: [String: Int]
    let fades: Int
    let stressJudged: Int
    let stressShare: Double?
    let monotone: [MonotoneStretch]
    let monotoneSec: Double
    let monotoneShare: Double
    let paceCv: Double?
    let rangeMedian: Double?

    enum CodingKeys: String, CodingKey {
        case sentences, endings = "final", fades, stressJudged, stressShare, monotone, monotoneSec, monotoneShare, paceCv, rangeMedian
    }
}

/// Pitch and level every `step` seconds, each series base64 of signed bytes.
struct ProsodyTrack: Codable, Hashable {
    let step: Double
    let medianHz: Double
    let st: String
    let db: String

    /// Semitones from your median pitch; nil where there was no voice.
    var pitch: [Double?] {
        guard let d = Data(base64Encoded: st) else { return [] }
        return d.map { b in
            let v = Int8(bitPattern: b)
            return v == -128 ? nil : Double(v) / 10
        }
    }
}

struct ShadowRow: Codable, Hashable, Identifiable {
    let i: Int
    let text: String
    let start: Double
    let end: Double
    let similarity: Double?
    let rangeRatio: Double?
    let refFinal: String?
    let yourFinal: String?
    let refStress: String?
    let yourStress: String?
    let refContour: [Double]
    let yourContour: [Double]
    var id: Int { i }
}

struct ShadowSummary: Codable, Hashable {
    let compared: Int
    let of: Int
    let similarity: Double?
    let rangeRatio: Double?
    let sameFinal: Double?
    let sameStress: Double?
    let worst: [Int]
}

struct ShadowProsody: Codable, Hashable {
    let sentences: [ShadowRow]
    let summary: ShadowSummary
}

struct Prosody: Codable, Hashable {
    let track: ProsodyTrack
    let sentences: [ProsodySentence]
    let summary: ProsodySummary
    @Lossy var shadow: ShadowProsody?
}

struct ListenOverall: Codable, Hashable {
    let tone: String
    let confidence: Int?
    let energy: Int?
    let summary: String
    let tip: String
}

struct ListenSentence: Codable, Hashable {
    let i: Int
    let tone: String
    let confidence: Int?
    let note: String
}

struct ListenNotes: Codable, Hashable {
    let status: String         // pending | done | error | skipped
    let model: String?
    let overall: ListenOverall?
    let sentences: [ListenSentence]?
    let error: String?
    let reason: String?
    var isPending: Bool { status == "pending" }
    var isDone: Bool { status == "done" && overall != nil }
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
        case .presentation: return L("演示 / 汇报", "Presentation")
        case .meeting: return L("会议发言", "Meeting")
        case .interview: return L("面试", "Interview")
        case .pitch: return L("电梯演讲", "Elevator pitch")
        case .smalltalk: return L("闲聊 / 寒暄", "Small talk")
        case .other: return L("其他", "Other")
        }
    }
    static func label(for raw: String?) -> String { Scenario(rawValue: raw ?? "")?.label ?? (raw ?? "") }
}

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case en, zh, auto
    var id: String { rawValue }
    var label: String { self == .en ? "English" : self == .zh ? "中文" : L("自动", "Auto") }
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
        case "shadow": return L("跟读", "Shadow")
        case "retell": return L("复述", "Retell")
        case "agenda": return L("备讲", "Prep")
        default: return L("即兴", "Impromptu")
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

struct ListenSettings: Codable, Hashable {
    var enabled: Bool
    var model: String
    var hasKey: Bool?
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
    var listen: ListenSettings?
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
        case "shadow": return L("跟读", "Shadow")
        case "retell": return L("复述", "Retell")
        case "agenda": return L("备讲", "Prep")
        case "impromptu": return L("即兴", "Impromptu")
        case "topic": return L("讲稿", "Script")
        default: return L("自由", "Free")
        }
    }
}
