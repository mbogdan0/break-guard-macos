import SwiftUI

struct StatisticsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            WeeklyFocusSection(
                summaries: makeWeeklyFocusSummary(minutesByDay: appState.statistics.focusMinutesByDay)
            )

            Section {
                statisticRow("Total", value: formatMinutes(appState.statistics.totalFocusMinutes))
                    .fontWeight(.semibold)
            } header: {
                Text("Focus Time")
            } footer: {
                Text("Each completed break credits the actual focused time of that cycle.")
                    .foregroundStyle(.secondary)
            }

            Section {
                statisticRow("Current clean streak", value: "\(appState.statistics.currentCleanStreak)")
                statisticRow("Best clean streak", value: "\(appState.statistics.bestCleanStreak)")
                statisticRow("Completed breaks", value: "\(appState.statistics.completedBreaks)")
                statisticRow("Violated cycles", value: "\(appState.statistics.violatedCycles)")
                statisticRow("Total postponements", value: "\(appState.statistics.totalPostponements)")
                statisticRow("Last completed break", value: lastCompletedBreakText)
            } header: {
                Text("Break History")
            } footer: {
                Text("A clean streak grows when a full break is completed without postponing it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Statistics…", role: .destructive) {
                        showResetConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset statistics?", isPresented: $showResetConfirmation) {
            Button("Reset Statistics", role: .destructive) {
                appState.resetStatistics()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears focus time totals, daily focus history, streaks, completed breaks, violations, and postponement counts.")
        }
    }

    private var lastCompletedBreakText: String {
        guard let date = appState.statistics.lastCompletedBreakDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func statisticRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
        }
    }
}
