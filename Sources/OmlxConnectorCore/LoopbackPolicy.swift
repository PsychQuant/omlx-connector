import Foundation

/// Whether content is allowed to leave this machine.
///
/// This is the project's load-bearing invariant, stated in `CLAUDE.md` as the one that
/// cannot regress: the entire premise is that content stays on the hardware you own.
/// It is enforced in code rather than promised in a README, because a privacy property
/// that depends on nobody mis-editing a config file is not a privacy property.
///
/// It lives in the shared library because **both** entry points need it and neither may
/// have its own copy. The MCP server had it; `omlx-claude` shipped without it, and four
/// independent reviewers found that gap in one pass — a second implementation would
/// merely have moved the divergence somewhere harder to see.
public enum LoopbackPolicy {

    /// `127.0.0.1` is preferred over `localhost` as a default elsewhere in this module
    /// because the latter can resolve to `::1` first, which a server bound only to IPv4
    /// will refuse. Both are accepted here.
    public static func isLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        return normalized.hasPrefix("127.")
    }

    /// The deliberate opt-out, for the one legitimate case: an oMLX instance on another
    /// machine the operator owns.
    ///
    /// Accepts **only** the literal `1`. A stray `true` or `yes` does not open the door —
    /// this is checked by test, because the failure mode of a lenient parse here is
    /// content silently leaving the machine.
    public static func allowsRemote(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["OMLX_ALLOW_REMOTE"] == "1"
    }
}
