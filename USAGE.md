# Codex Pulse 1.3

Drag the handle on an account onto another account to reorder it. Your order is saved on this Mac.

The default signed-in account in `~/.codex` is also discovered. When weekly usage reaches 100%, countdowns show the weekly reset. Usage colors are green below 50%, yellow from 50% to 99%, and red at 100%.

A local macOS menu bar companion for your Monocode Codex profiles.

## Start and stop

Open **Codex Pulse.app** and click its waveform icon in the menu bar. The first
status read checks enabled accounts only. Automation is off by default.

- **Start** watches all enabled accounts. **Stop** cancels active work and prevents
  automatic checks. Right-click the menu bar icon and choose **Quit** to close the app.
- Each account has its own switch. A disabled account is skipped at startup, during
  refreshes, retries, wake checks, and the optional command-line status check.
- Account details start collapsed. Click an account's arrow or name to expand it;
  several accounts may remain expanded at the same time.
- A small countdown remains visible in collapsed rows. This timer runs locally;
  updating its digits does not send network requests.
- The panel fits one to three accounts. Additional accounts scroll inside the list.
- Use the account's settings icon to add a nickname or override scheduling. Press
  **Enter** or **Save** to save; the dialog closes after successful confirmation.

## Language

English is the default, including when updating preferences without a saved language.
Open **Settings → Language**, choose **English** or **Türkçe**, then **Save settings**.
Menus, status messages, notifications, history and date formatting follow your choice.
Your nicknames are never translated. No relaunch is required.

The usage bars are named **5-hour limit** and **Weekly limit**. Their numbers come
from Codex; their display labels are provided by this app, not imported from Monocode.

## Scheduling

**Only on reset** waits for the server's reported five-hour reset time plus a
15-second grace period, then verifies usage permission before considering a prompt.
**Also check periodically** adds status reads at an interval you enter in minutes.

**Retry status checks after** is a separate interval for connection failures or
unconfirmed resets. Both minute fields accept whole values from 1 to 10080.
These retries only read status: model prompts are attempted at most once per observed
reset. A full weekly limit waits for its known reset time.

A prompt attempt is recorded before the CLI starts. Failed, cancelled or interrupted
attempts are not automatically repeated for that reset. Duplicate profiles for the
same verified account share this record.

The app does not reset usage limits, add quota, or redeem reset credits. Optional
short prompts consume account usage and cannot guarantee that a new window starts.
API-key-only accounts, unknown identities and unverified permission do not receive prompts.

## Preferences

- Select a specific account for the menu bar countdown, or choose **Nearest reset**.
- Configure global scheduling or enable account-specific overrides.
- Quiet hours use your Mac's local HH:MM time and can cross midnight. Automatic
  prompts and notifications are deferred during these hours.
- Notifications are opt-in and require macOS permission. Repeated connection errors
  are not notified on every retry. macOS Focus can also suppress notifications.
- **Start watching when the app opens** affects the next launch, not the current session.
- **Open the app at login** manages the macOS login item. System Settings may require approval.

A sleeping or powered-off Mac cannot perform checks. An active watcher rechecks current
status on wake without sending a backlog of prompts. The refresh button reads status
without sending a model prompt.

## History and privacy

History keeps the last 300 local events. Filter successful prompts or errors, export
JSON, or clear the visible history. Clearing history never clears the duplicate-attempt
journal. Older history entries are shown in the currently selected language.

Preferences, nicknames, history and the attempt journal live at:

`~/Library/Application Support/Codex Pulse/state.json`

Profiles are discovered under:

`~/Library/Application Support/com.monocode.desktop/provider-accounts/codex/account-*`

The app does not read, copy or export token contents. Codex CLI uses each existing
profile's authentication in place and may refresh it. Monocode's selected account
is not changed. API-key environment variables are removed from child processes.

## Install or share

Copy **Codex Pulse.app** from the DMG to Applications or `~/Applications`. Quit any
older copy before replacing it. The Universal 2 app is compiled for Apple Silicon
and Intel, with runtime validation performed on Apple Silicon.

Requires macOS 13+, Python 3 at `/usr/bin/python3`, a compatible Codex CLI, and your
own signed-in Monocode accounts. A fresh Mac may need Apple Command Line Tools.
The app is ad-hoc signed, not Developer ID signed or notarized; macOS may block an
internet-downloaded copy. A DMG does not change that restriction.

Release packages contain no accounts, credentials, preferences or personal history.
The installed app contains its own backend and translations; moving the source
folder does not affect it. See README.md and CONTRIBUTING.md in the repository for
build/test instructions. This is not an official OpenAI or Monocode product.
