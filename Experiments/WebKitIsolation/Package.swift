// swift-tools-version: 6.2
import PackageDescription

// Separate from the shipping manager. Compiling this package does not install
// a system extension, alter networking, or qualify browser confinement.
let package = Package(
    name: "WebKitIsolation",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IsolationNetworkExtension", targets: ["IsolationNetworkExtension"]),
        .executable(name: "IsolationQAHost", targets: ["IsolationQAHost"]),
        .executable(name: "IsolationQAControl", targets: ["IsolationQAControl"]),
        .executable(name: "IsolationQAController", targets: ["IsolationQAController"]),
        .executable(name: "IsolationQADenyProvider", targets: ["IsolationQADenyProvider"]),
        .executable(name: "IsolationQASelfPin", targets: ["IsolationQASelfPin"])
    ],
    targets: [
        .target(name: "IsolationCore"),
        .target(name: "IsolationNetworkExtension", dependencies: ["IsolationCore"],
                linkerSettings: [.linkedFramework("NetworkExtension"), .linkedFramework("Security")]),
        .target(name: "IsolationQAHostSupport", dependencies: ["IsolationCore"], linkerSettings: [.linkedFramework("WebKit"), .linkedFramework("AppKit")]),
        .executableTarget(name: "IsolationQAHost", dependencies: ["IsolationQAHostSupport"]),
        .executableTarget(name: "IsolationQAControl", dependencies: ["IsolationQAHostSupport"]),
        .executableTarget(name: "IsolationQAController", dependencies: ["IsolationNetworkExtension", "IsolationCore"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SystemExtensions")]),
        .executableTarget(name: "IsolationQADenyProvider", dependencies: ["IsolationNetworkExtension"]),
        .executableTarget(name: "IsolationQASelfPin", dependencies: ["IsolationNetworkExtension", "IsolationCore"]),
        .testTarget(name: "IsolationCoreTests", dependencies: ["IsolationCore"])
    ],
    swiftLanguageModes: [.v5]
)
