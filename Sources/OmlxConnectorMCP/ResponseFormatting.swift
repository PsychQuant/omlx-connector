import Foundation

/// Errors whose `errorDescription` is authored here and may be shown verbatim.
///
/// Anything NOT conforming (notably `URLError`, whose message is produced by the
/// system) is routed through `sanitizeErrorMessage` before reaching stderr or a
/// tool result, so control characters cannot be injected into logs (CWE-117).
protocol TrustedErrorMessage {}

enum ToolError: LocalizedError {
    case invalidParameter(_ message: String)
    case unknownTool(_ name: String)

    var errorDescription: String? {
        switch self {
        case .invalidParameter(let message): return "Invalid parameter: \(message)"
        case .unknownTool(let name): return "Unknown tool: \(name)"
        }
    }
}

extension ToolError: TrustedErrorMessage {}

/// Strip control characters from an untrusted message and bound its length.
func sanitizeErrorMessage(_ raw: String) -> String {
    let cleaned = raw.unicodeScalars
        .filter { scalar in
            // Keep printable characters and plain spaces; drop C0/C1 and DEL so a
            // crafted message cannot forge log lines or move the terminal cursor.
            !(scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value))
        }
    let text = String(String.UnicodeScalarView(cleaned))
    return text.count > 500 ? String(text.prefix(500)) + "…" : text
}

/// Render an error for display, trusting only messages we authored.
func describeForDisplay(_ error: Error) -> String {
    if error is TrustedErrorMessage {
        return error.localizedDescription
    }
    return sanitizeErrorMessage(error.localizedDescription)
}

/// Serialize a JSON payload with stable key order.
///
/// The `isValidJSONObject` pre-check is not redundant: `JSONSerialization` raises
/// an ObjC exception — uncatchable from Swift, so it takes down the process — when
/// handed a `Date`, a NaN, or a non-string key.
func formatJSON(_ value: Any) throws -> String {
    guard JSONSerialization.isValidJSONObject(value) else {
        throw ToolError.invalidParameter(
            "response payload contains non-JSON-serializable value (developer bug)")
    }
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys]
    )
    guard let string = String(data: data, encoding: .utf8) else {
        throw ToolError.invalidParameter("response payload contained invalid UTF-8 (developer bug)")
    }
    return string
}

func actionResult(_ fields: [String: Any]) throws -> String {
    try formatJSON(fields)
}


/// Strip C0, DEL and C1 from a string the SERVER authored before it reaches a terminal.
/// `--ping` prints model ids the server reported; a reply carrying `\u{1B}[2K` or a raw
/// `\n` could erase or forge a line of the harness's own banner. The eval harness filters
/// the banner too, but cannot tell a structural newline from an injected one — only the
/// point that prints the id can. Same convention as `TrustedErrorMessage`: text we did not
/// author is not trusted into output as-is.
func sanitizedForTerminal(_ text: String) -> String {
    String(text.unicodeScalars.map { scalar -> Character in
        let v = scalar.value
        let isControl = v < 0x20 || (v >= 0x7F && v <= 0x9F)
        return isControl ? "\u{FFFD}" : Character(scalar)
    })
}
