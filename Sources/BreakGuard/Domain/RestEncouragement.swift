import Foundation

struct RestEncouragement {
    struct Message: Equatable {
        let title: String
        let emoji: String
        let text: String
    }

    // Seconds beyond the required break. After five minutes, steps slow down.
    static let rewardOffsets: [TimeInterval] = [
        0, 8, 25, 50, 79, 121, 171, 231, 281, 330,
        385, 445, 510, 580, 655, 735, 820, 915, 1020, 1135, 1260
    ]
    static let stageStarts = [0, 5, 10, 15]

    let elapsed: TimeInterval
    let requiredDuration: TimeInterval
    let canFinish: Bool
    let scaleIndex: Int
    private let dayNumber: Int
    private let introduction: Message

    init(elapsed: TimeInterval, requiredDuration: TimeInterval, canFinish: Bool,
         breakStartedAt: Date = Date(timeIntervalSince1970: 0), calendar: Calendar = .current,
         introduction: Message = RestIntroduction.messages[0]) {
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.requiredDuration = requiredDuration.isFinite ? max(0, requiredDuration) : 0
        self.canFinish = canFinish
        self.introduction = introduction
        // Anchor both the weekday and reflections to the saved break start.
        // Crossing midnight must not change a scale that is already in progress.
        self.scaleIndex = calendar.component(.weekday, from: breakStartedAt) - 1
        self.dayNumber = calendar.ordinality(of: .day, in: .era, for: breakStartedAt) ?? 0
    }

    var scale: RestRewardCatalog.Scale { RestRewardCatalog.scales[scaleIndex] }
    var extraRest: TimeInterval { max(0, elapsed - requiredDuration) }

    var messageIndex: Int {
        guard canFinish else { return 0 }
        return Self.rewardOffsets.lastIndex(where: { extraRest >= $0 }) ?? 0
    }

    var message: Message {
        canFinish ? scale.messages[messageIndex]
            : introduction
    }

    var title: String { message.title }

    // One quote at a time: alternate the story with a daily reflection.
    // Keep the introduction and final milestone tied to their own message.
    var quote: String {
        if canFinish, messageIndex % 2 == 1, let reflection { return reflection }
        return message.text
    }

    var reflection: String? {
        guard canFinish else { return nil }
        let count = RestReflections.messages.count
        // A different daily starting point, with no repeats within a scale.
        let index = ((dayNumber % count) + messageIndex * 17) % count
        return RestReflections.messages[index]
    }

    var stageIndex: Int { Self.stageStarts.lastIndex(where: { messageIndex >= $0 }) ?? 0 }

    var progress: Double {
        guard canFinish else { return 0 }
        let first = Self.stageStarts[stageIndex]
        let last = stageIndex + 1 < Self.stageStarts.count
            ? Self.stageStarts[stageIndex + 1] - 1 : Self.rewardOffsets.count - 1
        let start = Self.rewardOffsets[first]
        let end = Self.rewardOffsets[last]
        return min(1, max(0, (extraRest - start) / (end - start)))
    }

    var secondsToNextReward: TimeInterval {
        guard canFinish else { return 0 }
        return Self.rewardOffsets.first(where: { $0 > extraRest }).map { $0 - extraRest } ?? 0
    }
}

private enum RestReflections {
    // Original reflections, not quotations attributed to other people.
    static let messages = [
        "Five years from now, this task may be forgotten. You still matter.",
        "There is a whole day outside this window.",
        "You do not have to earn a moment of rest.",
        "Notice one small thing around you.",
        "Taking care of yourself is part of having a life.",
        "Let your shoulders find a comfortable place.",
        "You are a person, not an endless supply of output.",
        "Let your eyes wander somewhere farther away.",
        "The to-do list can wait while you look after yourself.",
        "Listen for a sound in the room.",
        "You can care about your work and still stop for a while.",
        "A quiet moment does not need to become anything else.",
        "Your health deserves room in the calendar, too.",
        "Let the next thought come and go.",
        "Rest does not need a business case.",
        "There is no score to improve here.",
        "Be on your own side for a moment.",
        "Notice the light where you are.",
        "You deserve care on ordinary days, too.",
        "You can leave this moment unfilled.",
        "An unfinished task is not a measure of your worth.",
        "Find a comfortable position.",
        "There is more to you than what you get done today.",
        "Take a moment to look beyond the screen.",
        "Caring for yourself can be a quiet everyday choice.",
        "Let the room have your attention for a while.",
        "Work is one part of your life. Leave room for the rest.",
        "Nothing new needs to happen right now.",
        "There is no hurry inside this moment.",
        "A little space between tasks can feel good.",
        "Let your hands rest for a moment.",
        "Watch something that is not asking for a response.",
        "The next step will still be there.",
        "You can simply be here for a little while.",
        "Notice a color you like.",
        "Let a few quiet moments pass.",
        "The day has room for a slower pace.",
        "Stay with something simple.",
        "There is no need to plan the next minute.",
        "Give your attention somewhere comfortable to land.",
        "A pause can just be a pause.",
        "Return when you feel ready."
    ]
}
