import Foundation

/// Builds the `--settings` payload handed to Claude Code, and reports the keys we
/// cannot safely re-assert.
///
/// ## Why a settings file at all
///
/// `omlx launch claude` sets its configuration as **environment variables** and
/// then `os.execvpe`s Claude Code (`integrations/claude.py:95-159`). Claude Code
/// ranks a settings-file `env` block above inherited environment, so a user whose
/// `~/.claude/settings.json` sets any of those keys silently overrides the
/// launcher — jundot/omlx#2715. `--settings` is a CLI argument, which outranks
/// user settings, so re-asserting a key there wins the fight for that key.
///
/// ## Why not simply re-assert all of them
///
/// Twelve-odd variables are set by the launcher, but half of their *values* are
/// computed by oMLX from state we deliberately do not replicate: the chosen model
/// (`ANTHROPIC_DEFAULT_*_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`), that model's
/// advertised window (`CLAUDE_CODE_MAX_CONTEXT_TOKENS`,
/// `CLAUDE_CODE_AUTO_COMPACT_WINDOW`), and the configured API key
/// (`ANTHROPIC_AUTH_TOKEN`, when it is not the open-server default).
///
/// Reproducing those would mean reimplementing oMLX's model selection here, and
/// that knowledge moves — it is the reason this launcher execs `omlx launch
/// claude` instead of talking to Claude Code directly. So the split is:
///
/// - **Override** what we can determine independently and correctly.
/// - **Detect and report** the rest, when the user's own settings would shadow it.
///
/// Silence on a key we cannot control is worse than a warning about it.
enum LaunchSettings {

    /// Keys we re-assert, with values we can compute without knowing which model
    /// oMLX will end up serving.
    ///
    /// Mirrors `integrations/claude.py` as of oMLX 0.6.0rc1 — see
    /// `UpstreamWorkaround.lastVerifiedOmlxVersion`, which is what tells you when
    /// this list is worth re-reading.
    static func overrides(baseURL: String, authToken: String) -> [String: String] {
        [
            // The three the launcher sets and settings.json most often shadows.
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_AUTH_TOKEN": authToken,
            "ANTHROPIC_API_KEY": "",

            // Fixed by the launcher regardless of model. Each is a real hazard if
            // a user's settings shadow it: a normal API_TIMEOUT_MS aborts local
            // inference mid-generation, since a cold model load alone can outlast
            // it.
            "API_TIMEOUT_MS": "3000000",
            "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",

            // Ours, not the launcher's: on plans where Opus is auto-upgraded to a
            // 1M window the model id gains a `[1m]` suffix, after which Claude Code
            // assumes a 1M window and CLAUDE_CODE_MAX_CONTEXT_TOKENS stops
            // applying — jundot/omlx#2716.
            "CLAUDE_CODE_DISABLE_1M_CONTEXT": "1",
        ]
    }

    /// Keys the launcher sets whose values depend on oMLX's model selection, which
    /// we do not replicate. If the user's own settings define one of these, oMLX
    /// loses and we cannot win it back on their behalf.
    static let modelDependentKeys = [
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL",
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
    ]

    /// Model-dependent keys present in the user's settings `env` block, sorted.
    ///
    /// These are reported, not fixed. Naming them is the whole value: the failure
    /// they cause otherwise — a context window that disagrees with the server, a
    /// tier pointing at a model that is not loaded — surfaces far from its cause.
    static func unwinnableConflicts(userSettings: [String: Any]) -> [String] {
        guard let env = userSettings["env"] as? [String: Any] else { return [] }
        return modelDependentKeys.filter { env[$0] != nil }.sorted()
    }

    /// The `--settings` JSON value. Claude Code accepts a literal JSON string here,
    /// so nothing is written to disk and the user's own config is never touched.
    static func settingsJSON(baseURL: String, authToken: String) throws -> String {
        let payload = ["env": overrides(baseURL: baseURL, authToken: authToken)]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw LaunchError.settingsEncodingFailed
        }
        return text
    }

    /// Reads the user's settings file, returning an empty dictionary when it is
    /// absent or unreadable.
    ///
    /// A malformed settings file is the user's problem to fix and Claude Code will
    /// say so itself; refusing to launch over it here would just be a second, less
    /// informative complaint.
    static func loadUserSettings(
        at path: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
    ) -> [String: Any] {
        guard let data = try? Data(contentsOf: path),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return parsed
    }
}

enum LaunchError: LocalizedError {
    case settingsEncodingFailed
    case serverUnreachable(url: String)
    case omlxNotInstalled

    var errorDescription: String? {
        switch self {
        case .settingsEncodingFailed:
            return "could not encode the settings payload"
        case .serverUnreachable(let url):
            return """
                No oMLX server responding at \(url)
                Start it with: open -a oMLX   (or: omlx start)
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
