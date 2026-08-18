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

    /// These cases are about URL *assembly*, so they opt in to remote explicitly. The
    /// loopback gate itself is covered in LoopbackGateTests — keeping the two apart is
    /// deliberate: before round 2 these very fixtures (`https://server.example:8443/api`)
    /// were pinning acceptance of a remote address as correct behavior, which is exactly
    /// the defect four reviewers reported. They may assert scheme/path preservation; they
    /// may not stand in for the policy.
    private func resolve(_ args: [String], _ env: [String: String] = [:]) -> URL? {
        var environment = env
        environment["OMLX_ALLOW_REMOTE"] = "1"
        return ProbeTarget.resolve(arguments: args, environment: environment)
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

    func testUnparseableOmlxUrlIsRefusedRatherThanSilentlyDefaulted() {
        // Falling back to the default would point the session at a different server
        // than the operator named, without saying so.
        XCTAssertNil(resolve([], ["OMLX_URL": "not a url"]))
        XCTAssertNil(resolve([], ["OMLX_URL": "server.example:8443"]))  // no scheme
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
        // The payload carries non-`env` members since #11, so it is [String: Any] now and
        // `env` has to be unwrapped on its own.
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let env = try XCTUnwrap(parsed?["env"] as? [String: String])

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
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let env = try XCTUnwrap(parsed?["env"] as? [String: String])

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

    func testTheManagedRefusalSaysWhyAndWhatToDo() {
        // The verdict is unit-tested and mutation-proven; the two lines in main.swift that
        // act on it are not, because that file execs. Pinning the message is what can be
        // checked here — a refusal whose text went empty would still "work" and tell the user
        // nothing, and this one has to explain that the address checked moments earlier is
        // not the address the session would use.
        let text = LaunchError.managedBaseURLRefused(host: "policy.corp").errorDescription ?? ""
        XCTAssertTrue(text.contains("policy.corp"))
        XCTAssertTrue(text.contains("managed"))
        XCTAssertTrue(text.contains("declines"), "must say it is refusing, not warning")
        XCTAssertFalse(
            text.contains("OMLX_ALLOW_REMOTE"),
            "the opt-in cannot override a managed setting; offering it would be the round-6 defect again")
    }

    func testAManagedRemoteBaseURLIsRefused_NotMerelyNamed() {
        // Round 6: the warning existed and the launch proceeded anyway. Naming a conflict we
        // cannot win is worth doing, but on ANTHROPIC_BASE_URL specifically it is not enough
        // — the gate would have verified 127.0.0.1 while the session left for the policy
        // endpoint, bearer token included. That is the invariant, not a warning about it.
        //
        // We cannot override managed settings. We can decline to launch into them.
        XCTAssertEqual(
            LaunchSettings.managedBaseURLVerdict(
                managedSettings: ["env": ["ANTHROPIC_BASE_URL": "https://policy.corp/api"]]),
            .refuse(host: "policy.corp"))
    }

    func testAManagedLoopbackBaseURLIsFine() {
        // A policy pointing at this machine is not a leak, and refusing it would break a
        // legitimate managed setup for no gain.
        XCTAssertEqual(
            LaunchSettings.managedBaseURLVerdict(
                managedSettings: ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8000"]]),
            .proceed)
        XCTAssertEqual(LaunchSettings.managedBaseURLVerdict(managedSettings: [:]), .proceed)
    }

    func testAManagedAmbiguousBaseURLIsRefusedToo() {
        // Same reasoning as the launcher's own gate: an address two parsers read differently
        // is not one the operator can be vouching for.
        XCTAssertEqual(
            LaunchSettings.managedBaseURLVerdict(
                managedSettings: ["env": ["ANTHROPIC_BASE_URL": "http://0127.0.0.1:8000"]]),
            .refuse(host: "0127.0.0.1"))
    }

    func testManagedConflictOnAnOverriddenKeyIsStillReported() {
        // Round 5: four places — including the shipped --help text — claimed this command
        // warns when it can see a managed ANTHROPIC_BASE_URL. It did not, because that key
        // is one we normally *win*, so it was absent from reportableKeys and no scope could
        // report it. On a managed Mac the gate then greenlights 127.0.0.1 while the session
        // leaves for the policy endpoint, bearer token included.
        //
        // Merging every scope into one dictionary made this unfixable: a merged key cannot
        // be attributed. Managed scope is now read separately.
        XCTAssertEqual(
            LaunchSettings.managedConflicts(
                managedSettings: ["env": ["ANTHROPIC_BASE_URL": "https://policy.corp"]]),
            ["ANTHROPIC_BASE_URL"])
    }

    func testAnOrdinaryUserSettingIsNotReportedAsManaged() {
        // The reason the key could not simply be added to reportableKeys: doing so would
        // have warned every ordinary user about a key we do override successfully.
        XCTAssertEqual(
            LaunchSettings.unwinnableConflicts(
                userSettings: ["env": ["ANTHROPIC_BASE_URL": "https://mine"]],
                authToken: .known("t")),
            [])
    }

    func testManagedScopePathsAreReadSeparately() {
        let managed = LaunchSettings.managedScopePaths().map(\.path)
        XCTAssertTrue(managed.contains { $0.contains("managed-settings.json") })
        // And must not appear in the mergeable set, or attribution is lost again.
        let mergeable = LaunchSettings.settingsScopePaths(
            home: URL(fileURLWithPath: "/h"), workingDirectory: URL(fileURLWithPath: "/w")
        ).map(\.path)
        XCTAssertFalse(mergeable.contains { $0.contains("managed-settings.json") })
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

/// Auto mode is Claude Code's built-in starting mode on Pro/Max/Team, and it hands
/// oversight to a classifier rather than to the operator. That premise assumes the acting
/// model is a hosted one; this command replaces it with a local one, so the launch turns
/// auto mode off. Issue #11.
final class AutoModeOptInTests: XCTestCase {

    func testOptInAcceptsOnlyLiteralOne() {
        // Same rule as OMLX_ALLOW_REMOTE, for the same reason: a lenient parse here
        // silently restores the mode the whole change exists to disable. The near-misses
        // are the point — a `!= nil` or a truthy parse passes none of them.
        for spelling in ["true", "TRUE", "yes", "on", "01", " 1", "1 ", "0", "", "disable"] {
            XCTAssertFalse(
                LaunchSettings.autoModeOptIn(environment: ["OMLX_ALLOW_AUTO_MODE": spelling]),
                "\(String(reflecting: spelling)) must not count as opting in")
        }
        XCTAssertTrue(LaunchSettings.autoModeOptIn(environment: ["OMLX_ALLOW_AUTO_MODE": "1"]))
        XCTAssertFalse(LaunchSettings.autoModeOptIn(environment: [:]))
    }
}

/// The payload's *shape* is the defect #11 is about. `disableAutoMode` is a top-level
/// settings key, not an environment variable, and `settingsJSON` used to emit
/// `["env": …]` and nothing else — so there was no slot for it, nor for any other
/// non-`env` setting this launcher might ever need to assert.
final class SettingsPayloadShapeTests: XCTestCase {

    private func payload(environment: [String: String]) throws -> [String: Any] {
        let json = try LaunchSettings.settingsJSON(
            baseURL: "http://127.0.0.1:8000", authToken: .known("omlx"),
            environment: environment)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testPayloadCarriesDisableAutoModeAtTopLevel() throws {
        let parsed = try payload(environment: [:])
        XCTAssertEqual(parsed["disableAutoMode"] as? String, "disable")
        // Not smuggled into env: it is not an environment variable, and Claude Code would
        // not read it as one.
        XCTAssertNil((parsed["env"] as? [String: String])?["disableAutoMode"])
    }

    func testOptInSuppressesTheKey() throws {
        // The one case that must NOT be refused. Without it, hard-coding the key
        // unconditionally would satisfy every negative test in this file — the failure this
        // repo already had once, when a malformed codesign requirement refused all input and
        // eight "refuses X" cases stayed green.
        let parsed = try payload(environment: ["OMLX_ALLOW_AUTO_MODE": "1"])
        XCTAssertNil(parsed["disableAutoMode"])
    }

    /// Characterization, not a red-first test: it passes before and after. Its job is to fail
    /// if widening the payload drops an `env` key on the way past, which is the real risk in
    /// this change — the new key is visible, a silently missing old one is not.
    func testEnvOverridesSurviveThePayloadChange() throws {
        let parsed = try payload(environment: [:])
        let env = try XCTUnwrap(parsed["env"] as? [String: String])
        let expected = LaunchSettings.overrides(
            baseURL: "http://127.0.0.1:8000", authToken: .known("omlx"))
        XCTAssertEqual(env, expected)
        XCTAssertFalse(expected.isEmpty)
    }
}

/// Managed policy outranks `--settings`, so a policy that re-enables auto mode wins and we
/// can only name it. Naming it correctly means looking where it actually lives.
final class ManagedAutoModeTests: XCTestCase {

    func testManagedTopLevelDisableAutoModeIsNamed() {
        // The trap this test exists for: `managedConflicts` reads managedSettings["env"],
        // and `disableAutoMode` is NOT an environment variable — it is a top-level settings
        // key. Registering it among the env-scanned keys would produce a check that can
        // never fire, which is the inert-mechanism failure this repo already shipped once
        // with CLAUDE_CODE_DISABLE_1M_CONTEXT.
        let managed: [String: Any] = ["disableAutoMode": "disable"]
        XCTAssertTrue(LaunchSettings.managedConflicts(managedSettings: managed)
            .contains("disableAutoMode"))
    }

    func testManagedNestedPermissionsFormIsNamedToo() {
        // Claude Code documents `permissions.disableAutoMode` as an accepted spelling. A
        // check that only knew the top-level one would miss half the policies that set it.
        let managed: [String: Any] = ["permissions": ["disableAutoMode": "disable"]]
        XCTAssertTrue(LaunchSettings.managedConflicts(managedSettings: managed)
            .contains("permissions.disableAutoMode"))
    }

    func testManagedSettingsWithoutTheKeyStayQuiet() {
        // The positive case, in the "must not refuse everything" sense: a managed file that
        // says nothing about auto mode must not be reported as conflicting about it.
        let managed: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8000"]]
        let named = LaunchSettings.managedConflicts(managedSettings: managed)
        XCTAssertFalse(named.contains("disableAutoMode"))
        XCTAssertFalse(named.contains("permissions.disableAutoMode"))
        XCTAssertTrue(named.contains("ANTHROPIC_BASE_URL"))
    }
}
