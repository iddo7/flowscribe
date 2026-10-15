import AppKit

// Entry point for the SPM executable: boot AppKit without NIB. AppKit is
// main-thread-only, so make that isolation explicit to Swift 6.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    if let flagIndex = CommandLine.arguments.firstIndex(of: "--test-transcription"),
       CommandLine.arguments.indices.contains(flagIndex + 1) {
        let file = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
        let client = TranscriptionClient()
        Task {
            do {
                let text = try await client.transcribe(fileAt: file)
                print(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? "Transcription service returned no text."
                      : "Transcription request succeeded. Transcript content was not logged.")
                exit(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
            } catch {
                print("Transcription test failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        app.run()
        return
    }
    if CommandLine.arguments.contains("--test-microphone") {
        // Use the signed app's microphone permission, without sending audio anywhere.
        let test = MicrophoneTest()
        test.start { result in
            switch result {
            case .success(let seconds):
                print(String(format: "Microphone received %.2f seconds of audio. Nothing was uploaded.", seconds))
                exit(0)
            case .failure(let error):
                print("Microphone test failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        withExtendedLifetime(test) { app.run() }
        return
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
