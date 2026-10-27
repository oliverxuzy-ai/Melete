// Downloads macOS's on-demand fonts by PostScript name, e.g. the Songti SC and Kaiti SC faces the
// Chinese interface cascades to (Typeface in Theme.swift). A Mac that has never downloaded them
// tries to fetch them on the main thread the first time text is laid out, and a headless runner
// waits there forever, so render.sh fetches them first. Fonts already installed return at once.
//
//   swift .github/screenshots/fetch-fonts.swift STSongti-SC-Regular STKaitiSC-Regular
import CoreText
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

final class Outcome: @unchecked Sendable {
    var failed = false
    var matched: [String] = []
}

let names = Array(CommandLine.arguments.dropFirst())
guard !names.isEmpty else {
    print("usage: fetch-fonts.swift <PostScript name>...")
    exit(2)
}
let descriptors = names.map { CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: $0] as CFDictionary) }
let outcome = Outcome()
let done = DispatchSemaphore(value: 0)

let started = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors as CFArray, nil) { state, info in
    let details = info as NSDictionary
    switch state {
    case .willBeginDownloading:
        print("fonts: downloading")
    case .didFinishDownloading:
        print("fonts: downloaded")
    case .didMatch:
        for case let d as CTFontDescriptor in (details[kCTFontDescriptorMatchingResult as String] as? [Any]) ?? [] {
            if let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String { outcome.matched.append(name) }
        }
    case .didFailWithError:
        outcome.failed = true
        print("fonts: failed: \(details[kCTFontDescriptorMatchingError as String] ?? "unknown error")")
    case .didFinish:
        done.signal()
    default:
        break
    }
    return true
}
guard started else {
    print("fonts: could not start matching")
    exit(1)
}
if done.wait(timeout: .now() + 600) == .timedOut {
    print("fonts: no answer after 600 s")
    exit(1)
}
let missing = names.filter { !outcome.matched.contains($0) }
print("fonts: ready \(outcome.matched.sorted().joined(separator: ", "))")
if outcome.failed || !missing.isEmpty {
    print("fonts: missing \(missing.joined(separator: ", "))")
    exit(1)
}
