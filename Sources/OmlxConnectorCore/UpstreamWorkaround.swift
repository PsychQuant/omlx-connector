import Foundation

/// A version of oMLX, ordered the way oMLX numbers its own releases.
///
/// Not semver: `omlx --version` prints things like `0.6.0rc1`, where the
/// pre-release suffix is glued straight onto the last number with no separator.
public struct OmlxVersion: Sendable, Equatable {
    /// Numeric components, left to right. Missing trailing components are zero,
    /// so `0.6` and `0.6.0` are the same version.
    let components: [Int]

    /// Pre-release ordinal, if the string carried one (`rc1` -> 1). A version with
    /// a pre-release sorts *before* the same version without one: `0.6.0rc1` is
    /// what led up to `0.6.0`.
    let preRelease: Int?

    /// Parses a version string, returning nil for anything unrecognizable.
    ///
    /// Nil is a real answer here, not an error. Every caller treats an unreadable
    /// version as "say nothing" — see `UpstreamWorkaround.stalenessNotice`.
    public static func parse(_ raw: String) -> OmlxVersion? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("v") { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        // Split off a trailing alphabetic pre-release tag and its number, e.g. the
        // "rc1" of "0.6.0rc1". Anything before it must be dotted digits.
        var numericPart = text
        var preRelease: Int?
        if let tagStart = text.firstIndex(where: { $0.isLetter }) {
            numericPart = String(text[text.startIndex..<tagStart])
            let tag = text[tagStart...]
            let digits = tag.drop { $0.isLetter }
            guard !digits.isEmpty, let ordinal = Int(digits) else { return nil }
            preRelease = ordinal
        }

        let fields = numericPart.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty else { return nil }
        var components: [Int] = []
        for field in fields {
            guard let value = Int(field) else { return nil }
            components.append(value)
        }
        return OmlxVersion(components: components, preRelease: preRelease)
    }

    /// Orders two version strings. Unparseable input compares `.orderedSame`, so a
    /// caller that only asks "is the installed one newer?" stays quiet on garbage.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let a = parse(lhs), let b = parse(rhs) else { return .orderedSame }
        return a.compare(to: b)
    }

    func compare(to other: OmlxVersion) -> ComparisonResult {
        // Compare numerically, not as text: "0.10.0" is newer than "0.9.0" even
        // though it sorts earlier as a string. Getting this backwards would go
        // silent for exactly the releases most likely to carry the upstream fix.
        let width = max(components.count, other.components.count)
        for index in 0..<width {
            let mine = index < components.count ? components[index] : 0
            let theirs = index < other.components.count ? other.components[index] : 0
            if mine != theirs { return mine < theirs ? .orderedAscending : .orderedDescending }
        }
        switch (preRelease, other.preRelease) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending   // release is newer than its rc
        case (_, nil): return .orderedAscending
        case let (mine?, theirs?):
            if mine == theirs { return .orderedSame }
            return mine < theirs ? .orderedAscending : .orderedDescending
        }
    }
}

/// Why `omlx-claude` exists on top of `omlx launch claude`, and how it announces
/// that the ground may have moved.
///
/// One upstream bug is actually worked around here, and a second is only tracked:
///
/// - [jundot/omlx#2715](https://github.com/jundot/omlx/issues/2715) — **worked
///   around.** The launcher passes `ANTHROPIC_BASE_URL` and friends as environment
///   variables (`integrations/claude.py`, `os.execvpe`), but a settings-file `env`
///   block outranks inherited environment in Claude Code. Anyone whose settings set
///   those keys silently talks to the wrong endpoint. `--settings` outranks both, so
///   re-asserting there wins.
/// - [jundot/omlx#2716](https://github.com/jundot/omlx/issues/2716) — **not fixed
///   here.** An auto-upgraded 1M context window puts a `[1m]` suffix on the model id,
///   after which `CLAUDE_CODE_MAX_CONTEXT_TOKENS` stops applying. This command sets
///   `CLAUDE_CODE_DISABLE_1M_CONTEXT`, which is correct for model ids Claude Code
///   recognizes — and oMLX-served ids never are, so it does not bound those sessions.
///   Claude Code says so itself at launch. Tracked in issue #6; do not describe the
///   key as the fix.
///
/// This command is **not** deleted when those are fixed: it also carries
/// distribution, a preflight that names the fix when no server answers, and a
/// wider settings override than the launcher's four keys. But it should not
/// quietly keep asserting a workaround against a version nobody checked.
///
/// The check deliberately runs backwards from the obvious design. "Has upstream
/// fixed it yet?" would need a fixed-in version constant, and that number does not
/// exist while the bugs are open — someone would have to come back and fill it in,
/// which is the act of remembering this mechanism exists to remove. Recording the
/// version we *did* verify needs no knowledge of the future: it speaks up as soon
/// as the ground moves.
public enum UpstreamWorkaround {

    /// The oMLX release this workaround was last read against, source and all.
    ///
    /// Verified 2026-08-17 against
    /// `/Applications/oMLX.app/Contents/Resources/omlx/integrations/claude.py`
    /// (env assignment at lines 95-159) and `cli.py` (`parse_known_args`, line
    /// 1418). Bump this only after re-reading those, not merely after testing that
    /// a launch still works.
    public static let lastVerifiedOmlxVersion = "0.6.0rc1"

    /// What the launcher should say about the installed oMLX, if anything.
    public enum Staleness: Equatable {
        /// Same as, or older than, the version this was verified against.
        case quiet
        /// Newer — the ground may have moved under the workaround.
        case newerThanVerified(String)
        /// The version could not be read at all. Not the same as "nothing to say":
        /// an unreadable string most likely means the output format changed, which is
        /// itself a reason to go and re-read the integration.
        case unreadable(String)
    }

    /// The recorded decision was that this command keeps existing after upstream lands
    /// its fixes, but must **announce that itself** rather than rely on anyone
    /// remembering. Returning silence for an unparseable version broke that promise at
    /// the one moment it mattered: if `omlx --version` ever prints `omlx 0.7.0` instead
    /// of `0.7.0`, the mechanism would have disabled itself exactly when upstream had
    /// changed something.
    public static func staleness(installedOmlxVersion: String?) -> Staleness {
        guard let raw = installedOmlxVersion, !raw.isEmpty else {
            return .unreadable(
                """
                could not read the installed oMLX version, so this launcher cannot tell \
                whether its settings override is still current. It was last verified \
                against \(lastVerifiedOmlxVersion); re-read integrations/claude.py if \
                anything looks wrong.
                """)
        }
        guard let installed = OmlxVersion.parse(raw) else {
            return .unreadable(
                """
                oMLX reports its version as '\(raw)', which this launcher cannot parse. \
                That usually means the output format changed — which is itself a reason \
                to re-read integrations/claude.py. Last verified against \
                \(lastVerifiedOmlxVersion).
                """)
        }
        guard let verified = OmlxVersion.parse(lastVerifiedOmlxVersion),
            installed.compare(to: verified) == .orderedDescending
        else { return .quiet }
        return .newerThanVerified(notice(installed: raw))
    }

    /// Kept for callers that only want the newer-than case.
    public static func stalenessNotice(installedOmlxVersion: String) -> String? {
        guard case .newerThanVerified(let text) = staleness(installedOmlxVersion: installedOmlxVersion)
        else { return nil }
        return text
    }

    private static func notice(installed installedOmlxVersion: String) -> String {
        """
            note: oMLX \(installedOmlxVersion) is newer than \
            \(lastVerifiedOmlxVersion), which is what this launcher's settings \
            override was last checked against. If jundot/omlx#2715 and #2716 are \
            fixed in your version, the override is redundant — `omlx launch claude` \
            may now be enough on its own.
            """
    }
}
