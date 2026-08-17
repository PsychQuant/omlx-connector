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
    /// ## Two spelling defects, and why the second one is instructive
    ///
    /// The first version ended in `normalized.hasPrefix("127.")` — a **text** test. RFC
    /// 1123 permits a DNS label to begin with a digit, so `127.evil.example` is an
    /// ordinary registrable hostname that satisfied it, demonstrated passing on both
    /// binaries. Its tests could not have caught that: every near-miss fixture broke on
    /// the character right after `127` (`127x.`, `1270.`), so none put a legitimate dot
    /// there.
    ///
    /// The replacement parsed with `inet_pton` — and the doc comment here then claimed
    /// that "address parsing removes the whole class". **It did not.** BSD's `inet_pton`
    /// reads a leading-zero field as decimal while the resolver and Claude Code's URL
    /// parser read it as octal, so `0127.13.37.42` passed as 127.13.37.42 and everything
    /// downstream sent content to 87.13.37.42. One spelling-sensitive parser had been
    /// swapped for another, and the sentence asserting otherwise is what made the second
    /// defect harder to see than the first.
    ///
    /// What holds is narrower and checkable: the host must **already be canonical**. Any
    /// spelling two parsers could read differently fails the round-trip, so the gate never
    /// has to predict which parser runs later. That is a property, not a list of examples.
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

        if let v4 = parseCanonicalIPv4(address) { return v4.0 == 127 }
        if let v6 = parseCanonicalIPv6(address) { return isIPv6Loopback(v6) }
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

    /// Parses only if `text` is already the address's canonical spelling.
    ///
    /// The round-trip is the whole point. `inet_pton` on BSD reads a leading-zero field
    /// as decimal, while the system resolver and Claude Code's WHATWG URL parser read it
    /// as octal — so `0127.13.37.42` was accepted here as 127.13.37.42 and resolved by
    /// everything downstream to 87.13.37.42, routable space. Since only the first octet
    /// was inspected, that made all of 87.0.0.0/8 reachable, and the preflight (URLSession,
    /// which happens to agree with `inet_pton`) reported success against the real local
    /// server on the way past.
    ///
    /// Demanding canonical form removes the disagreement rather than trying to predict
    /// it: any spelling two parsers could read differently is not canonical, so it is
    /// refused here without needing to know which parser runs later.
    private static func parseCanonicalIPv4(_ text: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        var addr = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard let printed = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)),
            String(cString: printed) == text
        else { return nil }

        let raw = addr.s_addr.bigEndian
        return (
            UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)
        )
    }

    /// As above, for v6, but comparing bytes rather than text.
    ///
    /// `0:0:0:0:0:0:0:1` and the fully zero-padded form are spellings people write and
    /// every parser agrees on, so a strict text round-trip would refuse an address that
    /// really is this machine — the exact over-strictness the previous version had when it
    /// matched `::1` by string equality. Re-parsing `inet_ntop`'s output and comparing the
    /// resulting bytes accepts those while still refusing anything that does not survive
    /// two passes through `inet_pton`.
    private static func parseCanonicalIPv6(_ text: String) -> [UInt8]? {
        var addr = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard let printed = inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
        else { return nil }
        let canonical = String(cString: printed)

        // `0:0:0:0:0:0:0:1` and the fully padded form are both spellings people write and
        // that every parser agrees on, so they are accepted even though `inet_ntop` would
        // print `::1`. What must be refused is a form no correct parser produces — hence
        // re-parsing the canonical output and comparing the *bytes*, not the text, while
        // still rejecting anything that fails to round-trip through inet_pton twice.
        var reparsed = in6_addr()
        guard canonical.withCString({ inet_pton(AF_INET6, $0, &reparsed) }) == 1,
            withUnsafeBytes(of: &addr, { Array($0) })
                == withUnsafeBytes(of: &reparsed, { Array($0) })
        else { return nil }

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
