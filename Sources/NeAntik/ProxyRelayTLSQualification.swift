#if DEBUG
import Foundation
import Network
import Security

/// Private-anchor TLS controls for owned loopback fixtures only. This type and
/// its transport initializer do not exist in release builds. Production keeps
/// Network's default certificate policy; no environment/preference override.
enum ProxyRelayTLSQualification {
    enum Failure: Error { case invalidAnchor, invalidEndpoint }
    struct Configuration: Sendable {
        private let anchorDER: Data
        init(anchorDER: Data) throws {
            guard !anchorDER.isEmpty, anchorDER.count <= 4096,
                  let certificate = SecCertificateCreateWithData(nil, anchorDER as CFData),
                  SecCertificateCopyData(certificate) as Data == anchorDER
            else { throw Failure.invalidAnchor }
            self.anchorDER = anchorDER
        }

        func parameters(for upstream: ProxyRelayDestination) throws -> NWParameters {
            // A fixed localhost TLS name is deliberate: a port is owned by the
            // fixture runner; arbitrary upstreams cannot receive test trust.
            guard upstream.host == "localhost" else { throw Failure.invalidEndpoint }
            let tls = NWProtocolTLS.Options()
            let anchorDER = self.anchorDER
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, "localhost")
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, supplied, complete in
                let trust = sec_trust_copy_ref(supplied).takeRetainedValue()
                guard let anchor = SecCertificateCreateWithData(nil, anchorDER as CFData),
                      SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "localhost" as CFString)) == errSecSuccess,
                      SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                      SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
                else { complete(false); return }
                // Preserve full chain, name and date evaluation. No pin-only,
                // changed verification date or unconditional success path.
                complete(SecTrustEvaluateWithError(trust, nil))
            }, DispatchQueue(label: "app.neantik.relay.owned-tls-qualification"))
            return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        }
    }
}
#endif
