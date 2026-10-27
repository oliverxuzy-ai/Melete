import SwiftUI

/// The daily clips: what was picked, from where, and what to listen for. Shown in a tray.
struct ClipsContent: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage

    private var grouped: [(String, [PracticeListItem])] {
        let clips = state.clipPractices.sorted { ($0.clip?.date ?? $0.createdAt) > ($1.clip?.date ?? $1.createdAt) }
        var order: [String] = []
        var by: [String: [PracticeListItem]] = [:]
        for c in clips {
            let d = c.clip?.date ?? String(c.createdAt.prefix(10))
            if by[d] == nil { order.append(d) }
            by[d, default: []].append(c)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .center) {
                Text("讲故事的用来跟读，讲道理的用来复述。").font(Typeface.italic(14)).foregroundStyle(Palette.ink2)
                Spacer()
                statusControl
            }
            if grouped.isEmpty {
                EmptyState(title: "还没有片段",
                           message: "片段每天清晨自动准备，需要本机装有 yt-dlp 和 ffmpeg。也可以贴一个 YouTube 链接，马上做成片段。",
                           actionTitle: "现在就挑今天的") { Task { await state.refreshClips(force: false) } }
            }
            ForEach(grouped, id: \.0) { day, items in
                VStack(alignment: .leading, spacing: 12) {
                    Text(dayTitle(day)).font(Typeface.display(20)).foregroundStyle(Palette.ink)
                    ForEach(items) { c in ClipRow(clip: c) }
                }
            }
            if !state.importedClips.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("自己导入的").font(Typeface.display(20)).foregroundStyle(Palette.ink)
                    ForEach(state.importedClips.sorted { ($0.lastAt ?? $0.createdAt) > ($1.lastAt ?? $1.createdAt) }) { c in ClipRow(clip: c) }
                }
            }
        }
    }

    @ViewBuilder private var statusControl: some View {
        let st = state.daily?.status
        HStack(spacing: 12) {
            if st?.state == "running" {
                ProgressView().controlSize(.small)
                Text(st?.message ?? "").font(Typeface.ui(12)).foregroundStyle(Palette.ink2).lineLimit(1)
            } else if let tools = state.daily?.tools, tools.ytDlp == nil || tools.ffmpeg == nil {
                Text("缺少 \(tools.ytDlp == nil ? "yt-dlp " : "")\(tools.ffmpeg == nil ? "ffmpeg" : "")").font(Typeface.ui(12)).foregroundStyle(Palette.cinnabar)
            }
            Button("重新挑今天的") { Task { await state.refreshClips(force: true) } }
                .buttonStyle(.glass)
                .disabled(st?.state == "running")
        }
    }

    private func dayTitle(_ iso: String) -> String {
        let rel = relativeDay(iso)
        return rel == "今天" || rel == "昨天" ? "\(rel)，\(chineseDate(iso))" : chineseDate(iso)
    }
}

struct ClipRow: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage
    let clip: PracticeListItem
    @State private var notes: String?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Chip(text: clip.clip?.role == "explain" ? "复述" : "跟读")
                    if let d = clip.refDuration { Text(durationLabel(Int(d.rounded()))).font(Typeface.ui(12)).foregroundStyle(Palette.ink3) }
                    if let w = clip.refWpm { Text("\(Int(w)) 词/分").font(Typeface.ui(12)).foregroundStyle(Palette.ink3) }
                    if clip.clip?.pickedBy == "claude" { Text("Claude 挑选").font(Typeface.ui(11)).foregroundStyle(Palette.ochre) }
                }
                Text(clip.title).font(Typeface.display(19)).foregroundStyle(Palette.ink).lineLimit(2)
                if let ch = clip.clip?.channel, !ch.isEmpty {
                    Text(clip.clip?.start.map { "\(ch)，从 \(formatClock($0)) 开始" } ?? ch)
                        .font(Typeface.ui(12)).foregroundStyle(Palette.ink2).lineLimit(1)
                }
                if let n = notes, !n.isEmpty {
                    Text(n).font(Typeface.italic(13)).foregroundStyle(Palette.ink2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                if clip.sessionCount > 0 {
                    Text("练过 \(clip.sessionCount) 遍").font(Typeface.ui(12)).foregroundStyle(Palette.malachite)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Button(clip.clip?.role == "explain" ? "听完复述" : "跟读") {
                    Task {
                        if let p = await state.fetchPractice(clip.id) {
                            state.closeTray()
                            stage.present(practice: p, mode: clip.clip?.role == "explain" ? .retell : .shadow)
                        }
                    }
                }
                .primaryGlass()
                Button("原文和记录") { Task { await state.openTray(.practice(clip.id)) } }.buttonStyle(InkButtonStyle())
                if let s = clip.clip?.url, let url = URL(string: s) {
                    Link("看原视频", destination: url).font(Typeface.ui(12)).foregroundStyle(Palette.kyanos)
                }
            }
        }
        .padding(18)
        .paper()
        .task(id: clip.id) {
            if notes == nil { notes = await state.fetchPractice(clip.id)?.notes }
        }
    }
}
