import Foundation
import Testing
@testable import NeAntik

struct ManagerSessionEvidenceTests {
    @Test func reportsDeadManagerSessionAndRemovesItsMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let first = ManagerSessionEvidenceStore(
            paths: paths,
            processIsAlive: { $0 == 101 }
        )
        let firstEvidence = try first.begin(
            pid: 101,
            now: Date(timeIntervalSince1970: 10),
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        )
        #expect(firstEvidence.interruptedSessionCount == 0)

        let recovery = ManagerSessionEvidenceStore(
            paths: paths,
            processIsAlive: { _ in false }
        )
        let recovered = try recovery.begin(
            pid: 202,
            now: Date(timeIntervalSince1970: 20),
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        )
        #expect(recovered.interruptedSessionCount == 1)
        try recovery.finish(token: recovered.token)

        let clean = try recovery.begin(pid: 303)
        #expect(clean.interruptedSessionCount == 0)
        try recovery.finish(token: clean.token)
    }

    @Test func keepsConcurrentLiveManagersWithoutFalseDirtyEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ManagerSessionEvidenceStore(
            paths: paths,
            processIsAlive: { $0 == 11 || $0 == 22 }
        )
        let first = try store.begin(pid: 11)
        let second = try store.begin(pid: 22)
        #expect(first.interruptedSessionCount == 0)
        #expect(second.interruptedSessionCount == 0)
        try store.finish(token: first.token)
        try store.finish(token: second.token)
    }
}
