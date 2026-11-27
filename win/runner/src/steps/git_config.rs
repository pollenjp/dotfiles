//! git-config (order 50): git の設定を Windows の `%USERPROFILE%\.config\git\` に置く。Linux の `nix/home/modules/git.nix` (home-manager の
//! `programs.git`) に当たる。どの OS でも同じにする値 (名前とメール・alias・core など・ignore) は、git.nix と同じ
//! `nix/home/modules/git.toml` を clone から読む (値の正本は 1 か所。dotfiles-private の docs/adr/066_win_git_config_*)。
//!
//! | 置くもの | 中身 |
//! | --- | --- |
//! | `config` | git.toml の `[settings]`・(道具 `gitIdentity` が true なら) `[user]`・`[filter "lfs"]` (PATH の git-lfs)・`core.sshCommand` (Windows の OpenSSH の ssh.exe。下) を home-manager と同じ形 (`lib.generators.toGitINI`) で並べ、`gitIdentity` なら後ろに owner ごとの `[includeIf "gitdir/i:~/ghq/github.com/<owner>/"]` |
//! | `config.<owner>` | owner ごとの `[user]` (`gitIdentity` のときだけ。上の includeIf が読む) |
//! | `ignore` | git.toml の `ignores` (1 行 1 つ) |
//!
//! WSL から写さないもの: 1Password の署名 (`commit.gpgSign`・`tag.gpgSign`・`[gpg]`)・delta (`pager.<diff・log・show・blame>`・
//! `interactive.diffFilter`・`[delta]`)・direnv の module が足す `.direnv/`。credential helper はどこにも書かない (bootstrap が gh に書かせない
//! 決まりと、claude-env が settings.json の env に足す組を壊さない)。includeIf の条件は Windows の ghq の root (bootstrap の置き場
//! `%USERPROFILE%\ghq`) の下で、末尾の `/` でその下の repo に当て、`/i` で大文字小文字を区別しない (WSL の条件は旧い `~/workdir` のまま)。
//!
//! `core.sshCommand` は Windows だけの値 (git.toml には書かない。書けば止まる)。無いと git は Git for Windows 付属の MSYS の ssh を使い、MSYS の ssh は
//! Windows の named pipe の agent (1Password の `\\.\pipe\openssh-ssh-agent`・op-reason の中継) に届かず、ssh の remote が `Permission denied (publickey)`
//! で落ちる。`win/openssh/Install-OpenSSH.ps1` が winget で入れる版 (`%ProgramFiles%\OpenSSH\ssh.exe`) があればそれ、無ければ Windows の機能の版
//! (`%SystemRoot%\System32\OpenSSH\ssh.exe`) を書く。git は値を shell で起こすので、`/` 区切りにして `'…'` で囲む。どちらも無ければ書かずに知らせる
//! (無い exe を書くと ssh の remote が全部起こせなくなる。OpenSSH が無いことは手順 openssh が知らせる)。中継を使わないホストにも書く。
//!
//! 入れたての Windows 11 には Windows の機能の版が既定で入っていて、winget の版は同じ apply の手順 openssh (order 96) が後から入れる。そこで apply では
//! openssh の後に、置いた config (記録どおりのもの) の core.sshCommand が今選ぶ ssh.exe と違えば、この手順をもう一度流す (`Step::rerun_after`。
//! runner の `execute` が流し直す)。順は 50 のまま (ハブを作る hc-hub (60) の pjp hub init の commit を、ここで書く名前とメールにする。ADR 066)。
//!
//! どれも記録つきのコピー (`%LOCALAPPDATA%\dotfiles\state\git-config.deployed.json`。CLAUDE.md と同じ `linker` の判定)。Windows 側で変わった・
//! 記録の無い違う中身は衝突で飛ばして知らせる (`~/.gitconfig` が無いと、`git config --global` はここの config に書く)。書かなくなった
//! ファイル (gitIdentity を外した・owner を消した) は、中身が記録どおりなら消す。

use super::linker::{Linker, Source};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::link::{is_link, same_path};
use crate::record::Records;
use crate::report::Kind;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// 値の正本 (dotfiles の clone の中。Linux の git.nix も読む)
pub const DATA: &str = "nix/home/modules/git.toml";
/// コピーの記録 (`%LOCALAPPDATA%\dotfiles\state\` の下)
pub const RECORD_FILE: &str = "git-config.deployed.json";
/// 置き場 (ホームからの相対。`XDG_CONFIG_HOME` の無いときに git が読む場所。WSL の home-manager と同じ)
pub const DIR: &str = ".config/git";
/// includeIf の条件に書く Windows の ghq の root (bootstrap が 3 つの repo を clone する `%USERPROFILE%\ghq`)
pub const GHQ_ROOT: &str = "~/ghq";
/// git.toml の `[settings]` に書かない節 (名前とメールは `[identity]`・道具 `gitIdentity` で、署名は WSL だけ、include は owner ごとに
/// 切り替えるので、`[settings]` にあると切り替えの外で書き出される。git.nix の assertion と同じ)
const RESERVED: [&str; 4] = ["user", "gpg", "include", "includeif"];
/// apply でこの手順の後に流れ、流れた直後にこの手順を流し直すかを聞く手順 (OpenSSH を入れる ps1 の手順。`Step::rerun_after`)
pub const RERUN_AFTER: &str = "openssh";
/// Windows の OpenSSH の ssh.exe の置き場 (見る順。環境変数・その下の相対パス)。前が `Install-OpenSSH.ps1` の入れる winget の版、後ろが Windows の機能の版
pub const SSH_EXES: [(&str, &str); 2] = [
    ("ProgramFiles", "OpenSSH/ssh.exe"),
    ("SystemRoot", "System32/OpenSSH/ssh.exe"),
];

/// git config の値。home-manager の toGitINI と同じ書き方: 文字列は `"…"` で囲んで `\`・`"`・改行・タブを escape し、真偽値と整数は素のまま。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IniValue {
    Str(String),
    Bool(bool),
    Int(i64),
}

impl IniValue {
    fn render(&self) -> String {
        match self {
            IniValue::Str(s) => {
                let mut out = String::from("\"");
                for c in s.chars() {
                    match c {
                        '\n' => out.push_str("\\n"),
                        '\t' => out.push_str("\\t"),
                        '"' => out.push_str("\\\""),
                        '\\' => out.push_str("\\\\"),
                        c => out.push(c),
                    }
                }
                out.push('"');
                out
            }
            IniValue::Bool(b) => b.to_string(),
            IniValue::Int(i) => i.to_string(),
        }
    }
}

/// 節 → キー → 値 (同じキーを並べるなら複数)。subsection のある節は `.` でつないだ名前 (`filter.lfs`。home-manager の gitFlattenAttrs と同じ)。
pub type Ini = BTreeMap<String, BTreeMap<String, Vec<IniValue>>>;

/// home-manager の `lib.generators.toGitINI` と同じ形の文字列。節とキーは名前の順 (Nix の attrset の順)、節のあいだは空行、行はタブで下げる。
pub fn to_git_ini(ini: &Ini) -> String {
    ini.iter()
        .map(|(name, keys)| {
            let mut s = format!("[{}]\n", section_header(name));
            for (k, values) in keys {
                for v in values {
                    s.push_str(&format!("\t{k} = {}\n", v.render()));
                }
            }
            s
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// 節の見出し: `filter.lfs` → `filter "lfs"` (最初の `.` の後ろが subsection。`"` を含む名前はそのまま。toGitINI の mkSectionName と同じ)。
fn section_header(name: &str) -> String {
    if name.contains('"') {
        return name.to_string();
    }
    match name.split_once('.') {
        Some((section, sub)) => format!("{section} \"{sub}\""),
        None => name.to_string(),
    }
}

/// ghq の owner ごとの名前とメール (`[[identity.owners]]`)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Owner {
    /// `github.com/<owner>/` の owner
    pub owner: String,
    pub name: String,
    pub email: String,
}

/// git.toml の中身。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitData {
    pub ignores: Vec<String>,
    /// 個人のアカウントの名前とメール (`[identity]`)
    pub name: String,
    pub email: String,
    pub owners: Vec<Owner>,
    /// どのホストにも書く設定 (`[settings]`)
    pub settings: Ini,
}

/// git.toml を読む (知らないキー・型の違いは文を返す)。
pub fn parse(text: &str) -> Result<GitData, String> {
    let t: toml::Table = text
        .parse()
        .map_err(|e| format!("TOML として読めません: {e}"))?;
    unknown_keys(&t, &["ignores", "identity", "settings"], "")?;
    let ignores = match t.get("ignores") {
        None => Vec::new(),
        Some(toml::Value::Array(items)) => items
            .iter()
            .map(|v| {
                v.as_str()
                    .map(str::to_string)
                    .ok_or_else(|| "ignores は文字列の配列で書いてください".to_string())
            })
            .collect::<Result<_, _>>()?,
        Some(_) => return Err("ignores は文字列の配列で書いてください".to_string()),
    };
    let Some(toml::Value::Table(identity)) = t.get("identity") else {
        return Err("[identity] (name・email) がありません".to_string());
    };
    unknown_keys(identity, &["name", "email", "owners"], "[identity] ")?;
    let name = string(identity, "name", "[identity]")?;
    let email = string(identity, "email", "[identity]")?;
    let owners = match identity.get("owners") {
        None => Vec::new(),
        Some(toml::Value::Array(items)) => items
            .iter()
            .map(|item| {
                let toml::Value::Table(o) = item else {
                    return Err("[[identity.owners]] は表の配列で書いてください".to_string());
                };
                unknown_keys(o, &["owner", "name", "email"], "[[identity.owners]] ")?;
                let owner = string(o, "owner", "[[identity.owners]]")?;
                if !owner_ok(&owner) {
                    return Err(format!(
                        "[[identity.owners]] の owner は英数字で始まり英数字・. _ - だけの名前で書いてください: \"{owner}\""
                    ));
                }
                Ok(Owner {
                    owner,
                    name: string(o, "name", "[[identity.owners]]")?,
                    email: string(o, "email", "[[identity.owners]]")?,
                })
            })
            .collect::<Result<_, _>>()?,
        Some(_) => return Err("[[identity.owners]] は表の配列で書いてください".to_string()),
    };
    let mut settings = Ini::new();
    match t.get("settings") {
        None => {}
        Some(toml::Value::Table(sections)) => {
            for (section, v) in sections {
                if RESERVED.contains(&section.to_ascii_lowercase().as_str()) {
                    return Err(format!(
                        "[settings] に {section} は書けません (名前とメールは [identity] に書く。署名と include は git.nix と runner が持つ)"
                    ));
                }
                let toml::Value::Table(keys) = v else {
                    return Err(format!(
                        "settings.{section} は表 ([settings.{section}]) で書いてください"
                    ));
                };
                flatten(&mut vec![section.clone()], keys, &mut settings)?;
            }
            if settings.iter().any(|(section, keys)| {
                section.eq_ignore_ascii_case("core")
                    && keys.keys().any(|k| k.eq_ignore_ascii_case("sshCommand"))
            }) {
                return Err(
                    "[settings.core] に sshCommand は書けません (OS で違う。Windows は runner の git-config が Windows の OpenSSH の ssh.exe を書く)"
                        .to_string(),
                );
            }
        }
        Some(_) => return Err("settings は [settings.<節>] の表で書いてください".to_string()),
    }
    Ok(GitData {
        ignores,
        name,
        email,
        owners,
        settings,
    })
}

fn unknown_keys(t: &toml::Table, known: &[&str], where_: &str) -> Result<(), String> {
    let unknown: Vec<&str> = t
        .keys()
        .map(String::as_str)
        .filter(|k| !known.contains(k))
        .collect();
    if unknown.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "{where_}知らないキーがあります: {} (書けるのは {})",
            unknown.join(", "),
            known.join("・")
        ))
    }
}

fn string(t: &toml::Table, key: &str, where_: &str) -> Result<String, String> {
    match t.get(key) {
        Some(toml::Value::String(s)) if !s.is_empty() => Ok(s.clone()),
        _ => Err(format!(
            "{where_} の {key} を空でない文字列で書いてください"
        )),
    }
}

/// GitHub の owner の名前の形 (includeIf の条件と include のファイル名に入れる)
fn owner_ok(s: &str) -> bool {
    s.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// 節の表を、入れ子の表は subsection として `.` でつないだ節の名前にして並べる (home-manager の gitFlattenAttrs と同じ)。
fn flatten(path: &mut Vec<String>, keys: &toml::Table, out: &mut Ini) -> Result<(), String> {
    for (k, v) in keys {
        if let toml::Value::Table(t) = v {
            path.push(k.clone());
            flatten(path, t, out)?;
            path.pop();
            continue;
        }
        let where_ = format!("settings.{}.{k}", path.join("."));
        let values = match v {
            toml::Value::Array(items) => items
                .iter()
                .map(|item| scalar(item, &where_))
                .collect::<Result<_, _>>()?,
            other => vec![scalar(other, &where_)?],
        };
        out.entry(path.join("."))
            .or_default()
            .insert(k.clone(), values);
    }
    Ok(())
}

fn scalar(v: &toml::Value, where_: &str) -> Result<IniValue, String> {
    match v {
        toml::Value::String(s) => Ok(IniValue::Str(s.clone())),
        toml::Value::Boolean(b) => Ok(IniValue::Bool(*b)),
        toml::Value::Integer(i) => Ok(IniValue::Int(*i)),
        _ => Err(format!(
            "{where_} は文字列・真偽値・整数 (同じキーを並べるならその配列) で書いてください"
        )),
    }
}

/// `[filter "lfs"]` の 4 つ。home-manager の `programs.git.lfs.enable` が書くものと同じ値で、git-lfs は PATH のもの (Git for Windows に同梱。
/// Git for Windows の system の設定にも同じ 4 つがある)。
pub fn lfs() -> BTreeMap<String, Vec<IniValue>> {
    [
        ("clean", IniValue::Str("git-lfs clean -- %f".to_string())),
        (
            "process",
            IniValue::Str("git-lfs filter-process".to_string()),
        ),
        ("required", IniValue::Bool(true)),
        ("smudge", IniValue::Str("git-lfs smudge -- %f".to_string())),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), vec![v]))
    .collect()
}

/// `[user]` (名前とメール)
fn user(name: &str, email: &str) -> BTreeMap<String, Vec<IniValue>> {
    BTreeMap::from([
        ("email".to_string(), vec![IniValue::Str(email.to_string())]),
        ("name".to_string(), vec![IniValue::Str(name.to_string())]),
    ])
}

/// Windows の config の includeIf より前の節 (`identity` は道具 `gitIdentity`、`ssh_command` は `core.sshCommand` の値 ([`ssh_command`]))。
pub fn main_ini(data: &GitData, identity: bool, ssh_command: Option<&str>) -> Ini {
    let mut ini = data.settings.clone();
    if identity {
        ini.insert("user".to_string(), user(&data.name, &data.email));
    }
    ini.entry("filter.lfs".to_string())
        .or_default()
        .extend(lfs());
    if let Some(cmd) = ssh_command {
        ini.entry("core".to_string()).or_default().insert(
            "sshCommand".to_string(),
            vec![IniValue::Str(cmd.to_string())],
        );
    }
    ini
}

/// git に使わせる Windows の OpenSSH の ssh.exe ([`SSH_EXES`] の順で、ファイルのある最初のもの)。どれも無ければ None
pub fn windows_ssh(ctx: &Ctx) -> Option<PathBuf> {
    SSH_EXES.iter().find_map(|(var, rel)| {
        let root = ctx.sys.env(var).filter(|v| !v.trim().is_empty())?;
        let exe = join_segments(Path::new(&root), rel);
        exe.is_file().then_some(exe)
    })
}

/// `core.sshCommand` の値。git は値を shell (Git for Windows の sh) で起こすので、`\` を `/` にし (sh の `\` の解釈を避ける)、空白を含む
/// `Program Files` のために `'…'` で囲む (中の `'` は `'\''`)
pub fn ssh_command(exe: &Path) -> String {
    let path = exe.to_string_lossy().replace('\\', "/");
    format!("'{}'", path.replace('\'', "'\\''"))
}

/// owner の includeIf の条件 (Windows の ghq の root の下。末尾の `/` でその下の repo に当て、`/i` で大文字小文字を区別しない)。
pub fn include_condition(owner: &str) -> String {
    format!("gitdir/i:{GHQ_ROOT}/github.com/{owner}/")
}

/// owner の include のファイルの名前 (config と同じ場所。includeIf の path は config からの相対で書く)
pub fn include_file(owner: &str) -> String {
    format!("config.{owner}")
}

/// 置くファイル (`~/.config/git/` の下の名前と中身)。config・owner ごとの include (gitIdentity のときだけ)・ignore (ignores が空なら無し) の順。
/// config は home-manager と同じく、includeIf より前の節の後ろに、include ごとに空行を挟んで足す。
pub fn render(data: &GitData, identity: bool, ssh_command: Option<&str>) -> Vec<(String, String)> {
    let mut config = to_git_ini(&main_ini(data, identity, ssh_command));
    let mut includes = Vec::new();
    if identity {
        for o in &data.owners {
            let file = include_file(&o.owner);
            let include = Ini::from([(
                format!("includeIf.{}", include_condition(&o.owner)),
                BTreeMap::from([("path".to_string(), vec![IniValue::Str(file.clone())])]),
            )]);
            config.push('\n');
            config.push_str(&to_git_ini(&include));
            let contents = Ini::from([("user".to_string(), user(&o.name, &o.email))]);
            includes.push((file, to_git_ini(&contents)));
        }
    }
    let mut files = vec![("config".to_string(), config)];
    files.extend(includes);
    if !data.ignores.is_empty() {
        files.push((
            "ignore".to_string(),
            format!("{}\n", data.ignores.join("\n")),
        ));
    }
    files
}

pub struct GitConfig;

impl Step for GitConfig {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "git-config",
            order: 50,
            title: "git の設定 (~/.config/git/config・ignore) を、WSL の home-manager と同じ git.toml から置く (署名と delta は除く)",
            // Linux の git.nix (minimum の基本の道具) と同じくどのホストにも置く。名前とメールだけ gitIdentity で切り替える
            gate: Gate::Always,
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let data_path = ctx.repo_path(DATA);
        ctx.say(format!("dotfiles: {}", data_path.display()));
        let data = match std::fs::read_to_string(&data_path) {
            Ok(text) => parse(&text).map_err(|e| format!("{}: {e}", data_path.display())),
            Err(e) => Err(format!("{} が読めない ({e})", data_path.display())),
        };
        let data = match data {
            Ok(d) => d,
            Err(why) => {
                ctx.say(format!("!! {why}"));
                return vec![Outcome::new(Kind::Failed, why)];
            }
        };
        let identity = ctx.host.tool("gitIdentity");
        if !identity {
            ctx.say(format!(
                "名前とメール ([user]・includeIf) は書かない (gitIdentity = false。{})。このホストで使う名前とメールは ~/.gitconfig に書く: git config --file \"$HOME\\.gitconfig\" user.name \"…\"",
                ctx.host.tool_origin("gitIdentity")
            ));
        }
        let ssh = windows_ssh(ctx);
        match &ssh {
            // Windows の機能の版 (winget の版が無い。入れたての Windows 11)。windows_ssh はそこで作ったパスを返すので、要素で見分ける
            Some(exe) if exe.ends_with(SSH_EXES[1].1) => ctx.say(format!(
                "git の ssh (core.sshCommand): {} (Windows の機能の OpenSSH。winget の版 (%ProgramFiles%\\OpenSSH\\ssh.exe) が無い。受け持ちが runner なら、apply の手順 openssh (96) が winget の版を入れた後に書き直す)",
                exe.display()
            )),
            Some(exe) => ctx.say(format!(
                "git の ssh (core.sshCommand): {} (Windows の OpenSSH。1Password・中継の agent に届く)",
                exe.display()
            )),
            None => ctx.say(format!(
                "!! {}",
                no_ssh_note()
            )),
        }
        let dir = join_segments(&ctx.roots.user_profile, DIR);
        let record_path = ctx.state_dir.join(RECORD_FILE);
        let records = match Records::load(&record_path) {
            Ok(r) => r,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![
                    Outcome::new(Kind::Failed, "git-config のコピーの記録が壊れている").note(e),
                ];
            }
        };
        let src = Source {
            root: ctx.repo_path("nix/home/modules"),
            prev: None,
            foreign_suffix: None,
            kinds: &[],
            skip_skills: Vec::new(),
            select: None,
            origin: "clone",
            absorb: "dotfiles の nix/home/modules/git.toml",
            step: "git-config",
        };
        let mut w = Linker::new(src, dir.clone(), mode, records);
        let files = render(&data, identity, ssh.as_deref().map(ssh_command).as_deref());
        for (name, text) in &files {
            w.copy_bytes(ctx, text.as_bytes(), &dir.join(name), &label(name));
        }
        let keep: Vec<String> = files
            .iter()
            .map(|(name, _)| dir.join(name).to_string_lossy().into_owned())
            .collect();
        prune(ctx, &mut w, &dir, &keep);
        let mut outcomes = w.finish(ctx, &record_path, None);
        if let Some(manual) = outcomes.iter_mut().find(|o| o.kind == Kind::Manual) {
            manual.notes.push(
                "Windows だけの設定は ~/.gitconfig に書く (git は ~/.config/git/config の後に読み、同じキーは ~/.gitconfig が勝つ。~/.gitconfig が無いと git config --global は ~/.config/git/config に書く)".to_string(),
            );
        }
        let gitconfig = ctx.roots.user_profile.join(".gitconfig");
        if gitconfig.is_file() {
            outcomes[0].notes.push(format!(
                "{} がある (git は ~/.config/git/config の後に読むので、同じキーはそちらが勝つ。git config --global の書き込み先もそちら)",
                gitconfig.display()
            ));
        }
        if ssh.is_none() {
            outcomes[0].notes.push(no_ssh_note());
        }
        outcomes.extend(where_git_reads(ctx, &dir));
        outcomes
    }

    /// 手順 openssh の後に、置いた config の core.sshCommand が今選ぶ ssh.exe と違えば流し直す ([`ssh_outdated`])。入れたての Windows では、
    /// この手順 (50) が Windows の機能の版を書いた後で openssh (96) が winget の版を入れるので、流し直さないと 1 回の apply で揃わない
    /// (順は 50 のまま: ハブの pjp hub init (hc-hub。60) の commit を個人の名前にする。dotfiles-private の ADR 066)
    fn rerun_after(&self, ctx: &Ctx, after: &str) -> bool {
        after == RERUN_AFTER && ssh_outdated(ctx)
    }
}

/// 置いた config (`~/.config/git/config`) の core.sshCommand が、今選ぶ ssh.exe ([`windows_ssh`]) の値と違うか。config が無い・読めない・
/// 記録と違う (Windows 側で変わった。衝突は書いたときに知らせた) ときは違わないとする (書き直さない)
pub fn ssh_outdated(ctx: &Ctx) -> bool {
    let config = join_segments(&ctx.roots.user_profile, DIR).join("config");
    let Ok(bytes) = std::fs::read(&config) else {
        return false;
    };
    let Ok(records) = Records::load(&ctx.state_dir.join(RECORD_FILE)) else {
        return false;
    };
    let have = fsutil::sha256_bytes(&bytes);
    if records.get(&config.to_string_lossy()) != Some(have.as_str()) {
        return false;
    }
    let text = String::from_utf8_lossy(&bytes);
    let written: Vec<&str> = text
        .lines()
        .filter(|l| l.trim_start().starts_with("sshCommand = "))
        .collect();
    match windows_ssh(ctx) {
        Some(exe) => {
            let want = format!(
                "\tsshCommand = {}",
                IniValue::Str(ssh_command(&exe)).render()
            );
            written != [want.as_str()]
        }
        None => !written.is_empty(),
    }
}

/// Windows の OpenSSH の ssh.exe が無いときの行
fn no_ssh_note() -> String {
    "Windows の OpenSSH の ssh.exe (%ProgramFiles%\\OpenSSH・%SystemRoot%\\System32\\OpenSSH) が無いので core.sshCommand を書かない (git は Git for Windows の ssh を使い、1Password・中継の agent に届かない)。PowerShell で Install-OpenSSH -IfMissing を打ってから dotfiles apply".to_string()
}

/// 出力と締めの表に出す名前
fn label(name: &str) -> String {
    format!("~/{DIR}/{name}")
}

/// 記録にあるファイルのうち、今は書かないもの (gitIdentity を外した・owner を消した・ignores を空にした) を消す。中身が記録どおりでなければ
/// 残して知らせる (記録からは外す)。
fn prune(ctx: &mut Ctx, w: &mut Linker, dir: &Path, keep: &[String]) {
    for key in w.records.keys() {
        if keep.contains(&key) {
            continue;
        }
        let dest = PathBuf::from(&key);
        let shown = match (dest.parent(), dest.file_name()) {
            (Some(parent), Some(name)) if same_path(parent, dir) => label(&name.to_string_lossy()),
            _ => key.clone(),
        };
        if !dest.exists() || is_link(&dest) {
            if w.mode.writes() {
                w.records.remove(&key);
            }
            continue;
        }
        let recorded = w.records.get(&key).map(str::to_string);
        match fsutil::sha256_file(&dest) {
            Ok(have) if recorded.as_deref() == Some(have.as_str()) => {
                match w.mode {
                    Mode::Check => ctx.say(format!("消す (apply で): {shown} (今は書かない)")),
                    Mode::DryRun { .. } => ctx.say(format!("[dry-run] 消す: {shown}")),
                    Mode::Apply { .. } => {
                        if let Err(e) = std::fs::remove_file(&dest) {
                            w.fail(ctx, format!("{shown} を消せない ({e})"));
                            continue;
                        }
                        w.records.remove(&key);
                        ctx.say(format!("消しました: {shown} (今は書かない)"));
                    }
                }
                w.tally.removed += 1;
            }
            Ok(_) => {
                w.skip(
                    ctx,
                    format!(
                        "{shown} (今は書かないが、Windows 側で変わっているので消さない。要らなければ手で消す)"
                    ),
                );
                if w.mode.writes() {
                    w.records.remove(&key);
                }
            }
            Err(e) => w.fail(ctx, format!("{shown} が読めない ({e})")),
        }
    }
}

/// git が `dir` の config を読まない環境なら、そのわけの行 (runner では直らない)。git は `XDG_CONFIG_HOME` があれば
/// `%XDG_CONFIG_HOME%\git\config` を、無ければ `$HOME\.config\git\config` を読む (Git for Windows は HOME が無ければ USERPROFILE)。
fn where_git_reads(ctx: &mut Ctx, dir: &Path) -> Vec<Outcome> {
    let set = |name: &str| ctx.sys.env(name).filter(|v| !v.trim().is_empty());
    let (var, reads) = if let Some(x) = set("XDG_CONFIG_HOME") {
        ("XDG_CONFIG_HOME", PathBuf::from(&x).join("git"))
    } else if let Some(h) = set("HOME") {
        ("HOME", join_segments(Path::new(&h), DIR))
    } else {
        return Vec::new();
    };
    if same_path(&reads, dir) {
        return Vec::new();
    }
    ctx.say(format!(
        "!! {var} があるので、git は {} を読み、{} の設定は効きません",
        reads.join("config").display(),
        dir.join("config").display()
    ));
    vec![
        Outcome::new(
            Kind::Manual,
            format!(
                "{var} があるので git は {} を読む (ここに置いた git の設定が効かない)",
                reads.join("config").display()
            ),
        )
        .note(format!(
            "{var} を外す (Windows の環境変数) か、{} に置いた設定をそちらへ写す",
            dir.display()
        )),
    ]
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - git.toml を読む: ignores・[identity]・[[identity.owners]]・[settings] (入れ子の表は subsection、配列は同じキーを並べる)。知らないキー・
    //!   型の違い・[settings] の user・gpg・include・includeIf・owner の名前の形の誤りは文を返す
    //! - home-manager の toGitINI と同じ形で書く (節とキーは名前の順・節のあいだは空行・タブで下げる・文字列は escape して "…" で囲む・
    //!   subsection は `節 "名前"`)
    //! - gitIdentity なら [user] と owner ごとの includeIf (gitdir/i:~/ghq/github.com/<owner>/) と include のファイル、でなければどれも書かない。
    //!   [filter "lfs"] は PATH の git-lfs でいつも書く
    //! - 記録つきのコピー: 無い → missing (check と dry-run は書かない)・apply で置く・同じ → ok・記録どおりなら上書き・Windows 側で変わった
    //!   ものは衝突 (--force で上書き)
    //! - gitIdentity を外すと、記録どおりの include のファイルを消す (変えていれば残して知らせる)
    //! - ~/.gitconfig があれば添える。XDG_CONFIG_HOME か HOME で git が別の場所を読むなら manual
    //! - core.sshCommand: %ProgramFiles%\OpenSSH\ssh.exe があればそれ、無ければ %SystemRoot%\System32\OpenSSH\ssh.exe を、`/` 区切りで `'…'` に囲んで
    //!   [core] に書く。どちらも無ければ書かずに知らせる。ssh.exe が増えた・減ったときは、記録どおりの config を書き換える (衝突にしない)。
    //!   git.toml の [settings.core] の sshCommand は文を返す。Windows の機能の版を選んだら、openssh が winget の版を入れた後に書き直すと添える
    //! - apply の openssh の後に流し直すのは、記録どおりの config の core.sshCommand が今選ぶ ssh.exe と違うときだけ (ほかの手順の後・衝突した
    //!   config・無い config では流し直さない)。入れたての Windows で受け持ちが runner の apply を 1 回流すと、続く check の git-config が揃う
    //! - repo の git.toml を読める (本物の repo)

    use super::*;
    use crate::host::{Groups, parse as parse_host};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir};

    const TOML: &str = r#"
ignores = [".env", "node_modules/"]

[identity]
name = "me"
email = "me@example.com"

[[identity.owners]]
owner = "me-sub"
name = "me-sub"
email = "me+sub@example.com"

[settings.core]
editor = "vim"
autocrlf = false

[settings.alias]
st = "status"

[settings.url."https://example.com/"]
insteadOf = ["git@example.com:", "ssh://git@example.com/"]

[settings.http]
postBuffer = 524288000
"#;

    fn data() -> GitData {
        parse(TOML).unwrap()
    }

    const SAMPLE_SSH: &str = "'C:/Program Files/OpenSSH/ssh.exe'";

    #[test]
    fn parses_the_data() {
        let d = data();
        assert_eq!(d.ignores, vec![".env", "node_modules/"]);
        assert_eq!(
            (d.name.as_str(), d.email.as_str()),
            ("me", "me@example.com")
        );
        assert_eq!(
            d.owners,
            vec![Owner {
                owner: "me-sub".into(),
                name: "me-sub".into(),
                email: "me+sub@example.com".into()
            }]
        );
        assert_eq!(
            d.settings["url.https://example.com/"]["insteadOf"],
            vec![
                IniValue::Str("git@example.com:".into()),
                IniValue::Str("ssh://git@example.com/".into())
            ]
        );
        assert_eq!(
            d.settings["http"]["postBuffer"],
            vec![IniValue::Int(524288000)]
        );
    }

    #[test]
    fn rejects_bad_data() {
        let base = "[identity]\nname = \"a\"\nemail = \"b\"\n";
        let cases = [
            ("x = 1\n", "知らないキー"),
            ("", "[identity] (name・email) がありません"),
            ("[identity]\nname = \"a\"\n", "email を空でない文字列"),
            (
                "[identity]\nname = \"a\"\nemail = \"b\"\nsigningKey = \"k\"\n",
                "[identity] 知らないキー",
            ),
            ("ignores = [1]\n", "文字列の配列"),
        ];
        for (text, want) in cases {
            let e = parse(text).unwrap_err();
            assert!(e.contains(want), "{text:?}: {e}");
        }
        let with = |extra: &str| parse(&format!("{base}{extra}")).unwrap_err();
        assert!(
            with("[settings.user]\nname = \"x\"\n").contains("[settings] に user は書けません")
        );
        assert!(with("[settings.includeIf]\nx = \"y\"\n").contains("includeIf は書けません"));
        assert!(
            with("[settings.core]\nx = 1.5\n").contains("settings.core.x は文字列・真偽値・整数")
        );
        assert!(with("[settings]\ncore = 1\n").contains("settings.core は表"));
        for key in ["sshCommand", "sshcommand"] {
            assert!(
                with(&format!("[settings.core]\n{key} = \"ssh\"\n"))
                    .contains("[settings.core] に sshCommand は書けません"),
                "{key}"
            );
        }
        assert!(
            with("[[identity.owners]]\nowner = \"a b\"\nname = \"n\"\nemail = \"e\"\n")
                .contains("owner は英数字で始まり")
        );
    }

    #[test]
    fn renders_like_home_manager() {
        let files = render(&data(), true, None);
        let names: Vec<&str> = files.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, vec!["config", "config.me-sub", "ignore"]);
        assert_eq!(
            files[0].1,
            concat!(
                "[alias]\n",
                "\tst = \"status\"\n",
                "\n",
                "[core]\n",
                "\tautocrlf = false\n",
                "\teditor = \"vim\"\n",
                "\n",
                "[filter \"lfs\"]\n",
                "\tclean = \"git-lfs clean -- %f\"\n",
                "\tprocess = \"git-lfs filter-process\"\n",
                "\trequired = true\n",
                "\tsmudge = \"git-lfs smudge -- %f\"\n",
                "\n",
                "[http]\n",
                "\tpostBuffer = 524288000\n",
                "\n",
                "[url \"https://example.com/\"]\n",
                "\tinsteadOf = \"git@example.com:\"\n",
                "\tinsteadOf = \"ssh://git@example.com/\"\n",
                "\n",
                "[user]\n",
                "\temail = \"me@example.com\"\n",
                "\tname = \"me\"\n",
                "\n",
                "[includeIf \"gitdir/i:~/ghq/github.com/me-sub/\"]\n",
                "\tpath = \"config.me-sub\"\n",
            )
        );
        assert_eq!(
            files[1].1,
            "[user]\n\temail = \"me+sub@example.com\"\n\tname = \"me-sub\"\n"
        );
        assert_eq!(files[2].1, ".env\nnode_modules/\n");
        // gitIdentity でなければ [user] も includeIf も include のファイルも無い
        let files = render(&data(), false, None);
        let names: Vec<&str> = files.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, vec!["config", "ignore"]);
        assert!(!files[0].1.contains("[user]") && !files[0].1.contains("includeIf"));
        assert!(
            files[0]
                .1
                .ends_with("\tinsteadOf = \"ssh://git@example.com/\"\n")
        );
    }

    #[test]
    fn ssh_command_is_quoted_for_the_shell() {
        assert_eq!(
            ssh_command(Path::new("C:\\Program Files\\OpenSSH\\ssh.exe")),
            SAMPLE_SSH
        );
        assert_eq!(
            ssh_command(Path::new("C:\\Windows\\System32\\OpenSSH\\ssh.exe")),
            "'C:/Windows/System32/OpenSSH/ssh.exe'"
        );
        assert_eq!(
            ssh_command(Path::new("C:/it's/ssh.exe")),
            "'C:/it'\\''s/ssh.exe'"
        );
        // [core] の中に、名前の順で書く (値の ' は escape しない)
        let files = render(&data(), false, Some(SAMPLE_SSH));
        assert!(
            files[0].1.contains(concat!(
                "[core]\n",
                "\tautocrlf = false\n",
                "\teditor = \"vim\"\n",
                "\tsshCommand = \"'C:/Program Files/OpenSSH/ssh.exe'\"\n",
                "\n",
            )),
            "{}",
            files[0].1
        );
    }

    #[test]
    fn escapes_strings() {
        let v = IniValue::Str("a\"b\\c\nd\te".into());
        assert_eq!(v.render(), r#""a\"b\\c\nd\te""#);
        assert_eq!(section_header("a"), "a");
        assert_eq!(section_header("a.b.c"), "a \"b.c\"");
        assert_eq!(section_header("includeIf \"x\""), "includeIf \"x\"");
    }

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            let t = TempDir::new("git-config");
            t.write("dotfiles/nix/home/modules/git.toml", TOML);
            Env { t }
        }

        fn git(&self, name: &str) -> PathBuf {
            self.t
                .path()
                .join("home")
                .join(".config")
                .join("git")
                .join(name)
        }

        fn run_with(&self, mode: Mode, host: &str, sys: FakeSys) -> (Vec<Outcome>, String) {
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.t.path().join("home")),
                    state_dir: self.t.path().join("state"),
                    host: parse_host(host, Path::new("h.toml"), Groups::embedded().unwrap())
                        .unwrap(),
                    sys: &sys,
                    out: &mut out,
                };
                GitConfig.run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        }

        fn run(&self, mode: Mode, host: &str) -> (Vec<Outcome>, String) {
            self.run_with(
                mode,
                host,
                FakeSys::new(|_| unreachable!("コマンドは打たない")),
            )
        }

        /// 後ろの手順 `after` の後に流し直すか (`Step::rerun_after`)
        fn rerun_after(&self, after: &str, sys: FakeSys) -> bool {
            let mut out = Vec::new();
            let ctx = Ctx {
                repo: self.t.path().join("dotfiles"),
                roots: Roots::from_home(&self.t.path().join("home")),
                state_dir: self.t.path().join("state"),
                host: parse_host("", Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                sys: &sys,
                out: &mut out,
            };
            GitConfig.rerun_after(&ctx, after)
        }
    }

    /// 名前とメールを書くホスト (gitIdentity は minimum に入らないので、使うホストが [tools] に書く)
    const IDENTITY: &str = "[tools]\ngitIdentity = true\n";

    fn kinds(o: &[Outcome]) -> Vec<Kind> {
        o.iter().map(|x| x.kind).collect()
    }

    #[test]
    fn places_and_records() {
        let e = Env::new();
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let (o, out) = e.run(mode, IDENTITY);
            assert_eq!(kinds(&o), vec![Kind::Missing], "{mode:?} {o:?}\n{out}");
            assert!(!e.git("config").exists());
        }
        let (o, out) = e.run(Mode::Apply { force: false }, IDENTITY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].text.starts_with("追加 3 / 更新 0 / 削除 0 / 同じ 0"),
            "{o:?}"
        );
        assert!(
            std::fs::read_to_string(e.git("config"))
                .unwrap()
                .contains("[includeIf \"gitdir/i:~/ghq/github.com/me-sub/\"]")
        );
        assert!(e.git("config.me-sub").is_file() && e.git("ignore").is_file());
        let record: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(e.t.path().join("state").join(RECORD_FILE)).unwrap(),
        )
        .unwrap();
        assert_eq!(record.as_object().unwrap().len(), 3);
        let (o, _) = e.run(Mode::Check, IDENTITY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        // git.toml を変えると、記録どおりの中身なので上書きする
        e.t.write(
            "dotfiles/nix/home/modules/git.toml",
            &TOML.replace("editor = \"vim\"", "editor = \"nano\""),
        );
        let (o, _) = e.run(Mode::Check, IDENTITY);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}");
        let (o, _) = e.run(Mode::Apply { force: false }, IDENTITY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(
            std::fs::read_to_string(e.git("config"))
                .unwrap()
                .contains("editor = \"nano\"")
        );
    }

    #[test]
    fn edited_config_conflicts() {
        let e = Env::new();
        e.run(Mode::Apply { force: false }, IDENTITY);
        // git config --global が足した (~/.gitconfig が無いと、ここの config に書く)
        let edited = format!(
            "{}[credential \"https://github.com\"]\n\thelper = !gh auth git-credential\n",
            std::fs::read_to_string(e.git("config")).unwrap()
        );
        std::fs::write(e.git("config"), &edited).unwrap();
        let (o, _) = e.run(Mode::Apply { force: false }, IDENTITY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes.iter().any(|n| n
                .starts_with("~/.config/git/config (中身が違う。Windows 側で変わった")
                && n.contains("dotfiles の nix/home/modules/git.toml へ取り込む")
                && n.contains("--steps git-config --force")),
            "{o:?}"
        );
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("Windows だけの設定は ~/.gitconfig に書く")),
            "{o:?}"
        );
        assert_eq!(std::fs::read_to_string(e.git("config")).unwrap(), edited);
        let (o, _) = e.run(Mode::Apply { force: true }, IDENTITY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(
            !std::fs::read_to_string(e.git("config"))
                .unwrap()
                .contains("credential")
        );
        // 記録の無い違う中身 (手で置いた config) も衝突
        let e = Env::new();
        e.t.write("home/.config/git/config", "[user]\n\tname = hand\n");
        let (o, _) = e.run(Mode::Apply { force: false }, IDENTITY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes.iter().any(|n| n.contains("置いた記録が無い")),
            "{o:?}"
        );
        assert_eq!(
            std::fs::read_to_string(e.git("config")).unwrap(),
            "[user]\n\tname = hand\n"
        );
    }

    #[test]
    fn identity_off_removes_the_include() {
        let e = Env::new();
        e.run(Mode::Apply { force: false }, IDENTITY);
        let off = "[tools]\ngitIdentity = false\n";
        let (o, out) = e.run(Mode::Check, off);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(
            out.contains("消す (apply で): ~/.config/git/config.me-sub"),
            "{out}"
        );
        assert!(out.contains("gitIdentity = false"), "{out}");
        let (o, _) = e.run(Mode::Apply { force: false }, off);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(o[0].text.contains("更新 1 / 削除 1"), "{o:?}");
        assert!(!e.git("config.me-sub").exists());
        assert!(
            !std::fs::read_to_string(e.git("config"))
                .unwrap()
                .contains("[user]")
        );
        // 変えた include のファイルは消さずに知らせる
        e.run(Mode::Apply { force: false }, IDENTITY);
        std::fs::write(e.git("config.me-sub"), "[user]\n\tname = edited\n").unwrap();
        let (o, _) = e.run(Mode::Apply { force: false }, off);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.contains("config.me-sub (今は書かないが")),
            "{o:?}"
        );
        assert!(e.git("config.me-sub").is_file());
    }

    #[test]
    fn notes_where_git_reads() {
        let e = Env::new();
        e.t.write("home/.gitconfig", "[core]\n\teditor = nano\n");
        let home = e.t.path().join("home");
        let sys = FakeSys::new(|_| unreachable!()).with_env("HOME", &home.to_string_lossy());
        let (o, _) = e.run_with(Mode::Check, "", sys);
        assert_eq!(kinds(&o), vec![Kind::Missing], "{o:?}");
        assert!(
            o[0].notes.iter().any(|n| n.contains(".gitconfig がある")),
            "{o:?}"
        );
        let sys = FakeSys::new(|_| unreachable!()).with_env("HOME", "/elsewhere");
        let (o, out) = e.run_with(Mode::Check, "", sys);
        assert_eq!(kinds(&o), vec![Kind::Missing, Kind::Manual], "{o:?}");
        assert!(o[1].text.starts_with("HOME があるので git は"), "{o:?}");
        assert!(out.contains("!! HOME があるので"), "{out}");
        let xdg = home.join(".config");
        let sys = FakeSys::new(|_| unreachable!())
            .with_env("XDG_CONFIG_HOME", &xdg.to_string_lossy())
            .with_env("HOME", "/elsewhere");
        let (o, _) = e.run_with(Mode::Check, "", sys);
        assert_eq!(
            kinds(&o),
            vec![Kind::Missing],
            "XDG_CONFIG_HOME が同じ場所なら効く {o:?}"
        );
        let sys = FakeSys::new(|_| unreachable!()).with_env("XDG_CONFIG_HOME", "/xdg");
        let (o, _) = e.run_with(Mode::Check, "", sys);
        assert_eq!(kinds(&o), vec![Kind::Missing, Kind::Manual], "{o:?}");
        assert!(o[1].text.starts_with("XDG_CONFIG_HOME があるので"), "{o:?}");
    }

    #[test]
    fn writes_the_windows_ssh() {
        let e = Env::new();
        let pf = e.t.path().join("pf");
        let sysroot = e.t.path().join("windows");
        let sys = || {
            FakeSys::new(|_| unreachable!())
                .with_env("ProgramFiles", &pf.to_string_lossy())
                .with_env("SystemRoot", &sysroot.to_string_lossy())
        };
        let config = || std::fs::read_to_string(e.git("config")).unwrap();
        let line = |exe: &Path| format!("\tsshCommand = \"{}\"\n", ssh_command(exe));

        // どちらも無い: 書かずに知らせる
        let (o, out) = e.run_with(Mode::Apply { force: false }, "", sys());
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].notes
                .iter()
                .any(|n| n.contains("core.sshCommand を書かない")
                    && n.contains("Install-OpenSSH -IfMissing")),
            "{o:?}"
        );
        assert!(out.contains("!! Windows の OpenSSH の ssh.exe"), "{out}");
        assert!(!config().contains("sshCommand"));

        // Windows の機能の版だけ: それを書く。前に置いた config (記録どおり) を書き換え、衝突にしない
        let inbox = join_segments(&sysroot, "System32/OpenSSH/ssh.exe");
        e.t.write("windows/System32/OpenSSH/ssh.exe", "");
        let (o, out) = e.run_with(Mode::Check, "", sys());
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(out.contains("git の ssh (core.sshCommand): "), "{out}");
        // winget の版が無いので Windows の機能の版を選んだ。apply では openssh の後に書き直すことを添える
        assert!(
            out.contains(
                "(Windows の機能の OpenSSH。winget の版 (%ProgramFiles%\\OpenSSH\\ssh.exe) が無い。受け持ちが runner なら、apply の手順 openssh (96) が winget の版を入れた後に書き直す)"
            ),
            "{out}"
        );
        let (o, _) = e.run_with(Mode::Apply { force: false }, "", sys());
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(
            o[0].notes.iter().all(|n| !n.contains("core.sshCommand")),
            "{o:?}"
        );
        assert!(config().contains(&line(&inbox)), "{}", config());

        // winget の版もある: そちらが先
        let winget = join_segments(&pf, "OpenSSH/ssh.exe");
        e.t.write("pf/OpenSSH/ssh.exe", "");
        let (o, out) = e.run_with(Mode::Apply { force: false }, "", sys());
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(
            out.contains("(Windows の OpenSSH。1Password・中継の agent に届く)")
                && !out.contains("Windows の機能の OpenSSH"),
            "{out}"
        );
        assert!(config().contains(&line(&winget)), "{}", config());
        assert_eq!(config().matches("sshCommand").count(), 1);

        // 無くなった: 記録どおりの config から外す
        std::fs::remove_file(&winget).unwrap();
        std::fs::remove_file(&inbox).unwrap();
        let (o, _) = e.run_with(Mode::Apply { force: false }, "", sys());
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(!config().contains("sshCommand"));
    }

    /// 入れたての Windows: 1 回目の apply の git-config (50) は Windows の機能の版を書き、openssh (96) が winget の版を入れる。openssh の後に
    /// 流し直すのは、置いた config が記録どおりで、その core.sshCommand が今選ぶ ssh.exe と違うときだけ (ほかの手順の後・衝突した config・
    /// 無い config では流し直さない)
    #[test]
    fn reruns_after_openssh_only_when_the_ssh_changed() {
        let e = Env::new();
        let pf = e.t.path().join("pf");
        let sysroot = e.t.path().join("windows");
        let sys = || {
            FakeSys::new(|_| unreachable!())
                .with_env("ProgramFiles", &pf.to_string_lossy())
                .with_env("SystemRoot", &sysroot.to_string_lossy())
        };
        // まだ置いていない
        e.t.write("windows/System32/OpenSSH/ssh.exe", "");
        assert!(!e.rerun_after("openssh", sys()));
        // Windows の機能の版を書いた。ssh.exe が同じ間は流し直さない
        e.run_with(Mode::Apply { force: false }, "", sys());
        assert!(!e.rerun_after("openssh", sys()));
        // openssh が winget の版を入れた: openssh の後なら流し直す (ほかの手順の後では流し直さない)
        e.t.write("pf/OpenSSH/ssh.exe", "");
        assert!(e.rerun_after("openssh", sys()));
        assert!(!e.rerun_after("files", sys()));
        // 流し直すと winget の版になり、もう流し直さない
        e.run_with(Mode::Apply { force: false }, "", sys());
        assert!(!e.rerun_after("openssh", sys()));
        // Windows 側で変えた config (衝突) は、1 回目が知らせたので流し直さない
        let winget = join_segments(&pf, "OpenSSH/ssh.exe");
        std::fs::remove_file(&winget).unwrap();
        let edited = format!(
            "{}[alias]\n\tx = y\n",
            std::fs::read_to_string(e.git("config")).unwrap()
        );
        std::fs::write(e.git("config"), edited).unwrap();
        assert!(!e.rerun_after("openssh", sys()));
    }

    /// 偽の openssh: apply で winget の版の ssh.exe を置く (入れたての Windows で OpenSSH を入れる)
    struct FakeOpenssh(PathBuf);

    impl Step for FakeOpenssh {
        fn info(&self) -> StepInfo {
            StepInfo {
                id: "openssh",
                order: 96,
                title: "OpenSSH",
                gate: Gate::Always,
                ported: true,
                windows_only: false,
            }
        }
        fn run(&self, _ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
            if mode.writes() {
                std::fs::create_dir_all(self.0.parent().unwrap()).unwrap();
                std::fs::write(&self.0, "").unwrap();
            }
            vec![Outcome::new(Kind::Ok, "入れた")]
        }
    }

    /// 入れたての Windows (Windows の機能の版だけがある) で、受け持ちが runner のホストの apply を 1 回流すと、openssh の後に git-config を
    /// 流し直して winget の版を書き、続く check の git-config が揃っている
    #[test]
    fn one_apply_settles_the_ssh_on_a_fresh_windows() {
        let e = Env::new();
        let pf = e.t.path().join("pf");
        let sysroot = e.t.path().join("windows");
        e.t.write("windows/System32/OpenSSH/ssh.exe", "");
        let sys = FakeSys::new(|_| unreachable!())
            .with_env("ProgramFiles", &pf.to_string_lossy())
            .with_env("SystemRoot", &sysroot.to_string_lossy());
        let winget = join_segments(&pf, "OpenSSH/ssh.exe");
        let steps: Vec<Box<dyn Step>> =
            vec![Box::new(GitConfig), Box::new(FakeOpenssh(winget.clone()))];
        let runner_host = "[runner]\nenable = true\n";
        let run = |mode: Mode| {
            let mut out = Vec::new();
            let rows = {
                let mut ctx = Ctx {
                    repo: e.t.path().join("dotfiles"),
                    roots: Roots::from_home(&e.t.path().join("home")),
                    state_dir: e.t.path().join("state"),
                    host: parse_host(
                        runner_host,
                        Path::new("h.toml"),
                        Groups::embedded().unwrap(),
                    )
                    .unwrap(),
                    sys: &sys,
                    out: &mut out,
                };
                crate::runner::execute(&mut ctx, mode, &steps)
            };
            (rows, String::from_utf8(out).unwrap())
        };
        let (rows, out) = run(Mode::Apply { force: false });
        let texts: Vec<(&str, &str)> = rows
            .iter()
            .map(|r| (r.id.as_str(), r.text.as_str()))
            .collect();
        // 締めの表の git-config の行は、流し直した行に置き換わる (1 回目の「追加 2」は残らない)
        assert_eq!(texts.len(), 2, "{texts:?}\n{out}");
        assert_eq!(texts[0].0, "git-config");
        assert!(
            texts[0]
                .1
                .starts_with("openssh の後に流し直した: 追加 0 / 更新 1"),
            "{texts:?}"
        );
        assert_eq!(texts[1], ("openssh", "入れた"));
        assert!(
            out.contains("━━ [50] git-config: ") && out.contains("(openssh の後に流し直す) ━━"),
            "{out}"
        );
        let config = std::fs::read_to_string(e.git("config")).unwrap();
        assert!(
            config.contains(&format!("\tsshCommand = \"{}\"\n", ssh_command(&winget))),
            "{config}"
        );
        let (rows, out) = run(Mode::Check);
        assert!(rows.iter().all(|r| r.kind == Kind::Ok), "{rows:?}\n{out}");
    }

    /// ssh.exe が無いまま書いた config (core.sshCommand なし) も、openssh が入れた後なら流し直す
    #[test]
    fn reruns_when_the_first_ssh_appears() {
        let e = Env::new();
        let pf = e.t.path().join("pf");
        let sys = || {
            FakeSys::new(|_| unreachable!())
                .with_env("ProgramFiles", &pf.to_string_lossy())
                .with_env("SystemRoot", &e.t.path().join("windows").to_string_lossy())
        };
        e.run_with(Mode::Apply { force: false }, "", sys());
        assert!(!e.rerun_after("openssh", sys()));
        e.t.write("pf/OpenSSH/ssh.exe", "");
        assert!(e.rerun_after("openssh", sys()));
    }

    #[test]
    fn broken_data_fails() {
        let e = Env::new();
        e.t.write(
            "dotfiles/nix/home/modules/git.toml",
            "[identity]\nname = \"a\"\n",
        );
        let (o, out) = e.run(Mode::Check, IDENTITY);
        assert_eq!(kinds(&o), vec![Kind::Failed], "{o:?}");
        assert!(o[0].text.contains("email を空でない文字列"), "{o:?}");
        assert!(out.contains("!! "), "{out}");
    }

    /// 本物の repo の git.toml を読め、Windows の config を書ける
    #[test]
    fn real_repo_renders() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let d = parse(&std::fs::read_to_string(join_segments(&repo, DATA)).unwrap()).unwrap();
        assert!(!d.owners.is_empty() && !d.ignores.is_empty());
        let files = render(&d, true, Some(SAMPLE_SSH));
        assert!(files[0].1.contains("[core]\n") && files[0].1.contains("autocrlf = false"));
        assert!(!files[0].1.contains("gpgSign") && !files[0].1.contains("delta"));
        assert!(!files[0].1.contains("credential"));
        assert!(
            files[0]
                .1
                .contains(&format!("\tsshCommand = \"{SAMPLE_SSH}\"\n"))
        );
    }

    /// 流し直しの相手 (RERUN_AFTER) の手順が本物の一覧にあり、git-config より後ろで流れる (id か順が変わると、流し直しが黙って効かなくなる)
    #[test]
    fn the_step_to_rerun_after_runs_later() {
        let all = super::super::all();
        let at = |id: &str| {
            all.iter()
                .position(|s| s.info().id == id)
                .unwrap_or_else(|| panic!("{id} が手順の一覧に無い"))
        };
        assert_eq!(RERUN_AFTER, "openssh");
        assert!(at(RERUN_AFTER) > at("git-config"));
    }

    #[test]
    fn step_info() {
        let i = GitConfig.info();
        assert_eq!((i.id, i.order, i.gate), ("git-config", 50, Gate::Always));
        assert!(i.ported && i.windows_only);
    }
}
