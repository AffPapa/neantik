// swift-tools-version: 6.2
import PackageDescription

// Separate from the shipping manager. Compiling this package does not install
// a system extension, alter networking, or qualify browser confinement.
let package = Package(
    name: "WebKitIsolation",
    platforms: [.macOS(.v14)],
    products: [.library(name: "IsolationNetworkExtension", targets: ["IsolationNetworkExtension"])],
    targets: [
        .target(name: "IsolationCore"),
        .target(name: "IsolationNetworkExtension", dependencies: ["IsolationCore"],
                linkerSettings: [.linkedFramework("NetworkExtension"), .linkedFramework("Security")]),
        .testTarget(name: "IsolationCoreTests", dependencies: ["IsolationCore"])
    ],
    swiftLanguageModes: [.v5]
)
