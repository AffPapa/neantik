// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NeAntik",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NeAntik", targets: ["NeAntik"]),
        .executable(name: "NeAntikUpdateAssessment", targets: ["NeAntikUpdateAssessment"])
    ],
    targets: [
        .target(name: "DirectZipCodec", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "DirectProvisioning", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "DirectAssessment", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "DirectInstallFilesystem"),
        .executableTarget(name: "NeAntikInstallFilesystemFixture", dependencies: ["DirectInstallFilesystem"],
                          path: "Tests/Fixtures/InstallFilesystem"),
        .executableTarget(name: "NeAntikUpdateAssessment", dependencies: ["DirectAssessment"],
                          linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(
            name: "NeAntik",
            dependencies: ["DirectZipCodec", "DirectProvisioning", "DirectInstallFilesystem"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Network")
            ]
        ),
        .testTarget(
            name: "NeAntikTests",
            dependencies: ["NeAntik", "DirectProvisioning", "DirectAssessment", "DirectInstallFilesystem", "NeAntikInstallFilesystemFixture"],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Network")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
