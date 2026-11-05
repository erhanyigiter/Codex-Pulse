# Contributing

Small, focused pull requests are welcome. Please describe the behavior changed
and how you verified it.

## Development

- `App.swift`: AppKit menu bar shell, SwiftUI panels, and notifications.
- `backend.py`: account discovery, Codex app-server client, scheduling, and local state.
- `Localizations.json`: shared English translations for native UI and backend messages. Turkish source strings remain canonical so old history can change language without being rewritten.
- `USAGE.md` / `KULLANIM.md`: bundled English and Turkish user guides.
- `tests/test_backend.py`: synthetic scheduling and process lifecycle tests.
- `build.sh`: Universal 2 build and local ad-hoc signing.
- `package.sh`: DMG, source archive, and checksums.

Run `python3 -m unittest discover -s tests -v` before submitting changes.
For native changes, also run `bash build.sh` on macOS. The test suite does not
require real accounts or an OpenAI API key.

Preserve these behaviors:

- Automation requires verified account identity and backend usage permission.
- An attempt is persisted before sending, and is not repeated for the same reset.
- Account profiles remain isolated and duplicate identities share their journal.
- Stop and Quit cancel active child processes.
- Quiet hours and account switches are rechecked before launching a prompt.
- A manual refresh reads status without starting a model turn.
- Missing or unsupported quota data must not trigger model requests.

Use synthetic accounts and sample data in tests and screenshots. Do not commit
auth files, real tokens, local preferences, exported personal history, or signing
keys. When reporting an issue, include the app version, macOS version, processor
architecture, Codex CLI version, and a redacted description of the problem.
