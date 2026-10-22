#!/usr/bin/env python3
"""nv: control NotchVoice from the terminal. It talks to the app over its socket.

  nv list                      sessions, with unread counts
  nv read [session] [n]        read the latest reply, or the n-th one before it (1 is the one before the latest)
  nv history [session] [n]     print the last n replies (add --json for the raw answer)
  nv next                      read the oldest unread reply
  nv markread [session]        count a session's replies as heard without reading them; with no session, all of them
  nv skip                      go on to the next reply in the queue
  nv stop                      stop reading and empty the queue
  nv mute <session>            stop reading a session's replies; nv unmute <session> turns them back on
  nv remove <session>          forget a session and its replies (closed sessions go by themselves)
  nv focus [folder]            treat the session in this folder's git worktree as the one you're working in, as if
                               you had just written to it (for editor hooks; the folder defaults to the current one)
  nv main [session]            make a session the main one: its replies are read, the others only announced.
                               Inside Claude Code, without a session, it's that session. nv main off undoes it.
  nv say <text>                read any text; with no text, or "-", it reads standard input

A session is its name, or the start of it. Without one, nv uses the session that replied most recently
(except nv markread, which then covers every session).
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile

DARWIN_USER_TEMP_DIR = 65537  # _CS_DARWIN_USER_TEMP_DIR in <unistd.h>
COMMANDS = ("list", "read", "history", "next", "markread", "skip", "stop", "mute", "unmute", "remove", "focus", "main", "say")


def user_temp_dir():
    # The folder NSTemporaryDirectory() gives the app. TMPDIR can't be trusted for this, because tool servers started
    # by the Claude desktop app don't get it, and tempfile then falls back to /tmp.
    try:
        return os.confstr(DARWIN_USER_TEMP_DIR) or tempfile.gettempdir()
    except (OSError, ValueError):
        return tempfile.gettempdir()


SOCKET = os.path.join(user_temp_dir(), "notchvoice.sock")
# Shared with speak.py, which skips a turn's reply when Claude already read something aloud with nv in that turn.
SPOKEN_DIR = os.path.join(user_temp_dir(), "notchvoice-spoken")
SPEAKING_COMMANDS = ("say", "read", "next")


class UsageError(Exception):
    pass


def session_and_number(args):
    """[session] [n] -> (session, n). A lone number is n, so `nv read 2` works."""
    if len(args) > 2:
        raise UsageError("Give at most a session and a number.")
    if len(args) == 1 and args[0].isdigit():
        return "", int(args[0])
    if len(args) == 2 and not args[1].isdigit():
        raise UsageError(f"\"{args[1]}\" isn't a number.")
    return (args[0] if args else ""), (int(args[1]) if len(args) == 2 else None)


def request_for(command, args, stdin=sys.stdin):
    if command in ("list", "next", "skip", "stop"):
        if args:
            raise UsageError(f"nv {command} takes nothing else.")
        return {"type": command}
    if command == "read":
        session, back = session_and_number(args)
        return {"type": "read", "session": session, "back": back or 0}
    if command == "history":
        session, count = session_and_number(args)
        return {"type": "history", "session": session, **({"count": count} if count else {})}
    if command == "markread":
        if len(args) > 1:
            raise UsageError("nv markread takes one session at most.")
        return {"type": "markread", "session": args[0] if args else ""}
    if command in ("mute", "unmute", "remove"):
        if len(args) != 1:
            raise UsageError(f"nv {command} needs a session.")
        return {"type": command, "session": args[0]}
    if command == "focus":
        if len(args) > 1:
            raise UsageError("nv focus takes one folder at most.")
        return {"type": "focus", "root": worktree_root(os.path.abspath(os.path.expanduser(args[0] if args else os.getcwd())))}
    if command == "main":
        if len(args) > 1:
            raise UsageError("nv main takes one session at most.")
        if args == ["off"]:
            return {"type": "main", "off": True}
        if args:
            return {"type": "main", "session": args[0]}
        session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
        if not session_id:
            raise UsageError("Outside Claude Code, say which session: nv main <session>.")
        return {"type": "main", "session_id": session_id}
    if command == "say":
        text = " ".join(args) if args and args != ["-"] else stdin.read()
        if not text.strip():
            raise UsageError("There is nothing to say.")
        return {"type": "say", "text": text.strip()}
    raise UsageError(f"Unknown command: {command}.")


def mark_spoken():
    """Inside Claude Code, tells the Stop hook not to read this turn's reply as well."""
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not re.fullmatch(r"[\w-]+", session_id):
        return
    try:
        os.makedirs(SPOKEN_DIR, exist_ok=True)
        open(os.path.join(SPOKEN_DIR, session_id), "w").close()
    except OSError:
        pass


def worktree_root(folder):
    """The same root speak.py sends with each reply: the git worktree, or the folder itself outside git."""
    try:
        result = subprocess.run(["git", "-C", folder, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=2)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.normpath(folder)


def send(request):
    """The app's answer, or None when the app isn't running."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(SOCKET)
            connection.sendall((json.dumps(request) + "\n").encode())
            line = connection.makefile().readline()
    except OSError:
        return None
    try:
        return json.loads(line)
    except ValueError:
        return None


def describe_sessions(answer):
    sessions = answer.get("sessions") or []
    if not sessions:
        return "No session has replied yet."
    home = os.path.expanduser("~")
    width = max(len(session["name"]) for session in sessions)
    lines = []
    for session in sessions:
        cwd = session.get("cwd") or ""
        cwd = "~" + cwd[len(home):] if cwd.startswith(home + "/") else cwd
        unread = f"{session['unread']} unread" if session["unread"] else ""
        flags = "main" if session.get("main") else "muted" if session.get("muted") else ""
        lines.append("  ".join(part for part in (session["name"].ljust(width), unread.ljust(9), flags.ljust(5), cwd) if part).rstrip())
    if answer.get("speaking"):
        waiting = answer.get("waiting") or 0
        lines.append(f"\nReading {answer['speaking']}" + (f", {waiting} waiting" if waiting else ""))
    return "\n".join(lines)


def describe_history(answer):
    blocks = []
    for reply in answer.get("replies") or []:
        mark = "" if reply.get("read") else "  (unread)"
        blocks.append(f"[{reply['index']}] {reply['date']}{mark}\n{reply['text']}")
    name = answer.get("session", {}).get("name", "")
    return "\n\n".join(blocks) if blocks else f"{name} has no replies yet."


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0
    as_json = "--json" in argv
    command, args = argv[0], [arg for arg in argv[1:] if arg != "--json"]
    try:
        request = request_for(command, args)
    except UsageError as error:
        print(f"nv: {error} Run nv --help to see the commands.", file=sys.stderr)
        return 2
    answer = send(request)
    if answer is None:
        if command == "say":
            # Better heard without the app than not at all.
            mark_spoken()
            subprocess.run(["say"], input=request["text"], text=True)
            return 0
        print("nv: NotchVoice isn't running. Open it from ~/Applications.", file=sys.stderr)
        return 1
    if not answer.get("ok"):
        print(f"nv: {answer.get('error', 'Something went wrong.')}", file=sys.stderr)
        return 1
    if command in SPEAKING_COMMANDS:
        mark_spoken()
    if as_json:
        print(json.dumps(answer, indent=2))
    elif command == "list":
        print(describe_sessions(answer))
    elif command == "history":
        print(describe_history(answer))
    elif command == "read":
        print(f"Reading {answer.get('session')}.")
    elif command in ("mute", "unmute", "remove"):
        print(f"{answer.get('session')} is {command}d.")
    elif command == "markread":
        print(f"{answer['session']}'s replies are marked as read." if answer.get("session") else "All replies are marked as read.")
    elif command == "main":
        print("No main session now." if request.get("off") else f"{answer.get('session')} is the main session.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
