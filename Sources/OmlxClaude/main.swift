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

// oMLX has to exist before anything else here makes sense.
guard let omlxVersion = capture("omlx", ["--version"]) else {
    fail(LaunchError.omlxNotInstalled)
}

// Say so when the launcher's assumptions were checked against an older oMLX. This
// is the whole exit-condition mechanism: it needs no knowledge of when upstream
// lands a fix, only of what we last verified.
if let notice = UpstreamWorkaround.stalenessNotice(installedOmlxVersion: omlxVersion) {
    note("\(LauncherIdentity.name): \(notice)")
}

// Every input here is user-supplied, so an unusable one is reported, never trapped
// on. `--host ::1` used to reach a force-unwrap and take the process down with
// SIGTRAP and no message at all.
guard let baseURL = ProbeTarget.resolve(arguments: forwarded) else {
    fail(LaunchError.unusableAddress(detail: "Cannot build a server address from those arguments."))
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
        // The server is up — saying "not responding" here would send the operator
        // to start a server that is already running.
        fail(LaunchError.serverRequiresAuth(url: probeURL))
    default:
        fail(LaunchError.serverUnreachable(url: probeURL))
    }
} catch {
    fail(LaunchError.serverUnreachable(url: probeURL))
}

// Keys we decline to assert — those whose values depend on oMLX's model selection,
// plus the credential when the operator did not supply one. Name them instead of
// pretending we control them.
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
