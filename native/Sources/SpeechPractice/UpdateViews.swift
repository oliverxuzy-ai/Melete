import SwiftUI
import AppKit

/// A new version, offered at the top of the window under the service line. It steps back
/// while you count down or record.
struct UpdateToast: View {
    @Environment(StageModel.self) private var stage
    @State private var notesShown = false
    private var updater: Updater { .shared }

    var body: some View {
        VStack(spacing: 0) {
            if visible {
                content.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.glass, value: key)
    }

    private var visible: Bool {
        if stage.isActive { return false }
        if updater.justUpdated != nil { return true }
        guard let m = updater.latest, updater.dismissed != m.version else { return false }
        switch updater.phase {
        case .available, .downloading, .unpacking, .ready, .installed: return updater.hasUpdate
        case .failed: return updater.hasUpdate
        default: return false
        }
    }

    /// What the capsule is showing; the download's percentage is left out so the bar moves
    /// without the capsule animating in again.
    private var key: String {
        guard visible else { return "none" }
        if let v = updater.justUpdated { return "updated \(v)" }
        if case .downloading = updater.phase { return "downloading" }
        return "\(updater.phase)"
    }

    @ViewBuilder private var content: some View {
        if let v = updater.justUpdated {
            toast {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.malachite)
                Text(L("已更新到 Melete \(v)", "Updated to Melete \(v)"))
                closeButton { updater.justUpdated = nil }
            }
        } else if let m = updater.latest {
            switch updater.phase {
            case .downloading(let p):
                toast {
                    ProgressView(value: p).progressViewStyle(.linear).frame(width: 90)
                    Text(L("正在下载 Melete \(m.version)", "Downloading Melete \(m.version)"))
                    Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(Palette.ink2)
                    Button(L("取消", "Cancel")) { updater.cancel() }.buttonStyle(InkButtonStyle(color: Palette.ink2))
                }
            case .unpacking:
                toast {
                    ProgressView().controlSize(.mini)
                    Text(L("正在核对和解压 \(m.version)", "Checking and unpacking \(m.version)"))
                }
            case .ready:
                toast {
                    Image(systemName: "checkmark.circle").foregroundStyle(Palette.kyanos)
                    Text(L("Melete \(m.version) 已就绪，重启后生效；退出时也会自动装上。", "Melete \(m.version) is ready. Restart to finish, or it goes in when you quit.")).lineLimit(2)
                    Button(L("现在重启", "Restart now")) { updater.restartNow() }
                        .buttonStyle(InkButtonStyle())
                        .disabled(updater.practiceUnderWay)
                    closeButton { updater.dismissed = m.version }
                }
            case .installed:
                toast {
                    ProgressView().controlSize(.mini)
                    Text(L("正在重启到 \(m.version)…", "Restarting into \(m.version)…"))
                }
            case .failed(let why):
                toast {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.ochre)
                    Text(L("更新没成功：", "The update didn't go through: ") + why).lineLimit(2)
                    if updater.installBlocker == nil {
                        Button(L("重试", "Try again")) { updater.update() }.buttonStyle(InkButtonStyle())
                    } else {
                        Button(L("去下载", "Download")) { NSWorkspace.shared.open(m.releaseURL ?? Updater.releasesPage) }.buttonStyle(InkButtonStyle())
                    }
                    closeButton { updater.dismissed = m.version }
                }
            default:
                toast {
                    Image(systemName: "arrow.down.circle").foregroundStyle(Palette.kyanos)
                    Text(L("Melete \(m.version) 可以更新了", "Melete \(m.version) is available"))
                    Button(L("更新内容", "What's new")) { notesShown = true }
                        .buttonStyle(InkButtonStyle(color: Palette.ink2))
                        .popover(isPresented: $notesShown, arrowEdge: .bottom) {
                            ReleaseNotes(manifest: m).padding(18).frame(width: 380)
                        }
                    UpdateButton(manifest: m)
                    closeButton { updater.dismissed = m.version }
                }
            }
        }
    }

    private func toast<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }
            .font(Typeface.ui(12)).foregroundStyle(Palette.ink)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 640)
    }

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
            .buttonStyle(InkButtonStyle(color: Palette.ink3))
            .help(L("先不更新", "Not now"))
    }
}

/// "Update and restart", or "Download" when this copy cannot be replaced where it is.
struct UpdateButton: View {
    let manifest: UpdateManifest

    var body: some View {
        if let why = Updater.shared.installBlocker {
            Button(L("去下载", "Download")) { NSWorkspace.shared.open(manifest.releaseURL ?? Updater.releasesPage) }
                .buttonStyle(InkButtonStyle())
                .help(why)
        } else {
            Button(L("更新并重启", "Update and restart")) { Updater.shared.update() }
                .buttonStyle(InkButtonStyle())
        }
    }
}

/// What changed in a version: the commit subjects CI wrote into latest.json.
struct ReleaseNotes: View {
    let manifest: UpdateManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Melete \(manifest.version)").font(Typeface.display(19)).foregroundStyle(Palette.ink)
            let notes = manifest.cleanNotes
            if notes.isEmpty {
                Text(L("这一版没有附更新说明。", "This version came without notes.")).font(Typeface.italic(14)).foregroundStyle(Palette.ink2)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(notes.prefix(12).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("·").foregroundStyle(Palette.ink3)
                            Text(line).font(Typeface.ui(13)).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let url = manifest.releaseURL {
                Button(L("在 GitHub 上看完整说明", "Full notes on GitHub")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(InkButtonStyle())
            }
        }
    }
}

/// Settings > Updates: this version, a check button, the automatic check, and a newer version
/// with its notes when there is one.
struct UpdateSettings: View {
    @AppStorage("autoCheckUpdates") private var auto = true
    private var updater: Updater { .shared }

    var body: some View {
        SettingsSection(title: L("更新", "Updates"),
                        note: L("新版本发布在 GitHub 上。检查时 Melete 只读取一个很小的版本说明文件，不发送你的任何数据。下载的新版本先核对校验和，再替换“应用程序”里的旧版本。",
                                "New versions are published on GitHub. To check, Melete reads a small file describing the latest release; nothing about you is sent. A downloaded version is checked against its published checksum before it replaces the old one in Applications.")) {
            if updater.isEnabled {
                SettingRow(title: L("当前版本", "This version"), detail: versionLine + statusLine) {
                    Button(L("检查更新", "Check now")) { Task { await updater.check(manual: true) } }
                        .buttonStyle(InkButtonStyle())
                        .disabled(busy)
                }
                SettingRow(title: L("自动检查", "Check automatically"),
                           detail: L("打开 Melete 时查一次，一直开着的话每 12 小时再查一次。有新版本时在窗口顶部提示，你点了才会装。",
                                     "Checks when Melete opens, and every 12 hours while it stays open. A new version is offered at the top of the window and goes in only when you say so."),
                           divider: updater.hasUpdate) {
                    MeleteToggle(isOn: $auto)
                }
                if updater.hasUpdate, let m = updater.latest {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 18) {
                            ReleaseNotes(manifest: m)
                            Spacer(minLength: 12)
                            action(m)
                        }
                        if case .failed(let why) = updater.phase {
                            Text(L("更新没成功：", "The update didn't go through: ") + why).font(Typeface.ui(12)).foregroundStyle(Palette.ochre)
                        } else if let why = updater.installBlocker {
                            Text(why).font(Typeface.ui(12)).foregroundStyle(Palette.ochre)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                }
            } else {
                SettingRow(title: L("当前版本", "This version"),
                           detail: versionLine + L("。这是在这台 Mac 上构建的版本，不检查更新；新版本在 GitHub 上下载。",
                                                   ". This copy was built on this Mac and doesn't check for updates; new versions are on GitHub."),
                           divider: false) {
                    Button(L("打开下载页", "Open downloads")) { NSWorkspace.shared.open(Updater.releasesPage) }
                        .buttonStyle(InkButtonStyle())
                }
            }
        }
        .onChange(of: auto) { _, on in if on { Task { await updater.check(manual: false) } } }
    }

    private var versionLine: String {
        "Melete \(AppVersion.current)" + (AppVersion.build.isEmpty ? "" : L("（\(AppVersion.build)）", " (\(AppVersion.build))"))
    }

    private var busy: Bool {
        switch updater.phase {
        case .checking, .downloading, .unpacking, .ready, .installed: return true
        default: return false
        }
    }

    private var statusLine: String {
        let stop = L("。", ". ")
        switch updater.phase {
        case .checking: return stop + L("正在检查…", "Checking…")
        case .upToDate: return stop + L("已是最新版本", "Up to date") + checkedAt
        case .failed(let why) where !updater.hasUpdate: return stop + why
        case .ready: return stop + L("新版本已经下载好，重启后生效。", "The new version is downloaded and goes in at the next restart.")
        default:
            if updater.hasUpdate, let m = updater.latest { return stop + L("有新版本 \(m.version)", "Version \(m.version) is available") }
            if let e = updater.lastError { return stop + L("上次检查没成功：", "The last check failed: ") + e }
            return ""
        }
    }

    private var checkedAt: String {
        guard let d = updater.lastChecked else { return "" }
        let t = d.formatted(date: .omitted, time: .shortened)
        return L("（\(t) 查过）", " (checked at \(t))")
    }

    @ViewBuilder private func action(_ m: UpdateManifest) -> some View {
        switch updater.phase {
        case .downloading(let p):
            HStack(spacing: 10) {
                ProgressView(value: p).progressViewStyle(.linear).frame(width: 110)
                Text("\(Int(p * 100))%").font(Typeface.ui(12)).monospacedDigit().foregroundStyle(Palette.ink2)
                Button(L("取消", "Cancel")) { updater.cancel() }.buttonStyle(InkButtonStyle(color: Palette.ink2))
            }
        case .unpacking, .installed:
            ProgressView().controlSize(.small)
        case .ready:
            Button(L("现在重启", "Restart now")) { updater.restartNow() }
                .buttonStyle(InkButtonStyle())
                .disabled(updater.practiceUnderWay)
        default:
            UpdateButton(manifest: m)
        }
    }
}
