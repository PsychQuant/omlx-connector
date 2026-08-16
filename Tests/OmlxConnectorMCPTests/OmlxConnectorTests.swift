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
