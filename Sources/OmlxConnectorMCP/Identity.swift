import Foundation
import OmlxConnectorCore

/// Identity and help text specific to the MCP server executable.
///
/// Split out of the shared `AppVersion` when the module gained a second
/// executable: the version is common to both, but the binary name, the MCP
/// `serverInfo.name`, and this help text describe only the server. Keeping them
/// here means `OmlxConnectorCore` never has to know that MCP exists.
enum MCPIdentity {
    /// Binary / product name. MUST equal the on-disk filename in ~/bin.
    static let name = "OmlxConnectorMCP"

    /// MCP `serverInfo.name`. MUST equal `mcpb/manifest.json` -> name.
    /// Claude Desktop silently drops the entire server on mismatch.
    static let mcpServerName = "omlx-connector"

    static var versionString: String { "\(name) \(AppVersion.current)" }

    static var helpMessage: String {
        """
        \(name) \(AppVersion.current) — delegate work to local models on oMLX

        Sends text tasks to an oMLX server running on this machine so that content
        which must not leave the machine is never sent to a cloud model.

        This is usage 2 — Claude answers you and hands selected work to a local
        model. For usage 1, where the local model is the agent itself, run
        `omlx-claude` instead.

        USAGE
          \(name)                 Run as an MCP server over stdio (default)
          \(name) --ping          Check that the oMLX server is reachable, then exit
          \(name) --version, -v   Print version
          \(name) --help, -h      Print this message

        ENVIRONMENT
          OMLX_BASE_URL     oMLX server base URL (default: \(OmlxConfig.defaultBaseURL))
                            Non-loopback hosts are refused unless OMLX_ALLOW_REMOTE=1.
          OMLX_ALLOW_REMOTE Set to 1 to permit a non-loopback host. Only do this for a
                            machine you control; the privacy guarantee is that content
                            stays on hardware you own.
          OMLX_MODEL        Default model id. If unset, the server picks the first
                            model reported by /v1/models at call time.
          OMLX_TIMEOUT      Per-request timeout in seconds (default: \(Int(OmlxConfig.defaultTimeout))).
                            Cold-starting a large model can take 30s or more.
        """
    }
}
