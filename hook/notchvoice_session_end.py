#!/usr/bin/env python3
"""SessionEnd hook: tell the NotchVoice app that this Claude Code session closed, so it leaves the notch and nv list.

Its replies, unread count and place in the queue go with it. If the session writes again later, for example after
--resume, it shows up again as a new session. Without the app, this does nothing.
"""
import json
import os
import socket
import sys
import tempfile

DARWIN_USER_TEMP_DIR = 65537  # _CS_DARWIN_USER_TEMP_DIR in <unistd.h>


def user_temp_dir():
    # The folder NSTemporaryDirectory() gives the app. TMPDIR can't be trusted for this, because tool servers started
    # by the Claude desktop app don't get it, and tempfile then falls back to /tmp.
    try:
        return os.confstr(DARWIN_USER_TEMP_DIR) or tempfile.gettempdir()
    except (OSError, ValueError):
        return tempfile.gettempdir()


SOCKET = os.path.join(user_temp_dir(), "notchvoice.sock")


def tell_app_removed(session_id):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(1)
            connection.connect(SOCKET)
            connection.sendall((json.dumps({"type": "remove", "session_id": session_id}) + "\n").encode())
            connection.recv(256)
    except OSError:
        pass


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    session_id = payload.get("session_id") if isinstance(payload, dict) else None
    if isinstance(session_id, str) and session_id:
        tell_app_removed(session_id)


if __name__ == "__main__":
    main()
