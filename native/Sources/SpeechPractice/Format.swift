import Foundation

// MARK: - Date helpers

private let cnDigits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

func chineseNumber(_ n: Int) -> String {
    if n <= 10 { return cnDigits[n] }
    if n < 20 { return "十" + (n % 10 == 0 ? "" : cnDigits[n % 10]) }
    return cnDigits[n / 10] + "十" + (n % 10 == 0 ? "" : cnDigits[n % 10])
}

/// "2026-10-25" -> "十月二十五日"
func chineseDate(_ iso: String) -> String {
    let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return iso }
    return "\(chineseNumber(parts[1]))月\(chineseNumber(parts[2]))日"
}

func chineseDate(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.month, .day], from: d)
    return "\(chineseNumber(c.month ?? 1))月\(chineseNumber(c.day ?? 1))日"
}

func durationLabel(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) 秒" }
    return seconds % 60 == 0 ? "\(seconds / 60) 分钟" : "\(seconds / 60) 分 \(seconds % 60) 秒"
}

func shortDay(_ iso: String) -> String {
    let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return iso }
    return "\(parts[1]) 月 \(parts[2]) 日"
}

func relativeDay(_ iso: String) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
    guard let d = f.date(from: String(iso.prefix(10))) else { return iso }
    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d), to: Calendar.current.startOfDay(for: Date())).day ?? 0
    switch days {
    case 0: return "今天"
    case 1: return "昨天"
    case 2...6: return "\(days) 天前"
    default: return shortDay(iso)
    }
}
