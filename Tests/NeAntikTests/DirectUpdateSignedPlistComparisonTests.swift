import DirectUpdateCore
import Foundation
import Testing

@Suite("Authenticated plist content equality")
struct DirectUpdateSignedPlistComparisonTests {
    private func encode(_ value: [String: Any], format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }
    @Test func dictionaryOrderAndSerializationFormatDoNotChangeContent() throws {
        let value: [String: Any] = ["version": "0.7.45", "enabled": true,
            "nested": ["b": 2, "a": 1], "array": ["a", "b"],
            "bytes": Data([1, 2]), "date": Date(timeIntervalSince1970: 100)]
        let binary = try encode(value), xml = try encode(value, format: .xml)
        #expect(binary != xml)
        #expect(DirectUpdateSignedPlistComparison.equal(binary, xml))
        #expect(DirectUpdateSignedPlistComparison.equal(xml, binary))
    }
    @Test func changedValuesTypesArraysAndEntriesRefuse() throws {
        let original = try encode(["pin": ["hash": "original"], "enabled": true, "array": [1, 2], "number": 1])
        let changes: [[String: Any]] = [
            ["pin": ["hash": "changed"], "enabled": true, "array": [1, 2], "number": 1],
            ["pin": ["hash": "original"], "enabled": 1, "array": [1, 2], "number": 1],
            ["pin": ["hash": "original"], "enabled": true, "array": [2, 1], "number": 1],
            ["pin": ["hash": "original"], "enabled": true, "array": [1, 2], "number": 1.0],
            ["pin": ["hash": "original"], "enabled": true, "array": [1, 2]],
            ["pin": ["hash": "original"], "enabled": true, "array": [1, 2], "number": 1, "extra": "entry"]
        ]
        for value in changes { #expect(!DirectUpdateSignedPlistComparison.equal(original, try encode(value))) }
        #expect(!DirectUpdateSignedPlistComparison.equal(original, Data("invalid".utf8)))
        #expect(!DirectUpdateSignedPlistComparison.equal(Data(), Data()))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_SIGNATURE_QA_APP"] != nil))
    func realSignedCandidateSurvivesAllocationPerturbation() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_SIGNATURE_QA_APP"])
        let app = URL(fileURLWithPath: path), root = app.deletingLastPathComponent()
        let prefix = "neantik-updater-install-"
        try #require(root.deletingLastPathComponent().path == "/private/tmp" && app.lastPathComponent == "NeAntik.app")
        let id = try #require(UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))))
        try #require(root.lastPathComponent == prefix + id.uuidString.lowercased())
        let first = try DirectUpdateCodeSignature.inspect(app, role: .manager)
        var retained: [[String: Any]] = []
        for index in 0..<8 {
            for n in 0..<33 {
                var filler: [String: Any] = [:]
                for k in 0..<(n + 1) { filler["fixture-\(index)-\(n)-\(k)"] = k }
                retained.append(filler)
            }
            try withExtendedLifetime(retained) {
                let next = try DirectUpdateCodeSignature.inspect(app, role: .manager)
                #expect(first == next)
                #expect(first.cdHash == next.cdHash)
            }
        }
    }
}
