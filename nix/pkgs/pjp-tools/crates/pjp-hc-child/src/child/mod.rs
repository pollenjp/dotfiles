//! `pjp child` (spec §7.4〜§7.8): ハブの会話が、子のマシンに子の Claude Code を立てる・読む・送る・片付ける。
//!
//! 子のマシンのコマンドは `hc exec [--on <m>]` で打ち、子の claude は `hc run --on <m> --outlive-parent` で立てる
//! (ハブの会話の子になる)。英字の控えはハブのマシンに置く ([`crate::ledger`])。

mod account;
mod agent;
mod cleanup;
mod grand;
mod machine;
mod misc;
mod new;

use std::io::Write;

use pjp_core::exit::{self, CONFIG};
use pjp_core::{Error, Result};
use serde_json::Value;

use crate::hc::{Hc, Runner, label_of};
use crate::ledger::{Ledger, Row};

pub use machine::WSL_ADD;

const USAGE: &str = "\
pjp child — hc と herdr-app で子の Claude Code を立てる・読む・送る・片付ける (ハブの会話から打つ)

使い方:
  pjp child new --agent <名前> --label '<repo>: <一言>' --brief <依頼のファイル>
                (--repo <owner/repo> | --checkout <子のマシンの repo> | --dir <子のマシンのディレクトリ>)
                [--on <machine>|local|wsl|auto] [--base <branch>] [--effort low|medium|high|xhigh|max (既定 high)]
                [--pack <pack>]… [--synced <名前>]… [--chrome] [--account <名前>|default] [--ticket <TKT-n>] [--dry-run]
  pjp child restart <英字> [--effort …] [--pack …]… [--synced …]… [--chrome | --no-chrome]
                [--session <会話の ID> | --fresh] [--brief <ファイル>] [--force] [--account <名前>|default]
                [--ticket <TKT-n>]
  pjp child ls [--all] [--ticket <TKT-n>]
  pjp child send <英字> (--file <ファイル> | <文>) [--no-agent-check] [--ticket <TKT-n>]
  pjp child read <英字> [--lines N] [--ticket <TKT-n>]
  pjp child report (<文> | --file <ファイル>) [--no-agent-check]   子の会話から、親 (指揮役) に 1 行で知らせる
  pjp child cleanup <英字> [--no-pr] [--branch <作業の branch>] [--repo <owner/repo>] [--force] [--dry-run]
                [--ticket <TKT-n>]

new      子のマシンで checkout を探し (無ければ ghq get)、fetch して既定の branch から worktree/<名前> を切って
         ~/.herdr/worktrees/<repo>/<名前> に worktree を作り、herdr-app の space を作って、hc run で claude を立てる。
         依頼は起動の引数で渡す。英字は親のチケットごとに A・B… と振る (使い回さない)。
         herdr-app の無いマシン (Linux のハブ) では、新しい id の label herdr.space・herdr.tab で立てて herdr-app (Windows) に
         space を作らせ、子のマシンの hc の doc herdr-app で名前を付ける (herdr-app が作らなければ、名前つきの space を doc に足す)。
         GitHub へ出る fetch・ghq get は gh の資格情報で打つ (git gh があればそれ、無ければ同じ組を git -c・env で付ける)。
         子はハブと同じ Claude のアカウントで立てる: ハブの CLAUDE_CONFIG_DIR が空・~/.claude なら素の claude、
         ~/.claude-<名前> なら子のマシンの claude-<名前> (--account で替える。default は素の claude)。claude-<名前> が無い・
         用意 (~/.claude-<名前>/.credentials.json か ~/.config/claude-accounts/<名前>.env) が無ければ、何も作らずに止まる
restart  同じ worktree・英字で claude を立て直す (--continue。--session なら --resume <ID>)。effort を上げるときなど。
         --fresh は前の会話を続けずに新しい会話で立てる (前の作業の文脈を持ち越さない。--brief が要り、pjp.ticket は引き継がない)
         effort・pack・chrome・アカウントは、渡さなければ前の起動の値を引き継ぐ (--pack か --synced を渡すと pack は渡したものだけ。
         effort は控えに前の値が無ければ high)
         herdr-app の無いマシンでは、前の端末を消すのを新しい端末が space に入った後にし (space を空にしない。立てられなければ
         前の端末は終えたまま残す)、space の名前を前と同じにする
         前の端末を終える前に、その端末が立てた端末 (孫) を探して知らせる (残った孫の親は消えた端末のままになり、herdr-app の
         Agents 欄の木で新しい子の下に出ない)。子が working か、前の端末と一緒に終わる孫 (--outlive-parent なしで立てた端末) が
         いれば止まる (--force で進む)。孫を探せなくても止めない。
         前の端末の見ていない解説動画の印 (🎬✅) は新しい端末へ引き継ぐ。作りかけの印 (🎬⏳) があり、前の端末の Claude が
         動いていれば止まる (前の端末を終えると作るのが止まる。--force なら引き継がずに立て直す)
ls       この会話 (親のチケット) の子を並べる (--all で片付けた子も)
send     子に文を送る (hc send。子が確認の画面で止まっていれば断られる)。送る前に hc get の状態の報告 (OSC 7501) と
         前面のプロセスで、子の端末で Claude が動いているかを確かめ、動いていない (Claude が終わって shell に戻った)・
         確かめられないなら送らずに終了コード 1 (shell が文を 1 行ずつコマンドとして打たないように)。
         --no-agent-check はこの確かめを飛ばす (わざと shell に送るときだけ)。report も親に同じ確かめをする
read     子の画面と履歴を読む (--lines は画面の上の履歴の行数。0 は画面だけ。既定 120)
cleanup  子の PR が merge 済み・worktree に変更が無い・孫がいない・働いていないのを確かめてから、hc kill → hc rm →
         space を閉じる → worktree と branch を消す (hc send の /exit は札で包まれて効かないので送らない)。
         herdr-app の無いマシンでは space.close を打たず、子の端末を消した後に herdr-app が space を消すのを待ち、残っていて
         中にほかの生きた端末が無ければ hc の doc herdr-app から消す。子の space に子のほかの端末 (ユーザーが開いた shell
         など) がいれば片付けない (--force なら、その端末と space を残して進む)。
         作業の branch は worktree の今の branch (detached なら reflog の直前の branch)。分からなければ --branch で渡す。
         控えに repo の無い子 (--checkout・--dir で立てた子) の PR は、--repo と --branch で渡せば確かめる。
         子の見ていない解説動画の印 (🎬✅) は、子を終える前にこの会話の端末 (hc の端末の外なら子の hc の親) へ移す
         (ユーザーが見るまで親の行に出る)。作りかけの印 (🎬⏳) があり、子の Claude が動いていれば片付けない (--force なら捨てる)。
         立てられなかった子は、控えだけを片付ける

親のチケットは、この端末の label pjp.ticket (pjp mark name で付く)、--ticket、どちらも無ければこの端末の住所で決める。
PowerShell では ~ を引用符で囲む ('~/h')。囲まないと Windows のホームに替わる。

子のマシンは --on (local はこのマシン、wsl は手元の WSL、auto は自動)、無ければ ~/.config/pjp/hub.toml の default_machine (同じ値)、
それも無ければ自動で選ぶ。手元の WSL は hc machine ls の --via の machine で、そのコマンドが wsl.exe のもの (名前は見ない)。wsl は
それが 1 つならそれ、2 つ以上なら名前が wsl のものを選び、無い・決まらない・connected でなければ止まる (無ければ足し方を出す:
hc machine add --via 'wsl.exe -d <ディストリビューション> --cd ~ -e bash -lc' --name <名前>。名前は自由)。local・wsl・auto は
machine の名前より先に語として読む (名前が wsl の SSH 先は --on wsl では選ばない)。
自動は hc machine ls の machine を SSH 先 → 手元の WSL の順に見る。
connected の machine を hc exec 1 回で測り (uname -s・nproc・/proc/loadavg・MemAvailable)、Linux の machine を空きコア (コア数 - 1 分の
負荷) の多い順 (同じなら空きメモリの多い順) に並べて、子を立てるアカウントの用意 (--repo の子は checkout か ghq も) がある最初の
machine を選ぶ。SSH 先は空きコア 1・空きメモリ 4 GiB 以上の所だけを使い、使える SSH 先が無ければ WSL に落ちる (下限は SSH 先だけに
効き、WSL は負荷によらず使う)。--chrome の子は WSL だけから選ぶ。選んだマシンと測った値・外したわけは出力の頭に出て、選んだマシンと値は
note 用の行にも出る (--dry-run でも測って選ぶ)。WSL でしか動かない作業 (WSL の中を直す・Windows の WSL に依る) は --on wsl、
既にあるパスを --dir で渡す子は --on で渡す。--checkout は --on が要る (自動でよければ --on auto。同じパスのほかのマシンの repo を
選びうるため)。restart・cleanup は立てたときのマシン (wsl で選んだなら、その machine の名前) を使う。hub.toml で変えられる:
  default_machine = \"auto\"     # 省いても自動。machine の名前・local・wsl なら、それに決める
  [auto]
  order = [\"ssh\", \"wsl\"]      # 見る順 (ssh・wsl・local。local はこのマシンで、Linux のハブ向け。WSL を先にすると WSL を毎回選ぶ)
  exclude = [\"host-a\"]          # 選ばない machine の名前 (語は読まない。WSL を見ないなら order から wsl を外す)
  min_free_cores = 1           # SSH 先の空きコアの下限
  min_free_mem_gib = 4         # SSH 先の空きメモリの下限 (GiB)
";

/// `pjp child …` (args は道具の名前を除いたもの)。終了コードを返す。
pub fn main(r: &dyn Runner, args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> u8 {
    let result = run(r, args, out, err);
    exit::report("pjp child", result, err)
}

fn run(r: &dyn Runner, args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> Result<u8> {
    let Some((sub, rest)) = args.split_first() else {
        let _ = write!(err, "{USAGE}");
        return Ok(CONFIG);
    };
    match sub.as_str() {
        "-h" | "--help" => {
            let _ = write!(out, "{USAGE}");
            Ok(exit::OK)
        }
        "new" => new::new(r, rest, out, err),
        "restart" => new::restart(r, rest, out, err),
        "ls" => misc::ls(r, rest, out),
        "send" => misc::send(r, rest, out),
        "read" => misc::read(r, rest, out),
        "report" => misc::report(r, rest, out),
        "cleanup" => cleanup::cleanup(r, rest, out, err),
        _ => Err(Error::config(format!(
            "知らないサブコマンドです: {sub} (new・restart・ls・send・read・report・cleanup。pjp child --help)"
        ))),
    }
}

/// `--help` なら使い方を出して true。
fn help(parsed: &crate::args::Parsed, out: &mut dyn Write) -> bool {
    if parsed.help() {
        let _ = write!(out, "{USAGE}");
    }
    parsed.help()
}

/// この端末 (`HC_TERMINAL_ID`) を読む。hc の端末の外なら None。
fn this_terminal(r: &dyn Runner, hc: &Hc<'_>) -> Result<Option<(String, Value)>> {
    let Some(id) = r.env("HC_TERMINAL_ID") else {
        return Ok(None);
    };
    let term = hc
        .get(&id)?
        .ok_or_else(|| Error::failure(format!("hc にこの端末 ({id}) がありません")))?;
    Ok(Some((id, term)))
}

/// 親のチケット (控えの名前) を決める: `--ticket` → この端末の label `pjp.ticket` → `t-<この端末の住所>`。
fn ledger_key(r: &dyn Runner, hc: &Hc<'_>, ticket: Option<&str>) -> Result<String> {
    if let Some(t) = ticket {
        return Ok(t.to_owned());
    }
    match this_terminal(r, hc)? {
        Some((id, term)) => Ok(label_of(&term, "pjp.ticket")
            .map_or_else(|| crate::ledger::terminal_key(&id), str::to_owned)),
        None => Err(Error::config(
            "親のチケットが分かりません (hc の端末の中で打つか、--ticket TKT-n を付ける)",
        )),
    }
}

/// 親のチケットの控えを開く。
fn open_ledger(r: &dyn Runner, hc: &Hc<'_>, ticket: Option<&str>) -> Result<(Ledger, String)> {
    let key = ledger_key(r, hc, ticket)?;
    let ledger = Ledger::open(&r.state_dir()?.join("children"), &key)?;
    Ok((ledger, key))
}

/// 控えから子を引く。
fn find_child(ledger: &Ledger, letter: &str) -> Result<Row> {
    ledger.find(letter)?.ok_or_else(|| {
        Error::failure(format!(
            "子 {} は控えにありません ({}。pjp child ls で確かめる)",
            letter.to_ascii_uppercase(),
            ledger.path().display()
        ))
    })
}

/// 文のファイルを読む (UTF-8。BOM・UTF-16 の BOM も受ける。PowerShell 5 の Out-File は UTF-16)。
fn read_text_file(path: &str) -> Result<String> {
    let bytes = std::fs::read(path).map_err(|e| Error::io(format!("{path} を読めません"), &e))?;
    let utf16 = |be: bool, rest: &[u8]| -> String {
        let units: Vec<u16> = rest
            .as_chunks::<2>()
            .0
            .iter()
            .map(|&p| {
                if be {
                    u16::from_be_bytes(p)
                } else {
                    u16::from_le_bytes(p)
                }
            })
            .collect();
        String::from_utf16_lossy(&units)
    };
    let text = match bytes.as_slice() {
        [0xFF, 0xFE, rest @ ..] => utf16(false, rest),
        [0xFE, 0xFF, rest @ ..] => utf16(true, rest),
        [0xEF, 0xBB, 0xBF, rest @ ..] => String::from_utf8(rest.to_vec())
            .map_err(|_| Error::failure(format!("{path} は UTF-8 ではありません")))?,
        _ => String::from_utf8(bytes)
            .map_err(|_| Error::failure(format!("{path} は UTF-8 ではありません")))?,
    };
    Ok(text.replace("\r\n", "\n"))
}

/// コマンドラインの長さの上限 (UTF-16 の単位)。Windows は約 32,767 字 (spec §4)。hc のほかの引数の分を残す。
pub const CMDLINE_LIMIT: usize = 30_000;

/// hc に渡す引数の長さを確かめる (Windows のコマンドラインに収まるか。Linux でも同じ上限で断る)。
fn check_cmdline(args: &[String], what: &str) -> Result<()> {
    // 1 引数ごとに、区切りの空白と囲む引用符の 3 字に加え、Windows で逃がす `"` (→ `\"`) と `\` (引用符の前で倍になる) の分を数える
    let total: usize = args
        .iter()
        .map(|a| a.encode_utf16().count() + 3 + a.matches(['"', '\\']).count())
        .sum();
    if total > CMDLINE_LIMIT {
        return Err(Error::config(format!(
            "{what}が長すぎます (コマンドラインが約 {total} 字。{CMDLINE_LIMIT} 字まで)。短くするか、2 つに分けて後半を pjp child send で送る"
        )));
    }
    Ok(())
}

/// 子のマシンのパスを決める: `~`・`~/…` は子のマシンの HOME に、`/…` はそのまま。Windows のパス (PowerShell が `~` を
/// 替えたもの) や相対パスは断る。
fn remote_path(path: &str, home: &str) -> Result<String> {
    if path == "~" {
        return Ok(home.to_owned());
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return Ok(format!(
            "{}/{}",
            home.trim_end_matches('/'),
            rest.trim_start_matches('/')
        ));
    }
    let windows_like = path.contains('\\') || path.as_bytes().get(1) == Some(&b':');
    if path.starts_with('/') && !windows_like {
        return Ok(path.to_owned());
    }
    Err(Error::config(format!(
        "{path} は子のマシンのパスではありません (/… か '~/…' で渡す。PowerShell では ~ を引用符で囲む)"
    )))
}

/// 子のマシンで、HOME・claude・ghq・git-gh・claude-account・(repo の) checkout を 1 回で探る `sh` の script の頭。$1 は `owner/repo` (無ければ空)。
const PROBE_HEAD: &str = r#"printf 'home=%s\n' "$HOME"
c=$(command -v claude 2>/dev/null) || c=
if [ -z "$c" ] && [ -x "$HOME/.local/share/mise/installs/claude/latest/claude" ]; then
  c="$HOME/.local/share/mise/installs/claude/latest/claude"
fi
printf 'claude=%s\n' "$c"
g=$(command -v ghq 2>/dev/null) || g=
printf 'ghq=%s\n' "$g"
printf 'gitgh=%s\n' "$(command -v git-gh 2>/dev/null)"
"#;

/// [`PROBE_HEAD`] と claude-account の断片の後ろ。
const PROBE_TAIL: &str = r#"if [ -n "$1" ] && [ -n "$g" ]; then
  printf 'checkout=%s\n' "$(ghq list -p --exact "$1" 2>/dev/null | head -n 1)"
fi
"#;

/// 子のマシンを 1 回で探る script (頭・claude-account の場所 ([`account::CLAUDE_ACCOUNT_PROBE`])・後ろ)。
fn probe_script() -> String {
    format!("{PROBE_HEAD}{}{PROBE_TAIL}", account::CLAUDE_ACCOUNT_PROBE)
}

/// 子のマシンを探った結果。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Probe {
    home: String,
    claude: String,
    ghq: String,
    /// `git gh` (dotfiles の git-gh) の場所。無ければ空。
    git_gh: String,
    /// 子のマシンの claude-account の場所。無ければ空 (素の claude の子の用意を確かめない)。
    claude_account: String,
    checkout: String,
}

fn probe(hc: &Hc<'_>, machine: Option<&str>, repo: &str) -> Result<Probe> {
    let script = probe_script();
    let out = hc.exec(machine, None, 60, &["sh", "-c", &script, "sh", repo])?;
    if !out.ok() {
        return Err(Error::failure(format!(
            "子のマシン ({}) を探れません: {}",
            machine.unwrap_or("local"),
            out.why()
        )));
    }
    let mut p = Probe::default();
    for line in out.stdout.lines() {
        if let Some((k, v)) = line.split_once('=') {
            let v = v.trim().to_owned();
            match k {
                "home" => p.home = v,
                "claude" => p.claude = v,
                "ghq" => p.ghq = v,
                "gitgh" => p.git_gh = v,
                "claude-account" => p.claude_account = v,
                "checkout" => p.checkout = v,
                _ => {}
            }
        }
    }
    if p.home.is_empty() {
        return Err(Error::failure("子のマシンの HOME が分かりません"));
    }
    Ok(p)
}

/// `hc exec` で git を打ち、落ちたら失敗にする。
fn git(hc: &Hc<'_>, machine: Option<&str>, timeout: u64, args: &[&str]) -> Result<String> {
    let mut argv = vec!["git"];
    argv.extend_from_slice(args);
    let out = hc.exec(machine, None, timeout, &argv)?;
    if !out.ok() {
        return Err(Error::failure(format!(
            "git {} が落ちました: {}",
            args.join(" "),
            out.why()
        )));
    }
    Ok(out.stdout)
}

/// GitHub との通信を gh の資格情報 (HTTPS) に向ける git の設定。dotfiles の `lib/git-via-gh.nix` と同じ組・同じ並び
/// (Claude の会話の env の `GIT_CONFIG_*` と、`git gh` が付けるもの)。`hc exec` の env にはどれも無いので、子のマシンで
/// GitHub へ出る git (fetch・ghq get) には、打つたびにこれを付ける (ユーザーの決まり 2026-11-16)。
const GH_GIT_CONFIG: [(&str, &str); 3] = [
    ("url.https://github.com/.insteadOf", "git@github.com:"),
    ("url.https://github.com/.insteadOf", "ssh://git@github.com/"),
    (
        "credential.https://github.com.helper",
        "!gh auth git-credential",
    ),
];

/// `git -c` で付けるとき、組の前に足す 1 組 (github.com の helper を空にする。`git gh`・`gh auth setup-git` と同じ形)。
/// 設定ファイルの別の helper (Windows の Git Credential Manager など) が gh より先に呼ばれないように。
const GH_HELPER_RESET: (&str, &str) = ("credential.https://github.com.helper", "");

/// 子のマシンの `repo` (checkout か worktree) で、GitHub へ出る git を gh の資格情報で打つ argv。`git gh` があれば
/// `git -C <repo> gh <args>`、無ければ同じ組を `git -c` で付ける (Windows の git も)。
fn gh_git_argv(pr: &Probe, repo: &str, args: &[&str]) -> Vec<String> {
    let mut argv: Vec<String> = vec!["git".into()];
    if pr.git_gh.is_empty() {
        for (k, v) in std::iter::once(GH_HELPER_RESET).chain(GH_GIT_CONFIG) {
            argv.extend(["-c".to_owned(), format!("{k}={v}")]);
        }
        argv.extend(["-C".to_owned(), repo.to_owned()]);
    } else {
        argv.extend(["-C".to_owned(), repo.to_owned(), "gh".to_owned()]);
    }
    argv.extend(args.iter().map(|a| (*a).to_owned()));
    argv
}

/// 中で git を呼ぶ道具 (ghq get) に同じ組を効かせる env (`GIT_CONFIG_COUNT`・`GIT_CONFIG_KEY_<n>`・`GIT_CONFIG_VALUE_<n>`)。
/// helper を空にする 1 組は入れない (Claude の会話の env と同じ。空の値を env で渡せるか確かめていない)。
fn gh_git_env() -> Vec<String> {
    let mut env = vec![format!("GIT_CONFIG_COUNT={}", GH_GIT_CONFIG.len())];
    for (i, (k, v)) in GH_GIT_CONFIG.iter().enumerate() {
        env.push(format!("GIT_CONFIG_KEY_{i}={k}"));
        env.push(format!("GIT_CONFIG_VALUE_{i}={v}"));
    }
    env
}

/// 打つ形の説明 (dry-run と落ちたときの文に添える)。
fn gh_git_how(pr: &Probe) -> &'static str {
    if pr.git_gh.is_empty() {
        "gh の資格情報を git -c で付ける"
    } else {
        "git gh で gh の資格情報を付ける"
    }
}

/// 子のマシンで GitHub へ出る操作 (fetch・ghq get) が落ちたときの文。どのマシンのどの repo のどの操作かと、確かめることと
/// 回避を添える。
fn gh_net_failure(machine: Option<&str>, what: &str, how: &str, out: &crate::hc::ExecOut) -> Error {
    Error::failure(format!(
        "子のマシン ({}) で {what} が落ちました ({how}): {}\n  \
         認証で落ちたなら、子のマシンで gh auth status (github.com にログインしているか) を確かめる。\n  \
         急ぐなら、子のマシンで checkout を用意し (fetch は git -C <checkout> gh fetch origin) worktree を手で切って \
         pjp child new --dir で立てる (片付けは pjp child cleanup <英字> --repo <owner/repo> --branch <作業の branch>)",
        machine.unwrap_or("local"),
        net_why(out)
    ))
}

/// 落ちたわけの 1 行。ghq は stderr の頭に進み具合 (`clone …`) を出すので、`fatal:` の行 (無ければ `error` を含む行) を選ぶ。
fn net_why(out: &crate::hc::ExecOut) -> String {
    let lines = || out.stderr.lines().map(str::trim);
    lines()
        .find(|l| l.starts_with("fatal:"))
        .or_else(|| lines().find(|l| l.contains("error")))
        .map_or_else(|| out.why(), str::to_owned)
}

/// 控えの子の端末を hc で引いた結果。
enum ChildTerm {
    /// 端末が無い (終わって消えた・まだ立っていない)。
    Missing,
    /// 同じ住所に別の端末がいる (core を立て直して住所が振り直されたなど)。わけを持つ。
    Other(String),
    /// 控えの子の端末。
    Ours(Value),
}

/// 控えの子の端末を引き、名前と英字の label が控えと合うかを確かめる (合わなければ触らない)。
fn child_terminal(hc: &Hc<'_>, row: &Row) -> Result<ChildTerm> {
    if row.terminal.is_empty() {
        return Ok(ChildTerm::Missing);
    }
    let Some(term) = hc.get(&row.terminal)? else {
        return Ok(ChildTerm::Missing);
    };
    let name = term["name"].as_str().unwrap_or_default();
    if !row.name.is_empty() && name != row.name {
        return Ok(ChildTerm::Other(format!(
            "{} の名前が {} で、控えの {} と違う",
            row.terminal,
            if name.is_empty() { "(なし)" } else { name },
            row.name
        )));
    }
    if let Some(letter) = label_of(&term, "pjp.letter")
        && letter != row.letter
    {
        return Ok(ChildTerm::Other(format!(
            "{} の英字の label が {letter} で、控えの {} と違う",
            row.terminal, row.letter
        )));
    }
    Ok(ChildTerm::Ours(term))
}

/// [`find_live_by_name`] を、見つかるまで [`FIND_TRIES`] 回打つ (間に [`FIND_WAIT`] 待つ)。host-a の hc は `hc run` に
/// 「registry persistence timed out; the operation may already have completed」を返すことがあり、そのときも端末は立っていた。
/// 一覧に出るのが遅れても、立った子の worktree を消さない (claude が消した worktree で動き続けないように)。hc が詰まって
/// 一覧そのものが遅いときに待ちを重ねないよう、探し直すのは探し始めてから [`FIND_BUDGET_SECS`] 秒のうちだけ。`exclude` の住所の
/// 端末 (`restart` で、終えただけでまだ消していない前の端末) は、立った子とみない。
fn find_live_soon(
    r: &dyn Runner,
    hc: &Hc<'_>,
    m: Option<&str>,
    name: &str,
    exclude: Option<&str>,
) -> Option<String> {
    let since = r.now().ok().map(|t| t.secs);
    for i in 0..FIND_TRIES {
        if i > 0 {
            let elapsed = match (since, r.now().ok()) {
                (Some(a), Some(b)) => b.secs - a,
                _ => 0,
            };
            if elapsed >= FIND_BUDGET_SECS {
                break;
            }
            r.sleep(FIND_WAIT);
        }
        if let Some(addr) = find_live_by_name(hc, m, name, exclude) {
            return Some(addr);
        }
    }
    None
}

/// `hc run` が落ちた後に、立った子を名前で探す回数・間・探し直す上限の秒。
const FIND_TRIES: u32 = 3;
const FIND_WAIT: std::time::Duration = std::time::Duration::from_secs(2);
const FIND_BUDGET_SECS: i64 = 30;

/// 名前が `name` の生きた端末の住所を探す (ハブの core の一覧、無ければ子のマシンの一覧)。`hc run` が落ちたように見えても、
/// 子が立っていることがある (時間切れ・出力の読み違い)。住所が `exclude` の端末は飛ばす。
fn find_live_by_name(
    hc: &Hc<'_>,
    m: Option<&str>,
    name: &str,
    exclude: Option<&str>,
) -> Option<String> {
    let pick = |terms: &[Value], prefix: Option<&str>| -> Option<String> {
        terms
            .iter()
            .filter(|t| t["state"].as_str().is_none_or(|s| s == "live"))
            .filter(|t| t["name"].as_str() == Some(name))
            .filter_map(|t| t["address"].as_str())
            .map(|a| match prefix {
                Some(m) if !a.contains('/') => format!("{m}/{a}"),
                _ => a.to_owned(),
            })
            .find(|a| Some(a.as_str()) != exclude)
    };
    if let Some(addr) = hc.ls(false).ok().and_then(|t| pick(&t, None)) {
        return Some(addr);
    }
    let m = m?;
    let out = hc.exec(Some(m), None, 60, &["hc", "ls", "--json"]).ok()?;
    if !out.ok() {
        return None;
    }
    let v: Value = serde_json::from_str(out.stdout.trim()).ok()?;
    pick(v["terminals"].as_array()?, Some(m))
}

/// 端末の状態を 1 語で (`working`・`idle`・`blocked`・`報告なし`・`終わった`)。
fn status_word(term: &Value) -> String {
    if crate::hc::finished(term) {
        let code = term["exit_code"]
            .as_i64()
            .map_or("?".to_owned(), |c| c.to_string());
        return format!("終わった (終了コード {code})");
    }
    match crate::hc::state_of(term) {
        Some(s) => s.to_owned(),
        None => "報告なし".to_owned(),
    }
}

/// 子のマシンのパスを、子のマシンの HOME で `~` に縮める (表示用)。
fn short_remote(path: &str, home: &str) -> String {
    let home = home.trim_end_matches('/');
    if home.is_empty() {
        return path.to_owned();
    }
    if path == home {
        return "~".to_owned();
    }
    match path.strip_prefix(home) {
        Some(rest) if rest.starts_with('/') => format!("~{rest}"),
        _ => path.to_owned(),
    }
}

#[cfg(test)]
mod tests;
