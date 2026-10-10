import Foundation
import Testing
@testable import NeAntik

final class MemoryBackupScopeBackend: BackupCompatibilityScopeBackend, @unchecked Sendable {
    private let lock = NSLock()
    var winnerOnInsert: Data?
    var rejectWrite = false
    var errorOnRead: Error?
    private var bytes: Data?
    private var inserts = 0
    init(_ value: Data? = nil) { bytes = value }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; if let errorOnRead { throw errorOnRead }; return bytes }
    func insertIfAbsent(_ value: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }; inserts += 1
        if rejectWrite { return true }
        if let winnerOnInsert { bytes = winnerOnInsert; return false }
        guard bytes == nil else { return false }; bytes = value; return true
    }
    func replace(_ value: Data?) { lock.lock(); defer { lock.unlock() }; bytes = value }
    var insertionCount: Int { lock.lock(); defer { lock.unlock() }; return inserts }
}

struct BackupCompatibilityScopeStoreTests {
    @Test func creationIsImmutableAndRestoreNeverRegeneratesMissingScope() throws {
        let backend = MemoryBackupScopeBackend()
        let scope = BackupCompatibilityScopeStore(backend: backend, random: { Data(repeating: 1, count: 32) })
        #expect(throws: BackupCompatibilityScopeError.unavailable) { try scope.digest(createForExport: false) }
        #expect(backend.insertionCount == 0)
        let digest = try scope.digest(createForExport: true)
        #expect(digest.count == 64 && digest != String(repeating: "01", count: 32))
        #expect(try scope.digest(createForExport: true) == digest)
        #expect(try scope.digest(createForExport: false) == digest)
        #expect(backend.insertionCount == 1)
        backend.replace(nil)
        #expect(throws: BackupCompatibilityScopeError.unavailable) { try scope.digest(createForExport: false) }
        #expect(backend.insertionCount == 1)
    }
    @Test func duplicateCreatorUsesPersistedWinnerAndLostWriteRefuses() throws {
        let backend = MemoryBackupScopeBackend(); backend.winnerOnInsert = Data(repeating: 2, count: 32)
        let scope = BackupCompatibilityScopeStore(backend: backend, random: { Data(repeating: 1, count: 32) })
        let winner = BackupCompatibilityScopeStore(backend: MemoryBackupScopeBackend(Data(repeating: 2, count: 32)))
        #expect(try scope.digest(createForExport: true) == winner.digest(createForExport: false))
        let lost = MemoryBackupScopeBackend(); lost.rejectWrite = true
        #expect(throws: BackupCompatibilityScopeError.unavailable) {
            try BackupCompatibilityScopeStore(backend: lost, random: { Data(repeating: 3, count: 32) }).digest(createForExport: true)
        }
    }
    @Test(arguments: [0, 31, 33, 4096]) func corruptScopeIsNeverRepaired(count: Int) {
        let backend = MemoryBackupScopeBackend(Data(repeating: 1, count: count))
        #expect(throws: BackupCompatibilityScopeError.unavailable) { try BackupCompatibilityScopeStore(backend: backend).digest(createForExport: true) }
        #expect(backend.insertionCount == 0)
    }
    @Test func lockedScopeFailsWithoutCreation() {
        let backend = MemoryBackupScopeBackend(); backend.errorOnRead = BackupCompatibilityScopeError.unavailable
        #expect(throws: BackupCompatibilityScopeError.unavailable) { try BackupCompatibilityScopeStore(backend: backend).digest(createForExport: true) }
        #expect(backend.insertionCount == 0)
    }
}
