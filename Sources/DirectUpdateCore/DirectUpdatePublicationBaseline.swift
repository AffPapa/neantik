import CoreFoundation
import Foundation

/// Called only after genuine signed-stage verification. Publication date is
/// allowed to advance without changing the historical runtime closure. This
/// never refreshes a manifest's expiry or substitutes for the release doctor.
package enum DirectUpdatePublicationBaseline {
    package static func validate(_ bytes: Data, now: Date = Date()) throws {
        guard (1...65_536).contains(bytes.count),
              let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw DirectUpdateRuntimeProvenanceError.metadata
        }
        let keys: Set<String> = ["schemaVersion", "checkedAt", "publishedAt", "maximumAgeDays",
            "minimumPublicChromiumVersion", "alsoObservedPublicChromiumVersions", "channel", "platforms",
            "securityFixCount", "reference", "referenceTitle", "sourceLabel", "releaseBoundary", "policy"]
        func integer(_ key: String) -> Int? {
            guard let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue == Double(n.intValue) else { return nil }
            return n.intValue
        }
        func version(_ text: String) -> [Int]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 &&
                $0.utf8.allSatisfy({ (48...57).contains($0) }) && ($0.count == 1 || $0.first != "0") }) else { return nil }
            let result = parts.compactMap { Int($0) }; return result.count == 4 ? result : nil
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX"); date.calendar = Calendar(identifier: .gregorian)
        date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "yyyy-MM-dd"; date.isLenient = false
        func day(_ key: String) -> Date? {
            guard let text = value[key] as? String, let d = date.date(from: text), date.string(from: d) == text else { return nil }
            return d
        }
        let extendedKeys = keys.union(["earlyStableObservation", "requiredSecurityFixes", "reviewedSecurityBranches"])
        guard (Set(value.keys) == keys || Set(value.keys) == extendedKeys), integer("schemaVersion") == 1, integer("maximumAgeDays") == 0,
              let fixes = integer("securityFixCount"), (0...100_000).contains(fixes),
              let checked = day("checkedAt"), let published = day("publishedAt"), published <= checked,
              checked <= now,
              let minimum = value["minimumPublicChromiumVersion"] as? String, let components = version(minimum),
              !components.lexicographicallyPrecedes(NeAntikRuntimeSecurityBaseline.minimumPublicChromiumVersion),
              let runtime = version(DirectUpdateRuntimePins.chromiumVersion), !runtime.lexicographicallyPrecedes(components),
              let observed = value["alsoObservedPublicChromiumVersions"] as? [String], observed.count <= 8,
              observed.allSatisfy({ version($0) != nil }),
              value["channel"] as? String == "Desktop Stable", value["platforms"] as? [String] == ["macOS"],
              value["sourceLabel"] as? String == "Chrome Releases",
              let reference = value["reference"] as? String, let url = URLComponents(string: reference),
              url.scheme == "https", url.host == "chromereleases.googleblog.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasSuffix(".html"),
              ["referenceTitle", "releaseBoundary", "policy"].allSatisfy({
                  guard let text = value[$0] as? String else { return false }
                  return !text.isEmpty && text.utf8.count <= 4_096
              }) else { throw DirectUpdateRuntimeProvenanceError.metadata }
    }

    /// Evaluate after closure and report selection: metadata alone cannot enroll a runtime.
    package static func validateSecurityReview(_ bytes: Data, record: DirectUpdateRuntimeRecord) throws {
        try validate(bytes)
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              (record == .fontSystemSecurity20261015V1 || record == .componentCompletionV1),
              value["reference"] as? String == DirectUpdateSecurityRuntimePins.securityReference,
              let required = value["requiredSecurityFixes"] as? [String],
              required.count == DirectUpdateSecurityRuntimePins.securityFixReferences.count,
              Set(required) == Set(DirectUpdateSecurityRuntimePins.securityFixReferences.keys),
              let branches = value["reviewedSecurityBranches"] as? [String: Any],
              Set(branches.keys) == ["156.0.8078"],
              let branch = branches["156.0.8078"] as? [String: Any],
              branch["status"] as? String == "verified",
              branch["minimumVersion"] as? String == DirectUpdateRuntimePins.chromiumVersion,
              branch["sourceCommit"] as? String == DirectUpdateSecurityRuntimePins.sourceCommit,
              branch["sourceContractSHA256"] as? String == record.reportHashes["sourceContractSHA256"],
              branch["securityReference"] as? String == DirectUpdateSecurityRuntimePins.securityReference,
              let fixes = branch["fixes"] as? [String: [String: String]],
              Set(fixes.keys) == Set(required),
              fixes.allSatisfy({ key, fix in
                  fix == ["status": "included", "reference": DirectUpdateSecurityRuntimePins.securityFixReferences[key]!]
              }),
              let count = value["securityFixCount"] as? Int, count == required.count,
              value["earlyStableObservation"] is [String: Any]
        else { throw DirectUpdateRuntimeProvenanceError.metadata }
    }

}
