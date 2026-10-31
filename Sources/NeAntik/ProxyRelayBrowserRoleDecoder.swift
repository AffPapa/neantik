import CoreFoundation
import Darwin
import Foundation

/// Decode only SystemInfo.getProcessInfo from a caller-owned private browser
/// control pipe. An arbitrary JSON file/client response is not an authority.
/// The returned PID still needs live code/kernel/session/socket validation.
enum ProxyRelayBrowserRoleDecoder {
    enum Failure: Error { case malformed, wrongResponse, missingRole, invalidLimit }
    static let maximumResponseBytes = 64 * 1024
    static let maximumProcesses = 512
    static let networkServiceRole = "network.mojom.NetworkService"

    static func networkService(in response: Data, requestID: Int, browserPID: pid_t) throws -> pid_t {
        guard !response.isEmpty, response.count <= maximumResponseBytes,
              requestID > 0, requestID <= Int(Int32.max), browserPID > 0
        else { throw Failure.invalidLimit }
        let root: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw Failure.malformed }
            root = value
        } catch { throw Failure.malformed }
        guard Set(root.keys) == ["id", "result"], integer(root["id"]) == requestID,
              let result = root["result"] as? [String: Any], Set(result.keys) == ["processInfo"],
              let processes = result["processInfo"] as? [[String: Any]],
              !processes.isEmpty, processes.count <= maximumProcesses
        else { throw Failure.wrongResponse }
        var ids = Set<Int>(), main: Int?, network: Int?
        for process in processes {
            guard Set(process.keys) == ["type", "id", "cpuTime"], let id = integer(process["id"]), id > 0,
                  let type = process["type"] as? String, !type.isEmpty, type.utf8.count <= 128,
                  type.utf8.allSatisfy({ (32...126).contains($0) }),
                  let cpu = process["cpuTime"] as? NSNumber, CFGetTypeID(cpu) != CFBooleanGetTypeID(),
                  cpu.doubleValue.isFinite, cpu.doubleValue >= 0, ids.insert(id).inserted
            else { throw Failure.malformed }
            if type == "browser" { guard main == nil else { throw Failure.malformed }; main = id }
            if type == networkServiceRole { guard network == nil else { throw Failure.malformed }; network = id }
        }
        guard main == Int(browserPID), let network, network != main else { throw Failure.missingRole }
        return pid_t(network)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == value.rounded(.towardZero), value > 0, value <= Double(Int32.max) else { return nil }
        return Int(value)
    }
}
