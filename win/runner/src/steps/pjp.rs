//! pjp (order 55): claude-skills の Rust の道具の入口 (shim) を `pjp-skills` の名前で入れ、clone の道具を作る (`pjp-skills --build`)。Linux の
//! `nix/scripts/bootstrap-pjp.sh` と同じ判断。入口の `pjp` は公開の dotfiles の道具 (`nix/pkgs/pjp-tools`。手順 pjp-tools が
//! `%LOCALAPPDATA%\dotfiles\bin\` に置く) で、hub・child・mark・pack のほかを pjp-skills に渡す (dotfiles-private の ADR 124)。手順の id は
//! `pjp` のまま (claude-skills の案内が `dotfiles apply --steps pjp` を指す):
//!
//! - 前の shim を外す: 前の手順が `cargo install` で入れた `<CARGO_HOME か %USERPROFILE%\.cargo>\bin\pjp.exe` は、PATH で公開の `pjp` を覆う
//!   (`.cargo\bin` は `dotfiles\bin` より前に来る) ので、cargo の記録 (`<CARGO_HOME>\.crates.toml`) に pjp-shim の bin `pjp.exe` があるときだけ
//!   `cargo uninstall --root <CARGO_HOME> pjp-shim` で外す (前の dotfiles が bin を 2 つとも入れた形も、記録ごと外れる)。外すのは、公開の入口
//!   (手順 pjp-tools が置く `%LOCALAPPDATA%\dotfiles\bin\` の `pjp.exe` と、ハブの hook が起こす `pjp-hub.exe`) が置かれているときだけ。まだ
//!   無ければ残して fix の行で知らせる (`--steps pjp` だけを打った・同じ apply の pjp-tools が止まったときに外すと、このホストから pjp が無くなり、
//!   ハブの hook の `pjp hub guard` も落ちる)。記録に無い pjp.exe (ほかのもの) は外さずに ⚠ で知らせる (消すのはユーザー)
//! - shim (`<CARGO_HOME>\bin\pjp-skills.exe`) が無い・起きない・`pjp-skills --version` の版 (shim は bin の名前によらず「pjp <版>」と出す) が
//!   clone の `crates/pjp-shim` の版と違うときだけ、`cargo install --locked --root <使い捨て>\root --target-dir <使い捨て>\target --path
//!   <clone>\crates\pjp-shim` を打ち、出来た `pjp-skills.exe` (無ければ `pjp.exe`。clone の shim の crate の bin は、前の pjp だけ・pjp と
//!   pjp-skills・pjp-skills だけ、のどれか) を `pjp-skills.exe` の名前で置く (shim は argv[0] を読まない。動いていても入れ替えられる
//!   `claude_files::replace_file` で)。使い捨ての root に入れるのは、`<CARGO_HOME>\bin\pjp.exe` も cargo の記録も `<CARGO_HOME>` に残さないため。
//!   cargo は clone の中で、clone の `rust-toolchain.toml` の channel を `RUSTUP_TOOLCHAIN` にして打つ (Windows の rustup は既定の toolchain を
//!   持たず、`cargo run` で起こした runner には runner の版の `RUSTUP_TOOLCHAIN` が付いているため)。置いた後に版を読み直す
//! - 順は、使い捨ての root に作る → (外すなら) 前の shim を外す → 作った shim を置く。作るのが落ちたら前の shim は外さない (private な道具を
//!   無くさない)。前の shim を外すと一緒に消える形 (記録に pjp-skills.exe もある) は、版が同じでも作って、外した後に置き直す
//! - 続けて毎回 `pjp-skills --build` (`PJP_SKILLS_DIR=<clone>`。runner の `RUSTUP_TOOLCHAIN` は外し、shim が clone の版を決める)
//!
//! check は shim と前の shim を見る (build しない。check は何も書かない)。dry-run は入れるもの・外すもの・置くもの・作るものを、apply で打つ順に
//! 出す。
//! dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*・docs/adr/124_*。

use super::claude_accounts::BIN_DIR_REL;
use super::claude_files::replace_file;
use super::claude_skills::clone_dir;
use super::ps1::{ps_quote, run_streaming};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::process::CommandSpec;
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// cargo install の待ちの上限 (shim と依存を使い捨ての target dir で作る)
const INSTALL_SECS: u64 = 1800;
/// cargo uninstall の待ちの上限
const UNINSTALL_SECS: u64 = 300;
/// pjp-skills --build の待ちの上限 (初めては道具を全部作る)
const BUILD_SECS: u64 = 3600;
/// claude-skills の shim の crate (cargo の記録の鍵の頭・cargo uninstall に渡す名前)
const SHIM_CRATE: &str = "pjp-shim";
/// 置く shim の bin の名前 (`<CARGO_HOME>\bin\pjp-skills.exe`)
pub const SHIM_BIN: &str = "pjp-skills";
/// 前の手順が置いた shim の bin の名前 (公開の入口 `pjp` と同じ名前なので、PATH で覆う)
pub const OLD_SHIM_BIN: &str = "pjp";
/// 前の shim を外す前に置かれているはずの公開の道具 (手順 pjp-tools が `%LOCALAPPDATA%\dotfiles\bin\` に置く入口と、ハブの hook の
/// `pjp hub guard` が起こすもの)
const PUBLIC_TOOLS: [&str; 2] = ["pjp", "pjp-hub"];
/// 公開の入口がまだ無いので前の shim を残す行の文 (check・dry-run・apply とも)
const KEEP_TEXT: &str = "公開の pjp (手順 pjp-tools) がまだ無いので、前の shim は残す (dotfiles apply で pjp-tools を流した後に外れる)";

/// exe の名前 (Windows は `<名前>.exe`。ほかの OS の名前は試験のため)。Windows の cargo は記録にもこの名前を書く
fn exe(name: &str) -> String {
    format!("{name}{}", std::env::consts::EXE_SUFFIX)
}

/// TOML のファイル `path` の `[table]` の `key` の文字列。読めない・無い・文字列でないなら None。
pub fn read_toml_string(path: &Path, table: &str, key: &str) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let t: toml::Table = text.parse().ok()?;
    t.get(table)?.get(key)?.as_str().map(str::to_string)
}

/// cargo install の入れ先 (`CARGO_HOME`、無ければ `%USERPROFILE%\.cargo`)。shim と同じ。
pub fn cargo_root(ctx: &Ctx) -> PathBuf {
    match ctx.sys.env("CARGO_HOME").filter(|s| !s.is_empty()) {
        Some(h) => PathBuf::from(h),
        None => ctx.roots.user_profile.join(".cargo"),
    }
}

/// 入れる shim のパス (`<cargo_root>\bin\pjp-skills.exe`)。
pub fn shim_path(ctx: &Ctx) -> PathBuf {
    cargo_root(ctx).join("bin").join(exe(SHIM_BIN))
}

/// 前の手順が入れた shim のパス (`<cargo_root>\bin\pjp.exe`)。
pub fn old_shim_path(ctx: &Ctx) -> PathBuf {
    cargo_root(ctx).join("bin").join(exe(OLD_SHIM_BIN))
}

/// 公開の道具の置き場 (`%LOCALAPPDATA%\dotfiles\bin`。手順 pjp-tools が置く)。
fn public_bin(ctx: &Ctx) -> PathBuf {
    join_segments(&ctx.roots.local_app_data, BIN_DIR_REL)
}

/// 公開の入口 (`pjp.exe` と `pjp-hub.exe`) のうち、置き場にまだ無いものの名前。空なら置かれている。
fn unplaced_public(ctx: &Ctx) -> Vec<String> {
    let bin = public_bin(ctx);
    PUBLIC_TOOLS
        .iter()
        .map(|t| exe(t))
        .filter(|n| !bin.join(n).is_file())
        .collect()
}

/// cargo の記録 (`<root>\.crates.toml` の `[v1]`。`"pjp-shim <版> (<出どころ>)" = ["pjp.exe", …]`) の、pjp-shim の bin の並び。記録が無い・
/// TOML として読めない・pjp-shim の行が無いなら None。
pub fn shim_record(root: &Path) -> Option<Vec<String>> {
    let text = std::fs::read_to_string(root.join(".crates.toml")).ok()?;
    let t: toml::Table = text.parse().ok()?;
    let mut found = false;
    let mut bins = Vec::new();
    for (key, v) in t.get("v1")?.as_table()? {
        if key.split(' ').next() != Some(SHIM_CRATE) {
            continue;
        }
        found = true;
        bins.extend(
            v.as_array()
                .into_iter()
                .flatten()
                .filter_map(|b| b.as_str())
                .map(str::to_string),
        );
    }
    found.then_some(bins)
}

/// 使う cargo (`CARGO_HOME\bin` → `%USERPROFILE%\.cargo\bin` → PATH。shim の locate_cargo と同じ順)。claude-selector の手順も使う。
pub(super) fn locate_cargo(ctx: &Ctx) -> Option<PathBuf> {
    let exe = format!("cargo{}", std::env::consts::EXE_SUFFIX);
    let homes = [
        ctx.sys
            .env("CARGO_HOME")
            .filter(|s| !s.is_empty())
            .map(PathBuf::from),
        Some(ctx.roots.user_profile.join(".cargo")),
    ];
    homes
        .into_iter()
        .flatten()
        .map(|h| h.join("bin").join(&exe))
        .find(|p| p.is_file())
        .or_else(|| ctx.sys.which("cargo"))
}

/// 入れてある shim の版 (`pjp-skills --version` の「pjp <版>」。shim は bin の名前によらず pjp と出す)。無い・起きないなら None。
fn installed_version(ctx: &Ctx, shim: &Path) -> Option<String> {
    if !shim.is_file() {
        return None;
    }
    let r = ctx.sys.run(
        &CommandSpec::new(shim)
            .arg("--version")
            .stdout_only()
            .timeout(Duration::from_secs(30)),
        &mut |_| {},
    );
    if r.code() != Some(0) {
        return None;
    }
    r.output
        .iter()
        .find_map(|l| l.trim().strip_prefix("pjp ").map(|v| v.trim().to_string()))
}

/// `^[A-Za-z0-9][A-Za-z0-9._-]*$` (rust-toolchain.toml の channel。Linux の bootstrap-pjp.sh と同じ確かめ。claude-selector の手順も使う)
pub(super) fn channel_ok(s: &str) -> bool {
    let mut c = s.chars();
    c.next().is_some_and(|x| x.is_ascii_alphanumeric())
        && c.all(|x| x.is_ascii_alphanumeric() || matches!(x, '.' | '_' | '-'))
}

/// `^[0-9][0-9A-Za-z.+-]*$` (crates/pjp-shim の version)
fn version_ok(s: &str) -> bool {
    let mut c = s.chars();
    c.next().is_some_and(|x| x.is_ascii_digit())
        && c.all(|x| x.is_ascii_alphanumeric() || matches!(x, '.' | '+' | '-'))
}

/// 前の手順が入れた shim (`<cargo_root>\bin\pjp.exe`) の様子。
enum OldShim {
    /// 無い
    Absent,
    /// cargo の記録に pjp-shim の bin pjp.exe がある (外す)。記録にある bin の並び
    Recorded(Vec<String>),
    /// 記録に無い (ほかのもの。外さない)
    Foreign,
}

fn old_shim(ctx: &Ctx) -> OldShim {
    if std::fs::symlink_metadata(old_shim_path(ctx)).is_err() {
        return OldShim::Absent;
    }
    match shim_record(&cargo_root(ctx)) {
        Some(bins) if bins.contains(&exe(OLD_SHIM_BIN)) => OldShim::Recorded(bins),
        _ => OldShim::Foreign,
    }
}

/// shim を入れる (入れ直す) わけ。入れなくてよければ None。`goes` は、この流しで前の shim を外し、そのときに一緒に消えるか (前の dotfiles が
/// bin を 2 つとも入れ、記録に pjp-skills.exe もある。打たずに決める)。
fn need(ctx: &Ctx, shim: &Path, want: &str, goes: bool) -> Option<(Kind, String)> {
    if goes {
        return Some((
            Kind::Fix,
            format!(
                "shim の pjp-skills は前の shim と同じ cargo の記録にあり、前の shim を外すと一緒に消える ({}) → 作り直して、外した後に置く",
                shim.display()
            ),
        ));
    }
    match installed_version(ctx, shim) {
        Some(v) if v == want => None,
        Some(v) => Some((
            Kind::Fix,
            format!("shim の pjp-skills が {v} (clone の {want} と違う) → 入れ直す"),
        )),
        None if shim.exists() => Some((
            Kind::Fix,
            format!(
                "shim の pjp-skills が起きない ({}) → 入れ直す",
                shim.display()
            ),
        )),
        None => Some((
            Kind::Missing,
            format!("shim の pjp-skills が無い ({}) → 入れる", shim.display()),
        )),
    }
}

/// 記録に無い pjp.exe を外さないことの文
fn foreign_text(old: &Path, root: &Path) -> String {
    format!(
        "{} は claude-skills の shim と確かめられないので外さない (cargo の記録 {} に {SHIM_CRATE} の bin {} が無い) → PATH で公開の入口 pjp (%LOCALAPPDATA%\\dotfiles\\bin) より前に来ると覆うので、要らなければ消す",
        old.display(),
        root.join(".crates.toml").display(),
        exe(OLD_SHIM_BIN)
    )
}

/// 主の行の後ろに、前の shim の行を足す
fn with(mut first: Vec<Outcome>, rest: Vec<Outcome>) -> Vec<Outcome> {
    first.extend(rest);
    first
}

pub struct Pjp;

impl Step for Pjp {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "pjp",
            order: 55,
            title: "claude-skills の Rust の道具の入口 (shim) を pjp-skills として入れ、前の shim の pjp を外し、道具を作る (pjp-skills --build)",
            gate: Gate::Tool("claudePrivateSkills"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let clone = clone_dir(ctx);
        let shim_dir = clone.join("crates").join("pjp-shim");
        let shim_toml = shim_dir.join("Cargo.toml");
        if !shim_toml.is_file() {
            return vec![
                Outcome::new(
                    Kind::Manual,
                    format!(
                        "claude-skills の clone に Rust の道具 (crates/pjp-shim) がまだ無い ({}) → clone を進める (dotfiles --self-update apply)",
                        clone.display()
                    ),
                )
                .note(format!(
                    "dotfiles 関数が --self-update を知らない古いものなら、手で pull する (gh の資格情報で HTTPS を通す): git -c url.https://github.com/.insteadOf=git@github.com: -c credential.helper= -c 'credential.helper=!gh auth git-credential' -C '{}' pull --ff-only",
                    ps_quote(&clone.to_string_lossy())
                )),
            ];
        }
        let toolchain = clone.join("rust-toolchain.toml");
        let channel = read_toml_string(&toolchain, "toolchain", "channel").unwrap_or_default();
        if !channel_ok(&channel) {
            return vec![Outcome::new(
                Kind::Failed,
                format!(
                    "claude-skills の rust-toolchain.toml の [toolchain] の channel を読めない ({})",
                    toolchain.display()
                ),
            )];
        }
        let want = read_toml_string(&shim_toml, "package", "version").unwrap_or_default();
        if !version_ok(&want) {
            return vec![Outcome::new(
                Kind::Failed,
                format!(
                    "claude-skills の crates/pjp-shim/Cargo.toml の [package] の version を読めない ({})",
                    shim_toml.display()
                ),
            )];
        }
        ctx.say(format!("clone: {}", clone.display()));
        ctx.say(format!("toolchain {channel}・shim {want}"));
        let root = cargo_root(ctx);
        let shim = shim_path(ctx);
        let old_path = old_shim_path(ctx);
        let old = old_shim(ctx);
        // 公開の入口 (手順 pjp-tools が置く) のうち、まだ無いもの。揃うまでは記録のある前の shim も外さない (外すと pjp が無くなる)
        let unplaced = unplaced_public(ctx);
        let recorded = matches!(old, OldShim::Recorded(_));
        let remove = recorded && unplaced.is_empty();
        // 前の shim の行 (主の行の後ろに足す)
        let mut rest = Vec::new();
        match &old {
            OldShim::Absent => {}
            OldShim::Recorded(_) if remove => ctx.say(format!(
                "前の shim: {} (cargo の記録の {SHIM_CRATE} のもの。公開の入口 pjp を覆うので、新しい shim を作れたら外す)",
                old_path.display()
            )),
            OldShim::Recorded(_) => {
                ctx.say(format!(
                    "前の shim: {} (cargo の記録の {SHIM_CRATE} のもの)",
                    old_path.display()
                ));
                ctx.say(format!("!! {KEEP_TEXT}"));
                let prefix = if matches!(mode, Mode::DryRun { .. }) {
                    "[dry-run] "
                } else {
                    ""
                };
                rest.push(
                    Outcome::new(Kind::Fix, format!("{prefix}{KEEP_TEXT}")).note(format!(
                        "公開の道具の置き場 {} に {} が無い (手順 pjp-tools が置く)。それまでは前の shim {} が claude-skills の道具を起こす",
                        public_bin(ctx).display(),
                        unplaced.join("・"),
                        old_path.display()
                    )),
                );
            }
            OldShim::Foreign => {
                let why = foreign_text(&old_path, &root);
                ctx.say(format!("!! {why}"));
                rest.push(Outcome::new(Kind::Manual, why));
            }
        }
        // この流しで前の shim を外し、そのときに pjp-skills.exe も一緒に消えるか (記録に pjp-skills.exe もある)
        let goes =
            remove && matches!(&old, OldShim::Recorded(bins) if bins.contains(&exe(SHIM_BIN)));
        let cargo_note = format!("(cwd は clone、RUSTUP_TOOLCHAIN={channel})");
        let uninstall_line = format!(
            "cargo uninstall --root {} {SHIM_CRATE} {cargo_note}",
            root.display()
        );
        let install_line = |work: &Path| {
            format!(
                "cargo install --locked --root {} --target-dir {} --path {} {cargo_note}",
                work.join("root").display(),
                work.join("target").display(),
                shim_dir.display()
            )
        };
        let place_line = |work: &Path| {
            format!(
                "{} (無ければ {}) を {} に置く",
                work.join("root").join("bin").join(exe(SHIM_BIN)).display(),
                exe(OLD_SHIM_BIN),
                shim.display()
            )
        };
        match mode {
            Mode::Check => {
                let main = match need(ctx, &shim, &want, goes) {
                    None => Outcome::new(Kind::Ok, format!("shim の pjp-skills は {want} のまま")),
                    Some((kind, text)) => {
                        ctx.say(&text);
                        Outcome::new(kind, format!("{text} (apply で)"))
                    }
                };
                if remove {
                    rest.insert(
                        0,
                        Outcome::new(
                            Kind::Fix,
                            format!(
                                "前の shim の {} を外す (apply で、新しい shim を作れてから: cargo uninstall --root {} {SHIM_CRATE}。公開の入口 pjp を覆うため)",
                                exe(OLD_SHIM_BIN),
                                root.display()
                            ),
                        ),
                    );
                }
                with(vec![main], rest)
            }
            Mode::DryRun { .. } => {
                // apply と同じ順 (作る → 外す → 置く → 道具を作る) に出す
                let todo = need(ctx, &shim, &want, goes);
                let work = Path::new("<使い捨ての dir>");
                if todo.is_some() {
                    ctx.say(format!("[dry-run] {}", install_line(work)));
                }
                if remove {
                    ctx.say(format!("[dry-run] {uninstall_line}"));
                }
                if todo.is_some() {
                    ctx.say(format!("[dry-run] {}", place_line(work)));
                }
                ctx.say(format!(
                    "[dry-run] pjp-skills --build を流す (PJP_SKILLS_DIR={})",
                    clone.display()
                ));
                let main = match todo {
                    None => Outcome::new(
                        Kind::Ok,
                        format!(
                            "[dry-run] shim の pjp-skills は {want} のまま。pjp-skills --build を流す"
                        ),
                    ),
                    Some((kind, text)) => Outcome::new(
                        kind,
                        format!("[dry-run] {text}。続けて pjp-skills --build を流す"),
                    ),
                };
                if remove {
                    rest.insert(
                        0,
                        Outcome::new(
                            Kind::Fix,
                            format!(
                                "[dry-run] 前の shim の {} を外す (cargo の記録の {SHIM_CRATE} のもの。公開の入口 pjp を覆うため。新しい shim を作れてから)",
                                exe(OLD_SHIM_BIN)
                            ),
                        ),
                    );
                }
                with(vec![main], rest)
            }
            Mode::Apply { .. } => {
                // 順は、使い捨ての root に作る → (外すなら) 前の shim を外す → 作った shim を置く。作るのが落ちたら前の shim は外さない
                // (private な道具を無くさない)。外すと pjp-skills.exe も一緒に消える形 (goes) は、版が同じでも作り、外した後に置く
                let todo = need(ctx, &shim, &want, goes);
                let cargo = if remove || todo.is_some() {
                    match locate_cargo(ctx) {
                        Some(c) => Some(c),
                        None => {
                            return with(
                                vec![Outcome::new(
                                    Kind::Failed,
                                    "cargo が見つからない (rustup は bootstrap が入れる)",
                                )],
                                rest,
                            );
                        }
                    }
                } else {
                    None
                };
                // 1. 作る (使い捨ての root に。<CARGO_HOME> にはまだ触らない)
                let mut built = None;
                if let (Some((_, text)), Some(cargo)) = (&todo, cargo.as_deref()) {
                    ctx.say(text);
                    let nanos = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_nanos())
                        .unwrap_or(0);
                    let work = std::env::temp_dir().join(format!(
                        "dotfiles-win-pjp-shim-{}-{nanos}",
                        std::process::id()
                    ));
                    ctx.say(format!("+ {}", install_line(&work)));
                    match build_shim(ctx, cargo, &work, &shim_dir, &clone, &channel) {
                        Ok(made) => built = Some((work, made)),
                        Err(o) => {
                            remove_work(ctx, &work);
                            let o = if remove {
                                o.note(format!(
                                    "前の shim ({}) は外していない (新しい shim を作れてから外す)。claude-skills の道具は前の shim で起こせる",
                                    old_path.display()
                                ))
                            } else {
                                o
                            };
                            return with(vec![o], rest);
                        }
                    }
                }
                // 2. 作れたら (作らなくてよければ、そのまま) 前の shim を外す
                let mut removed_old = false;
                if let Some(cargo) = cargo.as_deref().filter(|_| remove) {
                    ctx.say(format!("+ {uninstall_line}"));
                    let r = run_streaming(
                        ctx,
                        &CommandSpec::new(cargo)
                            .arg("uninstall")
                            .arg("--root")
                            .arg(root.as_os_str())
                            .arg(SHIM_CRATE)
                            .current_dir(&clone)
                            .env("RUSTUP_TOOLCHAIN", &channel)
                            .timeout(Duration::from_secs(UNINSTALL_SECS)),
                    );
                    if r.code() == Some(0) && std::fs::symlink_metadata(&old_path).is_err() {
                        removed_old = true;
                        ctx.say(format!("前の shim を外しました: {}", old_path.display()));
                    } else {
                        let why = format!(
                            "前の shim の {} を外せなかった (上の cargo の出力。{:?}): {}",
                            exe(OLD_SHIM_BIN),
                            r.exit,
                            old_path.display()
                        );
                        ctx.say(format!("!! {why}"));
                        rest.insert(
                            0,
                            Outcome::new(Kind::Failed, why)
                                .note("pjp を使っている会話・端末 (ハブの hook など) があると、外すのが「アクセスが拒否されました」で落ちることがある。止めてから流し直す")
                                .note(format!(
                                    "公開の入口 pjp を覆うので、手で外すなら: cargo uninstall --root '{}' {SHIM_CRATE}",
                                    ps_quote(&root.to_string_lossy())
                                )),
                        );
                    }
                }
                // 3. 作った shim を置く (2 つとも記録にある形は、外すと pjp-skills.exe も消えるので、置くのは外した後)
                if let Some((work, made)) = built {
                    let placed = place_shim(ctx, &made, &shim);
                    remove_work(ctx, &work);
                    if let Err(o) = placed {
                        return with(vec![o], rest);
                    }
                    match installed_version(ctx, &shim) {
                        Some(v) if v == want => ctx.say(format!(
                            "shim の pjp-skills {want} を入れました: {}",
                            shim.display()
                        )),
                        other => {
                            return with(
                                vec![Outcome::new(
                                    Kind::Failed,
                                    format!(
                                        "置いた shim が起きない・版が違う ({}: {other:?}。望んだのは {want})",
                                        shim.display()
                                    ),
                                )],
                                rest,
                            );
                        }
                    }
                }
                ctx.say(format!(
                    "+ pjp-skills --build (PJP_SKILLS_DIR={})",
                    clone.display()
                ));
                let spec = CommandSpec::new(&shim)
                    .arg("--build")
                    .env("PJP_SKILLS_DIR", clone.as_os_str())
                    .env_remove("RUSTUP_TOOLCHAIN")
                    .timeout(Duration::from_secs(BUILD_SECS));
                let r = run_streaming(ctx, &spec);
                if r.code() != Some(0) {
                    return with(
                        vec![
                            Outcome::new(
                                Kind::Failed,
                                format!("claude-skills の道具を作れなかった (pjp-skills --build。上の cargo の出力。{:?})", r.exit),
                            )
                            .note("道具は、初めて打ったときに shim が作り直す。直してから流し直す"),
                        ],
                        rest,
                    );
                }
                let head = if removed_old {
                    format!("前の shim の {} を外し、", exe(OLD_SHIM_BIN))
                } else {
                    String::new()
                };
                let mut main = Outcome::new(
                    Kind::Ok,
                    format!("{head}shim の pjp-skills {want}・道具を作った (pjp-skills --build)"),
                );
                if removed_old {
                    // 動いている herdr-app の会話は、前の shim を PATH の .cargo\bin で見つけていた
                    main = main.note(format!(
                        "pjp は公開の入口 ({}) から起きる。手順 pjp-tools が PATH に置き場を足したばかりなら、動いている herdr-app とその中の会話では、herdr-app を上げ直すまで pjp が見つからない",
                        public_bin(ctx).join(exe(OLD_SHIM_BIN)).display()
                    ));
                }
                with(vec![main], rest)
            }
        }
    }
}

/// 使い捨ての dir を消す (消せなければ知らせる)
fn remove_work(ctx: &mut Ctx, work: &Path) {
    let _ = std::fs::remove_dir_all(work);
    if work.exists() {
        ctx.say(format!(
            "!! 使い捨ての dir を消せなかった (数百 MB になりうる。要らなければ手で消す): {}",
            work.display()
        ));
    }
}

/// shim を使い捨ての dir `work` (`root`・`target`) に `cargo install` し、出来た exe (`pjp-skills.exe`、無ければ `pjp.exe`) のパスを返す
/// (`<CARGO_HOME>` には触らない)。落ちたら、その行。`work` を消すのは呼ぶ側。
fn build_shim(
    ctx: &mut Ctx,
    cargo: &Path,
    work: &Path,
    shim_dir: &Path,
    clone: &Path,
    channel: &str,
) -> Result<PathBuf, Outcome> {
    let root = work.join("root");
    let target = work.join("target");
    if let Err(e) = std::fs::create_dir_all(work) {
        return Err(Outcome::new(
            Kind::Failed,
            format!("shim を作る一時の dir を作れない ({}: {e})", work.display()),
        ));
    }
    let r = run_streaming(
        ctx,
        &CommandSpec::new(cargo)
            .arg("install")
            .arg("--locked")
            .arg("--root")
            .arg(root.as_os_str())
            .arg("--target-dir")
            .arg(target.as_os_str())
            .arg("--path")
            .arg(shim_dir.as_os_str())
            .current_dir(clone)
            .env("RUSTUP_TOOLCHAIN", channel)
            .timeout(Duration::from_secs(INSTALL_SECS)),
    );
    if r.code() != Some(0) {
        return Err(Outcome::new(
            Kind::Failed,
            format!("shim を入れられなかった (上の cargo の出力。{:?})", r.exit),
        ));
    }
    let bin = root.join("bin");
    [SHIM_BIN, OLD_SHIM_BIN]
        .iter()
        .map(|b| bin.join(exe(b)))
        .find(|p| p.is_file())
        .ok_or_else(|| {
            Outcome::new(
                Kind::Failed,
                format!(
                    "入れたはずの shim が見つからない ({} に {} も {} も無い)",
                    bin.display(),
                    exe(SHIM_BIN),
                    exe(OLD_SHIM_BIN)
                ),
            )
        })
}

/// 出来た exe `built` を `shim` の名前で置く (shim は argv[0] を読まない。動いていても入れ替えられる `replace_file` で)。落ちたら、その行。
fn place_shim(ctx: &mut Ctx, built: &Path, shim: &Path) -> Result<(), Outcome> {
    match std::fs::read(built).and_then(|bytes| replace_file(&bytes, shim)) {
        Ok(()) => {
            ctx.say(format!(
                "置きました: {} (<- 出来た {})",
                shim.display(),
                built.file_name().unwrap_or_default().to_string_lossy()
            ));
            Ok(())
        }
        Err(e) => Err(Outcome::new(
            Kind::Failed,
            format!("shim を置けなかった ({}: {e})", shim.display()),
        )
        .note("pjp-skills を使っている会話・端末があると、入れ替えが「アクセスが拒否されました」で落ちることがある。止めてから流し直す")),
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (Linux の nix/tests/bootstrap-pjp.test.sh と同じ判断)
    //!
    //! - clone に crates/pjp-shim が無い → manual。channel・version が読めない → failed
    //! - shim (pjp-skills.exe) が無い: check は missing で何も打たない、dry-run は打つもの (入れる・置く・作る) を出して何も打たない、apply は
    //!   cargo install を clone の中で RUSTUP_TOOLCHAIN を付けて使い捨ての --root と --target-dir に打ち、出来た exe を pjp-skills.exe の名前で
    //!   置き、使い捨ての dir を消し、続けて pjp-skills --build を PJP_SKILLS_DIR を付け RUSTUP_TOOLCHAIN を外して打つ
    //! - clone の shim の crate の bin の形 (前の pjp だけ・pjp と pjp-skills・pjp-skills だけ) によらず、<CARGO_HOME>\bin に置くのは pjp-skills.exe
    //!   だけ (出来た pjp-skills があればそれ、無ければ pjp を写す)
    //! - 版が同じ → install は打たず build だけ。版が違う・起きない → fix
    //! - 前の手順が入れた shim (<CARGO_HOME>\bin\pjp.exe で、cargo の記録に pjp-shim の bin pjp.exe がある) は、公開の入口 (%LOCALAPPDATA%\dotfiles\bin
    //!   の pjp.exe と pjp-hub.exe) が揃っているときだけ外す。順は、新しい shim を使い捨ての root に作る → cargo uninstall --root <CARGO_HOME>
    //!   pjp-shim で外す → 作った shim を置く (記録に pjp-skills.exe もあれば、外すと一緒に消えるので版が同じでも作って置き直す)。作るのが落ちたら
    //!   外さない。公開の入口が揃っていなければ外さず、残すことを fix の行で知らせる (check・dry-run・apply とも)。記録に無い pjp.exe は外さずに
    //!   ⚠ で知らせる
    //! - dry-run は外すもの (cargo uninstall) も apply の順に出し、何も打たない
    //! - cargo が無い・cargo install が落ちる・入れた exe が無い・置いた shim の版が違う・build が落ちる → failed。uninstall が落ちても作った shim を
    //!   置いて道具を作り、failed の行を足す

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::process::{CommandSpec, Exit, RunResult};
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::{Path, PathBuf};

    const APPLY: Mode = Mode::Apply { force: false };

    fn exe(name: &str) -> String {
        format!("{name}{}", std::env::consts::EXE_SUFFIX)
    }

    /// 偽の shim の中身 (`--version` は 2 つ目の語を「pjp <版>」で答える。shim でない中身は起きない)
    fn shim_text(version: &str, bin: &str) -> String {
        format!("shim {version} {bin}")
    }

    /// 偽の cargo と shim の答え方
    #[derive(Clone)]
    struct Fake {
        /// cargo install が --root の bin に書く bin (clone の shim の crate の bin の形)
        bins: Vec<&'static str>,
        /// cargo install が書く shim の版
        version: &'static str,
        install: i32,
        uninstall: i32,
        build: i32,
    }

    impl Default for Fake {
        fn default() -> Self {
            Fake {
                bins: vec!["pjp", "pjp-skills"],
                version: "0.1.0",
                install: 0,
                uninstall: 0,
                build: 0,
            }
        }
    }

    struct World {
        t: TempDir,
    }

    impl World {
        fn new() -> Self {
            let t = TempDir::new("pjp");
            std::fs::create_dir_all(t.path().join("g").join("dotfiles")).unwrap();
            t.write(
                "g/claude-skills/rust-toolchain.toml",
                "[toolchain]\nchannel = \"1.99.1\"\n",
            );
            t.write(
                "g/claude-skills/crates/pjp-shim/Cargo.toml",
                "[package]\nname = \"pjp-shim\"\n# 版\nversion = \"0.1.0\"\n",
            );
            World { t }
        }

        fn clone(&self) -> PathBuf {
            self.t.path().join("g").join("claude-skills")
        }

        fn cargo_home(&self) -> PathBuf {
            self.t.path().join("cargo")
        }

        /// `<CARGO_HOME>\bin\<name>.exe`
        fn bin(&self, name: &str) -> PathBuf {
            self.cargo_home().join("bin").join(exe(name))
        }

        fn shim(&self) -> PathBuf {
            self.bin("pjp-skills")
        }

        fn old_shim(&self) -> PathBuf {
            self.bin("pjp")
        }

        /// `<CARGO_HOME>\bin` に置く
        fn place(&self, name: &str, text: &str) {
            std::fs::create_dir_all(self.cargo_home().join("bin")).unwrap();
            std::fs::write(self.bin(name), text).unwrap();
        }

        /// 公開の道具の置き場 (`%LOCALAPPDATA%\dotfiles\bin`。手順 pjp-tools が置く)
        fn public_bin(&self) -> PathBuf {
            self.t
                .path()
                .join("home")
                .join("AppData")
                .join("Local")
                .join("dotfiles")
                .join("bin")
        }

        /// 手順 pjp-tools が公開の道具 `names` (入口 pjp と pjp-hub など) を置いた後にする
        fn public(&self, names: &[&str]) {
            std::fs::create_dir_all(self.public_bin()).unwrap();
            for n in names {
                std::fs::write(self.public_bin().join(exe(n)), "public").unwrap();
            }
        }

        /// cargo の記録 (`<CARGO_HOME>\.crates.toml`) に、pjp-shim の bin を `bins` で書く (Windows の cargo は bin の名前に .exe を付けて書く)
        fn record(&self, bins: &[&str]) {
            let list: Vec<String> = bins.iter().map(|b| format!("\"{}\"", exe(b))).collect();
            std::fs::create_dir_all(self.cargo_home()).unwrap();
            std::fs::write(
                self.cargo_home().join(".crates.toml"),
                format!(
                    "[v1]\n\"pjp-shim 0.1.0 (path+file:///x/claude-skills/crates/pjp-shim)\" = [{}]\n",
                    list.join(", ")
                ),
            )
            .unwrap();
        }

        /// `<CARGO_HOME>\bin` の中の名前 (偽の cargo を除く。名前の順)
        fn placed(&self) -> Vec<String> {
            let mut names: Vec<String> = std::fs::read_dir(self.cargo_home().join("bin"))
                .unwrap()
                .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                .filter(|n| *n != exe("cargo"))
                .collect();
            names.sort();
            names
        }

        fn read(&self, p: &Path) -> String {
            std::fs::read_to_string(p).unwrap()
        }

        /// 偽の口: `--version` は打たれた exe の中身で答え、cargo install は --root の bin に `fake.bins` を書き、cargo uninstall は記録の bin と
        /// 記録を消す
        fn sys(&self, fake: Fake) -> FakeSys {
            let cargo = self.bin("cargo");
            std::fs::create_dir_all(cargo.parent().unwrap()).unwrap();
            std::fs::write(&cargo, "").unwrap();
            let home = self.cargo_home();
            let program = cargo.clone();
            FakeSys::new(move |c: &CommandSpec| {
                let args = c.args_lossy();
                let code = |n| RunResult {
                    exit: Exit::Code(n),
                    output: vec![],
                };
                if args == ["--version"] {
                    // 版は stdout だけから読む (shim の注意は stderr に出る)
                    assert!(c.stdout_only, "--version は stdout だけを取る");
                    return match std::fs::read_to_string(&c.program) {
                        Ok(t) if t.starts_with("shim ") => RunResult {
                            exit: Exit::Code(0),
                            output: vec![format!("pjp {}", t.split(' ').nth(1).unwrap_or(""))],
                        },
                        _ => code(1),
                    };
                }
                if args == ["--build"] {
                    return code(fake.build);
                }
                if c.program == program {
                    match args.first().map(String::as_str) {
                        Some("install") => {
                            if fake.install == 0 {
                                let at = args.iter().position(|a| a == "--root").unwrap();
                                let bin = PathBuf::from(&args[at + 1]).join("bin");
                                std::fs::create_dir_all(&bin).unwrap();
                                for b in &fake.bins {
                                    std::fs::write(bin.join(exe(b)), shim_text(fake.version, b))
                                        .unwrap();
                                }
                            }
                            return code(fake.install);
                        }
                        Some("uninstall") => {
                            if fake.uninstall == 0 {
                                let record = home.join(".crates.toml");
                                let text = std::fs::read_to_string(&record).unwrap_or_default();
                                for b in ["pjp", "pjp-skills"] {
                                    if text.contains(&format!("\"{}\"", exe(b))) {
                                        let _ = std::fs::remove_file(home.join("bin").join(exe(b)));
                                    }
                                }
                                let _ = std::fs::remove_file(record);
                            }
                            return code(fake.uninstall);
                        }
                        _ => {}
                    }
                }
                panic!("思わぬコマンド: {} {args:?}", c.program.display());
            })
            .with_env("CARGO_HOME", &self.cargo_home().to_string_lossy())
        }

        fn run(&self, sys: &FakeSys, mode: Mode) -> (Vec<Outcome>, String) {
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("g").join("dotfiles"),
                    roots: Roots::from_home(&self.t.path().join("home")),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys,
                    out: &mut out,
                };
                Pjp.run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        }
    }

    fn kinds(o: &[Outcome]) -> Vec<Kind> {
        o.iter().map(|x| x.kind).collect()
    }

    /// 打ったコマンドのうち、最初の引数が `first` のもの
    fn call(sys: &FakeSys, first: &str) -> Option<CommandSpec> {
        sys.calls
            .borrow()
            .iter()
            .find(|c| c.args_lossy().first().map(String::as_str) == Some(first))
            .cloned()
    }

    /// 打ったコマンドのうち、最初の引数が `first` のものの何番目か
    fn at(sys: &FakeSys, first: &str) -> usize {
        sys.calls
            .borrow()
            .iter()
            .position(|c| c.args_lossy().first().map(String::as_str) == Some(first))
            .unwrap_or_else(|| panic!("{first} を打っていない: {:?}", sys.call_args()))
    }

    #[test]
    fn installs_pjp_skills_then_builds() {
        let w = World::new();
        let sys = w.sys(Fake::default());
        let (o, _) = w.run(&sys, Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Missing], "{o:?}");
        assert!(o[0].text.contains("pjp-skills"), "{o:?}");
        assert!(
            sys.calls.borrow().is_empty(),
            "check は何も打たない (shim が無い)"
        );
        let (o, out) = w.run(&sys, Mode::DryRun { force: false });
        assert_eq!(kinds(&o), vec![Kind::Missing], "{o:?}");
        assert!(
            out.contains("[dry-run] cargo install --locked --root <使い捨ての dir>"),
            "{out}"
        );
        assert!(
            out.contains(&format!("{}", w.shim().display())),
            "置く先を出す: {out}"
        );
        assert!(out.contains("[dry-run] pjp-skills --build"), "{out}");
        assert!(sys.calls.borrow().is_empty());

        let (o, out) = w.run(&sys, APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        let install = call(&sys, "install").unwrap();
        let args = install.args_lossy();
        assert_eq!(args[..3], ["install", "--locked", "--root"]);
        let root = PathBuf::from(&args[3]);
        let work = root.parent().unwrap().to_path_buf();
        assert_eq!(root, work.join("root"));
        assert_eq!(args[4], "--target-dir");
        assert_eq!(PathBuf::from(&args[5]), work.join("target"));
        assert!(work.starts_with(std::env::temp_dir()), "{work:?}");
        assert!(!work.exists(), "使い捨ての dir は消える: {work:?}");
        assert_eq!(
            args[6..],
            [
                "--path",
                &w.clone().join("crates").join("pjp-shim").to_string_lossy()
            ]
        );
        assert_eq!(install.cwd.as_deref(), Some(w.clone().as_path()));
        assert_eq!(
            install.env_value("RUSTUP_TOOLCHAIN").as_deref(),
            Some("1.99.1")
        );
        // <CARGO_HOME>\bin に置くのは pjp-skills.exe だけ (cargo の記録も残さない)
        assert_eq!(w.placed(), vec![exe("pjp-skills")]);
        assert_eq!(w.read(&w.shim()), shim_text("0.1.0", "pjp-skills"));
        assert!(!w.cargo_home().join(".crates.toml").exists());
        let build = sys
            .calls
            .borrow()
            .iter()
            .find(|c| c.args_lossy() == ["--build"])
            .cloned()
            .unwrap();
        assert_eq!(build.program, w.shim());
        assert_eq!(
            build.env_value("PJP_SKILLS_DIR").as_deref(),
            Some(&*w.clone().to_string_lossy())
        );
        assert!(build.removes_env("RUSTUP_TOOLCHAIN"));
        assert!(at(&sys, "install") < at(&sys, "--build"));
    }

    /// clone の shim の crate の bin の形によらず、置くのは pjp-skills.exe だけ (出来た pjp-skills があればそれ、無ければ pjp を写す)
    #[test]
    fn any_bin_shape_places_only_pjp_skills() {
        for (bins, from) in [
            (vec!["pjp"], "pjp"),
            (vec!["pjp", "pjp-skills"], "pjp-skills"),
            (vec!["pjp-skills"], "pjp-skills"),
        ] {
            let w = World::new();
            let sys = w.sys(Fake {
                bins: bins.clone(),
                ..Fake::default()
            });
            let (o, out) = w.run(&sys, APPLY);
            assert_eq!(kinds(&o), vec![Kind::Ok], "{bins:?} {o:?}\n{out}");
            assert_eq!(w.placed(), vec![exe("pjp-skills")], "{bins:?}");
            assert_eq!(w.read(&w.shim()), shim_text("0.1.0", from), "{bins:?}");
        }
    }

    #[test]
    fn same_version_only_builds() {
        let w = World::new();
        w.place("pjp-skills", &shim_text("0.1.0", "pjp-skills"));
        let sys = w.sys(Fake {
            install: 9,
            ..Fake::default()
        });
        let (o, _) = w.run(&sys, Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(o[0].text.contains("0.1.0 のまま"), "{o:?}");
        let (o, out) = w.run(&sys, APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(call(&sys, "install").is_none());
        assert!(call(&sys, "--build").is_some());
    }

    #[test]
    fn other_version_or_broken_shim_is_fix() {
        let w = World::new();
        w.place("pjp-skills", &shim_text("0.0.9", "pjp-skills"));
        let (o, _) = w.run(&w.sys(Fake::default()), Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}");
        assert!(o[0].text.contains("0.0.9"), "{o:?}");
        w.place("pjp-skills", "broken");
        let (o, _) = w.run(&w.sys(Fake::default()), Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}");
        assert!(o[0].text.contains("起きない"), "{o:?}");
        let sys = w.sys(Fake::default());
        let (o, out) = w.run(&sys, APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert_eq!(w.read(&w.shim()), shim_text("0.1.0", "pjp-skills"));
    }

    /// 前の手順が入れた shim (cargo の記録に pjp-shim の bin pjp.exe) は、公開の入口が置かれていれば、新しい shim を使い捨ての root に作れてから
    /// cargo uninstall で外し、作った shim を置く。前の dotfiles が bin を 2 つとも入れた形 (記録に pjp-skills.exe もある) は、外すと
    /// pjp-skills.exe も消えるので、版が同じでも作って置き直す (置くのは外した後)
    #[test]
    fn removes_the_recorded_old_shim_after_building_the_new_one() {
        for recorded in [vec!["pjp"], vec!["pjp", "pjp-skills"]] {
            let w = World::new();
            w.public(&["pjp", "pjp-hub"]);
            w.place("pjp", &shim_text("0.1.0", "pjp"));
            if recorded.contains(&"pjp-skills") {
                w.place("pjp-skills", &shim_text("0.1.0", "pjp-skills"));
            }
            w.record(&recorded);
            let sys = w.sys(Fake::default());
            let (o, out) = w.run(&sys, Mode::Check);
            assert!(
                o.iter()
                    .any(|x| x.kind == Kind::Fix && x.text.contains("前の shim")),
                "{recorded:?} {o:?}\n{out}"
            );
            assert!(
                o.iter().any(|x| x.text.contains("pjp-skills")
                    && matches!(x.kind, Kind::Missing | Kind::Fix)),
                "{recorded:?}: pjp-skills も入れる: {o:?}"
            );
            assert!(sys.calls.borrow().is_empty(), "check は何も打たない");
            assert!(w.old_shim().exists());

            let (o, out) = w.run(&sys, APPLY);
            assert_eq!(kinds(&o), vec![Kind::Ok], "{recorded:?} {o:?}\n{out}");
            assert!(o[0].text.contains("前の shim"), "{o:?}");
            let un = call(&sys, "uninstall").unwrap();
            assert_eq!(
                un.args_lossy(),
                [
                    "uninstall",
                    "--root",
                    &*w.cargo_home().to_string_lossy(),
                    "pjp-shim"
                ]
            );
            assert_eq!(un.cwd.as_deref(), Some(w.clone().as_path()));
            assert_eq!(un.env_value("RUSTUP_TOOLCHAIN").as_deref(), Some("1.99.1"));
            // 作る → 外す → (置く) → 道具を作る。2 つとも記録にある形で置くのが外すより先なら、外すときに置いた pjp-skills.exe も消える
            assert!(
                at(&sys, "install") < at(&sys, "uninstall")
                    && at(&sys, "uninstall") < at(&sys, "--build"),
                "{:?}",
                sys.call_args()
            );
            assert_eq!(w.placed(), vec![exe("pjp-skills")], "{recorded:?}");
            assert_eq!(w.read(&w.shim()), shim_text("0.1.0", "pjp-skills"));
        }
    }

    /// 公開の入口 (`%LOCALAPPDATA%\dotfiles\bin` の pjp.exe と pjp-hub.exe。手順 pjp-tools が置く) が揃うまでは、記録のある前の shim も外さず、
    /// 残すことを fix の行で知らせる (外すと、このホストから pjp が無くなる。`dotfiles apply --steps pjp` だけを打った・同じ apply の pjp-tools が
    /// 止まったとき)。pjp-skills は入れて作る
    #[test]
    fn keeps_the_old_shim_until_the_public_pjp_is_placed() {
        let keep = |o: &Outcome| {
            o.kind == Kind::Fix
                && o.text.contains("公開の pjp (手順 pjp-tools) がまだ無いので、前の shim は残す (dotfiles apply で pjp-tools を流した後に外れる)")
        };
        for public in [vec![], vec!["pjp"], vec!["pjp-hub"]] {
            let w = World::new();
            w.public(&public);
            w.place("pjp", &shim_text("0.1.0", "pjp"));
            w.record(&["pjp"]);
            let sys = w.sys(Fake::default());
            let (o, out) = w.run(&sys, Mode::Check);
            assert!(o.iter().any(keep), "{public:?} {o:?}\n{out}");
            assert!(
                !o.iter().any(|x| x.text.contains("外す")),
                "{public:?} {o:?}"
            );
            let (o, out) = w.run(&sys, Mode::DryRun { force: false });
            assert!(
                o.iter()
                    .any(|x| keep(x) && x.text.starts_with("[dry-run] ")),
                "{public:?} {o:?}\n{out}"
            );
            assert!(!out.contains("cargo uninstall"), "{public:?}\n{out}");
            assert!(sys.calls.borrow().is_empty(), "{:?}", sys.call_args());

            let (o, out) = w.run(&sys, APPLY);
            assert_eq!(
                kinds(&o),
                vec![Kind::Ok, Kind::Fix],
                "{public:?} {o:?}\n{out}"
            );
            assert!(keep(&o[1]), "{o:?}");
            assert!(!o[0].text.contains("前の shim"), "{o:?}");
            assert!(call(&sys, "uninstall").is_none(), "{:?}", sys.call_args());
            assert_eq!(
                w.read(&w.old_shim()),
                shim_text("0.1.0", "pjp"),
                "{public:?}"
            );
            assert!(w.cargo_home().join(".crates.toml").exists());
            assert_eq!(w.read(&w.shim()), shim_text("0.1.0", "pjp-skills"));
            assert!(call(&sys, "--build").is_some());
        }

        // 前の dotfiles が bin を 2 つとも入れた形: 外さないので pjp-skills.exe も消えない。版が同じなら入れ直さない
        let w = World::new();
        w.place("pjp", &shim_text("0.1.0", "pjp"));
        w.place("pjp-skills", &shim_text("0.1.0", "pjp-skills"));
        w.record(&["pjp", "pjp-skills"]);
        let sys = w.sys(Fake {
            install: 9,
            ..Fake::default()
        });
        let (o, _) = w.run(&sys, Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Fix], "{o:?}");
        assert!(keep(&o[1]), "{o:?}");
        let (o, out) = w.run(&sys, APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Fix], "{o:?}\n{out}");
        assert!(
            call(&sys, "install").is_none() && call(&sys, "uninstall").is_none(),
            "{:?}",
            sys.call_args()
        );
        assert!(w.old_shim().exists());
        assert!(call(&sys, "--build").is_some());
    }

    /// 新しい shim を作れてから前の shim を外す: 使い捨ての root に作るのが落ちたら、前の shim は外さない (private な道具を無くさない)
    #[test]
    fn a_failed_install_keeps_the_old_shim() {
        for recorded in [vec!["pjp"], vec!["pjp", "pjp-skills"]] {
            let w = World::new();
            w.public(&["pjp", "pjp-hub"]);
            w.place("pjp", &shim_text("0.1.0", "pjp"));
            if recorded.contains(&"pjp-skills") {
                w.place("pjp-skills", &shim_text("0.1.0", "pjp-skills"));
            }
            w.record(&recorded);
            let sys = w.sys(Fake {
                install: 101,
                ..Fake::default()
            });
            let (o, out) = w.run(&sys, APPLY);
            assert_eq!(kinds(&o), vec![Kind::Failed], "{recorded:?} {o:?}\n{out}");
            assert!(o[0].text.contains("shim を入れられなかった"), "{o:?}");
            assert!(
                o[0].notes
                    .iter()
                    .any(|n| n.contains("前の shim") && n.contains("外していない")),
                "{o:?}"
            );
            assert!(
                call(&sys, "uninstall").is_none(),
                "{recorded:?} {:?}",
                sys.call_args()
            );
            assert!(call(&sys, "--build").is_none());
            assert_eq!(
                w.read(&w.old_shim()),
                shim_text("0.1.0", "pjp"),
                "{recorded:?}"
            );
            assert!(w.cargo_home().join(".crates.toml").exists());
            if recorded.contains(&"pjp-skills") {
                assert_eq!(w.read(&w.shim()), shim_text("0.1.0", "pjp-skills"));
            }
        }
    }

    /// cargo の記録に pjp-shim の bin pjp.exe が無い pjp.exe (ほかのもの) は外さずに ⚠ で知らせる (pjp-skills は入れる)
    #[test]
    fn leaves_a_foreign_pjp_and_warns() {
        for record in [
            None,
            Some(
                "[v1]\n\"other 1.0.0 (registry+https://example.invalid/index)\" = [\"pjp.exe\", \"pjp\"]\n",
            ),
            Some("[v1]\n\"pjp-shim 0.1.0 (path+file:///x)\" = [\"pjp-other.exe\"]\n"),
            Some("not toml ["),
        ] {
            let w = World::new();
            w.place("pjp", "other");
            if let Some(text) = record {
                std::fs::write(w.cargo_home().join(".crates.toml"), text).unwrap();
            }
            let sys = w.sys(Fake::default());
            let (o, out) = w.run(&sys, Mode::Check);
            assert!(
                o.iter()
                    .any(|x| x.kind == Kind::Manual && x.text.contains("外さない")),
                "{record:?} {o:?}\n{out}"
            );
            let (o, out) = w.run(&sys, APPLY);
            assert_eq!(
                kinds(&o),
                vec![Kind::Ok, Kind::Manual],
                "{record:?} {o:?}\n{out}"
            );
            assert!(o[1].text.contains("外さない"), "{o:?}");
            assert!(out.contains("!! "), "{out}");
            assert!(call(&sys, "uninstall").is_none(), "{:?}", sys.call_args());
            assert_eq!(w.read(&w.old_shim()), "other", "{record:?}");
            assert_eq!(w.read(&w.shim()), shim_text("0.1.0", "pjp-skills"));
        }
    }

    /// dry-run は外すもの (cargo uninstall)・入れるもの・置くもの・作るものを、apply で打つ順 (作る → 外す → 置く → 道具を作る) に出し、何も
    /// 打たない
    #[test]
    fn dry_run_shows_what_it_removes() {
        let w = World::new();
        w.public(&["pjp", "pjp-hub"]);
        w.place("pjp", &shim_text("0.1.0", "pjp"));
        w.record(&["pjp"]);
        let sys = w.sys(Fake::default());
        let (o, out) = w.run(&sys, Mode::DryRun { force: false });
        let uninstall = format!(
            "[dry-run] cargo uninstall --root {} pjp-shim",
            w.cargo_home().display()
        );
        let install = "[dry-run] cargo install --locked --root <使い捨ての dir>";
        let place = format!(" を {} に置く", w.shim().display());
        let build = "[dry-run] pjp-skills --build";
        let pos = |s: &str| out.find(s).unwrap_or_else(|| panic!("{s} が無い:\n{out}"));
        assert!(
            pos(install) < pos(&uninstall)
                && pos(&uninstall) < pos(&place)
                && pos(&place) < pos(build),
            "{out}"
        );
        assert!(
            o.iter()
                .any(|x| x.kind == Kind::Fix && x.text.starts_with("[dry-run] 前の shim")),
            "{o:?}"
        );
        assert!(sys.calls.borrow().is_empty(), "{:?}", sys.call_args());
        assert!(w.old_shim().exists() && !w.shim().exists());
    }

    #[test]
    fn failures() {
        // cargo が無い
        let w = World::new();
        let sys = w.sys(Fake::default());
        std::fs::remove_file(w.bin("cargo")).unwrap();
        let (o, _) = w.run(&sys, APPLY);
        assert_eq!(kinds(&o), vec![Kind::Failed], "{o:?}");
        assert!(o[0].text.contains("cargo が見つからない"), "{o:?}");

        // cargo install が落ちる: 作らない。使い捨ての dir は消す
        let w = World::new();
        let sys = w.sys(Fake {
            install: 101,
            ..Fake::default()
        });
        let (o, _) = w.run(&sys, APPLY);
        assert_eq!(kinds(&o), vec![Kind::Failed], "{o:?}");
        assert!(o[0].text.contains("shim を入れられなかった"), "{o:?}");
        assert!(call(&sys, "--build").is_none());
        let root = PathBuf::from(&call(&sys, "install").unwrap().args_lossy()[3]);
        assert!(!root.parent().unwrap().exists());

        // cargo install が通っても exe が無い
        let w = World::new();
        let sys = w.sys(Fake {
            bins: vec![],
            ..Fake::default()
        });
        let (o, _) = w.run(&sys, APPLY);
        assert_eq!(kinds(&o), vec![Kind::Failed], "{o:?}");
        assert!(
            o[0].text.contains("入れたはずの shim が見つからない"),
            "{o:?}"
        );
        assert!(call(&sys, "--build").is_none());

        // 置いた shim の版が違う
        let w = World::new();
        let sys = w.sys(Fake {
            version: "0.0.1",
            ..Fake::default()
        });
        let (o, _) = w.run(&sys, APPLY);
        assert_eq!(kinds(&o), vec![Kind::Failed], "{o:?}");
        assert!(o[0].text.contains("版が違う"), "{o:?}");

        // build が落ちる
        let w = World::new();
        let (o, _) = w.run(
            &w.sys(Fake {
                build: 101,
                ..Fake::default()
            }),
            APPLY,
        );
        assert_eq!(kinds(&o), vec![Kind::Failed], "{o:?}");
        assert!(o[0].text.contains("pjp-skills --build"), "{o:?}");

        // 前の shim を外せない: 作った shim を置いて道具を作り、落ちた行を足す
        let w = World::new();
        w.public(&["pjp", "pjp-hub"]);
        w.place("pjp", &shim_text("0.1.0", "pjp"));
        w.record(&["pjp"]);
        let sys = w.sys(Fake {
            uninstall: 101,
            ..Fake::default()
        });
        let (o, out) = w.run(&sys, APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Failed], "{o:?}\n{out}");
        assert!(at(&sys, "install") < at(&sys, "uninstall"));
        assert_eq!(w.read(&w.shim()), shim_text("0.1.0", "pjp-skills"));
        assert!(o[1].text.contains("前の shim"), "{o:?}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.contains("cargo uninstall --root")),
            "{o:?}"
        );
        assert!(w.old_shim().exists());
        assert!(call(&sys, "install").is_some() && call(&sys, "--build").is_some());

        // clone に crates/pjp-shim が無い
        let w = World::new();
        std::fs::remove_file(w.clone().join("crates").join("pjp-shim").join("Cargo.toml")).unwrap();
        let (o, _) = w.run(&w.sys(Fake::default()), Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Manual], "{o:?}");
        assert!(o[0].text.contains("crates/pjp-shim"), "{o:?}");

        // channel を読めない
        let w = World::new();
        w.t.write(
            "g/claude-skills/rust-toolchain.toml",
            "[toolchain]\nchannel = \"1.99 1\"\n",
        );
        let (o, _) = w.run(&w.sys(Fake::default()), Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Failed], "{o:?}");
        assert!(o[0].text.contains("channel"), "{o:?}");
    }

    #[test]
    fn reads_the_cargo_record() {
        let t = TempDir::new("pjp-record");
        assert_eq!(shim_record(t.path()), None, "記録が無い");
        t.write(
            ".crates.toml",
            "[v1]\n\"ripgrep 14.1.0 (registry+https://example.invalid/index)\" = [\"rg.exe\"]\n\"pjp-shim 0.2.0 (path+file:///C:/x/claude-skills/crates/pjp-shim)\" = [\"pjp.exe\", \"pjp-skills.exe\"]\n",
        );
        assert_eq!(
            shim_record(t.path()),
            Some(vec!["pjp.exe".to_string(), "pjp-skills.exe".to_string()])
        );
        t.write(
            ".crates.toml",
            "[v1]\n\"ripgrep 14.1.0 (registry+https://example.invalid/index)\" = [\"rg.exe\"]\n",
        );
        assert_eq!(shim_record(t.path()), None, "pjp-shim の行が無い");
        t.write(".crates.toml", "[v1\n");
        assert_eq!(shim_record(t.path()), None, "TOML として読めない");
    }

    #[test]
    fn reads_toml_strings() {
        let t = TempDir::new("pjp-toml");
        let p = t.write(
            "a.toml",
            "[package]\nname = \"x\"\nversion = \"0.2.0\"\n[t]\nk = 1\n",
        );
        assert_eq!(
            read_toml_string(&p, "package", "version").as_deref(),
            Some("0.2.0")
        );
        assert_eq!(read_toml_string(&p, "t", "k"), None);
        assert_eq!(read_toml_string(&p, "nope", "k"), None);
        assert_eq!(
            read_toml_string(&t.path().join("none.toml"), "a", "b"),
            None
        );
    }
}
