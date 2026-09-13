import AppKit
import CoreAudio
import Foundation

/// Pauses whatever is playing while the user dictates, and puts it back.
///
/// Talking over your own music is the normal case, and it costs twice: the
/// recogniser hears the music as well as the voice, and the user hears their
/// own dictation competing with a song. Every dictation tool that does not do
/// this makes the user reach for the play button first.
///
/// The mechanism is the play/pause media key, synthesised and posted to the
/// system. That is deliberately not AppleScript aimed at Music or Spotify: the
/// media key is what every player already listens for — including browsers,
/// which is where most audio actually is — and it routes correctly regardless of
/// whether the sound is going to the built-in speakers, AirPods, or anything
/// else, because the key is handled by the player rather than by the output
/// device.
///
/// The hard part is not pausing but knowing whether to. A play/pause key sent
/// when nothing is playing *starts* something, which would be a genuinely
/// obnoxious bug — hold the dictation key in a quiet room and music begins. So
/// nothing is sent unless the default output device reports that some process is
/// actively playing through it, and `resume` does nothing unless this type is
/// the one that paused it.
@MainActor
public final class MediaPauser {

    /// Whether we paused something, and therefore owe it a resume. Nothing else
    /// may set this: resuming audio the user paused themselves, before they
    /// started dictating, would be the same bug in the other direction.
    public private(set) var didPause = false

    public init() {}

    /// Pause if — and only if — something is audibly playing.
    @discardableResult
    public func pauseIfPlaying() -> Bool {
        guard !didPause, let app = Self.playingApplication() else { return false }
        Self.sendPlayPause()
        didPause = true
        Log.audio.info("Paused \(app, privacy: .public) for a dictation session")
        return true
    }

    /// Put back only what we took.
    public func resume() {
        guard didPause else { return }
        didPause = false
        Self.sendPlayPause()
        Log.audio.info("Resumed playback")
    }

    // MARK: - Is anything playing?

    /// True when a real application is actually producing sound.
    ///
    /// This asks the *per-process* audio API, not the device. The obvious
    /// property — `kAudioDevicePropertyDeviceIsRunningSomewhere` — answers "does
    /// any process hold this device open", which is a different question and the
    /// wrong one: on a normal Mac `com.apple.TelephonyUtilities` holds the output
    /// device open for Handoff and call relay, so that property reads `true` with
    /// nothing audible at all.
    ///
    /// That is not a cosmetic inaccuracy. The play/pause key is a *toggle*, so a
    /// false positive does not merely fail to pause — it presses play on a paused
    /// player, and the user starts dictating while their music starts up. It was
    /// also intermittent, because the daemon comes and goes, which is precisely
    /// how the bug presented: sometimes the audio would un-pause instead.
    ///
    /// So a process only counts when all of these hold:
    ///
    /// - it is running output, per `kAudioProcessPropertyIsRunningOutput`;
    /// - it is not us;
    /// - it belongs to a real application. Daemons have no `NSRunningApplication`
    ///   at all, which is what separates `TelephonyUtilities` and `coreaudiod`
    ///   from Spotify, Music and a browser. Command-line tools like `afplay` are
    ///   excluded by the same test, deliberately: nothing is listening for a
    ///   media key on their behalf, so pausing cannot work and the key would land
    ///   on some other player instead.
    public static func isSomethingPlaying() -> Bool {
        playingApplication() != nil
    }

    /// The bundle identifier of an application currently producing sound, if any.
    /// Returned rather than a bare `Bool` so the log can name what was paused —
    /// when this goes wrong, knowing *which* app was detected is the whole
    /// diagnosis.
    public static func playingApplication() -> String? {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        for process in audioProcesses() {
            guard isRunningOutput(process) else { continue }
            let pid = processPID(process)
            guard pid != ourPID, pid > 0 else { continue }
            // No `NSRunningApplication` means a daemon or a bare executable.
            guard let app = NSRunningApplication(processIdentifier: pid),
                app.activationPolicy != .prohibited
            else { continue }
            return app.bundleIdentifier ?? processBundleID(process) ?? "pid \(pid)"
        }
        return nil
    }

    // MARK: - CoreAudio process objects

    private static func audioProcesses() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private static func processPID(_ process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr
        else { return -1 }
        return value
    }

    private static func processBundleID(_ process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Through a raw buffer rather than `inout CFString?`: taking a pointer to
        // an Optional that holds an object reference is not a valid way to hand
        // CoreAudio somewhere to write, and the compiler says so.
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        var raw: UnsafeRawPointer?
        let status = withUnsafeMutableBytes(of: &raw) { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(process, &address, 0, nil, &size, base)
        }
        guard status == noErr, let raw else { return nil }
        let identifier = Unmanaged<CFString>.fromOpaque(raw).takeRetainedValue() as String
        return identifier.isEmpty ? nil : identifier
    }

    // MARK: - The key

    /// `NX_KEYTYPE_PLAY`. Not exposed to Swift, so it is spelled out here.
    private static let playPauseKey: Int32 = 16

    /// Post a play/pause press and release.
    ///
    /// A system-defined event rather than a keyboard one: media keys are not
    /// virtual key codes, they arrive as `NSEvent.EventType.systemDefined` with
    /// subtype 8, and the key and its up/down state are packed into `data1`.
    /// Posting requires Accessibility, which Wizardsper already needs in order to
    /// paste — so if the paste works, this works.
    private static func sendPlayPause() {
        for isDown in [true, false] {
            let data1 = Int((playPauseKey << 16) | (isDown ? 0x0A00 : 0x0B00))
            guard
                let event = NSEvent.otherEvent(
                    with: .systemDefined, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil,
                    subtype: 8, data1: data1, data2: -1)
            else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
