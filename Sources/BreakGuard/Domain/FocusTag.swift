import Foundation

struct FocusTag: Codable, Equatable, Identifiable {
    static let maximumNameLength = 24

    let id: String
    var name: String

    static let defaults = [
        FocusTag(id: "work", name: "Work"),
        FocusTag(id: "study", name: "Study")
    ]

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FocusTagNameError: Error, Equatable {
    case empty
    case tooLong
    case duplicate

    var message: String {
        switch self {
        case .empty: return "Enter a tag name."
        case .tooLong: return "Tag names must be 24 characters or fewer."
        case .duplicate: return "Tag names must be unique."
        }
    }
}

enum FocusClassification: Equatable {
    case tag(id: String)
    case skipped
    // Chosen via "Continue Working" when focus tags are disabled:
    // the break counts, but no focus minutes are recorded anywhere.
    case untracked
}
