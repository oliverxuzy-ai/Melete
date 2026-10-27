import SwiftUI
import AVFoundation

/// A metric: small label, a numeral set in Iowan, an optional unit and note.
struct Tile: View {
    let value: String
    var unit: String = ""
    let label: String
    var note: String = ""
    /// Paints the numeral when it means something (inside the target, for example).
    var tone: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Typeface.display(27)).foregroundStyle(tone ?? Palette.ink).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(Typeface.ui(12)).foregroundStyle(Palette.ink2) }
            }
            if !note.isEmpty {
                Text(note).font(Typeface.ui(11)).foregroundStyle(Palette.ink3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .paper(radius: Radius.tile)
    }
}

let tileColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

struct Chip: View {
    enum Style { case plain, good, bad, filler, hedge }
    let text: String
    var style: Style = .plain

    var body: some View {
        Text(text)
            .font(Typeface.ui(12, .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch style {
        case .plain: return Palette.ink2
        case .good: return Palette.malachite
        case .bad: return Palette.cinnabar
        case .filler: return Palette.ochre
        case .hedge: return Palette.kyanos
        }
    }

    private var background: Color {
        switch style {
        case .plain: return Palette.ink.opacity(0.06)
        case .good: return Palette.malachite.opacity(0.14)
        case .bad: return Palette.cinnabar.opacity(0.12)
        case .filler: return Palette.ochre.opacity(0.18)
        case .hedge: return Palette.kyanos.opacity(0.12)
        }
    }
}

/// Wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    /// As wide as its widest row, so a short row of chips hugs whatever it is aligned to.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

/// A titled sheet of paper. The title is set in Iowan; content sits on the raised surface.
struct SectionCard<Content: View>: View {
    let title: String
    var trailing: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(Typeface.display(19)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                if !trailing.isEmpty {
                    Text(trailing).font(Typeface.ui(12)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.middle)
                }
            }
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .paper()
    }
}

/// Minimal audio player (play/pause, scrubber, time) used for session playback.
@Observable
@MainActor
final class PlayerModel {
    var player: AVPlayer?
    var time: Double = 0
    var duration: Double = 0
    var playing = false
    var rate: Float = 1
    enum ListenTarget { case reference(String), session(String) }
    var listenTarget: ListenTarget?
    /// Called on every playback tick with the wall-clock seconds and media seconds played since the last tick.
    var listenHandler: ((Double, Double, Float) -> Void)?
    var flushHandler: (() -> Void)?
    /// Fires once when playback reaches the end (used to move a drill to its next step).
    var onFinish: (() -> Void)?
    private var observer: Any?
    private var lastTick: Date?
    private var currentURL: URL?
    private var watchdog: Task<Void, Never>?

    /// Silences every player (end to end tests run without sound).
    static var muted = false
    /// Plays without sound, keeping time: shadowing on speakers, where the microphone would
    /// otherwise record the clip along with you.
    private(set) var silenced = false

    func setSilenced(_ s: Bool) {
        guard s != silenced else { return }
        silenced = s
        player?.volume = PlayerModel.muted || s ? 0 : 1
    }

    func load(_ url: URL) {
        stop()
        currentURL = url
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        let p = AVPlayer(playerItem: item)
        p.volume = PlayerModel.muted || silenced ? 0 : 1
        player = p
        Task { [weak self] in
            if let d = try? await item.asset.load(.duration).seconds, d.isFinite { await MainActor.run { self?.duration = d } }
        }
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                // Assign only what changed: an @Observable property notifies on every set, and
                // views that show `playing` would otherwise redraw ten times a second.
                self.time = t.seconds
                if let d = self.player?.currentItem?.duration.seconds, d.isFinite, d != self.duration { self.duration = d }
                let isPlaying = (self.player?.rate ?? 0) > 0
                if isPlaying != self.playing { self.playing = isPlaying }
                let now = Date()
                // A silent take on speakers only keeps time for the subtitles; it is not listening.
                if isPlaying, !self.silenced, let last = self.lastTick {
                    let wall = min(now.timeIntervalSince(last), 0.5)   // a stall or a long seek never counts as listening
                    self.listenHandler?(wall, wall * Double(self.rate), self.rate)
                }
                self.lastTick = isPlaying ? now : nil
            }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.playing = false; self?.lastTick = nil; self?.flushHandler?(); self?.onFinish?() }
        }
    }

    func toggle() {
        guard let player else { return }
        if playing { player.pause(); playing = false; lastTick = nil; flushHandler?() }
        else {
            if duration > 0, time >= duration - 0.05 { player.seek(to: .zero) }
            player.rate = rate; playing = true
        }
    }

    /// Plays, and checks once that it really started: now and then an item never begins, so
    /// if the time has not moved after a moment, the same audio is loaded again from there.
    func play() {
        if !playing { toggle() }
        watchdog?.cancel()
        let from = time
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, self.playing, abs(self.time - from) < 0.05, let url = self.currentURL else { return }
            let r = self.rate
            self.load(url)
            self.setRate(r)
            self.seek(to: from)
            self.toggle()
        }
    }
    func pause() { if playing { toggle() } }

    func seek(to seconds: Double, andPlay: Bool = false) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds   // the subtitles follow at once, not on the next tick
        if andPlay { player.rate = rate; playing = true }
    }

    func setRate(_ r: Float) {
        rate = r
        if playing { player?.rate = r }
    }

    func stop() {
        watchdog?.cancel()
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause(); player = nil; playing = false; time = 0; duration = 0; lastTick = nil
        flushHandler?()
    }
}

/// Play button, scrubber and times on a glass capsule.
struct PlayerBar: View {
    @Bindable var model: PlayerModel
    var tint: Color = Palette.kyanos

    var body: some View {
        HStack(spacing: 12) {
            Button { model.toggle() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(model.playing ? L("暂停", "Pause") : L("播放", "Play"))
            Text(formatClock(model.time)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.ink2)
            Scrubber(value: Binding(get: { model.time }, set: { model.seek(to: $0) }), total: max(model.duration, 0.01), tint: tint)
            Text(formatClock(model.duration)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.ink2)
        }
        .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}

/// A thin track that follows the pointer exactly while dragging.
struct Scrubber: View {
    @Binding var value: Double
    let total: Double
    var tint: Color = Palette.kyanos
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let frac = CGFloat(min(max(value / total, 0), 1))
            let knob: CGFloat = dragging ? 14 : 10
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.well).frame(height: 4)
                Capsule().fill(tint).frame(width: max(4, w * frac), height: 4)
                Circle().fill(Palette.raised)
                    .overlay(Circle().strokeBorder(tint, lineWidth: 2))
                    .frame(width: knob, height: knob)
                    .offset(x: w * frac - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in dragging = true; value = Double(min(max(g.location.x / w, 0), 1)) * total }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 22)
        .animation(Motion.ticker, value: dragging)
    }
}
