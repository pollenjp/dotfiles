//! local-env (order 50): マシンローカルの環境変数のファイル `%USERPROFILE%\.config\pjp\env` (`XDG_CONFIG_HOME` があればその下) を用意し、
//! 頭の「dotfiles が書く欄」を書き直す。Linux の `nix/scripts/bootstrap-local-env.sh` (dotfiles-private の ADR 021) を Windows に写したもの
//! (印・欄の組み方・書き直し方・文言をそろえる。Linux の CI が同じ入力で bash の版と突き合わせる)。
//!
//! Windows でこのファイルを読むのは claude-skills の pjp だけ (Notion の宛先の resolver が `PJP_NOTION_TOKEN_<名前>` を読む。
//! `skills/pjp-notion-profile/rust/src/auth.rs`)。シェルは環境へ読み込まない。値 (API キー) は人が欄より下に書く。
//!
//! | ファイル | すること | 行の種類 (apply の前) |
//! | --- | --- | --- |
//! | 無い | 欄だけのファイルを作る | missing |
//! | 印が 1 組 | 印の間を新しい欄に替える。印より上と下は 1 バイトも変えない | fix (同じなら ok) |
//! | 印の間に `#` でない行がある | その行を元の順のまま終わりの印のすぐ下へ移し、変数名だけを知らせる | fix |
//! | 印が無い (空のファイルも) | 欄を頭に足す。今の行は消さない | fix |
//! | 印が壊れている・symlink・普通のファイルでない・読み取り専用・NUL を含む (UTF-16 など)・env.bak がディレクトリ | 書かずに知らせる | manual |
//!
//! - 書き上がりが今と同じなら何も書かない。違えば前の版を同じディレクトリの `env.bak` (1 世代) に写し、一時ファイルから rename で書く
//! - 欄の節は skill の断片 (`%USERPROFILE%\.claude\skills\<名前>\pjp-env.txt`。名前の順) から組む。印に化ける行・行の途中の制御文字を
//!   持つ断片と、名前が見出しを壊しうる skill は入れずに知らせる (書いたうえで ⚠。断片を直す)
//!
//! Linux と違うところ (dotfiles-private の docs/adr/105_win_local_env_*):
//!
//! - dotfiles の節 (`nix/pjp-env/dotfiles.txt`) を入れない。Linux の setup が環境変数として読むもので、Windows では読むものが無い
//! - 印の後ろの文言と前置きは Windows のもの (印として見るのは行の頭だけなので、Linux から写したファイルも見分ける)
//! - 改行はファイルに合わせる (CR があれば CRLF。無い・新しいファイルは LF。powershell-profile と同じ決め方)
//! - 印の無いファイルに欄を足すとき、頭の UTF-8 の BOM を外す (残すと欄の下の 1 行目の頭に来て、pjp がその行を読めない)
//! - 断片の NUL も入れない (書いたファイルを次の回に UTF-16 と見てしまう)
//! - 権限は締めない (`%USERPROFILE%` の下は継いだ ACL で本人と SYSTEM・Administrators だけが読める)。読み取り専用のファイルは書かない
//! - 印の無い古いテンプレート (ADR 021 の前の Linux の script が置いたもの) は見分けない (Windows には置かれていない)
//! - `XDG_CONFIG_HOME` が相対パスなら書かない (runner は clone の中で流れるので、そこに秘密を置くファイルを作らない)

use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::report::Kind;
use std::path::{Path, PathBuf};

/// 置き先 (ホームからの相対。`XDG_CONFIG_HOME` が無いとき)
pub const REL: &str = ".config/pjp/env";
/// skill の置き場 (ホームからの相対)
const SKILLS_REL: &str = ".claude/skills";
/// skill の断片のファイル名
const FRAGMENT: &str = "pjp-env.txt";
/// 前の版の写し (env と同じディレクトリ。1 世代)
const BAK: &str = "env.bak";
/// 締めの表に出す名前
const WHAT: &str = "~/.config/pjp/env";

/// 印として見る行の頭 (Linux と同じ。後ろの文言は変えてよい (ADR 021 の A))
const BEGIN_PREFIX: &[u8] = b"# >>> dotfiles";
const END_PREFIX: &[u8] = b"# <<< dotfiles";
const BEGIN_LINE: &str =
    "# >>> dotfiles が書く欄 (dotfiles apply のたびに書き直す。ここには書かない) >>>";
const END_LINE: &str = "# <<< dotfiles が書く欄ここまで。この行より下に生の KEY=VALUE を書く (dotfiles apply はここから下を書き換えない) <<<";
const RULE_LINE: &str = "#####################################################";
/// 欄の前置き (始まりの印の次の行から、節の手前まで)
const PREAMBLE: &[&str] = &[
    "#",
    "# マシンローカルの環境変数。git に入れない値 (API キーなど) を置く。",
    "# Windows では pjp (claude-skills の Rust の道具) がこのファイルを直に読む。シェルは読み込まない",
    "# (dotfiles の win/README.md「マシンローカルの環境変数」)。",
    "#",
    "#   - 行頭から KEY=VALUE、1 行 1 個。改行は CRLF でも LF でもよい",
    "#   - クォートしない。= の後ろは行末までそのまま値 (FOO='x' は 'x' になる)",
    "#   - 展開しない (%X% や $env:X は文字列のまま)",
    "#   - 識別子で始まらない行は黙って無視される",
    "#   - 同じ名前を 2 回書くと、後の行が勝つ",
    "#   - UTF-8 で保存する (メモ帳の既定)。UTF-16 で保存すると pjp が読めない",
    "#",
    "# 下に並ぶのは、skill が受け取る環境変数 (Linux と同じ断片から集める)。Windows で効くのは、",
    "# pjp がこのファイルから読む変数 (Notion の token など) だけ。使うものは、この欄より下へ",
    "# 「#」を外して書き写し、値を入れる。",
    "#",
];
/// Windows のエディタが頭に付ける UTF-8 の BOM
const BOM: &[u8] = b"\xef\xbb\xbf";
const LF: &[u8] = b"\n";
const CRLF: &[u8] = b"\r\n";

pub struct LocalEnv;

impl Step for LocalEnv {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "local-env",
            order: 50,
            title: "マシンローカルの環境変数 (~/.config/pjp/env) を置き、頭の dotfiles が書く欄を書き直す",
            // 読むのは claude-skills の pjp だけ (pjp を入れる手順 pjp と同じ switch)
            gate: Gate::Tool("claudePrivateSkills"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        vec![sync(ctx, mode)]
    }
}

/// 欄に入れなかった断片のわけ。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Reject {
    /// 「# 」を付けると印として読まれる行がある
    Marker,
    /// 行の途中に制御文字か U+0085・U+2028・U+2029 がある
    Control,
    /// 読めない
    Unreadable,
}

/// 欄の節を組んだ結果。
struct Sections {
    bytes: Vec<u8>,
    /// 手順の途中に出す警告 (`!!` の行と、続きの行)
    warnings: Vec<Vec<String>>,
    /// 締めの表の行に添えること
    notes: Vec<String>,
}

/// 印の間から移す行 (名前と、KEY=VALUE の形でない行の数)。
#[derive(Debug, Default, PartialEq, Eq)]
struct Rescued {
    names: Vec<String>,
    other: usize,
}

impl Rescued {
    fn is_empty(&self) -> bool {
        self.names.is_empty() && self.other == 0
    }

    /// 「FOO, BAR。ほかに KEY=VALUE の形でない行 N 行」(Linux の script の warn と同じ字)
    fn describe(&self) -> String {
        let mut s = if self.names.is_empty() {
            "(無し)".to_string()
        } else {
            self.names.join(", ")
        };
        if self.other != 0 {
            s.push_str(&format!(
                "。ほかに KEY=VALUE の形でない行 {} 行",
                self.other
            ));
        }
        s
    }
}

/// 書き上がりの決め方。
#[derive(Debug, PartialEq, Eq)]
enum Plan {
    /// 無い: 欄だけのファイルを作る
    Create(Vec<u8>),
    /// 印が 1 組: 印の間を替える (`kept` は欄の外の行の数)
    Replace {
        new: Vec<u8>,
        kept: usize,
        rescued: Rescued,
    },
    /// 印が無い: 欄を頭に足す (`kept` は今の行の数)
    Prepend { new: Vec<u8>, kept: usize },
    /// 印が 1 組になっていない (始まりの印の行・終わりの印の行。1 から数える)
    Broken {
        begins: Vec<usize>,
        ends: Vec<usize>,
    },
    /// NUL がある (UTF-16 などで保存された)
    Nul,
}

/// 手順の中身。Linux の script と同じ順に確かめる (置き場所 → symlink・普通のファイル・書けるか → 欄を組む → NUL → 印 → 書く)。
fn sync(ctx: &mut Ctx, mode: Mode) -> Outcome {
    let path = match env_path(ctx) {
        Ok(p) => p,
        Err(rel) => {
            warn(
                ctx,
                &[
                    format!("XDG_CONFIG_HOME ({rel}) が相対パスなので、{WHAT} を書きません。"),
                    "pjp は打った場所から読むことになるので、絶対パスにするか外してください。"
                        .to_string(),
                ],
            );
            return Outcome::new(
                Kind::Manual,
                format!("XDG_CONFIG_HOME が相対パス → {WHAT} を書かない"),
            )
            .note("XDG_CONFIG_HOME を絶対パスにするか外して、dotfiles apply --steps local-env");
        }
    };
    let shown = path.display().to_string();
    // 読み取り専用 (Windows の属性) は、書くことがあるときにだけ止める (値を守るために付けたファイルを、毎回 ⚠ にしない)
    let mut readonly = false;
    let current = match std::fs::symlink_metadata(&path) {
        Ok(m) if m.file_type().is_symlink() => {
            let target = std::fs::read_link(&path)
                .map(|t| t.display().to_string())
                .unwrap_or_else(|e| format!("読めない: {e}"));
            warn(
                ctx,
                &[
                    format!("{shown} は symlink なので書き換えません (指す先: {target})。"),
                    "頭の欄を足すなら、symlink をやめて実体のファイルを置いてください。"
                        .to_string(),
                ],
            );
            return Outcome::new(Kind::Manual, format!("{WHAT} が symlink → 書き換えない"));
        }
        Ok(m) if !m.is_file() => {
            warn(
                ctx,
                &[format!(
                    "{shown} が普通のファイルではないので書き換えません。"
                )],
            );
            return Outcome::new(
                Kind::Manual,
                format!("{WHAT} が普通のファイルではない → 書き換えない"),
            );
        }
        Ok(m) => {
            readonly = m.permissions().readonly();
            match std::fs::read(&path) {
                Ok(b) => Some(b),
                Err(e) => {
                    ctx.say(format!("!! 読めません: {shown} ({e})"));
                    return Outcome::new(Kind::Failed, format!("{WHAT} が読めない ({e})"));
                }
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            ctx.say(format!("!! 確かめられません: {shown} ({e})"));
            return Outcome::new(Kind::Failed, format!("{WHAT} を確かめられない ({e})"));
        }
    };

    // 改行はファイルに合わせる (CR があれば CRLF。無い・新しいファイルは LF)
    let eol = match &current {
        Some(b) if b.contains(&b'\r') => CRLF,
        _ => LF,
    };
    let skills = join_segments(&ctx.roots.user_profile, SKILLS_REL);
    let sections = render_sections(&skills, eol);
    for w in &sections.warnings {
        warn(ctx, w);
    }
    let block = render_block(&sections.bytes, eol);
    let plan = plan(current.as_deref(), &block);

    let mut o = match plan {
        Plan::Broken { begins, ends } => {
            let lines = |v: &[usize]| {
                if v.is_empty() {
                    "無し".to_string()
                } else {
                    v.iter().map(usize::to_string).collect::<Vec<_>>().join(",")
                }
            };
            warn(
                ctx,
                &[
                    format!(
                        "{shown} の印の行が 1 組になっていないので、書き換えません (# >>> dotfiles の行: {}、# <<< dotfiles の行: {})。",
                        lines(&begins),
                        lines(&ends)
                    ),
                    "直すには、印の行を 1 組だけ残すか、欄ごと消して印の無い形に戻し、dotfiles apply --steps local-env で流し直してください。".to_string(),
                ],
            );
            Outcome::new(
                Kind::Manual,
                format!("{WHAT} の印の行が 1 組になっていない → 書き換えない"),
            )
            .note("印の行を 1 組だけ残すか、欄ごと消してから dotfiles apply --steps local-env")
        }
        Plan::Nul => {
            warn(
                ctx,
                &[
                    format!("{shown} に NUL があるので書き換えません (UTF-16 で保存された、など)。"),
                    "UTF-16 で保存したなら、メモ帳の「名前を付けて保存」で文字コードを UTF-8 にして保存し直してください。Windows PowerShell 5.1 の >> などで UTF-16 の行を足したなら、その行を消して書き直してください (前の版は env.bak)。直したら dotfiles apply --steps local-env で流し直してください (pjp も NUL のあるファイルは読めません)。".to_string(),
                ],
            );
            Outcome::new(
                Kind::Manual,
                format!("{WHAT} が UTF-16 などで保存されている (NUL がある) → 書き換えない"),
            )
            .note("メモ帳で UTF-8 にして保存し直すか、UTF-16 で足した行を消して書き直してから dotfiles apply --steps local-env")
        }
        Plan::Create(new) => write_plan(ctx, mode, &path, None, &new, Change::Create, false),
        Plan::Replace { new, kept, rescued } => {
            let o = write_plan(
                ctx,
                mode,
                &path,
                current.as_deref(),
                &new,
                Change::Replace { kept },
                readonly,
            );
            rescue_notes(ctx, mode, o, &shown, &rescued)
        }
        Plan::Prepend { new, kept } => write_plan(
            ctx,
            mode,
            &path,
            current.as_deref(),
            &new,
            Change::Prepend { kept },
            readonly,
        ),
    };
    if mode.writes() && o.kind == Kind::Ok {
        ctx.say("");
        ctx.say("値を足すには (pjp は打つたびに読むので、開き直しは要らない):");
        ctx.say(format!("  notepad \"{shown}\""));
    }
    if !sections.notes.is_empty() {
        if o.kind == Kind::Ok {
            o.kind = Kind::Manual;
            o.text.push_str(" (欄に入れなかった断片がある)");
        }
        o.notes.extend(sections.notes);
    }
    o
}

/// 書くことの種類 (出す字が変わる)。
#[derive(Clone, Copy)]
enum Change {
    Create,
    Replace { kept: usize },
    Prepend { kept: usize },
}

/// 書き上がり `new` を、mode に従って書く (同じなら何もしない)。前の版 (`current`) があれば env.bak へ写してから書く。書けない形
/// (読み取り専用・env.bak がディレクトリ) は、check と dry-run でも apply と同じく止める理由を出す。
fn write_plan(
    ctx: &mut Ctx,
    mode: Mode,
    path: &Path,
    current: Option<&[u8]>,
    new: &[u8],
    change: Change,
    readonly: bool,
) -> Outcome {
    let shown = path.display().to_string();
    let bak = path.with_file_name(BAK);
    let bak_shown = bak.display().to_string();
    if current == Some(new) {
        ctx.say(format!("欄は最新です: {shown}"));
        return Outcome::new(Kind::Ok, format!("{WHAT} の欄は最新"));
    }
    if readonly {
        warn(
            ctx,
            &[
                format!("{shown} は読み取り専用なので書き換えません。"),
                format!(
                    "書き換えてよければ、エクスプローラーのプロパティで「読み取り専用」を外すか attrib -r \"{shown}\" を打ち、dotfiles apply --steps local-env で流し直してください。"
                ),
            ],
        );
        return Outcome::new(
            Kind::Manual,
            format!("{WHAT} が読み取り専用 → 書き換えない"),
        )
        .note(format!(
            "attrib -r \"{shown}\" で外してから dotfiles apply --steps local-env"
        ));
    }
    // ディレクトリへ写すと、その中へ写しが溜まっていく (1 世代だけ、が崩れる。Linux と同じ)
    if current.is_some() && bak.is_dir() {
        warn(
            ctx,
            &[
                format!(
                    "{bak_shown} がディレクトリなので前の版を写せず、{shown} を書き換えません。"
                ),
                format!(
                    "{bak_shown} をどけてから、dotfiles apply --steps local-env で流し直してください。"
                ),
            ],
        );
        return Outcome::new(
            Kind::Manual,
            format!("env.bak がディレクトリ → {WHAT} を書き換えない"),
        )
        .note(format!(
            "{bak_shown} をどけてから dotfiles apply --steps local-env"
        ));
    }
    let (kind, state, todo) = match change {
        Change::Create => (Kind::Missing, "が無い", "作る"),
        Change::Replace { .. } => (Kind::Fix, "の欄が古い", "書き直す"),
        Change::Prepend { .. } => (Kind::Fix, "に欄が無い", "頭に足す"),
    };
    match mode {
        Mode::Check => {
            ctx.say(format!("{WHAT}{state} (apply で{todo}): {shown}"));
            return Outcome::new(kind, format!("{WHAT}{state} → apply で{todo}"));
        }
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] {todo}: {shown}"));
            return Outcome::new(kind, format!("[dry-run] {WHAT}{state} → {todo}"));
        }
        Mode::Apply { .. } => {}
    }
    if let Some(cur) = current
        && let Err(e) = fsutil::write_atomic(&bak, cur)
    {
        ctx.say(format!(
            "!! 前の版を {bak_shown} へ写せないので、{shown} を書き換えません ({e})。"
        ));
        return Outcome::new(
            Kind::Failed,
            format!("前の版を env.bak へ写せない → {WHAT} を書き換えない ({e})"),
        );
    }
    if let Err(e) = fsutil::write_atomic(path, new) {
        ctx.say(format!(
            "!! {shown} を書けませんでした (中身は元のまま): {e}"
        ));
        return Outcome::new(Kind::Failed, format!("{WHAT} を書けない ({e})"));
    }
    match change {
        Change::Create => {
            ctx.say(format!("作りました: {shown}"));
            Outcome::new(Kind::Ok, format!("{WHAT} を作った"))
                .note("値 (PJP_NOTION_TOKEN_<名前> など) は欄より下に書く")
        }
        Change::Replace { kept } => {
            ctx.say(format!(
                "欄を書き直しました: {shown} (欄の外の {kept} 行には触れていません。前の版は {bak_shown})"
            ));
            Outcome::new(Kind::Ok, format!("{WHAT} の欄を書き直した"))
        }
        Change::Prepend { kept } => {
            ctx.say(format!(
                "印が無かったので、欄を頭に足しました: {shown} (今あった {kept} 行はすべて欄の下に残しています。前の版は {bak_shown})"
            ));
            Outcome::new(Kind::Ok, format!("{WHAT} の頭に欄を足した"))
        }
    }
}

/// 印の間から移す行を知らせる (apply は移した後に `!!` で、check と dry-run は行に添えるだけ)。値は出さない。
fn rescue_notes(ctx: &mut Ctx, mode: Mode, o: Outcome, shown: &str, rescued: &Rescued) -> Outcome {
    if rescued.is_empty() {
        return o;
    }
    let moved = rescued.describe();
    if mode.writes() && o.kind == Kind::Ok {
        warn(
            ctx,
            &[
                format!(
                    "{shown} の欄の中に書かれていた行を、欄のすぐ下へ移しました: {moved} (値は出しません)。"
                ),
                "欄 (# >>> dotfiles から # <<< dotfiles まで) は dotfiles apply が書き直すので、値は欄より下に書いてください。".to_string(),
            ],
        );
        o.note(format!(
            "欄の中に書かれていた行を欄のすぐ下へ移した: {moved} (値は出さない)。値は欄より下に書く"
        ))
    } else if !mode.writes() && o.kind == Kind::Fix {
        o.note(format!(
            "apply で、欄の中に書かれている行を欄のすぐ下へ移す: {moved} (値は出さない)"
        ))
    } else {
        o
    }
}

/// 置き場所。`XDG_CONFIG_HOME` が空でなければその下 (pjp と同じ)、無ければ `%USERPROFILE%\.config`。相対パスなら Err (その値)。
/// 手順 notion-tokens も同じ置き場所を見る。
pub(super) fn env_path(ctx: &Ctx) -> Result<PathBuf, String> {
    match ctx.sys.env("XDG_CONFIG_HOME").filter(|v| !v.is_empty()) {
        Some(v) if Path::new(&v).is_absolute() => Ok(PathBuf::from(v).join("pjp").join("env")),
        Some(v) => Err(v),
        None => Ok(join_segments(&ctx.roots.user_profile, REL)),
    }
}

/// 手順を止めない警告を、Linux の script の warn と同じ形で出す (1 行目の頭に `!!`、続きの行は 3 字下げ)。
pub(super) fn warn(ctx: &mut Ctx, lines: &[String]) {
    for (i, l) in lines.iter().enumerate() {
        if i == 0 {
            ctx.say(format!("!! {l}"));
        } else {
            ctx.say(format!("   {l}"));
        }
    }
}

/// skill の断片から欄の節を組む (名前の順)。
fn render_sections(skills: &Path, eol: &[u8]) -> Sections {
    let mut s = Sections {
        bytes: Vec::new(),
        warnings: Vec::new(),
        notes: Vec::new(),
    };
    let mut found: Vec<(String, PathBuf)> = Vec::new();
    let mut odd: Vec<PathBuf> = Vec::new();
    if let Ok(rd) = std::fs::read_dir(skills) {
        for entry in rd.flatten() {
            let name = entry.file_name();
            let dir = entry.path();
            // glob の * と同じく . で始まるものは見ない。切れた symlink・junction はディレクトリでないので飛ばす
            if name.to_string_lossy().starts_with('.') || !dir.is_dir() {
                continue;
            }
            let file = dir.join(FRAGMENT);
            if !file.is_file() {
                continue;
            }
            match name.to_str().filter(|n| valid_name(n)) {
                Some(n) => found.push((n.to_string(), file)),
                None => odd.push(dir),
            }
        }
    }
    odd.sort();
    for dir in odd {
        // 名前は見出しの行にそのまま入るので、改行などを含む名前は入れない (見出しから生きた行が生まれる)
        let shown = escape_controls(&dir.display().to_string());
        s.warnings.push(vec![
            format!("{shown} は {WHAT} の欄に入れません。"),
            "skill のディレクトリ名に英数字と . _ - 以外の文字 (改行など) があり、欄の見出しが壊れるため。".to_string(),
        ]);
        s.notes.push(format!(
            "{shown} の pjp-env.txt は欄に入れなかった (skill のディレクトリ名に英数字と . _ - 以外の文字がある)"
        ));
    }
    found.sort();
    for (name, file) in found {
        let shown = file.display().to_string();
        let rendered = match std::fs::read(&file) {
            Ok(b) => render_fragment(&format!("skill: {name}"), &b, eol),
            Err(_) => Err(Reject::Unreadable),
        };
        match rendered {
            Ok(Some(b)) => s.bytes.extend(b),
            Ok(None) => {}
            Err(r) => {
                let (warning, why) = match r {
                    Reject::Marker => (
                        vec![
                            format!("{shown} は {WHAT} の欄に入れません。"),
                            "印と同じ頭 (>>> dotfiles / <<< dotfiles) で始まる行があり、欄が壊れるため。その行の頭を変えてください。".to_string(),
                        ],
                        "印と同じ頭で始まる行がある",
                    ),
                    Reject::Control => (
                        vec![
                            format!("{shown} は {WHAT} の欄に入れません。"),
                            "行の途中に制御文字 (CR・NUL・改ページ・U+2028 など) があり、pjp (Notion の宛先の resolver) がそこで行を分けて、欄の中に生きた変数が生まれうるため。その文字を消してください。".to_string(),
                        ],
                        "行の途中に制御文字がある",
                    ),
                    Reject::Unreadable => (
                        vec![format!("{shown} を読めないので、{WHAT} の欄に入れません。")],
                        "読めない",
                    ),
                };
                s.warnings.push(warning);
                s.notes.push(format!(
                    "{name} の pjp-env.txt は欄に入れなかった ({why})。skill の断片を直す"
                ));
            }
        }
    }
    s
}

/// 制御文字 (改行など) を `\\n` の形にする (Linux の printf '%q' の代わり。出す行を壊さない)
fn escape_controls(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_control() {
                c.escape_default().to_string()
            } else {
                c.to_string()
            }
        })
        .collect()
}

/// skill のディレクトリ名として欄の見出しに入れてよいか (Linux と同じ `^[A-Za-z0-9._-]+$`)
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// 断片 1 つの節 (見出し・前後の「#」の行を含む)。行末の CR と 1 行目の頭の BOM を外し、先頭と末尾の空行を落とし、空行は「#」、ほかは
/// 「# 」+ 行にする。空 (空行だけ) なら None。印に化ける行・行の途中の制御文字を持つ断片は Err (Linux の awk と同じく、バイトで見る)。
fn render_fragment(heading: &str, bytes: &[u8], eol: &[u8]) -> Result<Option<Vec<u8>>, Reject> {
    let mut lines: Vec<&[u8]> = bytes.split(|b| *b == b'\n').collect();
    // 末尾の改行の後ろは行にしない (awk の行と同じ)
    if lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    let lines: Vec<&[u8]> = lines
        .iter()
        .enumerate()
        .map(|(i, l)| {
            let l = l.strip_suffix(b"\r").unwrap_or(l);
            if i == 0 {
                l.strip_prefix(BOM).unwrap_or(l)
            } else {
                l
            }
        })
        .collect();
    let blank = |l: &[u8]| l.iter().all(|b| matches!(b, b' ' | b'\t'));
    let Some(first) = lines.iter().position(|l| !blank(l)) else {
        return Ok(None);
    };
    let last = lines.iter().rposition(|l| !blank(l)).unwrap_or(first);
    let body = &lines[first..=last];
    for l in body {
        if l.starts_with(b">>> dotfiles") || l.starts_with(b"<<< dotfiles") {
            return Err(Reject::Marker);
        }
        if breaks_line(l) {
            return Err(Reject::Control);
        }
    }
    let mut out = Vec::new();
    push_line(&mut out, format!("# ---- {heading} ----").as_bytes(), eol);
    push_line(&mut out, b"#", eol);
    for l in body {
        if blank(l) {
            push_line(&mut out, b"#", eol);
        } else {
            out.extend_from_slice(b"# ");
            push_line(&mut out, l, eol);
        }
    }
    push_line(&mut out, b"#", eol);
    Ok(Some(out))
}

/// pjp (Python の str.splitlines と同じ字) が行を分けうる字か、ほかの制御文字 (タブを除く) を持つか
fn breaks_line(l: &[u8]) -> bool {
    l.iter()
        .any(|b| matches!(b, 0x00..=0x08 | 0x0b..=0x1f | 0x7f))
        || [&b"\xc2\x85"[..], b"\xe2\x80\xa8", b"\xe2\x80\xa9"]
            .iter()
            .any(|seq| l.windows(seq.len()).any(|w| w == *seq))
}

fn push_line(out: &mut Vec<u8>, line: &[u8], eol: &[u8]) {
    out.extend_from_slice(line);
    out.extend_from_slice(eol);
}

/// 欄の全体 (始まりの印から終わりの印まで。終わりの印の後ろにも改行を付ける)
fn render_block(sections: &[u8], eol: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    push_line(&mut out, BEGIN_LINE.as_bytes(), eol);
    for l in PREAMBLE {
        push_line(&mut out, l.as_bytes(), eol);
    }
    out.extend_from_slice(sections);
    push_line(&mut out, RULE_LINE.as_bytes(), eol);
    push_line(&mut out, END_LINE.as_bytes(), eol);
    out
}

/// 今の中身 (`None` は無い) と新しい欄から、書き上がりを決める。
fn plan(current: Option<&[u8]>, block: &[u8]) -> Plan {
    let Some(cur) = current else {
        return Plan::Create(block.to_vec());
    };
    // NUL があるなら UTF-16 などで保存されている。UTF-8 の欄を足すと文字コードが混ざるので書かない
    if cur.contains(&0) {
        return Plan::Nul;
    }
    // 行 (改行を含む)。awk の行と同じく、末尾の改行の後ろは行にしない
    let lines: Vec<&[u8]> = cur.split_inclusive(|b| *b == b'\n').collect();
    let mut begins = Vec::new();
    let mut ends = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        let p = plain(l, i == 0);
        if p.starts_with(BEGIN_PREFIX) {
            begins.push(i + 1);
        }
        if p.starts_with(END_PREFIX) {
            ends.push(i + 1);
        }
    }
    match (begins.as_slice(), ends.as_slice()) {
        ([b], [e]) if b < e => {
            let (b, e) = (*b, *e);
            let mut new = Vec::new();
            for l in &lines[..b - 1] {
                new.extend_from_slice(l);
            }
            new.extend_from_slice(block);
            // 印の間のユーザーの行は、終わりの印のすぐ下 (下の行より前) へ移し、後の行が勝つ順を変えない
            let mut rescued = Rescued::default();
            for l in &lines[b..e - 1] {
                let content = l.strip_suffix(b"\n").unwrap_or(l);
                if content.iter().all(|c| matches!(c, b' ' | b'\t' | b'\r'))
                    || content.first() == Some(&b'#')
                {
                    continue;
                }
                new.extend_from_slice(l);
                match key_name(content) {
                    Some(n) => rescued.names.push(n),
                    None => rescued.other += 1,
                }
            }
            for l in &lines[e..] {
                new.extend_from_slice(l);
            }
            Plan::Replace {
                new,
                kept: b - 1 + lines.len() - e,
                rescued,
            }
        }
        ([], []) => {
            let mut new = block.to_vec();
            new.extend_from_slice(cur.strip_prefix(BOM).unwrap_or(cur));
            Plan::Prepend {
                new,
                kept: lines.len(),
            }
        }
        _ => Plan::Broken { begins, ends },
    }
}

/// 印と見分けるための行 (改行・行末の CR・1 行目の頭の BOM を外す)
fn plain(line: &[u8], first: bool) -> &[u8] {
    let l = line.strip_suffix(b"\n").unwrap_or(line);
    let l = l.strip_suffix(b"\r").unwrap_or(l);
    if first {
        l.strip_prefix(BOM).unwrap_or(l)
    } else {
        l
    }
}

/// `KEY=VALUE` の形の行の名前。= の後ろが空か = だけの行は (後ろに空白・タブ・CR が続いても) 名前として数えない (KEY= を付けずに貼った
/// パディング付きの base64 の値 (abc…XYZ==。写した値の行末に空白が付くこともある) は識別子の形に見え、名前として出すと値そのものを出す
/// ことになるため。Linux の script と同じ)
fn key_name(content: &[u8]) -> Option<String> {
    let eq = content.iter().position(|b| *b == b'=')?;
    let key = &content[..eq];
    let ok = key
        .first()
        .is_some_and(|b| b.is_ascii_alphabetic() || *b == b'_')
        && key.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_');
    if !ok {
        return None;
    }
    let rest = &content[eq + 1..];
    let end = rest
        .iter()
        .rposition(|b| !matches!(b, b' ' | b'\t' | b'\r'))
        .map_or(0, |i| i + 1);
    if rest[..end].iter().all(|b| *b == b'=') {
        return None;
    }
    Some(String::from_utf8_lossy(key).into_owned())
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! 欄を組む (Linux の nix/tests/bootstrap-local-env.test.sh の T1〜T5c を写したもの):
    //!
    //! - ファイルが無ければ、欄だけのファイルを作る (check と dry-run は書かない)。1 行目と最後の行は印で、すべての行が # で始まり、
    //!   pjp が読む行は 1 つも無い。改行は LF で、env.bak は作らない
    //! - 節は skill のディレクトリ名の順。つないだ skill (Windows は junction、Unix は symlink) の断片も読む。pjp-env.txt の無い skill・
    //!   空の断片・. で始まるディレクトリ・ディレクトリでないもの・先の消えたつなぎは節を作らない。dotfiles の節 (nix/pjp-env/dotfiles.txt)
    //!   は入れない
    //! - 断片の各行に「# 」を付ける (空行は「#」、先頭と末尾の空行は落とす)。FOO=bar と書いても欄では # FOO=bar
    //! - CRLF の断片・頭に BOM のある断片でも、欄の行に CR と BOM は混ざらず、末尾に改行の無い最後の行も落ちない
    //! - 印として読まれる行・行の途中の制御文字 (CR・NUL など) か U+0085・U+2028・U+2029 を持つ断片は入れず、!! で知らせて行に添える
    //!   (書いた後も ⚠)。名前に英数字と . _ - 以外の字がある skill のディレクトリも同じ
    //!
    //! 今あるファイルを書き直す (同じく T7〜T18 を写し、Windows の決まりを足したもの):
    //!
    //! - 印が 1 組なら印の間だけが替わる。始まりの印より上と、終わりの印より下はバイトで同じ。前の版は env.bak
    //! - 改行はファイルに合わせる (CR があれば欄も CRLF)
    //! - 印の間の # でない行は、元の順・元のバイトのまま終わりの印のすぐ下へ移り、変数名だけを知らせる (KEY=VALUE の形でない行と
    //!   = だけで終わる行は数だけ)。check と dry-run は移す名前を添えるだけで書かない
    //! - 書き上がりが今と同じなら何も書かない (更新時刻も env.bak も変わらない)
    //! - 頭の BOM: 印が頭なら印として見分け、書き直した欄の頭に BOM は付かない。印の無いファイルに欄を足すときも外す (pjp は
    //!   ファイルの頭の BOM しか外さないので、欄の下に残すとその行を読めない)
    //! - 印の無いファイル・空のファイルは、欄を頭に足す (今の中身はバイトで同じまま欄の下に残る)
    //! - 次のときは書かずに知らせる (中身はバイトで同じ、env.bak も作らない): 印が壊れている (始まりだけ・2 組・終わりが先。両方の
    //!   印の行番号)・symlink (Windows でファイルの symlink を張れなければ飛ばす)・普通のファイルでない・読み取り専用・NUL を含む
    //!   (UTF-16 など)・env.bak がディレクトリ
    //! - 置き場所は XDG_CONFIG_HOME (空でない絶対パス) の下、無ければ %USERPROFILE%\.config。相対パスなら書かない
    //! - 値は出力にも行にも出さない
    //! - 書き直した後に pjp が読むのは、欄の外の行だけ
    //! - Linux の CI で、bash の版 (nix/scripts/bootstrap-local-env.sh) と同じ入力から、欄の外のバイト・skill の節・移した名前・
    //!   書いたか・印の行番号が同じか

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::process::{CommandSpec, Exit};
    use crate::testutil::{FakeSys, TempDir, fake_file_symlink, fake_mklink};
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime};

    /// 値を出していないかを確かめるための、試験用の秘密の値
    const SECRET: &str = "ntn_test_secret_do_not_print";
    const BOM_STR: &str = "\u{feff}";
    const BEGIN: &str =
        "# >>> dotfiles が書く欄 (dotfiles apply のたびに書き直す。ここには書かない) >>>";
    const END: &str = "# <<< dotfiles が書く欄ここまで。この行より下に生の KEY=VALUE を書く (dotfiles apply はここから下を書き換えない) <<<";
    /// 標準の断片の組から組んだ節と、欄の終わり (LF)
    const SECTIONS: &str = "# ---- skill: alpha ----\n#\n# alpha が読む変数。取り得る値: パス。\n# ALPHA_PATH=xxxxxx\n#\n\
        # ---- skill: crlf ----\n#\n# crlf の変数。\n# CRLF_LAST=xxxxxx\n#\n\
        # ---- skill: zeta ----\n#\n# zeta が読む変数。取り得る値: 何でも。\n# FOO=bar\n#\n# zeta の 2 つめ。\n# ZETA_TWO=xxxxxx\n#\n\
        #####################################################\n";

    /// 1 ケースぶんの場所 (ホーム・skill・dotfiles の clone)。
    struct Case {
        t: TempDir,
    }

    impl Case {
        /// 標準の断片の組を置いたケース (Linux の試験の new_case と同じ中身。印に化ける断片 bad は別に足す)
        fn new(tag: &str) -> Self {
            let c = Case {
                t: TempDir::new(tag),
            };
            c.skill(
                "alpha",
                "alpha が読む変数。取り得る値: パス。\nALPHA_PATH=xxxxxx\n".as_bytes(),
            );
            c.skill(
                "zeta",
                "\n\nzeta が読む変数。取り得る値: 何でも。\nFOO=bar\n\nzeta の 2 つめ。\nZETA_TWO=xxxxxx\n\n".as_bytes(),
            );
            c.skill("empty", b"\n  \n\n");
            std::fs::create_dir_all(c.skills().join("noenv")).unwrap();
            // Windows のエディタで保存した形 (頭に BOM、CRLF、末尾に改行が無い)
            c.skill(
                "crlf",
                "\u{feff}crlf の変数。\r\nCRLF_LAST=xxxxxx".as_bytes(),
            );
            // . で始まるディレクトリ (glob の * に当たらない) と、ディレクトリでないもの
            c.skill(".hidden", b"HIDDEN=xxxxxx\n");
            std::fs::write(c.skills().join("plainfile"), b"x").unwrap();
            // dotfiles の断片は Windows の欄に入れない
            c.t.write(
                "dotfiles/nix/pjp-env/dotfiles.txt",
                "テスト用の変数。\nTEST_DOTFILES_ONE=xxxxxx\n",
            );
            c
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        fn skills(&self) -> PathBuf {
            self.home().join(".claude").join("skills")
        }

        fn dir(&self) -> PathBuf {
            self.home().join(".config").join("pjp")
        }

        fn env_file(&self) -> PathBuf {
            self.dir().join("env")
        }

        fn bak(&self) -> PathBuf {
            self.dir().join("env.bak")
        }

        fn skill(&self, name: &str, fragment: &[u8]) {
            let d = self.skills().join(name);
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("pjp-env.txt"), fragment).unwrap();
        }

        fn put(&self, bytes: &[u8]) {
            std::fs::create_dir_all(self.dir()).unwrap();
            std::fs::write(self.env_file(), bytes).unwrap();
        }

        fn read(&self) -> Vec<u8> {
            std::fs::read(self.env_file()).unwrap()
        }

        fn run(&self, mode: Mode) -> (Outcome, String) {
            self.run_with(&FakeSys::new(|_| unreachable!()), mode)
        }

        fn run_with(&self, sys: &FakeSys, mode: Mode) -> (Outcome, String) {
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys,
                    out: &mut out,
                };
                let mut v = LocalEnv.run(&mut ctx, mode);
                assert_eq!(v.len(), 1, "{v:?}");
                v.remove(0)
            };
            let out = String::from_utf8(out).unwrap();
            assert_quiet(&o, &out);
            (o, out)
        }
    }

    const APPLY: Mode = Mode::Apply { force: false };
    const DRY: Mode = Mode::DryRun { force: false };

    /// 値 (SECRET) が出力にも行にも出ていない
    fn assert_quiet(o: &Outcome, out: &str) {
        assert!(!out.contains(SECRET), "出力に値が出た: {out}");
        assert!(!o.text.contains(SECRET), "行に値が出た: {o:?}");
        for n in &o.notes {
            assert!(!n.contains(SECRET), "※ に値が出た: {n}");
        }
    }

    /// pjp (claude-skills の skills/pjp-notion-profile/rust/src/auth.rs の read_env_file) が読む名前を、上から順に。頭の BOM を外し、
    /// Python の str.splitlines と同じ字で行を分け、識別子で始まる KEY= の行だけを読む
    fn pjp_names(bytes: &[u8]) -> Vec<String> {
        let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
        let text = String::from_utf8_lossy(bytes);
        assert!(!text.contains('\0'), "pjp は NUL のあるファイルで止まる");
        let breaks = [
            '\n', '\r', '\u{0b}', '\u{0c}', '\u{1c}', '\u{1d}', '\u{1e}', '\u{85}', '\u{2028}',
            '\u{2029}',
        ];
        text.split(|c| breaks.contains(&c))
            .filter_map(|l| {
                let (k, _) = l.split_once('=')?;
                let mut cs = k.chars();
                let ok = cs
                    .next()
                    .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
                    && cs.all(|c| c.is_ascii_alphanumeric() || c == '_');
                ok.then(|| k.to_string())
            })
            .collect()
    }

    /// 行に分ける (改行を外す。CR は残す)
    fn lines(bytes: &[u8]) -> Vec<String> {
        String::from_utf8_lossy(bytes)
            .split('\n')
            .map(str::to_string)
            .collect()
    }

    /// 始まりの印の行の手前まで (バイトのまま)
    fn above(bytes: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        for l in bytes.split_inclusive(|b| *b == b'\n') {
            let plain = l.strip_prefix(b"\xef\xbb\xbf").unwrap_or(l);
            if plain.starts_with(b"# >>> dotfiles") {
                break;
            }
            out.extend_from_slice(l);
        }
        out
    }

    /// 終わりの印 (1 つめ) の次の行から最後まで (バイトのまま)
    fn below(bytes: &[u8]) -> Vec<u8> {
        let mut it = bytes.split_inclusive(|b| *b == b'\n');
        for l in it.by_ref() {
            if l.starts_with(b"# <<< dotfiles") {
                break;
            }
        }
        it.flat_map(|l| l.iter().copied()).collect()
    }

    /// 欄の節 (最初の「# ---- 」の行から ##### の行まで。CR は外す)
    fn sections(bytes: &[u8]) -> String {
        let text = String::from_utf8_lossy(bytes).replace('\r', "");
        let start = text.find("# ---- ").unwrap_or_else(|| {
            text.find("#####")
                .unwrap_or_else(|| panic!("節も ##### も無い: {text}"))
        });
        let end = text[start..].find("#####").unwrap() + start;
        let line_end = text[end..].find('\n').unwrap() + end + 1;
        text[start..line_end].to_string()
    }

    /// `link` に `target` のディレクトリをつなぐ (Windows は claude-skills と同じ junction (本物の `cmd /c mklink /J`)、Unix は symlink)
    fn link_dir(link: &Path, target: &Path) {
        let spec = CommandSpec::new("cmd")
            .arg("/c")
            .arg("mklink")
            .arg("/J")
            .arg(link)
            .arg(target);
        let made = fake_mklink(&spec).unwrap();
        assert_eq!(made.exit, Exit::Code(0), "{made:?}");
    }

    fn mtime(p: &Path) -> SystemTime {
        std::fs::metadata(p).unwrap().modified().unwrap()
    }

    fn set_old_mtime(p: &Path) {
        let old = SystemTime::UNIX_EPOCH + Duration::from_secs(946_684_800);
        std::fs::File::options()
            .write(true)
            .open(p)
            .unwrap()
            .set_modified(old)
            .unwrap();
    }

    #[test]
    fn creates_a_block_only_file() {
        let c = Case::new("local-env-create");
        for mode in [Mode::Check, DRY] {
            let (o, _) = c.run(mode);
            assert_eq!(o.kind, Kind::Missing, "{mode:?} {o:?}");
            assert!(!c.env_file().exists(), "{mode:?} で書いた");
        }
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        assert!(out.contains("作りました: "), "{out}");
        let got = c.read();
        let ls = lines(&got);
        assert_eq!(ls.first().map(String::as_str), Some(BEGIN));
        // 最後の行 (末尾の改行の後ろの空) の手前が終わりの印
        assert_eq!(ls[ls.len() - 2], END, "{ls:?}");
        assert_eq!(ls.last().map(String::as_str), Some(""));
        assert!(
            ls[..ls.len() - 1].iter().all(|l| l.starts_with('#')),
            "{ls:?}"
        );
        assert!(pjp_names(&got).is_empty(), "{:?}", pjp_names(&got));
        assert!(!got.contains(&b'\r'), "新しいファイルは LF");
        assert!(!got.starts_with(b"\xef\xbb\xbf"));
        assert!(!c.bak().exists());
        assert_eq!(sections(&got), SECTIONS);
        // もう一度は書かない
        let (o, out) = c.run(Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(out.contains("欄は最新です: "), "{out}");
    }

    #[test]
    fn sections_follow_skill_names_without_dotfiles() {
        let c = Case::new("local-env-order");
        // つないだ skill (clone の中。Windows は claude-files・claude-skills と同じ junction、Unix は symlink) と、先の消えたつなぎ
        let clone = c.t.path().join("clone").join("skills");
        let linked = clone.join("linked");
        std::fs::create_dir_all(&linked).unwrap();
        std::fs::write(
            linked.join("pjp-env.txt"),
            "linked が読む変数。\nLINKED=xxxxxx\n",
        )
        .unwrap();
        link_dir(&c.skills().join("linked"), &linked);
        let gone = clone.join("gone");
        std::fs::create_dir_all(&gone).unwrap();
        std::fs::write(gone.join("pjp-env.txt"), "GONE=xxxxxx\n").unwrap();
        link_dir(&c.skills().join("broken"), &gone);
        std::fs::remove_dir_all(&gone).unwrap();
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        let headings: Vec<String> = lines(&c.read())
            .into_iter()
            .filter(|l| l.starts_with("# ---- "))
            .collect();
        assert_eq!(
            headings,
            vec![
                "# ---- skill: alpha ----",
                "# ---- skill: crlf ----",
                "# ---- skill: linked ----",
                "# ---- skill: zeta ----",
            ]
        );
        assert!(
            !out.contains("broken"),
            "先の消えたつなぎは黙って飛ばす: {out}"
        );
        assert!(!out.contains("!! "), "{out}");
    }

    #[test]
    fn rejects_fragments_that_would_break_the_block() {
        let c = Case::new("local-env-reject");
        c.skill(
            "bad",
            "bad の変数。\n<<< dotfiles を足す\nBAD=xxxxxx\n".as_bytes(),
        );
        // pjp は CR・U+2028 でも行を分けるので、欄の中に生きた変数が生まれうる。NUL は次の回に UTF-16 と見てしまう
        c.skill(
            "ctrl",
            "ctrl の変数。\rPJP_NOTION_TOKEN_PERSONAL=bogus\n".as_bytes(),
        );
        c.skill("uline", "uline の変数。\u{2028}Z_INJECT=1\n".as_bytes());
        // NUL は Windows では予約された名前 (ディレクトリにできない) なので、名前は nulchar
        c.skill("nulchar", b"nul \0 NUL_INJECT=1\n");
        // 名前が見出しを壊しうる (英数字と . _ - 以外)
        c.skill("my skill", b"SPACE=xxxxxx\n");
        let (o, out) = c.run(APPLY);
        let got = c.read();
        for name in ["bad", "ctrl", "uline", "nulchar"] {
            assert!(
                out.lines()
                    .any(|l| l.starts_with("!! ") && l.contains(name) && l.contains("pjp-env.txt")),
                "{name}: {out}"
            );
            assert!(
                !String::from_utf8_lossy(&got).contains(&format!("skill: {name}")),
                "{name} の節がある"
            );
            assert!(
                o.notes
                    .iter()
                    .any(|n| n.contains(&format!("{name} の pjp-env.txt"))),
                "{name}: {o:?}"
            );
        }
        assert!(out.contains("my skill"), "{out}");
        assert!(!String::from_utf8_lossy(&got).contains("SPACE"));
        // 書いたうえで、直すことがある行にする
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert_eq!(sections(&got), SECTIONS);
        let text = String::from_utf8_lossy(&got);
        assert_eq!(text.matches("# >>> dotfiles").count(), 1);
        assert_eq!(text.matches("# <<< dotfiles").count(), 1);
        assert!(
            !got.iter()
                .any(|b| matches!(b, 0x00..=0x08 | 0x0b..=0x1f | 0x7f)),
            "欄に制御文字がある"
        );
        for seq in ["\u{85}", "\u{2028}", "\u{2029}"] {
            assert!(!text.contains(seq));
        }
        assert!(pjp_names(&got).is_empty(), "{:?}", pjp_names(&got));
    }

    #[cfg(unix)]
    #[test]
    fn rejects_skill_dirs_with_a_newline_in_the_name() {
        let c = Case::new("local-env-nl");
        c.skill("nl\nINJECT_NL=1", b"NL=xxxxxx\n");
        let (_, out) = c.run(APPLY);
        let got = c.read();
        assert!(!String::from_utf8_lossy(&got).contains("INJECT_NL"));
        assert!(out.contains("!! "), "{out}");
        assert!(pjp_names(&got).is_empty());
    }

    #[test]
    fn replaces_only_between_the_markers() {
        let c = Case::new("local-env-replace");
        let before = format!(
            "ABOVE_VAR=1\r\n# above\n{BEGIN}\n# old text\n{END}\nPJP_NOTION_TOKEN_PERSONAL={SECRET}\n# 会社の PC 用\n#PJP_NOTION_TOKEN_WORK={SECRET}\nCRLF_VAR=1\r\nLAST_VAR=2"
        );
        c.put(before.as_bytes());
        let (o, out) = c.run(Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{o:?}\n{out}");
        assert_eq!(c.read(), before.as_bytes(), "check で書いた");
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        assert!(out.contains("欄を書き直しました: "), "{out}");
        assert!(!out.contains("移しました"), "{out}");
        let got = c.read();
        assert_eq!(above(&got), b"ABOVE_VAR=1\r\n# above\n");
        assert_eq!(below(&got), below(before.as_bytes()));
        let text = String::from_utf8_lossy(&got).into_owned();
        assert!(!text.contains("# old text"));
        assert!(!text.contains("# ---- dotfiles ----"));
        assert_eq!(sections(&got), SECTIONS);
        // CR のあるファイルなので、欄も CRLF
        let block_start = text.find("# >>> dotfiles").unwrap();
        let block_end = text.find("# <<< dotfiles").unwrap();
        let block = &text[block_start..block_end];
        assert!(!block.is_empty());
        assert_eq!(
            block.matches('\n').count(),
            block.matches("\r\n").count(),
            "{block:?}"
        );
        assert!(text[block_end..].starts_with(&format!("{END}\r\n")));
        assert_eq!(std::fs::read(c.bak()).unwrap(), before.as_bytes());
        assert_eq!(
            pjp_names(&got),
            vec![
                "ABOVE_VAR",
                "PJP_NOTION_TOKEN_PERSONAL",
                "CRLF_VAR",
                "LAST_VAR"
            ]
        );
    }

    #[test]
    fn keeps_lf_for_a_file_without_cr() {
        let c = Case::new("local-env-lf");
        c.put(format!("{BEGIN}\n# old\n{END}\nV={SECRET}\n").as_bytes());
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        let got = c.read();
        assert!(!got.contains(&b'\r'));
        assert!(!String::from_utf8_lossy(&got).contains("# old"));
        assert_eq!(sections(&got), SECTIONS);
        assert_eq!(below(&got), format!("V={SECRET}\n").as_bytes());
    }

    #[test]
    fn writes_nothing_when_up_to_date() {
        let c = Case::new("local-env-same");
        c.put(format!("{BEGIN}\n# old\n{END}\nV={SECRET}\n").as_bytes());
        c.run(APPLY);
        let bak = std::fs::read(c.bak()).unwrap();
        set_old_mtime(&c.env_file());
        let was = mtime(&c.env_file());
        let before = c.read();
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(out.contains("欄は最新です: "), "{out}");
        assert_eq!(c.read(), before);
        assert_eq!(mtime(&c.env_file()), was);
        assert_eq!(std::fs::read(c.bak()).unwrap(), bak);
    }

    #[test]
    fn moves_lines_written_inside_the_block() {
        let c = Case::new("local-env-rescue");
        let before = format!(
            "{BEGIN}\nFOO_API_KEY={SECRET}\n# old\nexport BAR=1\n{SECRET}==\n{SECRET}= \t\n  \n{END}\nMINE=1\n"
        );
        c.put(before.as_bytes());
        for mode in [Mode::Check, DRY] {
            let (o, _) = c.run(mode);
            assert_eq!(o.kind, Kind::Fix, "{mode:?} {o:?}");
            assert!(
                o.notes.iter().any(|n| n.contains("FOO_API_KEY")),
                "{mode:?} {o:?}"
            );
            assert_eq!(c.read(), before.as_bytes(), "{mode:?} で書いた");
        }
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        let got = c.read();
        assert_eq!(
            below(&got),
            format!("FOO_API_KEY={SECRET}\nexport BAR=1\n{SECRET}==\n{SECRET}= \t\nMINE=1\n")
                .as_bytes()
        );
        assert!(
            out.contains("欄のすぐ下へ移しました: FOO_API_KEY。ほかに KEY=VALUE の形でない行 3 行"),
            "{out}"
        );
        assert!(o.notes.iter().any(|n| n.contains("FOO_API_KEY")), "{o:?}");
        // 移すだけで中身は変えない (= だけで終わる行も、欄の外では pjp が名前として読む。名前として出さないのは知らせる文だけ)
        assert_eq!(pjp_names(&got), vec!["FOO_API_KEY", SECRET, SECRET, "MINE"]);
    }

    #[test]
    fn drops_the_bom_at_the_head() {
        // 印が頭: 印として見分け、書き直した欄の頭に BOM は付かない
        let c = Case::new("local-env-bom-marker");
        c.put(format!("{BOM_STR}{BEGIN}\n# old\n{END}\nV=1\n").as_bytes());
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        assert!(out.contains("欄を書き直しました: "), "{out}");
        let got = c.read();
        assert!(got.starts_with(BEGIN.as_bytes()));
        assert_eq!(below(&got), b"V=1\n");
        // 印が無い: 欄を頭に足し、BOM を外す (pjp が 1 行目の変数を読めるように)
        let c = Case::new("local-env-bom-plain");
        c.put(format!("{BOM_STR}PJP_NOTION_TOKEN_PERSONAL={SECRET}\n").as_bytes());
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        let got = c.read();
        assert!(got.starts_with(BEGIN.as_bytes()));
        assert_eq!(
            below(&got),
            format!("PJP_NOTION_TOKEN_PERSONAL={SECRET}\n").as_bytes()
        );
        assert_eq!(pjp_names(&got), vec!["PJP_NOTION_TOKEN_PERSONAL"]);
    }

    #[test]
    fn prepends_the_block_to_a_file_without_markers() {
        let c = Case::new("local-env-prepend");
        let before = format!("V={SECRET}\n# memo");
        c.put(before.as_bytes());
        let (o, _) = c.run(Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{o:?}");
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(out.contains("頭に足しました"), "{out}");
        assert!(out.contains("今あった 2 行"), "{out}");
        let got = c.read();
        assert_eq!(below(&got), before.as_bytes());
        assert_eq!(std::fs::read(c.bak()).unwrap(), before.as_bytes());
        // 空のファイルは欄だけになる
        let c = Case::new("local-env-empty");
        c.put(b"");
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(out.contains("今あった 0 行"), "{out}");
        let got = c.read();
        assert!(got.starts_with(BEGIN.as_bytes()));
        assert!(below(&got).is_empty());
    }

    #[test]
    fn leaves_broken_markers_alone() {
        for (tag, before, want) in [
            (
                "a",
                format!("{BEGIN}\nV={SECRET}\n"),
                "# >>> dotfiles の行: 1、# <<< dotfiles の行: 無し",
            ),
            (
                "b",
                format!("{BEGIN}\n{END}\nV={SECRET}\n{BEGIN}\n{END}\n"),
                "# >>> dotfiles の行: 1,4、# <<< dotfiles の行: 2,5",
            ),
            (
                "c",
                format!("{END}\nV={SECRET}\n{BEGIN}\n"),
                "# >>> dotfiles の行: 3、# <<< dotfiles の行: 1",
            ),
        ] {
            let c = Case::new(&format!("local-env-broken-{tag}"));
            c.put(before.as_bytes());
            for mode in [Mode::Check, APPLY] {
                let (o, out) = c.run(mode);
                assert_eq!(o.kind, Kind::Manual, "{tag} {mode:?} {o:?}");
                assert!(out.contains("書き換えません"), "{tag}: {out}");
                assert!(out.contains(want), "{tag}: {out}");
                assert_eq!(c.read(), before.as_bytes(), "{tag}");
                assert!(!c.bak().exists(), "{tag}");
            }
        }
    }

    #[test]
    fn refuses_files_it_should_not_rewrite() {
        // 普通のファイルでない (ディレクトリ)
        let c = Case::new("local-env-dir");
        std::fs::create_dir_all(c.env_file()).unwrap();
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(out.contains("普通のファイルではない"), "{out}");
        assert!(c.env_file().is_dir());

        // NUL を含む (UTF-16 で保存した)
        let c = Case::new("local-env-nul");
        let before = b"V\0=\x001\0\n\0".to_vec();
        c.put(&before);
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(out.contains("UTF-8"), "{out}");
        assert_eq!(c.read(), before);
        assert!(!c.bak().exists());

        // env.bak がディレクトリ
        let c = Case::new("local-env-bakdir");
        let before = format!("V={SECRET}\n");
        c.put(before.as_bytes());
        std::fs::create_dir_all(c.bak()).unwrap();
        for mode in [Mode::Check, DRY] {
            let (o, out) = c.run(mode);
            assert_eq!(o.kind, Kind::Manual, "{mode:?} {o:?}");
            assert!(out.contains("env.bak"), "{mode:?} {out}");
        }
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(out.contains("env.bak"), "{out}");
        assert_eq!(c.read(), before.as_bytes());
        assert_eq!(std::fs::read_dir(c.bak()).unwrap().count(), 0);

        // 読み取り専用
        let c = Case::new("local-env-readonly");
        let before = format!("V={SECRET}\n");
        c.put(before.as_bytes());
        let mut perm = std::fs::metadata(c.env_file()).unwrap().permissions();
        perm.set_readonly(true);
        std::fs::set_permissions(c.env_file(), perm.clone()).unwrap();
        let (o, out) = c.run(APPLY);
        #[allow(clippy::permissions_set_readonly_false)]
        perm.set_readonly(false);
        std::fs::set_permissions(c.env_file(), perm).unwrap();
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(out.contains("読み取り専用"), "{out}");
        assert_eq!(c.read(), before.as_bytes());
        assert!(!c.bak().exists());

        // 読み取り専用でも、欄が最新なら書くことが無いので揃っている (値を守るために読み取り専用にしたファイル)
        let c = Case::new("local-env-readonly-same");
        c.put(format!("V={SECRET}\n").as_bytes());
        c.run(APPLY);
        let mut perm = std::fs::metadata(c.env_file()).unwrap().permissions();
        perm.set_readonly(true);
        std::fs::set_permissions(c.env_file(), perm.clone()).unwrap();
        let results: Vec<_> = [Mode::Check, APPLY].into_iter().map(|m| c.run(m)).collect();
        #[allow(clippy::permissions_set_readonly_false)]
        perm.set_readonly(false);
        std::fs::set_permissions(c.env_file(), perm).unwrap();
        for (o, out) in results {
            assert_eq!(o.kind, Kind::Ok, "{o:?}");
            assert!(out.contains("欄は最新です: "), "{out}");
        }
    }

    #[test]
    fn refuses_a_symlink() {
        let c = Case::new("local-env-symlink");
        let target = c.t.path().join("target");
        let before = format!("V={SECRET}\n");
        std::fs::write(&target, &before).unwrap();
        std::fs::create_dir_all(c.dir()).unwrap();
        // Windows でファイルの symlink を張れない (開発者モードでも管理者でもない) なら、確かめられないので飛ばす
        let made = fake_file_symlink(&c.env_file().to_string_lossy(), &target.to_string_lossy());
        if made.exit != Exit::Code(0) {
            eprintln!("ファイルの symlink を張れないので飛ばす: {:?}", made.output);
            return;
        }
        let (o, out) = c.run(APPLY);
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(out.contains("symlink"), "{out}");
        assert!(
            std::fs::symlink_metadata(c.env_file())
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(std::fs::read(&target).unwrap(), before.as_bytes());
    }

    #[test]
    fn follows_xdg_config_home() {
        // 絶対パスならその下
        let c = Case::new("local-env-xdg");
        let xdg = c.t.path().join("xdg");
        let sys =
            FakeSys::new(|_| unreachable!()).with_env("XDG_CONFIG_HOME", &xdg.to_string_lossy());
        let (o, _) = c.run_with(&sys, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(xdg.join("pjp").join("env").is_file());
        assert!(!c.env_file().exists());
        // 空ならホームの下
        let c = Case::new("local-env-xdg-empty");
        let sys = FakeSys::new(|_| unreachable!()).with_env("XDG_CONFIG_HOME", "");
        let (o, _) = c.run_with(&sys, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(c.env_file().is_file());
        // 相対パスなら書かない (runner は clone の中で流れるので、そこに秘密のファイルを作らない)
        let c = Case::new("local-env-xdg-rel");
        let rel = format!("local-env-xdg-rel-{}", std::process::id());
        let sys = FakeSys::new(|_| unreachable!()).with_env("XDG_CONFIG_HOME", &rel);
        let (o, out) = c.run_with(&sys, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(out.contains("XDG_CONFIG_HOME"), "{out}");
        assert!(!Path::new(&rel).exists());
        assert!(!c.env_file().exists());
    }

    /// 欄の節は ~/.claude/skills から組むので、skill をつなぐ手順 (dotfiles の skill の claude-files・claude-skills の claude-skills) の後に
    /// 流れる。読むのは pjp だけなので、pjp を入れるホスト (claudePrivateSkills) でだけ on
    #[test]
    fn runs_after_the_steps_that_link_skills() {
        let ids: Vec<&str> = crate::steps::all().iter().map(|s| s.info().id).collect();
        let at = |id: &str| ids.iter().position(|i| *i == id).unwrap();
        assert!(at("claude-files") < at("local-env"), "{ids:?}");
        assert!(at("claude-skills") < at("local-env"), "{ids:?}");
        assert_eq!(LocalEnv.info().gate, Gate::Tool("claudePrivateSkills"));
    }

    /// `src` の中身 (ディレクトリとファイル) を `dst` に写す
    #[cfg(unix)]
    fn copy_tree(src: &Path, dst: &Path) {
        std::fs::create_dir_all(dst).unwrap();
        for e in std::fs::read_dir(src).unwrap() {
            let e = e.unwrap();
            let to = dst.join(e.file_name());
            if e.path().is_dir() {
                copy_tree(&e.path(), &to);
            } else {
                std::fs::copy(e.path(), &to).unwrap();
            }
        }
    }

    /// 出力のうち、`head` の後ろから `tail` の手前まで (無ければ None)
    #[cfg(unix)]
    fn between<'a>(text: &'a str, head: &str, tail: &str) -> Option<&'a str> {
        let start = text.find(head)? + head.len();
        let len = text[start..].find(tail)?;
        Some(&text[start..start + len])
    }

    /// 欄に入れなかった断片の skill の名前 (`!! <…>/<名前>/pjp-env.txt は ~/.config/pjp/env の欄に入れません` の行から)
    #[cfg(unix)]
    fn rejected(text: &str) -> Vec<String> {
        let mut v: Vec<String> = text
            .lines()
            .filter(|l| l.starts_with("!! ") && l.contains("の欄に入れません"))
            .filter_map(|l| {
                let path = &l[3..l.find("pjp-env.txt")?];
                let path = path.trim_end_matches(['/', '\\']);
                Some(Path::new(path).file_name()?.to_string_lossy().into_owned())
            })
            .collect();
        v.sort();
        v
    }

    /// 何をしたか (作った・書き直した・頭に足した・最新・書かなかった)
    #[cfg(unix)]
    fn action(text: &str) -> &'static str {
        if text.contains("作りました: ") {
            "created"
        } else if text.contains("欄を書き直しました: ") {
            "replaced"
        } else if text.contains("欄を頭に足しました: ") {
            "prepended"
        } else if text.contains("欄は最新です: ") {
            "same"
        } else {
            "none"
        }
    }

    /// bash の版 (nix/scripts/bootstrap-local-env.sh) と同じ入力から流し、何をしたか・欄の外のバイト・skill の節・欄に入れなかった
    /// 断片・移した名前・印の行番号が同じかを見る。Windows の欄に dotfiles の節は無いので、bash の版の偽の checkout には dotfiles.txt を
    /// 置かない。Windows だけの決まり (印の無いファイルの頭の BOM・断片の NUL・古いテンプレート) の入力は使わない
    #[cfg(unix)]
    #[test]
    fn matches_bash() {
        use crate::hooks::parity;
        if !parity::available() {
            return;
        }
        let script = parity::repo_file("nix/scripts/bootstrap-local-env.sh");
        let cases: Vec<(&str, Option<String>)> = vec![
            ("none", None),
            ("empty", Some(String::new())),
            ("plain", Some(format!("V={SECRET}\n# memo"))),
            (
                "top",
                Some(format!(
                    "{BEGIN}\n# old\n{END}\nPJP_NOTION_TOKEN_PERSONAL={SECRET}\nCRLF_VAR=1\r\nLAST_VAR=2"
                )),
            ),
            (
                "above",
                Some(format!(
                    "ABOVE_VAR=1\r\n# above\n{BEGIN}\n# old\n{END}\nMINE=1\n"
                )),
            ),
            (
                "rescue",
                Some(format!(
                    "{BEGIN}\nFOO_API_KEY={SECRET}\n# old\nexport BAR=1\n{SECRET}==\n{SECRET}= \t\n  \n{END}\nMINE=1\n"
                )),
            ),
            (
                "rescue-crlf",
                Some(format!("{BEGIN}\r\nFOO=1\r\n{END}\r\nMINE=1\r\n")),
            ),
            (
                "bom-top",
                Some(format!("{BOM_STR}{BEGIN}\n# old\n{END}\nV=1\n")),
            ),
            ("broken-a", Some(format!("{BEGIN}\nV={SECRET}\n"))),
            (
                "broken-b",
                Some(format!("{BEGIN}\n{END}\nV={SECRET}\n{BEGIN}\n{END}\n")),
            ),
            ("broken-c", Some(format!("{END}\nV={SECRET}\n{BEGIN}\n"))),
            ("nul", Some("V\0=\x001\0\n\0".to_string())),
        ];
        for (tag, input) in cases {
            let c = Case::new(&format!("local-env-parity-{tag}"));
            c.skill(
                "bad",
                "bad の変数。\n<<< dotfiles を足す\nBAD=xxxxxx\n".as_bytes(),
            );
            c.skill("ctrl", "ctrl の変数。\rPJP_X=bogus\n".as_bytes());
            c.skill("uline", "uline の変数。\u{2028}Z_INJECT=1\n".as_bytes());
            let bash_home = c.t.path().join("bash-home");
            copy_tree(&c.skills(), &bash_home.join(".claude").join("skills"));
            let checkout = c.t.path().join("bash-repo").join("nix").join("scripts");
            std::fs::create_dir_all(&checkout).unwrap();
            let copied = checkout.join("bootstrap-local-env.sh");
            std::fs::copy(&script, &copied).unwrap();
            let bash_env = bash_home.join(".config").join("pjp").join("env");
            if let Some(b) = &input {
                c.put(b.as_bytes());
                std::fs::create_dir_all(bash_env.parent().unwrap()).unwrap();
                std::fs::write(&bash_env, b).unwrap();
            }
            for round in 0..2 {
                let out = std::process::Command::new("bash")
                    .arg(&copied)
                    .env("HOME", &bash_home)
                    .env("XDG_CONFIG_HOME", bash_home.join(".config"))
                    .env_remove("DOTFILES_SETUP_WARNINGS")
                    .output()
                    .unwrap();
                assert_eq!(
                    out.status.code(),
                    Some(0),
                    "{tag}: bash の版が 0 で終わらない"
                );
                let bash_text = format!(
                    "{}{}",
                    String::from_utf8_lossy(&out.stdout),
                    String::from_utf8_lossy(&out.stderr)
                );
                let (_, ours) = c.run(APPLY);
                let what = format!("{tag} {round} 回目\n--- bash\n{bash_text}\n--- runner\n{ours}");
                assert_eq!(action(&ours), action(&bash_text), "{what}");
                assert_eq!(rejected(&ours), rejected(&bash_text), "{what}");
                assert_eq!(rejected(&ours), vec!["bad", "ctrl", "uline"], "{what}");
                let moved = "欄のすぐ下へ移しました: ";
                assert_eq!(
                    between(&ours, moved, " (値は出しません)"),
                    between(&bash_text, moved, " (値は出しません)"),
                    "{what}"
                );
                let marks = "書き換えません (";
                assert_eq!(
                    between(&ours, marks, ")"),
                    between(&bash_text, marks, ")"),
                    "{what}"
                );
                let bash_got = std::fs::read(&bash_env).ok();
                let ours_got = std::fs::read(c.env_file()).ok();
                match (&bash_got, &ours_got) {
                    (Some(b), Some(r)) => {
                        assert_eq!(above(r), above(b), "{what}");
                        assert_eq!(below(r), below(b), "{what}");
                        if action(&ours) != "none" {
                            assert_eq!(sections(r), sections(b), "{what}");
                        } else {
                            // 書かなかった: どちらも元のまま
                            assert_eq!(Some(r.as_slice()), input.as_deref().map(str::as_bytes));
                            assert_eq!(Some(b.as_slice()), input.as_deref().map(str::as_bytes));
                        }
                    }
                    _ => panic!("{what}: ファイルの有る無しが違う"),
                }
            }
        }
    }
}
