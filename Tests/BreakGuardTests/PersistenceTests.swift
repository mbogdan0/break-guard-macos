import Foundation
import XCTest
@testable import BreakGuard

private struct FakeClock: TimeProvider {
    var now: Date
}

final class PersistenceTests: XCTestCase {
    func testCurrentSchemaRoundTripsFocusStatistics() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        var machine = StateMachine()
        machine.statistics.focusMinutesByDay = ["2026-07-11": 75, "2026-07-12": 30]

        store.save(machine.data)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.schemaVersion, PersistedAppData.currentSchemaVersion)
        XCTAssertEqual(loaded.statistics.focusMinutesByDay, ["2026-07-11": 75, "2026-07-12": 30])
        XCTAssertEqual(loaded.statistics.totalFocusMinutes, 105)
    }

    // Files written before the focus-tag removal carry extra JSON keys; they
    // must keep decoding under the same schema version so statistics survive.
    func testLegacyFocusTagKeysInStateFileAreIgnored() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        var machine = StateMachine()
        machine.statistics.focusMinutesByDay = ["2026-07-11": 75]

        let encoded = try JSONEncoder.breakGuard.encode(machine.data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["focusTags"] = [["id": "work", "name": "Work"]]
        var statistics = try XCTUnwrap(object["statistics"] as? [String: Any])
        statistics["focusMinutesByTag"] = ["work": 120]
        statistics["skippedFocusMinutes"] = 45
        object["statistics"] = statistics
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings["focusTagsEnabled"] = true
        object["settings"] = settings
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: location)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.statistics.focusMinutesByDay, ["2026-07-11": 75])
    }

    // Fields added after schema 3 shipped (runtime.focusExtended, the working
    // hours settings) are missing from older files; decoding must fall back to
    // defaults instead of discarding the file.
    func testFileWithoutPostSchemaKeysDecodesToDefaults() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)

        let encoded = try JSONEncoder.breakGuard.encode(StateMachine().data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var runtime = try XCTUnwrap(object["runtime"] as? [String: Any])
        runtime.removeValue(forKey: "focusExtended")
        runtime.removeValue(forKey: "completedFocusSessions")
        object["runtime"] = runtime
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "workingHoursEnabled")
        settings.removeValue(forKey: "weekdayWorkingHours")
        settings.removeValue(forKey: "weekendWorkingHours")
        object["settings"] = settings
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: location)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertFalse(loaded.runtime.focusExtended)
        XCTAssertEqual(loaded.runtime.completedFocusSessions, 0)
        XCTAssertFalse(loaded.settings.workingHoursEnabled)
        XCTAssertEqual(loaded.settings.weekdayWorkingHours, WorkingHoursRange(enabled: true))
        XCTAssertEqual(loaded.settings.weekendWorkingHours, WorkingHoursRange(enabled: false))
    }

    func testFocusExtendedAndWorkingHoursRoundTrip() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        let clock = FakeClock(now: Date(timeIntervalSince1970: 9_100))
        var machine = StateMachine(clock: clock)
        machine.extendFocus(by: 15 * 60)
        machine.settings.workingHoursEnabled = true
        machine.settings.weekdayWorkingHours = WorkingHoursRange(
            enabled: true, startMinutes: 11 * 60, endMinutes: 19 * 60
        )
        machine.runtime.completedFocusSessions = 5

        store.save(machine.data)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertTrue(loaded.runtime.focusExtended)
        XCTAssertEqual(loaded.runtime.completedFocusSessions, 5)
        XCTAssertTrue(loaded.settings.workingHoursEnabled)
        XCTAssertEqual(loaded.settings.weekdayWorkingHours.startMinutes, 11 * 60)
        XCTAssertEqual(loaded.settings.weekdayWorkingHours.endMinutes, 19 * 60)
    }

    func testOlderSchemaIsRejected() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        var data = StateMachine().data
        data.schemaVersion = PersistedAppData.currentSchemaVersion - 1
        store.save(data)

        XCTAssertNil(store.load())
    }

    func testManualBreakOriginAndBreakStartRoundTrip() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        // Whole-second dates: the ISO8601 date encoding drops subseconds.
        let clock = FakeClock(now: Date(timeIntervalSince1970: 9_000))
        var machine = StateMachine(clock: clock)
        machine.takeBreakNow()
        machine.startBreak()

        store.save(machine.data)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.runtime.breakStartedAt, machine.runtime.breakStartedAt)
        XCTAssertEqual(loaded.runtime.manualBreakOrigin, machine.runtime.manualBreakOrigin)
    }

    func testUnversionedDataIsRejectedForDestructiveMigration() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        let encoded = try JSONEncoder.breakGuard.encode(StateMachine().data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "schemaVersion")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        try oldData.write(to: location)

        XCTAssertNil(store.load())
    }

    func testMismatchedSchemaIsRejected() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        var data = StateMachine().data
        data.schemaVersion = PersistedAppData.currentSchemaVersion + 1
        store.save(data)

        XCTAssertNil(store.load())
    }

    func testSaveSkipsWriteWhenDataUnchanged() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        let data = StateMachine().data
        store.save(data)

        // Delete the file behind the store's back: an unchanged save must not recreate it.
        try FileManager.default.removeItem(at: location)
        store.save(data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))

        var changed = data
        changed.statistics.completedBreaks += 1
        store.save(changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.path))
    }

    func testLoadSeedsDedupeSoUnchangedDataIsNotRewritten() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        // Whole-second dates: the ISO8601 date encoding drops subseconds.
        let clock = FakeClock(now: Date(timeIntervalSince1970: 9_500))
        PersistenceStore(fileURL: location).save(StateMachine(clock: clock).data)

        let store = PersistenceStore(fileURL: location)
        let loaded = try XCTUnwrap(store.load())
        try FileManager.default.removeItem(at: location)
        store.save(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BreakGuardTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }
}
