import Foundation

/// Single source of truth for the version shared by every executable in this module.
///
/// `scripts/build-release.sh` hard-fails if any mirror of this value drifts
/// (mcpb/manifest.json, plugin/.claude-plugin/plugin.json,
/// .claude-plugin/marketplace.json).
///
/// Identity that belongs to one executable — binary name, MCP `serverInfo.name`,
/// per-command help text — deliberately does **not** live here. It sits with the
/// executable that owns it (`Sources/OmlxConnectorMCP/Identity.swift`), so this
/// library stays free of any single command's vocabulary.
public enum AppVersion {
    public static let current = "0.3.0"

    public static let displayName = "oMLX Connector"
}
