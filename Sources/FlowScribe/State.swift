/// Explicit application states. Transitions only via `TranscriptionStateMachine`.
enum AppState: Equatable {
    case idle
    case recording
    case transcribing
}

/// Pure-logic state machine enforcing valid transitions.
/// All mutation funnels through `handle(_:)` so behavior is unit-testable.
final class TranscriptionStateMachine {
    private(set) var state: AppState = .idle

    private let onTransition: ((AppState) -> Void)?

    init(onTransition: ((AppState) -> Void)? = nil) {
        self.onTransition = onTransition
    }

    enum Event: Equatable {
        case startRecordingRequested
        case recordingStarted
        case stopRecordingRequested
        case transcriptionSucceeded
        case transcriptionFailed
        case resetRequested
    }

    /// Whether the current state permits entering `recording`.
    var canStartRecording: Bool { state == .idle }

    /// Whether the current state permits stopping (or cancelling) an active session.
    var canStop: Bool { state == .recording }

    /// Hotkey toggle logic: idle -> start recording; recording -> stop; transcribing -> ignore.
    func event(forToggle: Void) -> Event? {
        switch state {
        case .idle: return .startRecordingRequested
        case .recording: return .stopRecordingRequested
        case .transcribing: return nil // ignore toggles while transcribing
        }
    }

    @discardableResult
    func handle(_ event: Event) -> Bool {
        let old = state
        switch (state, event) {
        case (.idle, .startRecordingRequested),
             (.idle, .resetRequested),
             (.recording, .recordingStarted),
             (.recording, .stopRecordingRequested),
             (.recording, .resetRequested),
             (.transcribing, .transcriptionSucceeded),
             (.transcribing, .transcriptionFailed),
             (.transcribing, .resetRequested):
            break // accepted
        default:
            return false // invalid transition; state unchanged
        }

        switch event {
        case .startRecordingRequested: state = .recording
        case .recordingStarted: state = .recording
        case .stopRecordingRequested: state = .transcribing
        case .transcriptionSucceeded, .transcriptionFailed, .resetRequested: state = .idle
        }

        if state != old { onTransition?(state) }
        return true
    }
}
