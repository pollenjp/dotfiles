"""who_is_asking の対の取り方と木の組み立てのテスト。

データは TKT-54 の実機 (2026-09-30) で見たプロセス表を縮めたもの。
/proc と powershell.exe には触らない (Linux 側の祖先は linux_nodes を差し替えて渡す)。
"""

import unittest

import who_is_asking as w

T = 1_790_748_000_000  # 基準の時刻 (epoch ms)

TAB_WSL = '"C:\\Windows\\system32\\wsl.exe" -d Ubuntu-24.04'


def proc(pid, ppid, name, cmd, t):
    return {"pid": pid, "ppid": ppid, "name": name, "cmd": cmd, "t": t}


def tab():
    """Windows Terminal のタブで wsl.exe を開いたところまで (どの場面にも共通)"""
    return {
        56244: proc(56244, 16128, "explorer.exe", "C:\\WINDOWS\\Explorer.EXE", T - 900_000),
        48512: proc(
            48512, 56244, "WindowsTerminal.exe",
            '"C:\\Program Files\\WindowsApps\\Microsoft.WindowsTerminal_1.24.11911.0_x64__8wekyb3d8bbwe\\WindowsTerminal.exe" ',
            T - 800_000,
        ),
        17080: proc(17080, 48512, "pwsh.exe", '"C:\\Program Files\\PowerShell\\7\\pwsh.exe"', T - 700_000),
        33416: proc(33416, 17080, "wsl.exe", TAB_WSL, T - 600_000),
        23720: proc(23720, 33416, "wsl.exe", TAB_WSL, T - 600_000),
    }


def stub(name, args, t):
    return {"name": name, "args": args, "t": t}


def fake_linux(chains):
    """代理プロセスの PID から、根から順の Linux 側の節の列を返す関数を作る"""

    def linux_nodes(pid):
        return [("L", p, label, None) for p, label in chains[pid]]

    return linux_nodes


def pids(nodes):
    return [(os_, pid) for os_, pid, _, _ in nodes]


class TestWinLabel(unittest.TestCase):
    def test_quoted_path_becomes_exe_name(self):
        self.assertEqual(w.win_label(proc(1, 0, "pwsh.exe", '"C:\\Program Files\\PowerShell\\7\\pwsh.exe"', 0)), "pwsh.exe")

    def test_unquoted_path_without_args(self):
        self.assertEqual(w.win_label(proc(1, 0, "explorer.exe", "C:\\WINDOWS\\Explorer.EXE", 0)), "explorer.exe")

    def test_unquoted_path_with_spaces_keeps_args(self):
        p = proc(1, 0, "foo.exe", "C:\\Program Files\\X\\foo.exe -a b", 0)
        self.assertEqual(w.win_label(p), "foo.exe -a b")

    def test_no_command_line_falls_back_to_name(self):
        self.assertEqual(w.win_label(proc(1, 0, "System", "", 0)), "System")


class TestIsHost(unittest.TestCase):
    def test_inner_wsl_exe_owns_the_session(self):
        procs = tab()
        self.assertTrue(w.is_host(procs[23720], procs))

    def test_outer_wsl_exe_does_not(self):
        procs = tab()
        self.assertFalse(w.is_host(procs[33416], procs))

    def test_wslhost_exe_is_treated_as_owner(self):
        procs = {9: proc(9, 1, "wslhost.exe", "wslhost.exe --distro-id {x}", 0)}
        self.assertTrue(w.is_host(procs[9], procs))


class TestPairUp(unittest.TestCase):
    def test_direct_call_pairs_ssh_exe_with_its_stub(self):
        procs = tab()
        procs[61704] = proc(
            61704, 23720, "ssh.exe",
            "ssh.exe -o SendEnv=GIT_PROTOCOL fake@192.0.2.1 \"git-upload-pack '/pollenjp/example.git'\"", T + 500,
        )
        stubs = {113719: stub("ssh.exe", "-o SendEnv=GIT_PROTOCOL fake@192.0.2.1 git-upload-pack '/pollenjp/example.git'", T)}
        self.assertEqual(w.pair_up(procs, stubs), {61704: 113719})

    def test_only_children_of_the_session_owner_are_paired(self):
        # cmd.exe 経由: ssh.exe の親は cmd.exe (セッションの持ち主ではない) なので、対になるのは cmd.exe
        procs = tab()
        procs[20272] = proc(20272, 23720, "cmd.exe", 'cmd.exe /c "ssh.exe -o BatchMode=yes tramp@192.0.2.1"', T + 600)
        procs[23488] = proc(23488, 20272, "ssh.exe", "ssh.exe  -o BatchMode=yes tramp@192.0.2.1", T + 700)
        stubs = {93564: stub("cmd.exe", "/c ssh.exe -o BatchMode=yes tramp@192.0.2.1", T)}
        self.assertEqual(w.pair_up(procs, stubs), {20272: 93564})

    def test_same_start_time_is_resolved_by_arguments(self):
        # 同時に 2 つ走らせると起動時刻がミリ秒まで同じになった
        procs = tab()
        procs[28624] = proc(28624, 23720, "ssh.exe", "ssh.exe -o SendEnv=GIT_PROTOCOL b@192.0.2.1 \"git-upload-pack '/repo-B.git'\"", T + 193)
        procs[44868] = proc(44868, 23720, "ssh.exe", "ssh.exe -o SendEnv=GIT_PROTOCOL a@192.0.2.1 \"git-upload-pack '/repo-A.git'\"", T + 193)
        stubs = {
            114336: stub("ssh.exe", "-o SendEnv=GIT_PROTOCOL b@192.0.2.1 git-upload-pack '/repo-B.git'", T),
            114337: stub("ssh.exe", "-o SendEnv=GIT_PROTOCOL a@192.0.2.1 git-upload-pack '/repo-A.git'", T),
        }
        self.assertEqual(w.pair_up(procs, stubs), {28624: 114336, 44868: 114337})

    def test_windows_side_may_look_earlier_because_of_clock_skew(self):
        # WSL の時計が 0.3〜0.5 秒進んでいて、Windows 側が 485 ms 先に起動したように見えた
        procs = tab()
        procs[61704] = proc(61704, 23720, "ssh.exe", "ssh.exe -T x@192.0.2.1", T - 485)
        stubs = {1: stub("ssh.exe", "-T y@192.0.2.1", T)}  # 引数が違っても時刻の幅に入れば対にする
        self.assertEqual(w.pair_up(procs, stubs), {61704: 1})

    def test_far_apart_in_time_needs_matching_arguments(self):
        procs = tab()
        procs[61704] = proc(61704, 23720, "ssh.exe", "ssh.exe -T x@192.0.2.1", T + 60_000)
        self.assertEqual(w.pair_up(procs, {1: stub("ssh.exe", "-T y@192.0.2.1", T)}), {})
        self.assertEqual(w.pair_up(procs, {1: stub("ssh.exe", "-T x@192.0.2.1", T)}), {61704: 1})

    def test_different_exe_names_never_pair(self):
        procs = tab()
        procs[61704] = proc(61704, 23720, "ssh.exe", "ssh.exe -V", T + 100)
        self.assertEqual(w.pair_up(procs, {1: stub("ssh-add.exe", "-V", T)}), {})


class TestTreeNodes(unittest.TestCase):
    def test_direct_call_joins_windows_and_linux_into_one_path(self):
        procs = tab()
        procs[61704] = proc(61704, 23720, "ssh.exe", "ssh.exe -T git@github.com", T + 500)
        linux = fake_linux({113719: [(644, "/init"), (15259, "claude"), (113717, "git ls-remote"), (113719, "ssh.exe -T git@github.com")]})
        nodes = w.tree_nodes(procs[61704], procs, {61704: 113719}, linux)
        self.assertEqual(
            pids(nodes),
            [("W", 56244), ("W", 48512), ("W", 17080), ("W", 33416), ("W", 23720),
             ("L", 644), ("L", 15259), ("L", 113717), ("L", 113719), ("W", 61704)],
        )

    def test_wsl_exe_trampoline_is_followed_back_to_the_caller(self):
        # wsl.exe -d … -e ssh.exe: 新しいセッションの中の ssh.exe から、元のセッションの claude まで戻る
        procs = tab()
        cmd = 'wsl.exe -d Ubuntu-24.04 -e "/mnt/c/Program Files/OpenSSH/ssh.exe" -T git@github.com'
        procs[3896] = proc(3896, 23720, "wsl.exe", cmd, T + 300)
        procs[39164] = proc(39164, 3896, "wsl.exe", cmd, T + 310)
        procs[29764] = proc(29764, 39164, "ssh.exe", "ssh.exe -T git@github.com", T + 900)
        linux = fake_linux({
            56399: [(644, "/init"), (15259, "claude"), (56399, "wsl.exe -d Ubuntu-24.04 -e …")],
            56405: [(56404, "/init"), (56405, "ssh.exe -T git@github.com")],
        })
        nodes = w.tree_nodes(procs[29764], procs, {3896: 56399, 29764: 56405}, linux)
        self.assertEqual(
            pids(nodes),
            [("W", 56244), ("W", 48512), ("W", 17080), ("W", 33416), ("W", 23720),
             ("L", 644), ("L", 15259), ("L", 56399),
             ("W", 3896), ("W", 39164),
             ("L", 56404), ("L", 56405), ("W", 29764)],
        )

    def test_reused_parent_pid_stops_the_walk(self):
        # 親が先に終わって PID が再利用されると、「親」の方が後から起動していることになる
        procs = tab()
        procs[700] = proc(700, 23720, "notepad.exe", "notepad.exe", T + 10_000)
        procs[800] = proc(800, 700, "ssh.exe", "ssh.exe -V", T)
        nodes = w.tree_nodes(procs[800], procs, {}, fake_linux({}))
        self.assertEqual(nodes[0][2], "(親は終了済み)")
        self.assertEqual(pids(nodes)[1:], [("W", 800)])


class TestRender(unittest.TestCase):
    def test_marks_each_crossing_between_windows_and_linux(self):
        nodes = [("W", 1, "wsl.exe", None), ("L", 2, "/init", None), ("L", 3, "ssh.exe -V", ["cwd /tmp"]), ("W", 4, "ssh.exe -V", None)]
        self.assertEqual(
            w.render(nodes),
            [
                "[Windows] 1 wsl.exe",
                "[Linux  ] └─ 2 /init  <== WSL interop",
                "[Linux  ]   └─ 3 ssh.exe -V",
                "[Linux  ]        cwd /tmp",
                "[Windows]     └─ 4 ssh.exe -V  <== WSL interop",
            ],
        )

    def test_long_labels_are_shown_in_full(self):
        line = w.render([("W", 1, "x" * 500, None)])[0]
        self.assertEqual(line, "[Windows] 1 " + "x" * 500)


class TestJoinArgv(unittest.TestCase):
    def test_arguments_with_spaces_are_quoted(self):
        # Linux 側のコマンドラインは、1 つの引数に空白があっても区切りが分かるように引用する
        self.assertEqual(w.join_argv(["zsh", "-c", "echo a b"]), "zsh -c 'echo a b'")

    def test_plain_arguments_stay_as_they_are(self):
        self.assertEqual(w.join_argv(["git", "ls-remote", "ssh://x@192.0.2.1/r.git"]), "git ls-remote ssh://x@192.0.2.1/r.git")


class TestUntrustedText(unittest.TestCase):
    def test_control_characters_are_escaped_in_labels(self):
        line = w.render([("L", 1, "ssh.exe x\n[Windows] 999 fake\x1b[1A", None)])[0]
        self.assertNotIn("\x1b", line)
        self.assertNotIn("\n", line)


class TestParseWindows(unittest.TestCase):
    def test_reads_powershell_json_with_bom_and_drops_itself(self):
        text = "\ufeff" + '{"self": 5, "procs": [{"pid": 5, "ppid": 1, "name": "powershell.exe", "cmd": "", "t": 1},' \
            ' {"pid": 6, "ppid": 1, "name": "ssh.exe", "cmd": "ssh.exe -V", "t": 2}]}'
        self.assertEqual(list(w.parse_windows(text)), [6])

    def test_non_json_output_gives_nothing(self):
        self.assertEqual(w.parse_windows("#< CLIXML\n<Objs>"), {})

    def test_entries_missing_keys_are_skipped(self):
        text = '{"self": 5, "procs": [{"pid": 6}, {"pid": 7, "ppid": 1, "name": "ssh.exe", "cmd": null, "t": 2}]}'
        procs = w.parse_windows(text)
        self.assertEqual(list(procs), [7])
        self.assertEqual(procs[7]["cmd"], "")


class TestStartTicks(unittest.TestCase):
    def test_comm_with_parens_and_spaces(self):
        # comm は ")" や空白を含みうるので、最後の ")" の後ろから数える
        stat = "123 (a) b) c) S 1 123 123 0 -1 4194304 1 0 0 0 0 0 0 0 20 0 1 0 98765 0 0"
        self.assertEqual(w.start_ticks(stat), 98765)

    def test_garbage_gives_none(self):
        self.assertIsNone(w.start_ticks(""))


if __name__ == "__main__":
    unittest.main()
