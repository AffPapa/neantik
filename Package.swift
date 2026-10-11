// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NeAntik",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NeAntik", targets: ["NeAntik"]),
        .executable(name: "NeAntikUpdateAssessment", targets: ["NeAntikUpdateAssessment"]),
        .executable(name: "NeAntikUpdateOwner", targets: ["NeAntikUpdateOwner"])
    ],
    targets: [
        .target(name: "DirectZipCodec", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "DirectProvisioning", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "DirectAssessment", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "DirectAssessmentParent"),
        .executableTarget(name: "NeAntikAssessmentParentFixture", dependencies: ["DirectAssessmentParent"], path: "Tests/Fixtures/AssessmentParent"),
        .target(name: "DirectInstallFilesystem"),
        .target(name: "DirectUpdateCore", dependencies: ["DirectZipCodec", "DirectProvisioning", "DirectInstallFilesystem", "DirectAssessmentParent"]),
        .executableTarget(name: "NeAntikUpdateOwner", dependencies: ["DirectUpdateCore", "DirectInstallFilesystem"]),
        .executableTarget(name: "NeAntikInstallFilesystemFixture", dependencies: ["DirectInstallFilesystem"],
                          path: "Tests/Fixtures/InstallFilesystem"),
        .executableTarget(name: "NeAntikUpdateAssessment", dependencies: ["DirectAssessment"],
                          linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(
            name: "NeAntik",
            dependencies: ["DirectUpdateCore", "DirectZipCodec", "DirectProvisioning", "DirectInstallFilesystem", "DirectAssessmentParent"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Network")
            ]
        ),
        .testTarget(
            name: "NeAntikTests",
            dependencies: ["NeAntik", "DirectUpdateCore", "DirectProvisioning", "DirectAssessment", "DirectInstallFilesystem", "DirectAssessmentParent", "NeAntikAssessmentParentFixture", "NeAntikInstallFilesystemFixture"],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Network")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
