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
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        shape
                            .fill(.white.opacity(isPressing ? 0.12 : 0.08))
                        Rectangle()
                            .fill(.white.opacity(0.28))
                            .frame(width: geometry.size.width * progress)
                    }
                    .clipShape(shape)
                }
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
// the longer one demands more deliberation. Compared against the sibling
// duration rather than the first/second position, because the user is free
// to configure the "first" postponement to be the longer one.
func postponeHoldDuration(for duration: TimeInterval, comparedTo other: TimeInterval) -> TimeInterval {
    duration <= other ? 2 : 5
}
