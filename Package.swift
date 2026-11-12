// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "call-transcription",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "MinuteMind",
            targets: ["MinuteMindApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing", from: "0.9.4"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.27.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "MinuteMindApp",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Highlightr", package: "Highlightr"),
            ],
            path: "Sources",
            exclude: [
                "App/Supporting/Info.plist"
            ],
            swiftSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", "Sources/App/Supporting/Info.plist",
                    ], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "MinuteMindTests",
            dependencies: [
                "MinuteMindApp",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests"
        ),
    ]
)
