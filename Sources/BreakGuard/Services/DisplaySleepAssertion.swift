import Foundation
import IOKit.pwr_mgt
import os

@MainActor
protocol SleepAssertionClient {
    func create(type: String, timeout: TimeInterval) -> IOPMAssertionID?
    func release(_ id: IOPMAssertionID)
}

@MainActor
private struct SystemSleepAssertionClient: SleepAssertionClient {
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "DisplaySleepAssertion")

    func create(type: String, timeout: TimeInterval) -> IOPMAssertionID? {
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: type,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
            kIOPMAssertionNameKey as String: "BreakGuard break overlay",
            kIOPMAssertionTimeoutKey as String: timeout,
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String
        ]
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
        guard status == kIOReturnSuccess else {
            logger.error("Sleep assertion failed: \(status, privacy: .public)")
            return nil
        }
        return id
    }

    func release(_ id: IOPMAssertionID) {
        // The timeout may have released it already.
        IOPMAssertionRelease(id)
    }
}

// Prevents automatic display and system sleep while the timer or completion
// screen is visible. Manual sleep, closing the lid, and locking still work.
// Renewed assertions have bounded lifetimes, even if teardown is missed.
@MainActor
final class DisplaySleepAssertion {
    private let client: SleepAssertionClient
    private var ids: [String: IOPMAssertionID] = [:]
    private var renewAt: TimeInterval?
    private static let types = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
        kIOPMAssertionTypePreventUserIdleSystemSleep as String
    ]

    init(client: SleepAssertionClient? = nil) {
        self.client = client ?? SystemSleepAssertionClient()
    }

    // Uptime, rather than wall-clock time: changing the clock must not let a
    // live overlay's assertions expire before their next renewal.
    func hold(timeout: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let renewAt, now < renewAt { return }
        let ceiling = Self.ceiling(for: timeout)
        var succeeded = true
        for type in Self.types {
            guard let newID = client.create(type: type, timeout: ceiling) else {
                succeeded = false
                continue
            }
            // Create before releasing the previous assertion. A failed renewal
            // leaves its remaining coverage intact and retries next tick.
            if let oldID = ids.updateValue(newID, forKey: type) { client.release(oldID) }
        }
        renewAt = succeeded ? now + Self.renewalInterval(for: ceiling) : nil
    }

    func release() {
        for id in ids.values { client.release(id) }
        ids.removeAll()
        renewAt = nil
    }

    nonisolated static func ceiling(for timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite else { return 60 }
        return max(60, timeout)
    }

    nonisolated static func renewalInterval(for ceiling: TimeInterval) -> TimeInterval {
        ceiling / 2
    }
}
