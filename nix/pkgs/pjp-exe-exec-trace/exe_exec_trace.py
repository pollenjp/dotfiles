"""WSL から Windows の .exe (ssh.exe など) が起動されるたびに、起動元の祖先を記録する。

WSL2 の全ディストロは 1 つのカーネルを共有しているので、sched_process_exec を eBPF で
見ると他ディストロの起動も拾える。起動したタスクの祖先 (PID は各ディストロの pid
namespace での値、comm) はカーネル側で集める。このディストロのプロセスなら、
/proc から argv / cwd / env / 祖先の cmdline も引く。

wsl.exe や cmd.exe を踏み台にされると、ssh.exe の祖先は新しいセッションの /init で
途切れる。そのときは直前に起動した踏み台の .exe の祖先が要求元なので、既定では
全ての .exe を記録する (ssh.exe などには agent=true を付ける)。

systemd の unit (dotfiles-exe-exec-trace.service) は --json で動かし、記録は journald に
1 行 1 イベントで残る。人が読むときは --pretty に流す:

    journalctl -u dotfiles-exe-exec-trace -o cat | pjp-exe-exec-trace --pretty

経緯は docs/adr/012_wsl_exe_exec_trace_service_20260930T153253JST/README.md。
"""

import argparse
import ctypes as ct
import datetime
import json
import os
import re
import shlex
import socket
import sys

PROG = r"""
#include <linux/sched.h>
#include <linux/pid.h>
#include <linux/pid_namespace.h>

#define MAX_DEPTH 12
#define FNAME_LEN 256

struct event_t {
    u32 pid;       /* 起動したプロセスの tgid (そのタスクの pid namespace での値) */
    u32 pidns;     /* そのタスクの pid namespace の inode 番号 (ディストロの区別に使う) */
    u32 uid;
    u32 depth;
    char filename[FNAME_LEN];
    u32 anc_pid[MAX_DEPTH];
    char anc_comm[MAX_DEPTH][TASK_COMM_LEN];
};

BPF_PERF_OUTPUT(events);
BPF_PERCPU_ARRAY(scratch, struct event_t, 1);

/* プロセス (thread group leader) の PID。
   このトレーサの pid namespace (MY_PIDNS。-D で渡す) から見えるなら、そこでの値を返す。
   コンテナや sandbox (unshare --pid) の中の入れ子のプロセスも、こちらの /proc で引ける
   番号になり、祖先も入れ子の外までたどれる。見えなければ (他ディストロ)、そのプロセス
   自身の namespace での値を返す。*inum には、見えたなら MY_PIDNS、でなければ自身の
   namespace の inode 番号を入れる */
static __always_inline u32 ns_tgid(struct task_struct *t, u32 *inum) {
    struct task_struct *leader = NULL;
    struct pid *p = NULL;
    unsigned int level = 0;
    struct upid up = {};
    u32 ino = 0;
    bpf_probe_read_kernel(&leader, sizeof(leader), &t->group_leader);
    bpf_probe_read_kernel(&p, sizeof(p), &leader->thread_pid);
    bpf_probe_read_kernel(&level, sizeof(level), &p->level);
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        if (i > level)
            break;
        bpf_probe_read_kernel(&up, sizeof(up), &p->numbers[i]);
        bpf_probe_read_kernel(&ino, sizeof(ino), &up.ns->ns.inum);
        if (ino == MY_PIDNS) {
            if (inum)
                *inum = ino;
            return up.nr;
        }
    }
    bpf_probe_read_kernel(&up, sizeof(up), &p->numbers[level & 31]);
    if (inum)
        bpf_probe_read_kernel(inum, sizeof(*inum), &up.ns->ns.inum);
    return up.nr;
}

TRACEPOINT_PROBE(sched, sched_process_exec) {
    int zero = 0;
    struct event_t *e = scratch.lookup(&zero);
    if (!e)
        return 0;

    unsigned short off = args->data_loc_filename & 0xFFFF;
    bpf_probe_read_kernel_str(e->filename, sizeof(e->filename), (void *)args + off);
    /* ".exe" (大文字小文字は問わない) で終わるものだけ残す。返り値の長さから添字を作ると
       bcc の helper が int を返すせいで verifier が範囲を見失うので、先頭から走査する */
    int found = 0;
    for (int k = 0; k < FNAME_LEN - 4; k++) {
        if (e->filename[k] == 0)
            break;
        if (e->filename[k] == '.' && (e->filename[k + 1] | 0x20) == 'e' &&
            (e->filename[k + 2] | 0x20) == 'x' && (e->filename[k + 3] | 0x20) == 'e' &&
            e->filename[k + 4] == 0) {
            found = 1;
            break;
        }
    }
    if (!found)
        return 0;

    struct task_struct *t = (struct task_struct *)bpf_get_current_task();
    e->pid = ns_tgid(t, &e->pidns);
    e->uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
    e->depth = 0;

    struct task_struct *p = NULL, *pl = NULL;
    bpf_probe_read_kernel(&p, sizeof(p), &t->real_parent);
    #pragma unroll
    for (int k = 0; k < MAX_DEPTH; k++) {
        if (!p)
            break;
        u32 ppid = ns_tgid(p, NULL);
        e->anc_pid[k] = ppid;
        /* PID は thread group leader のものなので、comm も leader から取る */
        bpf_probe_read_kernel(&pl, sizeof(pl), &p->group_leader);
        bpf_probe_read_kernel(e->anc_comm[k], TASK_COMM_LEN, &pl->comm);
        e->depth = k + 1;
        if (ppid <= 1)
            break;
        bpf_probe_read_kernel(&p, sizeof(p), &p->real_parent);
    }
    events.perf_submit(args, e, sizeof(*e));
    return 0;
}
"""

MAX_DEPTH = 12
FNAME_LEN = 256
TASK_COMM_LEN = 16


# bcc は char[12][16] の ctypes を自動生成できないので手で書く (PROG の struct event_t と揃える)
class Event(ct.Structure):
    _fields_ = [
        ("pid", ct.c_uint32),
        ("pidns", ct.c_uint32),
        ("uid", ct.c_uint32),
        ("depth", ct.c_uint32),
        ("filename", ct.c_char * FNAME_LEN),
        ("anc_pid", ct.c_uint32 * MAX_DEPTH),
        ("anc_comm", (ct.c_char * TASK_COMM_LEN) * MAX_DEPTH),
    ]


# 1Password の agent (named pipe) か署名に届きうる .exe
AGENT = re.compile(r"^(ssh|ssh-add|scp|sftp|op-ssh-sign|op-ssh-sign-wsl)\.exe$", re.I)
# 要求元の手掛かりになる env (親が先に終了して祖先が途切れても、子へ引き継がれる)
ENV_KEYS = ("WSL_INTEROP", "WT_SESSION", "HERDR_PANE_ID", "TMUX", "SSH_CONNECTION", "CLAUDE_CODE_SESSION_ID")
REPARENTED = "    (親は既に終了していて、/proc の祖先は付け替え後のもの)"

# argv や cmdline の 1 つの長さの上限。journald の 1 行の上限 (LineMax、既定 48K) を超えると
# 記録が割れるのと、コマンドラインの秘密を長く残しすぎないため
FIELD_MAX = 1024
ARGV_MAX = 64

# 記録の中身 (argv・cwd・ファイル名) は記録される側が決められる。改行や ESC をそのまま
# 表示すると、偽の行を差し込んだり端末を操作したりできるので、表示するときに \xNN にする
CTRL = re.compile(r"[\x00-\x1f\x7f]")


def safe(s):
    return CTRL.sub(lambda m: f"\\x{ord(m.group()):02x}", str(s))


def clip(s):
    return s if len(s) <= FIELD_MAX else s[: FIELD_MAX - 1] + "…"


def is_agent(exe):
    return bool(AGENT.match(exe))


def stub_argv(argv):
    """interop の代理プロセスの argv は ["/init", <exe のパス>, <argv0>, <引数…>] なので先頭 2 つを落とす"""
    return argv[2:] if len(argv) >= 2 and argv[0] == "/init" else argv


def clip_argv(argv):
    out = [clip(a) for a in argv[:ARGV_MAX]]
    if len(argv) > ARGV_MAX:
        out.append(f"…(+{len(argv) - ARGV_MAX})")
    return out


class ProcFS:
    """/proc を読む (テストでは同じ形の偽物に差し替える)"""

    @staticmethod
    def _read(pid, name):
        try:
            with open(f"/proc/{pid}/{name}", "rb") as f:
                return f.read()
        except OSError:
            return None

    def argv(self, pid):
        raw = self._read(pid, "cmdline")
        return raw.rstrip(b"\0").decode(errors="replace").split("\0") if raw else None

    def cwd(self, pid):
        try:
            return os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            return None

    def environ(self, pid):
        items = (self._read(pid, "environ") or b"").decode(errors="replace").split("\0")
        return dict(x.split("=", 1) for x in items if "=" in x)

    def ppid(self, pid):
        m = re.search(rb"^PPid:\s+(\d+)", self._read(pid, "status") or b"", re.M)
        return int(m.group(1)) if m else 0


def make_record(ev, my_pidns, proc, now):
    """カーネルから来た 1 件 (ev) を、JSON に書き出す記録にする。

    ev: {"filename", "pid", "uid", "pidns", "kernel_ancestry": [(pid, comm), …]}
    このディストロのプロセスなら /proc から詳細を足す (.exe が既に終わっていれば取れない)。
    """
    rec = {
        "time": now,
        "exe": ev["filename"],
        "agent": is_agent(ev["filename"].rsplit("/", 1)[-1]),
        "pid": ev["pid"],
        "uid": ev["uid"],
        "distro": "this" if ev["pidns"] == my_pidns else f"other(pidns={ev['pidns']})",
        # カーネルで集めた祖先 (exec の時点のもの。後で親が終わっても変わらない)
        "kernel_ancestry": [{"pid": p, "comm": c} for p, c in ev["kernel_ancestry"]],
    }
    if ev["pidns"] != my_pidns:
        return rec  # 他ディストロの /proc は見えない
    argv = proc.argv(ev["pid"])
    rec["argv"] = clip_argv(stub_argv(argv)) if argv else None
    cwd = proc.cwd(ev["pid"])
    rec["cwd"] = clip(cwd) if cwd else None
    rec["env"] = {k: clip(v) for k, v in proc.environ(ev["pid"]).items() if k in ENV_KEYS}
    anc, p = [], proc.ppid(ev["pid"])
    while p > 1 and len(anc) < 20:
        a = proc.argv(p)
        # シェルの引用でつなぐ (1 つの引数に空白があっても区切りが分かるように)
        anc.append({"pid": p, "cmdline": clip(shlex.join(a)) if a else None})
        p = proc.ppid(p)
    rec["ancestry"] = anc
    return rec


def format_record(rec):
    """記録 1 件を人が読む形 (複数行) にする。記録から来る文字列は safe() を通す。

    引数は 1 引数 1 行で、祖先のコマンドラインは 1 プロセス 1 行で、記録してある分を切らずに出す
    (Claude の Bash ツールの zsh -c は、実際のコマンドが長い前置きの後ろにあるため)。
    """
    exe = safe(rec["exe"].rsplit("/", 1)[-1])
    mark = "" if rec.get("agent") else "  (踏み台かもしれない .exe)"
    lines = [f"{safe(rec['time'])}  {exe}  pid={rec['pid']} uid={rec['uid']} distro={safe(rec['distro'])}{mark}"]
    argv = rec.get("argv")
    for i, a in enumerate([argv] if isinstance(argv, str) else argv or []):
        lines.append(f"    argv[{i}]: {safe(a)}")
    if rec.get("cwd"):
        lines.append(f"    cwd : {safe(rec['cwd'])}")
    if rec.get("env"):
        lines.append("    env : " + safe(" ".join(f"{k}={v}" for k, v in rec["env"].items())))
    kanc = rec.get("kernel_ancestry") or []
    lines.append("    at exec: " + " <- ".join(f"{safe(a['comm'])}({a['pid']})" for a in kanc))
    anc = rec.get("ancestry") or []
    if anc and kanc and anc[0]["pid"] != kanc[0]["pid"]:
        lines.append(REPARENTED)
    for a in anc:
        lines.append(f"      {a['pid']:<7} {safe(a['cmdline'] or '?')}")
    return "\n".join(lines)


def pretty(lines, only_agent=False):
    """journald から読んだ行を人が読む形にする。

    記録でない行 (起動のメッセージなど) と、読めない記録 (形が古い・欠けている) は
    そのまま返す (制御文字だけ \\xNN にする)。only_agent なら agent に届く .exe の記録だけ出す。
    """
    for line in lines:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            yield safe(line)
            continue
        if not (isinstance(rec, dict) and "exe" in rec and "kernel_ancestry" in rec):
            yield safe(line)
            continue
        if only_agent and not rec.get("agent"):
            continue
        try:
            yield format_record(rec)
        except (KeyError, TypeError, AttributeError):
            yield safe(line)


def sd_notify(msg, env=os.environ):
    """systemd (Type=notify) に状態を知らせる。NOTIFY_SOCKET が無ければ何もしない"""
    addr = env.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):  # abstract namespace
        addr = "\0" + addr[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
        s.connect(addr)
        s.sendall(msg.encode())


def trace(opts):
    from bcc import BPF  # トレースするときだけ読み込む (テストと --pretty は bcc も root も要らない)

    my_pidns = os.stat("/proc/self/ns/pid").st_ino
    proc = ProcFS()
    b = BPF(text=PROG, cflags=["-Wno-duplicate-decl-specifier", f"-DMY_PIDNS={my_pidns}U"])

    def handle(_cpu, data, _size):
        e = ct.cast(data, ct.POINTER(Event)).contents
        ev = {
            "filename": e.filename.decode(errors="replace"),
            "pid": e.pid,
            "uid": e.uid,
            "pidns": e.pidns,
            "kernel_ancestry": [(e.anc_pid[k], e.anc_comm[k].value.decode(errors="replace")) for k in range(e.depth)],
        }
        now = datetime.datetime.now().astimezone().isoformat(timespec="milliseconds")
        rec = make_record(ev, my_pidns, proc, now)
        if opts.only_agent and not rec["agent"]:
            return
        print(json.dumps(rec, ensure_ascii=False) if opts.json else format_record(rec), flush=True)

    b["events"].open_perf_buffer(handle, page_cnt=64)
    print("tracing .exe execs... (Ctrl-C で終了)", file=sys.stderr, flush=True)
    # unit は Type=notify。BPF を読み込み終えてから起動の完了を知らせるので、
    # systemctl restart はここまで待ち、読み込みに失敗すれば restart が失敗する
    sd_notify("READY=1")
    while True:
        try:
            b.perf_buffer_poll()
        except KeyboardInterrupt:
            return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="pjp-exe-exec-trace", description=__doc__.splitlines()[0])
    ap.add_argument("--only-agent", action="store_true", help="ssh.exe / ssh-add.exe / op-ssh-sign-wsl.exe など agent に届くものだけ記録する")
    ap.add_argument("--json", action="store_true", help="1 イベント 1 行の JSON で出す (journald に流す用)")
    ap.add_argument("--pretty", action="store_true", help="標準入力の JSON の記録を人が読む形にする (root は要らない)")
    opts = ap.parse_args(argv)
    if opts.pretty:
        try:
            for block in pretty(sys.stdin, only_agent=opts.only_agent):
                print(block, flush=True)
        except BrokenPipeError:
            # head などで途中で閉じられた。終了時の flush でもう一度落ちないよう、出力先を捨てる
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0
    if os.geteuid() != 0:
        print(
            "pjp-exe-exec-trace: 記録するには root が要る (systemd の unit か sudo で動かす)。"
            "記録を読むだけなら --pretty に journalctl の出力を流す",
            file=sys.stderr,
        )
        return 1
    return trace(opts)


if __name__ == "__main__":
    sys.exit(main())
