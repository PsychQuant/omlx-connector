import Foundation
import OmlxConnectorCore

// MARK: - Configuration

enum OmlxConfig {
    static let defaultBaseURL = "http://127.0.0.1:8000"
    static let defaultTimeout: TimeInterval = 120

    /// Resolved base URL, refusing non-loopback hosts unless explicitly permitted.
    ///
    /// The entire point of this server is that content does not leave the machine,
    /// so the loopback constraint is enforced in code rather than promised in a
    /// README. `OMLX_ALLOW_REMOTE=1` exists for the one legitimate case — an oMLX
    /// instance on another machine the user owns — and requires a deliberate act.
    static func resolveBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let raw = environment["OMLX_BASE_URL"] ?? defaultBaseURL
        guard let url = URL(string: raw), let host = url.host else {
            throw OmlxError.invalidConfiguration("OMLX_BASE_URL is not a valid URL: \(raw)")
        }
        let allowRemote = LoopbackPolicy.allowsRemote(environment: environment)
        if !isLoopback(host) && !allowRemote {
            throw OmlxError.nonLoopbackRefused(host: host)
        }
        return url
    }

    /// Forwards to `LoopbackPolicy`, which both entry points share.
    ///
    /// The implementation moved to `OmlxConnectorCore` when `omlx-claude` turned out to
    /// have shipped without any loopback check at all. This name is kept because it is
    /// the vocabulary the rest of this file and its tests use.
    static func isLoopback(_ host: String) -> Bool { LoopbackPolicy.isLoopback(host) }

    static func resolveTimeout(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        guard let raw = environment["OMLX_TIMEOUT"], let value = TimeInterval(raw), value > 0 else {
            return defaultTimeout
        }
        return value
    }

    static func defaultModel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let value = environment["OMLX_MODEL"], !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Errors

enum OmlxError: LocalizedError {
    case invalidConfiguration(String)
    case nonLoopbackRefused(host: String)
    case serverUnreachable(baseURL: String)
    case httpError(status: Int, message: String)
    case emptyResponse
    case noModelsAvailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return detail
        case .nonLoopbackRefused(let host):
            return """
                Refusing to send content to non-loopback host '\(host)'. This server exists so \
                that content stays on this machine. If '\(host)' is a machine you own and you \
                intend to send content there, set OMLX_ALLOW_REMOTE=1.
                """
        case .serverUnreachable(let baseURL):
            return """
                No oMLX server responding at \(baseURL). Start it with `open -a oMLX` (or \
                `omlx start`), then retry. If it runs on a different port, set OMLX_BASE_URL.
                """
        case .httpError(let status, let message):
            return "oMLX returned HTTP \(status): \(message)"
        case .emptyResponse:
            return "oMLX returned no content. The model may have produced only reasoning output; try raising max_tokens."
        case .noModelsAvailable:
            return "The oMLX server reports no available models. Download one first, or set OMLX_MODEL."
        }
    }
}

extension OmlxError: TrustedErrorMessage {}

// MARK: - Wire types

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct TemplateKwargs: Encodable {
        let enable_thinking: Bool
    }

    let model: String
    let messages: [Message]
    let max_tokens: Int
    let temperature: Double?
    let chat_template_kwargs: TemplateKwargs?
}

/// Internal, not private: a test decodes it directly. The alternative was leaving the
/// served-model-id fix uncovered, which is how the defect it fixes got in.
struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            /// Present only when the model produced reasoning AND thinking was enabled.
            /// oMLX omits the key entirely when thinking is off — a clean disable
            /// rather than post-hoc filtering.
            let reasoning_content: String?
        }
        let message: Message
        let finish_reason: String?
    }
    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_time: Double?
    }

    let choices: [Choice]
    let usage: Usage?
    /// What the server says it actually served. Optional because oMLX is not required to
    /// echo it, and a missing key must not fail the whole call.
    ///
    /// Without this, `CompletionResult.model` was built from the *request*: an explicit
    /// `model` argument comes back out of `resolveModel(explicit:)` unchanged, so the
    /// requested and served ids were identical by construction. Issue #1 asks for the
    /// model id to be recorded with every result precisely so results are comparable; an
    /// echo of the request records nothing an alias, a server-side fallback, or a
    /// different quantization could contradict.
    let model: String?
}

private struct ErrorEnvelope: Decodable {
    struct Payload: Decodable { let message: String? }
    let error: Payload?
}

struct ModelInfo: Sendable {
    let id: String
    let contextWindow: Int?
    let loaded: Bool
    let type: String?
}

/// Outcome of a completion, with reasoning kept separate from the answer.
struct CompletionResult: Sendable {
    let text: String
    let reasoning: String?
    let model: String
    let finishReason: String?
    let completionTokens: Int?
    let elapsedSeconds: Double?
}

// MARK: - Client

protocol OmlxClienting: Sendable {
    func listModels() async throws -> [ModelInfo]
    func complete(
        prompt: String,
        system: String?,
        model: String?,
        maxTokens: Int,
        temperature: Double?,
        thinking: Bool
    ) async throws -> CompletionResult
}

actor OmlxClient: OmlxClienting {
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let configuredModel: String?

    /// Cached fallback model, so a burst of calls does not re-query /v1/models.
    private var cachedFallbackModel: String?

    init(
        baseURL: URL,
        timeout: TimeInterval = OmlxConfig.defaultTimeout,
        configuredModel: String? = OmlxConfig.defaultModel()
    ) {
        self.baseURL = baseURL
        self.configuredModel = configuredModel

        let config = URLSessionConfiguration.ephemeral
        // Generous, because a cold start loads the weights from disk: a 15 GB
        // 4-bit model takes roughly 17s on Apple silicon, larger ones longer.
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: Public API

    func listModels() async throws -> [ModelInfo] {
        let data = try await request(method: "GET", path: "/v1/models/status", body: nil)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["models"] as? [[String: Any]]
        else {
            throw OmlxError.emptyResponse
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return ModelInfo(
                id: id,
                contextWindow: row["max_context_window"] as? Int,
                loaded: (row["loaded"] as? Bool) ?? false,
                type: row["model_type"] as? String
            )
        }
    }

    func complete(
        prompt: String,
        system: String?,
        model: String?,
        maxTokens: Int,
        temperature: Double?,
        thinking: Bool
    ) async throws -> CompletionResult {
        let resolvedModel = try await resolveModel(explicit: model)

        var messages: [ChatRequest.Message] = []
        if let system, !system.isEmpty {
            messages.append(.init(role: "system", content: system))
        }
        messages.append(.init(role: "user", content: prompt))

        let payload = ChatRequest(
            model: resolvedModel,
            messages: messages,
            max_tokens: maxTokens,
            temperature: temperature,
            // Only send the kwarg when disabling: leaving it absent preserves each
            // model's own default for callers that do want reasoning.
            chat_template_kwargs: thinking ? nil : .init(enable_thinking: false)
        )

        let body = try JSONEncoder().encode(payload)
        let data = try await request(method: "POST", path: "/v1/chat/completions", body: body)
        let decoded = try decoder.decode(ChatResponse.self, from: data)

        guard let choice = decoded.choices.first else { throw OmlxError.emptyResponse }
        let text = choice.message.content ?? ""
        guard !text.isEmpty else { throw OmlxError.emptyResponse }

        return CompletionResult(
            text: text,
            reasoning: choice.message.reasoning_content,
            model: Self.servedModel(reported: decoded.model, requested: resolvedModel),
            finishReason: choice.finish_reason,
            completionTokens: decoded.usage?.completion_tokens,
            elapsedSeconds: decoded.usage?.total_time
        )
    }

    // MARK: Internals

    /// Which model id to record: what the server says it served, falling back to what we
    /// asked for. They usually agree; the times they do not are exactly the times the
    /// recorded id matters, which is why issue #1 asks for it with every result.
    ///
    /// Internal and static so it can be tested. The previous form was an inline
    /// `decoded.model ?? resolvedModel` at the call site, and reverting it to plain
    /// `resolvedModel` left the entire suite green — the decode was covered, the line using
    /// it was not.
    static func servedModel(reported: String?, requested: String) -> String {
        guard let reported, !reported.trimmingCharacters(in: .whitespaces).isEmpty else {
            return requested
        }
        return reported
    }

    private func resolveModel(explicit: String?) async throws -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let configuredModel { return configuredModel }
        if let cachedFallbackModel { return cachedFallbackModel }

        let models = try await listModels()
        // Prefer a model already in memory — it avoids a cold start entirely.
        let choice = models.first(where: { $0.loaded }) ?? models.first
        guard let id = choice?.id else { throw OmlxError.noModelsAvailable }
        cachedFallbackModel = id
        return id
    }

    /// Single choke point for every HTTP call.
    private func request(method: String, path: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw OmlxError.invalidConfiguration("could not build URL for path \(path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            // The overwhelmingly common failure is "the server isn't running", and
            // URLError's own message does not say so. Translate before it reaches
            // the user, who would otherwise see "Could not connect to the server."
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut:
                throw OmlxError.serverUnreachable(baseURL: baseURL.absoluteString)
            default:
                throw urlError
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw OmlxError.emptyResponse
        }

        switch http.statusCode {
        case 200...299:
            return data
        default:
            let detail = (try? decoder.decode(ErrorEnvelope.self, from: data))?.error?.message
                ?? String(data: data, encoding: .utf8)
                ?? "no response body"
            throw OmlxError.httpError(status: http.statusCode, message: sanitizeErrorMessage(detail))
        }
    }
}
