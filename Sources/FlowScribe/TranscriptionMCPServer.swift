import CoreFoundation
import Foundation

struct TranscriptionMCPServer {
    let client: TranscriptionClient

    private static let currentVersion = "2026-07-28"
    private static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let serverInfo = ["name": "flowscribe", "version": "1.0.0"]
    private static let capabilities: [String: [String: Bool]] = ["tools": [:]]
    private static let instructions = "Use transcribe_audio when the user asks to transcribe a local audio file."
    private static let toolName = "transcribe_audio"
    private static let tool: [String: Any] = [
        "name": toolName,
        "description": "Transcribe a local audio file by sending it to OpenAI with FlowScribe's saved credentials. Returns the transcript as text.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "pattern": "^/",
                    "description": "Absolute path to the audio file (up to \(TranscriptionClient.maximumFileSizeMB) MB). Supported formats: \(TranscriptionAudioFormat.supportedExtensions)."
                ]
            ],
            "required": ["path"],
            "additionalProperties": false
        ]
    ]

    func run() async throws {
        while let line = readLine() {
            guard let response = await response(to: line) else { continue }
            var data = try JSONSerialization.data(withJSONObject: response)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }

    private func response(to line: String) async -> [String: Any]? {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed) else {
            return Self.failure(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let request = message as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return Self.failure(id: NSNull(), code: -32600, message: "Invalid request")
        }
        guard let id = request["id"] else { return nil } // Notifications have no response.
        guard id is String || (id is Int && CFGetTypeID(id as CFTypeRef) != CFBooleanGetTypeID()) else {
            return Self.failure(id: NSNull(), code: -32600, message: "Invalid request ID")
        }

        let params = request["params"] as? [String: Any] ?? [:]
        let metadata = params["_meta"] as? [String: Any]
        let version = metadata?["io.modelcontextprotocol/protocolVersion"] as? String
        if let version, version != Self.currentVersion {
            return Self.failure(id: id, code: -32022, message: "Unsupported protocol version", data: [
                "requested": version,
                "supported": [Self.currentVersion] + Self.legacyVersions
            ])
        }

        var result: [String: Any]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = Self.legacyVersions.first { $0 == requested } ?? Self.legacyVersions[0]
            result = [
                "protocolVersion": version,
                "capabilities": Self.capabilities,
                "serverInfo": Self.serverInfo,
                "instructions": Self.instructions
            ]
        case "server/discover":
            result = [
                "supportedVersions": [Self.currentVersion],
                "capabilities": Self.capabilities,
                "_meta": ["io.modelcontextprotocol/serverInfo": Self.serverInfo],
                "instructions": Self.instructions
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": [Self.tool]]
        case "tools/call":
            guard params["name"] as? String == Self.toolName else {
                return Self.failure(id: id, code: -32602, message: "Unknown tool")
            }
            result = await transcribe(arguments: params["arguments"] as? [String: Any])
        default:
            return Self.failure(id: id, code: -32601, message: "Method not found")
        }
        if version == Self.currentVersion || method == "server/discover" {
            result["resultType"] = "complete"
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func transcribe(arguments: [String: Any]?) async -> [String: Any] {
        guard let arguments, arguments.count == 1,
              let path = arguments["path"] as? String, path.hasPrefix("/"), !path.contains("\0") else {
            return Self.toolResult("Provide the absolute path to a local audio file.", isError: true)
        }
        do {
            let text = try await client.transcribe(fileAt: URL(fileURLWithPath: path))
            return Self.toolResult(text, isError: false)
        } catch {
            return Self.toolResult(error.localizedDescription, isError: true)
        }
    }

    private static func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func failure(id: Any, code: Int, message: String, data: [String: Any]? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        error["data"] = data
        return ["jsonrpc": "2.0", "id": id, "error": error]
    }
}
