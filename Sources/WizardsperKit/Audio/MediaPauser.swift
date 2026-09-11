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
        guard !didPause, Self.isSomethingPlaying() else { return false }
        Self.sendPlayPause()
        didPause = true
        Log.audio.info("Paused playback for a dictation session")
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

    /// True when some process is actively running audio through the default
    /// output device.
    ///
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` is the public answer to
    /// exactly this question and needs no entitlement and no private framework —
    /// the alternative everyone reaches for, `MRMediaRemoteGetNowPlaying…`, is
    /// private API that has broken across releases. It asks about the *output*
    /// device, so Wizardsper's own microphone capture cannot make it true.
    ///
    /// It is a slightly blunter instrument than "is music playing": a notification
    /// sound or a video keeps the device running for a moment. The cost of a
    /// false positive is one spurious play/pause pair, which is why `resume`
    /// re-sends the same key rather than trying to force a state.
    public static func isSomethingPlaying() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        guard status == noErr else {
            Log.audio.debug("Could not read output device activity: \(status)")
            return false
        }
        return running != 0
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
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
