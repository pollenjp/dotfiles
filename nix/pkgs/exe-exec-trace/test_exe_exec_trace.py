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


if __name__ == "__main__":
    unittest.main()
