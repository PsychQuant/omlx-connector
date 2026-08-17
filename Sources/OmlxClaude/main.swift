import Foundation
import OmlxConnectorCore

#if canImport(Darwin)
    import Darwin
#endif

/// `omlx-claude` — run Claude Code itself on a local model served by oMLX.
///
/// This is a thin layer over `omlx launch claude`, not a replacement for it. oMLX's
/// integration carries knowledge that keeps moving — tier mapping, the auto-compact
/// denominator, the LSP prefix-cache footgun, the telemetry trade-off — so the last
/// thing this does is `exec` into it rather than talk to Claude Code directly.
///
/// What it adds: a settings override that survives the user's own settings.json
/// (jundot/omlx#2715), a preflight against the address the launcher will actually
/// use, and a notice when oMLX has moved past the version this was checked against.

let forwarded = Array(CommandLine.arguments.dropFirst())

if forwarded.contains("--version") || forwarded.contains("-v") {
    print(LauncherIdentity.versionString)
    exit(0)
}

if forwarded.contains("--help") || forwarded.contains("-h") {
    print(LauncherIdentity.helpMessage)
    exit(0)
}

func fail(_ error: Error) -> Never {
    let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    FileHandle.standardError.write(Data("\(LauncherIdentity.name): \(text)\n".utf8))
    exit(1)
}

func note(_ text: String) {
    FileHandle.standardError.write(Data("\(text)\n".utf8))
}

/// Runs a command and returns its trimmed stdout, or nil if it could not be run.
func capture(_ launchPath: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [launchPath] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// Whether `omlx` is on PATH at all is the real precondition; what version it reports
// is not. An earlier cut treated a failed `omlx --version` as "oMLX is not installed"
// and aborted — so a slow or broken version subcommand blocked a launch that would
// have worked, and blamed the wrong thing. `execvp` below is the honest test of
// existence; this is only the staleness input.
let omlxVersion = capture("omlx", ["--version"])

// Say so when the launcher's assumptions were checked against an older oMLX. This is
// the whole exit-condition mechanism: it needs no knowledge of when upstream lands a
// fix, only of what we last verified.
//
// Silence is the one thing this may not do, which is why an unreadable version is
// reported rather than swallowed: an unparseable string most likely means the output
// format changed, and that is exactly when the integration is worth re-reading.
switch UpstreamWorkaround.staleness(installedOmlxVersion: omlxVersion) {
case .quiet:
    break
case .newerThanVerified(let notice), .unreadable(let notice):
    note("\(LauncherIdentity.name): \(notice)")
}

// Every input here is user-supplied, so an unusable one is reported, never trapped
// on. `--host ::1` used to reach a force-unwrap and take the process down with
// SIGTRAP and no message at all.
// The loopback policy is applied here, by the same rule the MCP server uses. It is not
// advisory: the address resolved below is asserted into ANTHROPIC_BASE_URL at a higher
// precedence than the environment oMLX sets, so a remote one takes the entire session
// with it.
let baseURL: URL
switch ProbeTarget.resolveChecked(arguments: forwarded) {
case .success(let url): baseURL = url
case .failure(let error): fail(error)
}
let probeURL = baseURL.absoluteString
let authToken = ProbeTarget.resolveAuthToken(arguments: forwarded)

// Preflight. Claude Code's own failure when the server is absent is a wall of
// retries; this is one line that names the fix.
var request = URLRequest(url: ProbeTarget.modelsEndpoint(base: baseURL))
request.timeoutInterval = 5
// Carry the credential the launch itself will use, or an authenticated server
// answers 401 here and `--api-key` can never reach `omlx launch` at all.
if case .known(let token) = authToken {
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
}
do {
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        fail(LaunchError.serverUnreachable(url: probeURL))
    }
    switch http.statusCode {
    case 200..<300:
        break
    case 401, 403:
        // The server is up. What happens next depends on whether we were the ones
        // holding a credential.
        if case .known = authToken {
            // We sent a key and it was rejected — that is a real, terminal error, and
            // the message must say the key was refused rather than that one is needed.
            fail(LaunchError.credentialRejected(url: probeURL))
        }
        // We had no key, so this 401 says nothing about whether the launch will work:
        // oMLX reads its own configuration and may well have one. Aborting here turned
        // a working setup into a hard failure — a regression against plain
        // `omlx launch claude`, which succeeds in exactly this case.
        note(
            """
            \(LauncherIdentity.name): the oMLX server at \(probeURL) requires a key and \
            this launcher has none (no --api-key, no OMLX_TOKEN), so the preflight could \
            not confirm it. Continuing — oMLX supplies its own configured key. If the \
            session cannot reach the model, pass --api-key.
            """)
    default:
        fail(LaunchError.serverUnreachable(url: probeURL))
    }
} catch {
    fail(LaunchError.serverUnreachable(url: probeURL))
}

// Keys we decline to assert — those whose values depend on oMLX's model selection,
// plus the credential when the operator did not supply one. Name them instead of
// pretending we control them.
// Managed policy outranks --settings, so a key set there is one we lose outright. It is
// read separately from everything else: merged into the other scopes it could not be
// attributed, and a key like ANTHROPIC_BASE_URL is one we normally win.
let managed = LaunchSettings.managedConflicts(
    managedSettings: LaunchSettings.loadManagedSettings())
if !managed.isEmpty {
    note(
        """
        \(LauncherIdentity.name): managed (MDM/policy) settings on this Mac set \
        \(managed.joined(separator: ", ")), which outrank even the --settings this \
        command passes. Those values win, so the address checked above may not be the \
        address the session uses. Ask whoever manages this Mac before relying on the \
        loopback guarantee here.
        """)
}

let conflicts = LaunchSettings.unwinnableConflicts(
    userSettings: LaunchSettings.loadUserSettings(), authToken: authToken)
if !conflicts.isEmpty {
    note(
        """
        \(LauncherIdentity.name): your Claude Code settings set \
        \(conflicts.joined(separator: ", ")), which outrank what oMLX passes. Their \
        correct values depend on what oMLX serves, so this launcher will not guess \
        them for you. Remove those keys if the session reports a context window, \
        model tier, or credential that disagrees with the server.
        """)
}

let settings: String
do {
    settings = try LaunchSettings.settingsJSON(baseURL: probeURL, authToken: authToken)
} catch {
    fail(error)
}

// exec, not spawn: this process should disappear, leaving Claude Code owning the
// terminal, the signals and the exit status.
let argv = ["omlx", "launch", "claude", "--settings", settings] + forwarded
var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
cargs.append(nil)
execvp("omlx", &cargs)

// execvp only returns on failure.
fail(LaunchError.omlxNotInstalled)
