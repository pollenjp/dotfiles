"""who_is_asking の対の取り方と木の組み立て、exe-exec-trace の記録の出し方のテスト。

データは TKT-54 の実機 (2026-09-30) で見たプロセス表と、TKT-69 の実機 (2026-10-17) の記録
(Claude Code の GitHub SSH の確かめ) を縮めたもの。/proc・powershell.exe・journalctl・systemctl には
触らない (Linux 側の祖先は linux_nodes を差し替えて渡し、I/O の関数は mock で差し替える)。
flake の checks (pjp-who-is-asking-unittest) が流す。

## 確かめること

- Windows のプロセスの見出し: コマンドラインのパスは exe の名前にし、引数は残す (パスが引用されていても、
  引用の無いパスに空白があっても)。コマンドラインが無ければ名前
- セッションの持ち主は内側の wsl.exe (と wslhost.exe) で、外側の wsl.exe ではない
- 対の取り方: セッションの持ち主の子だけを、Linux 側の代理プロセスと対にする。起動時刻が同じなら引数で
  分け、時計のずれで Windows 側が先に見えても対にし、時刻が離れていれば引数が合うときだけ対にする。
  exe の名前が違えば対にしない
- 木: 直接の呼び出しは Windows と Linux を 1 本の道につなぎ、wsl.exe -e の踏み台は元のセッションの
  呼び出し元まで戻る。親の PID が使い回されていたら (親の方が後から起動している) そこで止める
- 表示: Windows と Linux をまたぐ所に印を付け、長い見出しも切らない。Linux 側の引数は空白があれば
  引用する。見出しの制御文字は無害化する
- PowerShell の出力: BOM 付きの JSON を読み、自分 (powershell.exe) を外す。JSON でなければ空にし、
  欄の欠けた項目は飛ばす
- /proc/<pid>/stat の起動時刻: comm に ")" や空白があっても読み、壊れていれば None
- 記録の時刻: タイムゾーン付きの ISO 8601 を epoch ms にし、読めなければ None
- 記録の選び方: agent に届く .exe の記録と、引数で agent の exe をコマンドとして呼ぶ踏み台の記録
  (cmd.exe /c ssh.exe … など。sshd のような語や argv[0] には当たらない) だけを、窓の中 (ちょうど端は含む)
  から古い順に選ぶ。記録でない行・形の欠けた記録・時刻の読めない記録は黙って飛ばす
- 記録の木: カーネルの祖先をセッションの /init (コマンドラインが /init、無ければ comm が Relay(<pid>)) まで
  たどり、ラベルは /proc のコマンドライン、無ければ comm。末端に cwd と env、親がセッションの /init なら
  踏み台の案内を付ける。/init が無ければ祖先を全部出す。他のディストロの記録は comm だけ
- 動いているか: 記録の PID に居るのが同じ exe の代理プロセスで、起動時刻が記録から 3 秒以内のときだけ。
  他のディストロの記録は見ない
- 記録の節: 記録ごとに状態つきの見出しと木を出し、踏み台には印を付ける。0 件ならその旨、2 件以上なら
  一番新しいものを指す。記録の中の制御文字は無害化する。遡る長さは 60 で割り切れれば分で書く
- 記録を読めないとき: unit が無ければ読まずに 1 行、止まっていれば読んだうえで最後に 1 行、読めなければ
  1 行 (権限の Hint・journalctl の失敗)。systemctl の状態が分からなければ見ずに読む。窓に 5 秒足して遡らせる
- main: 記録の節をいま動いている木より先に出し、`--recent 0` なら記録を読まない。負の `--recent` は
  argparse のエラー。いま動いている木には見出しを付け、該当が無ければその旨を出す
"""

import io
import json
import os
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

import who_is_asking as w

_TZ = None


def setUpModule():
    # hhmmss はローカル時刻で出す。zoneinfo の無い Nix のサンドボックスでも効く POSIX の書き方で JST にそろえる
    global _TZ
    _TZ = os.environ.get("TZ")
    os.environ["TZ"] = "JST-9"
    time.tzset()


def tearDownModule():
    if _TZ is None:
        os.environ.pop("TZ", None)
    else:
        os.environ["TZ"] = _TZ
    time.tzset()

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


# ------------------------------------------------------------------ exe-exec-trace の記録

PROBE_MS = 1_792_200_937_246  # 2026-10-17T01:35:37.246Z (= 10:35:37.246 JST)


def probe_record(**over):
    """実機 (2026-10-17 10:35:37) の、Claude Code の GitHub SSH の確かめの記録を縮めたもの"""
    rec = {
        "time": "2026-10-17T10:35:37.246+09:00",
        "exe": "/mnt/c/Program Files/OpenSSH/ssh.exe",
        "agent": True,
        "pid": 1037709,
        "uid": 1000,
        "distro": "this",
        "kernel_ancestry": [
            {"pid": 980424, "comm": "claude"},
            {"pid": 2305724, "comm": "fish"},
            {"pid": 1256, "comm": "herdr"},
            {"pid": 660, "comm": "Relay(661)"},
            {"pid": 659, "comm": "SessionLeader"},
            {"pid": 1, "comm": "systemd"},
        ],
        "argv": ["ssh.exe", "-T", "-o", "BatchMode=yes", "git@github.com"],
        "cwd": "/home/pollenjp",
        "env": {"HERDR_PANE_ID": "w1T:pE"},
        "ancestry": [
            {"pid": 980424, "cmdline": "claude --remote-control"},
            {"pid": 2305724, "cmdline": "fish"},
            {"pid": 1256, "cmdline": "herdr server"},
            {"pid": 660, "cmdline": "/init"},
            {"pid": 659, "cmdline": "/init"},
        ],
    }
    rec.update(over)
    return rec


def other_distro_record():
    """他のディストロの記録 (/proc が見えないので argv・cwd・env・ancestry が無い)"""
    return {
        "time": "2026-10-17T10:35:00.000+09:00",
        "exe": "/mnt/c/Program Files/OpenSSH/ssh.exe",
        "agent": True,
        "pid": 31,
        "uid": 1000,
        "distro": "other(pidns=4026532000)",
        "kernel_ancestry": [{"pid": 30, "comm": "bash"}, {"pid": 28, "comm": "Relay(29)"}, {"pid": 1, "comm": "init"}],
    }


def as_line(rec):
    return json.dumps(rec, ensure_ascii=False)


def labels(nodes):
    return [(pid, label) for _, pid, label, _ in nodes]


class TestRecordMs(unittest.TestCase):
    def test_iso_time_with_offset_becomes_epoch_ms(self):
        self.assertEqual(w.record_ms(probe_record()), PROBE_MS)

    def test_unreadable_time_gives_none(self):
        for bad in ("x", None, 12345):
            self.assertIsNone(w.record_ms(probe_record(time=bad)), bad)
        rec = probe_record()
        del rec["time"]
        self.assertIsNone(w.record_ms(rec))


class TestParseRecords(unittest.TestCase):
    WINDOW = 180_000

    def test_keeps_agent_records_in_window_oldest_first(self):
        older = probe_record(pid=1, time="2026-10-17T10:34:00.000+09:00")
        newer = probe_record(pid=2, time="2026-10-17T10:35:00.000+09:00")
        got = w.parse_records([as_line(newer), as_line(older)], PROBE_MS, self.WINDOW)
        self.assertEqual([r["pid"] for r in got], [1, 2])

    def test_skips_lines_that_are_not_records(self):
        no_ancestry = {"exe": "/x/ssh.exe", "agent": True, "pid": 5, "time": "2026-10-17T10:35:00+09:00"}
        lines = [
            "Started dotfiles-exe-exec-trace.service - dotfiles: WSL から起動された Windows の .exe を祖先付きで記録する (eBPF).",
            "[1, 2]",
            json.dumps(no_ancestry),
            as_line(probe_record(time="x")),
            as_line(probe_record(pid="1037709")),
            as_line(probe_record(exe=None)),
            as_line(probe_record(kernel_ancestry="claude")),
            "",
        ]
        self.assertEqual(w.parse_records(lines, PROBE_MS, self.WINDOW), [])

    def test_skips_non_agent_and_old_records(self):
        edge = probe_record(pid=3, time="2026-10-17T10:32:37.246+09:00")  # ちょうど窓の端 (180 秒前)
        older = probe_record(pid=4, time="2026-10-17T10:32:37.245+09:00")  # それより 1 ms 古い
        tool = probe_record(pid=5, exe="/mnt/c/Windows/System32/reg.exe", agent=False, argv=["reg.exe", "query", "HKCU\\Software"])
        got = w.parse_records([as_line(edge), as_line(older), as_line(tool)], PROBE_MS, self.WINDOW)
        self.assertEqual([r["pid"] for r in got], [3])

    def test_keeps_trampolines_that_call_an_agent_exe(self):
        # cmd.exe /c ssh.exe では Linux 側に ssh.exe が現れず、記録は cmd.exe (agent ではない) だけになる
        def tramp(pid, exe, argv):
            return as_line(probe_record(pid=pid, exe=exe, agent=False, argv=argv))

        lines = [
            tramp(11, "/mnt/c/WINDOWS/system32/cmd.exe", ["cmd.exe", "/c", "ssh.exe -o BatchMode=yes tramp@192.0.2.1"]),
            tramp(12, "/mnt/c/WINDOWS/system32/wsl.exe",
                  ["wsl.exe", "-d", "Ubuntu-24.04", "-e", "/mnt/c/Program Files/OpenSSH/ssh.exe", "-T", "git@github.com"]),
            tramp(13, "/mnt/c/WINDOWS/system32/wsl.exe", ["wsl.exe", "-e", "ssh", "-T", "git@github.com"]),
            tramp(14, "/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe", ["powershell.exe", "-Command", "Write-Output sshd"]),
            tramp(15, "/mnt/c/WINDOWS/system32/cmd.exe", ["cmd.exe", "/c", "type ssh-config.txt openssh.txt"]),
            tramp(16, "/mnt/c/WINDOWS/system32/cmd.exe", ["ssh.exe"]),  # argv[0] は踏み台自身なので見ない
        ]
        self.assertEqual([r["pid"] for r in w.parse_records(lines, PROBE_MS, self.WINDOW)], [11, 12, 13])


class TestRecordNodes(unittest.TestCase):
    def test_stops_at_the_session_init_and_uses_command_lines(self):
        nodes = w.record_nodes(probe_record())
        self.assertEqual(
            labels(nodes),
            [
                (660, "/init  (WSL のセッション)"),
                (1256, "herdr server"),
                (2305724, "fish"),
                (980424, "claude --remote-control"),
                (1037709, "ssh.exe -T -o BatchMode=yes git@github.com"),
            ],
        )
        self.assertEqual(nodes[-1][3], ["cwd /home/pollenjp", "env HERDR_PANE_ID=w1T:pE"])
        self.assertEqual({os_ for os_, _, _, _ in nodes}, {"L"})

    def test_falls_back_to_comm_when_the_parent_had_exited(self):
        # 親が先に終わると、/proc で読んだ祖先は付け替え後のもの (セッションの /init だけ) になる
        nodes = w.record_nodes(probe_record(ancestry=[{"pid": 660, "cmdline": "/init"}]))
        self.assertEqual(
            labels(nodes)[:4],
            [(660, "/init  (WSL のセッション)"), (1256, "herdr"), (2305724, "fish"), (980424, "claude")],
        )

    def test_other_distro_record_uses_comm_and_relay(self):
        nodes = w.record_nodes(other_distro_record())
        self.assertEqual(labels(nodes), [(28, "/init  (WSL のセッション)"), (30, "bash"), (31, "ssh.exe")])
        self.assertIsNone(nodes[-1][3])

    def test_parent_is_session_init_adds_a_hint(self):
        rec = probe_record(kernel_ancestry=[{"pid": 4, "comm": "Relay(5)"}, {"pid": 1, "comm": "init"}], ancestry=[])
        self.assertIn(
            "親は /init: 親が先に終了したか、wsl.exe -e を踏み台にした要求 (踏み台の wsl.exe の記録が近くに並ぶ)",
            w.record_nodes(rec)[-1][3],
        )

    def test_without_session_init_shows_the_whole_chain(self):
        rec = probe_record(kernel_ancestry=[{"pid": 9, "comm": "a"}, {"pid": 8, "comm": "b"}, {"pid": 7, "comm": "c"}], ancestry=[])
        self.assertEqual([pid for pid, _ in labels(w.record_nodes(rec))], [7, 8, 9, 1037709])


class TestStubMatches(unittest.TestCase):
    ARGV = ["/init", "/mnt/c/Program Files/OpenSSH/ssh.exe", "ssh.exe", "-T"]

    def test_same_stub_started_close_to_the_record_is_alive(self):
        self.assertTrue(w.stub_matches(probe_record(), self.ARGV, PROBE_MS + 2000))

    def test_started_too_far_from_the_record_is_another_process(self):
        # PID が使い回されて、同じ exe の別の代理プロセスが居る
        self.assertFalse(w.stub_matches(probe_record(), self.ARGV, PROBE_MS + 4000))

    def test_pid_now_used_by_something_else(self):
        rec = probe_record()
        self.assertFalse(w.stub_matches(rec, ["bash"], PROBE_MS))
        self.assertFalse(w.stub_matches(rec, ["/init", "/mnt/c/Program Files/OpenSSH/ssh-add.exe", "ssh-add.exe"], PROBE_MS))
        self.assertFalse(w.stub_matches(rec, None, PROBE_MS))
        self.assertFalse(w.stub_matches(rec, self.ARGV, None))

    def test_other_distro_is_never_alive_here(self):
        self.assertFalse(w.stub_matches(probe_record(distro="other(pidns=1)"), self.ARGV, PROBE_MS))


HEAD = "## 直近 3 分に起動された要求 (exe-exec-trace の記録、古い順)"
NOT_INSTALLED = "(exe-exec-trace が入っていないので記録は読まない。入れるには dotfiles.wsl.exeExecTrace.enable を true にして setup --update)"


class TestFmtWindow(unittest.TestCase):
    def test_minutes_when_divisible_otherwise_seconds(self):
        self.assertEqual(w.fmt_window(180), "3 分")
        self.assertEqual(w.fmt_window(60), "1 分")
        self.assertEqual(w.fmt_window(90), "90 秒")


class TestParseUnitState(unittest.TestCase):
    def test_reads_load_and_active_state(self):
        self.assertEqual(w.parse_unit_state("LoadState=loaded\nActiveState=active\n"), ("loaded", "active"))
        self.assertEqual(w.parse_unit_state("LoadState=not-found\nActiveState=inactive\n"), ("not-found", "inactive"))

    def test_empty_output_gives_nothing(self):
        self.assertEqual(w.parse_unit_state(""), (None, None))


class TestJournalctlMessage(unittest.TestCase):
    NO_PERMISSION = "(他のユーザーの記録が見えない。adm か systemd-journal のグループに入ると読める)"

    def test_success_gives_none(self):
        self.assertIsNone(w.journalctl_message(0, ""))

    def test_permission_hints_say_which_groups(self):
        hint = (
            "Hint: You are currently not seeing messages from other users and the system.\n"
            "      Users in groups 'adm', 'systemd-journal' can see all messages.\n"
        )
        self.assertEqual(w.journalctl_message(0, hint), self.NO_PERMISSION)
        self.assertEqual(
            w.journalctl_message(1, "No journal files were opened due to insufficient permissions.\n"), self.NO_PERMISSION
        )

    def test_failure_shows_first_line_or_exit_code(self):
        self.assertEqual(w.journalctl_message(1, "Failed to open journal\nmore"), "(記録を読めなかった: Failed to open journal)")
        self.assertEqual(w.journalctl_message(1, ""), "(記録を読めなかった: 終了コード 1)")


class TestJournalBody(unittest.TestCase):
    NOTE = "[Linux  ]" + " " * 12  # 深さ 4 の節の注記の字下げ (1 + 2×4 + 3)
    TREE = [
        "[Linux  ] 660 /init  (WSL のセッション)",
        "[Linux  ] └─ 1256 herdr server",
        "[Linux  ]   └─ 2305724 fish",
        "[Linux  ]     └─ 980424 claude --remote-control",
        "[Linux  ]       └─ 1037709 ssh.exe -T -o BatchMode=yes git@github.com",
        NOTE + "cwd /home/pollenjp",
        NOTE + "env HERDR_PANE_ID=w1T:pE",
    ]

    def test_shows_each_record_as_a_tree_with_state(self):
        rec = probe_record()
        with mock.patch.object(w, "NOW", PROBE_MS / 1000 + 35):
            gone = w.journal_body([rec], lambda r: False, 180)
            alive = w.journal_body([rec], lambda r: True, 180)
        self.assertEqual(gone, ["== ssh.exe  Linux pid 1037709  起動 10:35:37.246 (35 秒前)  終了済み", *self.TREE, ""])
        self.assertEqual(alive, ["== ssh.exe  Linux pid 1037709  起動 10:35:37.246 (35 秒前)  動いている (下の木にも出る)", *self.TREE, ""])

    def test_other_distro_heading_does_not_look_at_proc(self):
        alive = mock.Mock(side_effect=AssertionError("他のディストロの記録で /proc を見た"))
        with mock.patch.object(w, "NOW", 1_792_200_900 + 5):
            out = w.journal_body([other_distro_record()], alive, 180)
        self.assertEqual(out[0], "== ssh.exe  other(pidns=4026532000) pid 31  起動 10:35:00.000 (5 秒前)  他のディストロ: 祖先は comm だけ")

    def test_no_records_says_none(self):
        self.assertEqual(w.journal_body([], lambda r: False, 180), ["(none: 直近 3 分に記録された要求は無い)", ""])

    def test_trampoline_record_is_marked(self):
        rec = probe_record(exe="/mnt/c/WINDOWS/system32/cmd.exe", agent=False, argv=["cmd.exe", "/c", "ssh.exe tramp@192.0.2.1"])
        with mock.patch.object(w, "NOW", PROBE_MS / 1000 + 1):
            out = w.journal_body([rec], lambda r: False, 180)
        self.assertEqual(out[0], "== cmd.exe  Linux pid 1037709  起動 10:35:37.246 (1 秒前)  終了済み  (踏み台かもしれない .exe)")

    def test_two_or_more_records_point_at_the_newest(self):
        with mock.patch.object(w, "NOW", PROBE_MS / 1000 + 1):
            out = w.journal_body([probe_record(pid=1), probe_record(pid=2)], lambda r: False, 180)
        self.assertEqual(sum(line.startswith("== ") for line in out), 2)
        self.assertEqual(out[-1], "ダイアログの要求は、たいてい一番新しいもの (一番下)")

    def test_control_characters_in_records_are_escaped(self):
        rec = probe_record(
            exe="/mnt/c/x\x1b[2J.exe", argv=["x.exe", "a\nb"], cwd="/tmp/\x1b]0;x\x07", env={"WT_SESSION": "\x1b[1A"}
        )
        with mock.patch.object(w, "NOW", PROBE_MS / 1000 + 1):
            out = w.journal_body([rec], lambda r: False, 180)
        for line in out:
            for ch in ("\x1b", "\n", "\x07"):
                self.assertNotIn(ch, line)


class TestJournalLines(unittest.TestCase):
    def run_lines(self, state, journal=None):
        """unit の状態と journal の読み取りを差し替えて journal_lines を走らせる。journal が None なら読ませない"""
        if journal is None:
            read = mock.Mock(side_effect=AssertionError("journal を読んだ"))
        else:
            read = mock.Mock(return_value=journal)
        with (
            mock.patch.object(w, "unit_state", return_value=state),
            mock.patch.object(w, "read_journal", read),
            mock.patch.object(w, "is_alive", return_value=False),
            mock.patch.object(w, "NOW", PROBE_MS / 1000 + 10),
        ):
            return w.journal_lines(180, 0.0), read

    def test_not_installed_skips_reading(self):
        out, _ = self.run_lines(("not-found", "inactive"))
        self.assertEqual(out, [HEAD, NOT_INSTALLED, ""])

    def test_inactive_unit_still_reads_and_warns(self):
        out, _ = self.run_lines(("loaded", "failed"), ([as_line(probe_record())], None))
        self.assertIn("== ssh.exe  Linux pid 1037709  起動 10:35:37.246 (10 秒前)  終了済み", out)
        self.assertEqual(out[-2:], ["(exe-exec-trace が動いていない (ActiveState=failed)。止まっている間の要求は記録に無い)", ""])

    def test_read_failure_is_one_line(self):
        out, _ = self.run_lines(("loaded", "active"), ([], "(journalctl が無いので記録は読まない)"))
        self.assertEqual(out, [HEAD, "(journalctl が無いので記録は読まない)", ""])

    def test_unknown_unit_state_still_reads(self):
        # systemctl が無い・失敗したときは、状態を見ずに読む
        out, read = self.run_lines((None, None), ([as_line(probe_record())], None))
        read.assert_called_once()
        self.assertIn("== ssh.exe  Linux pid 1037709  起動 10:35:37.246 (10 秒前)  終了済み", out)
        self.assertFalse(any("動いていない" in line for line in out))

    def test_reads_back_the_window_plus_slack(self):
        # 10:35:47.246 から 180 + 5 秒遡った epoch 秒 (10:32:42)
        _, read = self.run_lines(("loaded", "active"), ([], None))
        read.assert_called_once_with(1_792_200_762)


class TestMain(unittest.TestCase):
    def run_main(self, argv, journal=None):
        """/proc・powershell.exe・journal を差し替えて main を走らせ、(終了コード, stdout) を返す"""
        journal = journal or mock.Mock(side_effect=AssertionError("journal を読んだ"))
        buf = io.StringIO()
        with (
            mock.patch.object(w, "boot_time", return_value=0.0),
            mock.patch.object(w, "linux_stubs", return_value={}),
            mock.patch.object(w, "windows_procs", return_value={}),
            mock.patch.object(w, "journal_lines", journal),
            redirect_stdout(buf),
        ):
            rc = w.main(argv)
        return rc, buf.getvalue()

    def test_recent_zero_skips_the_journal(self):
        rc, out = self.run_main(["--no-windows", "--recent", "0"])
        self.assertEqual(rc, 0)
        self.assertIn("## いま動いている .exe (Linux 側だけ)", out)
        self.assertIn("(none: 動いている .exe は無い)", out)
        self.assertNotIn("## 直近", out)

    def test_journal_section_comes_first_with_the_default_window(self):
        journal = mock.Mock(return_value=[HEAD, "x", ""])
        _, out = self.run_main(["--no-windows"], journal)
        self.assertLess(out.index("## 直近"), out.index("## いま動いている"))
        self.assertEqual(journal.call_args.args[0], 180)

    def test_windows_mode_heading_and_none_line(self):
        _, out = self.run_main(["--recent", "60"], mock.Mock(return_value=[]))
        self.assertIn("## いま動いている ssh.exe など (Windows と Linux の木)", out)
        self.assertIn("(none: いま動いている ssh.exe などは無い)", out)

    def test_negative_recent_is_rejected(self):
        err = io.StringIO()
        with redirect_stderr(err), self.assertRaises(SystemExit) as cm:
            w.main(["--recent", "-1"])
        self.assertEqual(cm.exception.code, 2)
        self.assertIn("0 以上の整数", err.getvalue())


if __name__ == "__main__":
    unittest.main()
