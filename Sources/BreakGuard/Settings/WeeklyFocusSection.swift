import SwiftUI

// "Last 7 Days" section of the Statistics tab: one row per day with the
// focus total and how it compares to the user's weekday or weekend average.
struct WeeklyFocusSection: View {
    let summaries: [DailyFocusSummary]

    var body: some View {
        Section {
            ForEach(summaries) { summary in
                row(for: summary)
            }
        } header: {
            Text("Last 7 Days")
        } footer: {
            Text("Weekdays are compared with your weekday average, weekend days with your weekend average, across all recorded days.")
                .foregroundStyle(.secondary)
        }
    }

    private func row(for summary: DailyFocusSummary) -> some View {
        LabeledContent {
            Text(formatMinutes(summary.minutes))
                .monospacedDigit()
        } label: {
            Text(dayTitle(for: summary.date))
            if let caption = comparisonCaption(for: summary) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dayTitle(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func comparisonCaption(for summary: DailyFocusSummary) -> String? {
        let category = summary.category.title
        switch summary.comparison {
        case .noHistory:
            // A dayless, historyless row carries no signal worth a caption.
            return summary.minutes > 0 ? "No other \(category) days recorded" : nil
        case let .delta(percent):
            if percent == 0 {
                return "Matches your \(category) average"
            }
            let direction = percent > 0 ? "more" : "less"
            return "\(abs(percent))% \(direction) than your \(category) average"
        }
    }
}
