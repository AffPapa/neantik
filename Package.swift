// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NeAntik",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NeAntik", targets: ["NeAntik"])
    ],
    targets: [
        .target(name: "DirectZipCodec", linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(
            name: "NeAntik",
            dependencies: ["DirectZipCodec"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Network")
            ]
        ),
        .testTarget(
            name: "NeAntikTests",
            dependencies: ["NeAntik"],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Network")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
