// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Hushnote",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Hushnote", targets: ["Hushnote"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Hushnote",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Hushnote",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "HushnoteTests",
            dependencies: [
                "Hushnote",
                // Lets tests drive the migrator directly and inspect schema
                // objects such as the FTS triggers.
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/HushnoteTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)

