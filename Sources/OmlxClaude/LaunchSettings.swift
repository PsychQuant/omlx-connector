import Foundation
import OmlxConnectorCore

/// Builds the `--settings` payload handed to Claude Code, and reports the keys we
/// cannot safely re-assert.
///
/// ## Why a settings file at all
///
/// `omlx launch claude` sets its configuration as **environment variables** and then
/// `os.execvpe`s Claude Code (`integrations/claude.py:95-159`). Claude Code ranks a
/// settings-file `env` block above inherited environment, so a user whose
/// `~/.claude/settings.json` sets any of those keys silently overrides the launcher —
/// jundot/omlx#2715. `--settings` is a CLI argument, which outranks the user, project
/// and local settings files, so re-asserting a key there wins the fight for that key.
///
/// **It does not outrank everything.** Claude Code's documented precedence puts managed
/// (MDM / policy) settings above command-line arguments. On a managed Mac whose policy
/// sets `env.ANTHROPIC_BASE_URL`, our value loses — #2715 is not worked around, and the
/// loopback gate will have verified an address the session does not use. That population
/// is not hypothetical: #2715's own trigger is "any gateway, proxy, or rate-limiting
/// plugin", which is the fleet-managed setup most likely to also carry policy settings.
/// So the managed paths are scanned and a conflict there is *named* — the one scope we
/// genuinely cannot win is the one where silence is least acceptable.
///
/// ## Why not simply re-assert all of them
///
/// Twelve-odd variables are set by the launcher, but half of their *values* are
/// computed by oMLX from state we deliberately do not replicate: the chosen model
/// (`ANTHROPIC_DEFAULT_*_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`), that model's
/// advertised window (`CLAUDE_CODE_MAX_CONTEXT_TOKENS`,
/// `CLAUDE_CODE_AUTO_COMPACT_WINDOW`), and — unless the operator hands it to us — the
/// configured API key.
///
/// Reproducing those would mean reimplementing oMLX's model selection here, and that
/// knowledge moves; it is the reason this launcher execs `omlx launch claude` instead
/// of talking to Claude Code directly. So the split is:
///
/// - **Override** what we can determine independently and correctly.
/// - **Detect and report** the rest, when the user's own settings would shadow it.
///
/// Silence on a key we cannot control is worse than a warning about it.
enum LaunchSettings {

    /// Keys we re-assert, with values we can compute without knowing which model oMLX
    /// will end up serving.
    ///
    /// Mirrors `integrations/claude.py` as of oMLX 0.6.0rc1 — see
    /// `UpstreamWorkaround.lastVerifiedOmlxVersion`, which is what tells you when this
    /// list is worth re-reading.
    static func overrides(baseURL: String, authToken: ProbeTarget.AuthToken)
        -> [String: String]
    {
        var env = [
            // The ones the launcher sets and settings.json most often shadows.
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_API_KEY": "",

            // Fixed by the launcher regardless of model. Each is a real hazard if a
            // user's settings shadow it: a normal API_TIMEOUT_MS aborts local
            // inference mid-generation, since a cold model load alone can outlast it.
            "API_TIMEOUT_MS": "3000000",
            "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",

            // Ours, not the launcher's. Correct for model IDs Claude Code recognizes;
            // inert for the ones oMLX serves, which are never recognized — so it does
            // NOT bound an oMLX session, and nothing here should be read as fixing
            // jundot/omlx#2716. Kept because it costs nothing and is right if a model
            // ever is recognized. Tracked in issue #6.
            "CLAUDE_CODE_DISABLE_1M_CONTEXT": "1",
        ]

        // Only assert the credential when the operator gave us one. oMLX otherwise
        // computes it from its own configuration, and a guess here replaces a working
        // credential with a broken one on every authenticated server.
        if case .known(let token) = authToken {
            env["ANTHROPIC_AUTH_TOKEN"] = token
        }

        return env
    }

    /// Keys the launcher sets whose values depend on oMLX's model selection, which we
    /// do not replicate. If the user's own settings define one of these, oMLX loses
    /// and we cannot win it back on their behalf.
    static let modelDependentKeys = [
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL",
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
    ]

    /// Every key we decline to assert for this launch — the model-dependent set, plus
    /// the credential when the operator did not supply one.
    static func reportableKeys(authToken: ProbeTarget.AuthToken) -> [String] {
        var keys = modelDependentKeys
        if authToken == .unknown { keys.append("ANTHROPIC_AUTH_TOKEN") }
        return keys
    }

    /// Reportable keys present in the user's settings, sorted.
    ///
    /// These are named, not fixed. Naming them is the whole value: the failures they
    /// cause otherwise — a context window that disagrees with the server, a tier
    /// pointing at a model that is not loaded, a 401 from an authenticated server —
    /// surface far from their cause.
    static func unwinnableConflicts(
        userSettings: [String: Any], authToken: ProbeTarget.AuthToken
    ) -> [String] {
        guard let env = userSettings["env"] as? [String: Any] else { return [] }
        return reportableKeys(authToken: authToken).filter { env[$0] != nil }.sorted()
    }

    /// The `--settings` JSON value. Claude Code accepts a literal JSON string here, so
    /// nothing is written to disk and the user's own config is never touched.
    static func settingsJSON(baseURL: String, authToken: ProbeTarget.AuthToken) throws
        -> String
    {
        let payload = ["env": overrides(baseURL: baseURL, authToken: authToken)]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw LaunchError.settingsEncodingFailed
        }
        return text
    }

    /// Every settings file that can shadow inherited environment, weakest first.
    ///
    /// Checking only the global file left the promise half-kept: project and local
    /// settings shadow the launcher's environment exactly as the global one does, so a
    /// conflict defined there produced no warning at all.
    /// Scopes that `--settings` **beats**, ordered weakest to strongest. These can be
    /// merged into one dictionary because the verdict for every key in them is the same:
    /// we win it.
    static func settingsScopePaths(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> [URL] {
        [
            home.appendingPathComponent(".claude/settings.json"),
            workingDirectory.appendingPathComponent(".claude/settings.json"),
            workingDirectory.appendingPathComponent(".claude/settings.local.json"),
        ]
    }

    /// The scope that beats `--settings`, kept **separate on purpose**.
    ///
    /// An earlier version appended these to the mergeable list, which made the promise
    /// they were added for impossible to keep: once merged, a key cannot be attributed, so
    /// `unwinnableConflicts` could not tell a user-scope `ANTHROPIC_BASE_URL` (which we
    /// override successfully) from a managed one (which overrides us). Adding the key to
    /// `reportableKeys` would then have warned every ordinary user about something that
    /// works fine.
    static func managedScopePaths() -> [URL] {
        [
            URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"),
            URL(fileURLWithPath: "/etc/claude-code/managed-settings.json"),
        ]
    }

    /// Keys a managed policy sets that we cannot override — **including the ones we
    /// normally win**, which is the whole point of reading this scope separately.
    ///
    /// `ANTHROPIC_BASE_URL` is the one that matters. Four places (this file, README,
    /// CLAUDE.md, and the shipped `--help`) claimed this warning existed while it did not,
    /// and CLAUDE.md spelled out the consequence: on a managed Mac the loopback gate
    /// verifies an address the session does not use. The gate says 127.0.0.1, the session
    /// leaves for the policy endpoint, and the bearer token goes with it.
    static func managedConflicts(managedSettings: [String: Any]) -> [String] {
        guard let env = managedSettings["env"] as? [String: Any] else { return [] }
        let keysWeWouldOtherwiseWin = ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY",
                                       "API_TIMEOUT_MS", "CLAUDE_CODE_DISABLE_1M_CONTEXT"]
        return (keysWeWouldOtherwiseWin + reportableKeys(authToken: .unknown))
            .filter { env[$0] != nil }.sorted()
    }

    /// Whether a managed `ANTHROPIC_BASE_URL` permits launching at all.
    ///
    /// Naming an unwinnable conflict is the right response for most keys. For this one it is
    /// not sufficient, and round 6 said so: the warning fired and the launch proceeded, so
    /// the gate verified 127.0.0.1 while the session left for the policy endpoint with the
    /// bearer token. A warning about the invariant is not the invariant.
    ///
    /// Managed settings cannot be overridden. They can be declined: this command exists so
    /// that content stays on the machine, and launching into a policy that sends it elsewhere
    /// would be doing the opposite while printing a notice about it.
    ///
    /// The address is judged by the same `LoopbackPolicy` the launcher applies to its own
    /// inputs — including the ambiguous case, for the same reason.
    enum ManagedBaseURLVerdict: Equatable {
        case proceed
        case refuse(host: String)
    }

    static func managedBaseURLVerdict(managedSettings: [String: Any]) -> ManagedBaseURLVerdict {
        guard let env = managedSettings["env"] as? [String: Any],
            let raw = env["ANTHROPIC_BASE_URL"] as? String,
            let host = URLComponents(string: raw)?.host
        else { return .proceed }

        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return LoopbackPolicy.classify(bare) == .loopback ? .proceed : .refuse(host: bare)
    }

    /// Reads the managed scope alone, without merging it into anything.
    ///
    /// A missing or unreadable file is not an error: these paths are root-owned and absent
    /// on an unmanaged Mac, which is the common case.
    static func loadManagedSettings(paths: [URL] = managedScopePaths()) -> [String: Any] {
        for path in paths {
            guard let data = try? Data(contentsOf: path),
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return parsed
        }
        return [:]
    }

    /// Merged `env` blocks from every scope, later scopes winning.
    ///
    /// A malformed or missing settings file is skipped rather than fatal: Claude Code
    /// will complain about it itself, and refusing to launch here would just be a
    /// second, less informative complaint.
    static func loadUserSettings(paths: [URL] = settingsScopePaths()) -> [String: Any] {
        var mergedEnv: [String: Any] = [:]
        for path in paths {
            guard let data = try? Data(contentsOf: path),
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let env = parsed["env"] as? [String: Any]
            else { continue }
            mergedEnv.merge(env) { _, newer in newer }
        }
        return mergedEnv.isEmpty ? [:] : ["env": mergedEnv]
    }
}

enum LaunchError: LocalizedError, Equatable {
    case settingsEncodingFailed
    case unusableAddress(detail: String)
    case nonLoopbackRefused(host: String, url: String)
    case ambiguousAddress(host: String)
    case managedBaseURLRefused(host: String)
    case serverUnreachable(url: String)
    case serverRequiresAuth(url: String)
    case credentialRejected(url: String)
    case omlxNotInstalled

    var errorDescription: String? {
        switch self {
        case .settingsEncodingFailed:
            return "could not encode the settings payload"
        case .unusableAddress(let detail):
            return """
                \(detail)
                --host must be a host name or IP (an IPv6 literal may be given bare or
                bracketed); --port must be 1-65535.
                """
        case .nonLoopbackRefused(let host, let url):
            return """
                Refusing to run a session against non-loopback host '\(host)' (\(url)).
                This command exists so that content stays on this machine, and the
                address resolved here is asserted into ANTHROPIC_BASE_URL above every
                settings file you write — so the whole session, and the API token, would
                go there.
                If '\(host)' is a machine you own and you intend that, set
                OMLX_ALLOW_REMOTE=1.
                """
        case .ambiguousAddress(let host):
            // Deliberately does NOT mention OMLX_ALLOW_REMOTE. The old message did, for this
            // case as well as for genuinely remote hosts, and following that advice restored
            // the octal bypass this check exists to close.
            return """
                Refusing '\(host)': it is an IP address written in a form that different
                parsers read differently. This one reads it as one address; the system
                resolver and Claude Code's URL parser may read it as another, so content
                would leave for a machine you did not name — and the preflight would report
                success against the machine you meant.
                Write the address in its canonical form (for example 127.0.0.1, not
                0127.0.0.1). OMLX_ALLOW_REMOTE does not apply here: it means "this other
                machine is mine", which cannot be asserted about an address that names two.
                """
        case .managedBaseURLRefused(let host):
            return """
                Refusing to launch: managed (MDM/policy) settings on this Mac set
                ANTHROPIC_BASE_URL to '\(host)', which is not this machine.
                Managed settings outrank the --settings this command passes, so the session
                would go there — with everything you type and the API token — no matter what
                address was checked a moment ago. This command exists to prevent exactly that,
                so it declines rather than launching and warning.
                Ask whoever manages this Mac to remove that key, or use plain `claude` if you
                intend to talk to the managed endpoint.
                """
        case .serverUnreachable(let url):
            return """
                No oMLX server responding at \(url)
                Start it with: open -a oMLX   (or: omlx start)
                """
        case .serverRequiresAuth(let url):
            return """
                The oMLX server at \(url) refused the request (401).
                It expects an API key. Pass it with --api-key <key>, or set OMLX_TOKEN.
                """
        case .credentialRejected(let url):
            return """
                The oMLX server at \(url) rejected the API key you provided (401).
                Check the value passed to --api-key, or OMLX_TOKEN if that is where it
                came from.
                """
        case .omlxNotInstalled:
            return """
                oMLX is not installed, or `omlx` is not on PATH.
                Install it from https://github.com/jundot/omlx — this command is a
                thin layer over `omlx launch claude` and cannot run without it.
                """
        }
    }
}
