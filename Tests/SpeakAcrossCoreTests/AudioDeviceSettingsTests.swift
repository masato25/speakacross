import Testing
@testable import SpeakAcrossCore

@Test func audioDeviceCatalogReturnsStableUIDs() throws {
    let devices = try AudioDeviceCatalog.allDevices()
    #expect(!devices.isEmpty)
    #expect(devices.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
    #expect(devices.contains { $0.hasInput })
    #expect(devices.contains { $0.hasOutput })
}

@Test func defaultAudioDeviceUIDsResolveWhenPresent() throws {
    if let input = AudioDeviceCatalog.defaultInputUID() {
        _ = try AudioDeviceCatalog.deviceID(forUID: input)
    }
    if let output = AudioDeviceCatalog.defaultOutputUID() {
        _ = try AudioDeviceCatalog.deviceID(forUID: output)
    }
}
