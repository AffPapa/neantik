import Foundation
import Testing
@testable import NeAntik

struct ProxyTesterLiveFixtureTests {
    @Test
    func approvedLocalProxyFixtureProvidesFreshCrossCheckedContext() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "NEANTIK_APPROVED_PROXY_FIXTURE"
        ] else {
            return
        }
        let lines = try String(
            contentsOfFile: path,
            encoding: .utf8
        ).split(whereSeparator: \.isNewline)
        #expect((1...33).contains(lines.count))
        for (index, line) in lines.enumerated() {
            let draft = try ProxyImportParser.parse(
                String(line),
                kind: .http
            )
            do {
                let observation = try await ProxyTester().probe(
                    configuration: draft.configuration,
                    password: draft.password
                )
                #expect(observation.source == .crossChecked)
                #expect(!observation.result.ipAddress.isEmpty)
                #expect(observation.result.timezoneIdentifier != nil)
                #expect(observation.result.localeIdentifier != nil)
            } catch {
                Issue.record("Private proxy fixture row \(index + 1) failed")
            }
        }
    }
}
