import Foundation
import OmlxConnectorCore

let arguments = CommandLine.arguments

if arguments.contains("--version") || arguments.contains("-v") {
    print(MCPIdentity.versionString)
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(MCPIdentity.helpMessage)
    exit(0)
}

/// Resolve configuration before anything else. A refused non-loopback host or a
/// malformed URL is a startup error, not a per-call surprise — the operator should
/// learn about it when they configure the server, not when a tool call fails.
let baseURL: URL
do {
    baseURL = try OmlxConfig.resolveBaseURL()
} catch {
    FileHandle.standardError.write(
        Data("\(MCPIdentity.name): \(describeForDisplay(error))\n".utf8))
    exit(2)
}

let client = OmlxClient(baseURL: baseURL, timeout: OmlxConfig.resolveTimeout())

if arguments.contains("--ping") {
    do {
        let models = try await client.listModels()
        let loaded = models.filter(\.loaded).map(\.id)
        print("\(MCPIdentity.name) \(AppVersion.current)")
        print("server:  \(baseURL.absoluteString) — reachable")
        print("models:  \(models.count) available")
        print("loaded:  \(loaded.isEmpty ? "none (first call will pay a cold start)" : loaded.joined(separator: ", "))")
        if let configured = OmlxConfig.defaultModel() {
            print("default: \(configured) (from OMLX_MODEL)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("\(MCPIdentity.name): \(describeForDisplay(error))\n".utf8))
        exit(1)
    }
}

// Banner goes to stderr so it cannot corrupt the stdio JSON-RPC stream.
if ProcessInfo.processInfo.environment["OMLX_CONNECTOR_NO_BANNER"] == nil {
    FileHandle.standardError.write(
        Data("\(MCPIdentity.name) \(AppVersion.current) → \(baseURL.absoluteString)\n".utf8))
}

let server = await OmlxConnectorServer(client: client)
try await server.run()
