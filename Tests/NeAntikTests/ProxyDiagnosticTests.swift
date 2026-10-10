import Foundation
import Testing
@testable import NeAntik

struct ProxyDiagnosticTests {
    @Test func strictAddressAndDecodedSchema() throws {
        for good in ["https://example.com/ip", "https://example.com:8443/ip", "https://[::1]/ip"] {
            #expect(try ProxyDiagnosticEndpoint(good).address == good)
        }
        for bad in ["", "http://example.com/ip", "HTTPS://example.com/ip", "https://u:p@example.com/ip", "https://example.com/ip?token=x", "https://example.com/ip#x", "https://example.com:0/ip", "https://example.com:65536/ip", " https://example.com/ip", "https://example.com/\n", "https://example.com/%0A", "https://bad%0Ahost/ip", "https://example.com\\ip", String(repeating: "x", count: 2_049)] {
            #expect(throws: (any Error).self) { try ProxyDiagnosticEndpoint(bad) }
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ProxyDiagnosticEndpoint.self, from: Data("\"http://example.com/ip\"".utf8))
        }
    }

    @Test func consentPrecedesAnyProcessAndSecretsRemainInStdinOnly() async throws {
        let endpoint = try ProxyDiagnosticEndpoint("https://example.com/private-ip")
        let proxy = try ProxyImportParser.parse("fixture:synthetic@127.0.0.1:8080", kind: .http).configuration
        await #expect(throws: ProxyDiagnosticError.consentRequired) {
            try await ProxyTester().diagnose(endpoint: endpoint, configuration: proxy, password: "synthetic", consent: false) { _, _, _, _ in
                Issue.record("No request is permitted without consent")
                return .init(status: 0, output: Data(), outputExceeded: false)
            }
        }
        let value = try await ProxyTester().diagnose(endpoint: endpoint, configuration: proxy, password: "synthetic", consent: true) { executable, arguments, input, limit in
            #expect(executable.path == "/usr/bin/curl")
            #expect(!arguments.joined().contains(endpoint.address))
            #expect(!arguments.joined().contains("synthetic"))
            #expect(!arguments.contains("--location"))
            #expect(!arguments.contains("--insecure"))
            #expect(arguments.contains("=https"))
            #expect(String(decoding: input, as: UTF8.self).contains("url = \"https://example.com/private-ip\""))
            #expect(String(decoding: input, as: UTF8.self).contains("fixture:synthetic"))
            #expect(limit == ProxyTester.maximumProbeOutputBytes)
            return .init(status: 0, output: Data("{\"ip\":\"203.0.113.12\",\"timezone\":\"Europe/Berlin\",\"languages\":\"de-DE\"}\nNEANTIK_METRICS_V2:0.125|200|200\n".utf8), outputExceeded: false)
        }
        #expect(value.ipAddress == "203.0.113.12")
        #expect(value.responseTimeMilliseconds == 125)
    }

    @Test func endpointFailureIsExclusiveAndNotAProxyFailure() async throws {
        let endpoint = try ProxyDiagnosticEndpoint("https://example.com/ip")
        let proxy = try ProxyImportParser.parse("127.0.0.1:8080", kind: .http).configuration
        for (status, connect, response, expected) in [
            (Int32(22), "200", "429", ProxyHealthOutcome.probeServiceFailed),
            (22, "407", "000", .authenticationRejected),
            (56, "502", "000", .protocolFailed),
            (60, "000", "000", .transportSecurityFailed)
        ] {
            let count = Calls()
            do {
                _ = try await ProxyTester().diagnose(endpoint: endpoint, configuration: proxy, password: "", consent: true) { _, _, _, _ in
                    await count.increment()
                    return .init(status: status, output: Data("\nNEANTIK_METRICS_V2:0.01|\(connect)|\(response)\n".utf8), outputExceeded: false)
                }
                Issue.record("Fault must not succeed")
            } catch let error as ProxyProbeError { #expect(error.outcome == expected) }
            #expect(await count.value == 1)
        }
    }

    @Test func redirectsMalformedMetricsOversizeAndInvalidBodyCannotSucceed() async throws {
        let endpoint = try ProxyDiagnosticEndpoint("https://example.com/ip")
        let proxy = try ProxyImportParser.parse("127.0.0.1:8080", kind: .http).configuration
        for (body, metrics, oversized) in [
            ("{\"ip\":\"203.0.113.12\"}", "0.1|200|302", false),
            ("{\"ip\":\"203.0.113.12\"}", "0.1|502|200", false),
            ("{\"ip\":\"203.0.113.12\"}", "0.1", false),
            ("{\"ip\":\"203.0.113.12\"}", "0.1|200|200", true),
            ("{\"ip\":\"not-an-ip\"}", "0.1|200|200", false),
            ("broken", "0.1|200|200", false)
        ] {
            await #expect(throws: ProxyProbeError(outcome: .invalidResponse)) {
                try await ProxyTester().diagnose(endpoint: endpoint, configuration: proxy, password: "", consent: true) { _, _, _, _ in
                    .init(status: 0, output: Data("\(body)\nNEANTIK_METRICS_V2:\(metrics)\n".utf8), outputExceeded: oversized)
                }
            }
        }
    }

    @Test func processEnvironmentDoesNotInheritTrustProxyOrLoaderOverrides() async throws {
        let result = try await ProxyTester.runCancellableProcess(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], standardInput: Data())
        let lines = Set(String(decoding: result.output, as: UTF8.self).split(separator: "\n").map(String.init))
        #expect(lines == ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "LC_ALL=C"])
    }

    @Test @MainActor func changedProxyDuringPasswordReadPreventsCredentialTransmission() async throws {
        let state = RequestState()
        let endpoint = try ProxyDiagnosticEndpoint("https://example.com/ip")
        let proxy = try ProxyImportParser.parse("fixture:synthetic@127.0.0.1:8080", kind: .http).configuration
        await #expect(throws: CancellationError.self) {
            try await ProxyDiagnosticRequest.run(
                endpoint: endpoint, configuration: proxy,
                readPassword: {
                    await MainActor.run { state.snapshot = false }
                    return "replacement-secret"
                },
                snapshotIsCurrent: { state.snapshot }, requestIsCurrent: { state.tokenMatches },
                runProcess: { _, _, _, _ in
                    Issue.record("Replacement password must never be sent to the old proxy")
                    return .init(status: 0, output: Data(), outputExceeded: false)
                }
            )
        }
    }

    @Test @MainActor func replacementRequestInvalidatesLateSuccessAfterPasswordAwait() async throws {
        let state = RequestState()
        let endpoint = try ProxyDiagnosticEndpoint("https://example.com/ip")
        let proxy = try ProxyImportParser.parse("127.0.0.1:8080", kind: .http).configuration
        await #expect(throws: CancellationError.self) {
            try await ProxyDiagnosticRequest.run(
                endpoint: endpoint, configuration: proxy,
                readPassword: {
                    await MainActor.run {
                        state.passwordReads += 1
                        if state.passwordReads == 2 { state.tokenMatches = false }
                    }
                    return ""
                },
                snapshotIsCurrent: { state.snapshot }, requestIsCurrent: { state.tokenMatches },
                runProcess: { _, _, _, _ in
                    .init(status: 0, output: Data("{\"ip\":\"203.0.113.12\"}\nNEANTIK_METRICS_V2:0.1|200|200\n".utf8), outputExceeded: false)
                }
            )
        }
        #expect(state.passwordReads == 2)
    }

    @Test func atomicPreferencesAndRevisionConflictPreservePreviousValue() async throws {
        let paths = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let store = ProxyDiagnosticPreferenceStore(paths: paths)
        #expect(try await store.load() == nil)
        let first = try await store.save(ProxyDiagnosticEndpoint("https://example.com/ip"), expectedRevision: nil)
        #expect(try await store.load() == first)
        await #expect(throws: ProxyDiagnosticError.revisionConflict) {
            try await store.save(ProxyDiagnosticEndpoint("https://example.com/other"), expectedRevision: nil)
        }
        #expect(try await store.load() == first)
        let failing = ProxyDiagnosticPreferenceStore(paths: paths, write: { _, _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        await #expect(throws: (any Error).self) {
            try await failing.save(ProxyDiagnosticEndpoint("https://example.com/other"), expectedRevision: first.revision)
        }
        #expect(try await store.load() == first)
    }

    @Test func corruptUnsupportedOversizeAndSymlinkPreferencesRemainUnchanged() async throws {
        for payload in [Data("broken".utf8), Data("{\"schemaVersion\":99,\"revision\":\"\(UUID())\",\"endpoint\":\"https://example.com/ip\"}".utf8), Data(repeating: 0x20, count: 4_097)] {
            let paths = try fixture()
            defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
            try paths.writePrivateFile(payload, to: paths.proxyDiagnosticPreferenceFile)
            let store = ProxyDiagnosticPreferenceStore(paths: paths)
            await #expect(throws: (any Error).self) { try await store.load() }
            await #expect(throws: (any Error).self) { try await store.save(ProxyDiagnosticEndpoint("https://example.com/ip"), expectedRevision: nil) }
            #expect(try Data(contentsOf: paths.proxyDiagnosticPreferenceFile) == payload)
        }
        let paths = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let target = paths.rootDirectory.appendingPathComponent("owned-fixture")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: paths.proxyDiagnosticPreferenceFile, withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await ProxyDiagnosticPreferenceStore(paths: paths).load() }
        #expect(try Data(contentsOf: target) == Data("preserve".utf8))
    }

    private func fixture() throws -> AppPaths {
        let paths = AppPaths(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("neantik-endpoint-\(UUID())"))
        try paths.prepareBaseDirectories()
        return paths
    }
    private actor Calls {
        var value = 0
        func increment() { value += 1 }
    }
    @MainActor private final class RequestState {
        var snapshot = true
        var tokenMatches = true
        var passwordReads = 0
    }
}
