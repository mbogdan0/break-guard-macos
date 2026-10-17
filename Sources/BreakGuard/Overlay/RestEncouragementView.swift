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
        VStack(alignment: .leading, spacing: 14) {
            if status.canFinish {
                HStack {
                    Text(status.scale.name)
                    Spacer()
                    Text("Self-care · \(status.stageIndex + 1)/4")
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            }

            statusContent
                .id("\(status.canFinish)-\(status.scaleIndex)-\(status.messageIndex)")
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 5)),
                    removal: .opacity
                ))

            if status.canFinish {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(status.stageTitle)
                        Spacer()
                        if status.progress >= 1 {
                            Image(systemName: "checkmark.circle.fill")
                                .accessibilityLabel("Stage complete")
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(height: 16)

                    ProgressView(value: status.progress)
                        .tint(tint)
                        .accessibilityLabel("Self-care stage progress")
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: status.progress)
                }
                // A new stage fades in with a fresh bar instead of draining the old one.
                .id(status.stageIndex)
                .transition(.opacity)

                HStack {
                    Text(status.secondsToNextReward == 0 ? "Stay as long as you like" : "Time for yourself")
                    Spacer()
                    if status.secondsToNextReward > 0 {
                        Text("Next step in \(formatDurationCompact(ceil(status.secondsToNextReward)))")
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(18)
        .frame(maxWidth: 460)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text(status.message.emoji)
                    .font(.system(size: 36))
                    .frame(width: 48, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(status.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(status.message.text)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                }
            }
            if let reflection = status.reflection {
                Text(reflection)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
        }
    }
}
