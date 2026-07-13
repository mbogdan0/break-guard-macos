import Foundation
import XCTest
@testable import BreakGuard

private struct FakeClock: TimeProvider {
    var now: Date
}

final class PersistenceTests: XCTestCase {
    func testCurrentSchemaRoundTripsTagsAndFocusStatistics() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        var machine = StateMachine()
        let custom = try machine.addFocusTag(named: "Writing")
        machine.statistics.focusMinutesByTag[custom.id] = 120
        machine.statistics.skippedFocusMinutes = 45
        machine.statistics.focusMinutesByDay = ["2026-07-11": 75, "2026-07-12": 30]

        store.save(machine.data)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.schemaVersion, PersistedAppData.currentSchemaVersion)
        XCTAssertEqual(loaded.focusTags, machine.focusTags)
        XCTAssertEqual(loaded.statistics.focusMinutesByTag[custom.id], 120)
        XCTAssertEqual(loaded.statistics.skippedFocusMinutes, 45)
        XCTAssertEqual(loaded.statistics.focusMinutesByDay, ["2026-07-11": 75, "2026-07-12": 30])
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
        machine.settings.focusTagsEnabled = false
        machine.takeBreakNow()
        machine.startBreak()

        store.save(machine.data)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertFalse(loaded.settings.focusTagsEnabled)
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
