import Foundation

#if canImport(Darwin)
    import Darwin
#endif

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

    /// Whether `host` names this machine.
    ///
    /// ## This asks the resolver, not the spelling
    ///
    /// The previous implementation ended in `normalized.hasPrefix("127.")`, which is a
    /// **text** test. RFC 1123 permits a DNS label to begin with a digit, so
    /// `127.evil.example` and `127.0.0.1.attacker.example` are ordinary registrable
    /// hostnames that satisfied it — and reviewers demonstrated both passing the gate on
    /// both shipped binaries, with only DNS non-resolution standing between the session
    /// and an attacker-controlled endpoint.
    ///
    /// The tests shipped with that version could not have caught it: every "near miss"
    /// fixture broke on the character immediately after `127` (`127x.`, `1270.`), so not
    /// one of them put a legitimate dot there. Address parsing removes the whole class
    /// rather than the examples anyone happened to think of.
    ///
    /// **DNS is deliberately not consulted.** Resolving the name would make the answer
    /// depend on a lookup that can differ between this check and the connection that
    /// follows — a TOCTOU the gate cannot win. A name is not this machine unless it is
    /// the literal `localhost`.
    public static func isLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if normalized.isEmpty { return false }
        if normalized == "localhost" { return true }

        // A zone id (`fe80::1%en0`) is not part of the address itself.
        let address = normalized.split(separator: "%", maxSplits: 1).first.map(String.init)
            ?? normalized

        if let v4 = parseIPv4(address) { return v4.0 == 127 }
        if let v6 = parseIPv6(address) { return isIPv6Loopback(v6) }
        return false
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

    // MARK: - Address parsing

    private static func parseIPv4(_ text: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        var addr = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        let raw = addr.s_addr.bigEndian
        return (
            UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)
        )
    }

    private static func parseIPv6(_ text: String) -> [UInt8]? {
        var addr = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    /// `::1`, in any spelling, or an IPv4-mapped address inside 127/8.
    ///
    /// Spelling matters here in the other direction too: matching `::1` by string
    /// equality refused `0:0:0:0:0:0:0:1` and the fully expanded form, sending users to
    /// `OMLX_ALLOW_REMOTE` for an address that is this machine.
    private static func isIPv6Loopback(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        // ::ffff:a.b.c.d — an IPv4 address wearing an IPv6 spelling; it reaches whatever
        // a.b.c.d reaches, so it is loopback exactly when that is.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return bytes[12] == 127
        }
        return false
    }
}
