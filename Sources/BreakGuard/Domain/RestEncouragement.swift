import Foundation

struct RestEncouragement {
    struct Message {
        let title: String
        let emoji: String
        let text: String
    }

    // Seconds after the required break ends. Short, uneven gaps gradually
    // widen as staying on the break becomes less of an immediate decision.
    static let rewardOffsets: [TimeInterval] = [
        0, 7, 23, 40, 53, 72, 90, 113, 136, 154, 178, 200, 227, 254, 275, 302, 326, 356, 385, 409, 439, 465, 497, 529, 555, 586, 615, 649, 682, 710, 743, 773, 809, 844, 873, 908, 940, 977, 1013, 1044, 1080, 1200, 1320, 1440, 1560, 1680, 1800, 1920, 2040, 2160, 2280, 2400, 2520, 2640, 2760, 2880
    ]
    static let messages: [Message] = [
        Message(title: "A little more rest", emoji: "😴", text: "The required rest is done. Give yourself a little more."),
        Message(title: "An easy start", emoji: "🥱", text: "A few extra seconds. A good choice."),
        Message(title: "One slow breath", emoji: "😮‍💨", text: "Stay for another slow breath."),
        Message(title: "Time for yourself", emoji: "🫧", text: "You kept a little more time for yourself."),
        Message(title: "No need to hurry", emoji: "🥺", text: "No rush. Let the pause last a little longer."),
        Message(title: "A gentler pace", emoji: "🐢", text: "Another quiet moment is yours."),
        Message(title: "Beyond the countdown", emoji: "🪶", text: "You are going beyond the countdown."),
        Message(title: "Room to grow", emoji: "🌱", text: "Your extra rest is beginning to grow."),
        Message(title: "Breathing room", emoji: "😌", text: "A little extra breathing room. Keep it going."),
        Message(title: "A welcome pause", emoji: "🙂", text: "Stay a little longer. You have made room."),
        Message(title: "A passing breeze", emoji: "🍃", text: "Let another quiet moment pass."),
        Message(title: "A moment of green", emoji: "🌿", text: "A little more rest is worth your time."),
        Message(title: "An easy smile", emoji: "😊", text: "No need to jump straight back in."),
        Message(title: "Let it steep", emoji: "🫖", text: "Let this pause steep a little longer."),
        Message(title: "Cloud watching", emoji: "☁️", text: "Nothing to solve for the next few breaths."),
        Message(title: "A brighter moment", emoji: "🌤️", text: "The next small step is close."),
        Message(title: "Room to bloom", emoji: "🌼", text: "Your pause has room to bloom."),
        Message(title: "Stepping back", emoji: "😎", text: "You are getting good at stepping away."),
        Message(title: "Putting down roots", emoji: "🌳", text: "Let the break put down roots."),
        Message(title: "Let your mind wander", emoji: "🦋", text: "Let your attention wander somewhere new."),
        Message(title: "A wider view", emoji: "🏞️", text: "Look beyond the screen. Stay there a while."),
        Message(title: "Taking the slow route", emoji: "🐌", text: "No prize for rushing this part."),
        Message(title: "A quiet cup", emoji: "🍵", text: "A quiet pause is time well spent."),
        Message(title: "A little kindness", emoji: "💚", text: "Keep a little more of this time for yourself."),
        Message(title: "A touch of color", emoji: "🌈", text: "That is a generous pause."),
        Message(title: "Making space", emoji: "🙌", text: "You made space for more than a quick stop."),
        Message(title: "Growing calm", emoji: "🌻", text: "Let this unhurried moment keep growing."),
        Message(title: "Just being here", emoji: "🧘", text: "For now, just being here is enough."),
        Message(title: "A little distance", emoji: "🕊️", text: "Give the next task a little more distance."),
        Message(title: "An island of quiet", emoji: "🏝️", text: "Enjoy this small island of quiet."),
        Message(title: "Time to treasure", emoji: "💎", text: "This time belongs to you. Keep some more."),
        Message(title: "Let it drift", emoji: "🌊", text: "Let the busy part of the day drift away."),
        Message(title: "A bright pause", emoji: "🌟", text: "A stretch of quiet worth celebrating."),
        Message(title: "A stretch of quiet", emoji: "✨", text: "You gave yourself a real stretch of quiet."),
        Message(title: "Worth celebrating", emoji: "🥳", text: "That is a brilliant commitment to your break."),
        Message(title: "Everyday magic", emoji: "🪄", text: "A little everyday magic: making time for you."),
        Message(title: "A softer moment", emoji: "🌙", text: "Stay in this calm for a little longer."),
        Message(title: "A little more space", emoji: "💫", text: "There is still room for a few quiet minutes."),
        Message(title: "Something rare", emoji: "🦄", text: "An unusually lovely amount of breathing room."),
        Message(title: "Room for rest", emoji: "🌠", text: "You have made plenty of room for rest."),
        Message(title: "Out of this world", emoji: "🚀", text: "You took this break to space."),
        Message(title: "A pocket of calm", emoji: "🌌", text: "A whole pocket of calm in a busy day."),
        Message(title: "A quiet orbit", emoji: "🪐", text: "You are in your own quiet orbit now."),
        Message(title: "A rest milestone", emoji: "🏆", text: "Rest milestone reached. Nicely done."),
        Message(title: "Your time, your choice", emoji: "👑", text: "You made time for yourself. Own that choice."),
        Message(title: "A longer celebration", emoji: "🎉", text: "A long pause deserves a little celebration."),
        Message(title: "No levels to chase", emoji: "🛸", text: "No next level to chase. Enjoy the quiet."),
        Message(title: "At your own pace", emoji: "♾️", text: "Stay if you like. Return when you are ready."),
        Message(title: "A quiet harbor", emoji: "⚓️", text: "Let your thoughts settle for a while."),
        Message(title: "An open horizon", emoji: "🌅", text: "There is room to look beyond the next task."),
        Message(title: "A little music", emoji: "🎶", text: "Let a favorite tune keep you company."),
        Message(title: "A mountain moment", emoji: "🏔️", text: "Some things can wait. Take in the view."),
        Message(title: "A gentle drift", emoji: "⛵️", text: "Let the day move at a softer pace."),
        Message(title: "A peaceful corner", emoji: "🏡", text: "Make yourself at home in this quiet moment."),
        Message(title: "A small keepsake", emoji: "🐚", text: "Take a little of this calm into the rest of your day."),
        Message(title: "Ready when you are", emoji: "🪷", text: "The pause is yours. Stay or return when it feels right."),
    ]

    let elapsed: TimeInterval
    let requiredDuration: TimeInterval
    let canFinish: Bool
    private let messageOrder: [Int]

    init(elapsed: TimeInterval, requiredDuration: TimeInterval, canFinish: Bool,
         breakStartedAt: Date = Date(timeIntervalSince1970: 0), calendar: Calendar = .current) {
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.requiredDuration = requiredDuration.isFinite ? max(0, requiredDuration) : 0
        self.canFinish = canFinish
        let weekday = UInt64(calendar.component(.weekday, from: breakStartedAt))
        var random = RestRandom(seed: breakStartedAt.timeIntervalSince1970.bitPattern ^ (weekday &* 0x9E3779B97F4A7C15))
        // Shuffle within stages: early rewards stay gentle, later ones playful.
        // The saved break start keeps the order stable across ticks and relaunches.
        self.messageOrder = stride(from: 0, to: Self.messages.count, by: 8).flatMap { start in
            Array(start..<min(start + 8, Self.messages.count)).shuffled(using: &random)
        }
    }

    var extraRest: TimeInterval { max(0, elapsed - requiredDuration) }
    var goal: TimeInterval { max(60, 20 * 60 - requiredDuration) }

    var messageIndex: Int {
        guard canFinish else { return 0 }
        let lastOffset = Self.rewardOffsets.last!
        if extraRest >= lastOffset + 120 {
            // After the complete sequence, rotate only the final calm messages.
            return (Self.messages.count - 8) + Int(((extraRest - lastOffset - 120) / 120)
                .truncatingRemainder(dividingBy: 8))
        }
        return Self.rewardOffsets.lastIndex(where: { extraRest >= $0 }) ?? 0
    }

    var message: Message {
        canFinish ? Self.messages[messageOrder[messageIndex]]
            : Message(title: "Required rest", emoji: "😌", text: "Let yourself rest. There is nothing to do right now.")
    }

    var title: String { message.title }

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

// SplitMix64 gives each break a repeatable order without using global randomness.
private struct RestRandom: RandomNumberGenerator {
    var seed: UInt64

    mutating func next() -> UInt64 {
        seed &+= 0x9E3779B97F4A7C15
        var value = seed
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
