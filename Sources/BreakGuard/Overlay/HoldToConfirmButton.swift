import SwiftUI

// Press-and-hold button for actions the app wants to discourage: the action
// fires only after the pointer stays down for `holdDuration`, with a fill
// sweeping the button as visual progress. Releasing early cancels and the
// fill drains back. Assistive technology activates it as a plain button.
struct HoldToConfirmButton: View {
    let title: String
    let holdDuration: TimeInterval
    let action: () -> Void

    @State private var isPressing = false
    @State private var progress: CGFloat = 0

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        Text(title)
            .font(.system(size: 18, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                // Both layers fill the button, so the fill's leading anchor —
                // not stack alignment — is what makes it sweep left to right.
                ZStack {
                    shape
                        .fill(.white.opacity(isPressing ? 0.12 : 0.08))
                    // Scaled rather than resized: a width animation re-runs
                    // layout on every frame of the hold, a transform does not.
                    Rectangle()
                        .fill(.white.opacity(0.28))
                        .scaleEffect(x: progress, anchor: .leading)
                }
                .clipShape(shape)
            )
            .overlay(shape.strokeBorder(.white.opacity(0.25)))
            .contentShape(shape)
            .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 30) {
                action()
            } onPressingChanged: { pressing in
                isPressing = pressing
                if pressing {
                    withAnimation(.linear(duration: holdDuration)) {
                        progress = 1
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) {
                        progress = 0
                    }
                }
            }
            .accessibilityRepresentation {
                Button(title, action: action)
            }
    }
}

// The shorter postponement is the lesser evil, so it needs the shorter hold;
// the longer one demands more deliberation. Compare against the sibling
// duration rather than field order because either setting can be longer.
func postponeHoldDuration(
    for duration: TimeInterval,
    comparedTo other: TimeInterval,
    tier: PostponeHoldTier = .standard
) -> TimeInterval {
    let isLonger = duration > other
    switch tier {
    case .standard:
        return isLonger ? 3 : 1
    case .harder:
        return isLonger ? 6 : 3
    case .repeated:
        return isLonger ? 9 : 3
    }
}
