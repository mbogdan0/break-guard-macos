import SwiftUI

struct RestEncouragementView: View {
    let status: RestEncouragement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        guard status.canFinish else { return .white.opacity(0.6) }
        // Every small gain changes the color, without waiting for a large tier.
        let colors: [(Double, Double, Double)] = [
            (0.65, 0.80, 0.74), (0.31, 0.91, 0.63),
            (0.40, 0.82, 0.95), (0.77, 0.65, 1)
        ]
        let position = status.progress * Double(colors.count - 1)
        let index = min(Int(position), colors.count - 2)
        let blend = position - Double(index)
        let from = colors[index]
        let to = colors[index + 1]
        return Color(red: from.0 + (to.0 - from.0) * blend,
                     green: from.1 + (to.1 - from.1) * blend,
                     blue: from.2 + (to.2 - from.2) * blend)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text(status.message.emoji)
                    .font(.system(size: 32))
                    .frame(width: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(status.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(status.message.text)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                }
                .id("\(status.canFinish)-\(status.messageIndex)")
                .transition(.opacity)
            }
            if status.canFinish {
                ProgressView(value: status.progress)
                    .tint(tint)
                    .accessibilityLabel("Extra rest progress")
                HStack {
                    Text(status.progress >= 1 ? "A lovely long rest" : "Every extra moment counts")
                    Spacer()
                    Text("Next boost in \(Int(ceil(status.secondsToNextReward)))s")
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            }

        }
        .padding(18)
        .frame(maxWidth: 460)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [tint.opacity(0.13), tint.opacity(0.04)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: tint.opacity(glowOpacity), radius: 18)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1), value: status.messageIndex)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1), value: status.canFinish)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1), value: glowOpacity)
    }

    // A slow, small glow uses the overlay's existing one-second timeline.
    private var glowOpacity: Double {
        guard status.canFinish, status.progress >= 0.75 else { return 0 }
        guard !reduceMotion else { return 0.12 }
        return 0.12 + 0.04 * sin(status.extraRest * .pi / 4)
    }
}
