import Foundation
import Testing
@testable import DirectUpdateCore

struct DirectUpdateOwnerProtocolTests {
    private func request(nonce: UInt8 = 1) throws -> DirectUpdateOwnerInit {
        try .init(archive: URL(fileURLWithPath: "/private/tmp/synthetic update/archive.zip"),
                  manifest: Data("synthetic-manifest-not-signed".utf8), nonce: Data(repeating: nonce, count: 32))
    }
    private func offer(_ request: DirectUpdateOwnerInit, build: UInt64 = 96) throws -> DirectUpdateOwnerOffer {
        try .init(request: request, version: "0.7.33", build: build, archiveSHA256: Data(repeating: 2, count: 32),
                  runtimeSHA256: Data(repeating: 3, count: 32), candidateCDHash: Data(repeating: 4, count: 20))
    }
    @Test func actualScalarRoundTripIsNotAuthority() throws {
        let request = try request(), offer = try offer(request)
        #expect(try DirectUpdateOwnerInit.parse(request.bytes) == request)
        try request.validateManifest(Data("synthetic-manifest-not-signed".utf8))
        #expect(try DirectUpdateOwnerOffer.parse(offer.bytes, request: request) == offer)
        #expect(offer.version == "0.7.33" && offer.build == 96)
        #expect(offer.archiveSHA256 == Data(repeating: 2, count: 32))
        #expect(offer.runtimeSHA256 == Data(repeating: 3, count: 32))
        #expect(offer.candidateCDHash == Data(repeating: 4, count: 20))
        for decision in [DirectUpdateOwnerDecision.commit, .cancel] {
            let bytes = try DirectUpdateOwnerConsent.command(decision, request: request, offer: offer)
            #expect(bytes.count == 68)
            #expect(try DirectUpdateOwnerConsent.parseCommand(bytes, request: request, offer: offer) == decision)
        }
        try DirectUpdateOwnerConsent.validateAccepted(DirectUpdateOwnerConsent.accepted(request: request, offer: offer), request: request, offer: offer)
    }
    @Test(arguments: [0, 4, 35, 36, 67, 68, 71])
    func changedInitRejectsOrChangesOfferBinding(offset: Int) throws {
        let original = try request(), observation = try offer(original)
        var bytes = original.bytes; bytes[offset] ^= 1
        do { let changed = try DirectUpdateOwnerInit.parse(bytes)
            #expect(throws: DirectUpdateOwnerProtocolError.reply) { try DirectUpdateOwnerOffer.parse(observation.bytes, request: changed) }
        } catch { #expect(error as? DirectUpdateOwnerProtocolError == .request) }
    }
    @Test(arguments: ["", "a.zip", "/a//b.zip", "/a/../b.zip", "/a/./b.zip", "/a/", "/a\nb.zip", "/a\u{0}b.zip"])
    func malformedPathsFailBeforeURLNormalization(path: String) throws {
        var bytes = try request().bytes.prefix(68); let raw = Data(path.utf8)
        var size = UInt32(raw.count).bigEndian; withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }; bytes.append(raw)
        #expect(throws: DirectUpdateOwnerProtocolError.request) { try DirectUpdateOwnerInit.parse(bytes) }
    }
    @Test func manifestIsBoundedAndBoundToInit() throws {
        let request = try request()
        for data in [Data(), Data([1]), Data(repeating: 1, count: 128 * 1024 + 1)] {
            #expect(throws: DirectUpdateOwnerProtocolError.binding) { try request.validateManifest(data) }
        }
        let maximum = Data(repeating: 5, count: 128 * 1024)
        let large = try DirectUpdateOwnerInit(archive: request.archive, manifest: maximum)
        try large.validateManifest(maximum)
        #expect(throws: DirectUpdateOwnerProtocolError.request) { try DirectUpdateOwnerInit(archive: request.archive, manifest: maximum + Data([1])) }
    }
    @Test(arguments: [0, 4, 35, 36, 67, 68, 99, 100, 131, 132, 163, 164, 183, 184, 191, 192, 193, 194])
    func everyOfferBindingChangesConsent(offset: Int) throws {
        let request = try request(), original = try offer(request)
        let accepted = try DirectUpdateOwnerConsent.accepted(request: request, offer: original)
        var bytes = original.bytes; bytes[offset] ^= 1
        do { let changed = try DirectUpdateOwnerOffer.parse(bytes, request: request)
            #expect(throws: DirectUpdateOwnerProtocolError.binding) { try DirectUpdateOwnerConsent.validateAccepted(accepted, request: request, offer: changed) }
        } catch { #expect(error as? DirectUpdateOwnerProtocolError == .reply) }
    }
    @Test(arguments: ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "-1.2.3", "1.2.3-rc", "١.2.3"])
    func invalidDisplayVersionCannotBeOffered(version: String) throws {
        #expect(throws: DirectUpdateOwnerProtocolError.reply) {
            try DirectUpdateOwnerOffer(request: request(), version: version, build: 96,
                archiveSHA256: Data(repeating: 2, count: 32), runtimeSHA256: Data(repeating: 3, count: 32), candidateCDHash: Data(repeating: 4, count: 20))
        }
    }
    @Test func acceptedCommandAndWrongSessionAreNotInterchangeable() throws {
        let request = try request(), offer = try offer(request), another = try self.request(nonce: 9)
        let accepted = try DirectUpdateOwnerConsent.accepted(request: request, offer: offer)
        #expect(throws: DirectUpdateOwnerProtocolError.binding) { try DirectUpdateOwnerConsent.parseCommand(accepted, request: request, offer: offer) }
        let command = try DirectUpdateOwnerConsent.command(.commit, request: request, offer: offer)
        #expect(throws: DirectUpdateOwnerProtocolError.binding) { try DirectUpdateOwnerConsent.validateAccepted(command, request: request, offer: offer) }
        #expect(throws: DirectUpdateOwnerProtocolError.reply) { try DirectUpdateOwnerConsent.validateAccepted(accepted, request: another, offer: offer) }
        let changedOffer = try self.offer(request, build: 97)
        #expect(throws: DirectUpdateOwnerProtocolError.binding) { try DirectUpdateOwnerConsent.parseCommand(command, request: request, offer: changedOffer) }
        for malformed in [command + Data([0]), Data(command.dropLast()), Data()] {
            #expect(throws: DirectUpdateOwnerProtocolError.binding) { try DirectUpdateOwnerConsent.parseCommand(malformed, request: request, offer: offer) }
        }
    }
}
