import CoreFoundation
import DirectProvisioning
import Foundation
import Security
import Testing

struct DirectProvisioningCMSTests {
    private func der(_ tag: UInt8, _ value: Data) -> Data {
        let length = value.count
        let encoded: [UInt8] = length < 128 ? [UInt8(length)] :
            (length < 256 ? [0x81, UInt8(length)] : [0x82, UInt8(length >> 8), UInt8(length & 255)])
        return Data([tag] + encoded) + value
    }
    private func oid(_ last: UInt8) -> Data {
        der(0x06, Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, last]))
    }
    private func envelope(outer: UInt8 = 2, inner: UInt8 = 1, detached: Bool = false) -> Data {
        let attached = detached ? Data() : der(0xa0, der(0x04, Data("synthetic".utf8)))
        let content = der(0x30, oid(inner) + attached)
        let signed = der(0x30, der(0x02, Data([1])) + der(0x31, Data()) + content + der(0x31, Data()))
        return der(0x30, oid(outer) + der(0xa0, signed))
    }
    private func admitted(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            neantik_profile_signed_data_envelope(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) != 0
        }
    }
    private func authenticate(_ data: Data) -> (Data?, Int32) {
        var status: Int32 = -1
        let content = neantik_profile_copy_authenticated_content(data as CFData, &status)
        return (content.map { $0 as Data }, status)
    }

    @Test func admissionDoesNotEstablishSignatureOrTrust() {
        let unsigned = envelope()
        #expect(admitted(unsigned))
        let (content, status) = authenticate(unsigned)
        #expect(content == nil)
        #expect(status != NEANTIK_PROFILE_OK)
    }

    @Test func decryptionAndDetachedFormsRefuseBeforeCMS() {
        for value in [envelope(outer: 3), envelope(outer: 6), envelope(inner: 3),
                      envelope(inner: 6), envelope(detached: true)] {
            #expect(!admitted(value))
            let (content, status) = authenticate(value)
            #expect(content == nil)
            #expect(status == NEANTIK_PROFILE_FORMAT)
        }
    }

    @Test func truncationTrailingBytesAndNonDERRefuse() {
        let valid = envelope()
        for count in 0..<valid.count { #expect(!admitted(Data(valid.prefix(count)))) }
        #expect(!admitted(valid + Data([0])))
        #expect(!admitted(Data([0x30, 0x80]) + valid + Data([0, 0])))
        #expect(!admitted(Data([0x30, 0x84, 0xff, 0xff, 0xff, 0xff])))
        #expect(!admitted(Data([0x30, 0x81, UInt8(valid.count-2)]) + valid.dropFirst(2)))
        #expect(!admitted(Data(repeating: 0, count: 2 * 1024 * 1024 + 1)))
    }

    @Test func actualForeignCMSIsCryptographicallyValidButNotAnAppleProfile() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("neantik-cms-negative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.currentDirectoryURL = root
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try Data("synthetic profile negative control".utf8).write(to: root.appendingPathComponent("payload"))
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "owned.key", "-out", "owned.cert",
                 "-subj", "/CN=NeAntikOwnedCMSFixture", "-days", "1"])
        try run(["smime", "-sign", "-binary", "-nodetach", "-in", "payload", "-signer", "owned.cert", "-inkey",
                 "owned.key", "-outform", "DER", "-out", "foreign.cms", "-md", "sha256"])
        let cms = try Data(contentsOf: root.appendingPathComponent("foreign.cms"))
        #expect(admitted(cms))
        let (content, status) = authenticate(cms)
        #expect(content == nil)
        #expect(status == NEANTIK_PROFILE_TRUST)
        try run(["smime", "-encrypt", "-binary", "-in", "payload", "-outform", "DER", "-out", "encrypted.cms", "owned.cert"])
        let encrypted = try Data(contentsOf: root.appendingPathComponent("encrypted.cms"))
        #expect(!admitted(encrypted))
        #expect(authenticate(encrypted).1 == NEANTIK_PROFILE_FORMAT)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_WRONG_PURPOSE_PROFILE"] != nil))
    func trustedAppleCMSOtherPurposeCannotSatisfyMacProfilePolicy() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_WRONG_PURPOSE_PROFILE"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        try #require(admitted(bytes))
        // Deliberately weak control: valid signature plus generic system X509
        // trust. A legitimate iOS CMS must pass this and fail OSX profile policy.
        var decoder: CMSDecoder?
        try #require(CMSDecoderCreate(&decoder) == errSecSuccess)
        let actual = try #require(decoder)
        let update = bytes.withUnsafeBytes { CMSDecoderUpdateMessage(actual, $0.baseAddress!, $0.count) }
        try #require(update == errSecSuccess && CMSDecoderFinalizeMessage(actual) == errSecSuccess)
        var count = 0
        try #require(CMSDecoderGetNumSigners(actual, &count) == errSecSuccess && count == 1)
        var signer = CMSSignerStatus(rawValue: 0)!, trust: SecTrust?, ignored: OSStatus = errSecParam
        let policy = SecPolicyCreateBasicX509()
        try #require(CMSDecoderCopySignerStatus(actual, 0, policy, false, &signer, &trust, &ignored) == errSecSuccess)
        try #require(signer == .valid)
        let realTrust = try #require(trust)
        try #require(SecTrustSetNetworkFetchAllowed(realTrust, false) == errSecSuccess)
        try #require(SecTrustEvaluateWithError(realTrust, nil))
        let (content, status) = authenticate(bytes)
        #expect(content == nil && status == NEANTIK_PROFILE_TRUST)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_QA_PROFILE"] != nil))
    func approvedQAProfileActualOfflineTrustAndTamperControls() throws {
        // Explicit opt-in file; no profile bytes/UUID/certificates are logged.
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_QA_PROFILE"])
        let input: Data
        do { input = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) }
        catch { Issue.record("Approved QA profile could not be read"); return }
        #expect(admitted(input))
        let (content, status) = authenticate(input)
        #expect(status == NEANTIK_PROFILE_OK)
        #expect(content != nil)
        if let content {
            let decoded = try PropertyListSerialization.propertyList(from: content, format: nil) as? [String: Any]
            #expect(decoded?["Platform"] as? [String] == ["OSX"])
        }
        var damaged = input
        guard let signedField = damaged.range(of: Data("<key>Platform</key>".utf8)) else {
            Issue.record("Approved QA profile lacks the expected signed XML fixture field"); return
        }
        // Alter attached signed content, not a possibly unsigned CMS attribute.
        damaged[signedField.lowerBound+5] ^= 1
        let (damagedContent, damagedStatus) = authenticate(damaged)
        #expect(damagedContent == nil)
        #expect(damagedStatus != NEANTIK_PROFILE_OK)
        let (truncatedContent, truncatedStatus) = authenticate(Data(input.dropLast()))
        #expect(truncatedContent == nil)
        #expect(truncatedStatus == NEANTIK_PROFILE_FORMAT)
    }
}
