import SwiftUI

// MARK: - Numbers

/// A number whose digits roll like an odometer; only the digits that change move.
struct RollingNumber: View {
    let value: Double
    var font: Font = Typeface.display(40)
    var color: Color = Palette.ink
    var format: (Double) -> String = { String(Int($0.rounded())) }

    var body: some View {
        Text(format(value))
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.numericText(value: value))
            .animation(Motion.ticker, value: value)
    }
}

// MARK: - Page header

struct PageHeader: View {
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Typeface.display(34)).tracking(-0.3).foregroundStyle(Palette.ink)
            if !subtitle.isEmpty {
                Text(subtitle).font(Typeface.ui(13)).foregroundStyle(Palette.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What an empty page says: what is missing and the one thing to do about it.
struct EmptyState: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Typeface.display(20)).foregroundStyle(Palette.ink)
            Text(message).font(Typeface.ui(13)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).primaryGlass().padding(.top, 4)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.vertical, 28)
    }
}

// MARK: - Step progress

/// Dots for a sequence; the current step stretches into a bar that fills while it runs.
struct StepDots: View {
    let count: Int
    let current: Int
    var progress: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                let isCurrent = i == current
                Capsule()
                    .fill(i < current ? Palette.kyanos : Palette.vein)
                    .overlay(alignment: .leading) {
                        if isCurrent {
                            GeometryReader { g in
                                Capsule().fill(Palette.kyanos).frame(width: max(7, g.size.width * min(max(progress, 0), 1)))
                            }
                        }
                    }
                    .frame(width: isCurrent ? 30 : 7, height: 7)
            }
        }
        .animation(Motion.glass, value: current)
        .accessibilityElement()
        .accessibilityLabel(L("第 \(min(current + 1, count)) 步，共 \(count) 步", "Step \(min(current + 1, count)) of \(count)"))
    }
}

// MARK: - Laurel wreath (weekly practice)

/// A laurel crown that grows from the tie at the bottom: one pair of leaves per weekday,
/// Monday lowest. Gilded leaves are days you practiced.
struct LaurelWreath: View {
    enum Day: Equatable { case done, missed, today, future }
    let days: [Day]
    var target: Int = 5
    var size: CGFloat = 132
    var showCount = true

    private var doneCount: Int { days.filter { $0 == .done }.count }

    var body: some View {
        ZStack {
            stems
            ForEach(Array(days.prefix(7).enumerated()), id: \.offset) { i, d in
                leaf(i, d, left: true)
                leaf(i, d, left: false)
            }
            if showCount {
                VStack(spacing: 0) {
                    RollingNumber(value: Double(doneCount), font: Typeface.display(size * 0.3))
                    Text(L("本周目标 \(target) 天", "Goal: \(plural(target, "day"))")).font(Typeface.ui(max(9, size * 0.08))).foregroundStyle(Palette.ink2)
                }
                .offset(y: size * 0.02)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(L("本周练了 \(doneCount) 天，目标 \(target) 天", "Practiced \(plural(doneCount, "day")) this week, goal \(target)"))
    }

    private var radius: CGFloat { size * 0.40 }

    private func angle(_ i: Int) -> Double { 24 + Double(i) * 19 }   // degrees up from the bottom

    private func point(_ i: Int, left: Bool) -> CGPoint {
        let a = angle(i) * .pi / 180
        let x = CGFloat(sin(a)) * radius * (left ? -1 : 1)
        let y = CGFloat(cos(a)) * radius
        return CGPoint(x: x, y: y)
    }

    private func leaf(_ i: Int, _ d: Day, left: Bool) -> some View {
        let p = point(i, left: left)
        let base = angle(i) - 90
        let rot = left ? base - 26 : -base + 26
        let w = size * 0.085, h = size * 0.2
        return LeafShape()
            .fill(fill(d))
            .overlay(LeafShape().stroke(stroke(d), lineWidth: d == .done ? 0 : 1))
            .frame(width: w, height: h)
            .scaleEffect(d == .done ? 1 : 0.92)
            .rotationEffect(.degrees(rot))
            .offset(x: p.x, y: p.y)
            .animation(Motion.leaf, value: d)
    }

    private var stems: some View {
        Canvas { gc, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            for left in [true, false] {
                var path = Path()
                path.addArc(center: c, radius: radius * 0.93,
                            startAngle: .degrees(left ? 90 + 12 : 90 - 12),
                            endAngle: .degrees(left ? 90 + 150 : 90 - 150),
                            clockwise: !left)
                gc.stroke(path, with: .color(Palette.ink.opacity(0.18)), lineWidth: 1.2)
            }
        }
    }

    private func fill(_ d: Day) -> AnyShapeStyle {
        switch d {
        case .done: return AnyShapeStyle(LinearGradient(colors: [Palette.ochre.opacity(0.75), Palette.ochre], startPoint: .top, endPoint: .bottom))
        case .missed: return AnyShapeStyle(Palette.ink.opacity(0.13))
        case .today: return AnyShapeStyle(Palette.kyanos.opacity(0.08))
        case .future: return AnyShapeStyle(Color.clear)
        }
    }

    private func stroke(_ d: Day) -> Color {
        switch d {
        case .done: return .clear
        case .missed: return .clear
        case .today: return Palette.kyanos.opacity(0.7)
        case .future: return Palette.ink.opacity(0.22)
        }
    }
}

// MARK: - Voice orb (the klepsydra)

/// Eases a value toward a target in real time (exponential follower), so frame rate and
/// update rate never show up as steps.
final class Follower {
    private var value: Double?
    private var last: Date?

    func next(_ target: Double, at t: Date, speed: Double) -> Double {
        guard let v = value, let l = last else { value = target; last = t; return target }
        let dt = min(0.1, max(0, t.timeIntervalSince(l)))
        last = t
        let nv = v + (target - v) * (1 - exp(-speed * dt))
        value = nv
        return nv
    }
}

/// The speaking stage's centrepiece. Athenian courts timed speeches with a water clock;
/// here the water is the time you have left and your voice raises waves on it.
///
/// Everything moves inside one display-synced timeline: the level is read from the audio
/// meter each frame and the water level is computed from the clock each frame, so nothing
/// steps and speaking never re-renders the page around it. The halo is a fixed ring that only
/// turns, swells and fades, and the water is drawn on the GPU (`drawingGroup`): repainting a
/// moving conic gradient on the CPU every frame is what used to stall the main thread.
struct VoiceOrb: View {
    /// Live voice level, 0...1, read every frame.
    var level: () -> Double
    /// Water left (0...1) at a moment in time; nil keeps the vessel full.
    var remaining: (Date) -> Double?
    var live: Bool
    /// False while the studio waits behind the overview: nothing to draw, so the clock stops.
    var visible = true
    var size: CGFloat = 240
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.renderClock) private var renderClock
    @State private var levelFollower = Follower()
    @State private var waterFollower = Follower()

    var body: some View {
        // Always the display's full rate: changing the schedule mid-flight does not always take,
        // and the countdown is the one moment that must never stutter.
        TimelineView(.animation(paused: !visible || (reduceMotion && !live))) { ctx in
            let t = renderClock ?? ctx.date
            let _ = FrameProbe.mark()
            let lv = levelFollower.next(live ? level() : 0, at: t, speed: 16)
            let rem = waterFollower.next(remaining(t) ?? 1, at: t, speed: 5)
            ZStack {
                halo(t: t.timeIntervalSinceReferenceDate, level: lv)
                Circle()
                    .fill(RadialGradient(colors: [Palette.raised, Palette.well], center: .init(x: 0.42, y: 0.35),
                                         startRadius: 4, endRadius: size * 0.62))
                    .frame(width: size, height: size)
                water(t: t.timeIntervalSinceReferenceDate, level: lv, remaining: rem)
                    .frame(width: size - 14, height: size - 14)
                    .clipShape(Circle())
                    .drawingGroup()
                rim
            }
        }
        // Lays out at 1.25 times the vessel; the halo is drawn past that edge, which frames
        // do not clip, so the stage keeps its width in a narrow window.
        .frame(width: size * 1.25, height: size * 1.25)
        .accessibilityHidden(true)
    }

    /// A ring of light around the rim. The ring itself never changes; it turns, swells and
    /// brightens with your voice.
    private func halo(t: Double, level: Double) -> some View {
        Circle()
            .stroke(AngularGradient(colors: [Palette.kyanos, Palette.ochre, Palette.malachite, Palette.kyanos], center: .center),
                    lineWidth: size * 0.12)
            .frame(width: size * 1.02, height: size * 1.02)
            .blur(radius: size * 0.09)
            .rotationEffect(.degrees(live ? (t * 24).truncatingRemainder(dividingBy: 360) : 0))
            .scaleEffect(1 + 0.08 * level)
            .opacity(live ? 0.3 + 0.55 * level : 0.14)
    }

    private func water(t: Double, level: Double, remaining: Double) -> some View {
        Canvas { gc, sz in
            let fill = CGFloat(min(max(remaining, 0), 1))
            let surface = sz.height * (1 - fill) + 4
            let amp = 2.5 + CGFloat(level) * sz.height * 0.075
            func wavePath(phase: Double, freq: Double, scale: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: sz.height))
                var x: CGFloat = 0
                while x <= sz.width {
                    let u = Double(x / sz.width)
                    let y = surface
                        + CGFloat(sin(u * .pi * 2 * freq + phase)) * amp * scale
                        + CGFloat(sin(u * .pi * 2 * freq * 2.3 - phase * 1.4)) * amp * scale * 0.3
                    p.addLine(to: CGPoint(x: x, y: y))
                    x += 2
                }
                p.addLine(to: CGPoint(x: sz.width, y: sz.height))
                p.closeSubpath()
                return p
            }
            let back = wavePath(phase: t * 1.6 + 1.2, freq: 1.1, scale: 0.8)
            gc.fill(back, with: .color(Palette.kyanos.opacity(0.35)))
            let front = wavePath(phase: t * 2.2, freq: 1.4, scale: 1)
            gc.fill(front, with: .linearGradient(Gradient(colors: [Palette.kyanos.opacity(0.78), Palette.kyanos]),
                                                 startPoint: CGPoint(x: 0, y: surface), endPoint: CGPoint(x: 0, y: sz.height)))
        }
    }

    /// A glass rim drawn as light, not as a live Liquid Glass layer over moving water.
    private var rim: some View {
        ZStack {
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.12), .white.opacity(0.35)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                .frame(width: size, height: size)
            Circle()
                .trim(from: 0.58, to: 0.82)
                .stroke(LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.65), .white.opacity(0.0)], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: size - 22, height: size - 22)
        }
    }
}

// MARK: - Pace gauge

/// Where your pace sits against the target band. The gilded tick is the reference speaker.
struct PaceGauge: View {
    let wpm: Double?
    let band: ClosedRange<Double>
    var reference: Double? = nil
    var scale: ClosedRange<Double> = 80...220

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { v in
                CGFloat((min(max(v, scale.lowerBound), scale.upperBound) - scale.lowerBound) / (scale.upperBound - scale.lowerBound)) * w
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.well).frame(height: 6)
                Capsule().fill(Palette.malachite.opacity(0.4))
                    .frame(width: max(6, x(band.upperBound) - x(band.lowerBound)), height: 6)
                    .offset(x: x(band.lowerBound))
                if let reference {
                    Capsule().fill(Palette.ochre).frame(width: 3, height: 14).offset(x: x(reference) - 1.5)
                }
                if let wpm, wpm > 0 {
                    Capsule().fill(Palette.ink).frame(width: 3, height: 22).offset(x: x(wpm) - 1.5)
                        .animation(Motion.ticker, value: wpm)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel(wpm.map { L("语速 \(Int($0))，目标 \(Int(band.lowerBound)) 到 \(Int(band.upperBound))", "Pace \(Int($0)), target \(Int(band.lowerBound))–\(Int(band.upperBound))") }
                            ?? L("目标语速 \(Int(band.lowerBound)) 到 \(Int(band.upperBound))", "Target pace \(Int(band.lowerBound))–\(Int(band.upperBound))"))
    }
}

// MARK: - Hold to commit

/// A button you hold until it fills. Used once a week to commit to the plan.
struct HoldToCommit: View {
    let title: String
    var duration: Double = 1.1
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var holding = false

    var body: some View {
        Text(title)
            .font(Typeface.ui(13, .semibold))
            .foregroundStyle(progress >= 1 ? .white : Palette.kyanos)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.kyanos.opacity(0.1))
                        Capsule().fill(Palette.kyanos).frame(width: g.size.width * progress)
                    }
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: duration, maximumDistance: 30) {
                action()
            } onPressingChanged: { pressing in
                holding = pressing
                withAnimation(pressing ? .linear(duration: duration) : Motion.stone) { progress = pressing ? 1 : 0 }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

// MARK: - Render mode

private struct RenderModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while the design-review harness draws views offscreen, where Liquid Glass has no backdrop.
    var renderMode: Bool {
        get { self[RenderModeKey.self] }
        set { self[RenderModeKey.self] = newValue }
    }

    /// The moment the harness draws, when it draws the frames of an animation; nil follows the
    /// display.
    var renderClock: Date? {
        get { self[RenderClockKey.self] }
        set { self[RenderClockKey.self] = newValue }
    }

    /// Where the harness has scrolled the subtitles to: a line index, between two lines while
    /// they move. Nil centres the active line.
    var renderLine: Double? {
        get { self[RenderLineKey.self] }
        set { self[RenderLineKey.self] = newValue }
    }
}

private struct RenderClockKey: EnvironmentKey { static let defaultValue: Date? = nil }
private struct RenderLineKey: EnvironmentKey { static let defaultValue: Double? = nil }

