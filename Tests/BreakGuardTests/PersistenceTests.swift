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

        store.save(machine.data)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.schemaVersion, PersistedAppData.currentSchemaVersion)
        XCTAssertEqual(loaded.focusTags, machine.focusTags)
        XCTAssertEqual(loaded.statistics.focusMinutesByTag[custom.id], 120)
        XCTAssertEqual(loaded.statistics.skippedFocusMinutes, 45)
    }

    func testSchemaV2MigratesKeepingEverythingButFocusCounters() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        var machine = StateMachine()
        machine.statistics.currentCleanStreak = 4
        machine.statistics.bestCleanStreak = 6
        machine.statistics.completedBreaks = 9

        // Rewrite the payload into schema-2 shape: session counters instead of minutes.
        let encoded = try JSONEncoder.breakGuard.encode(machine.data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 2
        var statistics = try XCTUnwrap(object["statistics"] as? [String: Any])
        statistics.removeValue(forKey: "focusMinutesByTag")
        statistics.removeValue(forKey: "skippedFocusMinutes")
        statistics["focusSessionsByTag"] = ["work": 5]
        statistics["skippedFocusSessions"] = 2
        object["statistics"] = statistics
        try JSONSerialization.data(withJSONObject: object).write(to: location)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.schemaVersion, PersistedAppData.currentSchemaVersion)
        XCTAssertTrue(loaded.statistics.focusMinutesByTag.isEmpty)
        XCTAssertEqual(loaded.statistics.skippedFocusMinutes, 0)
        XCTAssertEqual(loaded.statistics.currentCleanStreak, 4)
        XCTAssertEqual(loaded.statistics.bestCleanStreak, 6)
        XCTAssertEqual(loaded.statistics.completedBreaks, 9)
        XCTAssertEqual(loaded.settings, machine.settings)
        XCTAssertEqual(loaded.focusTags, machine.focusTags)
    }

    func testSchema3WithoutNewFieldsStillLoads() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)

        // Rewrite the payload into the pre-focusTagsEnabled schema-3 shape.
        let encoded = try JSONEncoder.breakGuard.encode(StateMachine().data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "focusTagsEnabled")
        object["settings"] = settings
        var runtime = try XCTUnwrap(object["runtime"] as? [String: Any])
        runtime.removeValue(forKey: "breakStartedAt")
        runtime.removeValue(forKey: "manualBreakOrigin")
        object["runtime"] = runtime
        try JSONSerialization.data(withJSONObject: object).write(to: location)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertTrue(loaded.settings.focusTagsEnabled)
        XCTAssertNil(loaded.runtime.breakStartedAt)
        XCTAssertNil(loaded.runtime.manualBreakOrigin)
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

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BreakGuardTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }
}
