import CoreMediaIO
import Foundation
import os

// Watches whether any camera on the system is in use by any process, via
// CoreMediaIO's DeviceIsRunningSomewhere property. Reading device state is
// not capturing: it needs no camera entitlement and triggers no TCC prompt.
// Fully event-driven — listener blocks on the main queue, no polling.
@MainActor
final class CameraUsageMonitor {
    private weak var appState: AppState?
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "CameraUsageMonitor")

    private static let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
    private var watchedDevices: [CMIOObjectID] = []
    private var lastReportedActive = false

    private var runningAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    private var devicesAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    init(appState: AppState) {
        self.appState = appState
        // Cameras come and go (Continuity Camera, USB webcams), so the device
        // list itself is watched and the per-device listeners are rebuilt.
        CMIOObjectAddPropertyListenerBlock(Self.systemObject, &devicesAddress, .main) { [weak self] _, _ in
            Task { @MainActor in self?.rebuildDeviceListeners() }
        }
        rebuildDeviceListeners()
    }

    private func rebuildDeviceListeners() {
        for device in watchedDevices {
            CMIOObjectRemovePropertyListenerBlock(device, &runningAddress, .main, deviceListener)
        }
        watchedDevices = currentDevices()
        for device in watchedDevices {
            CMIOObjectAddPropertyListenerBlock(device, &runningAddress, .main, deviceListener)
        }
        refresh()
    }

    // One shared block so remove can match the registration.
    private lazy var deviceListener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.refresh() }
    }

    private func refresh() {
        let active = watchedDevices.contains { isRunningSomewhere($0) }
        guard active != lastReportedActive else { return }
        lastReportedActive = active
        appState?.setCameraActive(active)
    }

    private func currentDevices() -> [CMIOObjectID] {
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(Self.systemObject, &devicesAddress, 0, nil, &dataSize) == kCMIOHardwareNoError,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        let status = devices.withUnsafeMutableBytes { buffer in
            CMIOObjectGetPropertyData(
                Self.systemObject, &devicesAddress, 0, nil,
                dataSize, &dataUsed, buffer.baseAddress
            )
        }
        guard status == kCMIOHardwareNoError else {
            logger.error("Device enumeration failed: \(status, privacy: .public)")
            return []
        }
        return devices
    }

    private func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var running: UInt32 = 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            device, &runningAddress, 0, nil,
            dataSize, &dataUsed, &running
        )
        return status == kCMIOHardwareNoError && running != 0
    }
}
