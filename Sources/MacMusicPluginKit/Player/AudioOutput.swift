import AVFoundation
import CoreAudio

/// A selectable output device. Identified to the UI by `name` (what the Omarchy
/// widget shows and stores); `id` is resolved fresh each time it is applied so a
/// unplugged/renamed device fails cleanly rather than at the next track.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let name: String
}

/// CoreAudio output-device enumeration and selection, replacing SDL's
/// `SDL_GetNumAudioDevices` / `SDL_OpenAudioDevice(name, ...)`.
public enum AudioOutput {
    /// Every device that currently has at least one output stream.
    public static func devices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard hasOutputStreams(id), let name = name(of: id) else { return nil }
            return AudioDevice(id: id, name: name)
        }
    }

    /// Points `engine`'s output at the device named `name`, or the system default
    /// when `name` is nil. The engine must be stopped. Returns the name actually
    /// selected — nil (default) when the requested device is gone, mirroring the
    /// fallback in `open_audio_device` (backend/app.c:2353).
    @discardableResult
    public static func select(_ name: String?, on engine: AVAudioEngine) -> String? {
        guard let audioUnit = engine.outputNode.audioUnit else { return nil }

        guard let name else {
            setDevice(defaultOutputDeviceID(), on: audioUnit)
            return nil
        }
        guard let device = devices().first(where: { $0.name == name }) else {
            setDevice(defaultOutputDeviceID(), on: audioUnit)
            return nil
        }
        setDevice(device.id, on: audioUnit)
        return name
    }

    // MARK: - CoreAudio plumbing

    private static func setDevice(_ id: AudioDeviceID, on audioUnit: AudioUnit) {
        guard id != 0 else { return }
        var deviceID = id
        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0,
                             &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &id)
        return id
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue()
        else { return nil }
        return cf as String
    }
}
