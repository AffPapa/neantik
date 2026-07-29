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
        .executableTarget(
            name: "NeAntik",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Network")
            ]
        ),
        .testTarget(
            name: "NeAntikTests",
            dependencies: ["NeAntik"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Network")
            ]
        )
    ]
)
