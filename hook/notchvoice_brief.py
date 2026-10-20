#!/usr/bin/env python3
"""UserPromptSubmit hook: while NotchVoice voice replies are on, remind Claude that its final reply is read aloud.

Claude gets this note with every prompt, so every session keeps its spoken replies short. It adds nothing while
voice replies are muted (~/.claude/tts_off exists) or when "brief" is false in ~/.claude/tts_settings.json.

It also clears this session's "already spoken" marker (see speak.py), in case the last turn was cut short before the
Stop hook could clear it, and tells the NotchVoice app that this is the session the user is working in now.
"""
import json
import os
import re
import socket
import sys
import tempfile

MUTE_FILE = os.path.join(os.path.expanduser("~"), ".claude", "tts_off")
SETTINGS_FILE = os.path.join(os.path.expanduser("~"), ".claude", "tts_settings.json")
REMINDER = (
    "Voice replies are on, so your final message for this prompt is read aloud to the user. "
    "Keep it short: two to four plain sentences giving the high-level outcome. "
    "Leave out long lists, tables, code and file paths unless the user asks for them, and offer more detail instead of including it."
)


DARWIN_USER_TEMP_DIR = 65537  # _CS_DARWIN_USER_TEMP_DIR in <unistd.h>


def user_temp_dir():
    try:
        return os.confstr(DARWIN_USER_TEMP_DIR) or tempfile.gettempdir()
    except (OSError, ValueError):
        return tempfile.gettempdir()


SPOKEN_DIR = os.path.join(user_temp_dir(), "notchvoice-spoken")
SOCKET = os.path.join(user_temp_dir(), "notchvoice.sock")
# Claude Code wakes a session with these when a background task ends. The user didn't write them, so they don't
# move the focus to that session.
AUTOMATED_PROMPTS = ("<task-notification>",)


def tell_app_focus(session_id):
    """Replies from this session are read in full; the app only announces the others. Quick, as this runs on every prompt."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(0.5)
            connection.connect(SOCKET)
            connection.sendall((json.dumps({"type": "focus", "session_id": session_id}) + "\n").encode())
            connection.recv(256)
    except OSError:
        pass


def clear_spoken_marker(session_id):
    if isinstance(session_id, str) and re.fullmatch(r"[\w-]+", session_id):
        try:
            os.remove(os.path.join(SPOKEN_DIR, session_id))
        except OSError:
            pass


def wants_short_replies():
    try:
        with open(SETTINGS_FILE) as f:
            return json.load(f).get("brief", True) is not False
    except (OSError, ValueError, AttributeError):
        return True


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        payload = {}
    if isinstance(payload, dict) and isinstance(payload.get("session_id"), str):
        clear_spoken_marker(payload["session_id"])
        prompt = payload.get("prompt")
        if not (isinstance(prompt, str) and prompt.lstrip().startswith(AUTOMATED_PROMPTS)):
            tell_app_focus(payload["session_id"])
    if os.path.exists(MUTE_FILE) or not wants_short_replies():
        return
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": REMINDER}}))


if __name__ == "__main__":
    main()
