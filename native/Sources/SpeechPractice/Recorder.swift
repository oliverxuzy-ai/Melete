import AVFoundation
import Foundation
import Observation
import Speech
import os

enum RecorderError: LocalizedError {
    case micDenied, noInput
    var errorDescription: String? {
        switch self {
        case .micDenied: return L("没有麦克风权限。到 系统设置 > 隐私与安全性 > 麦克风 里允许 Melete。", "No microphone access. Allow Melete in System Settings > Privacy & Security > Microphone.")
        case .noInput: return L("现在没有可用的麦克风。到 系统设置 > 声音 > 输入 选一个，再开始。", "No microphone is available. Pick one in System Settings > Sound > Input, then start again.")
        }
    }
}

/// The voice level, written by the audio thread and read by the orb on every frame.
/// Nothing here touches SwiftUI state, so speaking never invalidates a view.
final class LevelMeter: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var value: Float = 0

    /// Envelope follower: rises fast when you speak, falls slowly, like a VU needle.
    func push(_ rms: Float) {
        let target = min(1, rms * 8)
        os_unfair_lock_lock(&lock)
        value = target > value ? value + (target - value) * 0.55 : value * 0.86 + target * 0.14
        os_unfair_lock_unlock(&lock)
    }

    func read() -> Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Double(value)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        value = 0
        os_unfair_lock_unlock(&lock)
    }
}

/// Audio-thread side of the capture: meters every buffer and, once capture is open, converts it
/// to the file's fixed format, writes it, and feeds the live transcriber. The microphone's format
/// can change in the middle of a recording (AirPods switching to their headset mode, an iPhone
/// microphone taking over), so every buffer is converted from whatever format it arrives in.
final class CaptureSink: @unchecked Sendable {
    /// What every recording is stored as: mono, 48 kHz (16-bit PCM on disk).
    static let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    let file: AVAudioFile
    let meter: LevelMeter
    let continuation: AsyncStream<AnalyzerInput>.Continuation?
    private let liveFormat: AVAudioFormat?
    private let liveConverter: AVAudioConverter?
    private var inputConverter: AVAudioConverter?
    private var lock = os_unfair_lock()
    private var open = false
    private var frames: AVAudioFramePosition = 0
    private var failures = 0
    private var formats: [String] = []

    init(file: AVAudioFile, liveFormat: AVAudioFormat?, continuation: AsyncStream<AnalyzerInput>.Continuation?, meter: LevelMeter) {
        self.file = file; self.liveFormat = liveFormat; self.continuation = continuation; self.meter = meter
        if let liveFormat, liveFormat != CaptureSink.fileFormat {
            liveConverter = AVAudioConverter(from: CaptureSink.fileFormat, to: liveFormat)
        } else {
            liveConverter = nil
        }
    }

    /// A file in the fixed format, ready for `handle`.
    static func makeFile(at url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fileFormat.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Armed sinks only meter; capture starts when the countdown ends.
    func setOpen(_ v: Bool) {
        os_unfair_lock_lock(&lock); open = v; os_unfair_lock_unlock(&lock)
    }

    private var isOpen: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return open
    }

    /// Seconds actually written, buffers that could not be converted or written, and the input
    /// formats seen while open.
    var report: (seconds: Double, failures: Int, formats: [String]) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (Double(frames) / CaptureSink.fileFormat.sampleRate, failures, formats)
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        meter.push(CaptureSink.rms(buffer))
        guard isOpen, buffer.frameLength > 0 else { return }
        noteFormat(buffer.format)
        let (mono, ok) = toFileFormat(buffer)
        guard ok else { fail(); return }
        guard let mono else { return }   // a resampler can hold back its first few frames
        do {
            try file.write(from: mono)
            os_unfair_lock_lock(&lock); frames += AVAudioFramePosition(mono.frameLength); os_unfair_lock_unlock(&lock)
        } catch { fail(); return }
        guard let continuation else { return }
        if let liveConverter, let liveFormat {
            if let out = CaptureSink.convert(mono, with: liveConverter, to: liveFormat).buffer { continuation.yield(AnalyzerInput(buffer: out)) }
        } else {
            continuation.yield(AnalyzerInput(buffer: mono))
        }
    }

    private func fail() {
        os_unfair_lock_lock(&lock); failures += 1; os_unfair_lock_unlock(&lock)
    }

    private func noteFormat(_ f: AVAudioFormat) {
        let d = "\(Int(f.sampleRate)) Hz × \(f.channelCount)"
        os_unfair_lock_lock(&lock)
        if formats.last != d { formats.append(d) }
        os_unfair_lock_unlock(&lock)
    }

    private func toFileFormat(_ buffer: AVAudioPCMBuffer) -> (AVAudioPCMBuffer?, Bool) {
        if buffer.format == CaptureSink.fileFormat { return (buffer, true) }
        if inputConverter?.inputFormat != buffer.format {
            inputConverter = AVAudioConverter(from: buffer.format, to: CaptureSink.fileFormat)
            inputConverter?.downmix = true
        }
        guard let c = inputConverter else { return (nil, false) }
        return CaptureSink.convert(buffer, with: c, to: CaptureSink.fileFormat)
    }

    /// One buffer through a streaming converter. Returns nil with `ok` when the converter had
    /// nothing to give back yet.
    static func convert(_ buffer: AVAudioPCMBuffer, with c: AVAudioConverter, to format: AVAudioFormat) -> (buffer: AVAudioPCMBuffer?, ok: Bool) {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return (nil, false) }
        var fed = false
        var error: NSError?
        let status = c.convert(to: out, error: &error) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true
            s.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return (nil, false) }
        return (out.frameLength > 0 ? out : nil, true)
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { let v = data[0][i]; sum += v * v }
        return (sum / Float(n)).squareRoot()
    }
}

/// One line per recording in ~/Library/Logs/<bundle id>/capture.log, so a recording that came
/// out short can be explained afterwards.
enum CaptureLog {
    /// Lines are written in order on a queue of their own, so a key press never waits on disk.
    private static let queue = DispatchQueue(label: "melete.capture-log", qos: .utility)

    static func write(_ line: String) {
        let now = Date()
        queue.async {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/\(Bundle.main.bundleIdentifier ?? "Melete")")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("capture.log")
            let data = Data("\(ISO8601DateFormatter().string(from: now)) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// Records the microphone to a WAV file and shows a live transcript while recording
/// (on-device SpeechAnalyzer). The final metrics still come from Whisper on the server.
///
/// Two steps so starting feels instant: `arm` (during the 3 s countdown) sets up the engine,
/// the file and the live transcriber; `beginCapture` only opens the tap.
/// `MELETE_FAKE_MIC=<audio file>` replaces the microphone with that file (end to end tests).
/// With `MELETE_FAKE_LIVE=1` the file also goes through the live transcriber, fed at the pace
/// it was spoken, the way a microphone would feed it.
@Observable
@MainActor
final class Recorder {
    var isRecording = false
    var isArmed = false
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var liveSentences: [String] = []
    var liveVolatile = ""
    var liveWordCount = 0
    /// Live pace, rounded and refreshed once a second so the numeral does not flicker.
    var liveWPM: Double = 0
    var liveAvailable = true
    /// Which recognizer the live transcript comes from (see `setupLive`).
    enum LiveModel { case transcriber, dictation }
    @ObservationIgnored private(set) var liveModel = LiveModel.transcriber
    var liveNote: String?
    var fileURL: URL?
    var lastFinalChunk = ""
    @ObservationIgnored let meter = LevelMeter()
    @ObservationIgnored private(set) var startDate: Date?

    /// For the render harness, which draws a take in progress without recording one: the water
    /// clock reads the time left from this start.
    func pretendStarted(at date: Date?) { startDate = date }

    /// Seconds of audio the last recording actually holds (the file, not the clock).
    @ObservationIgnored private(set) var capturedSeconds: Double = 0

    private var engine: AVAudioEngine?
    private var sink: CaptureSink?
    private var timer: Timer?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: (any SpeechModule)?
    private var resultsTask: Task<Void, Never>?
    private var ticks = 0
    @ObservationIgnored private var arming: Task<Void, Error>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    @ObservationIgnored private var restarts = 0
    /// Held while recording: no App Nap if you switch to another window, no idle sleep.
    @ObservationIgnored private var activity: NSObjectProtocol?

    private var fakeSource: URL? {
        ProcessInfo.processInfo.environment["MELETE_FAKE_MIC"].map { URL(fileURLWithPath: $0) }
    }
    private var fakeLive: Bool { ProcessInfo.processInfo.environment["MELETE_FAKE_LIVE"] == "1" }
    @ObservationIgnored private var fakeLiveInput: (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation)?
    @ObservationIgnored private var fakeFeed: Task<Void, Never>?
    /// When the fake live feed began, and how late each live result came after the newest audio
    /// it covers (seconds). Only kept with the fake live microphone, for tests.
    @ObservationIgnored private var liveClock: Date?
    @ObservationIgnored private(set) var liveLags: [Double] = []

    func start(language: SpeechLanguage) async throws {
        try await arm(language: language)
        beginCapture()
    }

    /// Words worth teaching the live transcriber: names, products, acronyms and numbers from
    /// the prompt, the script or the original (Fivetran, Salesforce, ETL), not everyday words.
    static func vocabulary(from texts: [String], limit: Int = 100) -> [String] {
        let common: Set<String> = ["the", "a", "an", "and", "or", "but", "so", "if", "then", "now", "this", "that", "these",
                                   "those", "what", "how", "why", "when", "where", "who", "which", "we", "you", "your", "our",
                                   "my", "it", "its", "they", "their", "he", "she", "i", "in", "on", "at", "to", "for", "of",
                                   "with", "from", "by", "as", "is", "are", "was", "be", "do", "does", "give", "tell", "name",
                                   "open", "make", "explain", "walk", "pitch", "one", "two", "three", "first", "next", "say",
                                   "everything", "something", "nothing", "because", "however", "therefore", "recommendation"]
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-'")).inverted
        var seen = Set<String>()
        var out: [String] = []
        for text in texts {
            for raw in text.components(separatedBy: separators) {
                let w = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-'"))
                guard w.count >= 2, w.unicodeScalars.allSatisfy(\.isASCII), let first = w.first else { continue }
                let key = w.lowercased()
                let special = first.isUppercase || w.contains(where: \.isNumber) || w.count >= 10
                guard special, !common.contains(key), seen.insert(key).inserted else { continue }
                out.append(w)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Sets everything up and starts metering, without writing anything yet. Safe to call while
    /// another call is still setting up: both wait for the same microphone.
    /// `follow`: the live transcript only has to say where in a known text you are (shadowing on
    /// speakers), so the quickest recognizer is used rather than the most accurate.
    func arm(language: SpeechLanguage, vocabulary: [String] = [], follow: Bool = false) async throws {
        if isArmed { return }
        if let arming {
            try await arming.value
            if isArmed { return }   // that setup was discarded by a disarm; make a fresh one
        }
        // Taken now, not when the setup starts running: an Esc that lands in between must win.
        let gen = generation
        let task = Task { @MainActor in try await self.armNow(language: language, vocabulary: vocabulary, follow: follow, generation: gen) }
        arming = task
        defer { if arming == task { arming = nil } }
        try await task.value
    }

    /// How many times a microphone was set up (tests check that one press arms once).
    @ObservationIgnored private(set) var armCount = 0

    private func armNow(language: SpeechLanguage, vocabulary: [String], follow: Bool, generation gen: Int) async throws {
        guard gen == generation else { return }   // cancelled before it began
        armCount += 1
        liveSentences = []; liveVolatile = ""; liveWordCount = 0; liveNote = nil; lastFinalChunk = ""; liveWPM = 0
        capturedSeconds = 0
        restarts = 0
        meter.reset()
        if let fake = fakeSource {
            if fakeLive {
                let (format, continuation) = await setupLive(language: language, vocabulary: vocabulary, follow: follow)
                guard gen == generation else { continuation?.finish(); return }
                if let format, let continuation { fakeLiveInput = (format, continuation) }
            }
            armFake(fake)
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.micDenied }
        guard gen == generation else { return }

        let engine = AVAudioEngine()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).wav")
        let file = try CaptureSink.makeFile(at: url)
        let (liveFormat, continuation) = await setupLive(language: language, vocabulary: vocabulary, follow: follow)
        guard gen == generation else {   // disarmed while setting up
            continuation?.finish()
            try? FileManager.default.removeItem(at: url)
            return
        }
        // A device that just went away (an iPhone microphone, a virtual device) reports no format;
        // attaching a tap to that raises an exception nothing can catch, so stop here instead.
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            continuation?.finish()
            try? FileManager.default.removeItem(at: url)
            CaptureLog.write("no usable input: \(inputFormat)")
            throw RecorderError.noInput
        }
        fileURL = url
        let sink = CaptureSink(file: file, liveFormat: liveFormat, continuation: continuation, meter: meter)
        self.sink = sink
        // The tap takes the input's current format (nil), so a device that changed since is never
        // forced into a stale one. 1024 frames is about 21 ms: the orb sees the voice at once.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in sink.handle(buffer) }
        engine.prepare()
        try engine.start()
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputChanged() }
        }
        isArmed = true
    }

    /// The input device or its format changed (headphones switching to headset mode, another
    /// microphone taking over). The engine has stopped itself; reattach and carry on recording.
    private func inputChanged() {
        guard let engine, let sink else { return }
        restarts += 1
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            liveNote = L("麦克风断开了", "The microphone disconnected")
            CaptureLog.write("input lost after change \(restarts)")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in sink.handle(buffer) }
        engine.prepare()
        do {
            try engine.start()
            CaptureLog.write("input changed to \(Int(format.sampleRate)) Hz × \(format.channelCount), reattached")
        } catch {
            liveNote = L("麦克风重新连接失败：", "Couldn't reconnect the microphone: ") + error.localizedDescription
            CaptureLog.write("reattach failed: \(error.localizedDescription)")
        }
    }

    /// Opens capture. Instant, because `arm` already did the slow part.
    func beginCapture() {
        if sink == nil && fakeSource == nil { CaptureLog.write("capture opened with no microphone attached") }
        sink?.setOpen(true)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording practice")
        }
        startDate = Date()
        elapsed = 0
        ticks = 0
        isRecording = true
        if let fake = fakeSource, let input = fakeLiveInput { startFakeFeed(fake, input.format, input.continuation) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let start = startDate else { return }
        elapsed = Date().timeIntervalSince(start)
        ticks += 1
        if fakeSource != nil, isRecording { liveWordCount = Int(elapsed * 2.4) }
        if ticks % 5 == 0 {   // once a second
            level = Float(meter.read())
            // The words still being heard count too: the dictation recognizer used for
            // shadowing on speakers can keep a whole take in one unfinished result.
            // (The fake microphone sets its own count above.)
            let words = fakeSource != nil ? liveWordCount : liveWordCount + Recorder.countUnits(liveVolatile)
            liveWPM = elapsed > 5 ? (Double(words) / (elapsed / 60)).rounded() : 0
        }
    }

    /// Stops capture, finishes live transcription, returns the WAV file. `capturedSeconds` then
    /// says how much audio it really holds.
    func stop() async -> URL? {
        timer?.invalidate(); timer = nil
        let clock = startDate.map { Date().timeIntervalSince($0) } ?? 0
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRecording = false
        isArmed = false
        level = 0
        meter.reset()
        if fakeSource != nil {
            fakeTimer?.invalidate(); fakeTimer = nil; capturedSeconds = clock
            await endFakeFeed()
            return fileURL
        }
        sink?.setOpen(false)
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let r = sink?.report {
            capturedSeconds = r.seconds
            let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
            CaptureLog.write(String(format: "recorded %.1f s of %.1f s on the clock, device %@, formats %@, %d input changes, %d failed buffers",
                                    r.seconds, clock, device, r.formats.joined(separator: " then "), restarts, r.failures))
        }
        sink?.continuation?.finish()
        sink = nil   // closes the file
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        // give the results stream a moment to deliver the last final chunk
        try? await Task.sleep(for: .milliseconds(120))
        resultsTask?.cancel(); resultsTask = nil
        analyzer = nil; transcriber = nil
        if !liveVolatile.isEmpty { liveSentences.append(liveVolatile); liveVolatile = "" }
        return fileURL
    }

    /// 放弃这段: ends the take in progress and throws it away. Nothing is kept or analysed.
    /// Synchronous, so a new take can be armed right after without racing this teardown.
    func discard() {
        guard isRecording else { return }
        let clock = startDate.map { Date().timeIntervalSince($0) } ?? 0
        timer?.invalidate(); timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRecording = false
        isArmed = false
        level = 0
        meter.reset()
        generation += 1
        sink?.setOpen(false)
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        sink?.continuation?.finish()
        sink = nil
        fakeTimer?.invalidate(); fakeTimer = nil
        fakeFeed?.cancel(); fakeFeed = nil
        fakeLiveInput?.continuation.finish(); fakeLiveInput = nil
        resultsTask?.cancel(); resultsTask = nil
        analyzer = nil; transcriber = nil
        liveSentences = []; liveVolatile = ""; liveWordCount = 0; liveWPM = 0
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        capturedSeconds = 0
        CaptureLog.write(String(format: "discarded after %.1f s, nothing kept", clock))
    }

    /// Stops without waiting for anything, for when the app is quitting: closes the file and
    /// returns it, so what was said can be analysed next time.
    func stopNow() -> URL? {
        guard isRecording else { return nil }
        timer?.invalidate(); timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRecording = false
        isArmed = false
        if fakeSource != nil { fakeTimer?.invalidate(); fakeTimer = nil; return fileURL }
        sink?.setOpen(false)
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        sink?.continuation?.finish()
        sink = nil   // closes the file
        CaptureLog.write("stopped by quitting; kept for analysis on next launch")
        return fileURL
    }

    /// Leaves an armed but unused session (closed during the countdown).
    func disarm() {
        generation += 1   // a setup still in flight discards what it made
        guard !isRecording else { return }
        // New material is going on stage: the last take's captions belong to the old one.
        liveSentences = []; liveVolatile = ""; liveWordCount = 0; liveWPM = 0; liveNote = nil; lastFinalChunk = ""
        guard isArmed else { return }
        timer?.invalidate(); timer = nil
        isArmed = false
        meter.reset()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        sink?.continuation?.finish()
        sink = nil
        resultsTask?.cancel(); resultsTask = nil
        analyzer = nil; transcriber = nil
        fakeTimer?.invalidate(); fakeTimer = nil
        fakeFeed?.cancel(); fakeFeed = nil
        fakeLiveInput?.continuation.finish(); fakeLiveInput = nil
        if let fileURL, fakeSource == nil { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: fake microphone (tests)

    private func armFake(_ source: URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(Int(Date().timeIntervalSince1970)).\(source.pathExtension)")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: source, to: url)
        fileURL = url
        isArmed = true
        // A voice-like level: syllables at about 4 Hz riding on phrases at about 0.4 Hz.
        let meter = self.meter
        let t0 = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            let t = Date().timeIntervalSince(t0)
            let phrase = max(0, sin(t * 2 * .pi * 0.4))
            let syll = 0.5 + 0.5 * sin(t * 2 * .pi * 4.2)
            meter.push(Float(0.015 + 0.09 * phrase * syll))
        }
        fakeTimer = timer
        timer = nil
    }

    @ObservationIgnored private var fakeTimer: Timer?

    /// Reads the fake microphone's file in 1024-frame buffers, each handed over when it would have
    /// been spoken, through the same sink a microphone feeds (conversion, level, live transcriber).
    private func startFakeFeed(_ source: URL, _ format: AVAudioFormat, _ continuation: AsyncStream<AnalyzerInput>.Continuation) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fake-live-\(UUID().uuidString).wav")
        guard let file = try? CaptureSink.makeFile(at: scratch) else { return }
        let sink = CaptureSink(file: file, liveFormat: format, continuation: continuation, meter: meter)
        sink.setOpen(true)
        fakeTimer?.invalidate(); fakeTimer = nil   // real levels from here on
        let t0 = Date()
        liveClock = t0
        liveLags = []
        fakeFeed = Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: scratch) }
            guard let input = try? AVAudioFile(forReading: source) else { return }
            let chunk: AVAudioFrameCount = 1024
            var fed: Double = 0
            while !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk),
                      (try? input.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                fed += Double(buffer.frameLength) / input.processingFormat.sampleRate
                let wait = t0.addingTimeInterval(fed).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                sink.handle(buffer)
            }
            sink.setOpen(false)
        }
    }

    private func endFakeFeed() async {
        fakeFeed?.cancel(); fakeFeed = nil
        guard let input = fakeLiveInput else { return }
        fakeLiveInput = nil
        input.continuation.finish()
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        try? await Task.sleep(for: .milliseconds(120))
        resultsTask?.cancel(); resultsTask = nil
        analyzer = nil; transcriber = nil
        liveClock = nil
        if !liveVolatile.isEmpty { liveSentences.append(liveVolatile); liveVolatile = "" }
    }

    /// Starts the on-device transcriber; returns the format it wants and the stream to feed it.
    /// Starts the on-device recognizer; returns the format it wants and the stream to feed it.
    ///
    /// Measured on the same speech fed at its own pace (a clip of real speech and a read-along with
    /// pauses): the transcriber reported every 3.8 s by default, so a word appeared 2.3 s after it
    /// was said (3.9 s at worst). With fastResults it reports every 0.96 s: 0.65 s typical, 1 s at
    /// worst, 97 to 99% of words right. The dictation transcriber with frequent finalization reports
    /// every 0.5 s: 0.15 to 0.4 s typical, 0.6 s at worst, but 91% of words right on real speech.
    /// So captions use the transcriber, and following a known text uses dictation.
    private func setupLive(language: SpeechLanguage, vocabulary: [String], follow: Bool) async -> (AVAudioFormat?, AsyncStream<AnalyzerInput>.Continuation?) {
        let locale = Locale(identifier: language.localeIdentifier)
        do {
            let slow = ProcessInfo.processInfo.environment["MELETE_LIVE_SLOW"] == "1"   // the old way, for comparison in tests
            let times: Set<SpeechTranscriber.ResultAttributeOption> = fakeLive ? [.audioTimeRange] : []
            let module: any SpeechModule
            if follow, !slow, await DictationTranscriber.supportedLocale(equivalentTo: locale) != nil {
                let dictation = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                                     reportingOptions: [.volatileResults, .frequentFinalization],
                                                     attributeOptions: fakeLive ? [.audioTimeRange] : [])
                module = dictation
                liveModel = .dictation
                resultsTask = Task { [weak self] in
                    do {
                        for try await result in dictation.results {
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            let end = Recorder.newestWordEnd(result.text)
                            await MainActor.run { self?.handle(text: text, isFinal: result.isFinal, audioEnd: end) }
                        }
                    } catch {
                        await MainActor.run { self?.liveNote = L("实时识别中断：", "Live recognition stopped: ") + error.localizedDescription }
                    }
                }
            } else {
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                    reportingOptions: slow ? [.volatileResults] : [.volatileResults, .fastResults],
                                                    attributeOptions: times)
                module = transcriber
                liveModel = .transcriber
                resultsTask = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            let end = Recorder.newestWordEnd(result.text)
                            await MainActor.run { self?.handle(text: text, isFinal: result.isFinal, audioEnd: end) }
                        }
                    } catch {
                        await MainActor.run { self?.liveNote = L("实时字幕中断：", "Live captions stopped: ") + error.localizedDescription }
                    }
                }
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                liveNote = L("正在下载语音识别模型…", "Downloading the speech model…")
                try await request.downloadAndInstall()
                liveNote = nil
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try? await analyzer.setContext(context)
            }
            let outFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            self.analyzer = analyzer
            self.transcriber = module
            liveAvailable = true
            return (outFormat, continuation)
        } catch {
            resultsTask?.cancel(); resultsTask = nil
            liveAvailable = false
            liveNote = L("实时字幕不可用：", "Live captions unavailable: ") + error.localizedDescription
            return (nil, nil)
        }
    }

    /// Where the newest timed word of a result ends in the audio (only when word times were asked for).
    nonisolated static func newestWordEnd(_ text: AttributedString) -> Double {
        var end = -1.0
        for run in text.runs {
            if let r = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] { end = max(end, CMTimeRangeGetEnd(r).seconds) }
        }
        return end
    }

    private func handle(text: String, isFinal: Bool, audioEnd: Double) {
        guard !text.isEmpty else { return }
        if let clock = liveClock, audioEnd.isFinite, audioEnd > 0 {
            let lag = Date().timeIntervalSince(clock) - audioEnd
            liveLags.append(lag)
            FileHandle.standardError.write(String(format: "[live] at %.2f s, newest word ends %.2f s, %.2f s late, %@: %@\n",
                                                  Date().timeIntervalSince(clock), audioEnd, lag, isFinal ? "final" : "volatile", text).data(using: .utf8)!)
        }
        if isFinal {
            liveSentences.append(text)
            liveVolatile = ""
            lastFinalChunk = text
            liveWordCount += Recorder.countUnits(text)
        } else {
            liveVolatile = text
        }
    }

    static func countUnits(_ text: String) -> Int {
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        if cjk > 0 { return cjk }
        return text.split { $0.isWhitespace }.count
    }
}

/// Follows a script while the speaker talks: highlights the sentence that best matches
/// the latest recognized chunk, only ever moving forward a few sentences at a time.
struct Teleprompter {
    var sentences: [String] = []
    var cursor: Int = 0
    private var tokens: [[String]] = []

    init(script: String = "") { load(script) }

    mutating func load(_ script: String) {
        sentences = Teleprompter.split(script)
        tokens = sentences.map { Set(Teleprompter.tokenize($0)).sorted() }
        cursor = 0
    }

    mutating func advance(with chunk: String) {
        guard !sentences.isEmpty else { return }
        let chunkTokens = Set(Teleprompter.tokenize(chunk))
        guard chunkTokens.count >= 2 else { return }
        var best = cursor, bestScore = 0.0
        for i in cursor..<min(cursor + 4, sentences.count) {
            let s = Set(tokens[i])
            let score = Double(s.intersection(chunkTokens).count) / Double(chunkTokens.count)
            if score > bestScore { bestScore = score; best = i }
        }
        if bestScore >= 0.35 { cursor = best }
    }

    static func split(_ text: String) -> [String] {
        var out: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: #"^[A-Za-z][\w .'\-]{0,24}[:：]\s*"#, options: .regularExpression) { line.removeSubrange(r) }
            if line.isEmpty { continue }
            var current = ""
            for ch in line {
                current.append(ch)
                if ".!?。！？".contains(ch) { out.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current.trimmingCharacters(in: .whitespaces)) }
        }
        return out
    }

    static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        for ch in text.lowercased() {
            if let v = ch.unicodeScalars.first?.value, (0x4E00...0x9FFF).contains(v) {
                if !word.isEmpty { out.append(word); word = "" }
                out.append(String(ch))
            } else if ch.isLetter || ch.isNumber || ch == "'" {
                word.append(ch)
            } else if !word.isEmpty { out.append(word); word = "" }
        }
        if !word.isEmpty { out.append(word) }
        let stop: Set<String> = ["the", "a", "an", "and", "or", "to", "of", "in", "on", "is", "are", "it", "we", "you", "i", "that", "this", "so", "um", "uh", "like"]
        return out.filter { !stop.contains($0) && $0.count > 1 }
    }
}
