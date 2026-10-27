import Foundation
import Observation

/// The interface language. Chinese is the original; English mirrors it line for line.
enum AppLanguage: String, CaseIterable, Identifiable {
    case zh, en
    var id: String { rawValue }
    /// Each language names itself, so the choice reads the same whichever one is on.
    var nativeName: String { self == .zh ? "中文" : "English" }
    /// What AppKit's own menus (Quit, Hide, Edit, Window) and the permission prompts follow.
    var appleLanguage: String { self == .zh ? "zh-Hans" : "en" }
}

/// The language the interface is in. Views that call `L` while drawing observe it, so
/// switching redraws them in place, without closing anything.
@Observable
final class LanguageSetting: @unchecked Sendable {
    static let shared = LanguageSetting()
    static let defaultsKey = "uiLanguage"

    var current: AppLanguage

    private init() {
        current = AppLanguage(rawValue: UserDefaults.standard.string(forKey: LanguageSetting.defaultsKey) ?? "") ?? .zh
    }

    var isEnglish: Bool { current == .en }

    /// The user's choice: remembered, and handed to AppKit for its own menus from the next launch.
    func choose(_ lang: AppLanguage) {
        current = lang
        UserDefaults.standard.set(lang.rawValue, forKey: LanguageSetting.defaultsKey)
        LanguageSetting.syncSystemMenus(lang)
    }

    /// AppKit reads its menu language once, at launch, from AppleLanguages.
    static func syncSystemMenus(_ lang: AppLanguage) {
        let want = [lang.appleLanguage]
        if UserDefaults.standard.stringArray(forKey: "AppleLanguages") != want {
            UserDefaults.standard.set(want, forKey: "AppleLanguages")
        }
    }
}

/// Interface text in the current language: the Chinese first, the English second.
func L(_ zh: String, _ en: String) -> String { LanguageSetting.shared.current == .en ? en : zh }

/// True while the interface is in English; for the few layouts that need more room.
var isEnglishUI: Bool { LanguageSetting.shared.current == .en }

/// "1 day", "3 days". English only; Chinese has no plural.
func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
    "\(n) \(n == 1 ? one : (many ?? one + "s"))"
}
