import SwiftUI

/// 今天: what to practice today and the button that starts it, on one screen. How practice is
/// going (the laurel, the trends, the record, the year) lives in the 进展 tray, opened from the
/// laurel in the top bar, from the week line here, or with ⌘4. Keeping the two apart is the
/// point: this page answers "what now?", the tray answers "how is it going?".
struct HomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            HomeContent()
                .padding(.horizontal, 36).padding(.top, 16).padding(.bottom, 36)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { await state.refreshToday(quiet: true) }
        .onChange(of: state.space) { _, s in if s == .home { Task { await state.refreshToday(quiet: true) } } }
    }
}

struct HomeContent: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let t = state.today {
                HomeHeader(today: t)
                TodayPlan(today: t).padding(.top, 14)
                WeekLine(week: t.week).padding(.top, 10)
                // Within ten days a talk takes over the plan's third slot, so it is worth a line here.
                if let ev = t.nextEvent, ev.daysLeft <= 10 { NextTalk(event: ev).padding(.top, 10) }
                Doors(today: t).padding(.top, 12)
            } else {
                HomeBooting().frame(maxWidth: .infinity, minHeight: 520)
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }
}

struct HomeBooting: View {
    @Environment(StageModel.self) private var stage

    var body: some View {
        VStack(spacing: 14) {
            Text(longDate(Date())).font(Typeface.display(34)).foregroundStyle(Palette.ink)
            Text(L("分析服务在后台启动。现在就可以录，录完会自动分析。", "The analysis service is starting in the background. You can record now; it's analyzed when you finish.")).font(Typeface.ui(14)).foregroundStyle(Palette.ink2)
            Button { stage.presentFree() } label: { Label(L("随便说一段", "Say anything"), systemImage: "mic.fill") }
                .primaryGlass()
        }
    }
}

// MARK: - Heading

/// The date, then where you are in the training cycle and why, in one sentence.
struct HomeHeader: View {
    let today: TodayPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(today.weekday).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                Text(today.block.greek).font(Typeface.italic(13)).foregroundStyle(Palette.kyanos)
                Text(L("\(today.block.name)，第 \(today.block.week ?? 1) / \(today.block.weeks) 周", "\(today.block.name), week \(today.block.week ?? 1) of \(today.block.weeks)")).font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
            }
            Text(longDate(today.date)).font(Typeface.display(30)).foregroundStyle(Palette.ink)
            Text(today.block.why).font(Typeface.italic(14)).foregroundStyle(Palette.ink2)
                .lineSpacing(2).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Today's plan

/// Today's items in order, the next one marked, and the button that starts it. Each line is a
/// way in: an open item goes on stage in its studio, a finished one opens its verdict.
struct TodayPlan: View {
    let today: TodayPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("今天的安排", "Today's plan")).font(Typeface.display(19)).foregroundStyle(Palette.ink)
                Spacer()
                if !today.items.isEmpty {
                    Text(summary).font(Typeface.ui(12)).foregroundStyle(Palette.ink3).monospacedDigit()
                }
            }
            .padding(.bottom, 8)
            if today.items.isEmpty {
                Text(L("今天没有安排。随便讲一段，也算练过。", "Nothing planned today. Say anything; it still counts."))
                    .font(Typeface.ui(13)).foregroundStyle(Palette.ink3).padding(.vertical, 10)
            }
            ForEach(Array(today.items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Hairline().padding(.leading, 34) }
                PlanRow(item: item, isNext: item.id == today.nextItem?.id)
            }
            if let status = clipStatus {
                Text(status).font(Typeface.ui(11)).foregroundStyle(Palette.ochre).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8).padding(.leading, 8)
            }
            StartBlock(today: today)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
        .paper()
    }

    private var summary: String {
        let done = today.items.filter(\.done).count
        let left = today.items.filter { !$0.done }.map(\.seconds).reduce(0, +)
        if left == 0 { return L("\(done) / \(today.items.count) 项，都练完了", "\(done) of \(today.items.count) done") }
        return L("\(done) / \(today.items.count) 项，还剩约 \(durationLabel(roundedMinutes(left)))",
                 "\(done) of \(today.items.count) done, about \(durationLabel(roundedMinutes(left))) left")
    }

    /// Whole minutes above a minute, so the total reads as an estimate.
    private func roundedMinutes(_ s: Int) -> Int { s < 60 ? s : Int((Double(s) / 60).rounded()) * 60 }

    /// Why today's clips might be missing or late.
    private var clipStatus: String? {
        switch today.daily.state {
        case "running": return today.daily.message?.isEmpty == false ? today.daily.message : L("正在准备今天的片段", "Preparing today's clips")
        case "waiting": return L("今天的片段还没准备，去跟读那边可以现在就挑", "Today's clips aren't ready yet; go to Shadowing to pick them now")
        case "failed": return L("没挑到片段：", "No clips picked: ") + (today.daily.errors.last ?? today.daily.message ?? L("原因不明", "unknown reason"))
        default: return nil
        }
    }
}

struct PlanRow: View {
    let item: PlanItem
    let isNext: Bool
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage
    @State private var hover = false

    /// A finished item's recording. A prep step done by hand carries its own id instead.
    private var verdict: String? {
        guard item.done, let sid = item.sessionId, sid != item.id else { return nil }
        return sid
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: item.done ? "checkmark.circle.fill" : (isNext ? "circle.inset.filled" : "circle"))
                    .font(.system(size: 14))
                    .foregroundStyle(item.done ? Palette.ochre : (isNext ? Palette.kyanos : Palette.ink3))
                    .frame(width: 22)
                Text(item.kindLabel).font(Typeface.ui(12, .medium))
                    .foregroundStyle(Space.of(kind: item.kind) == .shadow ? Palette.ochre : Palette.kyanos)
                    .frame(width: isEnglishUI ? 70 : 30, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(Typeface.display(15))
                        .foregroundStyle(item.done ? Palette.ink2 : Palette.ink)
                        .lineLimit(1)
                    if let second = secondLine {
                        Text(second).font(Typeface.ui(11)).foregroundStyle(Palette.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 10)
                if isNext {
                    Text(L("下一项", "Next")).font(Typeface.ui(10, .semibold)).foregroundStyle(Palette.kyanos)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Palette.kyanos.opacity(0.1), in: Capsule())
                }
                Text(verdict != nil ? L("看点评", "Verdict") : durationLabel(item.seconds))
                    .font(Typeface.ui(11)).foregroundStyle(Palette.ink3).monospacedDigit()
                    .fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hover ? Palette.kyanos : Palette.ink3)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(hover ? Palette.well.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.ticker) { hover = h } }
        .help(help)
    }

    /// The prompt itself for an impromptu talk; otherwise the clip's source or the days to a talk.
    private var secondLine: String? {
        if item.kind == "impromptu", let p = item.prompt, !p.isEmpty { return p }
        return item.subtitle.isEmpty ? nil : item.subtitle
    }

    private var help: String {
        if verdict != nil { return L("打开这一段的点评", "Open the verdict on this take") }
        return L("放上\(Space.of(kind: item.kind).label)的讲台，准备好再开始", "Put it on stage in \(Space.of(kind: item.kind).label); start when you're ready")
    }

    private func open() {
        guard !stage.isActive else { return }
        if let sid = verdict { Task { await state.openTray(.session(sid)) } }
        else { stage.present(item: item, autoStart: false) }
    }
}

// MARK: - Start

/// The same button as on stage: one press goes to the right studio and starts.
struct StartBlock: View {
    let today: TodayPayload
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage

    var body: some View {
        VStack(spacing: 8) {
            Button { stage.presentNext() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                    Text(title)
                }
                .font(Typeface.ui(15, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 30).frame(height: 46)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Palette.kyanos).interactive(), in: .capsule)
            .keyboardShortcut(state.tray == nil && state.space == .home ? .defaultAction : nil)
            Text(caption).font(Typeface.ui(12)).foregroundStyle(Palette.ink3)
        }
    }

    private var title: String {
        if today.items.isEmpty { return L("自由练一段", "Free practice") }
        return today.nextItem == nil ? L("今天都练完了，再来一段", "All done today. One more?") : L("开始下一项", "Start the next item")
    }

    private var caption: String {
        guard let n = today.nextItem else { return L("回车开始。三秒后自动录音。", "Press Return. Recording starts after three seconds.") }
        return L("回车开始\(n.kindLabel)，约 \(durationLabel(n.seconds))。三秒后自动录音。",
                 "Press Return: \(n.kindLabel.lowercased()), about \(durationLabel(n.seconds)). Recording starts after three seconds.")
    }
}

// MARK: - The week, in one line

/// Seven leaves and how many days are left this week. The whole line opens 进展.
struct WeekLine: View {
    let week: WeekInfo
    @Environment(AppState.self) private var state
    @State private var hover = false

    var body: some View {
        Button { Task { await state.openTray(.progress) } } label: {
            HStack(alignment: .center, spacing: 14) {
                LaurelWreath(days: week.laurel, target: week.target, size: 46, showCount: false)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(L("本周", "This week")).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
                        Text("\(week.done) / \(week.target)").font(Typeface.display(18)).monospacedDigit().foregroundStyle(Palette.ink)
                        Text(L("天", "days")).font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
                    }
                    Text(weekCaption(week)).font(Typeface.italic(14)).foregroundStyle(weekCaptionColor(week))
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                HStack(spacing: 6) {
                    Text(L("看进展", "Progress")).font(Typeface.ui(12, .medium)).foregroundStyle(hover ? Palette.kyanos : Palette.ink2)
                    Text("⌘4").font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hover ? Palette.kyanos : Palette.ink3)
                        .offset(x: hover ? 3 : 0)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(hover ? Palette.well.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.ticker) { hover = h } }
        .help(L("一片叶子是一天：录满 20 秒（听原文算一半）就算练过，一周 \(week.target) 天就算达标。点开看进展。",
                "One leaf is one day: 20 seconds of recording counts it (listening to an original counts half); \(week.target) days makes the week. Click for progress."))
    }
}

/// One sentence on the week so far, kind about a missed day.
func weekCaption(_ w: WeekInfo) -> String {
    if w.todayDone {
        return w.done >= w.target ? L("本周的目标已经达到。", "This week's goal is reached.")
            : L("今天练过了。还差 \(max(0, w.target - w.done)) 天。", "Done for today. \(plural(max(0, w.target - w.done), "more day")) to go.")
    }
    if let d = w.daysSince, d > 2 { return L("上次练是 \(d) 天前。今天录一段一分钟的，先把节奏接上。", "Last practice was \(d) days ago. Record one minute today to get the rhythm back.") }
    if w.missedTwo { return L("已经两天没练了。今天录一段一分钟的就行。", "Two days off now. One minute today is enough.") }
    if w.missedYesterday { return L("昨天没练。今天录一段，就不会连着断两天。", "You skipped yesterday. Record one today and it won't become two.") }
    return L("今天还没练。完成任意一项就算数。", "Not yet today. Any one item counts.")
}

func weekCaptionColor(_ w: WeekInfo) -> Color {
    if w.todayDone { return Palette.malachite }
    return w.missedYesterday ? Palette.ochre : Palette.ink2
}

// MARK: - The next talk

struct NextTalk: View {
    let event: AgendaEvent
    @Environment(AppState.self) private var state

    var body: some View {
        Button { Task { await state.openTray(.agenda) } } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.daysLeft == 0 ? L("今天", "Today") : "\(event.daysLeft)").font(Typeface.display(event.daysLeft == 0 && isEnglishUI ? 20 : 28))
                        .foregroundStyle(event.daysLeft <= 2 ? Palette.cinnabar : Palette.kyanos)
                    if event.daysLeft > 0 { Text(L("天后", event.daysLeft == 1 ? "day to go" : "days to go")).font(Typeface.ui(10)).foregroundStyle(Palette.ink3).fixedSize() }
                }
                .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("下一场，\(event.kindLabel)", "Next up, \(event.kindLabel)")).font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
                    Text(event.title).font(Typeface.display(15)).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let step = event.steps.first(where: { $0.state == "today" }) ?? event.steps.first(where: { $0.state == "upcoming" }) {
                        Text(L("\(step.state == "today" ? "今天" : shortDay(step.date))：\(step.title)", "\(step.state == "today" ? "Today" : shortDay(step.date)): \(step.title)")).font(Typeface.ui(11)).foregroundStyle(Palette.ink2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.vein))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Doors

/// The two studios as two quiet lines, each with what it holds.
struct Doors: View {
    let today: TodayPayload
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            Door(space: .shadow, shortcut: "⌘2", footer: shadowFooter,
                 help: L("跟读：先听别人怎么讲，再跟着讲或用自己的话复述", "Shadowing: hear how someone else says it, then speak along or retell it"))
            Door(space: .topic, shortcut: "⌘3", footer: topicFooter,
                 help: L("主题：围绕一个题目、讲稿或要讲的会，自己讲", "Topics: speak on your own about a prompt, a script or a talk you have coming up"))
        }
    }

    private var shadowFooter: String {
        let n = state.shadowPractices.count
        return n == 0 ? L("片段库还是空的", "No clips yet") : L("片段库 \(n) 段", plural(n, "clip"))
    }

    private var topicFooter: String {
        let scripts = state.userPractices.filter { $0.kind != "agenda" }.count
        let talks = (state.agenda?.events ?? []).filter { !$0.past }.count
        return L("讲稿 \(scripts) 份，议程 \(talks) 场", "\(plural(scripts, "script")), \(plural(talks, "talk"))")
    }
}

struct Door: View {
    let space: Space
    let shortcut: String
    let footer: String
    let help: String
    @Environment(AppState.self) private var state
    @State private var hover = false

    var body: some View {
        Button { state.go(space) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(space.label).font(Typeface.display(17)).foregroundStyle(Palette.ink).fixedSize()
                Text(space.greek).font(Typeface.italic(12)).foregroundStyle(Palette.kyanos).fixedSize()
                Text(footer).font(Typeface.ui(11)).foregroundStyle(Palette.ink3).lineLimit(1)
                Spacer(minLength: 6)
                Text(shortcut).font(Typeface.ui(11)).foregroundStyle(Palette.ink3)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hover ? Palette.kyanos : Palette.ink3)
                    .offset(x: hover ? 3 : 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .strokeBorder(hover ? Palette.kyanos.opacity(0.5) : Palette.vein, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.ticker) { hover = h } }
        .help(help)
    }
}
