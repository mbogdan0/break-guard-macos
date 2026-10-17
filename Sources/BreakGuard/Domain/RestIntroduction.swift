import Foundation

struct RestIntroduction {
    static let messages: [RestEncouragement.Message] = [
        .init(title: "Required rest", emoji: "😌", text: "Let yourself rest. There is nothing to do right now."),
        .init(title: "A moment for yourself", emoji: "🌿", text: "Put the next task down. This little pause is yours."),
        .init(title: "Room to breathe", emoji: "🍃", text: "Let the day slow down for a moment. You can simply be here."),
        .init(title: "An easy pause", emoji: "☁️", text: "You do not need to fill this time. Let a few quiet moments pass."),
        .init(title: "A little kindness", emoji: "🤍", text: "Give yourself the same care you would offer someone you love."),
        .init(title: "Time to look away", emoji: "🏞️", text: "Let your eyes wander beyond the screen. The next task can wait."),
        .init(title: "A softer pace", emoji: "🐢", text: "There is no hurry inside this pause. Settle into your own pace."),
        .init(title: "Nothing to prove", emoji: "🪶", text: "You do not have to earn your rest. Make yourself comfortable."),
        .init(title: "A quiet corner", emoji: "🫖", text: "Leave a little space around your thoughts. Nothing needs an answer."),
        .init(title: "Let things settle", emoji: "🫧", text: "Let a passing thought keep passing. You can return to it later."),
        .init(title: "Back to yourself", emoji: "🪷", text: "Notice where you are. Let this moment be simple."),
        .init(title: "Care comes first", emoji: "💚", text: "Your needs belong in the day, too. Take this time for yourself."),
        .init(title: "A small stretch of quiet", emoji: "🕊️", text: "Let your hands rest and your shoulders settle. Just pause for a while.")
    ]

    private var breakStartedAt: Date?
    private var current = Self.messages[0]
    private var remaining: [RestEncouragement.Message] = []

    mutating func message(for start: Date?) -> RestEncouragement.Message {
        guard let start else { return current }
        guard start != breakStartedAt else { return current }
        if remaining.isEmpty {
            remaining = Self.messages.shuffled()
            // Avoid repeating the previous pause at the boundary between rounds.
            if remaining.last == current {
                remaining.swapAt(0, remaining.count - 1)
            }
        }
        current = remaining.removeLast()
        breakStartedAt = start
        return current
    }
}
