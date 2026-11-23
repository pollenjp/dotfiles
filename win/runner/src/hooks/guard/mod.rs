//! コマンドを読む 3 つの guard (xref-guard・gist-guard・install-iac-guard) の共有の道具。Linux の `nix/files/claude/hooks/<名前>.sh` の bash の関数
//! (expand_home・join_dir・abs_path・remember・expand_value・read_file・remember_write・skip_opts) を写した。読み手 (単純コマンドを見る `simple`) は
//! guard ごとに bash の版と同じ形で持つ (`xref`・`gist`・`iac`)。
//!
//! Windows だけの違い (bash の版に無いもの。Linux の試験は bash の版と同じ答えを確かめ、ここは Windows の CI と単体の試験が確かめる):
//!
//! - パス: Claude Code は cwd を `C:\…` の形で渡し、Git Bash のコマンドは `/c/…`・`C:/…`、PowerShell は `C:\…`・`~\…` で書く。`\` を `/` にし、
//!   `/c/…` を `C:/…` にしてから bash の版と同じに組み立てる。ドライブ (`C:/`) と UNC (`//server`) も絶対パス。ファイルの名前は大文字小文字を
//!   区別しない (同じコマンドで書いたファイルの控え)
//! - コマンドの名前: `git.exe`・`C:\…\gh.exe`・`Git` も同じコマンド (Windows は大文字小文字を区別しない)
//! - PowerShell の tool (`tool_name` が `PowerShell`): PowerShell の書き方の lexer (`pslex`) で単純コマンドに分け、同じ読み手に渡す。PowerShell の
//!   別名 (`Set-Location`・`Invoke-Expression`・`Get-Content` など) は `ps_alias` で bash のコマンドに読み替える
//! - `pwsh -Command`・`powershell -Command`・`cmd /c` の中も読み直す。`wsl` の後ろは WSL の中のコマンドとして読む (dir は分からない。git・gh の
//!   repo を Windows の hook からは引けないので、push と公開範囲は確かめられないものとして扱う)

pub mod gist;
pub mod iac;
pub mod lex;
pub mod pslex;
pub mod refs;
pub mod xref;

use crate::process::{CommandSpec, Sys};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// 中を読むコマンドの長さの上限 (バイト)。bash の版は gawk・mawk があれば 64 KB (無ければ 16 KB。Windows に awk は要らないので 64 KB)
pub const LEX_LIMIT: usize = 65536;

/// WSL の中の dir (Windows の hook からは中を読めない) の印
pub const FOREIGN: &str = "\u{1}wsl";

/// どの書き方で読むか
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lang {
    Bash,
    PowerShell,
}

/// コマンドの文字を単純コマンドに分ける (`net_records` は gist-guard の awk の形)
pub fn split(lang: Lang, src: &str, net_records: bool, world: &World) -> Vec<lex::Cmd> {
    match lang {
        Lang::Bash => lex::split_commands(src, net_records),
        Lang::PowerShell => pslex::split_commands(src, world),
    }
}

/// guard が 1 回の実行で持つもの (bash の版の大域の変数のうち、3 つの guard に共通のもの)
pub struct World<'a> {
    pub sys: &'a dyn Sys,
    /// bash の `${HOME}` (Windows は `USERPROFILE`。`/` の形)
    pub home: String,
    /// Windows のパスの形で読む (`\`・ドライブ・大文字小文字を区別しない)
    pub win: bool,
    /// hook の入力の cwd (無い・dir でなければ今の dir)
    pub cwd: String,
    /// 代入だけの単純コマンドで見た値 (bash の `vars`)
    pub vars: HashMap<String, String>,
    /// 同じコマンドの前の方で書いたファイル (中身が分からなければ None)
    pub written: HashMap<String, Option<String>>,
    /// Windows の Git Bash の `/tmp` の行き先 (`%TEMP%`。`/` の形。Windows の形でなければ空)
    git_bash_tmp: String,
    git: Option<Option<PathBuf>>,
}

impl<'a> World<'a> {
    pub fn new(sys: &'a dyn Sys, cwd: &str) -> Self {
        let win = cfg!(windows);
        Self::with_style(sys, cwd, win)
    }

    /// パスの形を決めて作る (試験で Windows の形を Linux でも確かめるため)
    pub fn with_style(sys: &'a dyn Sys, cwd: &str, win: bool) -> Self {
        let home = super::home(sys)
            .map(|h| h.to_string_lossy().into_owned())
            .unwrap_or_default();
        let mut w = World {
            sys,
            home: String::new(),
            win,
            cwd: String::new(),
            vars: HashMap::new(),
            written: HashMap::new(),
            git_bash_tmp: String::new(),
            git: None,
        };
        w.home = w.norm(&home);
        if win {
            let tmp = sys
                .env("TEMP")
                .filter(|t| !t.is_empty())
                .or_else(|| sys.env("TMP"))
                .unwrap_or_default();
            w.git_bash_tmp = w.norm(&tmp).trim_end_matches('/').to_string();
        }
        let cwd = w.norm(cwd);
        w.cwd = if !cwd.is_empty() && Path::new(&cwd).is_dir() {
            cwd
        } else {
            let here = std::env::current_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            w.norm(&here)
        };
        w
    }

    /// Windows の形なら `\` を `/` にし、Git Bash の `/c/…` を `C:/…` にする (ほかはそのまま)
    pub fn norm(&self, p: &str) -> String {
        if !self.win {
            return p.to_string();
        }
        let p = p.replace('\\', "/");
        let b = p.as_bytes();
        if b.len() >= 2
            && b[0] == b'/'
            && b[1].is_ascii_alphabetic()
            && (b.len() == 2 || b[2] == b'/')
        {
            let rest = if b.len() == 2 { "/" } else { &p[2..] };
            return format!("{}:{}", (b[1] as char).to_ascii_uppercase(), rest);
        }
        p
    }

    /// 絶対パスか (bash は `/` で始まるか。Windows はドライブ (`C:/`) も)
    pub fn is_abs(&self, p: &str) -> bool {
        if p.starts_with('/') {
            return true;
        }
        let b = p.as_bytes();
        self.win && b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':'
    }

    /// bash の expand_home: 頭の `${HOME}`・`$HOME`・`~`・`~/` を置き換える
    pub fn expand_home(&self, d: &str) -> String {
        let mut d = self.norm(d);
        if let Some(rest) = d.strip_prefix("${HOME}") {
            d = format!("{}{rest}", self.home);
        } else if let Some(rest) = d.strip_prefix("$HOME") {
            d = format!("{}{rest}", self.home);
        }
        if d == "~" {
            d = self.home.clone();
        } else if let Some(rest) = d.strip_prefix("~/") {
            d = format!("{}/{rest}", self.home);
        }
        // bash は $(expand_home …) で受ける (末尾の改行が落ちる)
        d.trim_end_matches('\n').to_string()
    }

    /// bash の abs_path: dir から見た path (`/./` と `//` は詰める)。`trim` なら末尾の `/.` と `/` も外す (install-iac-guard の版)
    pub fn abs_path(&self, dir: &str, path: &str, trim: bool) -> String {
        let mut p = self.expand_home(path);
        if !self.is_abs(&p) {
            p = format!("{dir}/{p}");
        }
        // Windows の UNC (//server/share) の頭の // は残す
        let unc = self.win && p.starts_with("//") && !p.starts_with("///");
        let (head, mut body) = if unc {
            ("/", p[1..].to_string())
        } else {
            ("", p)
        };
        while body.contains("/./") || body.contains("//") {
            body = body.replace("/./", "/").replace("//", "/");
        }
        let mut p = format!("{head}{body}").trim_end_matches('\n').to_string();
        if trim {
            if let Some(s) = p.strip_suffix("/.") {
                p = s.to_string();
            }
            if p != "/"
                && let Some(s) = p.strip_suffix('/')
            {
                p = s.to_string();
            }
        }
        p
    }

    /// 控えの鍵 (Windows はファイルの名前の大文字小文字を区別しない)
    fn key(&self, p: &str) -> String {
        if self.win {
            p.to_lowercase()
        } else {
            p.to_string()
        }
    }

    /// bash の join_dir: cd の行き先。分からない (cd -・$( )・変数) なら今の dir。`expand` なら前の代入とファイルの印を入れる (xref・gist の版)
    pub fn join_dir(&mut self, cur: &str, arg: &str, expand: bool) -> String {
        if cur.starts_with(FOREIGN) {
            return cur.to_string();
        }
        let v = if expand {
            self.expand_value(cur, arg)
        } else {
            arg.to_string()
        };
        let d = self.expand_home(&v);
        if d.is_empty() {
            return self.home.clone();
        }
        if d == "-" || d.contains('$') || d.contains('`') || d.contains(lex::MARK_OPEN) {
            return cur.to_string();
        }
        if self.is_abs(&d) {
            d
        } else {
            format!("{cur}/{d}")
        }
    }

    /// bash の remember: `NAME=値` を覚える (後ろの `"$NAME"` に入れる)
    pub fn remember<S: AsRef<str>>(&mut self, assigns: &[S]) {
        for a in assigns {
            let a = a.as_ref();
            if let Some((name, value)) = a.split_once('=')
                && is_name(name)
            {
                self.vars.insert(name.to_string(), value.to_string());
            }
        }
    }

    /// bash の remember_write: 同じコマンドの前の方で書いたファイルを覚える
    pub fn remember_write(&mut self, dir: &str, path: &str, known: bool, content: &str) {
        let p = self.abs_path(dir, path, false);
        let k = self.key(&p);
        self.written.insert(k, known.then(|| content.to_string()));
    }

    /// bash の read_written: 同じコマンドの前の方で書いたファイルなら、書いた中身
    pub fn read_written(&self, dir: &str, path: &str) -> Option<String> {
        let p = self.abs_path(dir, path, false);
        self.written.get(&self.key(&p)).cloned().flatten()
    }

    /// bash の read_file: 同じコマンドの前の方で書いたファイルは書いた中身 (分からなければ None)、ほかはふつうのファイルの頭の 1 MB
    /// (`$(…)` と同じく末尾の改行を外す)
    pub fn read_file(&self, dir: &str, path: &str) -> Option<String> {
        let mut p = self.abs_path(dir, path, false);
        if let Some(v) = self.written.get(&self.key(&p)) {
            return v.clone();
        }
        if p.starts_with(FOREIGN) {
            return None;
        }
        // Windows の Git Bash の /tmp は %TEMP% (ドライブの根の \tmp に無ければ、そちらを読む)
        if !Path::new(&p).is_file()
            && !self.git_bash_tmp.is_empty()
            && (p == "/tmp" || p.starts_with("/tmp/"))
        {
            p = format!("{}{}", self.git_bash_tmp, &p[4..]);
        }
        if !Path::new(&p).is_file() {
            return None;
        }
        let mut buf = Vec::new();
        let f = std::fs::File::open(&p).ok()?;
        use std::io::Read;
        f.take(1_048_576).read_to_end(&mut buf).ok()?;
        let text = String::from_utf8_lossy(&buf).replace('\0', "");
        Some(text.trim_end_matches('\n').to_string())
    }

    /// bash の expand_value: 語の値。ちょうど `$NAME`・`${NAME}` で前に代入を見たなら、その値。`$(cat <file>)` の印はファイルの中身 (読めなければ
    /// `$(cat <file>)` の文字のまま)
    pub fn expand_value(&self, dir: &str, word: &str) -> String {
        let mut v = word.to_string();
        if let Some(name) = var_ref(word)
            && let Some(val) = self.vars.get(name)
        {
            v = val.clone();
        }
        let mut out = String::new();
        while let Some(open) = v.find(lex::MARK_OPEN) {
            let after = &v[open + 1..];
            let Some(close_rel) = after.find(lex::MARK_CLOSE) else {
                break;
            };
            out.push_str(&v[..open]);
            let path = &after[..close_rel];
            match self.read_file(dir, path) {
                Some(t) => out.push_str(&t),
                None => {
                    out.push_str("$(cat ");
                    out.push_str(path);
                    out.push(')');
                }
            }
            v = after[close_rel + 1..].to_string();
        }
        out.push_str(&v);
        out
    }

    /// git を dir で流す (stderr は捨て、stdin は渡さない)。終わりのコードが 0 か と、stdout (`$(…)` と同じく末尾の改行を外す)。git が無い・
    /// WSL の中の dir なら流さずに失敗
    pub fn git(&mut self, dir: &str, gopts: &[String], args: &[&str]) -> (bool, String) {
        if dir.starts_with(FOREIGN) {
            return (false, String::new());
        }
        if self.git.is_none() {
            self.git = Some(self.sys.which("git"));
        }
        let Some(Some(git)) = &self.git else {
            return (false, String::new());
        };
        let mut spec = CommandSpec::new(git.clone())
            .arg("-C")
            .arg(dir)
            .stdout_only();
        for o in gopts {
            spec = spec.arg(o);
        }
        for a in args {
            spec = spec.arg(a);
        }
        let r = self.sys.run(&spec, &mut |_| {});
        let out = r.output.join("\n").trim_end_matches('\n').to_string();
        (r.code() == Some(0), out)
    }

    /// git の出力を行に (bash の `mapfile -t`。空の出力は 0 行)
    pub fn git_lines(&mut self, dir: &str, gopts: &[String], args: &[&str]) -> Vec<String> {
        let (_, out) = self.git(dir, gopts, args);
        if out.is_empty() {
            Vec::new()
        } else {
            out.split('\n').map(str::to_string).collect()
        }
    }
}

/// 変数の名前か (`[A-Za-z_][A-Za-z0-9_]*`)
pub fn is_name(s: &str) -> bool {
    let mut cs = s.chars();
    matches!(cs.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && cs.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// `^\$\{?NAME\}?$` の NAME
fn var_ref(word: &str) -> Option<&str> {
    let rest = word.strip_prefix('$')?;
    let rest = rest.strip_prefix('{').unwrap_or(rest);
    let rest = rest.strip_suffix('}').unwrap_or(rest);
    is_name(rest).then_some(rest)
}

/// bash の skip_opts: w の頭のオプションを外す (`takes` の値を取るものは値も)
pub fn skip_opts(w: &mut Vec<String>, takes: &[&str]) {
    while let Some(first) = w.first() {
        if first == "--" {
            w.remove(0);
            return;
        }
        if first.len() >= 2 && first.starts_with('-') {
            let n = if takes.contains(&first.as_str()) {
                2
            } else {
                1
            };
            w.drain(..n.min(w.len()));
        } else {
            return;
        }
    }
}

/// コマンドの名前 (bash の `${w[0]##*/}`)。Windows の形なら `\` でも区切り、大文字小文字をそろえ、`.exe` を外す
pub fn base_name(word: &str, win: bool) -> String {
    if !win {
        return word.rsplit('/').next().unwrap_or(word).to_string();
    }
    let b = word
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(word)
        .to_lowercase();
    b.strip_suffix(".exe").map(str::to_string).unwrap_or(b)
}

/// PowerShell の別名・cmdlet を、読み手が見る bash のコマンドの名前に読み替える (小文字にそろえた名前で引く)
pub fn ps_alias(name: &str) -> &str {
    match name {
        "set-location" | "sl" | "chdir" | "push-location" => "cd",
        "invoke-expression" | "iex" => "invoke-expression",
        "write-output" | "write" => "echo",
        "get-content" | "gc" | "type" | "cat" => "get-content",
        "tee-object" | "tee" => "tee-object",
        "set-content" | "add-content" | "ac" => "set-content",
        "out-file" => "out-file",
        "invoke-webrequest" | "iwr" | "invoke-restmethod" | "irm" => "invoke-webrequest",
        other => other,
    }
}

/// PowerShell の Set-Content・Add-Content・Out-File が書くファイルと中身 (パス・中身が分かるか・中身)。`-Value` (Set-Content は 2 つ目の位置の
/// 引数も) が無ければ、パイプで受けたもの。Add-Content は bash の `>>` と同じく、書いた中身だけを控える
pub fn ps_write_target(
    name: &str,
    args: &[String],
    in_text: &str,
    in_known: bool,
) -> Option<(String, bool, String)> {
    let (named, pos) = ps_params(args, WRITE_VALUES);
    let path = ps_named(&named, &["path", "filepath", "literalpath"])
        .map(str::to_string)
        .or_else(|| pos.first().cloned())?;
    let value = ps_named(&named, &["value", "inputobject"])
        .map(str::to_string)
        .or_else(|| {
            if name == "set-content" {
                pos.get(1).cloned()
            } else {
                None
            }
        });
    Some(match value {
        Some(v) => (path, true, v),
        None => (path, in_known, in_text.to_string()),
    })
}

/// Get-Content の値を取る引数 (小文字。略した名前は頭の字で引く。ほかの名前は値を取らない switch)
pub const GET_CONTENT_VALUES: &[&str] = &[
    "path",
    "literalpath",
    "encoding",
    "totalcount",
    "tail",
    "head",
    "readcount",
    "delimiter",
    "filter",
    "include",
    "exclude",
    "stream",
    "credential",
];

/// Tee-Object の値を取る引数
pub const TEE_VALUES: &[&str] = &[
    "filepath",
    "literalpath",
    "variable",
    "inputobject",
    "encoding",
];

/// Set-Content・Add-Content・Out-File の値を取る引数
pub const WRITE_VALUES: &[&str] = &[
    "path",
    "filepath",
    "literalpath",
    "value",
    "inputobject",
    "encoding",
    "filter",
    "include",
    "exclude",
    "credential",
    "stream",
    "width",
];

/// PowerShell の cmdlet の引数を、名前つき (`-Name 値`・`-Name:値`) と位置の引数に分ける。`values` は値を取る引数の正式な名前 (小文字・`-` なし)
/// で、略した名前 (`-Meth`) は頭の字が合う最初のものと読む。どれにも合わない名前は値を取らない switch とみなす (`-UseBasicParsing`・`-useb`・
/// `-Verbose` が、後ろの URL を値として取ってしまわないように)。名前つきの引数は正式な名前で返す
pub fn ps_params(args: &[String], values: &[&str]) -> (Vec<(String, String)>, Vec<String>) {
    let canon = |n: &str| -> Option<&str> {
        let l = n.to_lowercase();
        values
            .iter()
            .copied()
            .find(|v| !l.is_empty() && v.starts_with(&l))
    };
    let mut named = Vec::new();
    let mut pos = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a.len() >= 2
            && a.starts_with('-')
            && a[1..].starts_with(|c: char| c.is_ascii_alphabetic())
        {
            let body = &a[1..];
            if let Some((n, v)) = body.split_once(':') {
                let name = canon(n).map_or_else(|| n.to_lowercase(), str::to_string);
                named.push((name, v.to_string()));
            } else if let Some(name) = canon(body) {
                named.push((
                    name.to_string(),
                    args.get(i + 1).cloned().unwrap_or_default(),
                ));
                i += 1;
            } else {
                named.push((body.to_lowercase(), String::new()));
            }
        } else {
            pos.push(a.clone());
        }
        i += 1;
    }
    (named, pos)
}

/// 名前つきの引数の値 (`names` は正式な名前。ps_params が正式な名前で返す)
pub fn ps_named<'b>(named: &'b [(String, String)], names: &[&str]) -> Option<&'b str> {
    named
        .iter()
        .find(|(n, _)| names.contains(&n.as_str()))
        .map(|(_, v)| v.as_str())
}

/// hook の deny の答え (jq -cn の 1 行)
pub fn deny(reason: &str) -> String {
    super::answer(
        "PreToolUse",
        &[
            ("permissionDecision", "deny"),
            ("permissionDecisionReason", reason),
        ],
    )
}

/// `pwsh`・`powershell` の引数から `-Command` の文字列 (後ろの語をつないだもの)。無ければ None。オプションの名前は PowerShell と同じく、頭の字で
/// 略してよい (`-Exec Bypass`・`-win hidden`・`-c`)
pub fn pwsh_command(args: &[String]) -> Option<String> {
    // 値を取るオプション (正式な名前と、決まった別名)
    const VALUES: &[&str] = &[
        "executionpolicy",
        "workingdirectory",
        "windowstyle",
        "outputformat",
        "inputformat",
        "configurationname",
        "configurationfile",
        "settingsfile",
        "psconsolefile",
        "version",
        "custompipename",
    ];
    const VALUE_ALIASES: &[&str] = &["ex", "ep", "wd", "w", "of", "o", "if", "v"];
    let mut i = 0;
    while i < args.len() {
        let a = args[i].to_lowercase();
        if !a.starts_with('-') && !a.starts_with('/') {
            // -Command を略して書いた (pwsh 'git push')。-File のファイルは読まない
            return Some(args[i..].join(" "));
        }
        let name = a.trim_start_matches(['-', '/']);
        if name == "c"
            || (name.len() >= 3 && "command".starts_with(name))
            || name == "cwa"
            || "commandwithargs" == name
        {
            return Some(args[i + 1..].join(" "));
        }
        if name == "f"
            || name == "e"
            || name == "ec"
            || (name.len() >= 2 && ("file".starts_with(name) || "encodedcommand".starts_with(name)))
        {
            return None;
        }
        if VALUE_ALIASES.contains(&name)
            || (name.len() >= 2 && VALUES.iter().any(|v| v.starts_with(name)))
        {
            i += 1;
        }
        i += 1;
    }
    None
}

/// `cmd /c …`・`cmd /k …` の後ろの文字 (Git Bash の `cmd //c` も)。無ければ None。読み直すときは、`\` を字のまま残す PowerShell の lexer で
/// 近似する (cmd の `"…"` と `&`・`&&`・`|` は同じに分かれる)
pub fn cmd_command(args: &[String]) -> Option<String> {
    let i = args.iter().position(|a| {
        let l = a.to_lowercase();
        l == "/c" || l == "/k" || l == "//c" || l == "//k"
    })?;
    Some(args[i + 1..].join(" "))
}

/// `wsl` の引数のうち、WSL の中で流すコマンドの語 (`-d`・`-u`・`--cd` などのオプションを外す)。コマンドが無ければ空
pub fn wsl_command(args: &[String]) -> Vec<String> {
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--" | "-e" | "--exec" => return args[i + 1..].to_vec(),
            "-d" | "--distribution" | "-u" | "--user" | "--cd" | "--distribution-id" => i += 2,
            _ if a.starts_with('-') => i += 1,
            _ => return args[i..].to_vec(),
        }
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - bash の expand_home・abs_path・join_dir・expand_value・skip_opts と同じに組み立てる
    //! - Windows の形: `\` と `/c/…` を `/` の形にそろえ、ドライブを絶対パスと読み、UNC の頭を残し、控えの鍵の大文字小文字を区別しない
    //! - コマンドの名前・PowerShell の別名と引数・pwsh・cmd・wsl の中のコマンドの取り出し

    use super::*;
    use crate::testutil::FakeSys;

    fn sys_with_home(home: &str) -> FakeSys {
        let name = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
        FakeSys::new(|_| unreachable!()).with_env(name, home)
    }

    #[test]
    fn paths_like_bash() {
        let sys = sys_with_home("/home/u");
        let mut w = World::with_style(&sys, "/nonexistent-cwd", false);
        w.home = "/home/u".to_string();
        assert_eq!(w.expand_home("~/x"), "/home/u/x");
        assert_eq!(w.expand_home("${HOME}/y"), "/home/u/y");
        assert_eq!(w.abs_path("/r", "./a//b/./c", false), "/r/a/b/c");
        assert_eq!(w.abs_path("/r", "box/", true), "/r/box");
        assert_eq!(w.abs_path("/r", ".", true), "/r");
        assert_eq!(w.join_dir("/r", "sub", true), "/r/sub");
        assert_eq!(w.join_dir("/r", "$X", true), "/r");
        assert_eq!(w.join_dir("/r", "", true), "/home/u");
        w.remember(&["X=/opt"]);
        assert_eq!(w.join_dir("/r", "$X", true), "/opt");
        assert_eq!(w.join_dir("/r", "${X}", false), "/r");
        assert_eq!(w.expand_value("/r", "a\u{2}nope\u{3}b"), "a$(cat nope)b");
    }

    #[test]
    fn windows_paths() {
        let sys = sys_with_home("C:\\Users\\u");
        let mut w = World::with_style(&sys, "C:\\nope", true);
        w.home = "C:/Users/u".to_string();
        assert_eq!(w.norm("C:\\Users\\u\\x"), "C:/Users/u/x");
        assert_eq!(w.norm("/c/Users/u"), "C:/Users/u");
        assert_eq!(w.norm("/tmp/x"), "/tmp/x");
        assert_eq!(w.expand_home("~\\repo"), "C:/Users/u/repo");
        assert!(w.is_abs("D:/x"));
        assert_eq!(w.abs_path("C:/r", "..\\b\\.\\c", false), "C:/r/../b/c");
        assert_eq!(
            w.abs_path("C:/r", "\\\\srv\\share\\f", false),
            "//srv/share/f"
        );
        assert_eq!(w.join_dir("C:/r", "D:\\work", true), "D:/work");
        w.remember_write("C:/R", "Body.md", true, "x");
        assert_eq!(w.read_written("c:/r", "body.MD").as_deref(), Some("x"));
        assert_eq!(w.join_dir(FOREIGN, "/home/u", true), FOREIGN);
    }

    /// Git Bash の /tmp は %TEMP% (ドライブの根の \tmp に無ければ、そちらを読む)
    #[test]
    fn git_bash_tmp_is_temp() {
        let t = crate::testutil::TempDir::new("guard-tmp");
        let name = format!("dotfiles-win-guard-{}.md", std::process::id());
        t.write(&name, "NixOS/nixpkgs#1\n");
        let sys = FakeSys::new(|_| unreachable!()).with_env("TEMP", &t.path().to_string_lossy());
        let w = World::with_style(&sys, ".", true);
        assert_eq!(
            w.read_file("C:/r", &format!("/tmp/{name}")).as_deref(),
            Some("NixOS/nixpkgs#1")
        );
        let linux = World::with_style(&sys, ".", false);
        assert_eq!(linux.read_file("/r", &format!("/tmp/{name}")), None);
    }

    #[test]
    fn options_and_names() {
        let mut v: Vec<String> = ["-u", "root", "-E", "pip", "x"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        skip_opts(&mut v, &["-u"]);
        assert_eq!(v, vec!["pip", "x"]);
        assert_eq!(base_name("/usr/bin/git", false), "git");
        assert_eq!(
            base_name("C:\\Program Files\\Git\\cmd\\Git.EXE", true),
            "git"
        );
        assert_eq!(base_name("git.exe", false), "git.exe");
        assert_eq!(ps_alias("set-location"), "cd");
        let s = |l: &[&str]| -> Vec<String> { l.iter().map(|x| x.to_string()).collect() };
        // 値を取る引数は略した名前でも引き、知らない名前 (-UseBasicParsing・-useb・-Verbose) は後ろの語を取らない switch
        let args = s(&[
            "-useb",
            "https://x",
            "-Meth:Post",
            "-UseBasicParsing",
            "-Verbose",
            "-Head",
            "@{…}",
            "a",
        ]);
        let (named, pos) = ps_params(&args, &["uri", "method", "headers"]);
        assert_eq!(ps_named(&named, &["method"]), Some("Post"));
        assert_eq!(ps_named(&named, &["headers"]), Some("@{…}"));
        assert_eq!(ps_named(&named, &["uri"]), None);
        assert_eq!(pos, vec!["https://x", "a"]);
        for (args, want) in [
            (
                &[
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-c",
                    "git",
                    "push",
                ][..],
                Some("git push"),
            ),
            (
                &["-nop", "-Exec", "Bypass", "-Command", "git push"][..],
                Some("git push"),
            ),
            (
                &[
                    "-win",
                    "hidden",
                    "-o",
                    "Text",
                    "-WorkingDir",
                    ".",
                    "-com",
                    "x",
                ][..],
                Some("x"),
            ),
            (&["-NoLogo", "git push"][..], Some("git push")),
            (&["-File", "x.ps1"][..], None),
            (&["-ec", "ZwBpAHQA"][..], None),
        ] {
            assert_eq!(pwsh_command(&s(args)).as_deref(), want, "{args:?}");
        }
        assert_eq!(
            cmd_command(&s(&["/c", "git", "push"])).as_deref(),
            Some("git push")
        );
        assert_eq!(
            wsl_command(&s(&["-d", "example-wsl", "--", "git", "push"])),
            s(&["git", "push"])
        );
        assert_eq!(wsl_command(&s(&["git", "push"])), s(&["git", "push"]));
    }
}
