import XCTest

@testable import OmlxClaude

/// `--host`, `--port` and `--api-key` belong to oMLX and never reach Claude Code, so
/// the launcher reads them without consuming them.
///
/// Every case below except the first two is a defect this suite was written to pin
/// down after verify on PR #7 — the shell wrapper this command replaces, and the
/// first cut of this command, got them wrong in ways that were either silent or
/// fatal.
final class ProbeTargetFlagScanTests: XCTestCase {

    func testReadsSpaceSeparatedFlag() {
        XCTAssertEqual(ProbeTarget.value(of: "--host", in: ["--host", "h"]), "h")
    }

    func testReadsEqualsSeparatedFlag() {
        XCTAssertEqual(ProbeTarget.value(of: "--port", in: ["--port=8080"]), "8080")
    }

    func testLastOccurrenceWins() {
        // argparse's `store` action keeps the LAST occurrence. Taking the first
        // meant a shell alias carrying --host, plus a user override, made us probe
        // and — far worse — write into ANTHROPIC_BASE_URL a host oMLX was not
        // serving. Content would leave for somewhere the user did not choose.
        XCTAssertEqual(
            ProbeTarget.value(of: "--host", in: ["--host", "gateway", "--host", "127.0.0.1"]),
            "127.0.0.1")
        XCTAssertEqual(
            ProbeTarget.value(of: "--port", in: ["--port=1", "--port", "2"]), "2")
    }

    func testValuelessOccurrenceDoesNotHideALaterValidOne() {
        // Previously the first occurrence followed by another flag returned nil
        // outright, abandoning the rest of the array.
        XCTAssertEqual(
            ProbeTarget.value(of: "--host", in: ["--host", "--port", "8001", "--host", "h"]),
            "h")
    }

    func testStopsAtTheDoubleDashDelimiter() {
        // Past `--`, arguments belong to Claude Code; oMLX's argparse does not
        // consume them and neither may we.
        XCTAssertNil(ProbeTarget.value(of: "--host", in: ["--", "--host", "h"]))
        XCTAssertEqual(
            ProbeTarget.value(of: "--host", in: ["--host", "mine", "--", "--host", "theirs"]),
            "mine")
    }

    func testTrailingFlagWithNoValueIsNotAValue() {
        XCTAssertNil(ProbeTarget.value(of: "--host", in: ["--host"]))
    }

    func testEmptyValueIsRejectedRatherThanAccepted() {
        XCTAssertNil(ProbeTarget.value(of: "--host", in: ["--host="]))
    }
}

/// Building the address to probe. The old implementation kept only host and port and
/// rebuilt `http://host:port` from scratch, which silently dropped TLS and any path,
/// produced an unparseable string for IPv6, and then force-unwrapped the result.
final class ProbeTargetResolveTests: XCTestCase {

    private func resolve(_ args: [String], _ env: [String: String] = [:]) -> URL? {
        ProbeTarget.resolve(arguments: args, environment: env)
    }

    func testDefault() {
        XCTAssertEqual(resolve([])?.absoluteString, "http://127.0.0.1:8000")
    }

    func testFlags() {
        XCTAssertEqual(
            resolve(["--host", "192.168.1.9", "--port", "8001"])?.absoluteString,
            "http://192.168.1.9:8001")
    }

    func testOmlxUrlKeepsItsSchemeAndPath() {
        // Regression pinned: `https://server.example:8443/api` used to come back as
        // `http://server.example:8443` — TLS downgraded, path discarded — and that
        // result was then written into ANTHROPIC_BASE_URL.
        XCTAssertEqual(
            resolve([], ["OMLX_URL": "https://server.example:8443/api"])?.absoluteString,
            "https://server.example:8443/api")
    }

    func testFlagsOverrideOnlyWhatTheyName() {
        // Overriding the port must not silently reset the scheme or the path.
        XCTAssertEqual(
            resolve(["--port", "9000"], ["OMLX_URL": "https://server.example:8443/api"])?
                .absoluteString,
            "https://server.example:9000/api")
    }

    func testIPv6HostIsBracketed() {
        // `::1` is not an exotic input: this repo's own OmlxConfig.isLoopback accepts
        // it as the canonical IPv6 loopback. The old code produced `http://::1:8000`
        // and then crashed on the force-unwrap.
        XCTAssertEqual(resolve(["--host", "::1"])?.absoluteString, "http://[::1]:8000")
        XCTAssertEqual(resolve(["--host", "[::1]"])?.absoluteString, "http://[::1]:8000")
    }

    func testUnusableHostReturnsNilRatherThanCrashing() {
        // Any of these used to reach `URL(string:)!` and take the process down with
        // SIGTRAP and no message at all.
        XCTAssertNil(resolve(["--host", "a b c"]))
        XCTAssertNil(resolve(["--host", "a|b"]))
    }

    func testNonNumericOrOutOfRangePortIsRefused() {
        XCTAssertNil(resolve(["--port", "not-a-number"]))
        XCTAssertNil(resolve(["--port", "70000"]))
        XCTAssertNil(resolve(["--port", "-1"]))
    }

    func testUnparseableOmlxUrlFallsBackToTheDefault() {
        XCTAssertEqual(resolve([], ["OMLX_URL": "not a url"])?.absoluteString,
                       "http://127.0.0.1:8000")
    }

    func testModelsEndpointAppendsToAnyExistingPath() {
        let base = resolve([], ["OMLX_URL": "https://server.example:8443/api"])!
        XCTAssertEqual(
            ProbeTarget.modelsEndpoint(base: base).absoluteString,
            "https://server.example:8443/api/v1/models")
        let plain = resolve([])!
        XCTAssertEqual(
            ProbeTarget.modelsEndpoint(base: plain).absoluteString,
            "http://127.0.0.1:8000/v1/models")
    }
}

/// Which credential the launcher uses, and — the part it got wrong — when it must
/// admit it does not know.
final class AuthTokenResolutionTests: XCTestCase {

    func testApiKeyFlagWins() {
        XCTAssertEqual(
            ProbeTarget.resolveAuthToken(arguments: ["--api-key", "secret"], environment: [:]),
            .known("secret"))
    }

    func testEnvironmentTokenIsUsedWhenNoFlagIsGiven() {
        XCTAssertEqual(
            ProbeTarget.resolveAuthToken(arguments: [], environment: ["OMLX_TOKEN": "t"]),
            .known("t"))
    }

    func testFlagOutranksEnvironment() {
        XCTAssertEqual(
            ProbeTarget.resolveAuthToken(
                arguments: ["--api-key", "flag"], environment: ["OMLX_TOKEN": "env"]),
            .known("flag"))
    }

    func testUnknownWhenNeitherIsGiven() {
        // The launcher used to substitute the literal "omlx" here and assert it over
        // whatever oMLX had configured — the one thing LaunchSettings' own doc
        // comment says must never be guessed.
        XCTAssertEqual(ProbeTarget.resolveAuthToken(arguments: [], environment: [:]), .unknown)
    }
}

/// The settings override is the reason this command exists, so what it does and does
/// not claim to control is worth pinning down.
final class LaunchSettingsTests: XCTestCase {

    func testOverridesCarryTheKeysSettingsFilesShadow() throws {
        let json = try LaunchSettings.settingsJSON(
            baseURL: "http://127.0.0.1:8000", authToken: .known("omlx"))
        let parsed =
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: String]]
        let env = try XCTUnwrap(parsed?["env"])

        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8000")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"], "omlx")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "")
        // A normal timeout aborts local inference mid-generation — a cold model load
        // alone can outlast it.
        XCTAssertEqual(env["API_TIMEOUT_MS"], "3000000")
    }

    func testUnknownTokenIsNotAsserted() throws {
        // With no --api-key and no OMLX_TOKEN we do not know what oMLX configured, so
        // overriding would replace a working credential with a guess.
        let json = try LaunchSettings.settingsJSON(
            baseURL: "http://127.0.0.1:8000", authToken: .unknown)
        let parsed =
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: String]]
        let env = try XCTUnwrap(parsed?["env"])

        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8000")
    }

    func testUnknownTokenMakesTheAuthKeyReportable() {
        // Anything we decline to assert has to be something we warn about instead.
        XCTAssertTrue(
            LaunchSettings.reportableKeys(authToken: .unknown).contains("ANTHROPIC_AUTH_TOKEN"))
        XCTAssertFalse(
            LaunchSettings.reportableKeys(authToken: .known("t")).contains("ANTHROPIC_AUTH_TOKEN"))
    }

    func testOverridesClaimNoModelDependentKey() throws {
        let overrides = LaunchSettings.overrides(baseURL: "http://x", authToken: .known("t"))
        for key in LaunchSettings.modelDependentKeys {
            XCTAssertNil(overrides[key], "\(key) must not be guessed at")
        }
    }

    func testDisable1MContextIsStillSentButNotClaimedAsTheFix() throws {
        // Kept because it is correct for model IDs Claude Code recognizes, and inert
        // otherwise. What was wrong was the documentation calling it the #2716 fix:
        // oMLX-served IDs are never recognized, so it does not bound those sessions.
        // See issue #6. This test pins the behavior; the prose is fixed elsewhere.
        let overrides = LaunchSettings.overrides(baseURL: "http://x", authToken: .known("t"))
        XCTAssertEqual(overrides["CLAUDE_CODE_DISABLE_1M_CONTEXT"], "1")
    }

    func testReportsModelDependentKeysFoundInUserSettings() {
        let settings: [String: Any] = [
            "env": [
                "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "200000",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "something",
                "SOMETHING_UNRELATED": "1",
            ]
        ]
        XCTAssertEqual(
            LaunchSettings.unwinnableConflicts(userSettings: settings, authToken: .known("t")),
            ["ANTHROPIC_DEFAULT_OPUS_MODEL", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
    }

    func testReportsAuthTokenConflictOnlyWhenWeCannotWinIt() {
        let settings: [String: Any] = ["env": ["ANTHROPIC_AUTH_TOKEN": "theirs"]]
        XCTAssertEqual(
            LaunchSettings.unwinnableConflicts(userSettings: settings, authToken: .unknown),
            ["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertEqual(
            LaunchSettings.unwinnableConflicts(userSettings: settings, authToken: .known("t")),
            [])
    }

    func testKeysWeDoOverrideAreNotReportedAsUnwinnable() {
        let settings: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": "https://elsewhere"]]
        XCTAssertEqual(
            LaunchSettings.unwinnableConflicts(userSettings: settings, authToken: .known("t")), [])
    }

    func testAbsentOrShapelessSettingsReportNothing() {
        XCTAssertEqual(
            LaunchSettings.unwinnableConflicts(userSettings: [:], authToken: .known("t")), [])
        XCTAssertEqual(
            LaunchSettings.unwinnableConflicts(
                userSettings: ["env": "not an object"], authToken: .known("t")), [])
    }

    func testSettingsScopesCoverMoreThanTheGlobalFile() {
        // Project and local settings shadow inherited environment just as the global
        // file does; reporting only the global one left the promise half-kept.
        let scopes = LaunchSettings.settingsScopePaths(
            home: URL(fileURLWithPath: "/home/u"),
            workingDirectory: URL(fileURLWithPath: "/w"))
        let joined = scopes.map(\.path)
        XCTAssertTrue(joined.contains("/home/u/.claude/settings.json"))
        XCTAssertTrue(joined.contains("/w/.claude/settings.json"))
        XCTAssertTrue(joined.contains("/w/.claude/settings.local.json"))
    }

    func testMissingSettingsFileIsNotAnError() {
        XCTAssertTrue(
            LaunchSettings.loadUserSettings(paths: [URL(fileURLWithPath: "/nonexistent/s.json")])
                .isEmpty)
    }
}
