//! 入口 `pjp` (dotfiles-private の ADR 124)。bash でも PowerShell でも `pjp <道具> <引数>…` と同じ字面で打てる。
//!
//! - `pjp hub|child|mark|pack <引数…>`: 公開の道具。この exe と同じディレクトリの `pjp-<道具>` を起こし、引数と stdio をそのまま
//!   渡して、その終了コードで終わる (Unix は exec、Windows は待って終了コードを写す。待つ間の Ctrl+C は子に任せる)
//! - ほかの `pjp <引数…>` (`--build`・`--supervise` も): private な claude-skills の shim `pjp-skills` ([`pjp_core::extras::shim`]) に
//!   そのまま渡す。無ければ、private な道具がこのホストに無いと出して終了コード 127 (シェルの「コマンドが無い」と同じ)
//!
//! 入口はどのホストでも公開のこの 1 つ (ホストによって `pjp` の中身が違う形にしない)。Linux は home-manager の package、Windows は
//! runner の手順 pjp-tools が `%LOCALAPPDATA%\dotfiles\bin\` に置く。

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use pjp_core::process::{self, Cmd};
use pjp_core::{Error, Result, exit, extras};

const VERSION: &str = env!("CARGO_PKG_VERSION");
/// Release の exe に埋める key (workspace の git の tree の hash。CI が env で渡す。手元と Nix の build は空)。
const KEY: Option<&str> = option_env!("PJP_TOOLS_KEY");
/// 公開の道具 (この exe と同じディレクトリの `pjp-<道具>`)。
const PUBLIC_TOOLS: [&str; 4] = ["hub", "child", "mark", "pack"];
/// private な道具 (`pjp-skills`) が無いときの終了コード。
const NO_PRIVATE_TOOL: u8 = 127;

const USAGE: &str = "\
pjp — ハブと子の道具の入口 (dotfiles の nix/pkgs/pjp-tools)

使い方:
  pjp hub <引数…>      ハブの道具 (init・check・guard・hello・bake)。pjp hub --help
  pjp child <引数…>    子を立てる・読む・送る・片付ける。pjp child --help
  pjp mark <引数…>     space の名前と印。pjp mark --help
  pjp pack <引数…>     pack の JSON。pjp pack --help
  pjp <ほか…>          private な claude-skills の道具 (pjp ticket など)。pjp-skills にそのまま渡す
  pjp --version        版・Release の key・pjp-skills の場所
  pjp --help           この説明

公開の道具 (hub・child・mark・pack) は、この exe と同じディレクトリの pjp-<道具> を起こす。ほかは claude-skills の shim
pjp-skills (PATH → CARGO_HOME の bin → ~/.cargo/bin の順に探す) に渡し、無ければ終了コード 127 で終わる (private な
claude-skills を読めないホストには入らない)。
";

fn main() {
    let argv: Vec<OsString> = std::env::args_os().skip(1).collect();
    std::process::exit(i32::from(run(&argv)));
}

fn run(argv: &[OsString]) -> u8 {
    match argv.first().and_then(|a| a.to_str()) {
        None | Some("-h" | "--help") => {
            print!("{USAGE}");
            exit::OK
        }
        Some("--version" | "-V") => {
            println!("pjp {VERSION}");
            println!("key={}", KEY.unwrap_or(""));
            match extras::shim() {
                Some(p) => println!("{}={}", extras::SHIM, p.display()),
                None => println!("{}=無い", extras::SHIM),
            }
            exit::OK
        }
        Some(tool) if PUBLIC_TOOLS.contains(&tool) => {
            exit::report("pjp", run_public(tool, &argv[1..]), &mut std::io::stderr())
        }
        _ => run_private(argv),
    }
}

/// この exe と同じディレクトリの `pjp-<tool>` を起こす (戻るのは起こせなかったときだけ)。
fn run_public(tool: &str, args: &[OsString]) -> Result<u8> {
    let here =
        std::env::current_exe().map_err(|e| Error::io("pjp の exe の場所が分かりません", &e))?;
    let exe = sibling(&here, tool);
    if !exe.is_file() {
        return Err(Error::config(format!(
            "{} がありません (pjp と同じディレクトリに pjp-{tool} を置く。Linux は home-manager の pjp-tools、Windows は dotfiles の runner の手順 pjp-tools が置く)",
            exe.display()
        )));
    }
    match process::exec_replace(&Cmd::new(&exe).args(args)) {
        Ok(never) => match never {},
        Err(e) => Err(e),
    }
}

/// `here` (この exe) と同じディレクトリの `pjp-<tool>` (拡張子は OS の形)。
fn sibling(here: &Path, tool: &str) -> PathBuf {
    here.with_file_name(format!("pjp-{tool}{}", std::env::consts::EXE_SUFFIX))
}

/// private な claude-skills の shim に引数をそのまま渡す。無ければ 127。
fn run_private(argv: &[OsString]) -> u8 {
    let name = argv
        .first()
        .map_or_else(String::new, |a| a.to_string_lossy().into_owned());
    let Some(shim) = extras::shim() else {
        eprintln!(
            "pjp: pjp {name} は private な claude-skills の道具で、このホストには入っていません ({} が無い)。公開の道具は pjp {} (pjp --help)",
            extras::SHIM,
            PUBLIC_TOOLS.join("・")
        );
        return NO_PRIVATE_TOOL;
    };
    // pjp-skills が公開の入口そのもの (名前を替えて置いた写し) なら、渡し合いが止まらないので止める
    if std::env::current_exe()
        .ok()
        .zip(pjp_core::paths::real_path(&shim).ok())
        .is_some_and(|(here, there)| {
            pjp_core::paths::real_path(&here)
                .is_ok_and(|h| pjp_core::paths::same_path_here(&h, &there))
        })
    {
        eprintln!(
            "pjp: {} は公開の入口 pjp そのものです (claude-skills の shim を入れ直す。dotfiles の手順 pjp・bootstrap-pjp.sh)",
            shim.display()
        );
        return exit::CONFIG;
    }
    let code = match process::exec_replace(&Cmd::new(&shim).args(argv)) {
        Ok(never) => match never {},
        Err(e) => Err(e),
    };
    exit::report("pjp", code, &mut std::io::stderr())
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 公開の道具の exe は、この exe と同じディレクトリの `pjp-<道具>` (拡張子は OS の形)

    use super::*;

    #[test]
    fn sibling_is_next_to_this_exe() {
        let here = Path::new("bin").join(format!("pjp{}", std::env::consts::EXE_SUFFIX));
        assert_eq!(
            sibling(&here, "hub"),
            Path::new("bin").join(format!("pjp-hub{}", std::env::consts::EXE_SUFFIX))
        );
    }
}
