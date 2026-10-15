import CryptoKit
import Foundation
import Testing
import DirectInstallFilesystem
@testable import DirectUpdateCore

/// Policy/handshake controls only. Synthetic measurements do not manufacture
/// a genuine provenance observation or installation authority.
@Suite(.serialized) struct DirectUpdateRuntimeRecordTests {
    private func report(_ record: DirectUpdateRuntimeRecord) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = record == .final9 ? "Tests/Fixtures/direct-update-final9-runtime-verification.json"
            : "runtime/chromium-15612-font-system-v1-runtime-verification.json"
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        #expect(BackupFS.hex(SHA256.hash(data: bytes)) == record.reportDigest)
        return bytes
    }
    private func runtime(_ record: DirectUpdateRuntimeRecord) -> DirectRuntimeClosureMeasurement {
        .init(digest: record.runtimeDigest, entries: record.runtimeEntries, regularBytes: record.runtimeBytes,
              machoPaths: DirectUpdateRuntimePins.machoPaths, capturedReport: nil, publicationBaseline: nil)
    }
    private func evidence(_ record: DirectUpdateRuntimeRecord, report: Data?) -> DirectRuntimeClosureMeasurement {
        .init(digest: record.evidenceDigest, entries: record.evidenceEntries, regularBytes: record.evidenceBytes,
              machoPaths: [], capturedReport: report, publicationBaseline: nil)
    }
    @Test func oneCompleteCompiledRecordRequiredForEveryCombination() throws {
        for r in DirectUpdateRuntimeRecord.allCases {
            for e in DirectUpdateRuntimeRecord.allCases {
                for p in DirectUpdateRuntimeRecord.allCases {
                    let bytes = try report(p)
                    if r == e && e == p {
                        #expect(try DirectUpdateRuntimeProvenance.validateMeasurements(runtime(r), evidence(e, report: bytes)) == r)
                    } else {
                        #expect(throws: DirectUpdateRuntimeProvenanceError.closure) {
                            try DirectUpdateRuntimeProvenance.validateMeasurements(runtime(r), evidence(e, report: bytes))
                        }
                    }
                }
            }
        }
    }
    @Test func countSizePathsAndCapturedReportCannotBeOmittedOrRelabeled() throws {
        for record in DirectUpdateRuntimeRecord.allCases {
            let r = runtime(record), bytes = try report(record)
            let brokenRuntime = [
                DirectRuntimeClosureMeasurement(digest: r.digest, entries: r.entries + 1, regularBytes: r.regularBytes,
                    machoPaths: r.machoPaths, capturedReport: nil, publicationBaseline: nil),
                DirectRuntimeClosureMeasurement(digest: r.digest, entries: r.entries, regularBytes: r.regularBytes + 1,
                    machoPaths: r.machoPaths, capturedReport: nil, publicationBaseline: nil)
            ]
            for changed in brokenRuntime {
                #expect(throws: DirectUpdateRuntimeProvenanceError.closure) {
                    try DirectUpdateRuntimeProvenance.validateMeasurements(changed, evidence(record, report: bytes))
                }
            }
            let wrongPaths = DirectRuntimeClosureMeasurement(digest: r.digest, entries: r.entries, regularBytes: r.regularBytes,
                machoPaths: [], capturedReport: nil, publicationBaseline: nil)
            #expect(throws: DirectUpdateRuntimeProvenanceError.architecture) {
                try DirectUpdateRuntimeProvenance.validateMeasurements(wrongPaths, evidence(record, report: bytes))
            }
            for badReport in [nil, Data("{}".utf8), bytes + Data([10])] {
                #expect(throws: DirectUpdateRuntimeProvenanceError.closure) {
                    try DirectUpdateRuntimeProvenance.validateMeasurements(r, evidence(record, report: badReport))
                }
            }
        }
    }
    @Test func eachExactReportRetainsItsOwnSchemaAndSourceScope() throws {
        for record in DirectUpdateRuntimeRecord.allCases {
            let dictionary = try #require(JSONSerialization.jsonObject(with: report(record)) as? [String: Any])
            try DirectUpdateRuntimeProvenance.validateReport(dictionary, record: record)
            let other: DirectUpdateRuntimeRecord = record == .final9 ? .fontSystemV1 : .final9
            #expect(throws: DirectUpdateRuntimeProvenanceError.metadata) {
                try DirectUpdateRuntimeProvenance.validateReport(dictionary, record: other)
            }
            let controls: [(String, Any)] = [
                ("sourceVariant", "font-system-v2"), ("sourceEvidenceMode", other.sourceMode),
                ("sourceLockSHA256", String(repeating: "0", count: 64)), ("baseFullFDObservationSHA256", "wrong"),
                ("createdAt", other.createdAt), ("schemaVersion", true), ("machoCount", 15),
                ("freshWholeSourceTreeObserved", 0), ("freshWholeSourceTreeObserved", true),
                ("buildArguments", ["sha256": other.argsDigest]), ("unknown", true)
            ]
            for (key, value) in controls {
                var changed = dictionary; changed[key] = value
                #expect(throws: DirectUpdateRuntimeProvenanceError.metadata) {
                    try DirectUpdateRuntimeProvenance.validateReport(changed, record: record)
                }
            }
        }
    }
    @Test func bootstrapDoesNotEchoARequestForAnotherRuntime() throws {
        let object: [String: Any] = ["transactionID": UUID().uuidString,
            "journalSHA256": String(repeating: "a", count: 64), "candidateReceiptSHA256": String(repeating: "b", count: 64),
            "candidateDevice": 42, "candidateInode": 43]
        let receipt = try JSONDecoder().decode(InstallFilesystemReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        for record in DirectUpdateRuntimeRecord.allCases {
            let request = try DirectUpdateBootstrapRequest(receipt: receipt, cdHash: Data(repeating: 7, count: 20),
                build: 130, runtimeSHA256: record.runtimeDigest, nonce: Data(repeating: 8, count: 32))
            let reply = try request.reply(cdHash: request.candidateCDHash, build: request.build, runtimeSHA256: record.runtimeDigest)
            try request.validateReply(reply)
            let other: DirectUpdateRuntimeRecord = record == .final9 ? .fontSystemV1 : .final9
            #expect(throws: DirectUpdateInstallSessionError.reply) {
                try request.reply(cdHash: request.candidateCDHash, build: request.build, runtimeSHA256: other.runtimeDigest)
            }
        }
    }
}
