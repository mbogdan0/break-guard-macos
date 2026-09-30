import CoreMediaIO

// Read-only device properties: no stream is opened and no capture permission
// is requested. Enumerate fresh IDs on every read, including after sleep.
struct CameraUsageReader {
    var client: HardwarePropertyClient = CoreMediaIOPropertyClient()

    func isInUse() -> Bool {
        client.objectIDs(object: UInt32(kCMIOObjectSystemObject),
                         selector: UInt32(kCMIOHardwarePropertyDevices),
                         scope: UInt32(kCMIOObjectPropertyScopeGlobal)).contains { device in
            client.uint32(object: device, selector: UInt32(kCMIODevicePropertyDeviceIsAlive),
                          scope: UInt32(kCMIOObjectPropertyScopeGlobal)) == 1
                && !client.objectIDs(object: device, selector: UInt32(kCMIODevicePropertyStreams),
                                     scope: UInt32(kCMIODevicePropertyScopeInput)).isEmpty
                && client.uint32(object: device, selector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                 scope: UInt32(kCMIOObjectPropertyScopeGlobal)) == 1
        }
    }
}

private struct CoreMediaIOPropertyClient: HardwarePropertyClient {
    func dataSize(object: UInt32, selector: UInt32, scope: UInt32) -> UInt32? {
        var address = CMIOObjectPropertyAddress(mSelector: selector, mScope: scope,
                                               mElement: UInt32(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == kCMIOHardwareNoError else {
            return nil
        }
        return size
    }

    func read(object: UInt32, selector: UInt32, scope: UInt32,
              into buffer: UnsafeMutableRawBufferPointer) -> UInt32? {
        var address = CMIOObjectPropertyAddress(mSelector: selector, mScope: scope,
                                               mElement: UInt32(kCMIOObjectPropertyElementMain))
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(buffer.count),
                                       &used, buffer.baseAddress) == kCMIOHardwareNoError else { return nil }
        return used
    }
}
