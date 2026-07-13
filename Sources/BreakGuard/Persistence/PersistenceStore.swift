import Foundation
import os

final class PersistenceStore {
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "Persistence")
    // What the file currently holds; save() skips the write when nothing changed.
    private var lastSaved: PersistedAppData?
    let fileURL: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BreakGuard", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("state.json")
    }

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func load() -> PersistedAppData? {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.breakGuard.decode(PersistedAppData.self, from: data)
            guard decoded.schemaVersion == PersistedAppData.currentSchemaVersion else {
                logger.notice("Persistence schema mismatch; resetting stored data")
                return nil
            }
            lastSaved = decoded
            return decoded
        } catch {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                logger.error("Persistence load failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    func save(_ data: PersistedAppData) {
        guard data != lastSaved else { return }
        do {
            let encoded = try JSONEncoder.breakGuard.encode(data)
            let temporary = fileURL.appendingPathExtension("tmp")
            try encoded.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
            lastSaved = data
        } catch {
            logger.error("Persistence save failed: \(error.localizedDescription)")
        }
    }
}

extension JSONEncoder {
    static var breakGuard: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var breakGuard: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
