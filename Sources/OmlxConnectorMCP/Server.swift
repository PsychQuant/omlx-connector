import Foundation
import OmlxConnectorCore
import MCP

/// Shared preamble. Local models are chattier than frontier models about what they
/// are doing, and a leading "Sure, here is the summary:" ruins the output for a
/// caller that will paste the result straight into a document.
private let outputOnlyRule =
    "Output only the requested result. No preamble, no explanation of what you did, "
    + "no meta-commentary, no markdown fences unless the result is itself code."

final class OmlxConnectorServer {
    private let server: Server
    private let transport: StdioTransport
    private let client: any OmlxClienting
    private let tools: [Tool]

    init(client: any OmlxClienting) async {
        self.client = client
        self.tools = Self.defineTools()

        server = Server(
            name: MCPIdentity.mcpServerName,
            version: AppVersion.current,
            capabilities: .init(tools: .init())
        )
        transport = StdioTransport()

        await registerHandlers()
    }

    func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool definitions

    static func defineTools() -> [Tool] {
        // openWorldHint is true throughout: every call reaches a separate process.
        let readOnlyLocal = Tool.Annotations(readOnlyHint: true, openWorldHint: true)

        return [
            Tool(
                name: "local_summarize",
                description: """
                    Summarize text using a model running on THIS machine, so the content is \
                    never sent to any cloud API. Use this whenever the text must not leave the \
                    machine — third-party transcripts and recordings, unpublished research, \
                    student or client data, anything covered by a confidentiality obligation. \
                    Slower than summarizing directly (seconds, and up to a minute if the model \
                    has to load), so prefer it for content that requires it rather than for speed.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("The text to summarize.")
                        ]),
                        "max_sentences": .object([
                            "type": .string("integer"),
                            "description": .string("Target length in sentences. Default 3.")
                        ]),
                        "focus": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Optional aspect to emphasize, e.g. 'decisions made' or 'open questions'.")
                        ]),
                        "language": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Output language, e.g. '繁體中文' or 'English'. Defaults to the language of the input.")
                        ]),
                        "model": .object([
                            "type": .string("string"),
                            "description": .string("Override the model id. Use local_models to see options.")
                        ])
                    ]),
                    "required": .array([.string("text")])
                ]),
                annotations: readOnlyLocal
            ),

            Tool(
                name: "local_rewrite",
                description: """
                    Rewrite text according to an instruction, using a model running on THIS \
                    machine so the content never leaves it. Suited to cleaning up ASR \
                    transcripts, fixing recognition errors, adjusting tone, or reformatting — \
                    the cases where the raw text is confidential but the result is needed. \
                    Give the instruction in the same spirit you would give a human editor.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("The text to rewrite.")
                        ]),
                        "instruction": .object([
                            "type": .string("string"),
                            "description": .string(
                                "What to do, e.g. 'fix speech-recognition errors, keep wording otherwise intact'.")
                        ]),
                        "language": .object([
                            "type": .string("string"),
                            "description": .string("Output language. Defaults to the language of the input.")
                        ]),
                        "model": .object([
                            "type": .string("string"),
                            "description": .string("Override the model id.")
                        ])
                    ]),
                    "required": .array([.string("text"), .string("instruction")])
                ]),
                annotations: readOnlyLocal
            ),

            Tool(
                name: "local_classify",
                description: """
                    Assign text to one of a set of categories, using a model running on THIS \
                    machine so the content never leaves it. Useful for triaging confidential \
                    material in bulk — routing messages, tagging transcript segments, sorting \
                    records — where sending each item to a cloud model is not acceptable.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("The text to classify.")
                        ]),
                        "categories": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Candidate categories. At least two.")
                        ]),
                        "model": .object([
                            "type": .string("string"),
                            "description": .string("Override the model id.")
                        ])
                    ]),
                    "required": .array([.string("text"), .string("categories")])
                ]),
                annotations: readOnlyLocal
            ),

            Tool(
                name: "local_complete",
                description: """
                    Send an arbitrary prompt to a model running on THIS machine. The escape \
                    hatch for local work that the task-specific tools do not cover; prefer \
                    local_summarize / local_rewrite / local_classify when they fit, since they \
                    carry better defaults. Reasoning is off by default because it costs several \
                    times the latency; enable it for problems that genuinely need working-out.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "prompt": .object([
                            "type": .string("string"),
                            "description": .string("The user message.")
                        ]),
                        "system": .object([
                            "type": .string("string"),
                            "description": .string("Optional system message.")
                        ]),
                        "thinking": .object([
                            "type": .string("boolean"),
                            "description": .string(
                                "Let the model reason before answering. Roughly 3-4x slower. Default false.")
                        ]),
                        "max_tokens": .object([
                            "type": .string("integer"),
                            "description": .string(
                                "Output cap. Default 1024. With thinking on, allow well above the expected answer length or the answer gets truncated by the reasoning.")
                        ]),
                        "temperature": .object([
                            "type": .string("number"),
                            "description": .string("Sampling temperature.")
                        ]),
                        "model": .object([
                            "type": .string("string"),
                            "description": .string("Override the model id.")
                        ])
                    ]),
                    "required": .array([.string("prompt")])
                ]),
                annotations: readOnlyLocal
            ),

            Tool(
                name: "local_models",
                description: """
                    List the models available on the local oMLX server, with each one's context \
                    window and whether it is currently loaded in memory. An already-loaded model \
                    answers immediately; a cold one costs a load first.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                annotations: readOnlyLocal
            )
        ]
    }

    // MARK: - Handlers

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { [tools] _ in
            ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return CallTool.Result(
                    content: [.text(text: "Server unavailable", annotations: nil, _meta: nil)],
                    isError: true)
            }
            do {
                let result = try await self.executeToolCall(
                    name: params.name, arguments: params.arguments ?? [:])
                return CallTool.Result(
                    content: [.text(text: result, annotations: nil, _meta: nil)])
            } catch {
                return CallTool.Result(
                    content: [
                        .text(
                            text: "Error: \(describeForDisplay(error))", annotations: nil,
                            _meta: nil)
                    ],
                    isError: true)
            }
        }
    }

    /// Internal, not private: tests assert that every declared tool name dispatches.
    func executeToolCall(name: String, arguments: [String: Value]) async throws -> String {
        switch name {
        case "local_summarize": return try await handleSummarize(arguments)
        case "local_rewrite": return try await handleRewrite(arguments)
        case "local_classify": return try await handleClassify(arguments)
        case "local_complete": return try await handleComplete(arguments)
        case "local_models": return try await handleModels(arguments)
        default: throw ToolError.unknownTool(name)
        }
    }

    private func handleSummarize(_ args: [String: Value]) async throws -> String {
        guard let text = args["text"]?.stringValue, !text.isEmpty else {
            throw ToolError.invalidParameter("text is required")
        }
        let sentences = args["max_sentences"]?.intValue ?? 3
        guard sentences > 0 else {
            throw ToolError.invalidParameter("max_sentences must be positive")
        }

        var instruction = "Summarize the following text in at most \(sentences) sentence(s)."
        if let focus = args["focus"]?.stringValue, !focus.isEmpty {
            instruction += " Emphasize: \(focus)."
        }
        if let language = args["language"]?.stringValue, !language.isEmpty {
            instruction += " Write the summary in \(language)."
        } else {
            instruction += " Write the summary in the same language as the input."
        }

        let result = try await client.complete(
            prompt: "\(instruction)\n\n---\n\(text)",
            system: outputOnlyRule,
            model: args["model"]?.stringValue,
            maxTokens: max(256, sentences * 120),
            temperature: nil,
            thinking: false
        )
        return try render(result, extra: ["task": "summarize"])
    }

    private func handleRewrite(_ args: [String: Value]) async throws -> String {
        guard let text = args["text"]?.stringValue, !text.isEmpty else {
            throw ToolError.invalidParameter("text is required")
        }
        guard let instruction = args["instruction"]?.stringValue, !instruction.isEmpty else {
            throw ToolError.invalidParameter("instruction is required")
        }

        var directive = "Rewrite the text below. Instruction: \(instruction)"
        if let language = args["language"]?.stringValue, !language.isEmpty {
            directive += "\nWrite the result in \(language)."
        }

        // A rewrite is at least as long as the input, so the cap is derived from it
        // rather than fixed. Roughly 4 characters per token, doubled for headroom.
        let budget = min(8192, max(512, text.count / 2))

        let result = try await client.complete(
            prompt: "\(directive)\n\n---\n\(text)",
            system: outputOnlyRule,
            model: args["model"]?.stringValue,
            maxTokens: budget,
            temperature: nil,
            thinking: false
        )
        return try render(result, extra: ["task": "rewrite"])
    }

    private func handleClassify(_ args: [String: Value]) async throws -> String {
        guard let text = args["text"]?.stringValue, !text.isEmpty else {
            throw ToolError.invalidParameter("text is required")
        }
        guard let rawCategories = args["categories"]?.arrayValue else {
            throw ToolError.invalidParameter("categories is required")
        }
        let categories = try rawCategories.enumerated().map { index, value -> String in
            guard let name = value.stringValue, !name.isEmpty else {
                throw ToolError.invalidParameter("categories[\(index)] must be a non-empty string")
            }
            return name
        }
        guard categories.count >= 2 else {
            throw ToolError.invalidParameter("categories needs at least two entries")
        }

        let list = categories.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
            Classify the text below into exactly one of these categories:
            \(list)

            Reply with the category name alone, copied exactly as written above.

            ---
            \(text)
            """

        let result = try await client.complete(
            prompt: prompt,
            system: outputOnlyRule,
            model: args["model"]?.stringValue,
            maxTokens: 64,
            temperature: 0,
            thinking: false
        )

        // Local models sometimes decorate the answer ("Category: X", quotes, a
        // trailing period). Match back onto the caller's list so the return value is
        // always one of the strings they supplied, and say so when it is not.
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = categories.first { raw.localizedCaseInsensitiveContains($0) }

        let categoryValue: Any = matched ?? NSNull()
        return try formatJSON([
            "task": "classify",
            "category": categoryValue,
            "matched": matched != nil,
            "raw_response": raw,
            "model": result.model,
            "elapsed_seconds": result.elapsedSeconds ?? NSNull()
        ])
    }

    private func handleComplete(_ args: [String: Value]) async throws -> String {
        guard let prompt = args["prompt"]?.stringValue, !prompt.isEmpty else {
            throw ToolError.invalidParameter("prompt is required")
        }
        let thinking = args["thinking"]?.boolValue ?? false
        let maxTokens = args["max_tokens"]?.intValue ?? 1024
        guard maxTokens > 0 else {
            throw ToolError.invalidParameter("max_tokens must be positive")
        }

        let result = try await client.complete(
            prompt: prompt,
            system: args["system"]?.stringValue,
            model: args["model"]?.stringValue,
            maxTokens: maxTokens,
            temperature: args["temperature"]?.doubleValue,
            thinking: thinking
        )
        return try render(result, extra: ["task": "complete"])
    }

    private func handleModels(_ args: [String: Value]) async throws -> String {
        let models = try await client.listModels()
        let rows: [[String: Any]] = models.map { model in
            [
                "id": model.id,
                "context_window": model.contextWindow ?? NSNull(),
                "loaded": model.loaded,
                "type": model.type ?? NSNull()
            ]
        }
        return try formatJSON(["models": rows, "count": rows.count])
    }

    private func render(_ result: CompletionResult, extra: [String: Any]) throws -> String {
        var payload: [String: Any] = extra
        payload["text"] = result.text
        payload["model"] = result.model
        payload["elapsed_seconds"] = result.elapsedSeconds ?? NSNull()
        if let reasoning = result.reasoning, !reasoning.isEmpty {
            payload["reasoning"] = reasoning
        }
        // Surfaced so the caller can tell a real answer from one cut off mid-sentence.
        if let finish = result.finishReason, finish != "stop" {
            payload["finish_reason"] = finish
        }
        return try formatJSON(payload)
    }
}
