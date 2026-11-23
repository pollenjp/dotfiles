//! 手順に渡す文脈 (置き場所・ホストの値・外のコマンドの口・出力)。
//!
//! 手順は置き場所をここから引き、外のコマンドは `sys` で打ち、出力は `say` (見出しは `heading`) で出す。W0-2 などで手順を足すときも同じ。
//! 色は出すときに付ける (`color`。出力が端末で NO_COLOR が無いときだけ)。

use crate::color::Paint;
use crate::host::HostValues;
use crate::manifest::Roots;
use crate::process::{Stream, Sys};
use std::borrow::Cow;
use std::io::Write;
use std::path::{Path, PathBuf};

pub struct Ctx<'a> {
    /// dotfiles の clone の root
    pub repo: PathBuf,
    /// Windows の置き先の根 (`%USERPROFILE%`・`%APPDATA%`・`%LOCALAPPDATA%`)
    pub roots: Roots,
    /// 配った記録の置き場 (`%LOCALAPPDATA%\dotfiles\state`)
    pub state_dir: PathBuf,
    pub host: HostValues,
    pub sys: &'a dyn Sys,
    pub out: &'a mut dyn Write,
}

impl Ctx<'_> {
    /// 1 行出す (書けなくても止めない)。`!! ` で始まる行 (手順の途中で知らせる警告や誤り。setup.sh の `warn` と同じ印) は、出力が端末なら
    /// 黄にする (包むのはその 1 行だけで、続きの行は包まない)。
    pub fn say(&mut self, line: impl AsRef<str>) {
        let line = line.as_ref();
        let shown = if line.starts_with("!! ") {
            Cow::Owned(self.paint().yellow(line))
        } else {
            Cow::Borrowed(line)
        };
        let _ = writeln!(self.out, "{shown}");
    }

    /// 見出し (`==> …`・`━━ [n] id: 題 ━━`) を出す。出力が端末なら太字 (setup.sh の見出しと同じ)。
    pub fn heading(&mut self, line: impl AsRef<str>) {
        let shown = self.paint().bold(line.as_ref());
        let _ = writeln!(self.out, "{shown}");
    }

    /// 出力 (`out`。cli は stdout を渡す) の色。端末で NO_COLOR が無いときだけ付ける (`color`)。
    pub fn paint(&self) -> Paint {
        Paint::detect(self.sys, Stream::Stdout)
    }

    /// dotfiles の clone の中のパス (`rel` は `/` 区切り)。
    pub fn repo_path(&self, rel: &str) -> PathBuf {
        join_segments(&self.repo, rel)
    }

    /// dotfiles の clone の隣の clone (`dotfiles-private`・`claude-skills`)。隣に無ければ bootstrap の置き場 (`clone_dir`)。
    pub fn sibling(&self, name: &str) -> PathBuf {
        clone_dir(&self.repo, Some(&self.roots.user_profile), name)
    }

    /// SSH の会話の中か (sshd が SSH_CONNECTION・SSH_CLIENT を渡す。win/openssh/Install-Sshd.ps1 と同じ見方)。Win32-OpenSSH の会話は
    /// セッション 0 で、デスクトップの会話の窓・プロセス・名前付きイベントが見えない (powertoys・international が書くのを止める)
    pub fn in_ssh(&self) -> bool {
        ["SSH_CONNECTION", "SSH_CLIENT"]
            .iter()
            .any(|k| self.sys.env(k).is_some_and(|v| !v.is_empty()))
    }
}

/// bootstrap が 3 つの repo を clone する ghq の owner のディレクトリ (`%USERPROFILE%\ghq\github.com\pollenjp`)。
pub fn ghq_owner_dir(user_profile: &Path) -> PathBuf {
    join_segments(user_profile, "ghq/github.com/pollenjp")
}

/// 隣の clone の置き場: dotfiles の clone の隣にあればそれ、無ければ bootstrap の置き場 (`%USERPROFILE%\ghq\github.com\pollenjp\<name>`)、
/// どちらにも無ければ隣 (無いと知らせる場所)。runner を一時の場所の clone から流しても、ホストの値と隣の clone を見つけるため。
pub fn clone_dir(repo: &Path, user_profile: Option<&Path>, name: &str) -> PathBuf {
    let sibling = repo.parent().unwrap_or(repo).join(name);
    if sibling.is_dir() {
        return sibling;
    }
    if let Some(up) = user_profile {
        let ghq = ghq_owner_dir(up).join(name);
        if ghq.is_dir() {
            return ghq;
        }
    }
    sibling
}

/// `base` に `/` 区切りの `rel` を要素ごとに足す (`Path::join` に `C:/…` を渡すと前を捨てるので、要素ごとに push する)。
pub fn join_segments(base: &Path, rel: &str) -> PathBuf {
    let mut p = base.to_path_buf();
    for seg in rel.split('/').filter(|s| !s.is_empty()) {
        p.push(seg);
    }
    p
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 隣の clone は、dotfiles の clone の隣 → bootstrap の置き場 (%USERPROFILE%\ghq\github.com\pollenjp) の順に探し、どちらにも無ければ隣
    //! - 出力が端末で NO_COLOR が無ければ、見出しは太字・`!!` で始まる行は黄にする。ほかの行と、端末でないときは字のまま

    use super::*;
    use crate::host::Groups;
    use crate::testutil::{FakeSys, TempDir};

    /// `f` で出した字
    fn said(sys: &FakeSys, f: impl FnOnce(&mut Ctx)) -> String {
        let mut out = Vec::new();
        {
            let mut ctx = Ctx {
                repo: "/r".into(),
                roots: Roots::from_home(Path::new("/h")),
                state_dir: "/s".into(),
                host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                sys,
                out: &mut out,
            };
            f(&mut ctx);
        }
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn headings_and_warnings_are_colored_on_a_terminal() {
        let lines = |ctx: &mut Ctx| {
            ctx.heading("━━ [90] files: x ━━");
            ctx.say("!! 書けません: a");
            ctx.say("途中の !! は印にしない");
            ctx.say("");
        };
        let sys = || FakeSys::new(|_| unreachable!());
        assert_eq!(
            said(&sys().with_terminal(Stream::Stdout), lines),
            "\u{1b}[1m━━ [90] files: x ━━\u{1b}[0m\n\u{1b}[33m!! 書けません: a\u{1b}[0m\n途中の !! は印にしない\n\n"
        );
        let plain = "━━ [90] files: x ━━\n!! 書けません: a\n途中の !! は印にしない\n\n";
        assert_eq!(said(&sys(), lines), plain);
        let no_color = sys()
            .with_terminal(Stream::Stdout)
            .with_env("NO_COLOR", "1");
        assert_eq!(said(&no_color, lines), plain);
        // 端末なのが stderr だけなら、stdout の行には付けない
        assert_eq!(said(&sys().with_terminal(Stream::Stderr), lines), plain);
    }

    #[test]
    fn clone_dir_prefers_sibling_then_bootstrap_place() {
        let t = TempDir::new("clone-dir");
        let repo = join_segments(t.path(), "tmp/dotfiles");
        let home = t.path().join("home");
        std::fs::create_dir_all(&repo).unwrap();
        let sibling = join_segments(t.path(), "tmp/dotfiles-private");
        let ghq = join_segments(&home, "ghq/github.com/pollenjp/dotfiles-private");
        // どちらにも無い: 隣
        assert_eq!(clone_dir(&repo, Some(&home), "dotfiles-private"), sibling);
        // bootstrap の置き場にだけある
        std::fs::create_dir_all(&ghq).unwrap();
        assert_eq!(clone_dir(&repo, Some(&home), "dotfiles-private"), ghq);
        assert_eq!(clone_dir(&repo, None, "dotfiles-private"), sibling);
        // 隣にもある: 隣
        std::fs::create_dir_all(&sibling).unwrap();
        assert_eq!(clone_dir(&repo, Some(&home), "dotfiles-private"), sibling);
    }
}
