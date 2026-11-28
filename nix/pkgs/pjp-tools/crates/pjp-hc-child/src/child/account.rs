//! 子を立てる Claude のアカウント。子は、ハブ (`pjp` を打った会話) と同じアカウントで立てる。
//!
//! - 決め方: `--account <名前|default>` があればそれ。無ければハブの `CLAUDE_CONFIG_DIR` から: 空・`~/.claude` → 既定 (素の
//!   claude)、`~/.claude-<名前>` (Windows の `C:\Users\<人>\.claude-work` も) → 子のマシンの launcher `claude-<名前>`、それ以外の
//!   形 → 立てずに止まる。`restart` は控えの値 (立てたときのアカウント) を使う
//! - launcher (dotfiles。Linux は claude.nix、Windows は runner の launcher) は、/login の資格情報より優先される env を外し
//!   (token のアカウントの launcher は、`~/.config/claude-accounts/<名前>.env` から token を env で渡す)、`CLAUDE_CONFIG_DIR`
//!   を `~/.claude-<名前>` にして claude を起こす。Linux では exec するので、端末の前面のプロセスは claude のままで、状態の
//!   報告 (OSC 7501) も今までどおり届く (2026-11-19 に WSL で見た)
//! - hc の子は core の env で起きるので、core を立てた会話のアカウントの env が紛れうる。どの子も [`CLEARED_ENV`] を外して立てる
//! - 名前のアカウントは、立てる前に子のマシンで launcher があるかと、アカウントの用意 (ログイン) ができているかを確かめる。
//!   用意は、子のマシンに claude-account (dotfiles のアカウントのコマンド) があればその `check` の答えで ([`ask_claude_account`])、
//!   無ければファイルの有る無しで見る ([`KINDS`])。だめなら worktree・space を作る前に止まり、素の claude に黙って落とさない
//! - 素の claude の子も、子のマシンに claude-account があれば `check default` で用意を確かめる ([`ask_default`]。dotfiles-private の
//!   ADR 123 §2 H)。default を知らない古い claude-account (終了コード 2) と、claude-account の無いマシンは、今までどおり確かめずに立てる

use pjp_core::paths::{normalize_for_compare, same_path};
use pjp_core::{Error, Result};

use crate::hc::{Hc, Runner, first_line};

/// 子の env から外すもの (`pjp child` が `env -u` で外す)。hc の子は core の env で起き、core の env は core を立てたシェルの
/// 写しなので、claude-work の会話から core を立て直すと `CLAUDE_CONFIG_DIR` が紛れ込む (token も同じ)。外しておけば、既定の
/// 子はいつも `~/.claude` の /login で起き、名前のアカウントの子は launcher が要るものを付け直す。
pub(super) const CLEARED_ENV: [&str; 4] = [
    "CLAUDE_CONFIG_DIR",
    "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_AUTH_TOKEN",
];

/// 子を立てるアカウント。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Account {
    /// 既定 (`~/.claude`)。素の claude で立てる。
    Default,
    /// `~/.claude-<名前>`。子のマシンの `claude-<名前>` で立てる。
    Named(String),
}

impl Account {
    /// 控えの列 `account` の値 (既定は空)。
    pub(super) fn ledger_value(&self) -> &str {
        match self {
            Self::Default => "",
            Self::Named(n) => n,
        }
    }

    /// 控えの列の値から。空は既定 (列の無い前の控えの子は、どれも素の claude で立てた)。
    pub(super) fn from_ledger(v: &str) -> Self {
        if v.is_empty() {
            Self::Default
        } else {
            Self::Named(v.to_owned())
        }
    }

    /// 出力に出す名前。
    pub(super) fn label(&self) -> String {
        match self {
            Self::Default => "既定 (素の claude・~/.claude)".to_owned(),
            Self::Named(n) => format!("claude-{n}"),
        }
    }
}

/// 選んだアカウントと、そのわけ (出力に出す)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Choice {
    pub(super) account: Account,
    pub(super) why: String,
}

/// 子のマシンで起こすもの (claude か launcher のパス) と、確かめた用意 (名前のアカウントのとき。出力のアカウントの行の末尾の文)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Ready {
    pub(super) program: String,
    pub(super) note: Option<String>,
}

/// アカウントの名前の形 (`[a-z0-9][a-z0-9_-]*`。dotfiles の claude.nix・bootstrap-claude-accounts.sh・Windows の launcher と
/// 同じ)。`default` は `--account default` (既定) と重なるので名前にしない。`account` も、`claude-account` が管理のコマンド
/// で launcher と重なるので名前にしない (dotfiles の claude-account も断る)。
fn name_ok(name: &str) -> bool {
    let mut chars = name.chars();
    let lead_ok = chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    lead_ok
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
        && name != "default"
        && name != "account"
}

/// `--account` の値を読む。
fn from_flag(v: &str) -> Result<Choice> {
    if v == "default" {
        return Ok(Choice {
            account: Account::Default,
            why: "--account default から".to_owned(),
        });
    }
    // コマンドの名前 (claude-work) をそのまま渡したとき。名前の形には合うが、~/.claude-claude-work を指すことになる
    if let Some(rest) = v.strip_prefix("claude-").filter(|r| name_ok(r)) {
        return Err(Error::config(format!(
            "--account には claude- を除いた名前を渡す (--account {rest})"
        )));
    }
    if name_ok(v) {
        return Ok(Choice {
            account: Account::Named(v.to_owned()),
            why: "--account から".to_owned(),
        });
    }
    Err(Error::config(format!(
        "--account は default (素の claude) かアカウントの名前 (a-z・0-9・-・_。claude-work なら work。account は管理のコマンド \
         claude-account と重なるので使わない) にする ({v})"
    )))
}

/// Windows のパスの形か (ドライブ名か `\` がある)。ハブの OS でなく値の形で決める (pjp-core の比べ方に渡す)。
fn windows_like(p: &str) -> bool {
    p.contains('\\') || p.as_bytes().get(1) == Some(&b':')
}

/// ハブの `CLAUDE_CONFIG_DIR` (`dir`) から決める。`homes` はハブの家の候補 (USERPROFILE・HOME)。家の下の `.claude` は既定、
/// `.claude-<名前>` は名前のアカウント。ほかの形は、子をどのアカウントで立てるか分からないので止まる。
fn from_config_dir(dir: Option<&str>, homes: &[String]) -> Result<Choice> {
    let Some(dir) = dir.map(str::trim).filter(|d| !d.is_empty()) else {
        return Ok(Choice {
            account: Account::Default,
            why: "ハブの CLAUDE_CONFIG_DIR が空".to_owned(),
        });
    };
    let unreadable = || {
        Error::config(format!(
            "ハブの CLAUDE_CONFIG_DIR ({dir}) から子のアカウントを決められません (家の下の .claude か .claude-<名前> でない。\
             名前は a-z・0-9・-・_ で、default・account は使わない)。--account <名前> (子のマシンの claude-<名前>) か \
             --account default (素の claude) で渡す"
        ))
    };
    // 区切りを / に、末尾の区切りを落とす。Windows の形なら \\?\ を外して小文字にする (Windows の dir の名前は大文字小文字を
    // 区別しない。子のマシンの launcher は小文字の claude-<名前>)
    let win = windows_like(dir);
    let path = normalize_for_compare(dir, win);
    let (parent, base) = path.rsplit_once('/').ok_or_else(unreadable)?;
    let in_home = parent == "~"
        || homes
            .iter()
            .any(|h| same_path(parent, h, win || windows_like(h)));
    if !in_home {
        return Err(unreadable());
    }
    if base == ".claude" {
        return Ok(Choice {
            account: Account::Default,
            why: format!("ハブの CLAUDE_CONFIG_DIR が {dir}"),
        });
    }
    match base.strip_prefix(".claude-").filter(|n| name_ok(n)) {
        Some(name) => Ok(Choice {
            account: Account::Named(name.to_owned()),
            why: format!("ハブの CLAUDE_CONFIG_DIR {dir} から"),
        }),
        None => Err(unreadable()),
    }
}

/// `pjp child new`: `--account` → ハブの `CLAUDE_CONFIG_DIR` (家は Windows の USERPROFILE と HOME のどちらでもよい)。
pub(super) fn choose(r: &dyn Runner, flag: Option<&str>) -> Result<Choice> {
    if let Some(v) = flag {
        return from_flag(v);
    }
    let homes: Vec<String> = ["USERPROFILE", "HOME"]
        .iter()
        .filter_map(|k| r.env(k))
        .collect();
    from_config_dir(r.env("CLAUDE_CONFIG_DIR").as_deref(), &homes)
}

/// `pjp child restart`: `--account` → 控え (立てたときのアカウント)。
pub(super) fn choose_again(flag: Option<&str>, recorded: &str) -> Result<Choice> {
    if let Some(v) = flag {
        return from_flag(v);
    }
    Ok(Choice {
        account: Account::from_ledger(recorded),
        why: "控えから (立てたときのアカウント)".to_owned(),
    })
}

/// アカウントの用意 (ログイン) の種類。
struct Kind {
    /// 子のマシンの script の出力の鍵。
    key: &'static str,
    /// 有る無しを見るファイル (`$HOME` からの相対。`{}` はアカウントの名前)。中身は読まない。
    file: &'static str,
    /// 出力に出す種類の名前。
    what: &'static str,
    /// どの種類の用意も無いときに出す手 (`{}` はアカウントの名前)。
    fix: &'static str,
}

/// アカウントの用意の見分け方 (子のマシンに claude-account が無いときだけ使う。あれば [`ask_claude_account`])。どれか 1 つのファイルが
/// あれば、用意ができているとみる。見分け方の違う種類を足すときは、ここに 1 つ足す (子のマシンの script と、止まったときの手の
/// 文に入る)。
const KINDS: &[Kind] = &[
    Kind {
        key: "login",
        file: ".claude-{}/.credentials.json",
        what: "/login のアカウント",
        fix: "/login のアカウントなら、子のマシンの端末で claude-{} を起こして /login する (ユーザーの手)",
    },
    // token のアカウント (launcher は dotfiles が用意し、このファイルの token を CLAUDE_CODE_OAUTH_TOKEN で渡す。/login の資格情報は
    // 持たない)。ファイルの置き場は dotfiles の launcher と合わせてある (2026-11-19 に指揮役が知らせた)。中身の形 (token の値そのもの・
    // 1Password の参照) と置き方は launcher の案内に任せ、ここでは決めない
    Kind {
        key: "token",
        file: ".config/claude-accounts/{}.env",
        what: "token のアカウント",
        fix: "token のアカウントなら、子のマシンの端末で claude-{} を一度起こし、出る案内どおりに ~/.config/claude-accounts/{}.env に token を置く (ユーザーの手)",
    },
];

/// launcher がありうる、core の PATH の外の場所 (`$HOME` からの相対)。Linux の dotfiles の home-manager の置き場と、
/// claude-account add の link の置き場。core の env が古いと PATH に入らない。
const OFF_PATH_DIRS: [&str; 2] = [".nix-profile/bin", ".local/bin"];

/// 子のマシンの claude-account の場所を `claude-account=<パス>` (無ければ空) で出す `sh` の断片。PATH のものを先に、無ければ
/// `~/.nix-profile/bin` のものを使う (指揮役との約束)。名前のアカウントの探り ([`probe_script`]) と、子のマシンを 1 回で
/// 探る script (`child::probe_script`。素の claude の子が使う) の両方に入る。
pub(super) const CLAUDE_ACCOUNT_PROBE: &str = r#"a=$(command -v claude-account 2>/dev/null) || a=
if [ -z "$a" ] && [ -x "$HOME/.nix-profile/bin/claude-account" ]; then
  a=$HOME/.nix-profile/bin/claude-account
fi
printf 'claude-account=%s\n' "$a"
"#;

/// 子のマシンで launcher の場所・claude-account の場所・用意のファイルの有る無しを出す `sh` の script。$1 はアカウントの名前。
/// launcher は core の PATH にあるものだけを使う (Linux の launcher は PATH の claude か mise で claude を探すので、PATH に無い
/// launcher は claude も見つけられない)。PATH に無くて [`OFF_PATH_DIRS`] にあれば、その場所を知らせる。claude-account は
/// PATH のものを先に、無ければ `~/.nix-profile/bin` のものを使う (指揮役との約束)。
fn probe_script() -> String {
    let mut s = format!(
        r#"l=$(command -v "claude-$1" 2>/dev/null) || l=
printf 'launcher=%s\n' "$l"
if [ -z "$l" ]; then
  for d in {}; do
    if [ -x "$HOME/$d/claude-$1" ]; then
      printf 'offpath=%s\n' "$HOME/$d/claude-$1"
      break
    fi
  done
fi
"#,
        OFF_PATH_DIRS.join(" ")
    );
    s.push_str(CLAUDE_ACCOUNT_PROBE);
    for k in KINDS {
        let file = k.file.replace("{}", "$1");
        s.push_str(&format!(
            "if [ -e \"$HOME/{file}\" ]; then printf '{}=1\\n'; fi\n",
            k.key
        ));
    }
    s
}

/// 子のマシンで見つけたもの。
#[derive(Debug, Default, PartialEq, Eq)]
struct Found {
    /// core の PATH で見つけた launcher。
    launcher: String,
    /// PATH に無く、`~/.nix-profile/bin` にあった launcher (使わない。止まるときの文に出す)。
    offpath: String,
    /// 用意のファイルがあった種類の鍵 ([`Kind::key`])。
    kinds: Vec<String>,
    /// 子のマシンの claude-account (無ければ空。あれば用意をその答えで見分ける)。
    claude_account: String,
}

fn parse_found(stdout: &str) -> Found {
    let mut f = Found::default();
    for line in stdout.lines() {
        match line.split_once('=') {
            Some(("launcher", v)) => f.launcher = v.trim().to_owned(),
            Some(("offpath", v)) => f.offpath = v.trim().to_owned(),
            Some(("claude-account", v)) => f.claude_account = v.trim().to_owned(),
            Some((k, "1")) if KINDS.iter().any(|x| x.key == k) => f.kinds.push(k.to_owned()),
            _ => {}
        }
    }
    f
}

/// 止まるときの手の最後の行 (素の claude で立てる)。
const OR_DEFAULT: &str = "  - --account default で素の claude (~/.claude) で立てる";

/// 素の claude で止まるときの手の最後の行 (名前のアカウントで立てる)。
const OR_NAMED: &str =
    "  - --account <名前> で、子のマシンで用意のできた名前のアカウント (claude-<名前>) で立てる";

/// 子のマシンで起こすものを決める。既定は probe で見つけた claude (無ければ止まる)。子のマシンに claude-account があれば
/// (`claude_account`。probe で見つけた場所)、素の claude の用意も `check default` で確かめる。名前のアカウントは、launcher と用意を
/// 子のマシンで確かめ、だめなら止まる (worktree・space を作る前と、`restart` で前の端末を終える前に呼ぶ)。
pub(super) fn ready(
    hc: &Hc<'_>,
    m: Option<&str>,
    claude: &str,
    claude_account: &str,
    account: &Account,
) -> Result<Ready> {
    let machine = m.unwrap_or("local");
    let name = match account {
        Account::Default if claude.is_empty() => {
            return Err(Error::failure(format!(
                "子のマシン ({machine}) に claude が見つかりません (PATH にも ~/.local/share/mise/installs/claude/latest/claude にも無い)"
            )));
        }
        Account::Default => {
            let note = if claude_account.is_empty() {
                None
            } else {
                ask_default(hc, m, claude_account)?
            };
            return Ok(Ready {
                program: claude.to_owned(),
                note,
            });
        }
        Account::Named(n) => n,
    };
    let script = probe_script();
    let out = hc.exec(m, None, 60, &["sh", "-c", &script, "sh", name])?;
    if !out.ok() {
        return Err(Error::failure(format!(
            "子のマシン ({machine}) で claude-{name} の用意を確かめられません: {}",
            out.why()
        )));
    }
    let found = parse_found(&out.stdout);
    let other = OR_DEFAULT;
    let restart_core = "  - 子のマシンの herdr の外の対話シェルで hc server restart --fresh を打ってもらう (ユーザーの手)";
    if found.launcher.is_empty() && !found.offpath.is_empty() {
        let place = OFF_PATH_DIRS
            .iter()
            .find(|d| found.offpath.ends_with(&format!("/{d}/claude-{name}")))
            .map_or_else(|| found.offpath.clone(), |d| format!("~/{d}"));
        return Err(Error::failure(format!(
            "子のマシン ({machine}) の claude-{name} は {place} にあるが、hc の core の PATH に無い (core の env が足りず、\
             launcher も claude を見つけられない)。次のどちらかをしてから打ち直す:\n{restart_core}\n{other}"
        )));
    }
    // claude-account があれば、用意の見分けはその答えに任せる (知らない名前も、launcher の有る無しより先に答えを出す)
    let asked = if found.claude_account.is_empty() {
        None
    } else {
        Some(ask_claude_account(hc, m, &found.claude_account, name)?)
    };
    if found.launcher.is_empty() && asked.is_some() {
        // claude-account は launcher (link) があるときだけ使えると答えるので、core の PATH が古い (見ていない場所にある) とみる
        return Err(Error::failure(format!(
            "子のマシン ({machine}) の claude-account は claude-{name} を使えると答えたが、claude-{name} が hc の core の PATH に無い \
             (core の env が古い見込み)。次のどちらかをしてから打ち直す:\n{restart_core}\n{other}"
        )));
    }
    if found.launcher.is_empty() {
        return Err(Error::failure(format!(
            "子のマシン ({machine}) に claude-{name} がありません (PATH にも ~/.nix-profile/bin・~/.local/bin にも無い)。\
             次のどちらかをしてから打ち直す:\n  \
             - 子のマシンの dotfiles を新しくして claude-{name} を用意する\n{other}"
        )));
    }
    if let Some(note) = asked {
        return Ok(Ready {
            program: found.launcher,
            note: Some(note),
        });
    }
    let kinds: Vec<&Kind> = KINDS
        .iter()
        .filter(|k| found.kinds.iter().any(|f| f == k.key))
        .collect();
    if kinds.is_empty() {
        let files: Vec<String> = KINDS
            .iter()
            .map(|k| format!("~/{}", k.file.replace("{}", name)))
            .collect();
        let fixes: Vec<String> = KINDS
            .iter()
            .map(|k| format!("  - {}", k.fix.replace("{}", name)))
            .collect();
        return Err(Error::failure(format!(
            "子のマシン ({machine}) の claude-{name} は用意ができていません ({} も無い)。次のどれかをしてから打ち直す:\n{}\n{other}",
            files.join(" も "),
            fixes.join("\n")
        )));
    }
    Ok(Ready {
        program: found.launcher,
        note: Some(format!(
            "子のマシンに {}の用意がある",
            kinds.iter().map(|k| k.what).collect::<Vec<_>>().join("と ")
        )),
    })
}

/// `claude-account check <名前>` の答え (終了コード 0・1・2 のとき)。
struct Answer {
    code: i32,
    /// stdout の 1 行目 (使えるときの 1 行)。
    line: String,
    /// claude-account の出した文 (stderr。空なら stdout)。
    said: String,
}

/// 子のマシンの claude-account で `check <名前>` を打つ (dotfiles の claude-account と合わせた約束: 0 は使える・1 は用意が
/// 無い・2 は知らない名前か使い方の誤り)。0・1・2 は答えを返し、ほかの終了コード・時間切れ・打てないときは、ほかの見分けに戻らずに
/// 止まる (claude-account のあるマシンで、黙って別の見分けをしない)。`instead` は止まるときに足す「ほかの見分けには戻らない」の文、
/// `other` は手の最後の行。claude-account は token の値を出さず、1Password (op) も呼ばない作り (dotfiles の側)。
fn run_check(
    hc: &Hc<'_>,
    m: Option<&str>,
    path: &str,
    name: &str,
    instead: &str,
    other: &str,
) -> Result<Answer> {
    const TIMEOUT_SECS: u64 = 60;
    let machine = m.unwrap_or("local");
    let fix_tool = "  - 子のマシンの claude-account を直す (dotfiles を新しくする)";
    let out = hc
        .exec(m, None, TIMEOUT_SECS, &[path, "check", name])
        .map_err(|e| {
            Error::failure(format!(
                "子のマシン ({machine}) で claude-account check {name} を打てません ({e})。{instead}。\
                 次のどちらかをしてから打ち直す:\n  \
                 - 上のわけを確かめる (子のマシンの claude-account が消えた・hc が子のマシンにつながらない など)\n{other}"
            ))
        })?;
    // 文は stderr に出す約束。stderr が空なら stdout を出す (出したものを「何も出さなかった」と書かない)
    let said = if out.stderr.trim().is_empty() {
        out.stdout.clone()
    } else {
        out.stderr.clone()
    };
    match (out.timed_out, out.code) {
        (false, Some(code @ 0..=2)) => Ok(Answer {
            code,
            line: first_line(&out.stdout).to_owned(),
            said,
        }),
        _ => {
            let how = match (out.timed_out, out.code) {
                (true, _) => format!("{TIMEOUT_SECS} 秒で時間切れ"),
                (false, Some(c)) => format!("終了コード {c}"),
                (false, None) => "終了コードなし。シグナルなどで終わった".to_owned(),
            };
            Err(Error::failure(format!(
                "子のマシン ({machine}) の claude-account check {name} が思わぬ終わり方をしました ({how})。{instead}。\
                 claude-account の出した文:\n{}\n次のどちらかをしてから打ち直す:\n{fix_tool}\n{other}",
                quote(&said)
            )))
        }
    }
}

/// 「claude-account check <名前> の答え (終了コード n):」と、出した文を字のまま (止まるときの文に入れる)。
fn answer_text(name: &str, a: &Answer) -> String {
    format!(
        "claude-account check {name} の答え (終了コード {}):\n{}",
        a.code,
        quote(&a.said)
    )
}

/// 子のマシンの claude-account に、名前のアカウントの用意を聞く。0 なら使える (stdout の 1 行を、出力のアカウントの行に
/// 出す)・1 なら用意が無い (stderr にユーザーの手を 1〜3 行)・2 なら知らない名前か使い方の誤り。1 と 2 は claude-account の出した文を
/// 字のまま入れて止まる。
fn ask_claude_account(hc: &Hc<'_>, m: Option<&str>, path: &str, name: &str) -> Result<String> {
    let machine = m.unwrap_or("local");
    let other = OR_DEFAULT;
    let a = run_check(
        hc,
        m,
        path,
        name,
        "用意のファイルの有る無しの見分けには戻らずに止まる",
        other,
    )?;
    match a.code {
        0 => Ok(match a.line.as_str() {
            "" => "子のマシンの claude-account check で使えると確かめた".to_owned(),
            line => format!("子のマシンの claude-account check の答え: {line}"),
        }),
        1 => Err(Error::failure(format!(
            "子のマシン ({machine}) の claude-{name} は用意ができていません。{}\n次のどちらかをしてから打ち直す:\n  \
             - 上の手をする (ユーザーの手)\n{other}",
            answer_text(name, &a)
        ))),
        _ => Err(Error::failure(format!(
            "子のマシン ({machine}) の claude-account が claude-{name} を知らないか、使い方が合いません。{}\n\
             次のどちらかをしてから打ち直す:\n  \
             - 上の文に沿って直す (子のマシンにある別のアカウントなら --account <名前> で渡す)\n{other}",
            answer_text(name, &a)
        ))),
    }
}

/// 子のマシンの claude-account に、素の claude (`~/.claude`) の用意を聞く (dotfiles-private の ADR 123 §2 H。名前のアカウントと
/// 同じ約束)。宣言のあるホスト (`dotfiles.claude.tokens.default`) では token のファイルと wrapper を、無いホストでは /login の
/// 資格情報を claude-account が見る。0 なら立てる (stdout の 1 行を、出力のアカウントの行に出す)・1 なら claude-account の出した文を
/// 字のまま入れて止まる・2 は default を知らない古い claude-account なので、今までどおり確かめずに立てる (そのことを行に添える)。
fn ask_default(hc: &Hc<'_>, m: Option<&str>, path: &str) -> Result<Option<String>> {
    let machine = m.unwrap_or("local");
    let other = OR_NAMED;
    let a = run_check(
        hc,
        m,
        path,
        "default",
        "確かめないまま立てずに止まる",
        other,
    )?;
    match a.code {
        0 => Ok(Some(match a.line.as_str() {
            "" => "子のマシンの claude-account check default で使えると確かめた".to_owned(),
            line => format!("子のマシンの claude-account check default の答え: {line}"),
        })),
        1 => Err(Error::failure(format!(
            "子のマシン ({machine}) の素の claude (~/.claude) は用意ができていません。{}\n\
             次のどちらかをしてから打ち直す:\n  - 上の手をする (ユーザーの手)\n{other}",
            answer_text("default", &a)
        ))),
        _ => Ok(Some(
            "子のマシンの claude-account は default を知らない版なので、素の claude の用意は確かめていない".to_owned(),
        )),
    }
}

/// claude-account の出した文を、止まるときの文に字のまま入れる (行ごとに 4 字下げる。行末の空白と、前後の空の行は落とす)。
fn quote(text: &str) -> String {
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim_end)
        .skip_while(|l| l.is_empty())
        .collect();
    let end = lines
        .iter()
        .rposition(|l| !l.is_empty())
        .map_or(0, |i| i + 1);
    if end == 0 {
        return "    (何も出さなかった)".to_owned();
    }
    lines[..end]
        .iter()
        .map(|l| {
            if l.is_empty() {
                String::new()
            } else {
                format!("    {l}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// `pjp child ls` の行の末尾。名前のアカウント (`claude-<名前>`) で立てた子だけに出す (`recorded` は控えの列の値)。
pub(super) fn ls_suffix(recorded: &str) -> String {
    match Account::from_ledger(recorded) {
        Account::Default => String::new(),
        named => format!("  アカウント {}", named.label()),
    }
}

/// 出力の「アカウント:」の行の中身 (選んだアカウント・わけ・子のマシンで確かめた用意)。
pub(super) fn describe(choice: &Choice, ready: &Ready) -> String {
    let mut s = format!("{}。{}", choice.account.label(), choice.why);
    if let Some(note) = &ready.note {
        s.push_str(&format!("。{note}"));
    }
    s
}

#[cfg(test)]
mod tests {
    use pjp_core::exit::CONFIG;

    use super::*;

    fn named(n: &str) -> Account {
        Account::Named(n.to_owned())
    }

    fn homes(h: &[&str]) -> Vec<String> {
        h.iter().map(|s| (*s).to_owned()).collect()
    }

    /// 決まったアカウント (わけは見ない)。
    fn account_of(dir: Option<&str>, h: &[&str]) -> Result<Account> {
        from_config_dir(dir, &homes(h)).map(|c| c.account)
    }

    #[test]
    fn names_follow_the_dotfiles_rule() {
        for ok in ["work", "personal", "token1", "a_b-c", "0x"] {
            assert!(name_ok(ok), "{ok}");
        }
        // default は --account default (既定) と、account は管理のコマンド claude-account と重なるので名前にしない
        for bad in [
            "",
            "Work",
            "-x",
            "_x",
            "a/b",
            "a.b",
            "a b",
            "default",
            "account",
            "ワーク",
        ] {
            assert!(!name_ok(bad), "{bad}");
        }
    }

    #[test]
    fn hub_config_dir_empty_or_dot_claude_is_default() {
        let h = ["/home/u"];
        assert_eq!(account_of(None, &h).unwrap(), Account::Default);
        assert_eq!(account_of(Some(""), &h).unwrap(), Account::Default);
        assert_eq!(
            account_of(Some("/home/u/.claude"), &h).unwrap(),
            Account::Default
        );
        assert_eq!(
            account_of(Some("/home/u/.claude/"), &h).unwrap(),
            Account::Default
        );
        let c = from_config_dir(None, &homes(&h)).unwrap();
        assert_eq!(c.why, "ハブの CLAUDE_CONFIG_DIR が空");
        let c = from_config_dir(Some("/home/u/.claude"), &homes(&h)).unwrap();
        assert_eq!(c.why, "ハブの CLAUDE_CONFIG_DIR が /home/u/.claude");
    }

    #[test]
    fn hub_config_dir_dot_claude_name_is_named() {
        let h = ["/home/u"];
        assert_eq!(
            account_of(Some("/home/u/.claude-work"), &h).unwrap(),
            named("work")
        );
        assert_eq!(
            account_of(Some("/home/u/.claude-token1/"), &h).unwrap(),
            named("token1")
        );
        assert_eq!(
            account_of(Some("~/.claude-work"), &h).unwrap(),
            named("work")
        );
        let c = from_config_dir(Some("/home/u/.claude-work"), &homes(&h)).unwrap();
        assert_eq!(c.why, "ハブの CLAUDE_CONFIG_DIR /home/u/.claude-work から");
    }

    #[test]
    fn windows_hub_config_dir_is_read_under_userprofile() {
        let h = [r"C:\Users\user"];
        assert_eq!(
            account_of(Some(r"C:\Users\user\.claude-work"), &h).unwrap(),
            named("work")
        );
        // Windows の形なら、区切りの向きと大文字小文字を問わない
        assert_eq!(
            account_of(Some(r"c:/users/USER/.claude-work\"), &h).unwrap(),
            named("work")
        );
        assert_eq!(
            account_of(Some(r"C:\Users\user\.claude"), &h).unwrap(),
            Account::Default
        );
        // Windows の dir の名前は大文字小文字を区別しない (子のマシンの launcher は小文字の claude-work)
        assert_eq!(
            account_of(Some(r"C:\Users\user\.Claude-Work"), &h).unwrap(),
            named("work")
        );
        // Windows の canonicalize が返す形 (\\?\) も読む
        assert_eq!(
            account_of(Some(r"\\?\C:\Users\user\.claude-work"), &h).unwrap(),
            named("work")
        );
        // 家の候補が 2 つ (USERPROFILE と HOME) なら、どちらの下でもよい
        let both = [r"C:\Users\user", "/home/u"];
        assert_eq!(
            account_of(Some("/home/u/.claude-work"), &both).unwrap(),
            named("work")
        );
    }

    #[test]
    fn unreadable_hub_config_dir_stops_with_account_hint() {
        let h = ["/home/u"];
        for dir in [
            "/tmp/x/.claude-work",
            "/home/u/.claude-Work",
            "/home/u/.claude-",
            "/home/u/.claude-default",
            "/home/u/.claude-account",
            "/home/u/.config/claude",
            "/HOME/U/.claude-work",
            ".claude-work",
        ] {
            let e = from_config_dir(Some(dir), &homes(&h)).unwrap_err();
            assert_eq!(e.code(), CONFIG, "{dir}");
            let msg = e.to_string();
            assert!(msg.contains(dir), "{dir}: {msg}");
            assert!(msg.contains("--account <名前>"), "{dir}: {msg}");
            assert!(msg.contains("--account default"), "{dir}: {msg}");
            // 名前の決まりも出す (.claude-Work・.claude-default で止まったわけが分かるように)
            assert!(msg.contains("a-z・0-9・-・_"), "{dir}: {msg}");
        }
        // 家が分からなければ、家の下かを確かめられないので止まる
        assert!(from_config_dir(Some("/home/u/.claude-work"), &[]).is_err());
    }

    #[test]
    fn account_flag_values() {
        let c = from_flag("default").unwrap();
        assert_eq!(
            (c.account, c.why.as_str()),
            (Account::Default, "--account default から")
        );
        let c = from_flag("work").unwrap();
        assert_eq!(
            (c.account, c.why.as_str()),
            (named("work"), "--account から")
        );
        let e = from_flag("claude-work").unwrap_err();
        assert_eq!(e.code(), CONFIG);
        assert!(e.to_string().contains("--account work"), "{e}");
        for bad in ["", "Work", "a/b", "account"] {
            assert_eq!(from_flag(bad).unwrap_err().code(), CONFIG, "{bad}");
        }
    }

    #[test]
    fn restart_uses_recorded_account_unless_flag() {
        let c = choose_again(None, "work").unwrap();
        assert_eq!(c.account, named("work"));
        assert_eq!(c.why, "控えから (立てたときのアカウント)");
        // 列の無い前の控え (空) は、素の claude で立てた子
        assert_eq!(choose_again(None, "").unwrap().account, Account::Default);
        assert_eq!(
            choose_again(Some("default"), "work").unwrap().account,
            Account::Default
        );
        assert_eq!(
            choose_again(Some("personal"), "").unwrap().account,
            named("personal")
        );
    }

    #[test]
    fn ledger_values_and_labels() {
        assert_eq!(Account::Default.ledger_value(), "");
        assert_eq!(named("work").ledger_value(), "work");
        assert_eq!(Account::from_ledger(""), Account::Default);
        assert_eq!(Account::from_ledger("work"), named("work"));
        assert_eq!(Account::Default.label(), "既定 (素の claude・~/.claude)");
        assert_eq!(named("work").label(), "claude-work");
    }

    #[test]
    fn probe_script_looks_for_launcher_and_every_kind() {
        let s = probe_script();
        assert!(s.contains(r#"command -v "claude-$1""#), "{s}");
        // ~/.nix-profile/bin の launcher は使わず、core の PATH に無いと知らせるだけ (claude を見つけられないため)
        assert!(
            !s.contains(r#"l="$HOME/.nix-profile/bin/claude-$1""#),
            "{s}"
        );
        assert!(s.contains("printf 'offpath=%s\\n'"), "{s}");
        for (key, file) in [
            ("login", "$HOME/.claude-$1/.credentials.json"),
            ("token", "$HOME/.config/claude-accounts/$1.env"),
        ] {
            assert!(s.contains(&format!("[ -e \"{file}\" ]")), "{key}: {s}");
            assert!(s.contains(&format!("printf '{key}=1\\n'")), "{key}: {s}");
        }
    }

    #[test]
    fn parse_found_reads_launcher_and_kinds() {
        assert_eq!(
            parse_found("launcher=/home/u/.nix-profile/bin/claude-work\nlogin=1\ntoken=1\n"),
            Found {
                launcher: "/home/u/.nix-profile/bin/claude-work".to_owned(),
                kinds: vec!["login".to_owned(), "token".to_owned()],
                ..Found::default()
            }
        );
        assert_eq!(
            parse_found("launcher=\noffpath=/home/u/.nix-profile/bin/claude-work\n").offpath,
            "/home/u/.nix-profile/bin/claude-work"
        );
        assert_eq!(parse_found("launcher=\n"), Found::default());
        assert_eq!(parse_found(""), Found::default());
        // 子のマシンの claude-account
        assert_eq!(
            parse_found(
                "launcher=/x/claude-work\nclaude-account=/home/u/.nix-profile/bin/claude-account\n"
            )
            .claude_account,
            "/home/u/.nix-profile/bin/claude-account"
        );
        assert_eq!(
            parse_found("launcher=/x/claude-work\nclaude-account=\n").claude_account,
            ""
        );
    }

    #[test]
    fn quote_keeps_the_lines_and_says_when_nothing_was_said() {
        // 行の中身は字のまま (頭の空白も) 4 字下げ、前後の空の行と行末の空白・CR を落とす
        assert_eq!(
            quote("\n手 1\r\n  手 2  \n\n手 3\n\n"),
            "    手 1\n      手 2\n\n    手 3"
        );
        assert_eq!(quote(""), "    (何も出さなかった)");
        assert_eq!(quote(" \n\t\n"), "    (何も出さなかった)");
        // 頭の空白だけの行も、空の行として落とす
        assert_eq!(quote("  \n手\n"), "    手");
    }

    #[test]
    fn describe_named_and_default() {
        let c = Choice {
            account: named("work"),
            why: "ハブの CLAUDE_CONFIG_DIR /home/u/.claude-work から".to_owned(),
        };
        let r = Ready {
            program: "/x/claude-work".to_owned(),
            note: Some("子のマシンに /login のアカウントの用意がある".to_owned()),
        };
        assert_eq!(
            describe(&c, &r),
            "claude-work。ハブの CLAUDE_CONFIG_DIR /home/u/.claude-work から。子のマシンに /login のアカウントの用意がある"
        );
        let c = Choice {
            account: Account::Default,
            why: "ハブの CLAUDE_CONFIG_DIR が空".to_owned(),
        };
        let r = Ready {
            program: "/x/claude".to_owned(),
            note: None,
        };
        assert_eq!(
            describe(&c, &r),
            "既定 (素の claude・~/.claude)。ハブの CLAUDE_CONFIG_DIR が空"
        );
    }

    /// 子のマシンで流す script を本物の sh で流す (偽の HOME に launcher と用意のファイルを置く)。
    #[cfg(unix)]
    #[test]
    fn probe_script_runs_in_real_sh() {
        use std::os::unix::fs::PermissionsExt;

        let t = crate::testutil::TempDir::new("account-probe");
        let home = t.path().join("home");
        let bin = home.join(".nix-profile").join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let launcher = bin.join("claude-work");
        std::fs::write(&launcher, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o755)).unwrap();
        let run = |name: &str, path: &str| -> String {
            let out = std::process::Command::new("sh")
                .args(["-c", &probe_script(), "sh", name])
                .env("HOME", &home)
                .env("PATH", path)
                .output()
                .unwrap();
            assert!(out.status.success(), "{out:?}");
            String::from_utf8(out.stdout).unwrap()
        };
        let launcher = launcher.to_string_lossy().into_owned();
        let bare = "/usr/bin:/bin";
        let with_bin = format!("{}:{bare}", bin.to_string_lossy());
        // core の PATH に無い launcher は使わず (claude を見つけられない)、場所だけ知らせる
        assert_eq!(
            parse_found(&run("work", bare)),
            Found {
                offpath: launcher.clone(),
                ..Found::default()
            }
        );
        // PATH にあれば使う。用意のファイルはまだ無い
        assert_eq!(
            parse_found(&run("work", &with_bin)),
            Found {
                launcher: launcher.clone(),
                ..Found::default()
            }
        );
        // /login の資格情報と token のファイル (有る無しだけを見る)
        std::fs::create_dir_all(home.join(".claude-work")).unwrap();
        std::fs::write(home.join(".claude-work").join(".credentials.json"), "").unwrap();
        std::fs::create_dir_all(home.join(".config").join("claude-accounts")).unwrap();
        std::fs::write(
            home.join(".config")
                .join("claude-accounts")
                .join("work.env"),
            "",
        )
        .unwrap();
        assert_eq!(
            parse_found(&run("work", &with_bin)).kinds,
            vec!["login".to_owned(), "token".to_owned()]
        );
        // launcher の無い名前
        assert_eq!(parse_found(&run("personal", &with_bin)), Found::default());
        // claude-account: PATH のものを先に、PATH に無ければ ~/.nix-profile/bin のものを使う
        let put_claude_account = |dir: &std::path::Path| -> String {
            std::fs::create_dir_all(dir).unwrap();
            let p = dir.join("claude-account");
            std::fs::write(&p, "#!/bin/sh\nexit 0\n").unwrap();
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
            p.to_string_lossy().into_owned()
        };
        let in_profile = put_claude_account(&bin);
        assert_eq!(parse_found(&run("work", bare)).claude_account, in_profile);
        assert_eq!(
            parse_found(&run("work", &with_bin)).claude_account,
            in_profile
        );
        let other = t.path().join("other");
        let on_path = put_claude_account(&other);
        let other_first = format!("{}:{with_bin}", other.to_string_lossy());
        assert_eq!(
            parse_found(&run("work", &other_first)).claude_account,
            on_path
        );
        // claude-account add の launcher は ~/.local/bin の link。core の PATH に無ければ使わず、場所だけ知らせる
        let local_bin = home.join(".local").join("bin");
        std::fs::create_dir_all(&local_bin).unwrap();
        let linked = local_bin.join("claude-token1");
        std::fs::write(&linked, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&linked, std::fs::Permissions::from_mode(0o755)).unwrap();
        let f = parse_found(&run("token1", bare));
        assert_eq!(
            (f.launcher.as_str(), f.offpath.as_str()),
            ("", linked.to_string_lossy().as_ref())
        );
    }
}
