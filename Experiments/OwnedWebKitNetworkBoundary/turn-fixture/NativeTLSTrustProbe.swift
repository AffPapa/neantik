import Darwin
import Foundation
import Network
import Security

// Standalone macOS control for the Network.framework callback used by the
// owned WebKit patch. This executable is never linked into the browser.
let args = CommandLine.arguments
guard args.count == 4,
      let number = UInt16(args[1]), number >= 1024, let port = NWEndpoint.Port(rawValue: number),
      ["turn-neantik.invalid", "wrong-neantik.invalid"].contains(args[2]),
      let der = try? Data(contentsOf: URL(fileURLWithPath: args[3])), der.count <= 4096,
      let anchor = SecCertificateCreateWithData(nil, der as CFData) else {
    exit(EX_USAGE)
}

final class Probe: @unchecked Sendable {
    let queue = DispatchQueue(label: "neantik.qa.turn-tls")
    private var trustAccepted: Bool?

    func start(port: NWEndpoint.Port, hostname: String, anchor: SecCertificate) {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(options, hostname)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { [self] _, supplied, complete in
            let trust = sec_trust_copy_ref(supplied).takeRetainedValue()
            guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, hostname as CFString)) == errSecSuccess,
                  SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else {
                complete(false)
                finish("trust-setup-failed")
            }
            let status = SecTrustEvaluateAsyncWithError(trust, queue) { _, accepted, _ in
                self.trustAccepted = accepted
                complete(accepted)
            }
            if status != errSecSuccess {
                complete(false)
                finish("trust-evaluation-failed")
            }
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard trustAccepted == true else { finish("unexpected-ready") }
                let transaction = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
                let binding = Data([0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42]) + transaction
                connection.send(content: binding, completion: .contentProcessed { error in
                    guard error == nil else { self.finish("send-failed") }
                    connection.receive(minimumIncompleteLength: 20, maximumLength: 20) { data, _, _, error in
                        guard error == nil, let data, data.count == 20,
                              data.starts(with: [1, 1]), data[4..<8] == binding[4..<8],
                              data.suffix(12) == transaction else { self.finish("binding-refused") }
                        self.finish("binding-verified")
                    }
                })
            case .waiting where trustAccepted == false:
                // Network.framework can wait to retry a failed handshake.
                finish("trust-rejected")
            case .failed:
                finish(trustAccepted == false ? "trust-rejected" : "transport-failed")
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + 8) { [self] in finish("timeout") }
        connection.start(queue: queue)
    }

    private func finish(_ status: String) -> Never {
        FileHandle.standardOutput.write(Data((status + "\n").utf8))
        exit(EXIT_SUCCESS)
    }
}

let probe = Probe()
probe.start(port: port, hostname: args[2], anchor: anchor)
dispatchMain()
