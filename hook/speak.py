#!/usr/bin/env python3
"""Stop hook: read Claude's last reply aloud (fully offline).

When the NotchVoice app is running, the reply goes to it over its socket, and the app reads replies from all sessions
one at a time, each starting with the session's name. The name is $NOTCHVOICE_SESSION_NAME, else the git branch, else
the project folder. Without the app, this hook speaks the reply itself with macOS `say`.

Settings for speaking without the app come from ~/.claude/tts_settings.json, which the NotchVoice notch app writes:
  voice  a voice for `say -v`, else $CLAUDE_TTS_VOICE, else the system Spoken Content voice
  rate   words per minute, else $CLAUDE_TTS_RATE, else the voice's own rate
  duck   how loud Spotify / Music stay while speaking, as a fraction of their volume, else $CLAUDE_TTS_DUCK, else 0.5
Mute: touch ~/.claude/tts_off   Unmute: rm ~/.claude/tts_off   (NotchVoice samples set NOTCHVOICE_SAMPLE=1 and play anyway)
"""
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
MUTE_FILE = os.path.join(HOME, ".claude", "tts_off")
SETTINGS_FILE = os.path.join(HOME, ".claude", "tts_settings.json")
DARWIN_USER_TEMP_DIR = 65537  # _CS_DARWIN_USER_TEMP_DIR in <unistd.h>
MUSIC_APPS = ["Spotify", "Music"]


def user_temp_dir():
    # The folder NSTemporaryDirectory() gives the app. TMPDIR can't be trusted for this, because tool servers started
    # by the Claude desktop app don't get it, and tempfile then falls back to /tmp.
    try:
        return os.confstr(DARWIN_USER_TEMP_DIR) or tempfile.gettempdir()
    except (OSError, ValueError):
        return tempfile.gettempdir()


# "<hook pid> <say pid>" of the reply currently speaking (or getting ready to).
OWNER_FILE = os.path.join(user_temp_dir(), "claude_tts_owner")
DUCK_FILE = os.path.join(user_temp_dir(), "claude_tts_duck.json")
SOCKET = os.path.join(user_temp_dir(), "notchvoice.sock")
# nv leaves a file named after the session here when Claude reads something aloud with it, e.g. for /read.
# That turn's reply is then not read as well. notchvoice_brief.py clears it when the next prompt starts.
SPOKEN_DIR = os.path.join(user_temp_dir(), "notchvoice-spoken")
# Chats in the Claude desktop app have no session id; they share one session.
DESKTOP_SESSION = ("claude-desktop", "Claude chat")


def is_tool_result_only(content):
    return isinstance(content, list) and content and all(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content
    )


def last_reply_from_transcript(path):
    try:
        with open(path) as f:
            entries = [json.loads(line) for line in f if line.strip()]
    except (OSError, json.JSONDecodeError):
        return ""
    chunks = []
    for entry in reversed(entries):
        msg = entry.get("message") or {}
        if entry.get("type") == "user" and not is_tool_result_only(msg.get("content")):
            break
        if entry.get("type") != "assistant":
            continue
        for block in reversed(msg.get("content") or []):
            if isinstance(block, dict) and block.get("type") == "text":
                chunks.append(block.get("text", ""))
    return "\n\n".join(reversed(chunks))


def clean(text):
    text = re.sub(r"```.*?```", " (code block omitted) ", text, flags=re.S)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)  # markdown links -> label
    text = re.sub(r"https?://\S+", "link", text)
    text = re.sub(r"^\s*[#>|]+\s*", "", text, flags=re.M)
    text = re.sub(r"^\s*[-*]\s+", "", text, flags=re.M)
    text = re.sub(r"[*_~]{1,3}", "", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def already_spoken(session_id):
    """True, once, when nv already read something aloud for this turn."""
    if not session_id or not re.fullmatch(r"[\w-]+", session_id):
        return False
    try:
        os.remove(os.path.join(SPOKEN_DIR, session_id))
        return True
    except OSError:
        return False


def git(cwd, *args):
    try:
        result = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def session_name(cwd):
    name = os.environ.get("NOTCHVOICE_SESSION_NAME", "").strip()
    if name or not cwd:
        return name or DESKTOP_SESSION[1]
    # Empty on a detached HEAD, and unlike rev-parse it works before the first commit.
    branch = git(cwd, "symbolic-ref", "--short", "-q", "HEAD")
    if branch:
        return branch
    return os.path.basename(git(cwd, "rev-parse", "--show-toplevel") or os.path.normpath(cwd))


def send_to_app(payload, text):
    """Hands the reply to the NotchVoice app. Returns False when the app isn't there to take it."""
    cwd = payload.get("cwd")
    message = {
        "type": "reply",
        "session_id": payload.get("session_id") or DESKTOP_SESSION[0],
        "session_name": session_name(cwd),
        "cwd": cwd,
        "text": text,
        "timestamp": time.time(),
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(2)
            connection.connect(SOCKET)
            connection.sendall((json.dumps(message) + "\n").encode())
            return bool(connection.makefile().readline())
    except OSError:
        return False


def load_settings():
    try:
        with open(SETTINGS_FILE) as f:
            settings = json.load(f)
    except (OSError, ValueError):
        return {}
    return settings if isinstance(settings, dict) else {}


def music_level(settings):
    level = settings.get("duck", os.environ.get("CLAUDE_TTS_DUCK", "0.5"))
    try:
        return min(max(float(level), 0.0), 1.0)
    except (TypeError, ValueError):
        return 0.5


def read_owner():
    try:
        with open(OWNER_FILE) as f:
            return [int(pid) for pid in f.read().split()]
    except (OSError, ValueError):
        return []


def write_owner(*pids):
    with open(OWNER_FILE, "w") as f:
        f.write(" ".join(str(pid) for pid in pids))


def is_owner():
    owner = read_owner()
    return bool(owner) and owner[0] == os.getpid()


def take_over():
    """Stop the previous reply at any stage (still preparing or already speaking) and claim the voice."""
    for pid in read_owner():
        if pid == os.getpid():
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    write_owner(os.getpid())


def osascript(script):
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return result.stdout.strip()


def app_volume(app):
    # "is running" never launches the app.
    out = osascript(f'if application "{app}" is running then tell application "{app}" to get sound volume')
    return int(out) if out.isdigit() else None


def set_app_volume(app, volume):
    osascript(f'if application "{app}" is running then tell application "{app}" to set sound volume to {volume}')


def duck_music(factor):
    # Keep the first saved volumes when a reply interrupts another, so the restore uses the real level.
    if os.path.exists(DUCK_FILE):
        return
    original = {app: v for app in MUSIC_APPS if (v := app_volume(app)) is not None}
    with open(DUCK_FILE, "w") as f:
        json.dump(original, f)
    for app, volume in original.items():
        set_app_volume(app, round(volume * factor))


def restore_music():
    try:
        with open(DUCK_FILE) as f:
            original = json.load(f)
        os.remove(DUCK_FILE)
    except (OSError, ValueError):
        return
    for app, volume in original.items():
        set_app_volume(app, volume)


def main():
    payload = json.load(sys.stdin)
    if already_spoken(payload.get("session_id")):
        return
    text = payload.get("last_assistant_message") or last_reply_from_transcript(
        payload.get("transcript_path", "")
    )
    text = clean(text or "")
    if not text:
        return
    # The app keeps muted replies too, so they can be played later; it decides what to say.
    if send_to_app(payload, text):
        return
    if os.path.exists(MUTE_FILE) and not os.environ.get("NOTCHVOICE_SAMPLE"):
        return

    settings = load_settings()
    cmd = ["say"]
    voice = settings.get("voice") or os.environ.get("CLAUDE_TTS_VOICE")
    if voice:
        cmd += ["-v", str(voice)]
    rate = settings.get("rate") or os.environ.get("CLAUDE_TTS_RATE")
    if rate:
        cmd += ["-r", str(rate)]

    take_over()
    duck_music(music_level(settings))
    if not is_owner():
        return  # A newer reply took over while we were ducking; it restores the music.
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, text=True)
    write_owner(os.getpid(), proc.pid)
    proc.communicate(text)
    # A newer reply kills this process outright, so reaching here means we finished last.
    if is_owner():
        restore_music()
        os.remove(OWNER_FILE)

if __name__ == "__main__":
    main()
