import Foundation

/// When each line starts and ends in the fake microphone's audio, written by the script that made it.
struct FollowPlan: Decodable {
    struct Line: Decodable { let i: Int; let start: Double; let end: Double }
    let sentences: [Line]
    /// A silence was left after this line.
    let pauseAfter: Int?
    let duration: Double
}

extension E2E {
    /// `--followprobe <report>`: tapping lines of the original, and reading along on speakers with
    /// the subtitles following the voice. Runs with `MELETE_FAKE_LIVE=1` and a fake microphone
    /// holding the clip's own lines spoken at other paces, so the real live transcriber hears it;
    /// `FOLLOW_PRACTICE` names the clip and `FOLLOW_PLAN` says when each line starts in that audio.
    static func followProbe(state: AppState, recorder: Recorder, stage: StageModel) async {
        holdFullSpeed()
        if let i = CommandLine.arguments.firstIndex(of: "--followprobe"), CommandLine.arguments.count > i + 1 {
            reportURL = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        PlayerModel.muted = true
        StageModel.tracing = true
        log("Melete follow probe, \(Date())")
        followerCases()
        await state.boot()
        let env = ProcessInfo.processInfo.environment
        guard let pid = env["FOLLOW_PRACTICE"], let planPath = env["FOLLOW_PLAN"],
              let data = FileManager.default.contents(atPath: planPath),
              let plan = try? JSONDecoder().decode(FollowPlan.self, from: data),
              let p = await state.fetchPractice(pid), let r = p.reference else {
            log("missing the clip or the plan"); failures += 1; finish(); return
        }
        func dump() { for line in StageModel.trace { log("      " + line) } }
        func at(_ i: Int) -> String { String(format: "line %d lit, original at %.2f s (line %d starts %.2f s)", stage.activeSentence, stage.player.time, i, r.sentences[i].start) }
        func near(_ i: Int) -> Bool { abs(stage.player.time - max(0, r.sentences[i].start - 0.2)) < 0.6 }

        state.go(.shadow)
        stage.present(practice: p, mode: .shadow, autoStart: false)
        _ = await waitFor(8) { stage.practice?.id == pid && stage.phase == .ready }
        try? await Task.sleep(for: .milliseconds(600))

        // Tapping lines of the original before speaking.
        check("tap: lines can be tapped before you speak", stage.canJump, "\(stage.phase)")
        stage.jump(to: 6)
        let fromReady = await waitFor(3) { stage.phase == .listening && stage.player.playing && stage.activeSentence == 6 }
        check("tap: a line plays the original from there", fromReady && near(6), at(6))
        try? await Task.sleep(for: .seconds(1.2))
        let pressed = Date()
        stage.jump(to: 2)
        let lit = stage.activeSentence == 2
        let back = await waitFor(1) { stage.activeSentence == 2 && near(2) && stage.player.time > r.sentences[2].start - 0.2 }
        check("tap: an earlier line jumps back to it", lit && back && stage.phase == .listening,
              at(2) + String(format: ", lit at once %@, playing again after %.0f ms", "\(lit)", Date().timeIntervalSince(pressed) * 1000))
        stage.player.pause()
        try? await Task.sleep(for: .milliseconds(300))
        stage.jump(to: 9)
        let resumed = await waitFor(2) { stage.player.playing && stage.activeSentence == 9 }
        check("tap: a line plays even when the original was paused", resumed && near(9), at(9))
        let keeps = await holds(2) { stage.phase == .listening && stage.player.playing }
        check("tap: it plays on past the line", keeps, at(9))
        stage.cancel()
        _ = await waitFor(3) { stage.phase == .ready }
        try? await Task.sleep(for: .milliseconds(600))

        // Reading along on speakers.
        StageModel.trace = []
        stage.start("button")
        let rec = await waitFor(15) { stage.phase == .recording }
        check("read: recording opens", rec, "\(stage.phase)")
        guard rec else { dump(); finish(); return }
        let started = recorder.startDate ?? Date()
        check("read: on speakers the subtitles follow the voice, the original does not play",
              stage.followsVoice && !stage.player.playing, "follows \(stage.followsVoice), playing \(stage.player.playing), live \(recorder.liveAvailable)")
        check("read: the first line is lit as you start", stage.activeSentence == 0, "line \(stage.activeSentence)")
        var switches: [(line: Int, at: Double)] = []
        var last = stage.activeSentence
        while Date().timeIntervalSince(started) < plan.duration + 4 {
            if stage.activeSentence != last {
                last = stage.activeSentence
                switches.append((last, Date().timeIntervalSince(started)))
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        log("INFO  when each line lit up, against when the voice reached it (negative: before) and when the line before it ended")
        var lateness: [Double] = [], leftEarly: [Double] = []
        for s in plan.sentences where s.i >= 1 {
            let original = r.sentences.first { $0.i == s.i }?.start ?? 0
            let before = plan.sentences.first { $0.i == s.i - 1 }
            if let sw = switches.first(where: { $0.line >= s.i }) {
                lateness.append(sw.at - s.start)
                if let before { leftEarly.append(before.end - sw.at) }
                log(String(format: "      line %2d  voice at %5.2f s, lit at %5.2f s (%+.2f s), %.2f s before the line above ended; the original's clock: %5.2f s",
                           s.i, s.start, sw.at, sw.at - s.start, (before?.end ?? 0) - sw.at, original))
            } else {
                log(String(format: "      line %2d  voice at %5.2f s, never lit; the original's clock: %5.2f s", s.i, s.start, original))
            }
        }
        let forward = zip(switches, switches.dropFirst()).allSatisfy { $0.line < $1.line }
        check("read: the subtitles only move forward", forward, switches.map { "\($0.line)@\(String(format: "%.1f", $0.at))" }.joined(separator: " "))
        let read = plan.sentences.map(\.i).filter { $0 >= 1 }
        check("read: every line read lit up", read.allSatisfy { i in switches.contains { $0.line == i } }, "\(switches.count) moves")
        let lastRead = plan.sentences.last?.i ?? 0
        check("read: no line beyond what was read lit up", switches.allSatisfy { $0.line <= lastRead + 1 }, "last read \(lastRead)")
        if !lateness.isEmpty {
            // On time: lit no later than 0.3 s after the voice got there. Not too soon: the line being
            // read is left no more than 1.5 s before its end (lighting the next line during a pause is fine).
            let late = lateness.max() ?? 0, early = leftEarly.max() ?? 0
            let sorted = lateness.sorted()
            check("read: every line lights up by the time the voice reaches it", late <= 0.3,
                  String(format: "median %+.2f s, latest %+.2f s", sorted[sorted.count / 2], late))
            check("read: the line being read is not left long before its end", early <= 1.5, String(format: "at most %.2f s before", early))
        }
        if let pa = plan.pauseAfter, let a = plan.sentences.first(where: { $0.i == pa }), let b = plan.sentences.first(where: { $0.i == pa + 1 }) {
            // Moving on to the line after the pause is right (the line before it was finished);
            // going further while nothing is said is not, though the original's clock would.
            let during = switches.filter { $0.at > a.end + 0.3 && $0.at < b.start && $0.line > pa + 1 }
            check("read: a pause holds the place", during.isEmpty,
                  String(format: "silence %.1f to %.1f s, moves in it: %@", a.end, b.start, during.map { "\($0.line)" }.joined(separator: " ")))
        }
        let lags = recorder.liveLags.sorted()
        if !lags.isEmpty {
            note("read: live transcript latency", String(format: "median %.2f s, p90 %.2f s, max %.2f s over %d results",
                                                         lags[lags.count / 2], lags[min(lags.count - 1, lags.count * 9 / 10)], lags.last ?? 0, lags.count))
        }
        stage.jump(to: 1)
        check("read: tapping a line while reading sets the place", stage.activeSentence == 1 && stage.phase == .recording, "line \(stage.activeSentence)")
        stage.discard("button")
        _ = await waitFor(3) { stage.phase == .ready }
        check("read: afterwards the original is audible and keeps the subtitles again", !stage.followsVoice && !stage.player.silenced)
        if failures > 0 { dump() }
        finish()
    }

    /// The follower on its own, with transcripts written out by hand.
    static func followerCases() {
        let text = ["So if you haven't expressed your vision, if you haven't told people that you've done something in five minutes,",
                    "you're already lost.",
                    "So you have to be able to do that, and let me just mention a couple of things in that connection."]
        func words(_ n: Int, of s: Int) -> String { VoiceFollower.tokens(text[s]).prefix(n).joined(separator: " ") }

        // Word by word through the first line, as volatile results grow.
        var f = VoiceFollower(sentences: text)
        let first = VoiceFollower.tokens(text[0]).count
        var movedAt: Int?
        for n in 1...first {
            _ = f.hear(finals: [], volatile: words(n, of: 0))
            if movedAt == nil, f.sentence(lead: 2) == 1 { movedAt = n }
        }
        check("follower: moves to the next line with two words of this one left", movedAt == first - 2, "moved after \(movedAt ?? -1) of \(first) words")

        f = VoiceFollower(sentences: text)
        _ = f.hear(finals: [], volatile: "the and the to")
        check("follower: common words alone do not move the place", f.position == 0, "at word \(f.position)")

        f = VoiceFollower(sentences: text)
        _ = f.hear(finals: ["so if you havent express your fission if you haven't toll people that you done something in 5 minutes"], volatile: "")
        check("follower: misheard words and numbers in digits still carry it through the line", f.sentence(lead: 0) == 1, "at word \(f.position), line \(f.sentence(lead: 0))")

        f = VoiceFollower(sentences: text)
        _ = f.hear(finals: [words(first, of: 0)], volatile: "")
        _ = f.hear(finals: [words(first, of: 0)], volatile: "um so so you have to be able to do that")
        check("follower: a skipped line is caught up with", f.sentence(lead: 0) == 2, "line \(f.sentence(lead: 0))")

        f = VoiceFollower(sentences: text)
        _ = f.hear(finals: [], volatile: words(6, of: 0))
        let reached = f.position
        _ = f.hear(finals: [], volatile: words(2, of: 0))
        check("follower: a revised result never moves the place back", f.position == reached, "\(reached) then \(f.position)")

        f.anchor(sentence: 2)
        check("follower: a tapped line sets the place", f.sentence(lead: 2) == 2 && f.position == VoiceFollower.tokens(text[0] + " " + text[1]).count)

        f = VoiceFollower(sentences: text)
        _ = f.hear(finals: [words(VoiceFollower.tokens(text[0]).count, of: 0)], volatile: "you're")
        check("follower: a three word line is not passed over as soon as it is reached", f.sentence(lead: 2) == 1, "line \(f.sentence(lead: 2))")
        _ = f.hear(finals: [words(VoiceFollower.tokens(text[0]).count, of: 0)], volatile: "you're already")
        check("follower: it moves on with its last word left", f.sentence(lead: 2) == 2, "line \(f.sentence(lead: 2))")

        let zh = ["我们今天讨论数据平台的架构", "第一个问题是成本"]
        f = VoiceFollower(sentences: zh)
        _ = f.hear(finals: [], volatile: "我们今天讨论数据")
        let early = f.sentence(lead: 2)
        _ = f.hear(finals: [], volatile: "我们今天讨论数据平台的")
        check("follower: Chinese moves on with about four characters left", early == 0 && f.sentence(lead: 2) == 1, "line \(early) then \(f.sentence(lead: 2))")
    }
}
