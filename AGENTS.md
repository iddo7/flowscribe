# FlowScribe repository instructions

- After every completed change, rebuild and install the application so the user can test it locally. Run `swift build -c release`, then `./scripts/install.sh`.
- Quit the running FlowScribe app before installing, then relaunch `~/Applications/FlowScribe.app` so local testing uses the new executable. Preserve the user's settings and Keychain entries.
- Run relevant tests before handing off changes. Use `swift test` for Swift changes.
- Commit completed changes and push them to `main`, unless the user explicitly requests otherwise. Preserve unrelated work and never force-push.
- These instructions apply only to this repository. Building is required here; the previous instruction to never run builds no longer applies.
