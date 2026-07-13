import Foundation

protocol TimeProvider {
    var now: Date { get }
}

struct SystemClock: TimeProvider {
    var now: Date { Date() }
}
