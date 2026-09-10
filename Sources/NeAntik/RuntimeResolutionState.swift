import Foundation

struct RuntimeResolutionState: Equatable, Sendable {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}
