import MCP
import XCTest

@testable import OmlxConnectorMCP

/// The loopback constraint is the one property this project cannot get wrong:
/// everything else is a convenience, but a leak here defeats the entire purpose.
final class LoopbackEnforcementTests: XCTestCase {

    func testLoopbackHostsAreRecognized() {
        XCTAssertTrue(OmlxConfig.isLoopback("127.0.0.1"))
        XCTAssertTrue(OmlxConfig.isLoopback("127.1.2.3"))
        XCTAssertTrue(OmlxConfig.isLoopback("localhost"))
        XCTAssertTrue(OmlxConfig.isLoopback("LOCALHOST"))
        XCTAssertTrue(OmlxConfig.isLoopback("::1"))
        XCTAssertTrue(OmlxConfig.isLoopback("[::1]"))
    }

    func testNonLoopbackHostsAreRejected() {
        XCTAssertFalse(OmlxConfig.isLoopback("api.openai.com"))
        XCTAssertFalse(OmlxConfig.isLoopback("192.168.0.10"))
        XCTAssertFalse(OmlxConfig.isLoopback("10.0.0.1"))
        // A host that merely starts with the digits 127 is not loopback.
        XCTAssertFalse(OmlxConfig.isLoopback("127x.example.com"))
        XCTAssertFalse(OmlxConfig.isLoopback("1270.0.0.1"))
    }

    func testResolveRefusesRemoteHostByDefault() {
        XCTAssertThrowsError(
            try OmlxConfig.resolveBaseURL(environment: ["OMLX_BASE_URL": "https://api.example.com"])
        ) { error in
            guard case OmlxError.nonLoopbackRefused(let host) = error else {
                return XCTFail("expected nonLoopbackRefused, got \(error)")
            }
            XCTAssertEqual(host, "api.example.com")
        }
    }

    func testResolveAllowsRemoteHostOnlyWithExplicitOptIn() throws {
        let url = try OmlxConfig.resolveBaseURL(environment: [
            "OMLX_BASE_URL": "http://192.168.0.10:8000",
            "OMLX_ALLOW_REMOTE": "1",
        ])
        XCTAssertEqual(url.host, "192.168.0.10")
    }

    func testOptInMustBeExactlyOne() {
        // Anything other than "1" leaves the guard in place, so a stray "true" or
        // "yes" does not silently open the door.
        for value in ["true", "yes", "0", ""] {
            XCTAssertThrowsError(
                try OmlxConfig.resolveBaseURL(environment: [
                    "OMLX_BASE_URL": "http://192.168.0.10:8000",
                    "OMLX_ALLOW_REMOTE": value,
                ])
            )
        }
    }

    func testDefaultIsLoopback() throws {
        let url = try OmlxConfig.resolveBaseURL(environment: [:])
        XCTAssertEqual(url.absoluteString, OmlxConfig.defaultBaseURL)
        XCTAssertTrue(OmlxConfig.isLoopback(url.host ?? ""))
    }

    func testMalformedURLIsRejected() {
        XCTAssertThrowsError(
            try OmlxConfig.resolveBaseURL(environment: ["OMLX_BASE_URL": "not a url"]))
    }
}

final class ErrorSanitizationTests: XCTestCase {

    func testControlCharactersAreStripped() {
        let forged = "connection failed\n2026-01-01 ADMIN: access granted\u{1B}[2J"
        let cleaned = sanitizeErrorMessage(forged)
        XCTAssertFalse(cleaned.contains("\n"), "newline would let a message forge a log line")
        XCTAssertFalse(cleaned.contains("\u{1B}"), "escape sequence would reach the terminal")
        XCTAssertTrue(cleaned.contains("connection failed"))
    }

    func testLengthIsBounded() {
        let cleaned = sanitizeErrorMessage(String(repeating: "x", count: 5000))
        XCTAssertLessThanOrEqual(cleaned.count, 501)
    }

    func testAuthoredErrorsAreShownVerbatim() {
        let message = describeForDisplay(ToolError.invalidParameter("text is required"))
        XCTAssertEqual(message, "Invalid parameter: text is required")
    }

    func testNonCJKContentSurvivesSanitization() {
        XCTAssertEqual(sanitizeErrorMessage("模型未載入 — 需要 17 秒"), "模型未載入 — 需要 17 秒")
    }
}

final class ResponseFormattingTests: XCTestCase {

    func testStableKeyOrder() throws {
        let json = try formatJSON(["b": 2, "a": 1])
        let aIndex = try XCTUnwrap(json.range(of: "\"a\"")).lowerBound
        let bIndex = try XCTUnwrap(json.range(of: "\"b\"")).lowerBound
        XCTAssertLessThan(aIndex, bIndex, "sortedKeys keeps output diffable")
    }

    func testNonSerializablePayloadThrowsRatherThanCrashing() {
        // JSONSerialization raises an ObjC exception on a Date, which Swift cannot
        // catch — the process would die. The pre-check must turn it into an error.
        XCTAssertThrowsError(try formatJSON(["when": Date()]))
    }
}

// MARK: - Tool dispatch

private struct StubClient: OmlxClienting {
    let text: String

    func listModels() async throws -> [ModelInfo] {
        [ModelInfo(id: "stub", contextWindow: 4096, loaded: true, type: "llm")]
    }

    func complete(
        prompt: String, system: String?, model: String?, maxTokens: Int,
        temperature: Double?, thinking: Bool
    ) async throws -> CompletionResult {
        CompletionResult(
            text: text, reasoning: nil, model: "stub", finishReason: "stop",
            completionTokens: 3, elapsedSeconds: 0.1)
    }
}

final class ToolDispatchTests: XCTestCase {

    func testEveryDeclaredToolDispatches() async throws {
        let server = await OmlxConnectorServer(client: StubClient(text: "ok"))
        for tool in OmlxConnectorServer.defineTools() {
            do {
                _ = try await server.executeToolCall(name: tool.name, arguments: minimalArgs(for: tool.name))
            } catch let error as ToolError {
                if case .unknownTool = error {
                    XCTFail("declared tool \(tool.name) is not dispatched")
                }
                // invalidParameter is fine here — it proves the case was reached.
            }
        }
    }

    func testUnknownToolThrows() async {
        let server = await OmlxConnectorServer(client: StubClient(text: "ok"))
        do {
            _ = try await server.executeToolCall(name: "nope", arguments: [:])
            XCTFail("expected unknownTool")
        } catch let error as ToolError {
            guard case .unknownTool = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testClassifyMatchesBackOntoCallerCategories() async throws {
        // Local models decorate answers; the returned category must still be one of
        // the strings the caller supplied.
        let server = await OmlxConnectorServer(client: StubClient(text: "Category: 負面評價."))
        let json = try await server.executeToolCall(
            name: "local_classify",
            arguments: [
                "text": .string("x"),
                "categories": .array([.string("正面評價"), .string("負面評價")]),
            ])
        XCTAssertTrue(json.contains("\"負面評價\""))
        XCTAssertTrue(json.contains("\"matched\" : true"))
    }

    func testClassifyReportsWhenNoCategoryMatched() async throws {
        let server = await OmlxConnectorServer(client: StubClient(text: "I am not sure"))
        let json = try await server.executeToolCall(
            name: "local_classify",
            arguments: [
                "text": .string("x"),
                "categories": .array([.string("alpha"), .string("beta")]),
            ])
        XCTAssertTrue(json.contains("\"matched\" : false"))
    }

    func testClassifyRejectsSingleCategory() async {
        let server = await OmlxConnectorServer(client: StubClient(text: "x"))
        do {
            _ = try await server.executeToolCall(
                name: "local_classify",
                arguments: ["text": .string("x"), "categories": .array([.string("only")])])
            XCTFail("expected invalidParameter")
        } catch let error as ToolError {
            guard case .invalidParameter = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    private func minimalArgs(for tool: String) -> [String: Value] {
        switch tool {
        case "local_summarize": return ["text": .string("hello")]
        case "local_rewrite": return ["text": .string("hello"), "instruction": .string("fix")]
        case "local_classify":
            return ["text": .string("hello"), "categories": .array([.string("a"), .string("b")])]
        case "local_complete": return ["prompt": .string("hello")]
        default: return [:]
        }
    }
}

// MARK: - The served model id, not the requested one

/// `CompletionResult.model` used to echo whatever was asked for: `resolveModel(explicit:)`
/// returns a non-empty `explicit` unchanged, `ChatResponse` never decoded the response's
/// own `model` field, and the result was built from the request. So on the `--model` path
/// the two were identical by construction.
///
/// That silently defeats issue #1's "record the model id with every result": the eval
/// harness's `model` and `model_requested` columns were the same value in all 15 rows of
/// the first cross-size run, while `scripts/eval/README.md` described them as "what oMLX
/// actually served vs. what was asked for". An alias, a quantization the server picked, or
/// a fallback would all have gone unrecorded.
final class ServedModelIdTests: XCTestCase {
    func testDecodesTheModelIdTheServerReports() throws {
        let json = """
        {"model":"mlx-community--Qwen3-4B-Instruct-2507-4bit",
         "choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: json)
        XCTAssertEqual(decoded.model, "mlx-community--Qwen3-4B-Instruct-2507-4bit")
    }

    /// oMLX is not required to echo it. Absent must decode cleanly as nil so the caller
    /// can fall back to the requested id rather than the whole call failing.
    func testAModelIdIsOptional() throws {
        let json = """
        {"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: json)
        XCTAssertNil(decoded.model)
    }

    /// Round 2 found the *call site* untested: reverting `decoded.model ?? resolvedModel`
    /// to plain `resolvedModel` left all 133 tests green. The decode was covered; the line
    /// that uses it was not. That is the `main.swift` shape `CLAUDE.md` already records —
    /// "the decision function is tested and mutation-proven; its call site is not" — one
    /// level down, reproduced by the round that cited it.
    ///
    /// The fix `CLAUDE.md` prescribes for that shape is to shrink what has to be checked by
    /// hand rather than only warn about it: move the decision into a testable function and
    /// leave the call site a call. `OmlxClient.servedModel` is that function.
    func testServedModelPrefersWhatTheServerReported() {
        XCTAssertEqual(
            OmlxClient.servedModel(reported: "mlx-community--Qwen3-4B-Instruct-2507-4bit",
                                   requested: "qwen3-4b"),
            "mlx-community--Qwen3-4B-Instruct-2507-4bit")
    }

    func testServedModelFallsBackToTheRequestedIdWhenTheServerIsSilent() {
        XCTAssertEqual(OmlxClient.servedModel(reported: nil, requested: "qwen3-4b"), "qwen3-4b")
    }

    /// An empty string is not a report. Without this, a server echoing `"model": ""` would
    /// erase the one id the row has.
    func testServedModelIgnoresAnEmptyReport() {
        XCTAssertEqual(OmlxClient.servedModel(reported: "", requested: "qwen3-4b"), "qwen3-4b")
    }
}

// MARK: - Classify matching: exact, then unique containment, then unmatched

/// `handleClassify` used `categories.first { raw.contains($0) }` — the first offered label
/// appearing ANYWHERE in the reply, in the caller's list order. So "This is not a bug — it is
/// a feature request" resolved to `bug`, and the eval harness's accuracy signal scored a wrong
/// answer as correct (round-4 verify, requirement 6a). The rule is now: an exact match wins;
/// otherwise the UNIQUE contained label; otherwise unmatched.
final class ClassifyMatchingTests: XCTestCase {
    private func classify(_ reply: String, _ categories: [String]) async throws -> String {
        let server = await OmlxConnectorServer(client: StubClient(text: reply))
        return try await server.executeToolCall(
            name: "local_classify",
            arguments: ["text": .string("x"), "categories": .array(categories.map { .string($0) })])
    }

    func testTwoLabelsMentionedIsUnmatched() async throws {
        let json = try await classify("This is not a bug — it is a feature request.",
                                      ["bug", "feature request", "question"])
        XCTAssertTrue(json.contains("\"matched\" : false"), json)
    }

    func testExactMatchWinsOverContainmentOfAShorterLabel() async throws {
        // Containment alone picks "bug" (it appears first and is contained); the reply IS
        // "bug report", so that is the answer.
        let json = try await classify("bug report", ["bug", "bug report"])
        XCTAssertTrue(json.contains("\"category\" : \"bug report\""), json)
    }

    func testDecoratedSingleLabelStillMatches() async throws {
        let json = try await classify("Category: bug.", ["bug", "feature request"])
        XCTAssertTrue(json.contains("\"category\" : \"bug\""), json)
        XCTAssertTrue(json.contains("\"matched\" : true"), json)
    }

    func testHonestRefusalNamingTheOptionsIsUnmatched() async throws {
        // The desired outcome for out-of-domain input, and the harness's 6b case.
        let json = try await classify("neither a bug nor a feature request", ["bug", "feature request"])
        XCTAssertTrue(json.contains("\"matched\" : false"), json)
    }
}

extension ServedModelIdTests {
    /// `.whitespaces` does not include newlines, so `"model": "\n"` passed the emptiness
    /// guard and erased the requested id (round-4 verify).
    func testServedModelIgnoresANewlineOnlyReport() {
        XCTAssertEqual(OmlxClient.servedModel(reported: "\n", requested: "qwen3-4b"), "qwen3-4b")
        XCTAssertEqual(OmlxClient.servedModel(reported: "\r\n  ", requested: "qwen3-4b"), "qwen3-4b")
    }
}
