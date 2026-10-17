import Foundation

struct RestEncouragement {
    struct Message {
        let emoji: String
        let text: String
    }

    // Seconds after the required break ends. Short, uneven gaps gradually
    // widen as staying on the break becomes less of an immediate decision.
    static let rewardOffsets: [TimeInterval] = [
        0, 7, 23, 40, 53, 72, 90, 113, 136, 154, 178, 200, 227, 254, 275, 302, 326, 356, 385, 409, 439, 465, 497, 529, 555, 586, 615, 649, 682, 710, 743, 773, 809, 844, 873, 908, 940, 977, 1013, 1044, 1080, 1200, 1320, 1440, 1560, 1680, 1800, 1920
    ]
    static let messages: [Message] = [
        Message(emoji: "😴", text: "The required rest is done. Give yourself a little more."),
        Message(emoji: "🥱", text: "A few extra seconds. A good choice."),
        Message(emoji: "😮‍💨", text: "Stay for another slow breath."),
        Message(emoji: "🫧", text: "You kept a little more time for yourself."),
        Message(emoji: "🥺", text: "No rush. Let the pause last a little longer."),
        Message(emoji: "🐢", text: "Another quiet moment is yours."),
        Message(emoji: "🪶", text: "You are going beyond the countdown."),
        Message(emoji: "🌱", text: "Your extra rest is beginning to grow."),
        Message(emoji: "😌", text: "A little extra breathing room. Keep it going."),
        Message(emoji: "🙂", text: "Stay a little longer. You have made room."),
        Message(emoji: "🍃", text: "Let another quiet moment pass."),
        Message(emoji: "🌿", text: "A little more rest is worth your time."),
        Message(emoji: "😊", text: "No need to jump straight back in."),
        Message(emoji: "🫖", text: "Let this pause steep a little longer."),
        Message(emoji: "☁️", text: "Nothing to solve for the next few breaths."),
        Message(emoji: "🌤️", text: "The next small step is close."),
        Message(emoji: "🌼", text: "Your pause has room to bloom."),
        Message(emoji: "😎", text: "You are getting good at stepping away."),
        Message(emoji: "🌳", text: "Let the break put down roots."),
        Message(emoji: "🦋", text: "Let your attention wander somewhere new."),
        Message(emoji: "🏞️", text: "Look beyond the screen. Stay there a while."),
        Message(emoji: "🐌", text: "No prize for rushing this part."),
        Message(emoji: "🍵", text: "A quiet pause is time well spent."),
        Message(emoji: "💚", text: "Keep a little more of this time for yourself."),
        Message(emoji: "🌈", text: "That is a generous pause."),
        Message(emoji: "🙌", text: "You made space for more than a quick stop."),
        Message(emoji: "🌻", text: "Let this unhurried moment keep growing."),
        Message(emoji: "🧘", text: "For now, just being here is enough."),
        Message(emoji: "🕊️", text: "Give the next task a little more distance."),
        Message(emoji: "🏝️", text: "Enjoy this small island of quiet."),
        Message(emoji: "💎", text: "This time belongs to you. Keep some more."),
        Message(emoji: "🌊", text: "Let the busy part of the day drift away."),
        Message(emoji: "🌟", text: "A stretch of quiet worth celebrating."),
        Message(emoji: "✨", text: "You gave yourself a real stretch of quiet."),
        Message(emoji: "🥳", text: "That is a brilliant commitment to your break."),
        Message(emoji: "🪄", text: "A little everyday magic: making time for you."),
        Message(emoji: "🌙", text: "Stay in this calm for a little longer."),
        Message(emoji: "💫", text: "There is still room for a few quiet minutes."),
        Message(emoji: "🦄", text: "An unusually lovely amount of breathing room."),
        Message(emoji: "🌠", text: "You have made plenty of room for rest."),
        Message(emoji: "🚀", text: "You took this break to space."),
        Message(emoji: "🌌", text: "A whole pocket of calm in a busy day."),
        Message(emoji: "🪐", text: "You are in your own quiet orbit now."),
        Message(emoji: "🏆", text: "Rest milestone reached. Nicely done."),
        Message(emoji: "👑", text: "You made time for yourself. Own that choice."),
        Message(emoji: "🎉", text: "A long pause deserves a little celebration."),
        Message(emoji: "🛸", text: "No next level to chase. Enjoy the quiet."),
        Message(emoji: "♾️", text: "Stay if you like. Return when you are ready."),
    ]

    let elapsed: TimeInterval
    let requiredDuration: TimeInterval
    let canFinish: Bool

    init(elapsed: TimeInterval, requiredDuration: TimeInterval, canFinish: Bool) {
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.requiredDuration = requiredDuration.isFinite ? max(0, requiredDuration) : 0
        self.canFinish = canFinish
    }

    var extraRest: TimeInterval { max(0, elapsed - requiredDuration) }
    var goal: TimeInterval { max(60, 20 * 60 - requiredDuration) }

    var messageIndex: Int {
        guard canFinish else { return 0 }
        let lastOffset = Self.rewardOffsets.last!
        if extraRest >= lastOffset + 120 {
            // After the complete sequence, rotate only the final calm messages.
            return 40 + Int(((extraRest - lastOffset - 120) / 120)
                .truncatingRemainder(dividingBy: 8))
        }
        return Self.rewardOffsets.lastIndex(where: { extraRest >= $0 }) ?? 0
    }

    var message: Message {
        canFinish ? Self.messages[messageIndex]
            : Message(emoji: "😌", text: "Let yourself rest. There is nothing to do right now.")
    }

    var title: String {
        guard canFinish else { return "Required rest" }
        if extraRest >= goal { return "Cosmic calm" }
        switch extraRest {
        case ..<60: return "A little more for yourself"
        case ..<180: return "Room to unwind"
        case ..<480: return "Finding your calm"
        default: return "Stellar rest"
        }
    }

    // Logarithmic progress makes the first voluntary seconds count visibly.
    // It never resets at a reward, and slows smoothly toward the long-rest goal.
    var progress: Double {
        guard canFinish else { return 0 }
        return min(1, log1p(extraRest / 60) / log1p(goal / 60))
    }

    var secondsToNextReward: TimeInterval {
        guard canFinish else { return 0 }
        if let next = Self.rewardOffsets.first(where: { $0 > extraRest }) {
            return next - extraRest
        }
        return 120 - (extraRest - Self.rewardOffsets.last!)
            .truncatingRemainder(dividingBy: 120)
    }
}
