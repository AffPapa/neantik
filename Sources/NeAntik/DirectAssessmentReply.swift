import Foundation

/// The current C helper emits one fixed scalar JSON line. Parse that exact
/// grammar, before any coercing JSON decoder, so duplicate/escaped/extra keys,
/// numeric booleans, nesting and second objects cannot silently be accepted.
enum DirectAssessmentReply: Equatable, Sendable {
    case observed(offlineTicketDate: Double, onlineTicketDate: Double)
    case refused(status: Int, gatekeeper: Bool, offline: Bool, online: Bool, onlineDate: Bool, systemError: Int64)
    var installAuthorized: Bool { false }
    static func parse(_ data: Data, exitCode: Int32, normalExit: Bool, now: Double) throws -> Self {
        guard normalExit, !data.isEmpty, data.count <= 1024, now.isFinite, now > 0,
              let text = String(data: data, encoding: .utf8), text.utf8.allSatisfy({ $0 == 10 || (32...126).contains($0) }) else { throw DirectAssessmentParentError.reply }
        func groups(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.range.length == text.utf16.count else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
        let date = #"([0-9]{1,10}\.[0-9]{6})"#
        // No whitespace is emitted by printf. Keep the exact key order and
        // formatting versioned together with the helper, not reader heuristics.
        let successPattern = #"\A\{"schema":1,"status":0,"offlineTicketDate":"# + date + #",\"onlineTicketDate\":"# + date + #",\"freshRemoteResponseProven\":false,\"installAuthorized\":false\}\n\z"#
        if exitCode == 0, let values = groups(successPattern), values.count == 2,
           let offline = Double(values[0]), let online = Double(values[1]),
           offline.isFinite, online.isFinite, offline > 0, online > 0, offline <= now + 300, online <= now + 300 {
            return .observed(offlineTicketDate: offline, onlineTicketDate: online)
        }
        let refusal = #"\A\{"schema":1,"status":([1-9]),"gatekeeperAccepted":(true|false),"offlineTicketAccepted":(true|false),"onlineLookupSuccess":(true|false),"onlineDateValid":(true|false),"systemErrorCode":(0|-?[1-9][0-9]{0,18}),"installAuthorized":false\}\n\z"#
        guard exitCode == 1, let v = groups(refusal), v.count == 6, let status = Int(v[0]), let error = Int64(v[5]) else { throw DirectAssessmentParentError.reply }
        let gatekeeper = v[1] == "true", offline = v[2] == "true", online = v[3] == "true", dateValid = v[4] == "true"
        switch status {
        case 1...6: guard !gatekeeper && !offline && !online && !dateValid else { throw DirectAssessmentParentError.reply }
        case 7: guard gatekeeper && !offline && !online && !dateValid else { throw DirectAssessmentParentError.reply }
        case 8: guard gatekeeper && offline && !(online && dateValid) else { throw DirectAssessmentParentError.reply }
        case 9: guard gatekeeper && offline && online && dateValid && error == 0 else { throw DirectAssessmentParentError.reply }
        default: throw DirectAssessmentParentError.reply
        }
        return .refused(status: status, gatekeeper: gatekeeper, offline: offline, online: online, onlineDate: dateValid, systemError: error)
    }
}
