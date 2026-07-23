import SwiftUI

// Press-and-hold button for actions the app wants to discourage: the action
// fires only after the pointer stays down for `holdDuration`, with a fill
// sweeping the button as visual progress. Releasing early cancels and the
// fill drains back. Assistive technology activates it as a plain button.
struct HoldToConfirmButton: View {
    let title: String
    // Static caption at the trailing edge — the hold length, so it can be read
    // rather than discovered by holding. Never animated: it must not join the
    // fill's redraw path.
    var subtitle: String? = nil
    let holdDuration: TimeInterval
    let action: () -> Void

    @State private var isPressing = false
    @State private var progress: CGFloat = 0

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        // With a caption the button reads as a row — label left, hold length
        // right — because a centered title with something pinned beside it
        // looks off-center rather than deliberate. Without one the title keeps
        // the center, and the geometry is what it was before captions existed.
        Group {
            if let subtitle {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 18, weight: .medium))
                    Spacer(minLength: 8)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 14)
            } else {
                Text(title)
                    .font(.system(size: 18, weight: .medium))
            }
        }
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
                Button(subtitle.map { "\(title), \($0)" } ?? title, action: action)
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
    // Harder mode and a repeat postponement price the same: in both the
    // cycle's cheap skip is already gone. The tiers stay distinct in the enum
    // because the reasons are distinct and may not always cost the same.
    case .harder, .repeated:
        return isLonger ? 9 : 3
    }
}

// The hold length as a caption for the button that demands it. A fixed number
// for the life of the overlay — the fill already conveys the progress.
func postponeHoldHint(_ hold: TimeInterval) -> String {
    "Hold \(formatDurationCompact(hold))"
}
