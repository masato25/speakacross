import AudioToolbox
import CoreAudio
import Foundation

public enum AudioUnitDeviceRouting {
    public static func selectDevice(uid: String?, for audioUnit: AudioUnit) throws {
        guard let uid, !uid.isEmpty else { return }

        var deviceID = try AudioDeviceCatalog.deviceID(forUID: uid)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioDeviceSettingsError.coreAudio(status, "selecting audio device")
        }
    }
}
