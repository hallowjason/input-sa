import CoreAudio
import Foundation

/// Temporarily mutes the system's default output device while recording, so the
/// speaker can't play audio back into the microphone (external echo → re-record).
///
/// Design rules (all failures are silent — muting must NEVER affect recording):
///   • `beginMute()` remembers the current mute state, then mutes. If the device
///     was already muted, nothing is changed and `endMute()` won't unmute it.
///   • `endMute()` restores the exact state captured at `beginMute()`.
///   • A reentrancy flag makes unbalanced begin/end calls safe: a second
///     `beginMute()` without an intervening `endMute()` is ignored, and an
///     `endMute()` with no active mute is a no-op.
///
/// CoreAudio only — no AVAudioSession (macOS). Gated by the
/// `com.inputsa.muteWhileRecording` preference at the call site.
final class SystemAudioMute {
    static let shared = SystemAudioMute()
    private init() {}

    /// True between a successful `beginMute()` and its matching `endMute()`.
    private var isMuting = false
    /// The device we muted (may change between sessions — always re-resolve).
    private var mutedDevice: AudioDeviceID?
    /// The mute value that was in effect before we muted (restored on end).
    private var previousMuteValue: UInt32?

    // MARK: - Public API

    /// Remember the current mute state and mute the default output device.
    /// No-op if already in a mute session, if the device was already muted, or
    /// on any CoreAudio failure.
    func beginMute() {
        guard !isMuting else { return }

        guard let device = Self.defaultOutputDevice() else { return }
        guard Self.hasSettableMute(device) else { return }
        guard let current = Self.readMute(device) else { return }

        // Already muted by something else — leave it, and don't unmute on end.
        if current != 0 { return }

        guard Self.writeMute(device, value: 1) else { return }

        isMuting = true
        mutedDevice = device
        previousMuteValue = current
    }

    /// Restore the mute state captured at `beginMute()`. Safe to call when no
    /// mute session is active (no-op).
    func endMute() {
        guard isMuting, let device = mutedDevice, let previous = previousMuteValue else {
            isMuting = false
            mutedDevice = nil
            previousMuteValue = nil
            return
        }
        _ = Self.writeMute(device, value: previous)
        isMuting = false
        mutedDevice = nil
        previousMuteValue = nil
    }

    // MARK: - CoreAudio helpers

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Whether the device exposes a settable master-mute control (some devices
    /// have per-channel mute only, or none at all — skip those).
    private static func hasSettableMute(_ device: AudioDeviceID) -> Bool {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(device, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private static func readMute(_ device: AudioDeviceID) -> UInt32? {
        var address = muteAddress()
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    @discardableResult
    private static func writeMute(_ device: AudioDeviceID, value: UInt32) -> Bool {
        var address = muteAddress()
        var v = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &v) == noErr
    }
}
