import Foundation
import OmlxConnectorCore

enum LauncherIdentity {
    /// Binary / product name. MUST equal the on-disk filename in ~/bin.
    static let name = "omlx-claude"

    static var versionString: String { "\(name) \(AppVersion.current)" }

    static var helpMessage: String {
        """
        \(name) \(AppVersion.current) — run Claude Code itself on a local model

        This is usage 1: the local model *is* the agent, and Claude is not involved.
        For usage 2 — Claude answering you and handing selected work to a local
        model — install the MCP server; see the README.

        USAGE
          \(name)                          Pick a model interactively
          \(name) --model <model-id>       Use a specific model
          \(name) --model <id> -p "..."    Non-interactive, one question
          \(name) --version, -v            Print version
          \(name) --help, -h               Print this message

        Every other argument is forwarded to Claude Code untouched, so --resume,
        --continue, --permission-mode and the rest behave as they always do.

        FLAGS THAT DO NOT REACH CLAUDE CODE
        These belong to oMLX. `omlx launch` parses them itself, so `claude` never
        sees them:

          --model      selects the *oMLX* model to serve, which oMLX then maps onto
                       Claude Code's tiers. This is not `claude --model`.
          --host       oMLX server host      (default: \(ProbeTarget.defaultHost))
          --port       oMLX server port      (default: \(ProbeTarget.defaultPort))
          --api-key    oMLX server API key
          --opus / --sonnet / --haiku        per-tier model overrides
          --cross-session                    see `omlx launch --help`

        oMLX matches flags with argparse, which also accepts unambiguous prefixes —
        so an abbreviation of one of the names above is absorbed too, rather than
        forwarded. Spell Claude Code's flags in full.

        WHAT OMLX ADDS ON ITS OWN
        `--disallowedTools LSP` is injected unless you pass your own
        --disallowedTools. A language server attaching mid-session appends its whole
        schema to the tools array, which re-prefills the conversation on a
        prefix-caching server (jundot/omlx#2349). Pass your own --disallowedTools to
        take that decision back.

        ENVIRONMENT
          OMLX_URL     Base URL used for the pre-launch reachability check
                       (default: http://\(ProbeTarget.defaultHost):\(ProbeTarget.defaultPort)).
                       Its scheme and path are preserved; --host / --port override
                       only the parts they name.
          OMLX_TOKEN   Auth token for the oMLX server. --api-key outranks it. With
                       neither, no credential is asserted and oMLX's own configured
                       key is left in force.
          OMLX_ALLOW_REMOTE
                       Set to exactly 1 to permit a non-loopback server. See below.

        THE LOOPBACK GATE
        A non-loopback --host or OMLX_URL is refused unless OMLX_ALLOW_REMOTE=1. This
        is not caution about the preflight: the address resolved here is written into
        ANTHROPIC_BASE_URL through --settings, which outranks every settings file you
        write, so a remote one takes the entire session and the API token with it. The
        MCP server applies the same rule to the same policy. Set OMLX_ALLOW_REMOTE=1
        only for an oMLX instance on a machine you own.

        One scope beats --settings: managed (MDM / policy) settings. If your Mac is
        managed and policy sets ANTHROPIC_BASE_URL, that wins over everything here. The
        managed files are read separately and any such key is named at launch — but it
        cannot be overridden, so on a managed Mac the address checked above may not be
        the address the session uses.

        ON CLAUDE_CODE_DISABLE_1M_CONTEXT
        This launch sets it, and you should not read that as bounding your context.
        Claude Code honours it only for model ids it recognizes, and an oMLX-served
        id never is — it will tell you so itself at startup. It is therefore NOT a
        fix for jundot/omlx#2716; see issue #6 in this repository.

        WHY THIS EXISTS RATHER THAN `omlx launch claude`
        `omlx launch claude` passes its configuration as environment variables, but
        Claude Code ranks a settings-file `env` block above inherited environment.
        Anyone whose ~/.claude/settings.json sets ANTHROPIC_BASE_URL — common with
        gateway or rate-limiting plugins — has the launcher's value silently
        overridden, and the failure reads as `401 Invalid bearer token` while the
        oMLX log shows nothing arrived (jundot/omlx#2715). This command re-asserts
        those keys through --settings, a CLI argument, which outranks user, project and
        local settings and applies to this launch only. Your own config is never
        modified. Managed/policy settings still outrank it; see above.
        """
    }
}
