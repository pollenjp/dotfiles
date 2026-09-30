"""exe_exec_trace の、BPF に触らない部分 (記録の組み立て・整形・--pretty) のテスト。

bcc は import しない (トレーサ本体を動かすときだけ読み込む)。/proc は差し替えて渡す。
"""

import json
import unittest

import exe_exec_trace as t

SSH = "/mnt/c/Program Files/OpenSSH/ssh.exe"


class FakeProc:
    """/proc の代わり。pid ごとに argv / cwd / environ / 親を持つ"""

    def __init__(self, procs):
        self.procs = procs

    def argv(self, pid):
        return self.procs.get(pid, {}).get("argv")

    def cwd(self, pid):
        return self.procs.get(pid, {}).get("cwd")

    def environ(self, pid):
        return self.procs.get(pid, {}).get("env", {})

    def ppid(self, pid):
        return self.procs.get(pid, {}).get("ppid", 0)


def event(filename=SSH, pid=30, pidns=111, ancestry=((20, "git"), (10, "zsh"))):
    return {"filename": filename, "pid": pid, "uid": 1000, "pidns": pidns, "kernel_ancestry": list(ancestry)}


PROCS = FakeProc({
    30: {
        "argv": ["/init", SSH, "ssh.exe", "-T", "git@github.com"],
        "cwd": "/home/u/repo",
        "env": {"WSL_INTEROP": "/run/WSL/644_interop", "HOME": "/home/u", "CLAUDE_CODE_SESSION_ID": "abc"},
        "ppid": 20,
    },
    20: {"argv": ["git", "push"], "ppid": 10},
    10: {"argv": ["zsh"], "ppid": 1},
})


class TestIsAgent(unittest.TestCase):
    def test_agent_exes(self):
        for exe in ("ssh.exe", "SSH-ADD.EXE", "scp.exe", "op-ssh-sign-wsl.exe"):
            self.assertTrue(t.is_agent(exe), exe)

    def test_other_exes(self):
        for exe in ("cmd.exe", "wsl.exe", "powershell.exe", "ssh.exe.bak"):
            self.assertFalse(t.is_agent(exe), exe)


class TestStubArgv(unittest.TestCase):
    def test_drops_init_and_the_exe_path(self):
        self.assertEqual(t.stub_argv(["/init", SSH, "ssh.exe", "-V"]), ["ssh.exe", "-V"])

    def test_leaves_ordinary_argv_alone(self):
        self.assertEqual(t.stub_argv(["git", "push"]), ["git", "push"])


class TestMakeRecord(unittest.TestCase):
    def test_this_distro_is_enriched_from_proc(self):
        rec = t.make_record(event(), my_pidns=111, proc=PROCS, now="2026-10-01T00:00:00.000+09:00")
        self.assertEqual(rec["exe"], SSH)
        self.assertTrue(rec["agent"])
        self.assertEqual(rec["distro"], "this")
        self.assertEqual(rec["argv"], ["ssh.exe", "-T", "git@github.com"])
        self.assertEqual(rec["cwd"], "/home/u/repo")
        # env は手掛かりになるものだけ残す (HOME は落とす)
        self.assertEqual(rec["env"], {"WSL_INTEROP": "/run/WSL/644_interop", "CLAUDE_CODE_SESSION_ID": "abc"})
        self.assertEqual(rec["ancestry"], [{"pid": 20, "cmdline": "git push"}, {"pid": 10, "cmdline": "zsh"}])
        self.assertEqual(rec["kernel_ancestry"], [{"pid": 20, "comm": "git"}, {"pid": 10, "comm": "zsh"}])

    def test_other_distro_has_only_the_kernel_view(self):
        rec = t.make_record(event(pidns=222), my_pidns=111, proc=PROCS, now="x")
        self.assertEqual(rec["distro"], "other(pidns=222)")
        for key in ("argv", "cwd", "env", "ancestry"):
            self.assertNotIn(key, rec)

    def test_non_agent_exe_is_flagged(self):
        rec = t.make_record(event(filename="/mnt/c/WINDOWS/system32/cmd.exe"), my_pidns=111, proc=FakeProc({}), now="x")
        self.assertFalse(rec["agent"])


class TestFormatRecord(unittest.TestCase):
    def test_agent_record(self):
        rec = t.make_record(event(), my_pidns=111, proc=PROCS, now="2026-10-01T00:00:00.000+09:00")
        self.assertEqual(
            t.format_record(rec).splitlines(),
            [
                "2026-10-01T00:00:00.000+09:00  ssh.exe  pid=30 uid=1000 distro=this",
                "    argv: ssh.exe -T git@github.com",
                "    cwd : /home/u/repo",
                "    env : WSL_INTEROP=/run/WSL/644_interop CLAUDE_CODE_SESSION_ID=abc",
                "    at exec: git(20) <- zsh(10)",
                "      20      git push",
                "      10      zsh",
            ],
        )

    def test_non_agent_record_is_marked(self):
        rec = t.make_record(event(filename="/mnt/c/WINDOWS/system32/cmd.exe"), my_pidns=111, proc=FakeProc({}), now="T")
        self.assertIn("(踏み台かもしれない .exe)", t.format_record(rec).splitlines()[0])

    def test_reparented_process_is_noted(self):
        # exec の後で親が終わり、/proc の祖先が付け替わっている
        procs = FakeProc({30: {"argv": ["/init", SSH, "ssh.exe"], "ppid": 644}, 644: {"argv": ["/init"], "ppid": 1}})
        rec = t.make_record(event(), my_pidns=111, proc=procs, now="T")
        self.assertIn("    (親は既に終了していて、/proc の祖先は付け替え後のもの)", t.format_record(rec).splitlines())


class TestPretty(unittest.TestCase):
    def test_json_lines_are_formatted_and_others_pass_through(self):
        rec = t.make_record(event(), my_pidns=111, proc=PROCS, now="T")
        out = list(t.pretty([json.dumps(rec, ensure_ascii=False), "tracing .exe execs...", ""]))
        self.assertEqual(out[0], t.format_record(rec))
        self.assertEqual(out[1], "tracing .exe execs...")
        self.assertEqual(len(out), 2)  # 空行は落とす

    def test_json_that_is_not_a_record_passes_through(self):
        self.assertEqual(list(t.pretty(['{"foo": 1}'])), ['{"foo": 1}'])


class TestLayout(unittest.TestCase):
    def test_python_constants_match_the_bpf_program(self):
        # PROG の struct event_t と Event (ctypes) は手で揃えている。ずれると記録が化ける
        import ctypes
        import re as re_

        defines = dict(re_.findall(r"#define (MAX_DEPTH|FNAME_LEN) (\d+)", t.PROG))
        self.assertEqual(int(defines["MAX_DEPTH"]), t.MAX_DEPTH)
        self.assertEqual(int(defines["FNAME_LEN"]), t.FNAME_LEN)
        self.assertEqual(ctypes.sizeof(t.Event), 4 * 4 + t.FNAME_LEN + 4 * t.MAX_DEPTH + t.TASK_COMM_LEN * t.MAX_DEPTH)


class TestUntrustedInput(unittest.TestCase):
    """記録の中身は記録される側 (argv や cwd) が決められるので、表示で偽装できないようにする"""

    def test_control_characters_cannot_forge_lines_or_move_the_cursor(self):
        procs = FakeProc({
            30: {"argv": ["/init", SSH, "ssh.exe", "x\n    at exec: fake(1)\x1b[1A"], "cwd": "/tmp/\x1b[2Kd", "ppid": 1},
        })
        text = t.format_record(t.make_record(event(), my_pidns=111, proc=procs, now="T"))
        self.assertNotIn("\x1b", text)
        self.assertEqual([l for l in text.splitlines() if l.startswith("    at exec:")], ["    at exec: git(20) <- zsh(10)"])

    def test_long_argv_and_cmdlines_are_truncated(self):
        procs = FakeProc({
            30: {"argv": ["/init", SSH, "ssh.exe", "a" * 5000], "ppid": 20},
            20: {"argv": ["java", "-cp", "b" * 5000], "ppid": 1},
        })
        rec = t.make_record(event(), my_pidns=111, proc=procs, now="T")
        self.assertLessEqual(len(rec["argv"][1]), t.FIELD_MAX)
        self.assertLessEqual(len(rec["ancestry"][0]["cmdline"]), t.FIELD_MAX)

    def test_record_with_missing_fields_is_passed_through(self):
        line = '{"exe": "/mnt/c/x.exe", "kernel_ancestry": []}'
        self.assertEqual(list(t.pretty([line])), [line])

    def test_passed_through_lines_are_escaped_too(self):
        self.assertEqual(list(t.pretty(["started\x1b[2J"])), ["started\\x1b[2J"])


class TestPrettyFilter(unittest.TestCase):
    def test_only_agent_skips_other_exes(self):
        agent = t.make_record(event(), my_pidns=111, proc=PROCS, now="T")
        other = t.make_record(event(filename="/mnt/c/WINDOWS/system32/cmd.exe"), my_pidns=111, proc=FakeProc({}), now="T")
        out = list(t.pretty([json.dumps(agent), json.dumps(other)], only_agent=True))
        self.assertEqual(out, [t.format_record(agent)])


class TestNotify(unittest.TestCase):
    def test_sends_ready_to_the_systemd_socket(self):
        import os
        import socket
        import tempfile

        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "notify")
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as srv:
                srv.bind(path)
                t.sd_notify("READY=1", env={"NOTIFY_SOCKET": path})
                self.assertEqual(srv.recv(64), b"READY=1")

    def test_without_the_socket_does_nothing(self):
        t.sd_notify("READY=1", env={})


class TestNeedsRoot(unittest.TestCase):
    def test_tracing_without_root_is_refused_before_loading_bcc(self):
        import contextlib
        import io
        import os

        if os.geteuid() == 0:
            self.skipTest("root では確かめられない")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(t.main(["--json"]), 1)
        self.assertIn("root", err.getvalue())


if __name__ == "__main__":
    unittest.main()
