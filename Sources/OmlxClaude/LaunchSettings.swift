import Foundation

/// Builds the `--settings` payload handed to Claude Code, and reports the keys we
/// cannot safely re-assert.
///
/// ## Why a settings file at all
///
/// `omlx launch claude` sets its configuration as **environment variables** and then
/// `os.execvpe`s Claude Code (`integrations/claude.py:95-159`). Claude Code ranks a
/// settings-file `env` block above inherited environment, so a user whose
/// `~/.claude/settings.json` sets any of those keys silently overrides the launcher —
/// jundot/omlx#2715. `--settings` is a CLI argument, which outranks settings files, so
/// re-asserting a key there wins the fight for that key.
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

enum LaunchError: LocalizedError {
    case settingsEncodingFailed
    case unusableAddress(detail: String)
    case serverUnreachable(url: String)
    case serverRequiresAuth(url: String)
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
        case .omlxNotInstalled:
            return """
                oMLX is not installed, or `omlx` is not on PATH.
                Install it from https://github.com/jundot/omlx — this command is a
                thin layer over `omlx launch claude` and cannot run without it.
                """
        }
    }
}
