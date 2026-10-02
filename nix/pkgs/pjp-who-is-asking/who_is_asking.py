"""1Password の SSH 鍵の承認ダイアログが出ている間に実行し、要求元のプロセスを
Windows と Linux をまたいだ 1 本の木でたどる。

WSL の ssh は Windows の ssh.exe を interop で起動する。承認を待つ間 ssh.exe は
agent の応答を待って止まっているので、Linux 側には comm=ssh.exe の代理プロセス
(実体は /init) が、Windows 側には ssh.exe 本体が残っている。

木のつなぎ方:

- Windows で親が「セッションを持つ wsl.exe」のプロセス (interop の子) は、Linux 側の
  代理プロセスと対になる。exe 名が同じもののうち、引数が一致し起動時刻が近いものを選ぶ
- 代理プロセスの Linux 側の祖先は、そのセッションの /init で終わる。その /init を持つのが、
  対になった Windows プロセスの親の wsl.exe
- wsl.exe は起動すると同じ引数で自分をもう 1 つ起動し、内側がセッションを持つ

wsl.exe や cmd.exe を踏み台にした要求も、対を繰り返したどると元の呼び出し元まで届く。
親が先に終了した要求は、Linux 側の祖先がセッションの /init で途切れる (env を手掛かりに出す)。
経緯は docs/adr/012_wsl_exe_exec_trace_service_20260930T153253JST/README.md。
"""

import argparse
import base64
import datetime
import json
import os
import re
import subprocess
import sys
import time

# 1Password の agent (named pipe) か署名に届きうる .exe
AGENT = re.compile(r"^(ssh|ssh-add|scp|sftp|op-ssh-sign|op-ssh-sign-wsl)\.exe$", re.I)
ENV_KEYS = ("WSL_INTEROP", "WT_SESSION", "HERDR_PANE_ID", "TMUX", "SSH_CONNECTION", "CLAUDE_CODE_SESSION_ID")
LINE = 170  # 1 行の幅の目安 (字下げ込み)

# Windows 側は代理より 0.1〜0.6 秒遅れて起動するが、WSL と Windows の時計は 0.5 秒ほど
# ずれていることがある (Windows 側が先に見えることもある)。引数の一致を優先し、
# 起動時刻の差 (Windows - Linux) はこの幅まで許す
PAIR_WINDOW_MS = (-3000, 5000)


# ------------------------------------------------------------------ 対と木 (純粋な関数)


def win_label(p):
    """Windows のプロセスの表示名。先頭の実行ファイルのパスを exe 名に縮める"""
    cmd = (p.get("cmd") or "").strip()
    name = p["name"]
    i = cmd.lower().find(name.lower())
    if i < 0:
        return cmd or name
    rest = cmd[i + len(name) :]
    return (name + (rest[1:] if rest.startswith('"') else rest)).rstrip()


def norm(s):
    """引数の比べ方をそろえる。WSL は空白を含む引数を "…" で囲んで Windows へ渡す"""
    return " ".join(s.replace('"', " ").split())


def is_host(p, procs):
    """WSL のセッションを持ち、interop で起動した .exe の親になる Windows プロセスか"""
    n = p["name"].lower()
    if n == "wslhost.exe":
        return True  # タブの wsl.exe が先に終わると、残ったセッションはこちらが持つとみられる (未確認)
    q = procs.get(p["ppid"])
    return n == "wsl.exe" and q is not None and q["name"].lower() == "wsl.exe" and q["cmd"] == p["cmd"]


def pair_up(procs, stubs):
    """interop の子 (Windows) と代理プロセス (Linux) を 1 対 1 で対にする。{Windows の PID: Linux の PID}"""
    lo, hi = PAIR_WINDOW_MS
    cands = []
    for w in procs.values():
        q = procs.get(w["ppid"])
        if not (q and is_host(q, procs)):
            continue
        wargs = norm(win_label(w)[len(w["name"]) :])
        for lp, s in stubs.items():
            if s["name"] != w["name"].lower():
                continue
            same = norm(s["args"]) == wargs
            dt = w["t"] - (s["t"] or 0)
            if same or lo <= dt <= hi:
                cands.append(((0 if same else 1, abs(dt)), w["pid"], lp))
    pair, used = {}, set()
    for _, wp, lp in sorted(cands):
        if wp not in pair and lp not in used:
            pair[wp] = lp
            used.add(lp)
    return pair


def tree_nodes(w, procs, pair, linux_nodes):
    """Windows の対象から親へたどり、根から順に (os, pid, label, note) を返す。

    linux_nodes(代理の PID) は、その代理の Linux 側の祖先を根から順に返す関数。
    """
    out, p, seen = [], w, set()
    while p and p["pid"] not in seen:
        seen.add(p["pid"])
        out.append(("W", p["pid"], win_label(p), None))
        if p["pid"] in pair:
            # 対になった代理プロセスの Linux 側の祖先を、この Windows プロセスの上に差し込む
            out.extend(reversed(linux_nodes(pair[p["pid"]])))
        if p["name"].lower() == "explorer.exe":
            break
        q = procs.get(p["ppid"])
        if q is None or q["t"] > p["t"]:
            # 親が先に終了している (PID が再利用されていることもある)
            if p["ppid"]:
                out.append(("W", p["ppid"], "(親は終了済み)", None))
            break
        p = q
    return list(reversed(out))


# ラベルの中身 (argv・コマンドライン) は要求元が決められる。改行や ESC をそのまま出すと
# 偽の行を差し込んだり端末を操作したりできるので、表示する前に \xNN にする
CTRL = re.compile(r"[\x00-\x1f\x7f]")


def safe(s):
    return CTRL.sub(lambda m: f"\\x{ord(m.group()):02x}", s)


def cut(s, width):
    s = safe(s)
    return s if len(s) <= width else s[: max(width - 1, 20)] + "…"


def render(nodes, width=LINE):
    """木を 1 行ずつの文字列にする。OS が切り替わる行には <== WSL interop を付ける"""
    out, prev = [], None
    for depth, (os_, pid, label, note) in enumerate(nodes):
        tag = "[Windows]" if os_ == "W" else "[Linux  ]"
        indent = "  " * max(depth - 1, 0) + ("└─ " if depth else "")
        cross = "  <== WSL interop" if prev and prev != os_ else ""
        out.append(f"{tag} {indent}{cut(f'{pid} {label}', width - len(indent))}{cross}")
        for line in note or []:
            pad = "  " * depth + "   "
            out.append(f"{tag} {pad}{cut(line, width - len(pad))}")
        prev = os_
    return out


# ------------------------------------------------------------------ Linux (/proc)

NOW = time.time()


def boot_time():
    # /proc/stat の btime は秒単位で起動時刻が最大 1 秒ずれるので、今の時刻と uptime から引く
    with open("/proc/uptime") as f:
        return NOW - float(f.read().split()[0])


def read(pid, name):
    try:
        with open(f"/proc/{pid}/{name}", "rb") as f:
            return f.read()
    except OSError:
        return None


def argv_of(pid):
    raw = read(pid, "cmdline")
    return raw.rstrip(b"\0").decode(errors="replace").split("\0") if raw else None


def ppid_of(pid):
    m = re.search(rb"^PPid:\s+(\d+)", read(pid, "status") or b"", re.M)
    return int(m.group(1)) if m else 0


def start_ticks(stat):
    """/proc/<pid>/stat の 22 番目 (起動からの tick 数)。comm は ")" や空白を含みうるので、
    最後の ")" の後ろから数える (そこから 20 番目)"""
    try:
        return int(stat.rsplit(")", 1)[1].split()[19])
    except (IndexError, ValueError):
        return None


def start_ms(pid, boot):
    ticks = start_ticks((read(pid, "stat") or b"").decode(errors="replace"))
    return None if ticks is None else int((boot + ticks / os.sysconf("SC_CLK_TCK")) * 1000)


def env_of(pid):
    items = (read(pid, "environ") or b"").decode(errors="replace").split("\0")
    return " ".join(x for x in items if x.split("=", 1)[0] in ENV_KEYS)


def cwd_of(pid):
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return "?"


def is_stub(argv):
    # interop の代理プロセスは argv[0]=/init, argv[1]=<.exe のパス>
    return bool(argv) and len(argv) >= 2 and argv[0] == "/init" and argv[1].lower().endswith(".exe")


def linux_stubs(boot):
    out = {}
    for d in os.listdir("/proc"):
        if d.isdigit():
            argv = argv_of(int(d))
            if is_stub(argv):
                name = argv[1].rsplit("/", 1)[-1].lower()
                out[int(d)] = {"name": name, "args": " ".join(argv[3:]), "t": start_ms(int(d), boot)}
    return out


def linux_chain(pid):
    """代理プロセスから親へ、セッションの /init までの PID の列 (代理が先頭)"""
    out, x = [], pid
    while x > 1 and len(out) < 64:
        out.append(x)
        if argv_of(x) == ["/init"]:
            break
        x = ppid_of(x)
    return out


def linux_label(pid):
    argv = argv_of(pid) or ["(終了済み)"]
    if is_stub(argv):
        # "/init <exe のパス> <argv0> <引数…>" を "<exe 名> <引数…>" にする
        return " ".join([argv[1].rsplit("/", 1)[-1]] + argv[3:])
    if argv == ["/init"]:
        sock = f"/run/WSL/{pid}_interop"
        return "/init  (WSL のセッション" + (f": {sock}" if os.path.exists(sock) else "") + ")"
    return " ".join(argv)


def hhmmss(ms):
    return datetime.datetime.fromtimestamp(ms / 1000).strftime("%H:%M:%S.%f")[:-3] if ms else "?"


def ago(ms):
    return f"{max(NOW - ms / 1000, 0):.0f} 秒前" if ms else "?"


def stub_note(pid, chain, boot):
    t = start_ms(pid, boot)
    lines = [f"起動 {hhmmss(t)} ({ago(t)})  cwd {cwd_of(pid)}"]
    env = env_of(pid)
    if env:
        lines.append(f"env {env}")
    if len(chain) == 2:
        lines.append("親は /init: 親が先に終了したか、wsl.exe -e で直接起動された")
    return lines


def make_linux_nodes(boot):
    def linux_nodes(stub):
        chain = linux_chain(stub)
        nodes = [("L", x, linux_label(x), stub_note(x, chain, boot) if i == 0 else None) for i, x in enumerate(chain)]
        return list(reversed(nodes))

    return linux_nodes


# ------------------------------------------------------------------ Windows (powershell.exe)

PS = r"""
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$out = foreach ($p in Get-CimInstance Win32_Process) {
  [pscustomobject]@{
    pid = [int]$p.ProcessId; ppid = [int]$p.ParentProcessId; name = [string]$p.Name; cmd = [string]$p.CommandLine
    t = $(if ($p.CreationDate) { ([DateTimeOffset]$p.CreationDate).ToUnixTimeMilliseconds() } else { 0 })
  }
}
@{ self = $PID; procs = @($out) } | ConvertTo-Json -Depth 3 -Compress
"""


def parse_windows(text):
    """PS の出力 (JSON) をプロセス表にする。PowerShell 自身と、キーの欠けた行は落とす"""
    try:
        d = json.loads(text.lstrip("\ufeff"))
    except ValueError:
        return {}
    if not isinstance(d, dict):
        return {}
    out = {}
    for p in d.get("procs") or []:
        if not isinstance(p, dict) or not all(k in p for k in ("pid", "ppid", "name", "t")):
            continue
        if p["pid"] == d.get("self"):
            continue
        out[p["pid"]] = {**p, "cmd": p.get("cmd") or ""}
    return out


def windows_procs():
    enc = base64.b64encode(PS.encode("utf-16le")).decode()
    try:
        # /mnt/c から起動しないと cwd の UNC 変換の警告が出ることがある
        r = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", enc],
            cwd="/mnt/c", capture_output=True, stdin=subprocess.DEVNULL, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"(Windows 側を取れなかった: {e})\n")
        return {}
    procs = parse_windows(r.stdout.decode("utf-8", errors="replace"))
    if not procs:
        print("(Windows 側を取れなかった: powershell.exe の出力を読めない)\n")
    return procs


# ------------------------------------------------------------------ main


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="pjp-who-is-asking",
        description="1Password の承認ダイアログが出ている間に、要求元を Windows と Linux をまたいだ木で出す",
    )
    ap.add_argument("--no-windows", action="store_true", help="Windows 側 (powershell.exe で 1〜2 秒かかる) を省き、Linux 側の木だけ出す")
    opts = ap.parse_args(argv)

    boot = boot_time()
    stubs = linux_stubs(boot)
    linux_nodes = make_linux_nodes(boot)
    lines = []
    if opts.no_windows:
        if not stubs:
            lines.append("(none: 動いている .exe は無い)")
        for lp in sorted(stubs, key=lambda x: stubs[x]["t"] or 0):
            mark = "" if AGENT.match(stubs[lp]["name"]) else "  (踏み台かもしれない .exe)"
            lines += [f"== {stubs[lp]['name']}  Linux pid {lp}{mark}", *render(linux_nodes(lp)), ""]
        print("\n".join(lines))
        return 0

    procs = windows_procs()
    pair = pair_up(procs, stubs)
    targets = sorted((p for p in procs.values() if AGENT.match(p["name"])), key=lambda p: p["t"])
    if not targets:
        lines += ["(none: 承認待ちの ssh.exe などは無い)", ""]
    shown = set()
    for t in targets:
        nodes = tree_nodes(t, procs, pair, linux_nodes)
        shown.update(pid for os_, pid, _, _ in nodes if os_ == "L")
        lines += [f"== {t['name']}  Windows pid {t['pid']}  起動 {hhmmss(t['t'])} ({ago(t['t'])})", *render(nodes), ""]
    # Windows 側の起動がまだ・対が取れなかった agent 系の代理プロセス
    for lp in sorted(stubs, key=lambda x: stubs[x]["t"] or 0):
        if lp not in shown and AGENT.match(stubs[lp]["name"]):
            lines += [f"== {stubs[lp]['name']}  Linux pid {lp}  (Windows 側の対が見つからない)", *render(linux_nodes(lp)), ""]
    if len(targets) > 1:
        lines.append("承認待ちの要求は、たいてい起動が一番新しいもの (長く続いている ssh.exe は接続中のセッションのことがある)")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
