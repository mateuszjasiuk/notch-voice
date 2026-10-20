import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

HOOKS = Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HOOKS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


speak = load("speak")
brief = load("notchvoice_brief")
permission = load("notchvoice_permission")
mcp = load("notchvoice_mcp")
desktop = load("notchvoice_desktop")
nv = load("nv")


def run_main(module, payload):
    output = io.StringIO()
    with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(payload))), redirect_stdout(output):
        module.main()
    return output.getvalue()


def tool_use(tool_id, command):
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {"command": command}}]}}


def tool_result(tool_id):
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tool_id, "content": "ok"}]}}


class SpeakTests(unittest.TestCase):
    def test_clean_turns_markdown_into_plain_speech(self):
        text = "## Done\nSee [the guide](https://example.com/guide) and `install.sh`.\n```bash\nrm -rf build\n```\n- **one**"
        spoken = speak.clean(text)
        self.assertIn("code block omitted", spoken)
        self.assertIn("the guide", spoken)
        self.assertIn("install.sh", spoken)
        for markup in ("rm -rf", "https://", "##", "**", "`", "["):
            self.assertNotIn(markup, spoken)

    def test_music_level_prefers_settings_then_environment_then_half(self):
        self.assertEqual(speak.music_level({"duck": 0.2}), 0.2)
        self.assertEqual(speak.music_level({"duck": 3}), 1.0)
        self.assertEqual(speak.music_level({"duck": "loud"}), 0.5)
        with mock.patch.dict(os.environ, {"CLAUDE_TTS_DUCK": "0.3"}):
            self.assertEqual(speak.music_level({}), 0.3)
        with mock.patch.dict(os.environ):
            os.environ.pop("CLAUDE_TTS_DUCK", None)
            self.assertEqual(speak.music_level({}), 0.5)

    def test_load_settings_tolerates_missing_and_broken_files(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "tts_settings.json"
            with mock.patch.object(speak, "SETTINGS_FILE", str(path)):
                self.assertEqual(speak.load_settings(), {})
                path.write_text("not json")
                self.assertEqual(speak.load_settings(), {})
                path.write_text('{"voice": "Samantha", "rate": 200}')
                self.assertEqual(speak.load_settings(), {"voice": "Samantha", "rate": 200})

    def test_shares_its_files_with_the_app_whatever_tmpdir_says(self):
        app_folder = Path(os.confstr(speak.DARWIN_USER_TEMP_DIR))
        for tmpdir in (None, "/tmp/elsewhere"):
            with mock.patch.dict(os.environ):
                os.environ.pop("TMPDIR", None)
                if tmpdir:
                    os.environ["TMPDIR"] = tmpdir
                fresh_speak, fresh_permission = load("speak"), load("notchvoice_permission")
            self.assertEqual(Path(fresh_speak.OWNER_FILE).parent, app_folder)
            self.assertEqual(Path(fresh_speak.SOCKET).parent, app_folder)
            self.assertEqual(Path(fresh_permission.SOCKET).parent, app_folder)


def fake_app(path, answer=b'{"ok":true}\n'):
    """A one-request stand-in for the app's socket. Returns the thread and a list that receives the request."""
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(1)
    received = []

    def serve():
        connection, _ = server.accept()
        received.append(json.loads(connection.makefile().readline()))
        connection.sendall(answer)
        connection.close()
        server.close()

    thread = threading.Thread(target=serve)
    thread.start()
    return thread, received


class SpeakToAppTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(folder.cleanup)
        self.folder = folder.name
        self.socket_path = os.path.join(self.folder, "notch.sock")
        environment = mock.patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop("NOTCHVOICE_SESSION_NAME", None)

    def git(self, *args):
        subprocess.run(["git", "-C", self.folder, *args], check=True, capture_output=True)

    def test_session_name_comes_from_the_environment_then_the_branch_then_the_folder(self):
        project = os.path.join(self.folder, "my-project")
        os.mkdir(project)
        self.assertEqual(speak.session_name(project), "my-project")
        self.git("init", "-q", "-b", "feat/api", project)
        self.assertEqual(speak.session_name(project), "feat/api")
        os.environ["NOTCHVOICE_SESSION_NAME"] = "reviewer"
        self.assertEqual(speak.session_name(project), "reviewer")

    def test_a_detached_head_falls_back_to_the_worktree_folder(self):
        project = os.path.join(self.folder, "worktree-b")
        os.mkdir(project)
        self.git("init", "-q", project)
        subprocess.run(["git", "-C", project, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"], check=True)
        subprocess.run(["git", "-C", project, "checkout", "-q", "--detach"], check=True)
        os.mkdir(os.path.join(project, "src"))
        self.assertEqual(speak.session_name(os.path.join(project, "src")), "worktree-b")

    def test_desktop_chats_share_one_session(self):
        self.assertEqual(speak.session_name(None), "Claude chat")

    def test_sends_the_reply_to_the_app(self):
        thread, received = fake_app(self.socket_path)
        with mock.patch.object(speak, "SOCKET", self.socket_path):
            sent = speak.send_to_app({"session_id": "abc", "cwd": self.folder}, "Hello")
        thread.join()
        self.assertTrue(sent)
        message = received[0]
        self.assertEqual(message["type"], "reply")
        self.assertEqual(message["session_id"], "abc")
        self.assertEqual(message["text"], "Hello")
        self.assertEqual(message["cwd"], self.folder)
        self.assertEqual(message["root"], self.folder)
        self.assertIsInstance(message["timestamp"], float)

    def test_without_the_app_nothing_is_sent(self):
        with mock.patch.object(speak, "SOCKET", self.socket_path):
            self.assertFalse(speak.send_to_app({"session_id": "abc"}, "Hello"))

    def test_the_app_speaks_so_the_hook_does_not(self):
        with mock.patch.object(speak, "send_to_app", return_value=True) as send, mock.patch.object(speak.subprocess, "Popen") as popen:
            run_main(speak, {"session_id": "abc", "last_assistant_message": "**Done.**"})
        self.assertEqual(send.call_args.args[1], "Done.")
        popen.assert_not_called()

    def test_muted_replies_still_reach_the_app_but_are_not_spoken_without_it(self):
        mute_file = Path(self.folder) / "tts_off"
        mute_file.touch()
        with mock.patch.object(speak, "MUTE_FILE", str(mute_file)), mock.patch.object(speak, "send_to_app", return_value=False) as send, \
                mock.patch.object(speak.subprocess, "Popen") as popen:
            run_main(speak, {"session_id": "abc", "last_assistant_message": "Done."})
        send.assert_called_once()
        popen.assert_not_called()


class NvTests(unittest.TestCase):
    def run_nv(self, *argv, answer=None):
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(nv, "send", return_value=answer) as send, redirect_stdout(output), mock.patch.object(sys, "stderr", errors):
            code = nv.main(list(argv))
        return code, output.getvalue(), errors.getvalue(), send

    def test_commands_become_requests(self):
        self.assertEqual(nv.request_for("list", []), {"type": "list"})
        self.assertEqual(nv.request_for("read", []), {"type": "read", "session": "", "back": 0})
        self.assertEqual(nv.request_for("read", ["api"]), {"type": "read", "session": "api", "back": 0})
        self.assertEqual(nv.request_for("read", ["api", "2"]), {"type": "read", "session": "api", "back": 2})
        self.assertEqual(nv.request_for("read", ["1"]), {"type": "read", "session": "", "back": 1})
        self.assertEqual(nv.request_for("history", ["api", "3"]), {"type": "history", "session": "api", "count": 3})
        self.assertEqual(nv.request_for("mute", ["web"]), {"type": "mute", "session": "web"})
        self.assertEqual(nv.request_for("say", ["hello", "there"]), {"type": "say", "text": "hello there"})

    def test_main_picks_this_session_inside_claude_code_or_a_named_one(self):
        with mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "abc-123"}):
            self.assertEqual(nv.request_for("main", []), {"type": "main", "session_id": "abc-123"})
        self.assertEqual(nv.request_for("main", ["api"]), {"type": "main", "session": "api"})
        self.assertEqual(nv.request_for("main", ["off"]), {"type": "main", "off": True})
        with mock.patch.dict(os.environ):
            os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
            with self.assertRaises(nv.UsageError):
                nv.request_for("main", [])

    def test_focus_sends_the_worktree_of_a_folder_so_subfolders_match(self):
        with tempfile.TemporaryDirectory() as folder:
            project = os.path.realpath(os.path.join(folder, "worktree-a"))
            os.makedirs(os.path.join(project, "apps"))
            subprocess.run(["git", "init", "-q", project], check=True)
            self.assertEqual(nv.request_for("focus", [os.path.join(project, "apps")]), {"type": "focus", "root": project})
            outside = os.path.realpath(folder)
            self.assertEqual(nv.request_for("focus", [outside]), {"type": "focus", "root": outside})
            # speak.py sends the same root with each reply, so the two meet in the app.
            self.assertEqual(speak.worktree_root(os.path.join(project, "apps")), project)

    def test_say_reads_standard_input_without_text(self):
        self.assertEqual(nv.request_for("say", ["-"], stdin=io.StringIO("from a pipe\n")), {"type": "say", "text": "from a pipe"})
        self.assertEqual(nv.request_for("say", [], stdin=io.StringIO("piped")), {"type": "say", "text": "piped"})

    def test_mistakes_are_explained_and_nothing_is_sent(self):
        for argv in (["mute"], ["read", "api", "x"], ["skip", "now"], ["dance"]):
            code, _, errors, send = self.run_nv(*argv)
            self.assertEqual(code, 2)
            self.assertIn("nv --help", errors)
            send.assert_not_called()

    def test_errors_from_the_app_are_shown(self):
        code, _, errors, _ = self.run_nv("read", "x", answer={"ok": False, "error": 'No session matches "x".'})
        self.assertEqual(code, 1)
        self.assertIn('No session matches "x".', errors)

    def test_without_the_app_say_still_speaks(self):
        with mock.patch.object(nv.subprocess, "run") as run:
            code, _, _, _ = self.run_nv("say", "hello")
        self.assertEqual(code, 0)
        self.assertEqual(run.call_args.kwargs["input"], "hello")
        code, _, errors, _ = self.run_nv("list")
        self.assertEqual(code, 1)
        self.assertIn("isn't running", errors)

    def test_list_shows_unread_counts_and_what_is_being_read(self):
        answer = {"ok": True, "speaking": "api", "waiting": 1, "sessions": [
            {"name": "api", "unread": 2, "muted": False, "cwd": os.path.expanduser("~/work/api")},
            {"name": "web-frontend", "unread": 0, "muted": True, "cwd": "/srv/web"},
        ]}
        _, output, _, _ = self.run_nv("list", answer=answer)
        lines = output.splitlines()
        self.assertTrue(lines[0].startswith("api           2 unread"))
        self.assertIn("~/work/api", lines[0])
        self.assertIn("muted", lines[1])
        self.assertIn("Reading api, 1 waiting", output)

    def test_history_prints_each_reply_with_its_number(self):
        answer = {"ok": True, "session": {"name": "api"}, "replies": [
            {"index": 0, "text": "Latest.", "date": "2026-10-20T10:00:00Z", "read": False},
            {"index": 1, "text": "Earlier.", "date": "2026-10-20T09:00:00Z", "read": True},
        ]}
        _, output, _, _ = self.run_nv("history", "api", answer=answer)
        self.assertIn("[0] 2026-10-20T10:00:00Z  (unread)\nLatest.", output)
        self.assertIn("[1] 2026-10-20T09:00:00Z\nEarlier.", output)
        _, output, _, _ = self.run_nv("history", "api", "--json", answer=answer)
        self.assertEqual(json.loads(output), answer)

    def test_talks_to_the_app_over_its_socket(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as folder:
            path = os.path.join(folder, "notch.sock")
            thread, received = fake_app(path, b'{"ok":true,"session":"api"}\n')
            with mock.patch.object(nv, "SOCKET", path):
                answer = nv.send({"type": "read", "session": "api", "back": 0})
            thread.join()
        self.assertEqual(received, [{"type": "read", "session": "api", "back": 0}])
        self.assertEqual(answer, {"ok": True, "session": "api"})


class AlreadySpokenTests(unittest.TestCase):
    """/read: when Claude reads something aloud with nv, the Stop hook must not read that turn's reply too."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.spoken_dir = os.path.join(folder.name, "spoken")
        for module in (speak, nv, brief):
            patcher = mock.patch.object(module, "SPOKEN_DIR", self.spoken_dir)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = mock.patch.object(brief, "tell_app_focus")
        patcher.start()
        self.addCleanup(patcher.stop)

    def nv_in_session(self, *argv, session_id="abc-123"):
        with mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": session_id}), \
                mock.patch.object(nv, "send", return_value={"ok": True, "session": "api"}), redirect_stdout(io.StringIO()):
            return nv.main(list(argv))

    def test_the_stop_hook_skips_a_turn_where_nv_spoke_but_only_that_turn(self):
        self.nv_in_session("say", "The migration part.")
        with mock.patch.object(speak, "send_to_app", return_value=True) as send:
            run_main(speak, {"session_id": "abc-123", "last_assistant_message": "Read it."})
            send.assert_not_called()
            run_main(speak, {"session_id": "abc-123", "last_assistant_message": "Next turn."})
            send.assert_called_once()

    def test_other_sessions_are_still_read(self):
        self.nv_in_session("read", "api")
        with mock.patch.object(speak, "send_to_app", return_value=True) as send:
            run_main(speak, {"session_id": "other", "last_assistant_message": "Hi."})
        send.assert_called_once()

    def test_commands_that_say_nothing_leave_no_marker(self):
        self.nv_in_session("list")
        self.nv_in_session("mute", "api")
        self.assertFalse(os.path.exists(self.spoken_dir) and os.listdir(self.spoken_dir))

    def test_outside_claude_code_nv_leaves_no_marker(self):
        with mock.patch.dict(os.environ), mock.patch.object(nv, "send", return_value={"ok": True}), redirect_stdout(io.StringIO()):
            os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
            nv.main(["say", "hello"])
        self.assertFalse(os.path.exists(self.spoken_dir))

    def test_odd_session_ids_never_become_paths(self):
        self.nv_in_session("say", "hi", session_id="../escape")
        self.assertFalse(os.path.exists(self.spoken_dir))
        self.assertFalse(speak.already_spoken("../escape"))

    def test_a_new_prompt_clears_a_marker_left_by_an_interrupted_turn(self):
        self.nv_in_session("say", "hi")
        run_main(brief, {"session_id": "abc-123", "prompt": "next question"})
        self.assertFalse(speak.already_spoken("abc-123"))


class BriefTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(brief, "SOCKET", "/nonexistent/notchvoice.sock")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_tells_the_app_which_session_the_user_is_working_in(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as folder:
            path = os.path.join(folder, "notch.sock")
            thread, received = fake_app(path)
            with mock.patch.object(brief, "SOCKET", path), redirect_stdout(io.StringIO()):
                run_main(brief, {"session_id": "abc", "prompt": "hello"})
            thread.join()
        self.assertEqual(received, [{"type": "focus", "session_id": "abc"}])

    def test_a_background_task_waking_the_session_does_not_move_the_focus(self):
        prompt = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"
        with mock.patch.object(brief, "tell_app_focus") as tell:
            self.assertIn("read aloud", run_main(brief, {"session_id": "abc", "prompt": prompt}))
            tell.assert_not_called()
            run_main(brief, {"session_id": "abc", "prompt": "what about <task-notification>?"})
            tell.assert_called_once_with("abc")

    def test_without_the_app_the_prompt_goes_through_quickly(self):
        started = time.monotonic()
        self.assertIn("read aloud", run_main(brief, {"session_id": "abc", "prompt": "hello"}))
        self.assertLess(time.monotonic() - started, 0.3)

    def run_hook(self, settings=None, muted=False):
        with tempfile.TemporaryDirectory() as folder:
            settings_file = Path(folder) / "tts_settings.json"
            mute_file = Path(folder) / "tts_off"
            if settings is not None:
                settings_file.write_text(settings)
            if muted:
                mute_file.touch()
            with mock.patch.object(brief, "SETTINGS_FILE", str(settings_file)), mock.patch.object(brief, "MUTE_FILE", str(mute_file)):
                return run_main(brief, {"prompt": "hello"})

    def test_reminds_claude_by_default(self):
        output = json.loads(self.run_hook())["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "UserPromptSubmit")
        self.assertIn("read aloud", output["additionalContext"])

    def test_adds_nothing_while_voice_replies_are_muted(self):
        self.assertEqual(self.run_hook(muted=True), "")

    def test_adds_nothing_when_short_replies_are_turned_off(self):
        self.assertEqual(self.run_hook(settings='{"brief": false}'), "")

    def test_a_broken_settings_file_keeps_the_reminder(self):
        self.assertNotEqual(self.run_hook(settings="not json"), "")


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.folder.name, "transcript.jsonl")
        Path(self.path).touch()

    def tearDown(self):
        self.folder.cleanup()

    def write(self, *entries):
        with open(self.path, "a") as f:
            for entry in entries:
                f.write(json.dumps(entry) + "\n")

    def test_notices_when_the_pending_call_gets_a_result(self):
        self.write(tool_use("t1", "make"))
        transcript = permission.Transcript(self.path, "Bash", {"command": "make"})
        self.assertEqual(transcript.tool_use_id, "t1")
        self.assertFalse(transcript.answered_elsewhere())
        self.write(tool_result("t1"))
        self.assertTrue(transcript.answered_elsewhere())

    def test_ignores_an_earlier_identical_call_that_was_already_answered(self):
        self.write(tool_use("old", "make"), tool_result("old"), tool_use("new", "make"))
        transcript = permission.Transcript(self.path, "Bash", {"command": "make"})
        self.assertEqual(transcript.tool_use_id, "new")
        self.assertFalse(transcript.answered_elsewhere())

    def test_picks_up_a_call_written_after_the_hook_started(self):
        self.write(tool_use("old", "make"), tool_result("old"))
        transcript = permission.Transcript(self.path, "Bash", {"command": "make"})
        self.assertIsNone(transcript.tool_use_id)
        self.write(tool_use("new", "make"))
        self.assertFalse(transcript.answered_elsewhere())
        self.assertEqual(transcript.tool_use_id, "new")
        self.write(tool_result("new"))
        self.assertTrue(transcript.answered_elsewhere())

    def test_a_missing_transcript_never_counts_as_answered(self):
        self.assertFalse(permission.Transcript(None, "Bash", {"command": "make"}).answered_elsewhere())


class PermissionHookTests(unittest.TestCase):
    def test_without_the_app_there_is_no_decision(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(permission, "SOCKET", os.path.join(folder, "missing.sock")):
            self.assertIsNone(permission.ask_notch({"tool_name": "Bash"}, permission.Transcript(None, "Bash", {})))

    def test_returns_the_answer_given_in_the_notch(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as folder:
            path = os.path.join(folder, "notch.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)

            def answer():
                connection, _ = server.accept()
                connection.makefile().readline()
                connection.sendall(b'{"decision":"allow"}\n')
                connection.close()

            thread = threading.Thread(target=answer)
            thread.start()
            with mock.patch.object(permission, "SOCKET", path):
                decision = permission.ask_notch({"tool_name": "Bash"}, permission.Transcript(None, "Bash", {}))
            thread.join()
            server.close()
            self.assertEqual(decision, "allow")

    def test_prints_allow_and_deny_decisions_for_claude_code(self):
        for decision, behavior in (("allow", "allow"), ("deny", "deny")):
            with mock.patch.object(permission, "ask_notch", return_value=decision):
                output = json.loads(run_main(permission, {"tool_name": "Bash", "tool_input": {"command": "ls"}}))
            self.assertEqual(output["hookSpecificOutput"]["hookEventName"], "PermissionRequest")
            self.assertEqual(output["hookSpecificOutput"]["decision"]["behavior"], behavior)

    def test_a_dismissed_request_leaves_the_decision_to_claude_code(self):
        with mock.patch.object(permission, "ask_notch", return_value="ask"):
            self.assertEqual(run_main(permission, {"tool_name": "Bash", "tool_input": {"command": "ls"}}), "")

    def test_questions_and_plan_approvals_never_reach_the_notch(self):
        for tool in ("AskUserQuestion", "ExitPlanMode"):
            with mock.patch.object(permission, "ask_notch") as ask_notch:
                self.assertEqual(run_main(permission, {"tool_name": tool}), "")
            ask_notch.assert_not_called()

    def test_long_inputs_are_trimmed_before_they_are_sent(self):
        value = permission.trimmed({"content": "x" * 5000, "items": list(range(100))})
        self.assertEqual(len(value["content"]), permission.MAX_TEXT + 1)
        self.assertEqual(len(value["items"]), 50)


class SpeakToolTests(unittest.TestCase):
    def test_regular_chats_get_the_speak_tool_and_instructions(self):
        with mock.patch.object(mcp, "IN_CLAUDE_CODE", False):
            started = mcp.result_for("initialize", {"protocolVersion": "2025-03-26"})
            self.assertEqual(started["protocolVersion"], "2025-03-26")
            self.assertIn("speak tool", started["instructions"])
            self.assertIn("If you are Claude Code, never call it", started["instructions"])
            self.assertEqual([tool["name"] for tool in mcp.result_for("tools/list", {})["tools"]], ["speak"])

    def test_claude_code_gets_nothing_because_its_stop_hook_already_speaks(self):
        with mock.patch.object(mcp, "IN_CLAUDE_CODE", True):
            self.assertNotIn("instructions", mcp.result_for("initialize", {}))
            self.assertEqual(mcp.result_for("tools/list", {}), {"tools": []})
            self.assertIsNone(mcp.result_for("tools/call", {"name": "speak", "arguments": {"text": "hi"}}))

    def test_speak_passes_the_text_on(self):
        with mock.patch.object(mcp, "IN_CLAUDE_CODE", False), mock.patch.object(mcp, "speak", return_value="Speaking.") as speak_call:
            result = mcp.result_for("tools/call", {"name": "speak", "arguments": {"text": "  Hello  "}})
        speak_call.assert_called_once_with("Hello")
        self.assertEqual(result["content"][0]["text"], "Speaking.")

    def test_speaking_nothing_is_an_error(self):
        with mock.patch.object(mcp, "IN_CLAUDE_CODE", False):
            self.assertTrue(mcp.result_for("tools/call", {"name": "speak", "arguments": {}})["isError"])

    def test_nothing_is_spoken_while_voice_replies_are_muted(self):
        with tempfile.TemporaryDirectory() as folder:
            mute_file = Path(folder) / "tts_off"
            mute_file.touch()
            with mock.patch.object(mcp, "MUTE_FILE", str(mute_file)), mock.patch.object(mcp.subprocess, "Popen") as popen:
                self.assertIn("off", mcp.speak("hi"))
            popen.assert_not_called()

    def test_notifications_get_no_reply_and_unknown_requests_get_an_error(self):
        output = io.StringIO()
        with redirect_stdout(output):
            mcp.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
            mcp.handle({"jsonrpc": "2.0", "id": 7, "method": "resources/list"})
        replies = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0]["error"]["code"], -32601)


class DesktopConfigTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.config = Path(folder.name) / "claude_desktop_config.json"
        self.server = Path(folder.name) / "notchvoice_mcp.py"
        self.server.touch()
        self.config.write_text(json.dumps({"preferences": {"theme": "dark"}, "mcpServers": {"other": {"command": "other"}}}))

    def sync(self):
        return desktop.sync(str(self.config), str(self.server))

    def read(self):
        return json.loads(self.config.read_text())

    def test_adds_the_speak_tool_and_keeps_everything_else(self):
        self.assertEqual(self.sync(), "added")
        config = self.read()
        self.assertEqual(config["mcpServers"]["notchvoice"], {"command": "/usr/bin/python3", "args": [str(self.server)]})
        self.assertEqual(config["mcpServers"]["other"], {"command": "other"})
        self.assertEqual(config["preferences"], {"theme": "dark"})
        self.assertNotIn("notchvoice", json.loads(Path(f"{self.config}.bak").read_text())["mcpServers"])

    def test_takes_the_speak_tool_out_once_it_is_uninstalled(self):
        self.sync()
        self.server.unlink()
        self.assertEqual(self.sync(), "removed")
        self.assertEqual(self.read()["mcpServers"], {"other": {"command": "other"}})

    def test_leaves_a_config_that_already_matches_untouched(self):
        self.sync()
        written = self.config.read_text()
        self.assertIsNone(self.sync())
        self.assertEqual(self.config.read_text(), written)

    def test_never_overwrites_a_config_it_cannot_read(self):
        self.config.write_text("{ not json")
        with self.assertRaises(ValueError):
            self.sync()
        self.assertEqual(self.config.read_text(), "{ not json")

    def test_does_nothing_without_the_desktop_app(self):
        missing = self.config.parent / "Claude" / "claude_desktop_config.json"
        self.assertIsNone(desktop.sync(str(missing), str(self.server)))
        self.assertFalse(missing.parent.exists())

    def test_finds_the_desktop_app_but_not_claude_code(self):
        processes = (
            "  101 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper\n"
            "  102 /Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude\n"
        )
        with mock.patch.object(desktop.subprocess, "run", return_value=mock.Mock(stdout=processes)):
            self.assertIsNone(desktop.desktop_app_pid())
        with mock.patch.object(desktop.subprocess, "run", return_value=mock.Mock(stdout=processes + "  100 /Applications/Claude.app/Contents/MacOS/Claude\n")):
            self.assertEqual(desktop.desktop_app_pid(), 100)

    def test_while_the_app_is_open_the_edit_is_made_again_after_it_quits(self):
        with mock.patch.object(sys, "argv", ["notchvoice_desktop.py"]), mock.patch.object(desktop, "sync", return_value="added"), \
                mock.patch.object(desktop, "desktop_app_pid", return_value=100), mock.patch.object(desktop.subprocess, "Popen") as popen, \
                redirect_stdout(io.StringIO()) as output:
            desktop.main()
        self.assertEqual(popen.call_args.args[0][-1], "--after-quit")
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertIn("Quit the Claude desktop app", output.getvalue())

        with mock.patch.object(sys, "argv", ["notchvoice_desktop.py", "--after-quit"]), \
                mock.patch.object(desktop, "desktop_app_pid", side_effect=[100, 200, None]), \
                mock.patch.object(desktop, "wait_for_exit") as wait, mock.patch.object(desktop, "sync") as sync:
            desktop.main()
        self.assertEqual([call.args[0] for call in wait.call_args_list], [100, 200])
        sync.assert_called_once_with()

    def test_waiting_ends_as_soon_as_the_app_quits(self):
        app = subprocess.Popen(["sleep", "0.3"])
        started = time.monotonic()
        desktop.wait_for_exit(app.pid)
        self.assertLess(time.monotonic() - started, 0.9)
        app.wait()


if __name__ == "__main__":
    unittest.main()
