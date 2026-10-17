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

ただし、ダイアログに気付いた時点で要求元が既に終わっていることがある (Claude Code の GitHub SSH の
確かめは 3 秒で kill されるが、ダイアログは約 60 秒残る)。そのため、exe-exec-trace が journald に
残した直近 (既定 180 秒) の記録からも木を出し、いま動いている木より先に出す。
経緯は docs/adr/020_who_is_asking_recent_journal_20261017T110906JST/README.md。
"""

import argparse
import base64
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import time

# 1Password の agent (named pipe) か署名に届きうる .exe
AGENT = re.compile(r"^(ssh|ssh-add|scp|sftp|op-ssh-sign|op-ssh-sign-wsl)\.exe$", re.I)
ENV_KEYS = ("WSL_INTEROP", "WT_SESSION", "HERDR_PANE_ID", "TMUX", "SSH_CONNECTION", "CLAUDE_CODE_SESSION_ID")

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


def join_argv(argv):
    """表示用に argv をつなぐ。1 つの引数に空白があっても区切りが分かるよう、シェルの引用を使う"""
    return shlex.join(argv)


def render(nodes):
    """木を 1 行ずつの文字列にする。OS が切り替わる行には <== WSL interop を付ける。

    ラベル (コマンドライン) は切らない。長い行は端末の折り返しに任せる
    (Claude の Bash ツールの zsh -c は、実際のコマンドが長い前置きの後ろにあるため)。
    """
    out, prev = [], None
    for depth, (os_, pid, label, note) in enumerate(nodes):
        tag = "[Windows]" if os_ == "W" else "[Linux  ]"
        indent = "  " * max(depth - 1, 0) + ("└─ " if depth else "")
        cross = "  <== WSL interop" if prev and prev != os_ else ""
        out.append(f"{tag} {indent}{safe(f'{pid} {label}')}{cross}")
        for line in note or []:
            out.append(f"{tag} {'  ' * depth}   {safe(line)}")
        prev = os_
    return out


# ------------------------------------------------------------------ exe-exec-trace の記録 (純粋な関数)

# 要求元はダイアログに気付く前に終わっていることが多い (Claude Code の GitHub SSH の確かめは 3 秒で
# kill される) ので、exe-exec-trace が journald に残した直近の記録からも木を出す (ADR 020)。
# unit の名前は nix/home/modules/exe-exec-trace.nix と scripts/setup.sh に揃える
UNIT = "dotfiles-exe-exec-trace"
RECENT_DEFAULT = 180  # 遡る秒数の既定。1Password のダイアログは約 60 秒で時間切れになる
ALIVE_SKEW_MS = 3000  # 代理プロセスの起動時刻と記録の時刻の差がこの幅なら、記録の要求元がまだ動いている
SINCE_SLACK_S = 5  # journald の時刻と記録の時刻は数 ms ずれるので、journalctl には多めに遡らせる
SESSION_LABEL = "/init  (WSL のセッション)"
SESSION_COMM = re.compile(r"^Relay\(\d+\)$")  # WSL のセッションの /init の comm
PARENT_IS_INIT = "親は /init: 親が先に終了したか、wsl.exe -e を踏み台にした要求 (踏み台の wsl.exe の記録が近くに並ぶ)"
# 踏み台かもしれない .exe の引数に、agent に届く exe がコマンドとして出てくるか (cmd.exe /c ssh.exe … や
# wsl.exe -e …/ssh.exe …)。cmd.exe を踏み台にすると Linux 側に ssh.exe が現れず、記録は cmd.exe だけになる
TRAMPOLINE_ARG = re.compile(r"(?:^|[\\/\s\"'])(?:ssh|ssh-add|scp|sftp|op-ssh-sign|op-ssh-sign-wsl)(?:\.exe)?(?=$|[\s\"'])", re.I)
EPOCH = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)


def record_ms(rec):
    """記録の time (ISO 8601。ミリ秒とタイムゾーン付き) を epoch ms にする。読めなければ None"""
    try:
        return (datetime.datetime.fromisoformat(rec["time"]) - EPOCH) // datetime.timedelta(milliseconds=1)
    except (KeyError, TypeError, ValueError):
        return None


def is_trampoline(rec):
    """agent に届かない .exe の記録のうち、引数 (argv[1:]) で agent に届く exe を呼んでいるもの"""
    argv = rec.get("argv")
    return (
        rec.get("agent") is not True
        and isinstance(argv, list)
        and any(isinstance(a, str) and TRAMPOLINE_ARG.search(a) for a in argv[1:])
    )


def parse_records(lines, now_ms, window_ms):
    """journalctl -o cat の行から、agent に届く .exe と、それを呼ぶ踏み台 (is_trampoline) の記録のうち、
    now_ms - window_ms 以降のものを古い順に返す。

    記録でない行 (起動のメッセージなど)・形の欠けた記録・time の読めない記録は黙って飛ばす。
    """
    out = []
    for line in lines:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not (
            isinstance(rec, dict)
            and isinstance(rec.get("exe"), str)
            and isinstance(rec.get("pid"), int)
            and isinstance(rec.get("kernel_ancestry"), list)
            and (rec.get("agent") is True or is_trampoline(rec))
        ):
            continue
        t = record_ms(rec)
        if t is not None and t >= now_ms - window_ms:
            out.append((t, rec))
    out.sort(key=lambda x: x[0])
    return [rec for _, rec in out]


def exe_name(rec):
    return rec["exe"].rsplit("/", 1)[-1]


def record_nodes(rec):
    """記録 1 件から、根から順の Linux 側の節 (os, pid, label, note) の列を作る。末端が記録の .exe。

    木は、カーネルが exec の時点で集めた祖先 (kernel_ancestry) でたどる (親が後で終わっても変わらない)。
    ラベルは /proc で取れた祖先のコマンドライン (ancestry) を PID で引き、無ければ comm にする。
    セッションの /init (コマンドラインが /init、無ければ comm が Relay(<pid>)) で止める。
    """
    cmdlines = {a.get("pid"): a.get("cmdline") for a in rec.get("ancestry") or [] if isinstance(a, dict)}
    chain, at_session = [], False
    for a in rec["kernel_ancestry"]:
        if not isinstance(a, dict):
            continue
        pid, comm = a.get("pid"), str(a.get("comm") or "?")
        cmd = cmdlines.get(pid)
        if cmd == "/init" or (cmd is None and SESSION_COMM.match(comm)):
            chain.append(("L", pid, SESSION_LABEL, None))
            at_session = True
            break
        chain.append(("L", pid, str(cmd) if cmd else comm, None))

    argv = rec.get("argv")
    label = join_argv([exe_name(rec)] + [str(x) for x in argv[1:]]) if isinstance(argv, list) and argv else exe_name(rec)
    note = []
    if rec.get("cwd"):
        note.append(f"cwd {rec['cwd']}")
    env = rec.get("env")
    if isinstance(env, dict) and env:
        note.append("env " + " ".join(f"{k}={v}" for k, v in env.items()))
    if at_session and len(chain) == 1:
        note.append(PARENT_IS_INIT)
    return list(reversed(chain)) + [("L", rec["pid"], label, note or None)]


def stub_matches(rec, argv, start):
    """記録の PID に今いるプロセス (argv と、epoch ms の起動時刻 start) が、記録の代理プロセスそのものか。

    PID は使い回されるので、exe の名前と起動時刻 (記録から ALIVE_SKEW_MS 以内) で見分ける。
    他のディストロの記録は、PID の名前空間が違うので、ここの /proc とは比べない。
    """
    if rec.get("distro") != "this" or not is_stub(argv) or start is None:
        return False
    t = record_ms(rec)
    same_exe = argv[1].rsplit("/", 1)[-1].lower() == exe_name(rec).lower()
    return same_exe and t is not None and abs(start - t) <= ALIVE_SKEW_MS


NOT_INSTALLED = "(exe-exec-trace が入っていないので記録は読まない。入れるには dotfiles.wsl.exeExecTrace.enable を true にして setup --update)"
NO_JOURNALCTL = "(journalctl が無いので記録は読まない)"
NO_PERMISSION = "(他のユーザーの記録が見えない。adm か systemd-journal のグループに入ると読める)"
# journalctl が「system の記録を読めていない」と知らせる文 (stderr)
PERMISSION_HINTS = ("not seeing messages from other users", "insufficient permissions")


def fmt_window(sec):
    """遡る長さの見出し用の書き方。60 で割り切れれば分、でなければ秒"""
    return f"{sec // 60} 分" if sec % 60 == 0 else f"{sec} 秒"


def parse_unit_state(text):
    """systemctl show --property=LoadState,ActiveState の出力から (LoadState, ActiveState)"""
    kv = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
    return kv.get("LoadState"), kv.get("ActiveState")


def journalctl_message(returncode, stderr):
    """journalctl の結果から、記録を読めなかったときに出す 1 行。読めたら None"""
    if any(h in stderr for h in PERMISSION_HINTS):
        return NO_PERMISSION
    if returncode != 0:
        first = next((s.strip() for s in stderr.splitlines() if s.strip()), "")
        return f"(記録を読めなかった: {first or f'終了コード {returncode}'})"
    return None


def journal_body(recs, alive, recent_s):
    """記録の節の中身 (節の見出しは除く)。記録ごとに見出しと木を出す。alive(rec) は要求元がまだ動いているか"""
    if not recs:
        return [f"(none: 直近 {fmt_window(recent_s)}に記録された要求は無い)", ""]
    out = []
    for rec in recs:
        t = record_ms(rec)
        if rec.get("distro") == "this":
            where = f"Linux pid {rec['pid']}"
            state = "動いている (下の木にも出る)" if alive(rec) else "終了済み"
        else:
            # 他のディストロの PID はここの /proc と名前空間が違うので、動いているかは見ない
            where = f"{rec.get('distro')} pid {rec['pid']}"
            state = "他のディストロ: 祖先は comm だけ"
        mark = "  (踏み台かもしれない .exe)" if is_trampoline(rec) else ""
        out += [safe(f"== {exe_name(rec)}  {where}  起動 {hhmmss(t)} ({ago(t)})  {state}{mark}"), *render(record_nodes(rec)), ""]
    if len(recs) > 1:
        out.append("ダイアログの要求は、たいてい一番新しいもの (一番下)")
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
        return join_argv([argv[1].rsplit("/", 1)[-1]] + argv[3:])
    if argv == ["/init"]:
        sock = f"/run/WSL/{pid}_interop"
        return "/init  (WSL のセッション" + (f": {sock}" if os.path.exists(sock) else "") + ")"
    return join_argv(argv)


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


# ------------------------------------------------------------------ exe-exec-trace の記録 (systemctl / journalctl / /proc)


def unit_state():
    """exe-exec-trace の unit の (LoadState, ActiveState)。systemctl が無い・失敗したら (None, None)"""
    try:
        r = subprocess.run(
            ["systemctl", "show", "--property=LoadState,ActiveState", UNIT],
            capture_output=True, stdin=subprocess.DEVNULL, timeout=10, text=True, errors="replace",
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, None
    return parse_unit_state(r.stdout) if r.returncode == 0 else (None, None)


def read_journal(since_s):
    """exe-exec-trace の記録のうち since_s (epoch 秒) 以降の行と、読めなかったときに出す 1 行 (読めたら None)。

    journalctl は system のもの (PATH) を使う。記録の形式が system の journald と揃っている方が確実なため。
    -q は付けない (system の記録を読めないときの Hint を stderr で見る)。
    """
    try:
        r = subprocess.run(
            ["journalctl", "-u", UNIT, "--since", f"@{since_s}", "-o", "cat", "--no-pager"],
            capture_output=True, stdin=subprocess.DEVNULL, timeout=20, text=True, errors="replace",
        )
    except FileNotFoundError:
        return [], NO_JOURNALCTL
    except subprocess.TimeoutExpired:
        return [], "(記録を読めなかった: 20 秒で返らなかった)"
    except OSError as e:
        return [], f"(記録を読めなかった: {e})"
    msg = journalctl_message(r.returncode, r.stderr)
    return ([], msg) if msg else (r.stdout.splitlines(), None)


def is_alive(rec, boot):
    """記録の要求元 (interop の代理プロセス) が、まだ動いているか"""
    if rec.get("distro") != "this":
        return False
    return stub_matches(rec, argv_of(rec["pid"]), start_ms(rec["pid"], boot))


def journal_lines(recent_s, boot):
    """記録の節の行 (見出しから、最後の空行まで)。unit の状態を見て、journal を読み、記録ごとに木を出す"""
    out = [f"## 直近 {fmt_window(recent_s)}に起動された要求 (exe-exec-trace の記録、古い順)"]
    _, active = state = unit_state()
    if state[0] == "not-found":
        return out + [NOT_INSTALLED, ""]
    lines, msg = read_journal(int(NOW - recent_s - SINCE_SLACK_S))
    if msg:
        return out + [safe(msg), ""]
    recs = parse_records(lines, int(NOW * 1000), recent_s * 1000)
    out += journal_body(recs, lambda rec: is_alive(rec, boot), recent_s)
    if active not in (None, "active"):
        out.append(safe(f"(exe-exec-trace が動いていない (ActiveState={active})。止まっている間の要求は記録に無い)"))
    if out[-1] != "":
        out.append("")
    return out


# ------------------------------------------------------------------ main


def non_negative_int(s):
    """--recent の値 (0 以上の整数)"""
    try:
        n = int(s)
    except ValueError:
        n = -1
    if n < 0:
        raise argparse.ArgumentTypeError(f"0 以上の整数で渡す: {s!r}")
    return n


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="pjp-who-is-asking",
        description="1Password の承認ダイアログが出たときに、直近の要求 (exe-exec-trace の記録) と、"
        "いま動いている要求元を Windows と Linux をまたいだ木で出す",
    )
    ap.add_argument("--no-windows", action="store_true", help="Windows 側 (powershell.exe で 1〜2 秒かかる) を省き、Linux 側の木だけ出す")
    ap.add_argument(
        "--recent",
        type=non_negative_int,
        default=RECENT_DEFAULT,
        metavar="SEC",
        help=f"exe-exec-trace の記録を何秒遡って出すか (既定 {RECENT_DEFAULT}。0 なら記録を読まない)",
    )
    opts = ap.parse_args(argv)

    boot = boot_time()
    if opts.recent > 0:
        # 記録の節は Windows 側 (powershell.exe で 1〜2 秒) を待たずに出せるので、先に出す
        print("\n".join(journal_lines(opts.recent, boot)), flush=True)
    stubs = linux_stubs(boot)
    linux_nodes = make_linux_nodes(boot)
    lines = []
    if opts.no_windows:
        lines.append("## いま動いている .exe (Linux 側だけ)")
        if not stubs:
            lines.append("(none: 動いている .exe は無い)")
        for lp in sorted(stubs, key=lambda x: stubs[x]["t"] or 0):
            mark = "" if AGENT.match(stubs[lp]["name"]) else "  (踏み台かもしれない .exe)"
            lines += [f"== {stubs[lp]['name']}  Linux pid {lp}{mark}", *render(linux_nodes(lp)), ""]
        print("\n".join(lines))
        return 0

    # 見出しは powershell.exe を待つ前に出す (取れなかったときの知らせが見出しの下に来るように)
    print("## いま動いている ssh.exe など (Windows と Linux の木)", flush=True)
    procs = windows_procs()
    pair = pair_up(procs, stubs)
    targets = sorted((p for p in procs.values() if AGENT.match(p["name"])), key=lambda p: p["t"])
    if not targets:
        lines += ["(none: いま動いている ssh.exe などは無い)", ""]
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
