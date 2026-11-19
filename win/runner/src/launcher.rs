//! `claude-<名前>.exe` の launcher (claude-accounts の手順が `%LOCALAPPDATA%\dotfiles\bin\` に置く、この runner の exe の写し)。
//!
//! Linux の `nix/home/modules/claude.nix` の `claude-<名前>` に当たる (dotfiles-private の docs/adr/081_win_claude_accounts_*)。exe の名前
//! (`claude-<名前>`) からアカウントを決め、`%USERPROFILE%\.claude-<名前>\settings.json` が `~/.claude/settings.json` への symlink になって
//! いる (claude-accounts の手順が用意した) ことを確かめてから、`/login` の資格情報より優先される env を外し、`CLAUDE_CONFIG_DIR` を付けて
//! PATH の `claude.exe` を子 process で起こし、その終了コードで終わる (Windows に exec は無い)。用意を確かめるのは、Claude Code が空の
//! `CLAUDE_CONFIG_DIR` に起動しただけで `projects/` などを実体で作り、runner がリンクを張れなくなるため。
//!
//! `.cmd`・`.ps1` にしないのは、Git Bash と `hc run` (shell を通さない) が拡張子の無い名前で `.cmd` を探さず、`.cmd` は Ctrl+C で
//! 「バッチ ジョブを終了しますか」を出すため。

use crate::link::{link_target, same_path};
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

/// PATH で探す Claude Code の exe (Windows は winget の claude.exe。ほかの OS の名前は試験のため)
pub const CLAUDE_EXE: &str = if cfg!(windows) {
    "claude.exe"
} else {
    "claude"
};

/// 子に渡さない env (`/login` の資格情報より優先されるもの。Linux の claude-<名前> と同じ)
pub const REMOVED_ENV: [&str; 3] = [
    "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_AUTH_TOKEN",
];

/// アカウントの名前の形 (`[a-z0-9][a-z0-9_-]*`。Linux の claude.nix と bootstrap-claude-accounts.sh と同じ)。dir の名前 (`~/.claude-<名前>`)
/// とコマンドの名前に使うので、パスを壊す字を入れない。
pub fn account_name_ok(name: &str) -> bool {
    let mut chars = name.chars();
    let lead_ok = chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    lead_ok && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// exe の名前 (拡張子を除いて小文字にしたもの) が `claude-` で始まれば、その残り (アカウントの名前。形は `prepare` が確かめる)。
pub fn account_from_exe(exe: &Path) -> Option<String> {
    let stem = exe.file_stem()?.to_string_lossy().to_ascii_lowercase();
    stem.strip_prefix("claude-").map(str::to_string)
}

/// 起こすもの。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Launch {
    /// PATH で見つけた claude.exe
    pub program: PathBuf,
    /// CLAUDE_CONFIG_DIR に渡す薄い dir (`%USERPROFILE%\.claude-<名前>`)
    pub config_dir: PathBuf,
}

/// 起こしてよいかを確かめ、起こすものを返す。断るときは (終了コード, stderr に出す文)。`env` は環境変数、`path` は PATH の値。
pub fn prepare(
    name: &str,
    env: &dyn Fn(&str) -> Option<String>,
    path: Option<&OsStr>,
) -> Result<Launch, (i32, String)> {
    let cmd = format!("claude-{name}");
    if !account_name_ok(name) {
        return Err((
            2,
            format!(
                "{cmd}: アカウントの名前に使えない字があります (英小文字・数字で始まり、英小文字・数字・- と _ だけ)"
            ),
        ));
    }
    // runner の置き先の根 (manifest::Roots) と同じく USERPROFILE を家にする
    let Some(home) = env("USERPROFILE")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
    else {
        return Err((
            1,
            format!("{cmd}: 環境変数 USERPROFILE がありません (~/.claude-{name} を決められない)"),
        ));
    };
    let dir = home.join(format!(".claude-{name}"));
    let settings = dir.join("settings.json");
    match link_target(&settings) {
        Some(t) if same_path(&t, &home.join(".claude").join("settings.json")) => {}
        Some(t) => {
            return Err((
                1,
                format!(
                    "{cmd}: {} が別の先 ({}) を指しています。dotfiles apply で ~/.claude/settings.json へ張り直してください (UAC の確認が 1 回出ます)。",
                    settings.display(),
                    t.display()
                ),
            ));
        }
        None if settings.symlink_metadata().is_ok() => {
            return Err((
                1,
                format!(
                    "{cmd}: {} が ~/.claude/settings.json へのリンクではありません (この dir で先に Claude Code を起動した、など)。win/README.md の「既に ~/.claude-<名前> があるとき」の手順で片付けてから、dotfiles apply を打ってください。",
                    settings.display()
                ),
            ));
        }
        None => {
            return Err((
                1,
                format!(
                    "{cmd}: {} がまだ用意されていません。dotfiles apply を打ってください (初回は UAC の確認が 1 回出ます)。",
                    dir.display()
                ),
            ));
        }
    }
    // 空の要素・相対パスの要素は今の dir を探すことになるので見ない
    let program = path.and_then(|p| {
        std::env::split_paths(p)
            .filter(|d| d.is_absolute())
            .map(|d| d.join(CLAUDE_EXE))
            .find(|c| c.is_file())
    });
    let Some(program) = program else {
        return Err((
            127,
            format!(
                "{cmd}: {CLAUDE_EXE} が PATH に見つかりません (Windows の Claude Code は Install-ClaudeCode で入れる)。"
            ),
        ));
    };
    Ok(Launch {
        program,
        config_dir: dir,
    })
}

/// 起こして待ち、子の終了コードを返す。標準入出力は引き継ぐ。Windows では、子を起こす前に Ctrl+C・Ctrl+Break を受け流す handler を登録する
/// (console の Ctrl+C は launcher にも届くので、launcher だけが落ちないように)。
pub fn run(name: &str, launch: &Launch, args: &[OsString]) -> i32 {
    #[cfg(windows)]
    let _ = console_ctrl::pass_to_children();
    let mut cmd = std::process::Command::new(&launch.program);
    cmd.args(args);
    for key in REMOVED_ENV {
        cmd.env_remove(key);
    }
    cmd.env("CLAUDE_CONFIG_DIR", &launch.config_dir);
    match cmd.status() {
        Ok(s) => s.code().unwrap_or(1),
        Err(e) => {
            eprintln!(
                "claude-{name}: {} を起こせません ({e})",
                launch.program.display()
            );
            1
        }
    }
}

/// この exe の名前が `claude-<名前>` なら launcher として動き、終了コードを返す。そうでなければ None (runner として動く)。
pub fn main_if_launcher() -> Option<i32> {
    let exe = std::env::current_exe().ok()?;
    let name = account_from_exe(&exe)?;
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let env = |key: &str| std::env::var(key).ok();
    let path = std::env::var_os("PATH");
    Some(match prepare(&name, &env, path.as_deref()) {
        Ok(launch) => run(&name, &launch, &args),
        Err((code, msg)) => {
            eprintln!("{msg}");
            code
        }
    })
}

/// Ctrl+C・Ctrl+Break を launcher の中では受け流す (子の Claude Code が受けて扱う)。handler を登録する外のコマンドは無いので、kernel32 の
/// `SetConsoleCtrlHandler` を FFI で呼ぶ。runner の crate で unsafe を書くのはこの module だけ (Cargo.toml の `unsafe_code = "deny"` の
/// 例外。dotfiles-private の docs/adr/081_win_claude_accounts_*)。
///
/// `SetConsoleCtrlHandler(NULL, TRUE)` の形は「Ctrl+C を無視する」印を子 process に引き継がせ、Claude Code が Ctrl+C を受けなくなるので使わない。
/// TRUE を返す handler の登録は子に引き継がれない (rustup の proxy の cargo.exe なども同じ形で、子に Ctrl+C を任せる)。閉じる・ログオフ・
/// シャットダウンは FALSE を返して既定の扱い (終わる) に任せる。
#[cfg(windows)]
#[allow(unsafe_code)]
mod console_ctrl {
    const CTRL_C_EVENT: u32 = 0;
    const CTRL_BREAK_EVENT: u32 = 1;

    // BOOL WINAPI SetConsoleCtrlHandler(PHANDLER_ROUTINE HandlerRoutine, BOOL Add)
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn SetConsoleCtrlHandler(handler: Option<extern "system" fn(u32) -> i32>, add: i32) -> i32;
    }

    /// HandlerRoutine (BOOL WINAPI HandlerRoutine(DWORD dwCtrlType))。受け流すときは TRUE (1)
    extern "system" fn handler(ctrl_type: u32) -> i32 {
        i32::from(matches!(ctrl_type, CTRL_C_EVENT | CTRL_BREAK_EVENT))
    }

    /// handler を登録する。登録できたら true
    pub fn pass_to_children() -> bool {
        // SAFETY: handler は 'static な extern "system" の関数で、形は HandlerRoutine と同じ (DWORD を受けて BOOL を返し、panic しない)。
        // 登録は process が終わるまで外さない
        unsafe { SetConsoleCtrlHandler(Some(handler), 1) != 0 }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - アカウントの名前の形 (英小文字・数字で始まり、英小文字・数字・- と _ だけ)
    //! - exe の名前 (拡張子を除き小文字にした名前が `claude-` で始まる) からアカウントの名前を取る。runner (`dotfiles-win`)・hook の口
    //!   (`dotfiles-claude`)・素の `claude` は launcher でない
    //! - 断り方: 名前が規則に合わない → 2・USERPROFILE が無い → 1・settings.json が無い (まだ用意されていない) → 1・実体 → 1 (片付け方)・
    //!   別の先へのリンク → 1 (dotfiles apply で張り直す)・PATH に claude が無い → 127。通るときは PATH の最初の claude と薄い dir

    use super::*;
    use crate::testutil::{TempDir, fake_file_symlink};

    #[test]
    fn account_names() {
        for ok in ["personal", "work", "a-b_c", "0x"] {
            assert!(account_name_ok(ok), "{ok}");
        }
        for ng in ["", "Work", "-a", "_a", "a.b", "a b", "a/b", "a\\b", "ａ"] {
            assert!(!account_name_ok(ng), "{ng}");
        }
    }

    #[test]
    fn account_from_exe_reads_the_file_name() {
        let got = |p: &str| account_from_exe(Path::new(p));
        assert_eq!(got("claude-work.exe").as_deref(), Some("work"));
        assert_eq!(
            got("/opt/bin/Claude-Personal.EXE").as_deref(),
            Some("personal")
        );
        assert_eq!(got("claude-work").as_deref(), Some("work"));
        assert_eq!(got("claude-Work!.exe").as_deref(), Some("work!"));
        for none in [
            "dotfiles-win.exe",
            "dotfiles-claude.exe",
            "claude.exe",
            "claude",
            "xclaude-work.exe",
        ] {
            assert_eq!(got(none), None, "{none}");
        }
    }

    /// 家 (USERPROFILE) と、claude を置いた PATH の dir を持つ環境
    struct Home {
        t: TempDir,
    }

    impl Home {
        fn new() -> Self {
            let t = TempDir::new("launcher");
            t.write("home/.claude/settings.json", "{}\n");
            t.write(&format!("bin/{CLAUDE_EXE}"), "fake claude");
            Home { t }
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        fn env(&self) -> impl Fn(&str) -> Option<String> + '_ {
            move |n| (n == "USERPROFILE").then(|| self.home().to_string_lossy().into_owned())
        }

        fn path_var(&self) -> OsString {
            std::env::join_paths([self.t.path().join("empty"), self.t.path().join("bin")]).unwrap()
        }

        /// ~/.claude-<name>/settings.json を ~/.claude/settings.json へのリンクにする (張れなければ false)
        fn prepare_link(&self, name: &str, target: &Path) -> bool {
            std::fs::create_dir_all(self.home().join(format!(".claude-{name}"))).unwrap();
            let link = self
                .home()
                .join(format!(".claude-{name}"))
                .join("settings.json");
            let ok = fake_file_symlink(&link.to_string_lossy(), &target.to_string_lossy()).exit
                == crate::process::Exit::Code(0);
            if !ok {
                eprintln!("ファイルの symlink を張る権限が無いので飛ばす");
            }
            ok
        }
    }

    #[test]
    fn prepare_refuses_until_ready() {
        let h = Home::new();
        let path = h.path_var();
        let (code, msg) = prepare("Work", &h.env(), Some(&path)).unwrap_err();
        assert_eq!(code, 2, "{msg}");
        assert!(msg.contains("使えない字"), "{msg}");
        let (code, msg) = prepare("work", &|_| None, Some(&path)).unwrap_err();
        assert_eq!(code, 1);
        assert!(msg.contains("USERPROFILE"), "{msg}");
        let (code, msg) = prepare("work", &h.env(), Some(&path)).unwrap_err();
        assert_eq!(code, 1);
        assert!(msg.starts_with("claude-work: "), "{msg}");
        assert!(msg.contains("まだ用意されていません"), "{msg}");
        assert!(msg.contains("dotfiles apply"), "{msg}");
        assert!(msg.contains("UAC"), "{msg}");
        // Claude Code が作った実体
        h.t.write("home/.claude-work/settings.json", "{}\n");
        let (code, msg) = prepare("work", &h.env(), Some(&path)).unwrap_err();
        assert_eq!(code, 1);
        assert!(msg.contains("リンクではありません"), "{msg}");
        assert!(msg.contains("既に ~/.claude-<名前> があるとき"), "{msg}");
    }

    #[test]
    fn prepare_finds_claude_on_path() {
        let h = Home::new();
        if !h.prepare_link("work", &h.home().join(".claude").join("settings.json")) {
            return;
        }
        let path = h.path_var();
        let l = prepare("work", &h.env(), Some(&path)).unwrap();
        assert_eq!(
            l,
            Launch {
                program: h.t.path().join("bin").join(CLAUDE_EXE),
                config_dir: h.home().join(".claude-work"),
            }
        );
        let empty = std::env::join_paths([h.t.path().join("empty")]).unwrap();
        let (code, msg) = prepare("work", &h.env(), Some(&empty)).unwrap_err();
        assert_eq!(code, 127, "{msg}");
        assert!(msg.contains("PATH に見つかりません"), "{msg}");
        let (code, _) = prepare("work", &h.env(), None).unwrap_err();
        assert_eq!(code, 127);
    }

    #[test]
    fn prepare_refuses_a_link_to_elsewhere() {
        let h = Home::new();
        let other = h.t.write("home/other.json", "{}\n");
        if !h.prepare_link("personal", &other) {
            return;
        }
        let path = h.path_var();
        let (code, msg) = prepare("personal", &h.env(), Some(&path)).unwrap_err();
        assert_eq!(code, 1);
        assert!(msg.contains("別の先"), "{msg}");
        assert!(msg.contains("dotfiles apply"), "{msg}");
    }
}
