//! `pjp hub bake` の結合のテスト (偽のホームの一時ディレクトリに herdr-app の home と panel.json を作る。手元の herdr-app の
//! home には触らない)。panel の図の雛形 (`assets/panel/` の act・route・compare と sections.json) を焼いた写しを、golden
//! (`tests/bake/*.svg`) と比べる。
//!
//! 雛形か焼き方を直して golden を作り直すときは、`PJP_BAKE_RECORD=1 cargo test -p pjp-hc-hub --test bake` で書き直し、
//! 中身を目で確かめて commit する。golden が XML として読め、雛形の図と sections.json の marks に合っているかは、Python の
//! `scripts/test_panel_templates.py` が見る。

mod common;

use std::path::{Path, PathBuf};
use std::process::Output;

use common::{Sandbox, rel_path, stderr, stdout};

const NOW: &str = "2026-11-23T22:40:00+09:00";
const FIGURES: [&str; 3] = ["act.svg", "route.svg", "compare.svg"];
const MINIS: [&str; 3] = ["mini-flow.svg", "mini-before-after.svg", "mini-branch.svg"];

/// 図の雛形 (skill pjp-hc-hub の assets/panel。dotfiles の nix/files/claude/skills/pjp-hc-hub/assets/panel)
fn assets() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../../files/claude/skills/pjp-hc-hub/assets/panel")
}

fn goldens() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("bake")
}

/// 改行を LF にそろえて読む (Windows の checkout で CRLF になっても同じ中身とみる)。
fn read(path: &Path) -> String {
    std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("{}: {e}", path.display()))
        .replace("\r\n", "\n")
}

struct T {
    sb: Sandbox,
    /// herdr-app の home の、この会話の図のフォルダ (`<home>/pjp-hub-panel-media/TKT-n`)。
    media: PathBuf,
    panel: PathBuf,
    out: PathBuf,
}

impl T {
    /// 偽のホームの `~/.config/herdr-app` を herdr-app の home にし、雛形の図をその media に、sections.json を panel.json に置く。
    fn new(name: &str) -> T {
        let sb = Sandbox::new(name);
        let media = rel_path(&sb.home, ".config/herdr-app/pjp-hub-panel-media/TKT-n");
        for f in FIGURES.iter().chain(&MINIS) {
            sb.write(&media.join(f), read(&assets().join(f)));
        }
        let panel = rel_path(&sb.root, "scratch/hub-panel/panel.json");
        sb.write(&panel, read(&assets().join("sections.json")));
        let out = rel_path(&sb.root, "scratch/ticket-fig");
        T {
            sb,
            media,
            panel,
            out,
        }
    }

    /// `pjp-hub bake <panel.json> <ids>… --out <out>` に `extra` を足して打つ (PJP_NOW を決め、HERDR_APP_HOME は消す)。
    fn bake(&self, ids: &[&str], out: &Path, extra: &[&str]) -> Output {
        let panel = self.panel.to_string_lossy().into_owned();
        let out = out.to_string_lossy().into_owned();
        let mut args = vec!["bake", panel.as_str()];
        args.extend(ids);
        args.extend(["--out", out.as_str()]);
        args.extend(extra);
        let mut c = self.sb.hub(&args);
        c.env("PJP_NOW", NOW).env_remove("HERDR_APP_HOME");
        c.output().unwrap()
    }
}

/// golden を書き直すとき (`PJP_BAKE_RECORD` が空でない)。
fn recording() -> bool {
    std::env::var_os("PJP_BAKE_RECORD").is_some_and(|v| !v.is_empty())
}

fn ok(out: &Output) {
    assert_eq!(
        out.status.code(),
        Some(0),
        "stdout: {}\nstderr: {}",
        stdout(out),
        stderr(out)
    );
}

#[test]
fn templates_are_baked_like_the_goldens() {
    let t = T::new("goldens");
    let out = t.bake(&["act", "route", "compare"], &t.out, &[]);
    ok(&out);
    let so = stdout(&out);
    for f in FIGURES {
        let written = read(&t.out.join(f));
        let golden = goldens().join(f);
        if recording() {
            std::fs::create_dir_all(goldens()).unwrap();
            std::fs::write(&golden, &written).unwrap();
            continue;
        }
        assert_eq!(
            written,
            read(&golden),
            "{f} が golden と違う (焼き方を直したなら PJP_BAKE_RECORD=1 で書き直す)"
        );
        // panel に載せた図は書き換えない
        assert_eq!(read(&t.media.join(f)), read(&assets().join(f)), "{f}");
    }
    for want in [
        format!(
            "act: {} に書いた (flow 2・pulse 2 を焼いた)\n  caption: 2026/11/23 22:40 の panel の図: R1 手順の名前 (① ②) — 誰が何をして、何がどこへ行くか (1 行)\n",
            t.out.join("act.svg").display()
        ),
        format!(
            "route: {} に書いた (flow 2・pulse 1 を焼いた)\n",
            t.out.join("route.svg").display()
        ),
        format!(
            "compare: {} に書いた (marks なし。SVG をそのまま写した)\n  caption: 2026/11/23 22:40 の panel の図: 案 A と案 B — どこが違い、どちらを推すか (1 行)\n",
            t.out.join("compare.svg").display()
        ),
    ] {
        assert!(so.contains(&want), "{want}\n---\n{so}");
    }
    // Windows のドライブのパスにだけ、WSL から見たパスを添える
    assert_eq!(so.contains("  wsl: /mnt/"), cfg!(windows), "{so}");
    assert!(!so.contains("!!"), "{so}");
    assert_eq!(stderr(&out), "");
}

#[test]
fn minis_are_copied_and_srcs_name_their_sections() {
    let t = T::new("minis");
    let out = t.bake(&["TKT-n/mini-flow.svg", "TKT-n/act.svg"], &t.out, &[]);
    ok(&out);
    // ミニ絵は焼かずにそのまま写す。image の節の src を渡すと、その節を焼く
    assert_eq!(
        read(&t.out.join("mini-flow.svg")),
        read(&assets().join("mini-flow.svg"))
    );
    if !recording() {
        assert_eq!(
            read(&t.out.join("act.svg")),
            read(&goldens().join("act.svg"))
        );
    }
    let so = stdout(&out);
    for want in [
        format!(
            "TKT-n/mini-flow.svg: {} に写した (ミニ絵。marks は無いので、そのまま)\n  caption: 2026/11/23 22:40 の panel のミニ絵: 見出しの項目 (流れ) — 流れの説明 (小窓に出る 1 行)\n",
            t.out.join("mini-flow.svg").display()
        ),
        format!(
            "TKT-n/act.svg: {} に書いた (flow 2・pulse 2 を焼いた)\n",
            t.out.join("act.svg").display()
        ),
    ] {
        assert!(so.contains(&want), "{want}\n---\n{so}");
    }
    // 載っていない図のパスは断る
    let out = t.bake(&["TKT-n/mini-nope.svg"], &t.out, &[]);
    assert_eq!(out.status.code(), Some(1), "{}", stdout(&out));
    assert!(stderr(&out).contains("ミニ絵の行"), "{}", stderr(&out));
}

#[test]
fn sections_that_cannot_be_baked_fail_and_the_rest_are_written() {
    let t = T::new("partial");
    let out = t.bake(&["now", "act", "nope"], &t.out, &[]);
    assert_eq!(out.status.code(), Some(1), "{}", stdout(&out));
    let se = stderr(&out);
    assert!(
        se.contains("pjp hub bake: now: image の節ではありません (type \"markdown\")"),
        "{se}"
    );
    assert!(
        se.contains("pjp hub bake: nope: panel.json の sections に、この id の節がありません"),
        "{se}"
    );
    assert!(t.out.join("act.svg").is_file());
    assert!(stdout(&out).contains("act: "));
}

#[test]
fn out_dir_must_not_be_the_panel_folder() {
    let t = T::new("panel-dir");
    let dir = t.panel.parent().unwrap().to_path_buf();
    let out = t.bake(&["act"], &dir, &[]);
    assert_eq!(out.status.code(), Some(2), "{}", stdout(&out));
    assert!(
        stderr(&out).contains("は panel.json のフォルダです"),
        "{}",
        stderr(&out)
    );
    assert!(!dir.join("act.svg").exists());
}

#[test]
fn out_dir_must_be_outside_the_herdr_app_home() {
    let t = T::new("media-dir");
    // 図のフォルダ (同じ名前は panel の図そのもの)・mod のフォルダ (書くと mod が読み直す)・まだ無い下のフォルダも断る
    let home = t.sb.home.join(".config").join("herdr-app");
    for dir in [
        t.media.clone(),
        rel_path(&home, "mods/pjp-hub-panel"),
        rel_path(&home, "pjp-hub-panel-media/TKT-other/new"),
    ] {
        let out = t.bake(&["act"], &dir, &[]);
        assert_eq!(out.status.code(), Some(2), "{}", stdout(&out));
        assert!(
            stderr(&out).contains("は herdr-app の home"),
            "{}",
            stderr(&out)
        );
        assert!(!dir.join("act.svg").exists() || dir == t.media);
    }
    assert_eq!(
        read(&t.media.join("act.svg")),
        read(&assets().join("act.svg"))
    );
}

#[test]
fn a_baked_copy_is_not_baked_again() {
    let t = T::new("twice");
    ok(&t.bake(&["act"], &t.out, &[]));
    let baked = read(&t.out.join("act.svg"));
    t.sb.write(&t.media.join("act.svg"), &baked);
    let other = rel_path(&t.sb.root, "scratch/ticket-fig-2");
    let out = t.bake(&["act"], &other, &[]);
    assert_eq!(out.status.code(), Some(1), "{}", stdout(&out));
    assert!(
        stderr(&out).contains("もう焼いてある SVG です"),
        "{}",
        stderr(&out)
    );
}

#[test]
fn a_missing_figure_is_reported() {
    let t = T::new("missing");
    std::fs::remove_file(t.media.join("route.svg")).unwrap();
    let out = t.bake(&["route"], &t.out, &[]);
    assert_eq!(out.status.code(), Some(1), "{}", stdout(&out));
    assert!(stderr(&out).contains("route: 図 "), "{}", stderr(&out));
    assert!(stderr(&out).contains("を読めません"), "{}", stderr(&out));
}

#[test]
fn herdr_app_home_comes_from_the_option_then_the_env() {
    let t = T::new("home");
    // 偽のホームの既定 (~/.config/herdr-app) から図を外し、別の home にだけ置く
    let other = t.sb.root.join("app-home");
    let media = rel_path(&other, "pjp-hub-panel-media/TKT-n");
    t.sb.write(&media.join("act.svg"), read(&assets().join("act.svg")));
    std::fs::remove_file(t.media.join("act.svg")).unwrap();

    let home = other.to_string_lossy().into_owned();
    ok(&t.bake(&["act"], &t.out, &["--home", home.as_str()]));

    let panel = t.panel.to_string_lossy().into_owned();
    let out_dir = t.sb.root.join("scratch").join("ticket-fig-env");
    let out_s = out_dir.to_string_lossy().into_owned();
    let mut c =
        t.sb.hub(&["bake", panel.as_str(), "act", "--out", out_s.as_str()]);
    c.env("PJP_NOW", NOW).env("HERDR_APP_HOME", &other);
    ok(&c.output().unwrap());
    assert!(out_dir.join("act.svg").is_file());
}
