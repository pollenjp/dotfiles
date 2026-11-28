//! `claude-account.exe` (手順 `claude-accounts` が `%LOCALAPPDATA%\dotfiles\bin` に置く、この runner の exe の写し) の管理のコマンド。Linux の
//! `nix/pkgs/claude-account` の管理のコマンドと同じサブコマンドと文 (dotfiles-private の docs/adr/082_claude_token_accounts_*)。
//!
//! | サブコマンド | すること |
//! | --- | --- |
//! | `add <名前> --mode subscription\|token` | 登録 (`accounts`) に書き、手順 `claude-accounts` をそのアカウントのぶんだけ流す (dir・symlink (足りなければ UAC の確認 1 回)・launcher) |
//! | `set-token <名前>` | token のアカウントに token を入れる (`token::set_token`。DPAPI)。入れた時刻を控える (`token_audit::put_time`) |
//! | `list` | 既定と登録のアカウント (と素の claude) を、種類・元・状態で並べる |
//! | `check <名前>` | 使えるか (0 = 使える・stdout に 1 行 / 1 = 用意が無い・stderr にユーザーの手 / 2 = 知らない名前)。値を出さず、op を呼ばない |
//! | `remove <名前> [--purge]` | 登録から外して launcher を消す。`--purge` なら `~/.claude-<名前>` (中のリンクは辿らない) と token のファイルと入れた時刻の控えも消す |
//! | `audit` | token の置き場の宣言と、この PC の token・入れた時刻を値を見ずに並べ、判定を出す (`token_audit::audit`) |
//! | `help token [<名前>]` | token をこの PC とほかのマシンに置く手順 |
//!
//! 素の claude (`~/.claude`) は名前 `default` で扱う (`check default`・`list` の行)。Windows の素の claude は token を読まず /login で使うので、
//! `set-token default` は 2 (Linux は宣言のあるホストで token。dotfiles-private の docs/adr/123_claude_token_watch_*)。
//!
//! 終了コード: 0 = 済んだ・使える / 1 = できなかった・用意が無い / 2 = 使い方の誤り・知らない名前 (set-token は PowerShell が無ければ 127)。
//! audit は 0 = 手を入れるものが無い / 1 = ある / 2 = 宣言・登録・控えを読めない。

use crate::accounts::{self, MANAGER, Mode, Origin, Registry, SELECTOR};
use crate::context::Ctx;
use crate::host::{BARE_NAME, Groups, HostValues};
use crate::link::{is_link, link_target, remove_link, same_path};
use crate::manifest::Roots;
use crate::process::{RealSys, Sys};
use crate::report::Kind;
use crate::steps::{self, claude_accounts};
use crate::token;
use crate::token_audit;
use std::ffi::OsString;
use std::io::Write;
use std::path::{Path, PathBuf};

/// 使い方
pub fn usage() -> String {
    [
        "使い方: claude-account <サブコマンド>",
        "  add <名前> --mode subscription|token   アカウントを足す (~/.claude-<名前>・launcher claude-<名前>・登録)",
        "  set-token <名前>                       token のアカウントに token を入れる (見えない入力。パイプなら 1 行)。入れた時刻を控える",
        "  list                                   既定と登録のアカウント (と素の claude) と、その状態を並べる",
        "  check <名前>                           使えるかを確かめる (0 = 使える / 1 = 用意が無い / 2 = 知らない名前)",
        "  remove <名前> [--purge]                登録のアカウントを消す (--purge なら ~/.claude-<名前> と token のファイルも消す)",
        "  audit                                  token の置き場の宣言と、この PC の token・入れた時刻を値を見ずに並べ、判定を出す",
        "  help token [<名前>]                    token をこの PC とほかのマシンに置く手順",
        "",
        "既定のアカウント: personal work (dotfiles apply が作る)。名前は英小文字・数字で始まり、英小文字・数字・- と _ だけ (account・selector・default は使えない)。",
        "素の claude (~/.claude) は名前 default で扱う (check default。Windows の素の claude は token を読まず、/login で使う)。",
        "使い方の詳細は dotfiles の win/README.md「claude-personal・claude-work」「claude の token の置き場の宣言 ([claude.tokens])」。",
    ]
    .join("\n")
}

/// 外とのつなぎ (環境変数・外のコマンド・出力)。試験は偽物を渡す
pub struct Io<'a> {
    pub env: &'a dyn Fn(&str) -> Option<String>,
    pub sys: &'a dyn Sys,
    pub out: &'a mut dyn Write,
    pub err: &'a mut dyn Write,
    /// set-token の入力 (試験だけ。None なら端末)
    pub input: Option<&'a str>,
}

/// exe の入口 (`launcher::main_if_launcher` が呼ぶ)
pub fn main(args: &[OsString]) -> i32 {
    let args: Vec<String> = args
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let env = |k: &str| std::env::var(k).ok();
    let sys = RealSys;
    let mut out = std::io::stdout();
    let mut err = std::io::stderr();
    let mut io = Io {
        env: &env,
        sys: &sys,
        out: &mut out,
        err: &mut err,
        input: None,
    };
    run(&args, &mut io)
}

/// サブコマンドを流して終了コードを返す
pub fn run(args: &[String], io: &mut Io) -> i32 {
    let rest = &args[args.len().min(1)..];
    match args.first().map(String::as_str) {
        Some("add") => add(rest, io),
        Some("set-token") => set_token(rest, io),
        Some("list") => list(rest, io),
        Some("check") => check(rest, io),
        Some("remove") => remove(rest, io),
        Some("audit") => audit(rest, io),
        Some("-h" | "--help") => {
            let _ = writeln!(io.out, "{}", usage());
            0
        }
        Some("help") => match rest {
            [] => {
                let _ = writeln!(io.out, "{}", usage());
                0
            }
            [t] if t == "token" => {
                let _ = writeln!(io.out, "{}", token::help_text(None));
                0
            }
            [t, n] if t == "token" && n == BARE_NAME => {
                let _ = writeln!(io.out, "{}", token::bare_help_text());
                0
            }
            [t, n] if t == "token" && accounts::name_ok(n) => {
                let _ = writeln!(io.out, "{}", token::help_text(Some(n)));
                0
            }
            [t, _] if t == "token" => bad_name(io),
            _ => usage_err(io, "知らない help です (help token [<名前>] がある)。"),
        },
        None => {
            let _ = writeln!(io.err, "{}", usage());
            2
        }
        Some(other) => usage_err(io, &format!("知らないサブコマンドです: {other}")),
    }
}

fn usage_err(io: &mut Io, why: &str) -> i32 {
    let _ = writeln!(io.err, "claude-account: {why}\n{}", usage());
    2
}

fn say_err(io: &mut Io, text: &str) {
    let _ = writeln!(io.err, "{text}");
}

/// 名前に使えない文字列は文に出さない (token を名前の所に渡したときに、token を画面に出さないため)。2 を返す
fn bad_name(io: &mut Io) -> i32 {
    say_err(
        io,
        "claude-account: アカウントの名前に使えません (英小文字・数字で始まり、英小文字・数字・- と _ だけで 32 字まで。sk-ant- で始まらない)。\n  token を名前の所に渡していないか確かめてください (渡した文字は出しません。token は set-token の見えない入力で渡す)。",
    );
    2
}

/// 名前の種類と元。既定は登録を読まずに決める (登録が壊れていても既定は使える)。登録が読めなければ Err
fn lookup_name(home: &Path, name: &str) -> Result<Option<(Mode, Origin)>, String> {
    if claude_accounts::DEFAULT_ACCOUNTS.contains(&name) {
        return Ok(Some((Mode::Subscription, Origin::Default)));
    }
    Ok(accounts::lookup(
        name,
        &claude_accounts::DEFAULT_ACCOUNTS,
        &registry(home)?,
    ))
}

/// 家 (USERPROFILE)
fn home(io: &Io) -> Result<PathBuf, String> {
    (io.env)("USERPROFILE")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| "claude-account: 環境変数 USERPROFILE がありません。".to_string())
}

/// 登録を読む
fn registry(home: &Path) -> Result<Registry, String> {
    Registry::load(&accounts::registry_path(home)).map_err(|e| format!("claude-account: {e}"))
}

/// どのマシンか (check の手に添える)
fn machine(io: &Io) -> String {
    format!(
        "Windows ({})",
        (io.env)("COMPUTERNAME").unwrap_or_else(|| "?".to_string())
    )
}

/// launcher の置き場 (`%LOCALAPPDATA%\dotfiles\bin`)
fn bin_dir(io: &Io, home: &Path) -> PathBuf {
    let local = (io.env)("LOCALAPPDATA")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("AppData").join("Local"));
    crate::context::join_segments(&local, claude_accounts::BIN_DIR_REL)
}

/// 用意が済んでいるか (settings.json と projects が `~/.claude` の同じ名前へのリンク。launcher が確かめるのと同じ)
fn prepared(home: &Path, name: &str) -> bool {
    let dir = home.join(format!(".claude-{name}"));
    let base = home.join(".claude");
    ["settings.json", "projects"]
        .iter()
        .all(|rel| link_target(&dir.join(rel)).is_some_and(|t| same_path(&t, &base.join(rel))))
}

/// アカウントの状態: (終了コード, 0 なら stdout の 1 行・1 なら stderr の手, list に出す短い文)。値を出さず、op を呼ばない
fn state(io: &Io, home: &Path, name: &str, mode: Mode, origin: Origin) -> (i32, String, String) {
    let cmd = format!("claude-{name}");
    let w = machine(io);
    let dir = home.join(format!(".claude-{name}"));
    let fix_add = format!("claude-account add {name} --mode {}", mode.as_str());
    if !prepared(home, name) {
        let fix = match origin {
            Origin::Default => "dotfiles apply を打つ (初回は UAC の確認が 1 回出る)".to_string(),
            Origin::Registered => format!("{fix_add} を打つ"),
        };
        let settings = dir.join("settings.json");
        let real = std::fs::symlink_metadata(&settings).is_ok_and(|m| !m.file_type().is_symlink());
        let text = if real {
            format!(
                "{cmd}: {} が実体です (先に Claude Code を起こした、など)。{w} の端末で、win/README.md の「既に ~/.claude-<名前> があるとき」の手順で片付けてから {fix}。",
                settings.display()
            )
        } else {
            format!(
                "{cmd}: {} がまだ用意されていません。{w} の端末で {fix}。",
                dir.display()
            )
        };
        return (1, text, "dir が用意されていない".to_string());
    }
    let exe = bin_dir(io, home).join(format!("{cmd}.exe"));
    if origin == Origin::Registered && !exe.is_file() {
        return (
            1,
            format!(
                "{cmd}: launcher ({}) がありません。{w} の端末で {fix_add} を打つ。",
                exe.display()
            ),
            "launcher が無い".to_string(),
        );
    }
    if mode == Mode::Subscription {
        return if dir.join(".credentials.json").exists() {
            (
                0,
                format!("{cmd}: subscription (ログイン済み)"),
                "ログイン済み".to_string(),
            )
        } else {
            (
                1,
                format!(
                    "{cmd}: まだログインしていません。{w} の端末で {cmd} を起こし、/login する。"
                ),
                "ログインしていない".to_string(),
            )
        };
    }
    let file = token::file(home, name);
    match token::load(&file) {
        Ok(token::Stored::Plain(_) | token::Stored::Dpapi(_)) => (
            0,
            format!("{cmd}: token (ローカル)"),
            "token (ローカル)".to_string(),
        ),
        // 起こすたびに 1Password の承認が要る (子を立てる側からは、起動の直後に止まって見えうる)
        Ok(token::Stored::Op(_)) => (
            0,
            format!("{cmd}: token (1Password・起動のときに承認が要る)"),
            "token (1Password・起動のときに承認が要る)".to_string(),
        ),
        Err(p) if p.needs_guidance() => (
            1,
            format!(
                "{cmd}: token がありません。{w} の端末で claude setup-token を打って token を出し、claude-account set-token {name} で入れる。"
            ),
            "token が無い".to_string(),
        ),
        Err(p) => (
            1,
            format!(
                "{cmd}: token のファイル ({}) の {}。{w} の端末で直すか、claude-account set-token {name} で入れ直す。",
                file.display(),
                p.why(&file.display().to_string())
            ),
            "token のファイルの形が違う".to_string(),
        ),
    }
}

/// 素の claude (default) の状態 (state と同じ形)。Windows の素の claude は /login で使うので、`~/.claude\.credentials.json` を見る
fn state_bare(io: &Io, home: &Path) -> (i32, String, String) {
    if home.join(".claude").join(".credentials.json").exists() {
        (
            0,
            "claude: subscription (ログイン済み)".to_string(),
            "ログイン済み".to_string(),
        )
    } else {
        (
            1,
            format!(
                "claude: まだログインしていません。{} の端末で claude を起こし、/login する。",
                machine(io)
            ),
            "ログインしていない".to_string(),
        )
    }
}

fn check(args: &[String], io: &mut Io) -> i32 {
    let [name] = args else {
        return usage_err(io, "check に渡すのは名前 1 つだけです。");
    };
    if !accounts::name_ok(name) {
        return bad_name(io);
    }
    if name == BARE_NAME {
        let home = match home(io) {
            Ok(h) => h,
            Err(e) => {
                say_err(io, &e);
                return 1;
            }
        };
        let (code, text, _) = state_bare(io, &home);
        if code == 0 {
            let _ = writeln!(io.out, "{text}");
        } else {
            say_err(io, &text);
        }
        return code;
    }
    let (home, found) = match home(io).and_then(|h| lookup_name(&h, name).map(|f| (h, f))) {
        Ok(x) => x,
        Err(e) => {
            say_err(io, &e);
            return 1;
        }
    };
    let Some((mode, origin)) = found else {
        let w = machine(io);
        say_err(
            io,
            &format!(
                "claude-account: claude-{name} は既定のアカウントでも、登録したアカウントでもありません (一覧は claude-account list)。\n  足すなら {w} の端末で claude-account add {name} --mode subscription (か --mode token) を打つ。"
            ),
        );
        return 2;
    };
    let (code, text, _) = state(io, &home, name, mode, origin);
    if code == 0 {
        let _ = writeln!(io.out, "{text}");
    } else {
        say_err(io, &text);
    }
    code
}

fn list(args: &[String], io: &mut Io) -> i32 {
    if !args.is_empty() {
        return usage_err(io, "list は引数を取りません。");
    }
    let home = match home(io) {
        Ok(h) => h,
        Err(e) => {
            say_err(io, &e);
            return 1;
        }
    };
    let (reg, bad) = match registry(&home) {
        Ok(r) => (r, None),
        Err(e) => (Registry::default(), Some(e)),
    };
    let (_, _, short) = state_bare(io, &home);
    let _ = writeln!(
        io.out,
        "{BARE_NAME:<14} {:<13} 素の claude  {short}",
        Mode::Subscription.as_str()
    );
    for name in accounts::all_names(&claude_accounts::DEFAULT_ACCOUNTS, &reg) {
        if name == BARE_NAME {
            continue;
        }
        if let Some((mode, origin)) =
            accounts::lookup(&name, &claude_accounts::DEFAULT_ACCOUNTS, &reg)
        {
            let (_, _, short) = state(io, &home, &name, mode, origin);
            let _ = writeln!(
                io.out,
                "{name:<14} {:<13} {}  {short}",
                mode.as_str(),
                origin.label()
            );
        }
    }
    match bad {
        Some(e) => {
            say_err(io, &e);
            1
        }
        None => 0,
    }
}

/// 足す名前を確かめる。だめなら (2, わけ)
fn new_name_ok(name: &str) -> Result<(), String> {
    if !accounts::name_ok(name) {
        return Err(
            "claude-account: アカウントの名前に使えません (英小文字・数字で始まり、英小文字・数字・- と _ だけで 32 字まで。sk-ant- で始まらない)。\n  token を名前の所に渡していないか確かめてください (渡した文字は出しません)。".to_string(),
        );
    }
    if name == MANAGER {
        return Err(
            "claude-account: account は管理のコマンド (claude-account) の名前なので、アカウントには使えません。".to_string(),
        );
    }
    if name == SELECTOR {
        return Err(
            "claude-account: selector は claude-selector (cs) の名前なので、アカウントには使えません。".to_string(),
        );
    }
    if name == BARE_NAME {
        return Err(format!(
            "claude-account: {BARE_NAME} は素の claude (~/.claude) の名前なので、アカウントには使えません (Windows の素の claude は token を読まず、/login で使う)。"
        ));
    }
    if claude_accounts::DEFAULT_ACCOUNTS.contains(&name) {
        return Err(format!(
            "claude-account: {name} は既定のアカウントです (dotfiles apply が作るので、足さなくてよい)。"
        ));
    }
    Ok(())
}

fn add(args: &[String], io: &mut Io) -> i32 {
    let mut name: Option<&str> = None;
    let mut mode: Option<&str> = None;
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--mode" {
            let Some(v) = args.get(i + 1) else {
                return usage_err(
                    io,
                    "--mode の後ろに種類 (subscription・token) がありません。",
                );
            };
            mode = Some(v);
            i += 2;
        } else if let Some(v) = a.strip_prefix("--mode=") {
            mode = Some(v);
            i += 1;
        } else if a.starts_with('-') {
            return usage_err(io, &format!("知らない option です: {a}"));
        } else if name.is_some() {
            return usage_err(io, "名前は 1 つだけ渡します。");
        } else {
            name = Some(a);
            i += 1;
        }
    }
    let (Some(name), Some(mode)) = (name, mode) else {
        return usage_err(io, "add には名前と --mode が要ります。");
    };
    let Some(mode) = Mode::parse(mode) else {
        return usage_err(io, &format!("種類は subscription か token です: {mode}"));
    };
    if let Err(e) = new_name_ok(name) {
        say_err(io, &e);
        return 2;
    }
    let home = match home(io) {
        Ok(h) => h,
        Err(e) => {
            say_err(io, &e);
            return 1;
        }
    };
    let mut reg = match registry(&home) {
        Ok(r) => r,
        Err(e) => {
            say_err(io, &e);
            return 1;
        }
    };
    match reg.accounts.get(name) {
        Some(cur) if *cur != mode => {
            say_err(
                io,
                &format!(
                    "claude-account: {name} はもう {} で登録しています。種類を替えるなら claude-account remove {name} を打ってから足し直してください。",
                    cur.as_str()
                ),
            );
            return 1;
        }
        Some(_) => {}
        None => {
            reg.accounts.insert(name.to_string(), mode);
            if let Err(e) = reg.save(&accounts::registry_path(&home)) {
                say_err(io, &format!("claude-account: {e}"));
                return 1;
            }
            let _ = writeln!(io.out, "登録しました: {name} ({})", mode.as_str());
        }
    }
    let outcomes = match prepare_one(io, name) {
        Ok(o) => o,
        Err(e) => {
            say_err(io, &e);
            return 1;
        }
    };
    let mut ok = true;
    for o in &outcomes {
        let mark = if o.kind == Kind::Ok { "✔" } else { "⚠" };
        ok &= o.kind == Kind::Ok;
        let _ = writeln!(io.out, "{mark} {}", o.text);
        for n in &o.notes {
            let _ = writeln!(io.out, "    ※ {n}");
        }
    }
    let _ = writeln!(io.out);
    if mode == Mode::Subscription {
        let _ = writeln!(
            io.out,
            "claude-{name} で起こし、初回は /login でそのアカウントにログインしてください。"
        );
    } else {
        let file = token::file(&home, name);
        let line = match token::load(&file) {
            Ok(_) => format!(
                "この PC の token のファイル ({}) はもうあります。claude-{name} で起こせます (確かめるなら claude-account check {name})。",
                file.display()
            ),
            Err(_) => format!(
                "次に token を置いてください (この手順は claude-account help token {name} でいつでも見られます)。"
            ),
        };
        let _ = writeln!(io.out, "{line}\n\n{}", token::help_text(Some(name)));
    }
    if ok {
        0
    } else {
        say_err(
            io,
            &format!(
                "claude-account: 用意が済んでいないものがあります (上の ⚠)。直してから claude-account add {name} --mode {} を打ち直してください。",
                mode.as_str()
            ),
        );
        1
    }
}

/// 手順 `claude-accounts` を `name` のアカウントのぶんだけ apply で流す (ホストの値は使わない手順なので、無い値で組む)
fn prepare_one(io: &mut Io, name: &str) -> Result<Vec<steps::Outcome>, String> {
    let roots = Roots::from_env(io.env)?;
    let state_dir = roots.local_app_data.join("dotfiles").join("state");
    let groups = Groups::embedded()?;
    let mut ctx = Ctx {
        repo: PathBuf::new(),
        roots,
        state_dir,
        host: HostValues::missing(Path::new("claude-account"), groups),
        sys: io.sys,
        out: &mut *io.out,
    };
    Ok(claude_accounts::run_accounts(
        &mut ctx,
        steps::Mode::Apply { force: false },
        &[name.to_string()],
        false,
    ))
}

fn set_token(args: &[String], io: &mut Io) -> i32 {
    let [name] = args else {
        return usage_err(
            io,
            "set-token に渡すのは名前 1 つだけです (token は引数でなく、見えない入力かパイプで渡す)。",
        );
    };
    if !accounts::name_ok(name) {
        return bad_name(io);
    }
    if name == BARE_NAME {
        say_err(
            io,
            &format!(
                "claude-account: Windows の素の claude ({BARE_NAME}) は token を読みません (Windows の素の claude は /login で使う)。\n  token で起こすアカウントが要るなら、claude-account add <名前> --mode token で足してください。"
            ),
        );
        return 2;
    }
    let (home, found) = match home(io).and_then(|h| lookup_name(&h, name).map(|f| (h, f))) {
        Ok(x) => x,
        Err(e) => {
            say_err(io, &e);
            return 1;
        }
    };
    match found {
        None => {
            say_err(
                io,
                &format!(
                    "claude-account: {name} は既定のアカウントでも、登録したアカウントでもありません (足すなら claude-account add {name} --mode token)。"
                ),
            );
            return 2;
        }
        Some((Mode::Subscription, _)) => {
            say_err(
                io,
                &format!(
                    "claude-account: claude-{name} は subscription のアカウントで、token は使いません (claude-{name} を起こして /login する)。"
                ),
            );
            return 2;
        }
        Some((Mode::Token, _)) => {}
    }
    let powershell = token::system_powershell(io.env);
    if !powershell.is_file() {
        say_err(
            io,
            &format!(
                "claude-account: token を暗号化する powershell.exe が見つかりません ({})。",
                powershell.display()
            ),
        );
        return 127;
    }
    // 値を聞く前に、控えが読めない形なら止まる (token を書いたのに時刻を控えられない、を避ける)
    let times = token_audit::times_path(&home);
    if let Err(e) = token_audit::load_times(&times) {
        say_err(io, &e);
        return 1;
    }
    match token::set_token(name, &token::file(&home, name), &powershell, io.input) {
        Ok(msg) => {
            let _ = writeln!(io.out, "{msg}");
            let recorded = token_audit::now_epoch(io.env).and_then(|now| {
                let at = token_audit::iso_jst(now);
                token_audit::put_time(&times, name, Some(&at)).map(|()| at)
            });
            match recorded {
                Ok(at) => {
                    let _ = writeln!(io.out, "入れた時刻: {at} ({})", times.display());
                    0
                }
                Err(e) => {
                    say_err(
                        io,
                        &format!(
                            "{e}\nclaude-account: token は書きましたが、入れた時刻を {} に控えられません (棚卸しは「回す」と出す)。直してから set-token を打ち直してください。",
                            times.display()
                        ),
                    );
                    1
                }
            }
        }
        Err((code, msg)) => {
            say_err(io, &msg);
            code
        }
    }
}

fn audit(args: &[String], io: &mut Io) -> i32 {
    if !args.is_empty() {
        return usage_err(io, "audit は引数を取りません。");
    }
    let home = match home(io) {
        Ok(h) => h,
        Err(e) => {
            say_err(io, &e);
            return 2;
        }
    };
    let mut aio = token_audit::AuditIo {
        env: io.env,
        sys: io.sys,
        out: &mut *io.out,
        err: &mut *io.err,
    };
    token_audit::audit(&home, &mut aio)
}

/// dir を消す (中のリンクは辿らずにリンクだけを外す)。dir がリンク・`~/.claude` と同じ場所なら消さない
fn purge_dir(dir: &Path, base: &Path) -> Result<bool, String> {
    if std::fs::symlink_metadata(dir).is_err() {
        return Ok(false);
    }
    if is_link(dir) {
        return Err(format!(
            "claude-account: {} がリンクなので消しません (先を確かめてから手で外してください)。",
            dir.display()
        ));
    }
    if same_path(dir, base) {
        return Err(format!(
            "claude-account: {} は ~/.claude と同じ場所なので消しません。",
            dir.display()
        ));
    }
    remove_tree(dir)
        .map_err(|e| format!("claude-account: {} を消せません ({e})", dir.display()))?;
    Ok(true)
}

/// リンクを辿らずに木を消す (リンクは外すだけ。junction の先の中身を消さない)
fn remove_tree(p: &Path) -> std::io::Result<()> {
    for entry in std::fs::read_dir(p)? {
        let path = entry?.path();
        if is_link(&path) {
            remove_link(&path)?;
        } else if std::fs::symlink_metadata(&path)?.is_dir() {
            remove_tree(&path)?;
        } else {
            std::fs::remove_file(&path)?;
        }
    }
    std::fs::remove_dir(p)
}

fn remove(args: &[String], io: &mut Io) -> i32 {
    let mut name: Option<&str> = None;
    let mut purge = false;
    for a in args {
        if a == "--purge" {
            purge = true;
        } else if a.starts_with('-') {
            return usage_err(io, &format!("知らない option です: {a}"));
        } else if name.is_some() {
            return usage_err(io, "名前は 1 つだけ渡します。");
        } else {
            name = Some(a);
        }
    }
    let Some(name) = name else {
        return usage_err(io, "remove には名前が要ります。");
    };
    if !accounts::name_ok(name) {
        return bad_name(io);
    }
    if accounts::RESERVED.contains(&name) {
        say_err(
            io,
            &format!(
                "claude-account: {name} は管理のコマンド・claude-selector の名前で、アカウントではありません。"
            ),
        );
        return 2;
    }
    if name == BARE_NAME {
        say_err(
            io,
            &format!(
                "claude-account: {BARE_NAME} は素の claude (~/.claude) の名前で、消せるアカウントではありません。"
            ),
        );
        return 2;
    }
    if claude_accounts::DEFAULT_ACCOUNTS.contains(&name) {
        say_err(
            io,
            &format!(
                "claude-account: {name} は既定のアカウントなので消せません (dotfiles apply が作る)。"
            ),
        );
        return 2;
    }
    let (home, mut reg) = match home(io).and_then(|h| registry(&h).map(|r| (h, r))) {
        Ok(x) => x,
        Err(e) => {
            say_err(io, &e);
            return 1;
        }
    };
    let dir = home.join(format!(".claude-{name}"));
    let file = token::file(&home, name);
    let exe = bin_dir(io, &home).join(format!("claude-{name}.exe"));
    let registered = reg.accounts.contains_key(name);
    let leftovers = std::fs::symlink_metadata(&dir).is_ok() || file.exists();
    if !registered && !(purge && leftovers) {
        say_err(
            io,
            &format!(
                "claude-account: {name} は登録したアカウントではありません (claude-account list で見る)。"
            ),
        );
        return 2;
    }
    if exe.exists() {
        if let Err(e) = std::fs::remove_file(&exe) {
            say_err(
                io,
                &format!(
                    "claude-account: {} を消せません ({e})。claude-{name} が動いていれば閉じてから打ち直してください。",
                    exe.display()
                ),
            );
            return 1;
        }
        let _ = writeln!(io.out, "消しました: {}", exe.display());
    }
    if registered {
        reg.accounts.remove(name);
        if let Err(e) = reg.save(&accounts::registry_path(&home)) {
            say_err(io, &format!("claude-account: {e}"));
            return 1;
        }
        let _ = writeln!(io.out, "登録から外しました: {name}");
    }
    if !purge {
        let mut kept = false;
        if std::fs::symlink_metadata(&dir).is_ok() {
            let _ = writeln!(io.out, "残しました: {} (ログイン・履歴など)", dir.display());
            kept = true;
        }
        if file.exists() {
            let _ = writeln!(io.out, "残しました: {} (token)", file.display());
            kept = true;
        }
        if kept {
            let _ = writeln!(
                io.out,
                "消すなら claude-account remove {name} --purge を打ってください。"
            );
        }
        return 0;
    }
    match purge_dir(&dir, &home.join(".claude")) {
        Ok(true) => {
            let _ = writeln!(io.out, "消しました: {}", dir.display());
        }
        Ok(false) => {}
        Err(e) => {
            say_err(io, &e);
            return 1;
        }
    }
    if file.exists() {
        if let Err(e) = std::fs::remove_file(&file) {
            say_err(
                io,
                &format!("claude-account: {} を消せません ({e})", file.display()),
            );
            return 1;
        }
        let _ = writeln!(io.out, "消しました: {}", file.display());
    }
    // 消した token の入れた時刻も控えから外す (残すと、同じ名前で足し直した token が古い時刻で並ぶ)
    let times = token_audit::times_path(&home);
    let recorded = token_audit::load_times(&times).map(|t| t.contains_key(name));
    match recorded {
        Ok(false) => {}
        Ok(true) => match token_audit::put_time(&times, name, None) {
            Ok(()) => {
                let _ = writeln!(io.out, "控えから外しました: {name} の入れた時刻");
            }
            Err(e) => say_err(io, &e),
        },
        Err(_) => say_err(
            io,
            &format!(
                "claude-account: 入れた時刻の控え ({}) から {name} を外せません。",
                times.display()
            ),
        ),
    }
    0
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 使い方: 引数なし・知らないサブコマンド・知らない help は 2。help token <名前> は名前を埋めた置き方を出す
    //! - add: 規則外の名前・account・既定の名前・知らない種類は 2。token1 を token で足すと、登録に書き、手順の流れ (FakeSys の mklink) で
    //!   dir と launcher (claude-token1.exe) を用意し、置き方 (help token) を出す。違う種類の打ち直しは 1
    //! - check: 知らない名前は 2。用意が無い (既定は dotfiles apply)・token が無い (set-token)・ファイルの形が違う・ログインしていない
    //!   (/login) は 1 で stderr に手 (どのマシンかも)。使えるなら 0 で stdout に 1 行 (token (ローカル)・token (1Password)・
    //!   subscription (ログイン済み))。どの文にも値が無い
    //! - list: 既定と登録を種類と元と一緒に並べる
    //! - remove: 既定と知らない名前は 2。launcher と登録を消し、dir を残して --purge を出す。--purge は登録の外でも dir と token のファイル
    //!   を消し、中のリンクの先 (~/.claude) は残す
    //! - set-token: subscription・知らない名前・ほかの引数は 2
    //! - 素の claude (default): check default は ~/.claude\.credentials.json を見て 1・0 (どの PC かを添える)、list の先頭に素の claude の行、
    //!   set-token default・add default・remove default は 2 (何も書かない)、help token default は Linux と同じ素の claude の手順
    //! - (unix。偽の System32 の PowerShell) set-token は入れた時刻 (日本時間・秒まで。CLAUDE_ACCOUNT_NOW) を控え (1 行の JSON・キーの順)、ほかの
    //!   名前の時刻は残す。控えが読めない形なら PowerShell を起こす前に 1 で止まり、token のファイルを書かない。remove --purge は控えからも外す
    //! - audit (Linux の claude-account audit と同じ表・判定・数の行・終了コード): 宣言・登録・token のファイル・控えから ok・入れる (登録が無い・
    //!   token が無い)・宣言漏れ (宣言の無い token のアカウントと default.env)・回す (330 日を超えた・控えが無い。ちょうど 330 日は ok)・直す
    //!   (平文・ACL が広い・ACL を読めない) を出す。権限の列は ACL の要約 (本人だけ・SYSTEM・Administrators・本人・広い・?)。同じ呼び名の組を並べ、
    //!   宣言・登録・控え・CLAUDE_ACCOUNT_NOW が読めない形・引数は 2。どの出力にも値が無い

    use super::*;
    use crate::process::{Exit, RunResult};
    use crate::testutil::{FakeSys, TempDir, fake_mklink};
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::rc::Rc;

    struct World {
        t: TempDir,
        /// 偽の Get-Acl の答え (ファイル名 → 行。無ければ本人だけ)
        acl: Rc<RefCell<BTreeMap<String, Vec<String>>>>,
    }

    /// 偽の Get-Acl の答え: 本人だけ (set-token が付ける形)
    fn acl_me() -> Vec<String> {
        vec![
            "me=S-1-5-21-1000".to_string(),
            "owner=S-1-5-21-1000".to_string(),
            "rule=Allow|2032127|0|S-1-5-21-1000|PC1\\me".to_string(),
        ]
    }

    /// 偽の Get-Acl の答え: %USERPROFILE% から継いだ形 (SYSTEM・Administrators・本人)
    fn acl_inherited() -> Vec<String> {
        let mut v = acl_me();
        v.push("rule=Allow|2032127|0|S-1-5-18|NT AUTHORITY\\SYSTEM".to_string());
        v.push("rule=Allow|2032127|0|S-1-5-32-544|BUILTIN\\Administrators".to_string());
        v
    }

    impl World {
        fn new() -> Self {
            let t = TempDir::new("account-cli");
            t.write("home/.claude/settings.json", "{}\n");
            t.write("home/.claude/CLAUDE.md", "# 指示\n");
            t.write("home/.claude/projects/p1/s.jsonl", "{}\n");
            t.write("exe/dotfiles-win.exe", "runner-v1");
            World {
                t,
                acl: Rc::new(RefCell::new(BTreeMap::new())),
            }
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        fn local(&self) -> PathBuf {
            self.home().join("AppData").join("Local")
        }

        fn bin(&self, name: &str) -> PathBuf {
            self.local()
                .join("dotfiles")
                .join("bin")
                .join(format!("claude-{name}.exe"))
        }

        /// 偽の外のコマンド: mklink (junction とファイルの symlink) と、置き場が入っているユーザーの PATH
        fn sys(&self) -> FakeSys {
            let bin_dir = self.local().join("dotfiles").join("bin");
            let acl = Rc::clone(&self.acl);
            FakeSys::new(move |c| {
                if let Some(r) = fake_mklink(c) {
                    return r;
                }
                if c.args_lossy().last().is_some_and(|a| a.contains("Get-Acl")) {
                    let path = c
                        .envs
                        .iter()
                        .find(|(k, _)| k == "DOTFILES_ACL_PATH")
                        .and_then(|(_, v)| v.clone())
                        .map(PathBuf::from)
                        .unwrap();
                    let name = path.file_name().unwrap().to_string_lossy().into_owned();
                    let lines = acl.borrow().get(&name).cloned().unwrap_or_else(acl_me);
                    let code = if lines.iter().any(|l| l.starts_with("error:")) {
                        1
                    } else {
                        0
                    };
                    return RunResult {
                        exit: Exit::Code(code),
                        output: lines,
                    };
                }
                if c.args_lossy()
                    .last()
                    .is_some_and(|a| a.contains("DoNotExpandEnvironmentNames"))
                {
                    return RunResult {
                        exit: Exit::Code(0),
                        output: vec![
                            "kind=ExpandString".to_string(),
                            format!("raw=C:\\Windows;{}", bin_dir.display()),
                        ],
                    };
                }
                panic!("知らないコマンド: {:?}", c.args_lossy());
            })
            .with_program("pwsh", "pwsh")
            .with_env("ComSpec", "C:\\Windows\\system32\\cmd.exe")
            .with_exe(&self.t.path().join("exe").join("dotfiles-win.exe"))
        }

        /// サブコマンドを流す: (終了コード, stdout, stderr)
        fn run(&self, args: &[&str]) -> (i32, String, String) {
            self.run_env(args, &[])
        }

        /// 環境変数 `extra` (CLAUDE_ACCOUNT_NOW など) を足してサブコマンドを流す。SystemRoot は試験の家の win (偽の PowerShell の置き場)
        fn run_env(&self, args: &[&str], extra: &[(&str, &str)]) -> (i32, String, String) {
            let home = self.home();
            let local = self.local();
            let system_root = self.t.path().join("win");
            let extra: Vec<(String, String)> = extra
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect();
            let env = move |k: &str| match k {
                "USERPROFILE" => Some(home.to_string_lossy().into_owned()),
                "APPDATA" => Some(
                    home.join("AppData")
                        .join("Roaming")
                        .to_string_lossy()
                        .into_owned(),
                ),
                "LOCALAPPDATA" => Some(local.to_string_lossy().into_owned()),
                "COMPUTERNAME" => Some("PC1".to_string()),
                "SystemRoot" => Some(system_root.to_string_lossy().into_owned()),
                _ => extra.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone()),
            };
            let sys = self.sys();
            let (mut out, mut err) = (Vec::new(), Vec::new());
            let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
            let code = {
                let mut io = Io {
                    env: &env,
                    sys: &sys,
                    out: &mut out,
                    err: &mut err,
                    input: None,
                };
                run(&args, &mut io)
            };
            (
                code,
                String::from_utf8(out).unwrap(),
                String::from_utf8(err).unwrap(),
            )
        }

        fn registry(&self) -> Registry {
            Registry::load(&accounts::registry_path(&self.home())).unwrap()
        }
    }

    /// ファイルの symlink を張れる環境か (Windows で権限が無ければ add の試験を飛ばす)
    fn symlinks_work(t: &TempDir) -> bool {
        let target = t.write("probe/target", "x");
        let link = t.path().join("probe").join("link");
        let ok =
            crate::testutil::fake_file_symlink(&link.to_string_lossy(), &target.to_string_lossy())
                .exit
                == Exit::Code(0);
        let _ = std::fs::remove_file(&link);
        ok
    }

    #[test]
    fn usage_and_help() {
        let w = World::new();
        assert_eq!(w.run(&[]).0, 2);
        assert_eq!(w.run(&["frob"]).0, 2);
        assert_eq!(w.run(&["help", "x"]).0, 2);
        let (code, out, _) = w.run(&["--help"]);
        assert_eq!(code, 0);
        assert!(
            out.contains("add <名前> --mode subscription|token"),
            "{out}"
        );
        let (code, out, _) = w.run(&["help", "token", "token1"]);
        assert_eq!(code, 0);
        assert!(
            out.contains("claude-account add token1 --mode token"),
            "{out}"
        );
        assert!(out.contains("claude-account check token1"), "{out}");
    }

    #[test]
    fn add_refuses_bad_names() {
        let w = World::new();
        for args in [
            ["add", "Bad", "--mode", "token"],
            ["add", "account", "--mode", "token"],
            ["add", "selector", "--mode", "subscription"],
            ["add", "personal", "--mode", "subscription"],
            ["add", "x", "--mode", "foo"],
        ] {
            assert_eq!(w.run(&args).0, 2, "{args:?}");
        }
        assert!(w.registry().accounts.is_empty());
    }

    #[test]
    fn add_prepares_the_account() {
        let w = World::new();
        if !symlinks_work(&w.t) {
            return;
        }
        let (code, out, err) = w.run(&["add", "token1", "--mode", "token"]);
        assert_eq!(code, 0, "{out}\n{err}");
        assert_eq!(w.registry().accounts.get("token1"), Some(&Mode::Token));
        let dir = w.home().join(".claude-token1");
        for f in ["settings.json", "CLAUDE.md", "projects"] {
            assert!(
                same_path(
                    &link_target(&dir.join(f)).unwrap(),
                    &w.home().join(".claude").join(f)
                ),
                "{f}"
            );
        }
        assert_eq!(std::fs::read(w.bin("token1")).unwrap(), b"runner-v1");
        assert!(
            !w.bin("account").exists(),
            "add は claude-account.exe を置かない"
        );
        assert!(out.contains("ほかのマシン"), "{out}");
        assert!(out.contains("claude-account set-token token1"), "{out}");
        // 違う種類の打ち直しは 1
        let (code, _, err) = w.run(&["add", "token1", "--mode", "subscription"]);
        assert_eq!(code, 1, "{err}");
        assert!(err.contains("remove"), "{err}");
        // check: token が無い → 1 (手とマシン)、置けば 0
        let (code, out, err) = w.run(&["check", "token1"]);
        assert_eq!((code, out.as_str()), (1, ""), "{err}");
        assert!(err.contains("claude-account set-token token1"), "{err}");
        assert!(err.contains("Windows (PC1)"), "{err}");
        let file = token::file(&w.home(), "token1");
        std::fs::write(&file, "CLAUDE_CODE_OAUTH_TOKEN=dummy-plain-5\n").unwrap();
        let (code, out, _) = w.run(&["check", "token1"]);
        assert_eq!(
            (code, out.as_str()),
            (0, "claude-token1: token (ローカル)\n")
        );
        std::fs::write(&file, "CLAUDE_CODE_OAUTH_TOKEN=op://v/i/f\n").unwrap();
        let (code, out, _) = w.run(&["check", "token1"]);
        assert_eq!(
            (code, out.as_str()),
            (
                0,
                "claude-token1: token (1Password・起動のときに承認が要る)\n"
            )
        );
        std::fs::write(&file, "ANTHROPIC_API_KEY=dummy-key\n").unwrap();
        let (code, out, err) = w.run(&["check", "token1"]);
        assert_eq!(code, 1);
        assert!(!out.contains("dummy") && !err.contains("dummy"), "{err}");
        assert!(err.contains("1 行目"), "{err}");
        // list
        let (code, out, _) = w.run(&["list"]);
        assert_eq!(code, 0);
        assert!(
            out.lines().any(|l| l.starts_with("personal")
                && l.contains("subscription")
                && l.contains("既定")),
            "{out}"
        );
        assert!(
            out.lines()
                .any(|l| l.starts_with("token1") && l.contains("token") && l.contains("登録")),
            "{out}"
        );
        // remove: launcher と登録を消し、dir と token を残す
        let (code, out, err) = w.run(&["remove", "token1"]);
        assert_eq!(code, 0, "{err}");
        assert!(!w.bin("token1").exists());
        assert!(w.registry().accounts.is_empty());
        assert!(dir.exists());
        assert!(out.contains("--purge"), "{out}");
        // --purge は登録の外でも残りを消し、中のリンクの先は残す
        let (code, _, err) = w.run(&["remove", "token1", "--purge"]);
        assert_eq!(code, 0, "{err}");
        assert!(std::fs::symlink_metadata(&dir).is_err());
        assert!(!file.exists());
        assert!(w.home().join(".claude").join("settings.json").is_file());
        assert!(
            w.home()
                .join(".claude")
                .join("projects")
                .join("p1")
                .join("s.jsonl")
                .is_file()
        );
    }

    /// 登録の一覧が壊れていても既定は確かめられる。名前に token を渡しても文に出さない。知らない名前の 2 は add の手を出す
    #[test]
    fn broken_registry_and_token_like_names() {
        let w = World::new();
        w.t.write(
            "home/.config/claude-accounts/accounts.json",
            "{\"version\":1,\"accounts\":[",
        );
        let (code, _, err) = w.run(&["check", "personal"]);
        assert_eq!(code, 1, "{err}");
        assert!(!err.contains("accounts.json"), "{err}");
        assert!(err.contains("dotfiles apply"), "{err}");
        std::fs::remove_file(w.home().join(".config/claude-accounts/accounts.json")).unwrap();
        for sub in ["check", "set-token", "remove", "add"] {
            let args: Vec<&str> = if sub == "add" {
                vec![sub, "sk-ant-oat01-dummy-leak", "--mode", "token"]
            } else {
                vec![sub, "sk-ant-oat01-dummy-leak"]
            };
            let (code, out, err) = w.run(&args);
            assert_eq!(code, 2, "{sub}: {err}");
            assert!(
                !out.contains("dummy") && !err.contains("dummy"),
                "{sub}: {err}"
            );
        }
        let (code, _, err) = w.run(&["check", "nosuch"]);
        assert_eq!(code, 2);
        assert!(err.contains("claude-account add nosuch --mode"), "{err}");
    }

    #[test]
    fn check_subscription_and_unknown() {
        let w = World::new();
        assert_eq!(w.run(&["check", "nosuch"]).0, 2);
        let (code, _, err) = w.run(&["check", "work"]);
        assert_eq!(code, 1);
        assert!(err.contains("dotfiles apply"), "{err}");
        assert_eq!(w.run(&["remove", "work"]).0, 2);
        assert_eq!(w.run(&["remove", "nosuch"]).0, 2);
        assert_eq!(w.run(&["remove", "selector"]).0, 2);
        assert_eq!(w.run(&["set-token", "work"]).0, 2);
        assert_eq!(w.run(&["set-token", "nosuch"]).0, 2);
        assert_eq!(w.run(&["set-token", "a", "b"]).0, 2);
        if !symlinks_work(&w.t) {
            return;
        }
        let (code, _, err) = w.run(&["add", "sub2", "--mode", "subscription"]);
        assert_eq!(code, 0, "{err}");
        let (code, _, err) = w.run(&["check", "sub2"]);
        assert_eq!(code, 1);
        assert!(err.contains("claude-sub2 を起こし、/login"), "{err}");
        std::fs::write(
            w.home().join(".claude-sub2").join(".credentials.json"),
            "{}",
        )
        .unwrap();
        let (code, out, _) = w.run(&["check", "sub2"]);
        assert_eq!(
            (code, out.as_str()),
            (0, "claude-sub2: subscription (ログイン済み)\n")
        );
    }

    /// DPAPI の暗号文の形の字 (中身は作り物)
    fn blob() -> String {
        format!("{}{}", token::DPAPI_HEADER, "00".repeat(16))
    }

    /// 素の claude (default) は check・list で扱い、set-token・add・remove では断る (Windows の素の claude は /login)
    #[test]
    fn default_is_the_bare_claude() {
        let w = World::new();
        let (code, out, err) = w.run(&["check", "default"]);
        assert_eq!(code, 1, "{out}");
        assert_eq!(
            err,
            "claude: まだログインしていません。Windows (PC1) の端末で claude を起こし、/login する。\n"
        );
        let (_, out, _) = w.run(&["list"]);
        assert_eq!(
            out.lines().next(),
            Some("default        subscription  素の claude  ログインしていない")
        );
        std::fs::write(w.home().join(".claude").join(".credentials.json"), "{}").unwrap();
        let (code, out, _) = w.run(&["check", "default"]);
        assert_eq!(
            (code, out.as_str()),
            (0, "claude: subscription (ログイン済み)\n")
        );
        let (_, out, _) = w.run(&["list"]);
        assert_eq!(
            out.lines().next(),
            Some("default        subscription  素の claude  ログイン済み")
        );
        let (code, _, err) = w.run(&["set-token", "default"]);
        assert_eq!(code, 2);
        assert!(
            err.contains("Windows の素の claude (default) は token を読みません"),
            "{err}"
        );
        let (code, _, err) = w.run(&["add", "default", "--mode", "token"]);
        assert_eq!(code, 2);
        assert!(
            err.contains("default は素の claude (~/.claude) の名前"),
            "{err}"
        );
        let (code, _, err) = w.run(&["remove", "default", "--purge"]);
        assert_eq!(code, 2);
        assert!(err.contains("消せるアカウントではありません"), "{err}");
        assert!(w.registry().accounts.is_empty());
        assert!(!token::file(&w.home(), "default").exists());
        let (code, out, _) = w.run(&["help", "token", "default"]);
        assert_eq!(code, 0);
        assert!(out.contains("claude-account set-token default"), "{out}");
        assert!(out.contains("dotfiles.claude.tokens.default"), "{out}");
        assert!(!out.contains("claude-account add default"), "{out}");
    }

    /// 偽の System32 の PowerShell (set-token の script の代わりに、暗号文の形の字を DOTFILES_TOKEN_OUT に書く。起こされたら印を残す)
    #[cfg(unix)]
    fn fake_powershell(w: &World) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let ps = token::system_powershell(&|k| {
            (k == "SystemRoot").then(|| w.t.path().join("win").to_string_lossy().into_owned())
        });
        let marker = w.t.path().join("ps.called");
        std::fs::create_dir_all(ps.parent().unwrap()).unwrap();
        std::fs::write(
            &ps,
            format!(
                "#!/bin/sh\ntouch '{}'\nprintf '%s' '{}' > \"$DOTFILES_TOKEN_OUT\"\n",
                marker.display(),
                blob()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&ps, std::fs::Permissions::from_mode(0o755)).unwrap();
        marker
    }

    /// set-token は入れた時刻を控え、remove --purge は控えからも外す。控えが読めない形なら値を読む前に止まる
    #[cfg(unix)]
    #[test]
    fn set_token_records_the_time() {
        let w = World::new();
        let marker = fake_powershell(&w);
        w.t.write(
            "home/.config/claude-accounts/accounts.json",
            "{\"version\":1,\"accounts\":{\"token1\":{\"mode\":\"token\"},\"token2\":{\"mode\":\"token\"}}}\n",
        );
        let times = token_audit::times_path(&w.home());
        let (code, out, err) = w.run_env(
            &["set-token", "token1"],
            &[("CLAUDE_ACCOUNT_NOW", "2026-11-28T21:00:00+09:00")],
        );
        assert_eq!(code, 0, "{out}\n{err}");
        assert!(out.contains("書きました: "), "{out}");
        assert!(
            out.contains(&format!(
                "入れた時刻: 2026-11-28T21:00:00+09:00 ({})",
                times.display()
            )),
            "{out}"
        );
        let (code, _, err) = w.run_env(
            &["set-token", "token2"],
            &[("CLAUDE_ACCOUNT_NOW", "2026-11-28T23:30:15Z")],
        );
        assert_eq!(code, 0, "{err}");
        assert_eq!(
            std::fs::read_to_string(&times).unwrap(),
            "{\"token1\":{\"set_at\":\"2026-11-28T21:00:00+09:00\"},\"token2\":{\"set_at\":\"2026-11-29T08:30:15+09:00\"}}\n"
        );
        assert!(matches!(
            token::load(&token::file(&w.home(), "token1")),
            Ok(token::Stored::Dpapi(_))
        ));
        // 控えが読めない形なら PowerShell を起こさずに 1 (token のファイルを書かない)
        let keep = std::fs::read_to_string(&times).unwrap();
        std::fs::write(&times, "not json\n").unwrap();
        std::fs::remove_file(&marker).unwrap();
        let before = std::fs::read_to_string(token::file(&w.home(), "token1")).unwrap();
        let (code, _, err) = w.run(&["set-token", "token1"]);
        assert_eq!(code, 1, "{err}");
        assert!(err.contains("入れた時刻の控え"), "{err}");
        assert!(!marker.exists());
        assert_eq!(
            std::fs::read_to_string(token::file(&w.home(), "token1")).unwrap(),
            before
        );
        std::fs::write(&times, keep).unwrap();
        // remove --purge は控えからも外し、ほかは残す
        let (code, out, err) = w.run(&["remove", "token2", "--purge"]);
        assert_eq!(code, 0, "{err}");
        assert!(
            out.contains("控えから外しました: token2 の入れた時刻"),
            "{out}"
        );
        assert_eq!(
            std::fs::read_to_string(&times).unwrap(),
            "{\"token1\":{\"set_at\":\"2026-11-28T21:00:00+09:00\"}}\n"
        );
        assert!(!token::file(&w.home(), "token2").exists());
    }

    /// 棚卸しの世界: 宣言 (alt・x)・登録 (alt・token1 は token、sub2 は subscription)・token のファイル (alt・token1)・控え (alt)
    fn audit_world(set_at: Option<&str>) -> World {
        let w = World::new();
        w.t.write(
            "home/.local/state/dotfiles/claude-tokens.json",
            "{\"accounts\":{\"alt\":{\"item\":null,\"label\":\"alt\"},\"x\":{\"item\":\"op://v/i/f\",\"label\":\"shared\"}}}\n",
        );
        w.t.write(
            "home/.config/claude-accounts/accounts.json",
            "{\"version\":1,\"accounts\":{\"alt\":{\"mode\":\"token\"},\"sub2\":{\"mode\":\"subscription\"},\"token1\":{\"mode\":\"token\"}}}\n",
        );
        for n in ["alt", "token1"] {
            w.t.write(
                &format!("home/.config/claude-accounts/{n}.env"),
                &format!("CLAUDE_CODE_OAUTH_TOKEN={}\n", blob()),
            );
        }
        if let Some(at) = set_at {
            w.t.write(
                "home/.local/state/claude-accounts/tokens.json",
                &format!("{{\"alt\":{{\"set_at\":\"{at}\"}}}}\n"),
            );
        }
        w
    }

    fn audit_at(w: &World, now: &str) -> (i32, String, String) {
        w.run_env(&["audit"], &[("CLAUDE_ACCOUNT_NOW", now)])
    }

    /// 表の行 (`| <名前> |` で始まる行)
    fn row<'a>(out: &'a str, name: &str) -> Option<&'a str> {
        out.lines().find(|l| l.starts_with(&format!("| {name} |")))
    }

    #[test]
    fn audit_lists_and_judges() {
        let now = "2026-11-28T21:00:00+09:00";
        let w = audit_world(Some("2026-11-18T21:00:00+09:00"));
        let (code, out, err) = audit_at(&w, now);
        assert_eq!(code, 1, "{out}\n{err}");
        let head: Vec<&str> = out.lines().take(3).collect();
        assert_eq!(
            head,
            vec![
                "claude-account audit: PC1 (Windows) (2026-11-28 21:00 JST・入れてから 330 日を超えたら回す)",
                "宣言: ~/.local/state/dotfiles/claude-tokens.json (2 件)",
                "控え: ~/.local/state/claude-accounts/tokens.json (1 件)",
            ]
        );
        assert!(out.contains("| アカウント | 呼び名 | 1Password の参照 | 置き方 | 権限 | 入れた時刻 | 日数 | 判定 |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n"), "{out}");
        assert_eq!(
            row(&out, "alt"),
            Some(
                "| alt | alt | - | ローカル (DPAPI) | ACL 本人だけ | 2026-11-18 21:00 | 10 | ok |"
            )
        );
        assert_eq!(
            row(&out, "x"),
            Some("| x | shared | op://v/i/f | 無い | - | - | - | 入れる |")
        );
        assert_eq!(
            row(&out, "token1"),
            Some("| token1 | - | - | ローカル (DPAPI) | ACL 本人だけ | - | - | 宣言漏れ |")
        );
        assert!(row(&out, "sub2").is_none(), "{out}");
        assert!(out.contains("- x: 入れる — 登録が無い (claude-account add x --mode token を打ってから claude-account set-token x)\n"), "{out}");
        assert!(out.contains("- token1: 宣言漏れ — 宣言 ([claude.tokens.token1]) が無い token の置き場 (回す対象から漏れている。宣言に足すか、要らなければ claude-account remove token1 --purge)\n"), "{out}");
        assert!(out.contains("呼び名が同じ行は、ほかのホストの同じ呼び名の行とも同じ token。回すときは、その全部のホストで貼り直す。\n"), "{out}");
        assert!(
            out.ends_with("判定: ok 1・回す 0・入れる 1・直す 0・宣言漏れ 1\n"),
            "{out}"
        );
        assert!(
            !out.contains("0000000000000000") && !err.contains("0000000000000000"),
            "{out}"
        );
        // 330 日を超えたら回す (期限までの残りの日数も)。ちょうど 330 日は ok
        let w = audit_world(Some("2025-12-31T21:00:00+09:00"));
        let (code, out, _) = audit_at(&w, now);
        assert_eq!(code, 1);
        assert_eq!(
            row(&out, "alt"),
            Some(
                "| alt | alt | - | ローカル (DPAPI) | ACL 本人だけ | 2025-12-31 21:00 | 332 | 回す |"
            )
        );
        assert!(
            out.contains(
                "- alt: 回す — 入れてから 332 日 (330 日を超えた。期限の 1 年まで残り 33 日)\n"
            ),
            "{out}"
        );
        let (_, out, _) = audit_at(&w, "2026-11-26T21:00:00+09:00");
        assert_eq!(
            row(&out, "alt"),
            Some(
                "| alt | alt | - | ローカル (DPAPI) | ACL 本人だけ | 2025-12-31 21:00 | 330 | ok |"
            )
        );
        // 控えが無ければ回す (ファイルの時刻と、入れ直せば控えができることを添える)
        let w = audit_world(None);
        let (_, out, _) = audit_at(&w, now);
        assert_eq!(
            row(&out, "alt"),
            Some("| alt | alt | - | ローカル (DPAPI) | ACL 本人だけ | - | - | 回す |")
        );
        assert!(
            out.contains(
                "- alt: 回す — 入れた時刻の控えが無い (set-token で入れていない。ファイルの時刻は "
            ),
            "{out}"
        );
        assert!(
            out.contains("。同じ token を set-token で入れ直せば控えができる)\n"),
            "{out}"
        );
        assert!(
            out.contains("控え: なし (まだ set-token で入れていない)\n"),
            "{out}"
        );
    }

    #[test]
    fn audit_fixes_plain_tokens_and_wide_acls() {
        let now = "2026-11-28T21:00:00+09:00";
        // 平文は直す
        let w = audit_world(Some("2026-11-18T21:00:00+09:00"));
        w.t.write(
            "home/.config/claude-accounts/alt.env",
            "CLAUDE_CODE_OAUTH_TOKEN=dummy-plain-1\n",
        );
        let (_, out, err) = audit_at(&w, now);
        assert_eq!(
            row(&out, "alt"),
            Some(
                "| alt | alt | - | ローカル (平文) | ACL 本人だけ | 2026-11-18 21:00 | 10 | 直す |"
            )
        );
        assert!(out.contains("- alt: 直す — token が平文で置かれている (claude-account set-token alt で入れ直すと DPAPI の暗号文になる)\n"), "{out}");
        assert!(!out.contains("dummy") && !err.contains("dummy"), "{out}");
        // 広い ACL は直す。継いだ形は ok。読めなければ ? で直す
        let w = audit_world(Some("2026-11-18T21:00:00+09:00"));
        let mut wide = acl_inherited();
        wide.push("rule=Allow|1179785|0|S-1-5-32-545|BUILTIN\\Users".to_string());
        w.acl.borrow_mut().insert("alt.env".to_string(), wide);
        w.acl
            .borrow_mut()
            .insert("token1.env".to_string(), acl_inherited());
        let (_, out, _) = audit_at(&w, now);
        assert_eq!(
            row(&out, "alt"),
            Some("| alt | alt | - | ローカル (DPAPI) | ACL 広い | 2026-11-18 21:00 | 10 | 直す |")
        );
        assert!(out.contains("- alt: 直す — token のファイルを本人・SYSTEM・Administrators のほかも読める (BUILTIN\\Users。置き場所のディレクトリ ("), "{out}");
        assert_eq!(
            row(&out, "token1"),
            Some(
                "| token1 | - | - | ローカル (DPAPI) | ACL SYSTEM・Administrators・本人 | - | - | 宣言漏れ |"
            )
        );
        w.acl
            .borrow_mut()
            .insert("alt.env".to_string(), vec!["error: denied".to_string()]);
        let (_, out, _) = audit_at(&w, now);
        assert_eq!(
            row(&out, "alt"),
            Some("| alt | alt | - | ローカル (DPAPI) | ? | 2026-11-18 21:00 | 10 | 直す |")
        );
        assert!(
            out.contains("- alt: 直す — token のファイルの ACL を確かめられない ("),
            "{out}"
        );
    }

    #[test]
    fn audit_other_rows() {
        let now = "2026-11-28T21:00:00+09:00";
        // 宣言した token のファイルが無ければ入れる。宣言の無い default.env は宣言漏れ (素の claude を先に並べる)。同じ呼び名の組
        let w = audit_world(Some("2026-11-18T21:00:00+09:00"));
        w.t.write(
            "home/.local/state/dotfiles/claude-tokens.json",
            "{\"accounts\":{\"alt\":{\"item\":null,\"label\":\"alt\"},\"x\":{\"item\":null,\"label\":\"shared\"},\"y\":{\"item\":null,\"label\":\"shared\"}}}\n",
        );
        std::fs::remove_file(
            w.home()
                .join(".config")
                .join("claude-accounts")
                .join("alt.env"),
        )
        .unwrap();
        w.t.write(
            "home/.config/claude-accounts/default.env",
            &format!("CLAUDE_CODE_OAUTH_TOKEN={}\n", blob()),
        );
        let (_, out, _) = audit_at(&w, now);
        let rows: Vec<&str> = out
            .lines()
            .filter(|l| l.starts_with("| ") && !l.starts_with("| ア") && !l.starts_with("| -"))
            .collect();
        assert_eq!(
            rows[0],
            "| default (素の claude) | - | - | ローカル (DPAPI) | ACL 本人だけ | - | - | 宣言漏れ |",
            "{out}"
        );
        assert_eq!(
            row(&out, "alt"),
            Some("| alt | alt | - | 無い | - | 2026-11-18 21:00 | 10 | 入れる |")
        );
        assert!(out.contains("- alt: 入れる — token が無い (claude setup-token で出し、このホストで claude-account set-token alt で入れる)\n"), "{out}");
        assert!(out.contains("- default: 宣言漏れ — 素の claude (default) の token のファイルがある (Windows の素の claude は token を読まず、/login で使う。要らなければ消す)\n"), "{out}");
        assert!(
            out.contains(
                "同じ token (呼び名 shared) を置いたアカウント: x・y (回すときは、どれも貼り直す)\n"
            ),
            "{out}"
        );
        // 宣言も token も無ければ 0
        let w = World::new();
        let (code, out, _) = audit_at(&w, now);
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("宣言: なし (~/.local/state/dotfiles/claude-tokens.json が無い。dotfiles が古いか、Claude Code を入れないホスト)\n"), "{out}");
        assert!(out.contains("token の置き場はありません (宣言も、token のアカウントも、token のファイルも無い)。\n"), "{out}");
        // 全部 ok なら 0
        let w = audit_world(Some("2026-11-18T21:00:00+09:00"));
        w.t.write(
            "home/.local/state/dotfiles/claude-tokens.json",
            "{\"accounts\":{\"alt\":{\"item\":null,\"label\":\"alt\"},\"token1\":{\"item\":null,\"label\":\"t1\"}}}\n",
        );
        w.t.write(
            "home/.local/state/claude-accounts/tokens.json",
            "{\"alt\":{\"set_at\":\"2026-11-18T21:00:00+09:00\"},\"token1\":{\"set_at\":\"2026-11-20T09:00:00+09:00\"}}\n",
        );
        let (code, out, _) = audit_at(&w, now);
        assert_eq!(code, 0, "{out}");
        assert!(
            out.ends_with("判定: ok 2・回す 0・入れる 0・直す 0・宣言漏れ 0\n"),
            "{out}"
        );
        // 既定のアカウント (personal) を宣言したら直す。打っても通らない remove・add を出さない (Linux と同じ文)
        let w = audit_world(Some("2026-11-18T21:00:00+09:00"));
        w.t.write(
            "home/.local/state/dotfiles/claude-tokens.json",
            "{\"accounts\":{\"personal\":{\"item\":null,\"label\":\"personal\"}}}\n",
        );
        w.t.write(
            "home/.config/claude-accounts/personal.env",
            &format!("CLAUDE_CODE_OAUTH_TOKEN={}\n", blob()),
        );
        let (code, out, _) = audit_at(&w, now);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("- personal: 直す — 既定のアカウント (subscription。dotfiles が作る) で、token を置かない (宣言から外すか、別の名前で claude-account add <名前> --mode token を打って宣言し直す)\n"), "{out}");
        assert!(!out.contains("claude-account remove personal"), "{out}");
    }

    #[test]
    fn audit_stops_on_unreadable_files() {
        const SECRET: &str = "sk-ant-oat01-do-not-print";
        let now = "2026-11-28T21:00:00+09:00";
        let w = audit_world(Some("2026-11-18T21:00:00+09:00"));
        w.t.write(
            "home/.local/state/dotfiles/claude-tokens.json",
            &format!("{{\"accounts\":{{\"{SECRET}\":{{\"item\":null,\"label\":\"x\"}}}}}}\n"),
        );
        let (code, out, err) = audit_at(&w, now);
        assert_eq!((code, out.as_str()), (2, ""), "{err}");
        assert!(err.contains("宣言") && !err.contains(SECRET), "{err}");
        let w = audit_world(Some("2026-11-18T21:00:00+09:00"));
        w.t.write("home/.local/state/claude-accounts/tokens.json", "[1]\n");
        let (code, _, err) = audit_at(&w, now);
        assert_eq!(code, 2);
        assert!(err.contains("入れた時刻の控え"), "{err}");
        let w = audit_world(Some("2026-11-18T21:00:00+09:00"));
        w.t.write("home/.config/claude-accounts/accounts.json", "{}\n");
        assert_eq!(audit_at(&w, now).0, 2);
        let w = audit_world(Some("2026-11-18T21:00:00+09:00"));
        let (code, _, err) = audit_at(&w, "yesterday");
        assert_eq!(code, 2);
        assert!(err.contains("CLAUDE_ACCOUNT_NOW"), "{err}");
        assert_eq!(w.run(&["audit", "x"]).0, 2);
    }
}
