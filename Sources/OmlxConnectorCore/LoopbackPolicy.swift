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
    /// What kind of destination `host` names.
    ///
    /// `remote` and `nonCanonical` are deliberately separate, because they call for opposite
    /// advice and conflating them produced a message that walked users into a defect. Round
    /// 6: `--host 0127.0.0.1` was refused as a *non-loopback host*, and the refusal told the
    /// user to set `OMLX_ALLOW_REMOTE=1`. Doing so let it through — restoring the round-4
    /// octal bypass, with a green preflight against the real local server on the way past.
    public enum Verdict: Equatable {
        /// This machine. Proceed.
        case loopback
        /// Another machine, named unambiguously. `OMLX_ALLOW_REMOTE=1` covers this.
        case remote
        /// A spelling that two parsers read differently. **The opt-in does not cover this**,
        /// and that is the whole point: the opt-in means "this other machine is mine", which
        /// the user cannot be asserting here, because they have not named one machine. The
        /// gate would send content wherever the *next* parser decides.
        case nonCanonical
    }

    public static func classify(_ host: String) -> Verdict {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if normalized.isEmpty { return .remote }
        if normalized == "localhost" { return .loopback }

        // A zone id (`fe80::1%en0`) is not part of the address itself.
        let address = normalized.split(separator: "%", maxSplits: 1).first.map(String.init)
            ?? normalized

        if let v4 = parseCanonicalIPv4(address) { return v4.0 == 127 ? .loopback : .remote }
        if let v6 = parseCanonicalIPv6(address) {
            return isIPv6Loopback(v6) ? .loopback : .remote
        }
        // It parses as an address but not in canonical form — the ambiguous case. Anything
        // that is not an address at all is an ordinary name, and remote.
        if parsesAsAddressInAnyForm(address) { return .nonCanonical }
        return .remote
    }

    /// Whether `host` names this machine. Retained because both entry points and their tests
    /// ask exactly this; `classify` is for callers that must also explain a refusal.
    public static func isLoopback(_ host: String) -> Bool {
        classify(host) == .loopback
    }

    /// Parses under `inet_pton`'s lenient rules, ignoring canonical form.
    ///
    /// Used only to tell "ambiguous address" from "ordinary hostname", so that the two get
    /// different advice. It must never gate anything on its own.
    private static func parsesAsAddressInAnyForm(_ text: String) -> Bool {
        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &v6) } == 1
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

    /// Parses v6, refusing any spelling `inet_pton` would read differently from a
    /// stricter parser.
    ///
    /// The previous version tried to do this by re-parsing `inet_ntop`'s output and
    /// comparing bytes. **That was a tautology** — `inet_pton(inet_ntop(x)) == x` always
    /// holds, verified across eleven spellings — so the guard rejected nothing, v6 had no
    /// canonicalization at all, and deleting the whole block left the suite green. The
    /// octal defect fixed on the v4 path therefore survived through
    /// `::ffff:0127.13.37.42`, which reached `isIPv6Loopback` as bytes 127.13.37.42.
    ///
    /// A text round-trip is the wrong tool here, because `0:0:0:0:0:0:0:1` is a spelling
    /// people write that `inet_ntop` prints as `::1`. So the one thing that actually admits
    /// disagreement is checked directly instead: **an embedded IPv4 literal must itself be
    /// canonical**, since `inet_pton` applies the same leading-zero leniency to a dotted quad
    /// inside `::ffff:a.b.c.d` that it does to a bare one.
    ///
    /// **Hex groups are deliberately not checked, and an earlier version of this comment
    /// wrongly claimed they were.** Unlike a dotted quad, an IPv6 hex group has no second
    /// reading — `0001` is 1 under every parser — so leading zeros there are verbose rather
    /// than ambiguous, and refusing them would repeat the over-strictness that once rejected
    /// `0:0:0:0:0:0:0:1` outright. `LoopbackGateTests` pins that: `::0001` is loopback.
    ///
    /// That false half is worth naming rather than quietly deleting. It is the fourth time a
    /// guarantee has been written here that the code did not provide, and the test standing
    /// in front of it was vacuous — it refused its fixture for the address's *value*, not for
    /// its spelling, and stayed green with this whole mechanism removed.
    private static func parseCanonicalIPv6(_ text: String) -> [UInt8]? {
        var addr = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }

        // `::ffff:a.b.c.d` and `::a.b.c.d` embed a dotted quad, and `inet_pton` applies
        // the same leading-zero leniency there that it does for a bare v4 address.
        if let lastColon = text.lastIndex(of: ":") {
            let tail = String(text[text.index(after: lastColon)...])
            if tail.contains(".") {
                guard parseCanonicalIPv4(tail) != nil else { return nil }
            }
        }

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
