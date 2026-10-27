import SwiftUI

/// Real talks coming up. Each one gets a prep plan counted back from the day,
/// like a taper before a race. Shown in a tray.
struct AgendaContent: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center) {
                Text(L("把要讲的场合放进来：架构评审、1:1、onsite、面试。离那天十天以内，今天的计划会换成备讲。",
                       "Add the talks you have coming up: architecture reviews, 1:1s, onsites, interviews. Within ten days of one, today's plan switches to prep."))
                    .font(Typeface.italic(14)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { Task { await state.openTray(.newEvent) } } label: { Label(L("加一场", "Add a talk"), systemImage: "plus") }.primaryGlass()
            }
            if let a = state.agenda {
                let upcoming = a.events.filter { !$0.past }
                if upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("最近没有要讲的场合。可以从这些开始：", "Nothing coming up. You could start from one of these:")).font(Typeface.ui(14)).foregroundStyle(Palette.ink2)
                        FlowLayout(spacing: 8) {
                            ForEach(a.templates, id: \.title) { t in
                                Button(t.title) {
                                    Task { await state.createEvent(["title": t.title, "kind": t.kind, "minutes": t.minutes]) }
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                }
                ForEach(upcoming) { ev in EventCard(event: ev) }
                let past = a.events.filter(\.past)
                if !past.isEmpty {
                    Text(L("已经讲过", "Already given")).font(Typeface.display(18)).foregroundStyle(Palette.ink2).padding(.top, 8)
                    ForEach(past) { ev in
                        HStack {
                            Text(ev.title).font(Typeface.ui(13)).foregroundStyle(Palette.ink2)
                            Spacer()
                            Text(shortDay(ev.date)).font(Typeface.ui(12)).foregroundStyle(Palette.ink3)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
    }
}

struct EventCard: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage
    let event: AgendaEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.daysLeft == 0 ? L("今天", "Today") : "\(event.daysLeft)")
                        .font(Typeface.display(event.daysLeft == 0 && isEnglishUI ? 30 : 48)).foregroundStyle(event.daysLeft <= 2 ? Palette.cinnabar : Palette.kyanos)
                    if event.daysLeft > 0 { Text(L("天后", event.daysLeft == 1 ? "day to go" : "days to go")).font(Typeface.ui(12)).foregroundStyle(Palette.ink2) }
                }
                .frame(width: 84, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Chip(text: event.kindLabel, style: .hedge)
                        Text(L("\(shortDay(event.date))，\(event.minutes) 分钟", "\(shortDay(event.date)), \(event.minutes) min")).font(Typeface.ui(12)).foregroundStyle(Palette.ink3)
                    }
                    Text(event.title).font(Typeface.display(22)).foregroundStyle(Palette.ink)
                    if !event.notes.isEmpty {
                        Text(event.notes).font(Typeface.ui(13)).foregroundStyle(Palette.ink2).lineLimit(3)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if let pid = event.practiceId {
                        Button(L("编辑提纲，看记录", "Edit outline, see takes")) { Task { await state.openTray(.practice(pid)) } }.buttonStyle(InkButtonStyle())
                    }
                    ConfirmButton(title: L("删除这一场", "Delete this talk"), question: L("提纲和录音会保留。", "The outline and recordings stay.")) {
                        Task { await state.deleteEvent(event.id) }
                    }
                }
            }
            PrepTimeline(steps: event.steps)
            HStack(spacing: 12) {
                if let step = event.steps.first(where: { $0.state == "today" }) ?? event.steps.first(where: { $0.state != "done" }) {
                    Button { start(step) } label: { Label(L("练这一步：", "Practice this step: ") + step.title, systemImage: "mic.fill") }.primaryGlass()
                    Text(step.detail).font(Typeface.italic(13)).foregroundStyle(Palette.ink2).lineLimit(2)
                }
            }
        }
        .padding(22)
        .paper()
    }

    private func start(_ step: PrepStep) {
        Task {
            guard let pid = event.practiceId, let p = await state.fetchPractice(pid) else { return }
            let item = PlanItem(id: step.id, kind: "agenda", practiceId: pid, promptId: nil,
                                title: L("\(event.title)：\(step.title)", "\(event.title): \(step.title)"), subtitle: event.kindLabel, prompt: nil,
                                seconds: step.key == "first" || step.key == "timed" ? event.minutes * 60 : 90,
                                detail: step.detail, sessionId: nil)
            _ = p
            state.closeTray()
            stage.present(item: item)
        }
    }
}

/// The six prep steps on a line; done ones are gilded, today's is ringed.
struct PrepTimeline: View {
    let steps: [PrepStep]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        dot(s)
                        if i < steps.count - 1 {
                            Rectangle().fill(s.state == "done" ? Palette.ochre.opacity(0.6) : Palette.vein).frame(height: 1.5)
                        }
                    }
                    Text(s.title).font(Typeface.ui(12, s.state == "today" ? .semibold : .regular))
                        .foregroundStyle(s.state == "missed" ? Palette.ink3 : Palette.ink)
                    Text(s.offset == 0 ? L("当天", "On the day") : L("前 \(s.offset) 天", "\(plural(s.offset, "day")) before")).font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func dot(_ s: PrepStep) -> some View {
        switch s.state {
        case "done": Circle().fill(Palette.ochre).frame(width: 12, height: 12)
        case "today": Circle().strokeBorder(Palette.kyanos, lineWidth: 2.5).frame(width: 14, height: 14)
        case "missed": Circle().fill(Palette.vein).frame(width: 10, height: 10)
        default: Circle().strokeBorder(Palette.vein, lineWidth: 1.5).frame(width: 12, height: 12)
        }
    }
}
