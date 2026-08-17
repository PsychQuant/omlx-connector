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

let probeURL = ProbeTarget.resolve(arguments: forwarded)
let token = ProcessInfo.processInfo.environment["OMLX_TOKEN"] ?? "omlx"

// Preflight. Claude Code's own failure when the server is absent is a wall of
// retries; this is one line that names the fix.
var request = URLRequest(url: URL(string: "\(probeURL)/v1/models")!)
request.timeoutInterval = 5
do {
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        fail(LaunchError.serverUnreachable(url: probeURL))
    }
} catch {
    fail(LaunchError.serverUnreachable(url: probeURL))
}

// Keys whose values depend on oMLX's model selection cannot be re-asserted from
// here without reimplementing that selection. Name them instead of pretending.
let conflicts = LaunchSettings.unwinnableConflicts(
    userSettings: LaunchSettings.loadUserSettings())
if !conflicts.isEmpty {
    note(
        """
        \(LauncherIdentity.name): your ~/.claude/settings.json sets \
        \(conflicts.joined(separator: ", ")), which outranks the value oMLX passes \
        and depends on which model it serves — so this launcher cannot restore it \
        for you. Remove those keys if the session reports a context window or model \
        tier that disagrees with the server.
        """)
}

let settings: String
do {
    settings = try LaunchSettings.settingsJSON(baseURL: probeURL, authToken: token)
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
