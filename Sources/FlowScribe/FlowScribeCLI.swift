import Foundation

enum FlowScribeCLI {
    private static let usage = """
        Usage: flowscribe transcribe <audio-file>
               flowscribe mcp

        Transcription sends the audio file to OpenAI and prints the transcript.
        Supported formats (up to \(TranscriptionClient.maximumFileSizeMB) MB): \(TranscriptionAudioFormat.supportedExtensions).
        """

    /// Returns only for invocations that belong to the menu bar app.
    static func runIfRequested(arguments: [String]) {
        let command = arguments.dropFirst().first
        switch command {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "transcribe":
            if arguments.count == 3, arguments[2] == "--help" {
                print(usage)
                exit(0)
            }
            guard arguments.count == 3, !arguments[2].isEmpty else { exitWithUsageError() }
            let file = URL(fileURLWithPath: arguments[2])
            runAsync {
                let text = try await TranscriptionClient(usageStore: nil).transcribe(fileAt: file)
                print(text)
            }
        case "mcp":
            guard arguments.count == 2 else { exitWithUsageError() }
            runAsync {
                try await TranscriptionMCPServer(client: TranscriptionClient(usageStore: nil)).run()
            }
        default:
            guard arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "flowscribe" else {
                return
            }
            if command == nil {
                print(usage)
                exit(0)
            }
            exitWithUsageError()
        }
    }

    private static func runAsync(_ operation: @escaping @Sendable () async throws -> Void) -> Never {
        Task.detached {
            do {
                try await operation()
                exit(0)
            } catch {
                writeError(error.localizedDescription)
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func exitWithUsageError() -> Never {
        writeError(usage)
        exit(2)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
