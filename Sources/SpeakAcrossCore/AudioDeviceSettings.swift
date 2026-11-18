import Foundation
import CoreAudio

public struct AudioDeviceInfo: Identifiable, Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool

    public init(id: String, name: String, hasInput: Bool, hasOutput: Bool) {
        self.id = id
        self.name = name
        self.hasInput = hasInput
        self.hasOutput = hasOutput
    }
}

public struct AudioDevicePreferences: Equatable, Sendable, Codable {
    public var inputUID: String?
    public var outputUID: String?

    public init(inputUID: String? = nil, outputUID: String? = nil) {
        self.inputUID = inputUID
        self.outputUID = outputUID
    }
}

public enum AudioDeviceSettingsError: LocalizedError {
    case coreAudio(OSStatus, String)
    case deviceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .coreAudio(let status, let operation):
            "CoreAudio failed while \(operation) (OSStatus \(status))."
        case .deviceNotFound(let uid):
            "The selected audio device is no longer available: \(uid)"
        }
    }
}

public enum AudioDeviceCatalog {
    public static func allDevices() throws -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else {
            throw AudioDeviceSettingsError.coreAudio(status, "listing audio devices")
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                system,
                &address,
                0,
                nil,
                &size,
                buffer.baseAddress!
            )
        }
        guard status == noErr else {
            throw AudioDeviceSettingsError.coreAudio(status, "reading audio devices")
        }

        return ids.compactMap { id in
            guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName) else {
                return nil
            }

            let hasInput = hasStreams(id, scope: kAudioDevicePropertyScopeInput)
            let hasOutput = hasStreams(id, scope: kAudioDevicePropertyScopeOutput)
            guard hasInput || hasOutput else { return nil }

            return AudioDeviceInfo(
                id: uid,
                name: name,
                hasInput: hasInput,
                hasOutput: hasOutput
            )
        }
        .sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.id < rhs.id }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func deviceID(forUID uid: String) throws -> AudioDeviceID {
        guard let device = try allDeviceIDs().first(where: {
            stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid
        }) else {
            throw AudioDeviceSettingsError.deviceNotFound(uid)
        }
        return device
    }

    public static func defaultInputUID() -> String? {
        defaultDeviceUID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    public static func defaultOutputUID() -> String? {
        defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else {
            throw AudioDeviceSettingsError.coreAudio(status, "listing audio device IDs")
        }

        var ids = Array(
            repeating: AudioDeviceID(0),
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else {
            throw AudioDeviceSettingsError.coreAudio(status, "reading audio device IDs")
        }
        return ids
    }

    private static func stringProperty(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func hasStreams(
        _ device: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func defaultDeviceUID(
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr else {
            return nil
        }
        return stringProperty(device, selector: kAudioDevicePropertyDeviceUID)
    }
}

public enum AudioDevicePreferenceStore {
    public static func load() -> AudioDevicePreferences {
        guard let data = try? Data(contentsOf: fileURL),
              let preferences = try? JSONDecoder().decode(AudioDevicePreferences.self, from: data) else {
            return AudioDevicePreferences()
        }
        return preferences
    }

    public static func save(_ preferences: AudioDevicePreferences) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(preferences)
        try data.write(to: fileURL, options: .atomic)
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return base
            .appendingPathComponent("SpeakAcross", isDirectory: true)
            .appendingPathComponent("audio-devices.json")
    }
}
