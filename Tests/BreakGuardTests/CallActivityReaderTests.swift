import CoreAudio
import CoreMediaIO
import XCTest
@testable import BreakGuard

private struct PropertyKey: Hashable {
    var object: UInt32
    var selector: UInt32
    var scope: UInt32
}

private struct PropertyReply {
    var bytes: [UInt8]
    var capacity: UInt32
    var used: UInt32
    var sizeFails = false
    var readFails = false

    init(_ words: [UInt32]) {
        bytes = words.withUnsafeBytes { Array($0) }
        capacity = UInt32(bytes.count)
        used = capacity
    }
}

// All hardware responses are supplied in memory. These tests never inspect
// the user's devices, open streams, or ask for capture permissions.
private final class ActivityProperties: AudioActivityPropertyClient {
    var replies: [PropertyKey: PropertyReply] = [:]
    var underlyingDevices: [UInt32: UInt32] = [:]
    var reads: [PropertyKey] = []
    var sizeReads: [PropertyKey] = []
    var uidReads: [UInt32] = []

    func set(_ object: UInt32, _ selector: UInt32, _ scope: UInt32, _ values: [UInt32]) {
        replies[PropertyKey(object: object, selector: selector, scope: scope)] = PropertyReply(values)
    }

    func dataSize(object: UInt32, selector: UInt32, scope: UInt32) -> UInt32? {
        let key = PropertyKey(object: object, selector: selector, scope: scope)
        sizeReads.append(key)
        guard let reply = replies[key], !reply.sizeFails else { return nil }
        return reply.capacity
    }

    func read(object: UInt32, selector: UInt32, scope: UInt32,
              into buffer: UnsafeMutableRawBufferPointer) -> UInt32? {
        let key = PropertyKey(object: object, selector: selector, scope: scope)
        reads.append(key)
        guard let reply = replies[key], !reply.readFails else { return nil }
        for index in 0..<min(reply.bytes.count, buffer.count) { buffer[index] = reply.bytes[index] }
        return reply.used
    }

    func deviceID(forUIDOf object: AudioObjectID) -> AudioObjectID? {
        uidReads.append(object)
        return underlyingDevices[object]
    }

    func camera(_ id: UInt32, alive: UInt32 = 1, running: UInt32 = 1, inputs: [UInt32] = [100]) {
        set(id, UInt32(kCMIODevicePropertyDeviceIsAlive), UInt32(kCMIOObjectPropertyScopeGlobal), [alive])
        set(id, UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere), UInt32(kCMIOObjectPropertyScopeGlobal), [running])
        set(id, UInt32(kCMIODevicePropertyStreams), UInt32(kCMIODevicePropertyScopeInput), inputs)
    }

    @available(macOS 14.2, *)
    func process(_ id: UInt32, running: UInt32 = 1, inputs: [UInt32]) {
        set(id, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, [running])
        set(id, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput, inputs)
    }

    func audioDevice(_ id: UInt32, alive: UInt32 = 1, running: UInt32 = 1,
                     deviceClass: UInt32 = kAudioDeviceClassID, inputs: [UInt32] = [100]) {
        set(id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, [alive])
        set(id, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, [deviceClass])
        set(id, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, [running])
        set(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, inputs)
        for stream in inputs { audioStream(stream) }
    }

    func audioStream(_ id: UInt32, direction: UInt32 = 1, active: UInt32 = 1) {
        set(id, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal, [direction])
        set(id, kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal, [active])
    }
}

final class HardwarePropertyClientTests: XCTestCase {
    private let key = PropertyKey(object: 10, selector: 20, scope: 30)

    func testShrinkingListUsesReturnedCountAndIgnoresEmptyIDs() {
        let client = ActivityProperties()
        var reply = PropertyReply([41, 0])
        reply.capacity = 16
        client.replies[key] = reply
        XCTAssertEqual(client.objectIDs(object: 10, selector: 20, scope: 30), [41])
        reply.used = 0
        client.replies[key] = reply
        XCTAssertEqual(client.objectIDs(object: 10, selector: 20, scope: 30), [])
    }

    func testInvalidListSizesAndReadErrorsHaveNoActivityEvidence() {
        let client = ActivityProperties()
        var replies: [PropertyReply] = []
        var reply = PropertyReply([41])
        reply.capacity = 3
        replies.append(reply)
        reply = PropertyReply([41])
        reply.capacity = 0
        replies.append(reply)
        reply = PropertyReply([41])
        reply.used = 3
        replies.append(reply)
        reply = PropertyReply([41])
        reply.used = 8
        replies.append(reply)
        reply = PropertyReply([41])
        reply.readFails = true
        replies.append(reply)
        reply = PropertyReply([41])
        reply.sizeFails = true
        replies.append(reply)
        for reply in replies {
            client.replies[key] = reply
            XCTAssertEqual(client.objectIDs(object: 10, selector: 20, scope: 30), [])
        }
    }

    func testScalarFlagsRequireExactlyFourReturnedBytes() {
        let client = ActivityProperties()
        for size: UInt32 in [0, 1, 3, 5, 8] {
            var reply = PropertyReply([1])
            reply.used = size
            client.replies[key] = reply
            XCTAssertNil(client.uint32(object: 10, selector: 20, scope: 30))
        }
        client.replies[key] = PropertyReply([1])
        XCTAssertEqual(client.uint32(object: 10, selector: 20, scope: 30), 1)
        var failed = PropertyReply([1])
        failed.readFails = true
        client.replies[key] = failed
        XCTAssertNil(client.uint32(object: 10, selector: 20, scope: 30))
    }
}

final class CameraUsageReaderTests: XCTestCase {
    private func devices(_ client: ActivityProperties, _ ids: [UInt32]) {
        client.set(UInt32(kCMIOObjectSystemObject), UInt32(kCMIOHardwarePropertyDevices),
                   UInt32(kCMIOObjectPropertyScopeGlobal), ids)
    }

    func testOnlyLiveRunningInputDevicesCount() {
        let client = ActivityProperties()
        let reader = CameraUsageReader(client: client)
        devices(client, [10])
        client.camera(10)
        XCTAssertTrue(reader.isInUse())
        client.camera(10, alive: 0)
        XCTAssertFalse(reader.isInUse())
        client.camera(10, running: 0)
        XCTAssertFalse(reader.isInUse())
        client.camera(10, inputs: [])
        client.set(10, UInt32(kCMIODevicePropertyStreams), UInt32(kCMIODevicePropertyScopeOutput), [100])
        XCTAssertFalse(reader.isInUse(), "Running output devices are not cameras in use")
    }

    func testEveryReadEnumeratesDevicesAgainWithoutNotifications() {
        let client = ActivityProperties()
        let reader = CameraUsageReader(client: client)
        devices(client, [10])
        client.camera(10)
        XCTAssertTrue(reader.isInUse())
        devices(client, [])
        XCTAssertFalse(reader.isInUse(), "A retired ID must not retain its old running flag")
        devices(client, [20])
        client.camera(20, running: 0)
        XCTAssertFalse(reader.isInUse())
        client.camera(20)
        XCTAssertTrue(reader.isInUse())
        client.camera(20, running: 0)
        XCTAssertFalse(reader.isInUse())
        let systemReads = client.sizeReads.filter { $0.object == UInt32(kCMIOObjectSystemObject) }
        XCTAssertEqual(systemReads.count, 5)
    }

    func testReadFailureClearsPriorActivityAndOtherCamerasStillWork() {
        let client = ActivityProperties()
        let reader = CameraUsageReader(client: client)
        devices(client, [10])
        client.camera(10)
        XCTAssertTrue(reader.isInUse())
        client.replies.removeValue(forKey: PropertyKey(object: 10,
            selector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere), scope: UInt32(kCMIOObjectPropertyScopeGlobal)))
        XCTAssertFalse(reader.isInUse())
        devices(client, [10, 20])
        client.camera(20)
        XCTAssertTrue(reader.isInUse())
        devices(client, [])
        XCTAssertFalse(reader.isInUse())
    }
}

final class MicrophoneUsageReaderTests: XCTestCase {
    override func setUpWithError() throws {
        guard MicrophoneUsageReader.isSupported else { throw XCTSkip("Process input detection requires macOS 14.2") }
    }

    @available(macOS 14.2, *)
    private func microphone() -> ActivityProperties {
        let client = ActivityProperties()
        client.set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                   kAudioObjectPropertyScopeGlobal, [10])
        client.process(10, inputs: [20])
        client.audioDevice(20)
        return client
    }

    func testProcessInputMustHaveALiveRunningDeviceAndActiveInputStream() {
        guard #available(macOS 14.2, *) else { return }
        let client = microphone()
        let reader = MicrophoneUsageReader(client: client)
        XCTAssertTrue(reader.isInUse())
        client.process(10, running: 0, inputs: [20])
        XCTAssertFalse(reader.isInUse())
        client.process(10, inputs: [20])
        client.audioDevice(20, alive: 0)
        XCTAssertFalse(reader.isInUse())
        client.audioDevice(20, running: 0)
        XCTAssertFalse(reader.isInUse())
        client.audioDevice(20, inputs: [])
        XCTAssertFalse(reader.isInUse())
        client.audioDevice(20)
        client.audioStream(100, direction: 0)
        XCTAssertFalse(reader.isInUse())
        client.audioStream(100, active: 0)
        XCTAssertFalse(reader.isInUse())
        client.audioStream(100, active: 2)
        XCTAssertTrue(reader.isInUse(), "IsActive accepts any nonzero value")
    }

    func testPlaybackAndStaleInputFlagWithOnlyOutputDevicesDoNotHold() {
        guard #available(macOS 14.2, *) else { return }
        let client = microphone()
        client.process(10, inputs: [])
        client.set(10, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput, [20])
        client.set(10, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, [1])
        XCTAssertFalse(MicrophoneUsageReader(client: client).isInUse())
    }

    func testProcessExitDeviceReplacementAndReadFailuresReleaseActivity() {
        guard #available(macOS 14.2, *) else { return }
        let client = microphone()
        let reader = MicrophoneUsageReader(client: client)
        XCTAssertTrue(reader.isInUse())
        client.set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                   kAudioObjectPropertyScopeGlobal, [])
        XCTAssertFalse(reader.isInUse())
        client.set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                   kAudioObjectPropertyScopeGlobal, [11])
        client.process(11, inputs: [21])
        client.audioDevice(21, inputs: [101])
        XCTAssertTrue(reader.isInUse())
        client.replies.removeValue(forKey: PropertyKey(object: 101, selector: kAudioStreamPropertyIsActive,
                                                      scope: kAudioObjectPropertyScopeGlobal))
        XCTAssertFalse(reader.isInUse())
        client.audioStream(101)
        XCTAssertTrue(reader.isInUse())
        client.process(11, inputs: [])
        XCTAssertFalse(reader.isInUse())
    }

    func testTapOnlyAggregateDoesNotCountAsMicrophoneInput() {
        guard #available(macOS 14.2, *) else { return }
        let client = microphone()
        client.audioDevice(20, deviceClass: kAudioAggregateDeviceClassID)
        client.set(20, kAudioAggregateDevicePropertyActiveSubDeviceList, kAudioObjectPropertyScopeGlobal, [])
        let reader = MicrophoneUsageReader(client: client)
        XCTAssertFalse(reader.isInUse(), "A playback tap has input IO but no input subdevice")
        client.audioDevice(30, inputs: [])
        client.set(20, kAudioAggregateDevicePropertyActiveSubDeviceList, kAudioObjectPropertyScopeGlobal, [30])
        XCTAssertFalse(reader.isInUse(), "Adding an output-only subdevice must not turn a tap into a microphone")
    }

    func testAggregateWithRealMicrophoneAndTapKeepsItsHold() {
        guard #available(macOS 14.2, *) else { return }
        let client = microphone()
        client.audioDevice(20, deviceClass: kAudioAggregateDeviceClassID)
        client.audioDevice(30, inputs: [])
        client.audioDevice(31, inputs: [101])
        client.set(20, kAudioAggregateDevicePropertyActiveSubDeviceList, kAudioObjectPropertyScopeGlobal, [30, 31])
        let reader = MicrophoneUsageReader(client: client)
        XCTAssertTrue(reader.isInUse())
        client.audioStream(101, active: 0)
        XCTAssertFalse(reader.isInUse())
    }

    func testSubdeviceProxyIsResolvedToCurrentDeviceWithoutReadingItsIO() {
        guard #available(macOS 14.2, *) else { return }
        let client = microphone()
        client.audioDevice(20, deviceClass: kAudioAggregateDeviceClassID)
        client.audioDevice(30, deviceClass: kAudioSubDeviceClassID, inputs: [])
        client.replies.removeValue(forKey: PropertyKey(object: 30, selector: kAudioDevicePropertyDeviceIsAlive,
                                                      scope: kAudioObjectPropertyScopeGlobal))
        client.audioDevice(31, inputs: [101])
        client.set(20, kAudioAggregateDevicePropertyActiveSubDeviceList, kAudioObjectPropertyScopeGlobal, [30])
        client.underlyingDevices[30] = 31
        let reader = MicrophoneUsageReader(client: client)
        XCTAssertTrue(reader.isInUse())
        XCTAssertEqual(client.uidReads, [30])
        XCTAssertFalse(client.reads.contains { $0.object == 30 && $0.selector == kAudioDevicePropertyDeviceIsRunningSomewhere })
        client.audioDevice(31, alive: 0, inputs: [101])
        XCTAssertFalse(reader.isInUse())
        client.audioDevice(32, inputs: [102])
        client.underlyingDevices[30] = 32
        XCTAssertTrue(reader.isInUse(), "The proxy UID must resolve again after a device change")
        client.underlyingDevices.removeAll()
        XCTAssertFalse(reader.isInUse())
    }

    func testAggregateCyclesCannotLoopAndOtherValidInputsStillCount() {
        guard #available(macOS 14.2, *) else { return }
        let client = microphone()
        client.audioDevice(20, deviceClass: kAudioAggregateDeviceClassID)
        client.audioDevice(30, deviceClass: kAudioAggregateDeviceClassID, inputs: [101])
        client.set(20, kAudioAggregateDevicePropertyActiveSubDeviceList, kAudioObjectPropertyScopeGlobal, [30])
        client.set(30, kAudioAggregateDevicePropertyActiveSubDeviceList, kAudioObjectPropertyScopeGlobal, [20])
        let reader = MicrophoneUsageReader(client: client)
        XCTAssertFalse(reader.isInUse())
        client.audioDevice(31, inputs: [102])
        client.set(30, kAudioAggregateDevicePropertyActiveSubDeviceList, kAudioObjectPropertyScopeGlobal, [20, 31])
        XCTAssertTrue(reader.isInUse())
    }

    func testInactiveOrUnreadableProcessesCannotHideAnotherActiveInput() {
        guard #available(macOS 14.2, *) else { return }
        let client = microphone()
        client.set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                   kAudioObjectPropertyScopeGlobal, [8, 9, 10])
        client.process(9, running: 0, inputs: [20])
        XCTAssertTrue(MicrophoneUsageReader(client: client).isInUse())
    }
}

final class CallActivitySelectionTests: XCTestCase {
    func testOnlySelectedSourcesEngageHold() {
        let activity = CallActivity(cameraInUse: true, microphoneInUse: true)
        var settings = AppSettings.defaults
        XCTAssertEqual(activity.selected(for: settings), CallActivity(cameraInUse: true))
        settings.holdBreaksWhileOnCamera = false
        XCTAssertFalse(activity.selected(for: settings).isActive)
        settings.holdBreaksWhileMicrophoneInUse = true
        XCTAssertEqual(activity.selected(for: settings), CallActivity(microphoneInUse: true))
        settings.holdBreaksWhileOnCamera = true
        XCTAssertEqual(activity.selected(for: settings), activity)
    }

    func testDisabledMicrophoneIsNotRead() {
        let cameraClient = ActivityProperties()
        let microphoneClient = ActivityProperties()
        let reader = SystemCallActivityClient(camera: CameraUsageReader(client: cameraClient),
                                             microphone: MicrophoneUsageReader(client: microphoneClient))
        XCTAssertEqual(reader.read(includeMicrophone: false), CallActivity())
        XCTAssertTrue(microphoneClient.reads.isEmpty)
        XCTAssertTrue(microphoneClient.sizeReads.isEmpty)
    }
}
