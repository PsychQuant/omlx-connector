import Foundation

/// Works out which address to check before handing over to `omlx launch claude`.
///
/// `--host` and `--port` belong to oMLX, not to Claude Code: `omlx launch` parses
/// them itself and they never reach the `claude` binary. We therefore **read them
/// without consuming them** — they stay in the argument list we forward, and we
/// only need their values so the preflight checks the address the launcher is
/// actually about to use.
///
/// Without this, passing `--port 8001` to a server on 8001 would still make the
/// preflight probe 8000 and report the server as down. The shell wrapper this
/// command replaces had exactly that bug.
enum ProbeTarget {

    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8000

    /// Resolution order, weakest first: built-in default, `OMLX_URL` (carried over
    /// from the shell wrapper so existing setups keep working), then the flags.
    static func resolve(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var host = defaultHost
        var port = defaultPort

        if let raw = environment["OMLX_URL"], let url = URL(string: raw) {
            if let envHost = url.host { host = envHost }
            if let envPort = url.port { port = envPort }
        }

        if let flagHost = value(of: "--host", in: arguments) { host = flagHost }
        if let flagPort = value(of: "--port", in: arguments), let parsed = Int(flagPort) {
            port = parsed
        }

        return "http://\(host):\(port)"
    }

    /// Handles both `--flag value` and `--flag=value`.
    ///
    /// It does **not** handle argparse's prefix abbreviation (`--po 8001`), which
    /// oMLX accepts. Guessing at abbreviations here would risk reading a flag meant
    /// for Claude Code, and the cost of missing one is a preflight against the
    /// wrong port — a clear error message, not silent misbehaviour.
    static func value(of flag: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag, index + 1 < arguments.count {
                let next = arguments[index + 1]
                return next.hasPrefix("-") ? nil : next
            }
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            }
        }
        return nil
    }
}
