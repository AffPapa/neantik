import Testing

@testable import NeAntik

struct SensitiveRevealLeaseTests {
  @Test func revealExpiresOnlyForItsOwnGeneration() {
    var lease = SensitiveRevealLeaseState()
    let first = lease.reveal()
    let second = lease.reveal()

    let staleTimerExpired = lease.expire(generation: first)
    #expect(!staleTimerExpired)
    #expect(lease.isRevealed)
    let currentTimerExpired = lease.expire(generation: second)
    #expect(currentTimerExpired)
    #expect(!lease.isRevealed)
  }

  @Test func editingRefreshesOnlyAnActiveReveal() {
    var lease = SensitiveRevealLeaseState()
    #expect(lease.refreshIfRevealed() == nil)

    let first = lease.reveal()
    let refreshed = lease.refreshIfRevealed()
    #expect(refreshed != nil)
    #expect(refreshed != first)
    #expect(lease.isRevealed)
  }

  @Test func explicitHideInvalidatesPendingTimer() {
    var lease = SensitiveRevealLeaseState()
    let generation = lease.reveal()
    lease.hide()

    #expect(!lease.isRevealed)
    let hiddenTimerExpired = lease.expire(generation: generation)
    #expect(!hiddenTimerExpired)
  }
}
