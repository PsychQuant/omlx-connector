import Foundation
import OmlxConnectorCore

#if canImport(Darwin)
    import Darwin
#endif

/// What the launcher can work out about the oMLX server before handing over.
///
/// `--host`, `--port` and `--api-key` belong to oMLX, not to Claude Code: `omlx launch`
/// parses them itself and they never reach the `claude` binary. We therefore **read them
/// without consuming them** — they stay in the list we forward, and we need their values
/// only so that the preflight checks the server the launcher is actually about to use,
/// and so the settings override names that same address.
///
/// Getting this wrong is not cosmetic. The resolved address is written into
/// `ANTHROPIC_BASE_URL` through `--settings`, which outranks every settings file a user
/// writes (though not a managed/MDM policy — see `LaunchSettings`) — so an address we
/// resolve differently from oMLX is an address content leaves for while oMLX serves
/// somewhere else. Two rounds of review found two separate
/// ways that happened; both are now covered by tests that use oMLX's own semantics as
/// the oracle rather than our idea of them.
enum ProbeTarget {

    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8000

    /// Every option `omlx launch` defines, from its own `--help`.
    ///
    /// Needed in full because argparse accepts **any unambiguous prefix**: `--ho` is
    /// `--host`, `--p` is `--port`. Knowing only the options we care about is not enough
    /// — we must also know the ones we do not, or `--ha` (haiku) would be mistaken for a
    /// prefix of `--host`.
    static let omlxOptions = [
        "--api-key", "--cross-session", "--haiku", "--host", "--model",
        "--opus", "--port", "--sonnet", "--tools-profile",
    ]

    /// Options that take no value; a following token is not theirs to swallow.
    static let omlxFlagOptions: Set<String> = ["--cross-session"]

    /// The credential to talk to oMLX with, or an admission that we do not know it.
    ///
    /// The distinction matters: oMLX reads its own configuration for the API key, and a
    /// launcher that substitutes a guess would replace a working credential with a
    /// broken one. When we cannot determine it, we say so and decline to assert it.
    enum AuthToken: Equatable {
        case known(String)
        case unknown
    }

    /// Base URL of the oMLX server, or nil if the inputs cannot form one.
    ///
    /// Prefer `resolveChecked` — it also applies the loopback policy. This entry point
    /// exists for tests and for callers that have already decided about remoteness.
    static func resolve(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard case .success(let url) = resolveChecked(arguments: arguments, environment: environment)
        else { return nil }
        return url
    }

    /// Base URL, refusing a non-loopback target unless the operator opted in.
    ///
    /// Resolution order, weakest first: the built-in default, `OMLX_URL`, then the flags.
    /// Each step overrides **only what it names** — a `--port` does not reset the scheme,
    /// and `OMLX_URL`'s path survives into the result.
    ///
    /// The loopback check is the same `LoopbackPolicy` the MCP server uses. `omlx-claude`
    /// originally shipped without one, which four reviewers independently reported: the
    /// launcher would resolve any `OMLX_URL` and assert it into `ANTHROPIC_BASE_URL`,
    /// sending a whole session and its bearer token wherever that pointed.
    static func resolveChecked(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<URL, LaunchError> {
        var components = URLComponents()
        components.scheme = "http"
        components.host = defaultHost
        components.port = defaultPort

        if let raw = environment["OMLX_URL"] {
            guard let parsed = URLComponents(string: raw), parsed.host != nil,
                parsed.scheme != nil
            else {
                // Silently falling back to the default would point us at a different
                // server than the operator asked for, which is the failure class this
                // type exists to prevent.
                return .failure(
                    .unusableAddress(detail: "OMLX_URL is not a usable base URL: \(raw)"))
            }
            components = parsed
        }

        if let flagHost = value(of: "--host", in: arguments) {
            components.host = flagHost
        }
        if let flagPort = value(of: "--port", in: arguments) {
            guard let parsed = Int(flagPort), (1...65535).contains(parsed) else {
                return .failure(.unusableAddress(detail: "--port must be 1-65535, got \(flagPort)"))
            }
            components.port = parsed
        }

        guard let rawHost = components.host, !rawHost.isEmpty else {
            return .failure(.unusableAddress(detail: "No host to connect to."))
        }

        // Bracket IPv6 literals, and *only* those. Round 1 bracketed anything containing
        // a colon, which turned `--host evil.com:9999` into a usable-looking
        // `http://[evil.com:9999]:8000` and made the unusable-address error unreachable.
        let bare = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.contains(":") {
            guard isIPv6Literal(bare) else {
                return .failure(.unusableAddress(detail: "'\(rawHost)' is not a valid host."))
            }
            components.host = "[\(bare)]"
        }

        // The opt-in covers `.remote` and deliberately does not cover `.nonCanonical`. An
        // ambiguous spelling is not a machine the operator can be vouching for: the address
        // they typed and the address content reaches are decided by different parsers. The
        // previous message reported both as "non-loopback" and offered the opt-in for both,
        // so following its advice restored the round-4 octal bypass.
        switch LoopbackPolicy.classify(bare) {
        case .loopback:
            break
        case .remote:
            guard LoopbackPolicy.allowsRemote(environment: environment) else {
                return .failure(
                    .nonLoopbackRefused(host: bare, url: components.url?.absoluteString ?? bare))
            }
        case .nonCanonical:
            return .failure(.ambiguousAddress(host: bare))
        }

        guard let url = components.url else {
            return .failure(.unusableAddress(detail: "'\(rawHost)' is not a valid host."))
        }
        return .success(url)
    }

    /// Whether a string is an IPv6 address literal, optionally carrying a zone id.
    ///
    /// Uses the system resolver rather than a regex: getting this wrong in the lenient
    /// direction is what admitted arbitrary hosts in round 1.
    static func isIPv6Literal(_ candidate: String) -> Bool {
        let address = candidate.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        guard !address.isEmpty else { return false }
        var buffer = in6_addr()
        return address.withCString { inet_pton(AF_INET6, $0, &buffer) == 1 }
    }

    /// `/v1/models` under the resolved base, preserving any path the base already has.
    static func modelsEndpoint(base: URL) -> URL {
        base.appendingPathComponent("v1").appendingPathComponent("models")
    }

    /// The oMLX credential, from `--api-key` then `OMLX_TOKEN`.
    ///
    /// No default. The first version fell back to the literal `"omlx"` and asserted it
    /// over whatever oMLX had configured, which broke every authenticated server.
    static func resolveAuthToken(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AuthToken {
        if let flag = value(of: "--api-key", in: arguments) { return .known(flag) }
        // A whitespace-only token is not a credential; treating it as `.known` would
        // assert garbage at the highest precedence *and* suppress the warning that
        // should have fired for not knowing.
        if let env = environment["OMLX_TOKEN"],
            !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .known(env)
        }
        return .unknown
    }

    /// Value of `flag`, matching oMLX's argparse: **the last occurrence wins**, any
    /// unambiguous prefix counts, and nothing past a `--` delimiter is ours to read.
    ///
    /// The abbreviation handling is not optional politeness. An earlier version
    /// dismissed it in a comment — "the cost of missing one is a preflight against the
    /// wrong port, an error message, not silent misbehavior" — and both halves were
    /// false: oMLX honours `--ho 127.0.0.1` while we did not see it, so a user who
    /// explicitly typed localhost could have the session asserted onto whatever
    /// `OMLX_URL` held, with the preflight happily reaching that remote server.
    static func value(of flag: String, in arguments: [String]) -> String? {
        var found: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }  // everything after belongs to Claude Code

            let (matched, inlineValue) = matchOption(argument)
            if matched == flag {
                if let inlineValue {
                    if !inlineValue.isEmpty { found = inlineValue }
                } else if index + 1 < arguments.count, looksLikeValue(arguments[index + 1]) {
                    found = arguments[index + 1]
                    index += 1
                }
            }
            index += 1
        }
        return found
    }

    /// Resolves one argv token to the oMLX option it names, argparse-style.
    ///
    /// Returns the canonical option and, for `--opt=value` form, the inline value.
    /// An ambiguous prefix resolves to nothing: argparse errors on those, and quietly
    /// picking one of the candidates would be worse than not reading it.
    static func matchOption(_ token: String) -> (option: String?, inlineValue: String?) {
        guard token.hasPrefix("--"), token != "--" else { return (nil, nil) }
        let body = String(token.dropFirst(2))
        let name: String
        let inline: String?
        if let equals = body.firstIndex(of: "=") {
            name = String(body[body.startIndex..<equals])
            inline = String(body[body.index(after: equals)...])
        } else {
            name = body
            inline = nil
        }
        guard !name.isEmpty else { return (nil, nil) }

        let full = "--" + name
        if omlxOptions.contains(full) { return (full, inline) }

        let candidates = omlxOptions.filter { $0.hasPrefix(full) }
        guard candidates.count == 1 else { return (nil, nil) }  // 0 = not ours, >1 = ambiguous
        return (candidates[0], inline)
    }

    /// Whether a token following a flag is that flag's value rather than the next flag.
    ///
    /// Mirrors argparse's rule, negative numbers included: `--port -1` binds `-1` as the
    /// value, which we then refuse on range. Treating it as "no value given" would
    /// silently fall back to the default port.
    private static func looksLikeValue(_ token: String) -> Bool {
        if token.isEmpty { return false }
        if !token.hasPrefix("-") { return true }
        return token.range(of: #"^-\d+(\.\d+)?$"#, options: .regularExpression) != nil
    }
}
