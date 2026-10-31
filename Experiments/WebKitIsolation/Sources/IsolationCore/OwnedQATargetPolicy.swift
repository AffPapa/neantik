import Foundation
import Darwin

/// Limits navigation in the disposable probe. This is not a network firewall:
/// the native stage must separately own the endpoint and measure subresources.
public enum OwnedQATargetPolicy {
    public static func permits(_ url: URL, runID: String) -> Bool {
        guard UUID(uuidString: runID) != nil,
              url.scheme == "http", url.user == nil, url.password == nil,
              url.fragment == nil, let port = url.port, (1...65535).contains(port),
              let host = url.host,
              url.path.hasPrefix("/__neantik_isolation_qa/" + runID + "/") else { return false }
        if ["::1", "[::1]"].contains(host) { return true }
        // Parse the entire literal. Dropping nonnumeric DNS labels would let
        // e.g. 10.0.0.1.example.com escape the fixture's address scope.
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        return value == 0x7f000001 || value >> 24 == 10 ||
            value >> 20 == 0xac1 || value >> 16 == 0xc0a8
    }
}
