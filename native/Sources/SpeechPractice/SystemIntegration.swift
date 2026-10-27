import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Reminders

/// The daily nudge. Nothing is requested from macOS until you turn reminders on in Settings.
@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminders()
    private let center = UNUserNotificationCenter.current()
    private static let dailyID = "melete.daily"

    func setup() {
        center.delegate = self
        let start = UNNotificationAction(identifier: "start", title: "开始练习", options: [.foreground])
        let later = UNNotificationAction(identifier: "later", title: "一小时后提醒", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "practice", actions: [start, later], intentIdentifiers: [], options: [])])
    }

    /// Asks for permission (the first time only) and schedules the daily reminder.
    func enable(at time: String) async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        schedule(at: time)
        return true
    }

    func schedule(at time: String) {
        center.removePendingNotificationRequests(withIdentifiers: [Reminders.dailyID])
        let parts = time.split(separator: ":").compactMap { Int($0) }
        var when = DateComponents()
        when.hour = parts.first ?? 21
        when.minute = parts.count > 1 ? parts[1] : 30
        let request = UNNotificationRequest(identifier: Reminders.dailyID, content: content(),
                                            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true))
        center.add(request)
    }

    func disable() {
        center.removePendingNotificationRequests(withIdentifiers: [Reminders.dailyID])
    }

    func sendTest() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        let request = UNNotificationRequest(identifier: "melete.test", content: content(),
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        try? await center.add(request)
        return true
    }

    private func content() -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = "到点练一段了"
        c.body = "今天的片段和题目已经备好。点开就开始，三秒后自动录音。"
        c.sound = .default
        c.categoryIdentifier = "practice"
        return c
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        await MainActor.run {
            if action == "later" {
                let c = UNMutableNotificationContent()
                c.title = "说好的一小时到了"
                c.body = "录一段一分钟的就算数。"
                c.sound = .default
                c.categoryIdentifier = "practice"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "melete.later", content: c,
                                                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)))
            } else {
                AppState.shared?.requestStart()
            }
        }
    }
}

// MARK: - Global shortcut

/// Control-Option-R from any app opens the stage on today's next item.
/// Carbon hot keys need no Accessibility permission.
final class GlobalHotkey {
    static let shared = GlobalHotkey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Result of the last registration; noErr when the shortcut is live.
    private(set) var status: OSStatus = -1

    func register() {
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if handler == nil {
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { AppState.shared?.requestStart() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4D4C5445), id: 1)
        status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        status = -1
    }
}

// MARK: - Login item

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - Menu bar

/// Today's plan from the menu bar, so starting never needs the main window first.
struct MenuBarContent: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let t = state.today {
                HStack(alignment: .center, spacing: 12) {
                    LaurelWreath(days: t.week.laurel, target: t.week.target, size: 58, showCount: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chineseDate(t.date)).font(Typeface.display(18))
                        Text("本周 \(t.week.done) / \(t.week.target) 天，\(t.block.name)").font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(t.items.enumerated()), id: \.element.id) { i, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.done ? "✓" : "\(i + 1)").font(Typeface.display(13)).foregroundStyle(item.done ? Palette.ochre : Palette.ink3).frame(width: 14)
                            Text(item.kindLabel).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                            Text(item.title).font(Typeface.ui(12)).lineLimit(1)
                        }
                    }
                }
            } else {
                Text("分析服务启动中").font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
            }
            Button {
                state.openMain = state.openMain ?? { openWindow(id: "main") }
                state.requestStart()
            } label: {
                Label("开始今日练习", systemImage: "mic.fill").frame(maxWidth: .infinity)
            }
            .primaryGlass()
            HStack {
                Button("打开 Melete") { openMain() }.buttonStyle(InkButtonStyle())
                Spacer()
                Text("⌃⌥R").font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(InkButtonStyle(color: Palette.ink2))
            }
        }
        .padding(16)
        .frame(width: 300)
        .task { await state.refreshToday(quiet: true) }
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.frame.width > 400 }) { openWindow(id: "main") }
    }
}

extension Notification.Name {
    static let toggleRecording = Notification.Name("toggleRecording")
    static let newPractice = Notification.Name("newPractice")
    static let startToday = Notification.Name("startToday")
    static let openSettings = Notification.Name("openSettings")
}
