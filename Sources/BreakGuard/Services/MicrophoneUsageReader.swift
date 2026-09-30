import CoreAudio

protocol AudioActivityPropertyClient: HardwarePropertyClient {
    func deviceID(forUIDOf object: AudioObjectID) -> AudioObjectID?
}

// Process input alone also includes playback taps. Require a current input
// device and active input stream. For aggregates, inspect real subdevices:
// tap-only input must not keep breaks held after a call ends.
struct MicrophoneUsageReader {
    var client: AudioActivityPropertyClient = CoreAudioPropertyClient()

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func isInUse() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        return client.objectIDs(object: AudioObjectID(kAudioObjectSystemObject),
                                selector: kAudioHardwarePropertyProcessObjectList,
                                scope: kAudioObjectPropertyScopeGlobal).contains { process in
            guard client.uint32(object: process, selector: kAudioProcessPropertyIsRunningInput,
                                scope: kAudioObjectPropertyScopeGlobal) == 1 else { return false }
            return client.objectIDs(object: process, selector: kAudioProcessPropertyDevices,
                                    scope: kAudioObjectPropertyScopeInput).contains { device in
                var visited: Set<AudioObjectID> = []
                return hasActiveInput(device, visited: &visited)
            }
        }
    }

    private func hasActiveInput(_ device: AudioObjectID, visited: inout Set<AudioObjectID>) -> Bool {
        guard visited.insert(device).inserted,
              let deviceClass = client.uint32(object: device, selector: kAudioObjectPropertyClass,
                                              scope: kAudioObjectPropertyScopeGlobal) else { return false }

        // AudioSubDevice objects have no streams or IO path. Resolve their UID
        // to the current device instead of reading IO properties on the proxy.
        if deviceClass == kAudioSubDeviceClassID {
            guard let underlying = client.deviceID(forUIDOf: device) else { return false }
            return hasActiveInput(underlying, visited: &visited)
        }

        guard client.uint32(object: device, selector: kAudioDevicePropertyDeviceIsAlive,
                            scope: kAudioObjectPropertyScopeGlobal) == 1,
              client.uint32(object: device, selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                            scope: kAudioObjectPropertyScopeGlobal) == 1,
              client.objectIDs(object: device, selector: kAudioDevicePropertyStreams,
                               scope: kAudioObjectPropertyScopeInput).contains(where: { stream in
                  client.uint32(object: stream, selector: kAudioStreamPropertyDirection,
                                scope: kAudioObjectPropertyScopeGlobal) == 1
                      && (client.uint32(object: stream, selector: kAudioStreamPropertyIsActive,
                                        scope: kAudioObjectPropertyScopeGlobal) ?? 0) != 0
              }) else { return false }

        if deviceClass == kAudioAggregateDeviceClassID {
            return client.objectIDs(object: device, selector: kAudioAggregateDevicePropertyActiveSubDeviceList,
                                    scope: kAudioObjectPropertyScopeGlobal).contains {
                hasActiveInput($0, visited: &visited)
            }
        }
        return true
    }
}

private struct CoreAudioPropertyClient: AudioActivityPropertyClient {
    func dataSize(object: UInt32, selector: UInt32, scope: UInt32) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        return size
    }

    func read(object: UInt32, selector: UInt32, scope: UInt32,
              into buffer: UnsafeMutableRawBufferPointer) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        var used = UInt32(buffer.count)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &used, buffer.baseAddress!) == noErr else {
            return nil
        }
        return used
    }

    func deviceID(forUIDOf object: AudioObjectID) -> AudioObjectID? {
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: uid))
        let status = AudioObjectGetPropertyData(object, &uidAddress, 0, nil, &size, &uid)
        guard status == noErr, size == UInt32(MemoryLayout<Unmanaged<CFString>?>.size), let uid else { return nil }
        let retainedUID = uid.takeRetainedValue()
        return withExtendedLifetime(retainedUID) {
            var uidPointer = Unmanaged.passUnretained(retainedUID).toOpaque()
            var device: AudioObjectID = 0
            size = UInt32(MemoryLayout.size(ofValue: device))
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   UInt32(MemoryLayout.size(ofValue: uidPointer)), &uidPointer,
                                                   &size, &device)
            guard result == noErr, size == UInt32(MemoryLayout<AudioObjectID>.size), device != 0 else { return nil }
            return device
        }
    }
}
