import Foundation
import Darwin
import Security
import IsolationCore
import IsolationNetworkExtension

/// Positive dynamic Security-API control before another network experiment.
/// Reads ONLY its own kernel token. No other process, network, Keychain,
/// entitlement, profile or actual guest identity is inspected or exported.
@main enum SelfPinControl {
    private enum Refusal: Error { case arguments, ownToken, ownIntegrity, positive, negative }

    static func main() {
        do { try run() }
        catch {
            // An arbitrary Security error description can contain private
            // metadata. Only a closed failure label leaves this process.
            let label: String
            switch error {
            case Refusal.arguments: label = "arguments"
            case Refusal.ownToken: label = "own-token"
            case Refusal.ownIntegrity: label = "own-integrity"
            case Refusal.positive: label = "own-positive"
            case Refusal.negative: label = "negative-not-refused"
            default: label = "unexpected-control-failure"
            }
            write(["status": "FAIL", "stage": label, "networkRun": false,
                   "otherProcessInspected": false, "releaseQualified": false])
            exit(1)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 2 else { throw Refusal.arguments }
        let text = CommandLine.arguments[1]
        guard text.utf8.count == 40, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw Refusal.arguments }
        let hash = Data(stride(from: 0, to: 40, by: 2).compactMap { offset -> UInt8? in
            let start = text.index(text.startIndex, offsetBy: offset)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)
        })
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard status == KERN_SUCCESS, Int(count) * MemoryLayout<integer_t>.size == MemoryLayout<audit_token_t>.size
        else { throw Refusal.ownToken }
        let ownBytes = withUnsafeBytes(of: token) { Data($0) }
        let expectedToken = try ProcessToken(kernelBytes: ownBytes)
        var ownCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &ownCode) == errSecSuccess, let ownCode,
              SecCodeCheckValidity(ownCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { throw Refusal.ownIntegrity }
        let identifier = "app.neantik.desktop.network-qa.selfpin", team = "H6VGU2M6JD"
        let pin = try SignedHostPin(identifier: identifier, team: team, cdHash: hash)
        let diagnostic = pin.expectedClauseDiagnostics(kernelAuditToken: ownBytes)
        guard (try? pin.verify(kernelAuditToken: ownBytes)) == expectedToken else {
            write(["status": "FAIL", "stage": "own-positive", "expectedClauseStatuses": diagnostic,
                   "networkRun": false, "otherProcessInspected": false, "tokenExported": false,
                   "releaseQualified": false])
            exit(1)
        }
        var wrongHash = hash; wrongHash[0] ^= 1
        let wrongIdentifier = try SignedHostPin(identifier: identifier + ".wrong", team: team, cdHash: hash)
        let wrongBuild = try SignedHostPin(identifier: identifier, team: team, cdHash: wrongHash)
        var refused = 0
        for incorrect in [wrongIdentifier, wrongBuild] {
            do { _ = try incorrect.verify(kernelAuditToken: ownBytes); throw Refusal.negative }
            catch HostVerificationFailure.requirement(let status) where status != errSecSuccess { refused += 1 }
        }
        guard refused == 2 else { throw Refusal.negative }
        write(["schemaVersion": 1, "status": "PASS own dynamic pin and two negative controls",
               "ownKernelTokenRead": true, "fullTokenEqualityVerified": true,
               "expectedClauseStatuses": diagnostic, "negativeControlsRefused": refused,
               "networkRun": false, "otherProcessInspected": false,
               "tokenExported": false, "actualGuestIdentityExported": false,
               "releaseQualified": false])
    }

    private static func write(_ value: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), bytes.count <= 2048 else { exit(2) }
        FileHandle.standardOutput.write(bytes); FileHandle.standardOutput.write(Data([10]))
    }
}
