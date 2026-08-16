// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OmlxConnectorMCP",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.0"))
    ],
    targets: [
        // No Info.plist linker settings and no Entitlements: this server touches no
        // TCC-protected resource. It is a plain HTTP client to a loopback address.
        .executableTarget(
            name: "OmlxConnectorMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/OmlxConnectorMCP"
        ),
        .testTarget(
            name: "OmlxConnectorMCPTests",
            dependencies: [
                "OmlxConnectorMCP",
                // Declared explicitly: tests construct `Value` arguments directly,
                // and a transitive dependency is not importable.
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/OmlxConnectorMCPTests"
        )
    ]
)
