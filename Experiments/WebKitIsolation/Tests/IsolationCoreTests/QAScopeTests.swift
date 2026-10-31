import Foundation
import Testing
@testable import IsolationCore

@Suite struct QAScopeTests {
    private let run = "ABAD0001-0000-4000-8000-000000000001"
    private func allowed(_ authority: String, suffix: String = "") -> Bool {
        guard let url = URL(string: "http://" + authority + "/__neantik_isolation_qa/" + run + "/probe" + suffix) else { return false }
        return OwnedQATargetPolicy.permits(url, runID: run)
    }
    @Test func acceptsOnlyIntendedLiteralRanges() {
        for host in ["127.0.0.1", "[::1]", "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.4"] {
            #expect(allowed(host + ":8101"))
        }
        for host in ["127.0.0.2", "172.15.0.1", "172.32.0.1", "192.167.1.4", "8.8.8.8", "0.0.0.0", "[::]", "[2001:db8::1]"] {
            #expect(!allowed(host + ":8101"))
        }
    }
    @Test func catchesFormerDNSLabelBypass() {
        let trap = "10.0.0.1.example.com"
        let brokenParser = trap.split(separator: ".").compactMap { UInt8($0) }
        #expect(brokenParser.count == 4 && brokenParser[0] == 10)
        for host in [trap, "192.168.1.2.invalid", "10..0.0.1", "localhost", "10.0.0.1.", "10.0.0.256"] {
            #expect(!allowed(host + ":8101"))
        }
    }
    @Test func refusesCredentialsFragmentsAndMissingOrInvalidPort() {
        for authority in ["user:pass@10.0.0.1:8101", "user@10.0.0.1:8101", "10.0.0.1", "10.0.0.1:0", "10.0.0.1:65536"] {
            #expect(!allowed(authority))
        }
        #expect(!allowed("10.0.0.1:8101", suffix: "#fragment"))
    }
    @Test func bindsSchemeAndRunPath() {
        let base = "http://10.0.0.1:8101/__neantik_isolation_qa/"
        for text in [base + run, base + "another/", base + run + "extra/probe", "https://10.0.0.1:8101/__neantik_isolation_qa/" + run + "/probe"] {
            #expect(!OwnedQATargetPolicy.permits(URL(string: text)!, runID: run))
        }
        #expect(!OwnedQATargetPolicy.permits(URL(string: base + run + "/probe")!, runID: "not-a-run"))
    }
    @Test func pendingLaunchBlocksCleanupAndConfiguration() throws {
        var gate = QAOperationFence()
        let value = gate.begin(.launchHost), launch = try #require(value)
        #expect(gate.pendingLaunches == 1)
        let cleanup = gate.begin(.extensionRequest), configuration = gate.begin(.configuration)
        #expect(cleanup == nil && configuration == nil)
        let finished = gate.finish(launch)
        #expect(finished && gate.pendingLaunches == 0)
        let next = gate.begin(.configuration)
        #expect(next != nil)
    }
    @Test func pendingCleanupBlocksLaunchUntilCompletion() throws {
        var gate = QAOperationFence()
        let value = gate.begin(.extensionRequest), cleanup = try #require(value)
        let refused = gate.begin(.launchHost)
        #expect(refused == nil && gate.isBusy)
        let finished = gate.finish(cleanup), next = gate.begin(.launchHost)
        #expect(finished && next != nil)
    }
    @Test func duplicateOldCallbackCannotUnlockNewOperation() throws {
        var gate = QAOperationFence()
        let first = gate.begin(.configuration), old = try #require(first)
        let finished = gate.finish(old)
        #expect(finished)
        let second = gate.begin(.launchHost), current = try #require(second)
        let stale = gate.finish(old), refused = gate.begin(.extensionRequest)
        #expect(!stale && gate.pendingLaunches == 1 && refused == nil)
        let done = gate.finish(current)
        #expect(done && !gate.isBusy)
    }
}
