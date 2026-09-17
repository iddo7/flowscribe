# Security

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for security
issues. Do not include API keys, transcripts, audio recordings, system paths,
or other personal data in a public issue.

## Local data handling

- FlowScribe stores the OpenAI API key in the user's macOS login Keychain.
- Audio is written to a private temporary WAV only after recording stops and is
  deleted after the transcription request finishes or fails.
- Transcripts and API keys are not logged.
- Audio is sent directly to OpenAI's transcription API over TLS.

Each user must provide their own OpenAI API key and grant Microphone and
Accessibility permissions locally.
