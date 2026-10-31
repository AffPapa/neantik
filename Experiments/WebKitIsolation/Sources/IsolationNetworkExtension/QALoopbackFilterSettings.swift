import Foundation
import NetworkExtension
import IsolationCore

/// Unapplied recipe only. macOS ignores loopback in a wildcard/default rule;
/// explicit loopback rules must request filterData, then attribute the flow.
/// No manager preferences, activation or networking are changed here.
public enum QALoopbackFilterSettings {
    public static func make(scope: QALoopbackFilterScope) -> NEFilterSettings {
        let rules = scope.ports.flatMap { port in
            [("127.0.0.1", 32), ("::1", 128)].map { host, prefix in
                let endpoint = NWHostEndpoint(hostname: host, port: String(port))
                let match = NENetworkRule(remoteNetwork: endpoint, remotePrefix: prefix,
                                          localNetwork: nil, localPrefix: 0,
                                          protocol: .any, direction: .outbound)
                return NEFilterRule(networkRule: match, action: .filterData)
            }
        }
        return NEFilterSettings(rules: rules, defaultAction: .allow)
    }
}
