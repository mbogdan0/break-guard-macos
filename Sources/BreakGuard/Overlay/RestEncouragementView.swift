import SwiftUI

struct RestEncouragementView: View {
    let status: RestEncouragement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        guard status.canFinish else { return .white.opacity(0.6) }
        let colors = [
            Color(red: 0.57, green: 0.79, blue: 0.70),
            Color(red: 0.49, green: 0.80, blue: 0.79),
            Color(red: 0.56, green: 0.75, blue: 0.89),
            Color(red: 0.74, green: 0.69, blue: 0.91)
        ]
        return colors[status.stageIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusContent
                .id("\(status.canFinish)-\(status.scaleIndex)-\(status.messageIndex)")
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 3)),
                    removal: .opacity
                ))

            if status.canFinish {
                ProgressView(value: status.progress)
                    .tint(tint)
                    .accessibilityLabel("Self-care stage progress")
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: status.progress)
                    .id(status.stageIndex)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: 420)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.04)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: tint.opacity(status.canFinish ? 0.06 + Double(status.stageIndex) * 0.025 : 0), radius: 16)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: status.messageIndex)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: status.canFinish)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: status.stageIndex)
    }

    private var statusContent: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(status.message.emoji)
                .font(.system(size: 32))
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Text(status.quote)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            }
        }
    }
}
