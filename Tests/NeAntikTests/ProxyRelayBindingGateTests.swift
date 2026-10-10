import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayBindingGateTests {
    private func awaitPending(_ gate: ProxyRelayBindingGate, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await gate.pendingCount() != count {
            try #require(ContinuousClock.now < deadline, "Waiter not registered")
            await Task.yield()
        }
    }
    @Test func connectionsWaitForExactBindingThenAllProceed() async throws {
        let gate = try ProxyRelayBindingGate()
        let a = Task { try await gate.wait() }, b = Task { try await gate.wait() }
        try await awaitPending(gate, count: 2)
        try await gate.open(); try await a.value; try await b.value
        #expect(await gate.pendingCount() == 0)
        try await gate.wait()
        await #expect(throws: ProxyRelayBindingGate.Failure.alreadyBound) { try await gate.open() }
    }
    @Test func launchFailureClosesPendingAndFutureConnections() async throws {
        let gate = try ProxyRelayBindingGate()
        let task = Task { try await gate.wait() }
        try await awaitPending(gate, count: 1); await gate.close()
        await #expect(throws: ProxyRelayBindingGate.Failure.closed) { try await task.value }
        await #expect(throws: ProxyRelayBindingGate.Failure.closed) { try await gate.wait() }
        await #expect(throws: ProxyRelayBindingGate.Failure.closed) { try await gate.open() }
        #expect(await gate.pendingCount() == 0)
    }
    @Test func cancellationAndDeadlineReleaseTheirWaiters() async throws {
        let gate = try ProxyRelayBindingGate()
        let task = Task { try await gate.wait() }
        try await awaitPending(gate, count: 1); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await gate.pendingCount() == 0)
        await #expect(throws: ProxyRelayBindingGate.Failure.timeout) { try await gate.wait(timeout: 0.01) }
        #expect(await gate.pendingCount() == 0)
        try await gate.open(); try await gate.wait()
    }
    @Test func overloadAndInvalidBudgetCannotAccumulateUnboundedTasks() async throws {
        let gate = try ProxyRelayBindingGate(maximumWaiters: 1)
        let task = Task { try await gate.wait() }; try await awaitPending(gate, count: 1)
        await #expect(throws: ProxyRelayBindingGate.Failure.invalidLimit) { try await gate.wait() }
        for timeout in [0.0, -1, 11, .infinity, .nan] {
            await #expect(throws: ProxyRelayBindingGate.Failure.invalidLimit) { try await gate.wait(timeout: timeout) }
        }
        await gate.close(); await #expect(throws: ProxyRelayBindingGate.Failure.closed) { try await task.value }
        for limit in [0, 65] { #expect(throws: ProxyRelayBindingGate.Failure.invalidLimit) { try ProxyRelayBindingGate(maximumWaiters: limit) } }
    }
    @Test func cancelledEntryIsRefusedEvenAfterSuccessfulBinding() async throws {
        let gate = try ProxyRelayBindingGate(); try await gate.open()
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; try await gate.wait() }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
