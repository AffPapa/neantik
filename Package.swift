// swift-tools-version: 6.2

import PackageDescription
import Foundation

let webKitProxyBuildMode = ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_PROXY_BUILD_MODE"] ?? "disabled"
let chromiumOnlyBuild = ProcessInfo.processInfo.environment["NEANTIK_CHROMIUM_ONLY"] == "1"
let webKitProxyBuildSettings: [SwiftSetting]
switch webKitProxyBuildMode {
case "disabled":
    webKitProxyBuildSettings = []
case "qualification":
    webKitProxyBuildSettings = [.define("NEANTIK_WEBKIT_PROXY_QUALIFICATION")]
case "production":
    webKitProxyBuildSettings = [.define("NEANTIK_WEBKIT_PROXY_PRODUCTION")]
case "diagnostic":
    // Private, signed production-ID diagnostics only. Release entrypoints
    // reject this mode; it must never be used for ZIP/DMG delivery.
    webKitProxyBuildSettings = [.define("NEANTIK_WEBKIT_PROXY_DIAGNOSTIC")]
default:
    fatalError("NEANTIK_WEBKIT_PROXY_BUILD_MODE must be disabled, qualification, production, or diagnostic")
}

let package = Package(
    name: "NeAntik",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NeAntik", targets: ["NeAntik"]),
        .executable(name: "NeAntikWebKitHost", targets: ["NeAntikWebKitHost"]),
        .executable(name: "NeAntikUpdateAssessment", targets: ["NeAntikUpdateAssessment"]),
        .executable(name: "NeAntikUpdateOwner", targets: ["NeAntikUpdateOwner"])
    ],
    targets: [
        .target(name: "DirectZipCodec", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "DirectProvisioning", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "DirectAssessment", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "DirectAssessmentParent"),
        .target(name: "DirectUpdateBootstrapParent"),
        .executableTarget(name: "NeAntikUpdateBootstrapFixture", path: "Tests/Fixtures/UpdateBootstrap"),
        .executableTarget(name: "NeAntikUpdateOwnerFixture", dependencies: ["DirectUpdateBootstrapParent"], path: "Tests/Fixtures/UpdateOwner"),
        .executableTarget(name: "NeAntikAssessmentParentFixture", dependencies: ["DirectAssessmentParent"], path: "Tests/Fixtures/AssessmentParent"),
        .target(name: "DirectInstallFilesystem"),
        .target(name: "DirectUpdateCore", dependencies: ["DirectZipCodec", "DirectProvisioning", "DirectInstallFilesystem", "DirectAssessmentParent", "DirectUpdateBootstrapParent"]),
        .executableTarget(name: "NeAntikUpdateOwner", dependencies: ["DirectUpdateCore", "DirectInstallFilesystem"]),
        .executableTarget(name: "NeAntikInstallFilesystemFixture", dependencies: ["DirectInstallFilesystem"],
                          path: "Tests/Fixtures/InstallFilesystem"),
        .executableTarget(name: "NeAntikUpdateAssessment", dependencies: ["DirectAssessment"],
                          linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(
            name: "NeAntik",
            dependencies: ["DirectUpdateCore", "DirectZipCodec", "DirectProvisioning", "DirectInstallFilesystem", "DirectAssessmentParent"],
            // Use WebKit's Objective-C proxy API. The system Swift overlay
            // re-exports system WebKit and cannot enter an owned-runtime host.
            // Any new overlay symbol must fail linking, not silently mix engines.
            swiftSettings: webKitProxyBuildSettings + (chromiumOnlyBuild ? [.define("NEANTIK_CHROMIUM_ONLY")] : []) + [.unsafeFlags(["-Xfrontend", "-disable-autolink-library",
                                                                      "-Xfrontend", "swiftWebKit"])],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Network")
            ]
        ),
        .executableTarget(
            name: "NeAntikWebKitHost",
            dependencies: ["DirectUpdateCore", "DirectZipCodec", "DirectProvisioning", "DirectInstallFilesystem", "DirectAssessmentParent"],
            path: "DerivedSources/NeAntikWebKitHost",
            swiftSettings: [.define("NEANTIK_WEBKIT_STANDALONE_HOST")] + webKitProxyBuildSettings + [
                            .unsafeFlags(["-Xfrontend", "-disable-autolink-library",
                                          "-Xfrontend", "swiftWebKit"])],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("Network")]
        ),
        .testTarget(
            name: "NeAntikTests",
            dependencies: ["NeAntik", "DirectUpdateCore", "DirectProvisioning", "DirectAssessment", "DirectInstallFilesystem", "DirectAssessmentParent", "DirectUpdateBootstrapParent", "NeAntikAssessmentParentFixture", "NeAntikInstallFilesystemFixture", "NeAntikUpdateBootstrapFixture", "NeAntikUpdateOwnerFixture"],
            swiftSettings: webKitProxyBuildSettings,
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Network")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
