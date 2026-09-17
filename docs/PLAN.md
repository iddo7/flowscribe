# FlowScribe — Implementation Plan

## 1. Goal

Global-hotkey voice dictation for macOS 13+: hold ⌃⌥Space, speak, and release to put the transcript in the app the user was typing in. Standalone Swift Package, AppKit only, zero third-party dependencies.

## 2. Architecture / data flow

```
Carbon HotKeyManager ──press/release──▶ AppDelegate (orchestrator)
                                    │
                        TranscriptionStateMachine (pure)
                       idle ─▶ recording ─▶ transcribing ─▶ idle
                            │                     │
                     AudioCapture             TranscriptionClient
                     (AVAudioEngine →                │
                      Int16 16k mono in memory       │ URLSession multipart POST
                      → unique temp WAV)             │ https://api.openai.com/v1/audio/transcriptions)
                                    │                ▼
                          PasteController ◀── transcript text
                          (clipboard save/install, reactivate target app,
                           CGEvent ⌘V, clipboard restore)
```

Module responsibilities:

- **`main.swift`** — boots `NSApplication` with `.accessory` activation policy (no Dock icon).
- **`AppDelegate`** — owns the status item, menu, and orchestration; the only place with side effects.
- **`TranscriptionStateMachine`** — pure transition table; invalid transitions are rejected and reported, never silently coerced.
- **`AudioCapture`** — `AVAudioEngine` tap → `AVAudioConverter` (Int16, 16 kHz, mono) → in-memory buffer; WAV materialized only at stop, via `TempFileStore` (unique name, `0600`).
- **`TranscriptionClient`** — builds the multipart request (`MultipartBody`, pure), sends with `URLSession`, maps errors to user-safe messages.
- **`APIKeyStore`** — env-first (`OPENAI_API_KEY`), then Keychain (service `com.flowscribe.app`, account `openai-api-key`).
- **`PasteController`** — captures the target app plus caret/focused-input Accessibility geometry, then handles clipboard choreography and CGEvent synthesis; injected checkers make delivery testable.
- **`HUDController`** — a text-free 68×32 non-activating `NSPanel`: white voice bars for recording, a white rotating ring for transcription, and a brief green success glyph. It uses native `NSGlassEffectView` on macOS 26 and `NSVisualEffectView` fallback on macOS 13–15, anchored beside the paste destination when its geometry is available.
- **`SettingsWindowController`** — save/delete Keychain key; masked status only.

### OpenAI API choice

The default is `gpt-transcribe` through `POST /v1/audio/transcriptions`. Official OpenAI documentation describes the model as supporting completed audio files, streamed file transcripts, and committed turns in Realtime sessions. This v1 intentionally uses completed-file transcription: for short push-to-dictate clips it keeps the client and recovery model small, avoids a persistent WebSocket, and still provides a single-request result after the hotkey is released.

## 3. State transitions

| From | Event | To |
| --- | --- | --- |
| idle | startRecordingRequested | recording |
| recording | recordingStarted | recording (no-op confirm) |
| recording | stopRecordingRequested | transcribing |
| transcribing | transcriptionSucceeded / transcriptionFailed | idle |
| any | resetRequested | idle (explicit escape hatch) |
| * | anything else | rejected; state unchanged |

The hotkey manager emits distinct press and release edges: press starts from idle, release stops from recording, and events during transcription are ignored. The menu item retains toggle behavior as an accessibility and troubleshooting fallback.

## 4. Security & privacy

- API key never logged; request headers never logged; transcript never logged. Error messages carry only coarse causes.
- Key stored in Keychain with `kSecAttrAccessibleWhenUnlocked`; env var overrides Keychain (documented precedence).
- Temp WAV: unique filename (`flowscribe-<UUID>.wav`), mode `0600`, deleted in a `defer`-like path after the API call regardless of outcome; also cleaned on quit.
- Clipboard is snapshotted before transcript install and restored after a short paste-consumption delay, unless the user or another app replaced it in the meantime. Clipboard fallback intentionally keeps the transcript available.
- TLS-only endpoint; ATS defaults apply.

## 5. Failure handling

| Failure | Behavior |
| --- | --- |
| Hotkey already registered | Notice at launch; app still usable from the menu |
| Mic permission denied | Recording refused, notice opens the Microphone settings pane |
| Engine start error | Reset to idle, notice, no API call |
| Recording < ~0.3 s | No temp file, no API call, gentle notice |
| No API key | Notice with recovery path to Settings window |
| Network error / timeout (60 s) | Coarse message ("timed out", "offline"); state resets to idle |
| HTTP 401/403/429/other | Status plus short server-provided reason when safely extractable |
| Unparseable response | "Unexpected response" notice; temp file still deleted |
| Accessibility untrusted | Clipboard fallback + notice; ⌘V never synthesized |
| CGEvent send fails | Clipboard fallback message |

## 6. Testing strategy

Unit tests cover **pure logic only** (no audio hardware, no network, no real Keychain writes):

- WAV header byte-level layout and finalize rewrites (`WAVHeaderTests`).
- Multipart framing, unique boundaries, verbatim file bytes, optional language field (`MultipartBodyTests`).
- State machine: happy path, failure path, invalid transitions, toggle-per-state, transition callbacks (`StateMachineTests`).
- Model resolution incl. override/blank/trim, too-short detection at boundaries, response parsing (`TranscriptionSupportTests`).
- Env key resolution hermetically via injected environment; constants pinned (`APIKeyStoreTests`).

Manual/integration checks live in the README (permissions, paste behavior).

## 7. Packaging

`scripts/install.sh` assembles `~/Applications/FlowScribe.app` from a release binary built beforehand by the user (the script itself never runs `swift build`): writes `Info.plist` with `LSUIElement=true` (no Dock icon) and `NSMicrophoneUsageDescription`, copies the executable, then signs the complete bundle with a stable `com.flowscribe.app` designated requirement. This keeps the local app's TCC identity consistent across rebuilds.

## 8. Future work

- **Realtime streaming:** swap buffered capture for chunked upload (WebSocket or chunked multipart) behind the same `TranscriptionClient` seam; HUD gains a live level meter; state machine unchanged.
- Local Whisper fallback (offline), per-app model/language prefs, multi-shortcut profiles.
