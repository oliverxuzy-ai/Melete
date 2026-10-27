import SwiftUI
import AppKit

/// One window, three places. A glass capsule at the top switches between the overview and
/// the two studios; everything else (a recording's analysis, a script, settings) rises from
/// the bottom as a tray over the place you are in, so you never lose where you were.
///
/// The top bar is drawn in the window's own content, level with the traffic lights. It used to
/// live in the system toolbar, but SwiftUI views in a toolbar that change with the app's state
/// could stop the whole window from redrawing.
struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage
    @Environment(\.openWindow) private var openWindow
    @State private var chrome = WindowChrome()

    var body: some View {
        ZStack(alignment: .top) {
            Palette.marble.ignoresSafeArea()
            // Both places stay mounted; moving between them only changes which one shows.
            // Swapping whole studios in and out could leave the window unable to redraw.
            let _ = FrameProbe.drawnSpace = state.space.rawValue
            ZStack {
                HomeView()
                    .opacity(state.space == .home ? 1 : 0)
                    .allowsHitTesting(state.space == .home)
                    .accessibilityHidden(state.space != .home || state.tray != nil)
                StudioView()
                    .opacity(state.space == .home ? 0 : 1)
                    .allowsHitTesting(state.space != .home)
                    .accessibilityHidden(state.space == .home || state.tray != nil)
            }
            .animation(Motion.paper, value: state.space)
            .padding(.top, chrome.barHeight + 6)
            ServerToast().padding(.top, chrome.barHeight)
            TrayHost(topInset: chrome.barHeight)
            TopBarView(chrome: chrome)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(ChromeReader { chrome = $0 })
        .tint(Palette.kyanos)
        .alert(L("出错了", "Something went wrong"), isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button(L("好", "OK")) {}
        } message: { Text(state.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .newPractice)) { _ in
            guard !stage.isActive else { return }
            Task { await state.openTray(.newTopic) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            guard !stage.isActive else { return }
            Task { await state.openTray(.settings) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRecording)) { _ in
            // ⌘R: in a studio, start or stop what is on its stage; on the overview, today's next item.
            if state.space != .home, stage.studio == state.space, stage.hasMaterial {
                if state.tray != nil { state.closeTray() }
                stage.start("menu")
            } else if !stage.isActive {
                state.closeTray()
                stage.presentNext()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startToday)) { _ in
            NSApp.activate(ignoringOtherApps: true)
            guard !stage.isActive else { return }
            state.closeTray()
            stage.presentNext()
        }
        .onChange(of: state.server.status) { _, s in
            if s == .ready { Task { await state.flushPending() } }
        }
        .onAppear {
            state.openMain = { openWindow(id: "main") }
            guard state.pendingStart else { return }
            state.pendingStart = false
            Task {
                // Started from the shortcut with no window: wait for today's plan, then go.
                for _ in 0..<50 where state.today == nil { try? await Task.sleep(for: .milliseconds(100)) }
                if !stage.isActive { stage.presentNext() }
            }
        }
        .onDisappear {
            // The window closed. A recording keeps what was said; anything else steps back.
            // While quitting, the app delegate saves the recording instead.
            guard !AppDelegate.quitting else { return }
            if stage.phase == .recording {
                CaptureLog.write("window closed while recording")
                Task { await stage.stopRecording() }
            } else { stage.cancel() }
        }
    }
}

// MARK: - Window chrome

/// Where the window's traffic lights sit, so the top bar can sit clear of them.
struct WindowChrome: Equatable {
    var lightsCenterY: CGFloat = 16
    var lightsTrailingX: CGFloat = 69
    /// The bar's row sits below the traffic lights rather than beside them, so the switch
    /// reads as part of the page, not the window frame.
    var rowHeight: CGFloat { 32 }
    var rowTop: CGFloat { lightsCenterY + 8 }
    var barHeight: CGFloat { rowTop + rowHeight + 10 }
}

/// Reads the traffic lights' position once the view is in a window.
struct ChromeReader: NSViewRepresentable {
    let onChange: (WindowChrome) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = ReaderView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: ((WindowChrome) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        func measure() {
            guard let window, let close = window.standardWindowButton(.closeButton),
                  let zoom = window.standardWindowButton(.zoomButton) else { return }
            let c = close.convert(close.bounds, to: nil)
            let z = zoom.convert(zoom.bounds, to: nil)
            onChange?(WindowChrome(lightsCenterY: window.frame.height - c.midY, lightsTrailingX: z.maxX))
        }
    }
}

// MARK: - Top bar

/// The bar across the top: the wordmark after the traffic lights, the three places in the
/// middle of the window, this week and settings on the right.
struct TopBarView: View {
    let chrome: WindowChrome

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Wordmark()
                Spacer(minLength: 12)
                TopBarTrailing()
            }
            .padding(.horizontal, 36)   // the same margins as the page below
            NavCapsule()
        }
        .frame(height: chrome.rowHeight)
        .padding(.top, chrome.rowTop)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

struct Wordmark: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Melete").font(Typeface.display(15)).foregroundStyle(Palette.ink2)
            Text(Greek.melete).font(Typeface.italic(13)).foregroundStyle(Palette.ink3)
        }
        .opacity(stage.isActive ? 0.35 : 1)
        .animation(Motion.paper, value: stage.isActive)
        .accessibilityHidden(true)
    }
}

/// 总览, 跟读, 主题. The blue puck slides to where you are; a gold dot marks a studio that
/// still has something left for today.
struct NavCapsule: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Space.allCases) { s in
                Button { state.closeTray(); state.go(s) } label: { segment(s) }
                    .buttonStyle(.plain)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { FrameProbe.navFrames[s.rawValue] = $0 }
                    .matchedGeometryEffect(id: s, in: ns)
                    .help(help(s))
            }
        }
        // One puck that takes the selected segment's frame. Inserting a puck into each newly
        // selected segment instead puts two views in the same matched group at once, which
        // SwiftUI flags as invalid.
        .background {
            Capsule().fill(Palette.kyanos)
                .matchedGeometryEffect(id: state.space, in: ns, isSource: false)
        }
        .padding(2)
        .glassEffect(.regular, in: Capsule())
        .animation(Motion.glass, value: state.space)
        .opacity(stage.isActive ? 0.3 : 1)
        .disabled(stage.isActive)   // not only the mouse: VoiceOver and keyboard too
        .animation(Motion.paper, value: stage.isActive)
    }

    private func segment(_ s: Space) -> some View {
        let on = state.space == s
        return HStack(spacing: 6) {
            Text(s.label).font(Typeface.ui(13, on ? .semibold : .medium))
            Circle().fill(on ? Color.white.opacity(0.9) : Palette.ochre)
                .frame(width: 5, height: 5)
                .opacity(left(s) > 0 ? 1 : 0)
        }
        .foregroundStyle(on ? Color.white : Palette.ink2)
        .padding(.leading, 16).padding(.trailing, 11)
        .frame(height: 28)
        .contentShape(Capsule())
    }

    private func left(_ s: Space) -> Int {
        guard s != .home else { return 0 }
        return (state.today?.items ?? []).filter { !$0.done && Space.of(kind: $0.kind) == s }.count
    }

    private func help(_ s: Space) -> String {
        switch s {
        case .home: return L("总览：节奏、表现和记录（⌘1）", "Overview: rhythm, performance and the record (⌘1)")
        case .shadow: return L("跟读：先听别人怎么讲，再跟着讲（⌘2）", "Shadowing: hear how someone else says it, then speak along (⌘2)")
        case .topic: return L("主题：围绕一个题目或讲稿，自己讲（⌘3）", "Topics: speak on your own about a prompt or a script (⌘3)")
        }
    }
}

/// This week's laurel in miniature (back to the overview) and the settings gear.
struct TopBarTrailing: View {
    @Environment(AppState.self) private var state
    @Environment(StageModel.self) private var stage

    var body: some View {
        HStack(spacing: 10) {
            if let w = state.today?.week {
                Button { state.closeTray(); state.go(.home) } label: {
                    HStack(spacing: 5) {
                        LaurelWreath(days: w.laurel, target: w.target, size: 24, showCount: false)
                        Text("\(w.done)/\(w.target)").font(Typeface.display(14)).monospacedDigit().foregroundStyle(Palette.ink)
                    }
                    .padding(.leading, 5).padding(.trailing, 11).frame(height: 30)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .help(L("本周练了 \(w.done) 天，目标 \(w.target) 天", "Practiced \(plural(w.done, "day")) this week, goal \(w.target)"))
            }
            Button { Task { await state.openTray(.settings) } } label: {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink2)
                    .frame(width: 30, height: 30).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(L("设置（⌘,）", "Settings (⌘,)"))
        }
        .opacity(stage.isActive ? 0.3 : 1)
        .disabled(stage.isActive)
        .animation(Motion.paper, value: stage.isActive)
    }
}

// MARK: - Service status

/// The analysis service starts in the background; recording never waits for it.
struct ServerToast: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack {
            content
                .transition(.move(edge: .top).combined(with: .opacity))
            Spacer()
        }
        .padding(.top, 6)
        .animation(Motion.glass, value: key)
        .allowsHitTesting(key != "ready")
    }

    private var key: String {
        switch state.server.status {
        case .ready: return state.pending.isEmpty ? "ready" : "pending"
        case .starting: return "starting"
        case .failed: return "failed"
        }
    }

    @ViewBuilder private var content: some View {
        switch state.server.status {
        case .ready:
            if !state.pending.isEmpty {
                toast { ProgressView().controlSize(.mini); Text(L("正在分析启动前录的 \(state.pending.count) 段", "Analyzing \(plural(state.pending.count, "take")) recorded before startup")) }
            }
        case .starting:
            toast { ProgressView().controlSize(.mini); Text(L("分析服务在后台启动。现在就可以录，录完自动分析。", "The analysis service is starting in the background. Record now; it's analyzed when you finish.")) }
        case .failed(let msg):
            toast {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.ochre)
                Text(L("分析服务没起来：", "The analysis service didn't start: ") + msg).lineLimit(2)
                Button(L("重试", "Retry")) { Task { await state.boot() } }.buttonStyle(InkButtonStyle())
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
}
