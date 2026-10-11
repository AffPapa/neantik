import Darwin
import DirectAssessment
import Foundation
import Testing

struct DirectUpdateAssessmentTests {
    private func key(_ name: String) throws -> String {
        let pointer = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name))
        let value = pointer.assumingMemoryBound(to: CFString?.self).pointee
        return try #require(value) as String
    }
    private func result() throws -> [String: Any] {
        [try key("kSecAssessmentAssessmentVerdict"): true,
         try key("kSecAssessmentAssessmentAuthority"): [try key("kSecAssessmentAssessmentSource"): "Notarized Developer ID"]]
    }
    @Test func enforcedIndependentAssessmentFlags() {
        #expect(neantik_assessment_flags() == (1 << 28 | 1 << 27 | 1 << 26 | 1 << 24 | 1 << 22))
        #expect(neantik_assessment_flags() & (1 << 30 | 1 << 29 | 1 << 25) == 0)
    }
    @Test(arguments: ["kSecAssessmentAssessmentFromCache", "kSecAssessmentAssessmentWeakSignature",
                      "kSecAssessmentAssessmentCodeSigningError", "kSecAssessmentAssessmentAuthorityOverride",
                      "kSecAssessmentAssessmentAuthorityOriginalVerdict"])
    func bypassMarkersRefuseEvenWithNotarizedLabel(marker: String) throws {
        let normal = try result()
        #expect(neantik_assessment_result_admitted(normal as CFDictionary) == 1)
        var top = normal; top[try key(marker)] = false
        #expect(neantik_assessment_result_admitted(top as CFDictionary) == 0)
        var nested = normal
        var authority = try #require(nested[try key("kSecAssessmentAssessmentAuthority")] as? [String: Any])
        authority[try key(marker)] = 0
        nested[try key("kSecAssessmentAssessmentAuthority")] = authority
        #expect(neantik_assessment_result_admitted(nested as CFDictionary) == 0)
    }
    @Test(arguments: ["false", "integer", "string", "missing", "authority", "size"])
    func malformedOrDeniedAssessmentRefuses(control: String) throws {
        var value = try result(), verdict = try key("kSecAssessmentAssessmentVerdict")
        switch control {
        case "false": value[verdict] = false
        case "integer": value[verdict] = 1
        case "string": value[verdict] = "true"
        case "missing": value.removeValue(forKey: verdict)
        case "authority": value[try key("kSecAssessmentAssessmentAuthority")] = true
        case "size": for i in 0..<33 { value["fixture-\(i)"] = 0 }
        default: Issue.record("Unknown control")
        }
        #expect(neantik_assessment_result_admitted(value as CFDictionary) == 0)
    }
    @Test func ticketSuccessRequiresActualDateAndNoError() {
        let now = 812_000_000.0, date = now - 86400
        #expect(neantik_assessment_ticket_admitted(1, 0, date, now) == 1)
        #expect(neantik_assessment_ticket_admitted(0, 0, date, now) == 0)
        #expect(neantik_assessment_ticket_admitted(1, 1, date, now) == 0)
        #expect(neantik_assessment_ticket_admitted(2, 0, date, now) == 0)
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1, now + 301, now + 978_307_200] {
            #expect(neantik_assessment_ticket_admitted(1, 0, invalid, now) == 0)
        }
        #expect(neantik_assessment_ticket_admitted(1, 0, date, .nan) == 0)
    }
    @Test func rawSystemErrorMarkerRefuses() throws {
        var value = try result()
        value["assessment:error"] = 0
        #expect(neantik_assessment_result_admitted(value as CFDictionary) == 0)
    }
    @Test func revocationCompletionAllowsAbsentDateButNeverAnError() {
        let now = 812_000_000.0
        for date in [Double.nan, now - 86400, now] {
            #expect(neantik_assessment_revocation_admitted(1, 0, date, now) == 1)
            #expect(neantik_assessment_revocation_admitted(0, 0, date, now) == 0)
            #expect(neantik_assessment_revocation_admitted(2, 0, date, now) == 0)
            // Both simulated revoked and other API errors must refuse.
            #expect(neantik_assessment_revocation_admitted(1, EACCES, date, now) == 0)
            #expect(neantik_assessment_revocation_admitted(1, 1, date, now) == 0)
        }
        for invalid in [Double.infinity, -Double.infinity, 0, -1, now + 301] {
            #expect(neantik_assessment_revocation_admitted(1, 0, invalid, now) == 0)
        }
        for invalid in [Double.nan, Double.infinity, 0, -1] {
            #expect(neantik_assessment_revocation_admitted(1, 0, .nan, invalid) == 0)
        }
    }
    private func admits(_ entries: [String]) -> Int32 {
        let memory = entries.map { strdup($0)! }
        defer { memory.forEach { free($0) } }
        return (memory.map(Optional.some) + [nil]).withUnsafeBufferPointer {
            neantik_assessment_environment_admitted($0.baseAddress)
        }
    }
    @Test func environmentExcludesPolicyOverrideAndInjection() {
        let clean = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "TMPDIR=/private/tmp"]
        #expect(admits(clean) == 1)
        #expect(admits(clean + ["__CF_USER_TEXT_ENCODING=\(getuid()):0x0:0x0"]) == 1)
        let auto = "__CF_USER_TEXT_ENCODING=0x\(String(getuid(), radix: 16)):0:0"
        #expect(admits(clean + [auto]) == 1)
        #expect(admits([auto, "__CF_USER_TEXT_ENCODING=\(getuid()):0x0:0x0"]) == 0)
        #expect(admits(clean + ["__CF_USER_TEXT_ENCODING=\(getuid()):0x1:0x0"]) == 0)
        #expect(admits(clean + ["__CF_USER_TEXT_ENCODING=\(getuid() + 1):0x0:0x0"]) == 0)
        for invalid in ["+501:0:0", "501:0:0:0", "0x100000000000000:0:0", "501:00x:0", "501: :0"] {
            #expect(admits(["__CF_USER_TEXT_ENCODING=" + invalid]) == 0)
        }
        #expect(admits([]) == 1)
        for entry in ["SYSPOLICYNAME=fixture", "DYLD_INSERT_LIBRARIES=fixture", "HOME=fixture",
                      "TMPDIR=/tmp", "LANG=en_US.UTF-8", "PATH=/tmp", "NEANTIK_TEST=1"] {
            #expect(admits([entry]) == 0)
            #expect(admits(clean + [entry]) == 0)
        }
        #expect(admits([clean[0], clean[0]]) == 0)
    }
}
