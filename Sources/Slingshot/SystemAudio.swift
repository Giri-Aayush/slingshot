import SlingshotCore
import CoreAudio
import Foundation

// MARK: - System audio devices

/// The current system default input device.
func defaultInputDeviceID() -> AudioDeviceID? {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
          device != kAudioObjectUnknown else { return nil }
    return device
}

/// The Mac's built-in microphone, if it has one with input streams. Bluetooth
/// speakers take the default-input role the moment they connect, and their
/// far-field mics hear neither snaps nor claps; sound features pin to this.
func builtInInputDeviceID() -> AudioDeviceID? {
    var listAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size) == noErr,
          size > 0 else { return nil }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &devices) == noErr
    else { return nil }

    for device in devices {
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &transportAddr, 0, nil, &tSize, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { continue }
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var sSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streamsAddr, 0, nil, &sSize) == noErr, sSize > 0 else { continue }
        return device
    }
    return nil
}

// MARK: - System mute

/// Toggle the default output device's mute. Returns the new state (true means
/// now muted), or nil if the device refused. Blocking; call off the main
/// thread. CoreAudio first; devices with no mute control fall back to the
/// system volume setting.
func toggleSystemOutputMute() -> Bool? {
    if let muted = coreAudioToggleMute() { return muted }
    let script = """
    set volume output muted not (output muted of (get volume settings))
    output muted of (get volume settings)
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let out = Pipe()
    p.standardOutput = out
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        log("❌ osascript mute fallback failed to launch: \(error)")
        return nil
    }
    guard p.terminationStatus == 0 else { return nil }
    let answer = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return answer.map { $0 == "true" }
}

private func coreAudioToggleMute() -> Bool? {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var deviceAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddr,
                                     0, nil, &size, &device) == noErr,
          device != kAudioObjectUnknown else { return nil }

    var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var settable = DarwinBoolean(false)
    guard AudioObjectHasProperty(device, &muteAddr),
          AudioObjectIsPropertySettable(device, &muteAddr, &settable) == noErr,
          settable.boolValue else { return nil }

    var muted: UInt32 = 0
    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &muteSize, &muted) == noErr else { return nil }
    var flipped: UInt32 = muted == 0 ? 1 : 0
    guard AudioObjectSetPropertyData(device, &muteAddr, 0, nil, muteSize, &flipped) == noErr else { return nil }
    return flipped == 1
}
