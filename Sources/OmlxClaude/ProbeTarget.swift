import Foundation

/// What the launcher can work out about the oMLX server before handing over.
///
/// `--host`, `--port` and `--api-key` belong to oMLX, not to Claude Code: `omlx
/// launch` parses them itself and they never reach the `claude` binary. We therefore
/// **read them without consuming them** — they stay in the list we forward, and we
/// need their values only so that the preflight checks the server the launcher is
/// actually about to use, and so the settings override names that same address.
///
/// Getting this wrong is not cosmetic. The resolved address is written into
/// `ANTHROPIC_BASE_URL` through `--settings`, which is the highest-precedence channel
/// available — so an address we resolve differently from oMLX is an address content
/// leaves for while oMLX serves somewhere else.
enum ProbeTarget {

    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8000

    /// The credential to talk to oMLX with, or an admission that we do not know it.
    ///
    /// The distinction matters: oMLX reads its own configuration for the API key, and
    /// a launcher that substitutes a guess would replace a working credential with a
    /// broken one. When we cannot determine it, we say so and decline to assert it.
    enum AuthToken: Equatable {
        case known(String)
        case unknown
    }

    /// Base URL of the oMLX server, or nil if the inputs cannot form one.
    ///
    /// Resolution order, weakest first: the built-in default, `OMLX_URL` (carried over
    /// from the shell wrapper so existing setups keep working), then the flags. Each
    /// step overrides **only what it names** — a `--port` does not reset the scheme,
    /// and `OMLX_URL`'s path survives into the result.
    ///
    /// Returns nil rather than trapping. Every input here is user-supplied, and the
    /// previous version force-unwrapped the result: `--host ::1` — an address this
    /// repo's own `OmlxConfig.isLoopback` accepts as canonical IPv6 loopback — took
    /// the process down with SIGTRAP and no message.
    static func resolve(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = defaultHost
        components.port = defaultPort

        if let raw = environment["OMLX_URL"],
            let parsed = URLComponents(string: raw),
            parsed.host != nil
        {
            components = parsed
        }

        if let flagHost = value(of: "--host", in: arguments) {
            components.host = flagHost
        }
        if let flagPort = value(of: "--port", in: arguments) {
            guard let parsed = Int(flagPort), (1...65535).contains(parsed) else { return nil }
            components.port = parsed
        }

        // URLComponents does not bracket IPv6 literals for us, and reading one back
        // may or may not include the brackets depending on where it came from.
        // Normalize both directions so `::1` and `[::1]` land on the same URL.
        if let host = components.host, host.contains(":") {
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            components.host = "[\(bare)]"
        }

        guard let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }

    /// `/v1/models` under the resolved base, preserving any path the base already has.
    static func modelsEndpoint(base: URL) -> URL {
        base.appendingPathComponent("v1").appendingPathComponent("models")
    }

    /// The oMLX credential, from `--api-key` then `OMLX_TOKEN`.
    ///
    /// No default. The previous version fell back to the literal `"omlx"` and asserted
    /// it over whatever oMLX had configured, which broke every authenticated server
    /// and contradicted `LaunchSettings`' own rule about not guessing.
    static func resolveAuthToken(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AuthToken {
        if let flag = value(of: "--api-key", in: arguments) { return .known(flag) }
        if let env = environment["OMLX_TOKEN"], !env.isEmpty { return .known(env) }
        return .unknown
    }

    /// Value of `flag`, matching oMLX's argparse: **the last occurrence wins**, and
    /// nothing past a `--` delimiter is ours to read.
    ///
    /// Handles both `--flag value` and `--flag=value`. It does not handle argparse's
    /// prefix abbreviation (`--po 8001`): guessing at abbreviations risks swallowing a
    /// flag meant for Claude Code, and the cost of missing one is a preflight against
    /// the wrong port — an error message, not silent misbehavior.
    static func value(of flag: String, in arguments: [String]) -> String? {
        var found: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }  // everything after belongs to Claude Code
            if argument == flag, index + 1 < arguments.count {
                let next = arguments[index + 1]
                // A following flag means this occurrence carries no value — keep
                // scanning rather than abandoning later, valid occurrences.
                if looksLikeValue(next) {
                    found = next
                    index += 1
                }
            } else if argument.hasPrefix(flag + "=") {
                let candidate = String(argument.dropFirst(flag.count + 1))
                if !candidate.isEmpty { found = candidate }
            }
            index += 1
        }
        return found
    }

    /// Whether a token following a flag is that flag's value rather than the next
    /// flag.
    ///
    /// Mirrors argparse's rule, negative numbers included: `--port -1` binds `-1` as
    /// the value, which we then refuse on range. Treating it as "no value given"
    /// instead would silently fall back to the default port — a wrong address chosen
    /// without saying so, which is the failure mode this whole type exists to avoid.
    private static func looksLikeValue(_ token: String) -> Bool {
        if token.isEmpty { return false }
        if !token.hasPrefix("-") { return true }
        return token.range(of: #"^-\d+(\.\d+)?$"#, options: .regularExpression) != nil
    }
}
