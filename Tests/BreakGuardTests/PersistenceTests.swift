import Foundation
import XCTest
@testable import BreakGuard

final class PersistenceTests: XCTestCase {
    func testCurrentSchemaRoundTripsTagsAndFocusStatistics() throws {
        let location = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = PersistenceStore(fileURL: location)
        var machine = StateMachine()
        let custom = try machine.addFocusTag(named: "Writing")
        machine.statistics.focusSessionsByTag[custom.id] = 4
        machine.statistics.skippedFocusSessions = 2

        store.save(machine.data)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.schemaVersion, PersistedAppData.currentSchemaVersion)
        XCTAssertEqual(loaded.focusTags, machine.focusTags)
        XCTAssertEqual(loaded.statistics.focusSessionsByTag[custom.id], 4)
        XCTAssertEqual(loaded.statistics.skippedFocusSessions, 2)
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
