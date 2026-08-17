import XCTest

@testable import OmlxClaude

/// `--host` and `--port` belong to oMLX and never reach Claude Code, so the
/// launcher reads them without consuming them. The point of testing this is the
/// bug it removes: the shell wrapper this command replaces always probed
/// 127.0.0.1:8000, so `--port 8001` against a server on 8001 reported the server
/// as down.
final class ProbeTargetTests: XCTestCase {

    func testDefaultsWhenNothingIsGiven() {
        XCTAssertEqual(
            ProbeTarget.resolve(arguments: [], environment: [:]),
            "http://127.0.0.1:8000")
    }

    func testReadsSpaceSeparatedFlags() {
        XCTAssertEqual(
            ProbeTarget.resolve(
                arguments: ["--host", "192.168.1.9", "--port", "8001"], environment: [:]),
            "http://192.168.1.9:8001")
    }

    func testReadsEqualsSeparatedFlags() {
        XCTAssertEqual(
            ProbeTarget.resolve(arguments: ["--port=8080"], environment: [:]),
            "http://127.0.0.1:8080")
    }

    func testFlagsOutrankTheEnvironment() {
        XCTAssertEqual(
            ProbeTarget.resolve(
                arguments: ["--port", "9000"],
                environment: ["OMLX_URL": "http://127.0.0.1:8500"]),
            "http://127.0.0.1:9000")
    }

    func testEnvironmentIsUsedWhenNoFlagIsGiven() {
        // Carried over from the shell wrapper so existing setups keep working.
        XCTAssertEqual(
            ProbeTarget.resolve(
                arguments: [], environment: ["OMLX_URL": "http://127.0.0.1:8500"]),
            "http://127.0.0.1:8500")
    }

    func testFlagsAreOnlyReadNeverRemoved() {
        // The arguments array we forward must still contain them: oMLX is the one
        // that consumes these, and dropping them here would change the launch.
        let arguments = ["--port", "8001", "--model", "some-model"]
        _ = ProbeTarget.resolve(arguments: arguments, environment: [:])
        XCTAssertEqual(arguments, ["--port", "8001", "--model", "some-model"])
    }

    func testAFlagFollowedByAnotherFlagHasNoValue() {
        XCTAssertNil(ProbeTarget.value(of: "--host", in: ["--host", "--port", "8001"]))
    }

    func testTrailingFlagWithNoValueDoesNotCrash() {
        XCTAssertEqual(
            ProbeTarget.resolve(arguments: ["--port"], environment: [:]),
            "http://127.0.0.1:8000")
    }
}

/// The settings override is the reason this command exists, so what it does and
/// does not claim to control is worth pinning down.
final class LaunchSettingsTests: XCTestCase {

    func testOverridesCarryTheKeysSettingsFilesShadow() throws {
        let json = try LaunchSettings.settingsJSON(
            baseURL: "http://127.0.0.1:8000", authToken: "omlx")
        let parsed =
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: String]]
        let env = try XCTUnwrap(parsed?["env"])

        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8000")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"], "omlx")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "")
        // A normal timeout aborts local inference mid-generation — a cold model
        // load alone can outlast it.
        XCTAssertEqual(env["API_TIMEOUT_MS"], "3000000")
        XCTAssertEqual(env["CLAUDE_CODE_DISABLE_1M_CONTEXT"], "1")
    }

    func testOverridesClaimNoModelDependentKey() throws {
        // These depend on which model oMLX ends up serving. Asserting a guessed
        // value would be worse than leaving them alone: a wrong context window
        // fails far from its cause.
        let overrides = LaunchSettings.overrides(baseURL: "http://x", authToken: "t")
        for key in LaunchSettings.modelDependentKeys {
            XCTAssertNil(overrides[key], "\(key) must not be guessed at")
        }
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
            LaunchSettings.unwinnableConflicts(userSettings: settings),
            ["ANTHROPIC_DEFAULT_OPUS_MODEL", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
    }

    func testKeysWeDoOverrideAreNotReportedAsUnwinnable() {
        // We win these back through --settings, so warning about them would be
        // noise that trains the user to ignore the warning that matters.
        let settings: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": "https://elsewhere"]]
        XCTAssertEqual(LaunchSettings.unwinnableConflicts(userSettings: settings), [])
    }

    func testAbsentOrShapelessSettingsReportNothing() {
        XCTAssertEqual(LaunchSettings.unwinnableConflicts(userSettings: [:]), [])
        XCTAssertEqual(LaunchSettings.unwinnableConflicts(userSettings: ["env": "not an object"]), [])
    }

    func testMissingSettingsFileIsNotAnError() {
        // Launching must not depend on the file existing.
        let nowhere = URL(fileURLWithPath: "/nonexistent/settings.json")
        XCTAssertTrue(LaunchSettings.loadUserSettings(at: nowhere).isEmpty)
    }
}
