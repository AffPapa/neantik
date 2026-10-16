import Foundation

/// Closed source-compiled policy for the security successor.
/// Source/build/sign/scoped headed evidence is separate from final Direct delivery.
package enum DirectUpdateSecurityRuntimePins {
    package static let runtimeDigest = "6dfde85080a3fde010869cc00d6ac35f60cec32165725b5743f2b558070a2638"
    package static let evidenceDigest = "3d42c5fe520c9f55aa320c6b3c0dd8d9b333266aa5bdfd84cb30559fe8076555"
    package static let reportDigest = "71b25e291a3fae01f680e98ed9b3a08c9e97e2190fc2d5400d32a92b8c97069e"
    package static let createdAt = "2026-10-16T02:21:21.552204Z"
    package static let argsDigest = "428054a30abeb212aa3784f524bb27ef4bc0068ab7ebef149866b2b8bff30a3c"
    package static let executableDigest = "cf3bbc56ddbcac264363f33bac4d3f92ac66cf164038c9409651db22708a6941"
    package static let frameworkDigest = "4774c5ef3d9048b7faf9f26307ce07f29be7696a9951e6e179e3e5f8b01d046f"
    package static let runtimeEntries = 948, evidenceEntries = 158
    package static let runtimeBytes: Int64 = 411230673, evidenceBytes: Int64 = 52165979
    package static let reportHashes: [String: String] = [
        "appleDeviceTuplesManifestSHA256": "3c355a6a6708386c410c98cb9310a6f6e62ea5da065eb0faf0290b2a4a4ff6f2",
        "baseFullFDObservationSHA256": "11965553ae0535091f130a7caac97ed107ef99fd0980903847b2f708defe35e0",
        "candidateLockSHA256": "103715ced26bf373f2d1dcda4ebddb473357112192962503507d16d1ac4e78a5",
        "neantikPatchManifestSHA256": "c79ee59b55b1ad474229313660c31c19fcc3b67051bca4f1da1e6098b0b69748",
        "postbuildFullFDObservationSHA256": "55b974bd1c908f92fa7944339489cedbe5afd655b140553ff28545b9890ae97b",
        "securityBaselineSHA256": "aa42ae8b9de5589a1dfa9008e8fc8bcedd059f9123842681a274825973bc76ce",
        "sourceContractSHA256": "5da10213b79c97a4bc3b13a0fd6af5e26d6034179bcdbe160bd244463a06f903",
        "sourceDeltaProofSHA256": "ac345eb85cd0f622e2dac36b5d14b43ad28a4d0e4b19ed967815e54f15226dfc",
        "sourceLockSHA256": "103715ced26bf373f2d1dcda4ebddb473357112192962503507d16d1ac4e78a5",
        "sourceProvenanceSHA256": "4483da5335c04fdb9895d1d472ea0628f9e26f1d208c480da4f2998f25cde949",
    ]
    // Admission is bound to the compiled runtime, never a claim supplied by the download.
    package static let sourceCommit = "634b046faf2137b83af71c87baf362b533af9104"
    package static let sourceContractSHA256 = "5da10213b79c97a4bc3b13a0fd6af5e26d6034179bcdbe160bd244463a06f903"
    package static let securityReference = "https://chromereleases.googleblog.com/2026/10/stable-channel-update-for-desktop_01886704284.html"
    package static let securityFixReferences: [String: String] = [
        "568719351": "https://chromium.googlesource.com/chromium/src/+/d50992ebe4421079a6f9782c7e8a4d0eb3f14c5f",
        "567638392": "https://chromium.googlesource.com/chromium/src/+/6f8bd0510049073dacc94db8968ba350678da324",
        "568831769": "https://chromium.googlesource.com/v8/v8/+/4e469dd5830b78b8fea1318cbabe95c2682e974b",
        "568937999": "https://chromium.googlesource.com/chromium/src/+/eb3f43746d10e5627368c2340cab1ed76d494973",
        "569038297": "https://chromium.googlesource.com/chromium/src/+/54a60b5c28c32cbec956fb83af92142cd5b08568",
        "569286602": "https://chromium.googlesource.com/v8/v8/+/8dd66e1f4f687e137d9a6cfa6628268a1ba7869c",
        "569659194": "https://chromium.googlesource.com/v8/v8/+/d399837d2a9e790736fc05cb36d679215396bd1c",
        "501886301": "https://chromium.googlesource.com/chromium/src/+/90430e752b9669b5054a31d2d4f539cd50ff75e4",
        "556272421": "https://chromium.googlesource.com/chromium/src/+/f06e60e56d7f62632ed78bdfd414d89097669734",
        "563194341": "https://chromium.googlesource.com/chromium/src/+/08f529c57faad9e8bf7cb3881576d0c5fa4b984e",
    ]

}
