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

If the menu bar is crowded, press **⌃⌥,** to open Settings, or reopen **FlowScribe.app** from Finder or Spotlight. Settings also opens when the app launches.
Use **⌘H** to hide Settings or **⌘W** to close it; dictation continues in the background.

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
- The text-free HUD uses native Liquid Glass on macOS 26 and an AppKit material fallback on earlier versions. Voice bars show a scrolling history of the actual recorded microphone volume, preserving peaks and dips without saturating during ordinary speech. They switch to a rotating processing ring while transcribing, then resolve to a brief green check.
- The pill defaults to bottom-center on the active display. Settings offers top/bottom left, center, and right presets, plus **Near Typing** to follow the focused caret or input field.
- **Settings → Recording pill** adjusts width, height, number of bars, scroll speed, and sensitivity. Changes are saved automatically on your Mac and survive app restarts, rebuilds, and reinstalls over the existing app. They apply immediately, including while recording. The waveform tapers at both ends with uniform opacity. A labeled sample preview animates without opening the microphone; **Restore defaults** resets all five controls. Lower sensitivity if the waveform looks too flat, or increase scroll speed to show a shorter slice of audio. These controls only affect the display, never the recording or transcription.
- Audio is captured via `AVAudioEngine`, converted to 16 kHz mono 16-bit PCM in memory, written to a **unique temporary WAV** only when you stop, uploaded, then **deleted immediately** — success, failure, cancellation, or quit.
- Microphone changes rebuild the audio engine and converter while retaining audio already captured. Audio start/stop work runs off the UI thread so hotkey release can update the recording pill immediately.
- Transcript delivery: the app remembers your frontmost application when recording starts, copies the transcript to the clipboard, reactivates that app, and checks for a focused text input before synthesizing **⌘V** and restoring your original clipboard. With no focused text input (or if the target app is unavailable), the transcript stays on the clipboard for you to paste manually.

## Microphone selection

Open **Settings… → Microphone** and choose **System Default** to follow your Mac’s current input, or select a specific microphone for FlowScribe. The choice is saved across launches and applies to an active recording as well.

If your selected microphone disconnects, FlowScribe temporarily uses the system default and returns to the selected microphone when it reconnects. A route change may leave a brief gap in the recording. If no usable microphone remains, recording ends with a notice and the pill resets; connect a microphone and hold the shortcut again.

**Test microphone** checks the selected input for two seconds locally, without uploading audio or changing the clipboard. **Latest message** shows the actual recording/transcription error when the pill displays `!`, including when macOS notifications are hidden.

## Read selected text aloud

Open **Settings → Read aloud**, save your own ElevenLabs API key, and choose **Load my voices** or enter a voice ID. ElevenLabs usage is billed to your account. **Listen to a sample** previews the selected voice in French and English. A pasted voice ID is saved immediately and appears as the selected custom voice; **Apply voice** also explicitly confirms it. **Listen to a sample** uses the current field value even before leaving the field. Invalid IDs keep the previous saved voice but disable previews until corrected. Changing voices stops old samples and active readings; start a new reading to hear the new voice. Language detection is automatic; accent depends on the voice. Choose Natural (Multilingual v2), Expressive (Eleven v3), or Fast (Flash v2.5). Text is sent as selected, without an LLM rewrite or added emotion tags.

- Select text in another app and press **⌃⌥R**, or use the menu-bar **Read selection / pause** action. The shortcut toggles pause/resume during an existing reading.
- A quiet speaker button appears after selecting at least 40 characters and six words, excluding identifiable links and URL selections. It disappears after seven seconds, scrolling, typing, or changing apps. Disable it in Settings if you prefer the shortcut alone.
- Click the audio bubble to pause/resume. Its bars respond to the actual playback volume. **Esc**, the bubble’s **••• → Stop reading**, or the menu bar stops playback. Starting dictation also stops reading.
- When the source app exposes text geometry, the bubble follows the current word’s line alongside the selected passage. Click a word **within the original selected passage** to seek backward or forward. Normal link clicks are left alone; clicking does not consume the source app’s mouse event.
- **••• → Show reading text…** opens a synchronized reading view with clickable words, including for apps that do not expose word positions. The source bubble stays stable when geometry is unavailable. Reading continues if you switch apps; the bubble hides until you return.
- **••• → Speed** changes playback speed without generating audio again. Voice/model changes apply to the next reading.

Accessibility permission is required. Compatibility varies across browsers, PDF readers, and custom editors; image-only text requires OCR and is not supported. Explicit reading can fall back to Copy when an app exposes no AX selection, briefly saving/restoring the clipboard. Passive selection detection never touches the clipboard. Very large selections above 100,000 characters are not read.

Audio is requested in short segments, with at most one upcoming segment prepared during playback. Seeking to uncached text can take a moment and uses credits; if word timing is unavailable, seeking requests audio starting at the clicked word instead of guessing. Stopping cancels outstanding requests and clears the reading text/audio from memory. Requests already processed by ElevenLabs may still be billed.

The ElevenLabs key uses its own Keychain account, `elevenlabs-api-key`, under service `com.flowscribe.app`; it does not replace the OpenAI key. `ELEVENLABS_API_KEY` overrides it when present in the app’s launch environment. Speech requests use `https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/with-timestamps`; voice discovery uses `/v2/voices`. Selected text is sent to ElevenLabs, subject to its account retention policies. Generated audio is not written to disk or cached on disk by FlowScribe.

## Usage and cost

**Settings → Usage & cost** shows estimated API usage in USD for today, this calendar month, and since tracking started, plus a seven-day chart and monthly totals for ElevenLabs reading and OpenAI dictation. Tracking starts with this version; earlier usage is not reconstructed. Counters persist across app restarts and reinstalls. Only dates, model names, aggregate quantities and estimated amounts are saved locally; text, audio and API keys are not part of the usage history.

Estimates use published API prices checked October 28, 2026: Natural/Expressive reading at $0.08 per 1,000 submitted characters, Fast at $0.04 per 1,000 characters, and the default `gpt-transcribe` dictation at $0.0045 per audio minute. Known legacy transcription models use their documented estimates. **Edit estimate rates…** sets effective rates for future requests; it does not rewrite earlier estimates. Unknown models or unreadable audio durations are identified as unpriced usage rather than silently treated as free. Provider plans, included credits, custom voice surcharges, discounts and taxes can differ from these estimates. Sources: [ElevenLabs API pricing](https://elevenlabs.io/pricing/api), [OpenAI pricing](https://developers.openai.com/api/docs/pricing).

Every successful generation/upload is tracked once, including voice samples and prefetched audio, even if the response cannot be decoded. Replaying cached audio or changing playback speed adds no usage. ElevenLabs’ `character-cost` header supplies reported credits separately from the dollar estimate when available. Cancellations, network failures, server errors and requests still in flight are shown as unconfirmed possible charges outside the confirmed totals; HTTP rejections are excluded.

The separate **ElevenLabs account** section can refresh the account-wide quota, credit reset date and upcoming invoice via `/v1/user/subscription`. This requires **User: Read** permission on the API key. A restricted key can still synthesize speech and track local costs without this permission. Account values include other apps and are never added to FlowScribe’s estimates. OpenAI’s account billing is linked separately; no administrator credential is needed for local tracking.

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
- Dictation audio is sent to `https://api.openai.com/v1/audio/transcriptions` over TLS. Read-aloud text is sent to ElevenLabs as described above.

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

Unit tests cover WAV headers, multipart framing, state transitions, audio capture with fake engines, transcription support, settings, and clipboard delivery. Paste tests use a private pasteboard and injected activation/focus/keystroke handlers, without touching your clipboard or other apps.

```bash
swift test
```

## Troubleshooting

- **"Could not register the ⌃⌥Space global shortcut"** — another app owns it. Quit the other app or remap there.
- **Recording fails immediately** — Microphone permission not granted; open System Settings → Privacy & Security → Microphone.
- **Wrong microphone / input disconnected** — check Settings → Microphone. System Default follows macOS; a specific selection overrides it. The device list refreshes as microphones connect or disconnect.
- **Immediate `!` after release** — open Settings with ⌃⌥, and read Latest message. Use Test microphone to distinguish an input failure from an API/key/network error.
- **"Transcript copied" notice appears instead of pasting** — with no focused text input, this is expected: click a text field and press **⌘V**. If the notice asks for Accessibility access, permission is missing or stale. Quit FlowScribe, run `tccutil reset Accessibility com.flowscribe.app`, relaunch it, and grant the fresh prompt. `scripts/install.sh` bundle-signs the app with a stable designated requirement so future rebuilds retain the correct identity.
- **HTTP 401** — key invalid. HTTP 403 — key lacks access to the model. HTTP 429 — rate-limited; wait.
- **No text / "too short"** — recordings under ~0.3 s are discarded without an API call.
- **Key works in terminal but app says no key** — Finder didn't inherit your env (see above); use the Settings window.
- **Stuck on "Transcribing…"** — requests time out after 60 s and the state machine resets automatically; check connectivity.

To check microphone switching on your hardware, hold the shortcut and speak, unplug the headset or change the default input in macOS, continue speaking, then release. The pill should leave recording immediately and transcribe the captured audio. Also check a manually selected microphone while changing the macOS default, and disconnect/reconnect that selected microphone.

To check clipboard fallback, copy some unrelated text, click the desktop or a non-editable area with no text field focused, then dictate. After the copied notice, click a text field and press **⌘V**: the new transcript should appear. Repeat with an empty clipboard, then dictate directly into a focused text field to check automatic paste and restoration of the previous clipboard.

## Uninstall

```bash
./scripts/uninstall.sh   # removes the app, optionally deletes the Keychain item
```
