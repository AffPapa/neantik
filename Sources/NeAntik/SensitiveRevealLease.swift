import Foundation

/// A small generation-bound lease for temporarily revealing a local secret.
///
/// The state owns no secret value. A generation lets UI timers prove that
/// they still belong to the current reveal, so an older timer cannot hide a
/// newer user-requested reveal.
struct SensitiveRevealLeaseState: Equatable, Sendable {
  static let defaultLifetime: Duration = .seconds(15)

  private(set) var isRevealed = false
  private(set) var generation: UInt64 = 0

  mutating func reveal() -> UInt64 {
    generation &+= 1
    isRevealed = true
    return generation
  }

  mutating func refreshIfRevealed() -> UInt64? {
    guard isRevealed else { return nil }
    return reveal()
  }

  mutating func hide() {
    generation &+= 1
    isRevealed = false
  }

  mutating func expire(generation expectedGeneration: UInt64) -> Bool {
    guard isRevealed, generation == expectedGeneration else {
      return false
    }
    hide()
    return true
  }
}
