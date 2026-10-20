# Contributing to NotchVoice

Thanks for helping out. NotchVoice is a small project, so focused pull requests are the easiest to review and merge.

## How the project fits together

- **`Sources/NotchVoice/`** is the macOS app, built with SwiftUI and AppKit in Swift 6. It draws the notch panel, the glow and the settings window.
- **`hook/`** holds the three Claude Code hooks. They are Python scripts that use only the standard library:
  - `speak.py` is the `Stop` hook. It sends each reply to the app, which reads it aloud. When the app isn't running, it speaks the reply itself.
  - `notchvoice_permission.py` is the `PermissionRequest` hook. It sends permission requests to the notch.
  - `notchvoice_brief.py` is the `UserPromptSubmit` hook. It asks Claude to keep spoken replies short.
- **`hook/notchvoice_mcp.py`** is a small MCP server for chats in the Claude desktop app. Its `speak` tool runs `speak.py` with the text Claude passes in.
- **`hook/notchvoice_desktop.py`** adds that server to the desktop app's config for `install.sh`, or removes it. The desktop app rewrites its config while it's open, so when it's open the script makes the change again after the app quits.
- **`Tests/`** and **`hook/tests/`** hold the tests for the app and the hooks.

The app and the hooks never call each other directly. They share a few files in `~/.claude/`, plus a socket in `$TMPDIR`. The [How it works](README.md#how-it-works) section of the README lists the files, and the next section describes the socket. If you change one side of that contract, change the other side in the same pull request.

## The socket

The app listens on a Unix socket at `$TMPDIR/notchvoice.sock`. Each connection sends one request as a line of JSON and gets one line of JSON back. Every request except a permission request gets `{"ok": true, ...}`, or `{"ok": false, "error": "..."}` with a message you can show to the user.

The `type` field says what the request is:

| `type` | Other fields | What the app does |
| --- | --- | --- |
| `permission`, or no `type` | `tool_name`, `tool_input`, `cwd`, `session_id` | Shows the request in the notch. It answers `{"decision": "allow"}`, `"deny"` or `"ask"` once you click, and keeps the connection open until then. |
| `reply` | `session_id`, `session_name`, `cwd`, `text`, `timestamp` (seconds since 1970) | Saves the reply in the session's history, then reads it or announces it, depending on the setting. A reply never interrupts the one being read. |
| `say` | `text` | Reads the text straight away. |
| `list` | | Answers with `sessions`, each with `id`, `name`, `cwd`, `unread`, `replies`, `muted` and `last_activity`, plus `mode`, `speaking` and `waiting`. |
| `history` | `session`, `count` | Answers with `replies`, latest first. Each has `index` (0 is the latest), `text`, `date` and `read`. |
| `read` | `session`, `back` | Reads a reply straight away. `back` is 0 for the latest reply, 1 for the one before it, and so on. |
| `next` | | Reads the oldest unread reply, leaving out muted sessions. |
| `skip` | | Stops what is being read and goes on to the next reply in the queue. |
| `stop` | | Stops what is being read and empties the queue. |
| `mute`, `unmute` | `session` | Stops or starts reading a session's replies. Its replies are still saved. |

`session` can be a session's name, its id, or the start of either, as long as only one session matches. Without `session`, the app uses the session that replied most recently.

Requests that you make yourself (`say`, `read`, `next`) play even while voice replies are switched off. If they cut off a reply, that reply goes back to the front of the queue and is read again from the start afterwards. The app keeps history in memory only, so it starts empty each time the app opens.

Try it with `nc`:

```bash
echo '{"type": "list"}' | nc -U "$(getconf DARWIN_USER_TEMP_DIR)notchvoice.sock"
```

## Getting set up

You need macOS 14 or later, Xcode 16 or later, and Claude Code.

```bash
git clone https://github.com/NCSmit/notch-voice.git
cd notch-voice
swift build
```

- `./build.sh --install` builds the app, replaces the copy in `~/Applications` and restarts it.
- `./install.sh` does the same. It also copies the hooks into `~/.claude/hooks/`, registers them in `~/.claude/settings.json`, and adds the speak tool to the Claude desktop app's config. It keeps backups of anything it replaces. Restart Claude Code and the Claude desktop app afterwards, because both load these at startup.

## Running the tests

```bash
swift test
python3 -m unittest discover -s hook/tests
```

Both suites run automatically on every pull request.

## Trying changes by hand

Watch what the app is doing:

```bash
log stream --level info --predicate 'subsystem == "local.notchvoice"'
```

Hear a reply without waiting for Claude. This plays out loud and turns your music down while it speaks:

```bash
echo '{"session_id": "test", "cwd": "'"$PWD"'", "last_assistant_message": "Hello from NotchVoice"}' | python3 hook/speak.py
```

Run it twice quickly, with different `session_id`s and `NOTCHVOICE_SESSION_NAME` set to different names, to hear the replies queue up one after the other.

Send a test permission request to the notch. The card appears, and the command prints whatever you click:

```bash
echo '{"tool_name": "Bash", "tool_input": {"command": "echo hi", "description": "Say hi"}}' | python3 hook/notchvoice_permission.py
```

## Code style

- **Swift:** the app uses Swift 6 strict concurrency, with UI state in `@MainActor` classes. Keep types small and names descriptive. Add a comment only to explain why something is done, not what it does.
- **Hooks:** use only the Python standard library. A hook must never break Claude Code. If something it needs is missing, it should exit quietly with no output. Keep hooks fast, because `notchvoice_brief.py` runs on every prompt.
- **Screenshots:** when you change the UI, update the matching images in `docs/`. Use 2x PNGs with 8-bit colour.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep each pull request to one change.
3. In the description, say what changed and why in a sentence or two, and how you tested it. For UI changes, add a screenshot.
4. Make sure the app builds and both test suites pass.

## Reporting bugs

Open an issue using the bug report template. Please include:

- your macOS version and Mac model
- your Claude Code version, and where you run it (terminal, desktop app or IDE)
- your NotchVoice version, which is shown at the bottom of the settings window
