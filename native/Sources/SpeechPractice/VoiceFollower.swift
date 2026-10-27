import Foundation

/// Follows a reader through a known text from the live transcript, so the subtitles move with
/// the voice instead of with the original's clock.
///
/// Recognized words are matched forward against the text within a short reach. Common words may
/// only step a word or two, so a stray "the" cannot pull the place ahead; a content word may reach
/// further, which skips over words the recognizer missed. When several words in a row match
/// nothing (a skipped line, a stumble), two words found together further on carry the place there.
/// The place only moves forward; tapping a line sets it by hand.
struct VoiceFollower {
    private struct Word { let token: String; let sentence: Int }
    private var words: [Word] = []
    /// Index of each sentence's first word.
    private var starts: [Int] = []
    /// Next word expected, from finished results only.
    private var committed = 0
    private var finalsSeen = 0
    /// Next word expected, counting the result still being revised. Never moves back.
    private(set) var position = 0

    init(sentences: [String] = []) {
        for (i, s) in sentences.enumerated() {
            starts.append(words.count)
            for t in VoiceFollower.tokens(s) { words.append(Word(token: t, sentence: i)) }
        }
    }

    var sentenceCount: Int { starts.count }
    var wordCount: Int { words.count }

    /// Takes the transcript so far: every finished result, and the one still being revised.
    /// Returns true when the place moved.
    mutating func hear(finals: [String], volatile: String) -> Bool {
        guard !words.isEmpty else { return false }
        let before = position
        if finals.count < finalsSeen { finalsSeen = finals.count }
        while finalsSeen < finals.count {
            committed = advance(from: committed, over: VoiceFollower.tokens(finals[finalsSeen]))
            finalsSeen += 1
        }
        let tentative = volatile.isEmpty ? committed : advance(from: committed, over: VoiceFollower.tokens(volatile))
        position = max(position, committed, tentative)
        return position != before
    }

    /// The reader says where they are (a tapped line).
    mutating func anchor(sentence: Int) {
        guard starts.indices.contains(sentence) else { return }
        position = starts[sentence]
        committed = starts[sentence]
    }

    /// The line to show. It moves on to the next line once no more than `lead` words of this one
    /// are left (twice as many characters in Chinese), so the next line is already in place when
    /// the voice gets there, despite the recognizer running a little behind. A short line keeps
    /// at most a third of its words in reserve, so it is not passed over as soon as it is reached.
    /// `ahead` counts words taken as said beyond what was recognized (a prediction).
    func sentence(lead: Int, ahead: Int = 0) -> Int {
        guard !words.isEmpty else { return 0 }
        let position = min(words.count, self.position + max(0, ahead))
        guard position < words.count else { return starts.count - 1 }
        let s = words[position].sentence
        guard s + 1 < starts.count else { return s }
        let end = starts[s + 1]
        let heard = position - starts[s]
        let left = end - position
        let len = end - starts[s]
        let reach = min(VoiceFollower.isCJK(words[position].token) ? lead * 2 : lead, max(1, len / 3))
        return heard > 0 && left <= reach ? s + 1 : s
    }

    // MARK: matching

    private func advance(from start: Int, over spoken: [String]) -> Int {
        var p = start
        var unmatched: [String] = []
        for w in spoken {
            if let j = match(w, from: p) {
                p = j + 1
                unmatched = []
                continue
            }
            unmatched.append(w)
            if unmatched.count >= 3, let j = resync(Array(unmatched.suffix(3)), from: p) {
                p = j
                unmatched = []
            }
        }
        return p
    }

    private func match(_ w: String, from p: Int) -> Int? {
        let cjk = VoiceFollower.isCJK(w)
        let reach = VoiceFollower.isContent(w) ? (cjk ? 16 : 10) : (cjk ? 3 : 2)
        guard p < words.count else { return nil }
        for j in p..<min(words.count, p + reach) where VoiceFollower.same(words[j].token, w) { return j }
        return nil
    }

    /// Two of the last spoken words found next to each other further on, one of them a content word.
    private func resync(_ last: [String], from p: Int) -> Int? {
        guard p < words.count else { return nil }
        let limit = min(words.count, p + 60)
        for (x, y) in zip(last, last.dropFirst()) where VoiceFollower.isContent(x) || VoiceFollower.isContent(y) {
            for j in p..<limit where VoiceFollower.same(words[j].token, x) {
                for k in (j + 1)..<min(limit, j + 3) where VoiceFollower.same(words[k].token, y) { return k + 1 }
            }
        }
        return nil
    }

    // MARK: words

    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        for raw in s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }) {
            let t = raw.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            if t.isEmpty { continue }
            if t.unicodeScalars.contains(where: { isCJK($0) }) {
                // Chinese has no spaces: each character is a word here.
                out.append(contentsOf: t.map(String.init))
            } else {
                out.append(numbers[t] ?? t)
            }
        }
        return out
    }

    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // start and started, symbolic and symbols: the recognizer and the transcript disagree on endings
        guard a.count >= 5, b.count >= 5 else { return false }
        return a.prefix(5) == b.prefix(5)
    }

    static func isContent(_ w: String) -> Bool {
        if isCJK(w) { return !cjkCommon.contains(w) }
        if w.contains(where: \.isNumber) { return true }
        return w.count >= 4 && !common.contains(w)
    }

    static func isCJK(_ w: String) -> Bool { w.unicodeScalars.contains(where: { isCJK($0) }) }
    private static func isCJK(_ u: Unicode.Scalar) -> Bool { (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) }

    private static let numbers: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "fifteen": "15", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "hundred": "100", "thousand": "1000",
    ]

    /// Words of four letters or more that say little about where in a text you are.
    private static let common: Set<String> = [
        "that", "this", "these", "those", "your", "youre", "they", "them", "their", "theyre", "from", "have",
        "been", "does", "doesnt", "just", "will", "would", "could", "should", "what", "which", "there", "theres",
        "here", "then", "than", "about", "into", "also", "very", "really", "like", "know", "yeah", "well",
        "thats", "dont", "were", "with", "some", "more", "when", "where", "because", "kind", "sort", "going",
        "gonna", "want", "think", "thing", "things", "said", "says", "only", "even", "much", "many", "make",
        "made", "being", "other", "over", "after", "before", "again", "still", "something", "anything", "okay",
    ]
    private static let cjkCommon: Set<String> = ["的", "了", "是", "我", "你", "他", "她", "们", "这", "那", "就", "也", "在", "有", "和", "个", "不", "一", "说", "要", "会", "吗", "吧", "呢", "啊"]
}
