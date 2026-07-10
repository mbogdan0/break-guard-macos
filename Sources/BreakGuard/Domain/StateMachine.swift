import Foundation

struct StateMachine {
    var settings: AppSettings
    var focusTags: [FocusTag]
    var statistics: Statistics
    var runtime: RuntimeState
    var clock: TimeProvider

    init(settings: AppSettings = .defaults, statistics: Statistics = .empty, clock: TimeProvider = SystemClock()) {
        var validated = settings
        validated.clamp()
        self.settings = validated
        self.focusTags = FocusTag.defaults
        self.statistics = statistics
        self.clock = clock
        let warning = clock.now.addingTimeInterval(max(0, validated.workInterval - validated.warningLeadTime))
        let deadline = clock.now.addingTimeInterval(validated.workInterval)
        self.runtime = RuntimeState(
            timerState: .working(deadline: deadline, warningDeadline: warning),
            cycleViolated: false,
            cyclePostponements: 0,
            cycleStartDate: clock.now,
            preservedAt: nil,
            preservedRemaining: nil
        )
    }

    init(data: PersistedAppData, clock: TimeProvider = SystemClock()) {
        var validated = data.settings
        validated.clamp()
        self.settings = validated
        self.focusTags = data.focusTags
        self.statistics = data.statistics
        self.runtime = data.runtime
        self.clock = clock
        restoreAfterSleep()
    }

    var data: PersistedAppData {
        PersistedAppData(
            schemaVersion: PersistedAppData.currentSchemaVersion,
            settings: settings,
            focusTags: focusTags,
            statistics: statistics,
            runtime: runtime
        )
    }

    mutating func tick() -> TimerState {
        switch runtime.timerState {
        case let .working(deadline, warningDeadline):
            if clock.now >= deadline {
                runtime.timerState = .breakDue
            } else if settings.warningLeadTime > 0 && clock.now >= warningDeadline {
                runtime.timerState = .warning(deadline: deadline)
            }
        case let .warning(deadline):
            if clock.now >= deadline {
                runtime.timerState = .breakDue
            }
        case let .postponed(deadline):
            if clock.now >= deadline {
                runtime.timerState = .breakDue
            }
        case let .breaking(deadline, _, _):
            if clock.now >= deadline {
                runtime.timerState = .breakCompleted
            }
        case .breakDue, .breakCompleted, .suspended:
            break
        }
        return runtime.timerState
    }

    mutating func startBreak() {
        let duration = settings.breakDuration
        runtime.timerState = .breaking(
            deadline: clock.now.addingTimeInterval(duration),
            startedAt: clock.now,
            duration: duration
        )
    }

    mutating func completeBreak(classification: FocusClassification) {
        guard runtime.timerState == .breakCompleted else { return }

        switch classification {
        case let .tag(id):
            guard focusTags.contains(where: { $0.id == id }) else { return }
            statistics.focusSessionsByTag[id, default: 0] += 1
        case .skipped:
            statistics.skippedFocusSessions += 1
        }

        statistics.completedBreaks += 1
        statistics.lastCompletedBreakDate = clock.now
        if runtime.cycleViolated {
            statistics.currentCleanStreak = 0
        } else {
            statistics.currentCleanStreak += 1
            statistics.bestCleanStreak = max(statistics.bestCleanStreak, statistics.currentCleanStreak)
        }
        startWorkCycle()
    }

    @discardableResult
    mutating func addFocusTag(named rawName: String) throws -> FocusTag {
        let name = try validatedTagName(rawName)
        let tag = FocusTag(id: UUID().uuidString, name: name)
        focusTags.append(tag)
        return tag
    }

    mutating func renameFocusTag(id: String, to rawName: String) throws {
        guard let index = focusTags.firstIndex(where: { $0.id == id }) else { return }
        let name = try validatedTagName(rawName, excluding: id)
        focusTags[index].name = name
    }

    mutating func deleteFocusTag(id: String) {
        focusTags.removeAll { $0.id == id }
        statistics.focusSessionsByTag.removeValue(forKey: id)
    }

    mutating func startWorkCycle() {
        settings.clamp()
        runtime = RuntimeState(
            timerState: .working(
                deadline: clock.now.addingTimeInterval(settings.workInterval),
                warningDeadline: clock.now.addingTimeInterval(max(0, settings.workInterval - settings.warningLeadTime))
            ),
            cycleViolated: false,
            cyclePostponements: 0,
            cycleStartDate: clock.now,
            preservedAt: nil,
            preservedRemaining: nil
        )
    }

    mutating func postpone(by delay: TimeInterval) {
        let canPostpone: Bool
        if case .breakDue = runtime.timerState {
            canPostpone = true
        } else {
            canPostpone = isBreakingOrCompleted(runtime.timerState)
        }
        guard canPostpone else { return }
        if !runtime.cycleViolated {
            runtime.cycleViolated = true
            statistics.currentCleanStreak = 0
            statistics.violatedCycles += 1
        }
        runtime.cyclePostponements += 1
        statistics.totalPostponements += 1
        runtime.timerState = .postponed(deadline: clock.now.addingTimeInterval(delay))
    }

    mutating func takeBreakNow() {
        runtime.timerState = .breakDue
    }

    mutating func suspend(until: Date?) {
        let previous: SuspendedState
        let remaining: TimeInterval
        switch runtime.timerState {
        case let .working(deadline, _):
            previous = .working
            remaining = deadline.timeIntervalSince(clock.now)
        case let .warning(deadline):
            previous = .warning
            remaining = deadline.timeIntervalSince(clock.now)
        case let .postponed(deadline):
            previous = .postponed
            remaining = deadline.timeIntervalSince(clock.now)
        default:
            return
        }
        runtime.timerState = .suspended(previous: previous, remaining: max(1, remaining), until: until)
        runtime.preservedAt = clock.now
        runtime.preservedRemaining = max(1, remaining)
    }

    mutating func resume() {
        guard case let .suspended(previous, remaining, _) = runtime.timerState else { return }
        switch previous {
        case .working, .warning:
            let deadline = clock.now.addingTimeInterval(remaining)
            let warning = deadline.addingTimeInterval(-settings.warningLeadTime)
            runtime.timerState = clock.now >= warning && settings.warningLeadTime > 0
                ? .warning(deadline: deadline)
                : .working(deadline: deadline, warningDeadline: warning)
        case .postponed:
            runtime.timerState = .postponed(deadline: clock.now.addingTimeInterval(remaining))
        }
        runtime.preservedAt = nil
        runtime.preservedRemaining = nil
    }

    mutating func preserveForSleep() {
        switch runtime.timerState {
        case .working, .warning, .postponed:
            suspend(until: nil)
        case let .breaking(deadline, startedAt, duration):
            let remaining = max(1, deadline.timeIntervalSince(clock.now))
            runtime.timerState = .breaking(deadline: clock.now.addingTimeInterval(remaining), startedAt: startedAt, duration: duration)
            runtime.preservedAt = clock.now
            runtime.preservedRemaining = remaining
        default:
            break
        }
    }

    mutating func restoreAfterSleep() {
        if case let .breaking(_, startedAt, duration) = runtime.timerState,
           let remaining = runtime.preservedRemaining {
            runtime.timerState = .breaking(
                deadline: clock.now.addingTimeInterval(remaining),
                startedAt: startedAt,
                duration: duration
            )
            runtime.preservedAt = nil
            runtime.preservedRemaining = nil
        } else if case .suspended = runtime.timerState {
            resume()
        }
    }

    private func isBreakingOrCompleted(_ state: TimerState) -> Bool {
        if case .breaking = state { return true }
        if case .breakCompleted = state { return true }
        return false
    }

    private func validatedTagName(_ rawName: String, excluding excludedID: String? = nil) throws -> String {
        let name = FocusTag.normalizedName(rawName)
        guard !name.isEmpty else { throw FocusTagNameError.empty }
        guard name.count <= FocusTag.maximumNameLength else { throw FocusTagNameError.tooLong }
        guard !focusTags.contains(where: {
            $0.id != excludedID && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw FocusTagNameError.duplicate
        }
        return name
    }
}
