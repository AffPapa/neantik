#if DEBUG
import Foundation
import Testing
@testable import NeAntik

struct BackupScopeQualificationTests {
    @Test func refusesProductionIdentityAndUnboundRemoval() throws {
        let request = BackupScopeQualification.Request(runID: UUID(), phase: .create)
        #expect(throws: BackupScopeQualification.Failure.invalidIdentity) {
            try BackupScopeQualification.validate(request, bundleID: "app.neantik.desktop")
        }
        try BackupScopeQualification.validate(request, bundleID: BackupScopeQualification.bundleIdentifier)
        for digest in [nil, "", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] as [String?] {
            #expect(throws: BackupScopeQualification.Failure.invalidRequest) {
                try BackupScopeQualification.validate(.init(runID: UUID(), phase: .removeOwnedItem, expectedDigest: digest), bundleID: BackupScopeQualification.bundleIdentifier)
            }
        }
        try BackupScopeQualification.validate(.init(runID: UUID(), phase: .read, expectedDigest: String(repeating: "a", count: 64)), bundleID: BackupScopeQualification.bundleIdentifier)
    }
    @Test func releaseParserRejectsQualificationArguments() {
        for flag in [BackupScopeQualification.argument, BackupScopeQualification.argument + "=data"] {
            #expect(NeAntikLaunchIntent.parse(arguments: ["/Applications/NeAntik.app/Contents/MacOS/NeAntik", flag]).mode == .invalidControlArguments)
        }
    }
    @Test func dataOperationsAreBoundToRunRootAndPrivatePassphrase() throws {
        let run = UUID(), digest = String(repeating: "a", count: 64)
        for phase in [BackupScopeQualification.Phase.exportData, .restoreData, .wrongPassword, .corruptArchive, .missingScopeData, .interruptBeforeDecision, .interruptAfterDecision, .recoverData] {
            let valid = BackupScopeQualification.Request(runID: run, phase: phase, expectedDigest: digest,
                root: BackupScopeQualification.dataRoot(run).path, password: "synthetic QA passphrase")
            try BackupScopeQualification.validate(valid, bundleID: BackupScopeQualification.bundleIdentifier)
            for root in [nil, "/private/tmp/neantik-nonqa-synthetic", BackupScopeQualification.dataRoot(UUID()).path,
                         BackupScopeQualification.dataRoot(run).path + "/../other"] as [String?] {
                var changed = valid; changed.root = root
                #expect(throws: BackupScopeQualification.Failure.invalidRequest) {
                    try BackupScopeQualification.validate(changed, bundleID: BackupScopeQualification.bundleIdentifier)
                }
            }
            var changed = valid; changed.password = nil
            #expect(throws: BackupScopeQualification.Failure.invalidRequest) {
                try BackupScopeQualification.validate(changed, bundleID: BackupScopeQualification.bundleIdentifier)
            }
        }
        try BackupScopeQualification.validate(.init(runID: run, phase: .prepareData,
            root: BackupScopeQualification.dataRoot(run).path), bundleID: BackupScopeQualification.bundleIdentifier)
        #expect(throws: BackupScopeQualification.Failure.invalidRequest) {
            try BackupScopeQualification.validate(.init(runID: run, phase: .create,
                root: BackupScopeQualification.dataRoot(run).path), bundleID: BackupScopeQualification.bundleIdentifier)
        }
    }
}
#endif
