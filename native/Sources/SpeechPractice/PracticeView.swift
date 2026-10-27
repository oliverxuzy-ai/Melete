import SwiftUI

/// Editable header of a practice: title, scenario, script, notes.
/// A daily clip shows where it came from and what to listen for instead.
struct PracticeHeaderView: View {
    @Environment(AppState.self) private var state
    @State private var title = ""
    @State private var scenario = Scenario.presentation
    @State private var script = ""
    @State private var notes = ""
    @State private var scriptExpanded = true

    private var dirty: Bool {
        guard let p = state.practice else { return false }
        return title != p.title || scenario.rawValue != p.scenario || script != p.script || notes != p.notes
    }

    var body: some View {
        if let p = state.practice {
            VStack(alignment: .leading, spacing: 14) {
                TextField("练习标题", text: $title)
                    .textFieldStyle(.plain)
                    .font(Typeface.display(30))
                    .foregroundStyle(Palette.ink)
                if p.isClip { clipInfo(p) } else { meta(p) }
                DisclosureGroup(isExpanded: $scriptExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: $script)
                            .font(Typeface.ui(14))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 120, maxHeight: 260)
                            .paper(radius: Radius.tile, fill: Palette.marble)
                        if !p.isClip {
                            TextField("这个练习的目标或注意点", text: $notes).textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text(p.isClip ? "原文（转写）" : (script.isEmpty ? "原文（还没有，填上后可以算要点覆盖）" : "原文"))
                        .font(Typeface.ui(13, .medium)).foregroundStyle(Palette.ink2)
                }
                HStack(spacing: 12) {
                    Button("保存") { Task { await state.savePractice(title: title, scenario: scenario.rawValue, script: script, notes: notes) } }
                        .primaryGlass().disabled(!dirty).opacity(dirty ? 1 : 0.5)
                    if dirty { Text("有未保存的修改").font(Typeface.ui(12)).foregroundStyle(Palette.ink2) }
                    Spacer()
                    ConfirmButton(title: "删除练习", question: "里面的 \(p.sessions.count) 条录音会保留，变成未分组。", confirm: "删除练习") {
                        Task { await state.deletePractice() }
                    }
                }
                Text("改了原文以后，这个练习下所有录音的要点覆盖会重新计算。删除练习不会删录音。")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
            }
            .padding(22)
            .paper()
            .onChange(of: p.id, initial: true) { _, _ in load(p) }
            .onChange(of: p.updatedAt) { _, _ in if !dirty || title == p.title { load(p) } }
        }
    }

    private func meta(_ p: Practice) -> some View {
        HStack(spacing: 14) {
            Picker("场景", selection: $scenario) { ForEach(Scenario.allCases) { Text($0.label).tag($0) } }
                .labelsHidden().frame(width: 150)
            Text("要点 \(p.points.count) 个，术语 \(p.terms.count) 个，建于 \(shortDay(p.createdAt))")
                .font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
        }
    }

    private func clipInfo(_ p: Practice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let c = p.clip {
                    Text([c.channel, c.start.map { "从 \(formatClock($0)) 开始" }].compactMap { $0 }.joined(separator: "，"))
                        .font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
                    if let s = c.url, let url = URL(string: s) {
                        Link("看原视频", destination: url).font(Typeface.ui(12)).foregroundStyle(Palette.kyanos)
                    }
                    if c.pickedBy == "claude" { Text("Claude 挑选").font(Typeface.ui(11)).foregroundStyle(Palette.ochre) }
                }
            }
            if !p.notes.isEmpty {
                Text(p.notes).font(Typeface.italic(14)).foregroundStyle(Palette.ink).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.ochre.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            }
        }
    }

    private func load(_ p: Practice) {
        title = p.title; scenario = Scenario(rawValue: p.scenario) ?? .other; script = p.script; notes = p.notes
        scriptExpanded = !p.isClip
    }
}
