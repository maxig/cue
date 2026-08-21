import CoreAudio
import Foundation

/// Reads the system input volume for a capture device.
///
/// The level meter can only show what reaches it, and a microphone whose input
/// volume is turned down delivers speech 30 dB below where it belongs: the bar
/// barely moves, the recording transcribes to nothing, and it all looks exactly
/// like a broken microphone. The slider actually responsible lives in System
/// Settings ▸ Sound ▸ Input, so Cue has to be able to name it.
enum AudioInputGain {

    /// Input volume of the device with this capture `uniqueID`, 0…1, or nil
    /// when the device exposes no adjustable input gain — plenty don't, among
    /// them most USB interfaces and iPhone microphones.
    static func forDevice(uniqueID: String) -> Double? {
        guard let device = deviceID(matching: uniqueID) else { return nil }
        return volume(of: device)
    }

    /// CoreAudio and AVFoundation name devices identically, so a capture
    /// `uniqueID` can be matched straight against `kAudioDevicePropertyDeviceUID`.
    private static func deviceID(matching uniqueID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty,
              AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { self.uid(of: $0) == uniqueID }
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value as String?
    }

    /// Built-in microphones expose a main-element volume; some devices only
    /// carry per-channel ones, so fall through to the first channel that has it.
    private static func volume(of device: AudioDeviceID) -> Double? {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { continue }
            return Double(value)
        }
        return nil
    }
}
