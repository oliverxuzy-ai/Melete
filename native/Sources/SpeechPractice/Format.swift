import Foundation

// MARK: - Date helpers

private let cnDigits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

func chineseNumber(_ n: Int) -> String {
    if n <= 10 { return cnDigits[n] }
    if n < 20 { return "十" + (n % 10 == 0 ? "" : cnDigits[n % 10]) }
    return cnDigits[n / 10] + "十" + (n % 10 == 0 ? "" : cnDigits[n % 10])
}

private let enMonths = ["January", "February", "March", "April", "May", "June", "July",
                        "August", "September", "October", "November", "December"]

/// "2026-10-25" -> "十月二十五日", or "October 25"
func longDate(_ iso: String) -> String {
    let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return iso }
    return longDate(month: parts[1], day: parts[2])
}

func longDate(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.month, .day], from: d)
    return longDate(month: c.month ?? 1, day: c.day ?? 1)
}

private func longDate(month: Int, day: Int) -> String {
    if isEnglishUI { return "\(enMonths[max(0, min(11, month - 1))]) \(day)" }
    return "\(chineseNumber(month))月\(chineseNumber(day))日"
}

/// Short month name for chart labels: "10月" or "Oct".
func monthLabel(_ month: Int) -> String {
    isEnglishUI ? String(enMonths[max(0, min(11, month - 1))].prefix(3)) : "\(month)月"
}

/// Monday first. One character in Chinese, one letter in English.
var weekdayInitials: [String] {
    isEnglishUI ? ["M", "T", "W", "T", "F", "S", "S"] : ["一", "二", "三", "四", "五", "六", "日"]
}

func durationLabel(_ seconds: Int) -> String {
    if isEnglishUI {
        if seconds < 60 { return "\(seconds) sec" }
        return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) sec"
    }
    if seconds < 60 { return "\(seconds) 秒" }
    return seconds % 60 == 0 ? "\(seconds / 60) 分钟" : "\(seconds / 60) 分 \(seconds % 60) 秒"
}

func shortDay(_ iso: String) -> String {
    let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return iso }
    if isEnglishUI { return "\(enMonths[max(0, min(11, parts[1] - 1))].prefix(3)) \(parts[2])" }
    return "\(parts[1]) 月 \(parts[2]) 日"
}

/// Days from that date to today: 0 is today, 1 yesterday. Nil when it is not a date.
func daysAgo(_ iso: String) -> Int? {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
    guard let d = f.date(from: String(iso.prefix(10))) else { return nil }
    return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d), to: Calendar.current.startOfDay(for: Date())).day ?? 0
}

func relativeDay(_ iso: String) -> String {
    guard let days = daysAgo(iso) else { return iso }
    switch days {
    case 0: return L("今天", "Today")
    case 1: return L("昨天", "Yesterday")
    case 2...6: return L("\(days) 天前", "\(days) days ago")
    default: return shortDay(iso)
    }
}

/// A day heading: "今天，十月二十五日" for today and yesterday, the date alone before that.
func dayTitle(_ iso: String) -> String {
    let d = daysAgo(iso)
    return d == 0 || d == 1 ? L("\(relativeDay(iso))，\(longDate(iso))", "\(relativeDay(iso)), \(longDate(iso))") : longDate(iso)
}
