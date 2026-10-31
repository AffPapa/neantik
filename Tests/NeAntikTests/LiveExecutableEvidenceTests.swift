import Darwin
import Foundation
import Testing
@testable import NeAntik

struct LiveExecutableEvidenceTests {
    @Test func actualKernelGuestProvidesStableSignedExecutableAndRefusesReusedGeneration() throws {
        let pid = getpid()
        let generation = try #require(DarwinBrowserProcessInventoryProvider.currentProcessIdentity(pid))
        let observed = try #require(DarwinBrowserProcessInventoryProvider.verifiedLiveExecutable(pid: pid, generation: generation))
        #expect(observed.path.hasPrefix("/"))
        #expect(!observed.identifier.isEmpty)
        #expect(observed.cdHash.count == 20)
        #expect(DarwinBrowserProcessInventoryProvider.verifiedLiveExecutable(pid: pid, generation: generation) == observed)
        let stale = BrowserProcessKernelIdentity(startSeconds: generation.startSeconds + 1, startMicroseconds: generation.startMicroseconds)
        #expect(DarwinBrowserProcessInventoryProvider.verifiedLiveExecutable(pid: pid, generation: stale) == nil)
        #expect(DarwinBrowserProcessInventoryProvider.verifiedLiveExecutable(pid: -1, generation: generation) == nil)
    }
}
