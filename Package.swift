// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OmlxConnectorMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OmlxConnectorMCP", targets: ["OmlxConnectorMCP"]),
        // The product name is the on-disk filename. The target keeps Swift's
        // PascalCase; the command users type is hyphenated.
        .executable(name: "omlx-claude", targets: ["OmlxClaude"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.0"))
    ],
    targets: [
        // Deliberately small. Only what more than one executable needs lives here —
        // today the version and the upstream-workaround staleness check. Everything
        // that belongs to a single command (the MCP tool surface, the launcher's
        // argument handling) stays with that command, so this library never has to
        // widen its access level to serve one caller.
        .target(
            name: "OmlxConnectorCore",
            path: "Sources/OmlxConnectorCore"
        ),
        // No Info.plist linker settings and no Entitlements: this server touches no
        // TCC-protected resource. It is a plain HTTP client to a loopback address.
        .executableTarget(
            name: "OmlxConnectorMCP",
            dependencies: [
                "OmlxConnectorCore",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/OmlxConnectorMCP"
        ),
        // Usage 1: the local model is the agent. A thin layer over
        // `omlx launch claude`, which it execs into rather than replacing.
        .executableTarget(
            name: "OmlxClaude",
            dependencies: ["OmlxConnectorCore"],
            path: "Sources/OmlxClaude"
        ),
        .testTarget(
            name: "OmlxConnectorMCPTests",
            dependencies: [
                "OmlxConnectorCore",
                "OmlxConnectorMCP",
                "OmlxClaude",
                // Declared explicitly: tests construct `Value` arguments directly,
                // and a transitive dependency is not importable.
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/OmlxConnectorMCPTests"
        )
    ]
)
