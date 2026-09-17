# FlowScribe

A menu-bar dictation tool for macOS 13+. Hold **⌃⌥Space** anywhere, speak, then release it to transcribe and paste into whatever app you were using. No third-party dependencies — pure Swift Package.

FlowScribe is open source under the [MIT License](LICENSE). Each installation
uses its own OpenAI API key; no key or account is bundled with the app.

## Quick start

```bash
cd /path/to/FlowScribe
swift build -c release
./scripts/install.sh          # assembles ~/Applications/FlowScribe.app
open ~/Applications/FlowScribe.app
```

After launching, click the 🎙 menu-bar icon → **Settings…** and save your API key. It is stored in your login Keychain and is the recommended setup for an installed app.

For a one-off environment-variable launch, run the executable itself from a terminal that already exports the key:

```bash
export OPENAI_API_KEY="sk-..."
~/Applications/FlowScribe.app/Contents/MacOS/FlowScribe
```

### Finder does not inherit your shell environment

A crucial gotcha: **an app launched from Finder, Spotlight, or `open` does not see variables you `export`ed in your shell**. Practical options:

1. **Recommended:** save the key once via the in-app Settings window (Keychain) — no environment needed.
2. Launch the binary from a terminal that has the variable exported:
   ```bash
   export OPENAI_API_KEY="sk-..."
   ~/Applications/FlowScribe.app/Contents/MacOS/FlowScribe &
   ```

## How it works

- Menu-bar-only app (`LSUIElement`) — no Dock icon.
- Hold **⌃⌥Space** to record; release it to transcribe (Carbon global hotkey).
- States: **idle → recording → transcribing → idle**. Input during transcription is ignored.
- The text-free 68×32 HUD uses native Liquid Glass on macOS 26 and an AppKit material fallback on earlier versions. Five white voice bars animate while recording, switch to a white rotating processing ring while transcribing, then resolve to a brief green check.
- The pill defaults to bottom-center on the active display. Settings offers top/bottom left, center, and right presets, plus **Near Typing** to follow the focused caret or input field.
- Audio is captured via `AVAudioEngine`, converted to 16 kHz mono 16-bit PCM in memory, written to a **unique temporary WAV** only when you stop, uploaded, then **deleted immediately** — success, failure, cancellation, or quit.
- Transcript delivery: the app remembers your frontmost application when recording starts, copies the transcript to the clipboard, reactivates that app, and synthesizes **⌘V** — then restores your original clipboard.

## Permissions (System Settings → Privacy & Security)

| Permission | When | If denied |
| --- | --- | --- |
| **Microphone** | On first recording attempt | Recording fails with a notice and a button/pointer to Settings |
| **Accessibility** | Needed to synthesize ⌘V | Automatic paste is skipped; transcript stays on the clipboard and a notice tells you to press ⌘V yourself |

The app never activates itself into the foreground while you work.

## Privacy

- The temp WAV file is created with `0600` permissions, lives only for the duration of the API call, and is deleted afterwards — including on errors.
- The API key is never logged, never written to disk (except Keychain when you save it there), and never included in error messages.
- Transcripts are never logged. Network failures are reported with coarse reasons only (timeout, offline, HTTP status).
- Audio is sent to `https://api.openai.com/v1/audio/transcriptions` over TLS.

## Model selection

Default model: **`gpt-transcribe`**. Override per-launch:

```bash
OPENAI_TRANSCRIBE_MODEL=whisper-1 ~/Applications/FlowScribe.app/Contents/MacOS/FlowScribe
```

Blank/whitespace values fall back to the default. The model name is sent as the multipart `model` field.

## Keychain details

Saved keys live at service `com.flowscribe.app`, account `openai-api-key`, readable when your Mac is unlocked. `OPENAI_API_KEY` in the environment always takes precedence over Keychain. Delete via the Settings window or:

```bash
security delete-generic-password -s com.flowscribe.app -a openai-api-key
```

## Tests

Pure-logic unit tests (WAV header correctness, multipart framing, state-machine transitions, model resolution, too-short detection, response parsing, env key resolution):

```bash
swift test
```

## Troubleshooting

- **"Could not register the ⌃⌥Space global shortcut"** — another app owns it. Quit the other app or remap there.
- **Recording fails immediately** — Microphone permission not granted; open System Settings → Privacy & Security → Microphone.
- **"Transcript copied" notice appears instead of pasting** — Accessibility is missing or stale. Quit FlowScribe, run `tccutil reset Accessibility com.flowscribe.app`, relaunch it, and grant the fresh prompt. `scripts/install.sh` bundle-signs the app with a stable designated requirement so future rebuilds retain the correct identity.
- **HTTP 401** — key invalid. HTTP 403 — key lacks access to the model. HTTP 429 — rate-limited; wait.
- **No text / "too short"** — recordings under ~0.3 s are discarded without an API call.
- **Key works in terminal but app says no key** — Finder didn't inherit your env (see above); use the Settings window.
- **Stuck on "Transcribing…"** — requests time out after 60 s and the state machine resets automatically; check connectivity.

## Uninstall

```bash
./scripts/uninstall.sh   # removes the app, optionally deletes the Keychain item
```
