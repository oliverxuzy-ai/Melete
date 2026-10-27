import CoreAudio
import Foundation

/// Where the app's sound comes out. Shadowing plays the original while you record, which only
/// works when the sound stays in your ears: out of speakers, the microphone records the
/// original too, and the analysis would be of the original, not of you.
enum AudioRoute {
    /// True for headphones: the headphone jack, AirPods and other Bluetooth headphones.
    /// Anything else (built-in speakers, a display, USB or AirPlay speakers) counts as speakers.
    /// `MELETE_ROUTE=speakers|headphones` decides instead (tests).
    static var isPrivate: Bool {
        if let forced = ProcessInfo.processInfo.environment["MELETE_ROUTE"] { return forced == "headphones" }
        guard let device = defaultOutput else { return false }
        let name = outputName.lowercased()
        if name.contains("headphone") || name.contains("耳机") || name.contains("airpods") { return true }
        switch uint32(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn:
            // The built-in output is either the speakers or the headphone jack.
            return uint32(device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput) == fourCC("hdpn")
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return true
        default:
            return false
        }
    }

    /// The output device's name, for the capture log.
    static var outputName: String {
        if let forced = ProcessInfo.processInfo.environment["MELETE_ROUTE"] { return "test \(forced)" }
        guard let device = defaultOutput else { return "no output" }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "unknown" }
        return name.takeRetainedValue() as String
    }

    private static var defaultOutput: AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}
