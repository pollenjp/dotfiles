//! ## 確かめること (WSL の nix/tests/bootstrap-windows-fancyzones.test.sh のケースを、runner だけの試験と WSL の script との突き合わせに分けたもの)
//!
//! runner だけの試験 (偽の Sys。Windows の CI でも流れる):
//! - 何も無い PC で設定・カスタムレイアウト・横向きの既定を作り、次の回は揃っている (書かない)
//! - 設定: 値が違えば持つキーだけを書き (ほかのキーの値・順・1 行で末尾に改行なしの形は変えない)、読めなければ 5 回読んでから知らせる
//! - カスタムレイアウト: PC で直した・消したものは残して知らせ、--force で書き換える・足し直す (退避する)。取り込みは PC の名前で選んで repo へ写す
//!   (誤りがあれば何も書かない。PC のファイルは変えない)
//! - あて方: 解像度の決まりで埋め・組を作り・記録する。解像度が変われば前にあてた組を移す。手であてた組は残し、--force で上書きする。縦向きの
//!   組には触らない。ディスプレイは -EncodedCommand で、WSL と同じ本文で聞く。PowerShell が無い・返りが決めた形でなければ書かない
//! - check と dry-run は何も書かず、カスタムレイアウトの段が足すものを PC にあるものとして見る。FancyZones がオフなら知らせる
//! - 書いた後に更新時刻を進める (touch)
//! - PowerShell の本文・記録と退避の名前・待つ秒数・書く形が WSL の script の字と同じ
//! - 本物の Windows PowerShell がディスプレイを聞く本文を流し、決めた形の JSON を返す (Windows の CI)
//!
//! WSL の script との突き合わせ (偽の powershell.exe・sleep と本物の bash・jq。要るコマンドだけの PATH): 一続きの場面 (作る・揃う・組をあてる・
//! 解像度を変える・手であてた組・--force・番号の振り直し (手であてた古い組を写す分かれ道も)・横向きの既定の組・同じ画面の組が無い画面・番号で
//! 合わせる・PC で直した/消したレイアウト・既定のレイアウトを消した・横向きの既定・repo の更新・オフ・PowerShell が無い・壊れた記録・変わった値・
//! 設定の端・dry-run) で、4 つのファイル・記録・退避の数・計画の行 (--force の行も)・警告の頭の行が同じ。取り込み (誤りも) のバイト列と文が
//! 同じ。WSL が書いたものを、記録の無い runner が変えずに引き継ぐ

use super::*;
use crate::hooks::parity;
use crate::host::{Groups, parse};
use crate::manifest::Roots;
use crate::process::{Exit, RunResult};
use crate::steps::ps1;
use crate::testutil::{FakeSys, TempDir};

const RUNNER_HOST: &str = "[runner]\nenable = true\n";
const APPLY: Mode = Mode::Apply { force: false };
const FORCE: Mode = Mode::Apply { force: true };

/// 作り物のディスプレイ (モニターの ID・instance・番号・解像度)
#[derive(Clone)]
struct Disp {
    monitor: &'static str,
    instance: &'static str,
    number: u32,
    width: u32,
    height: u32,
}

const MON_A: &str = "AAA0001";
const MON_B: &str = "BBB0002";
const MON_C: &str = "CCC0003";
const INST_A: &str = "4&11111111&0&UID101";
const INST_B: &str = "4&22222222&0&UID202";
const INST_C: &str = "4&33333333&0&UID303";
const VD1: &str = "{11111111-1111-1111-1111-111111111111}";
const VD2: &str = "{22222222-2222-2222-2222-222222222222}";
#[cfg(unix)]
const VD3: &str = "{33333333-3333-3333-3333-333333333333}";
const UUID_4K: &str = "{67070A77-52EC-4EC3-9F63-DF5E58CD4400}";
const UUID_1080: &str = "{E389FFDC-3BDD-48CB-B448-0672774C5997}";
const UUID_MINE: &str = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";

fn disp(
    monitor: &'static str,
    instance: &'static str,
    number: u32,
    width: u32,
    height: u32,
) -> Disp {
    Disp {
        monitor,
        instance,
        number,
        width,
        height,
    }
}

/// PowerShell の返り (Windows PowerShell 5.1 の ConvertTo-Json -Compress の形)
fn displays_json(ds: &[Disp], vds: &[&str]) -> String {
    let d: Vec<String> = ds
        .iter()
        .map(|d| {
            format!(
                r#"{{"device":"\\\\.\\DISPLAY{}","id":"\\\\?\\DISPLAY#{}#{}#{{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}}","width":{},"height":{}}}"#,
                d.number, d.monitor, d.instance, d.width, d.height
            )
        })
        .collect();
    let v: Vec<String> = vds.iter().map(|x| format!("\"{x}\"")).collect();
    format!(
        r#"{{"displays":[{}],"desktops":[{}]}}"#,
        d.join(","),
        v.join(",")
    )
}

/// 組 1 つ (PowerToys の形の object)
fn group(monitor: &str, instance: &str, number: u32, serial: &str, vd: &str, layout: &str) -> Jv {
    Jv::parse(&format!(
        r#"{{"device":{{"monitor":"{monitor}","monitor-instance":"{instance}","monitor-number":{number},"serial-number":"{serial}","virtual-desktop":"{vd}"}},"applied-layout":{layout}}}"#
    ))
    .unwrap()
}

fn template(t: &str) -> String {
    format!(
        r#"{{"uuid":"{{00000000-0000-0000-0000-000000000000}}","type":"{t}","show-spacing":true,"spacing":16,"zone-count":3,"sensitivity-radius":20}}"#
    )
}

fn custom(uuid: &str, zones: usize) -> String {
    format!(
        r#"{{"uuid":"{uuid}","type":"custom","show-spacing":false,"spacing":0,"zone-count":{zones},"sensitivity-radius":20}}"#
    )
}

fn applied(groups: Vec<Jv>) -> String {
    pt_form(&Jv::Object(vec![(
        "applied-layouts".into(),
        Jv::Array(groups),
    )]))
}

/// PC のエディターが作ったレイアウト (repo に無い)
fn my_layout() -> Jv {
    Jv::parse(&format!(
        r#"{{"uuid":"{UUID_MINE}","name":"mine","type":"canvas","info":{{"ref-width":1920,"ref-height":1080,"zones":[{{"X":0,"Y":0,"width":960,"height":1080}}],"sensitivity-radius":20}}}}"#
    ))
    .unwrap()
}

const FZ_SETTINGS: &str = r##"{"properties":{"fancyzones_shiftDrag":{"value":true},"fancyzones_overrideSnapHotkeys":{"value":false},"fancyzones_zoneHighlightColor":{"value":"#0078D7"},"fancyzones_highlight_opacity":{"value":50}},"name":"FancyZones","version":"1.0"}"##;

struct Env {
    t: TempDir,
}

impl Env {
    /// repo のファイル (本物の managed.json・custom-layouts.json・layout-rules.json の写し)。PC には何も無い
    fn new() -> Env {
        let e = Env {
            t: TempDir::new("fancyzones"),
        };
        for rel in [MANAGED_REL, LAYOUTS_REL, RULES_REL] {
            let p = e.repo_file(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::copy(parity::repo_file(rel), &p).unwrap();
        }
        e
    }

    fn root(&self) -> &Path {
        self.t.path()
    }

    fn repo_file(&self, rel: &str) -> PathBuf {
        join_segments(&self.root().join("repo"), rel)
    }

    fn fz(&self, name: &str) -> PathBuf {
        join_segments(
            &Roots::from_home(&self.root().join("win")).local_app_data,
            FZ_REL,
        )
        .join(name)
    }

    fn global(&self) -> PathBuf {
        join_segments(
            &Roots::from_home(&self.root().join("win")).local_app_data,
            GLOBAL_REL,
        )
    }

    fn state(&self) -> PathBuf {
        self.root().join("state")
    }

    fn put(&self, p: &Path, s: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
    }

    fn read(&self, p: &Path) -> Option<String> {
        std::fs::read_to_string(p).ok()
    }

    fn doc(&self, p: &Path) -> Jv {
        Jv::parse(&self.read(p).unwrap()).unwrap()
    }

    fn backups(&self, base: &Path) -> usize {
        std::fs::read_dir(join_segments(base, BACKUP_REL))
            .map(|d| d.count())
            .unwrap_or(0)
    }

    /// runner の手順を流す。`displays` は PowerShell の返り (None なら PowerShell が無い)
    fn run(&self, mode: Mode, displays: Option<&str>) -> (Vec<Outcome>, String, FakeSys) {
        let out_json = displays.map(str::to_string);
        let mut sys = FakeSys::new(move |c| {
            if ps1::decode_command(c).is_some() {
                RunResult {
                    exit: Exit::Code(0),
                    output: out_json.iter().cloned().collect(),
                }
            } else {
                // git diff --no-index
                RunResult {
                    exit: Exit::Code(1),
                    output: vec![],
                }
            }
        })
        .with_program("git", "/fake/git");
        if displays.is_some() {
            sys = sys.with_program("powershell", "/fake/powershell");
        }
        let mut out = Vec::new();
        let rows = {
            let mut ctx = Ctx {
                repo: self.root().join("repo"),
                roots: Roots::from_home(&self.root().join("win")),
                state_dir: self.state(),
                host: parse(
                    RUNNER_HOST,
                    Path::new("h.toml"),
                    Groups::embedded().unwrap(),
                )
                .unwrap(),
                sys: &sys,
                out: &mut out,
            };
            FancyZones.run(&mut ctx, mode)
        };
        (rows, String::from_utf8(out).unwrap(), sys)
    }

    fn kinds(rows: &[Outcome]) -> Vec<Kind> {
        rows.iter().map(|r| r.kind).collect()
    }
}

fn two_displays() -> String {
    displays_json(
        &[
            disp(MON_A, INST_A, 1, 3840, 2160),
            disp(MON_B, INST_B, 2, 1920, 1080),
        ],
        &[VD1, VD2],
    )
}

#[test]
fn creates_everything_on_a_fresh_pc_then_stays_same() {
    let e = Env::new();
    let (rows, out, _) = e.run(APPLY, Some(&two_displays()));
    assert!(rows.iter().all(|r| r.kind == Kind::Ok), "{rows:?}\n{out}");
    assert_eq!(
        e.read(&e.fz("settings.json")).unwrap(),
        r#"{"properties":{"fancyzones_overrideSnapHotkeys":{"value":true}},"name":"FancyZones","version":"1.0"}"#
    );
    let layouts = e.read(&e.fz("custom-layouts.json")).unwrap();
    // repo のファイルは PowerToys の形なので、そのまま同じバイト列になる
    assert_eq!(layouts, e.read(&e.repo_file(LAYOUTS_REL)).unwrap());
    assert!(!layouts.ends_with('\n'));
    let dl = e.doc(&e.fz("default-layouts.json"));
    assert_eq!(
        dl.compact(),
        format!(
            r#"{{"default-layouts":[{{"monitor-configuration":"horizontal","layout":{{"uuid":"{UUID_1080}","type":"custom","show-spacing":false,"spacing":0,"zone-count":0,"sensitivity-radius":0}}}}]}}"#
        )
    );
    // applied-layouts.json が無いので、あて方の段は何もしない (PowerShell も呼ばない)
    assert!(!out.contains("ディスプレイへのあて方"), "{out}");
    assert!(e.state().join(RECORD_FILE).exists());
    assert_eq!(e.backups(&e.state()), 0);

    let snapshot: Vec<Option<String>> = [
        "settings.json",
        "custom-layouts.json",
        "default-layouts.json",
    ]
    .iter()
    .map(|n| e.read(&e.fz(n)))
    .collect();
    let (rows, out, _) = e.run(APPLY, Some(&two_displays()));
    assert!(rows.iter().all(|r| r.kind == Kind::Ok), "{rows:?}");
    assert!(
        out.contains("FancyZones の設定は揃っています (持つキー 1 件)。"),
        "{out}"
    );
    assert!(
        out.contains("カスタムレイアウトは揃っています (dotfiles のもの 2 件)"),
        "{out}"
    );
    assert!(
        out.contains("横向きの既定のレイアウトは揃っています (1080p)"),
        "{out}"
    );
    let again: Vec<Option<String>> = [
        "settings.json",
        "custom-layouts.json",
        "default-layouts.json",
    ]
    .iter()
    .map(|n| e.read(&e.fz(n)))
    .collect();
    assert_eq!(snapshot, again);
}

#[test]
fn settings_keep_other_keys_and_order() {
    let e = Env::new();
    e.put(&e.fz("settings.json"), FZ_SETTINGS);
    let (rows, out, _) = e.run(Mode::Check, None);
    assert_eq!(rows[0].kind, Kind::Fix, "{out}");
    assert!(
        out.contains("fancyzones_overrideSnapHotkeys.value false → true"),
        "{out}"
    );
    assert_eq!(e.read(&e.fz("settings.json")).unwrap(), FZ_SETTINGS);
    let (rows, out, _) = e.run(APPLY, None);
    assert_eq!(rows[0].kind, Kind::Ok, "{out}");
    assert!(out.contains("FancyZones の設定を dotfiles の値へ戻しました: properties.fancyzones_overrideSnapHotkeys.value false → true"), "{out}");
    assert_eq!(
        e.read(&e.fz("settings.json")).unwrap(),
        FZ_SETTINGS.replace(
            r#""fancyzones_overrideSnapHotkeys":{"value":false}"#,
            r#""fancyzones_overrideSnapHotkeys":{"value":true}"#
        )
    );
    // 読めない: 5 回読んでから知らせ、書かない
    e.put(&e.fz("settings.json"), "");
    let (rows, out, sys) = e.run(APPLY, None);
    assert_eq!(rows[0].kind, Kind::Failed, "{out}");
    assert_eq!(sys.sleeps.borrow().len(), 5);
    assert_eq!(e.read(&e.fz("settings.json")).unwrap(), "");
}

#[test]
fn layouts_kept_force_and_import() {
    let e = Env::new();
    e.run(APPLY, None);
    // PC のエディターで 1080p を直した: 書き換えずに知らせる
    let mut pc = e.doc(&e.fz("custom-layouts.json"));
    let mut list = pc
        .get("custom-layouts")
        .unwrap()
        .as_array()
        .unwrap()
        .clone();
    list[1].set("name", Jv::from("1080p-mine"));
    list.push(my_layout());
    pc.set("custom-layouts", Jv::Array(list));
    let edited = pt_form(&pc);
    e.put(&e.fz("custom-layouts.json"), &edited);
    let (rows, out, _) = e.run(APPLY, None);
    assert!(Env::kinds(&rows).contains(&Kind::Manual), "{rows:?}\n{out}");
    assert!(out.contains("1080p: PC のエディターで直されています (前に足した中身と違う) (PC での名前は「1080p-mine」)"), "{out}");
    assert!(
        out.contains("dotfiles import fancyzones '1080p-mine'"),
        "{out}"
    );
    assert_eq!(e.read(&e.fz("custom-layouts.json")).unwrap(), edited);
    // --force: repo の中身にする (PC にだけあるものは残す)・退避する
    let (_, out, _) = e.run(FORCE, None);
    assert!(out.contains("1080p: 書き換える (--force)"), "{out}");
    let list = e.doc(&e.fz("custom-layouts.json"));
    let names: Vec<String> = list
        .get("custom-layouts")
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l.get("name").unwrap().tostring())
        .collect();
    assert_eq!(names, vec!["4k-43inch", "1080p", "mine"]);
    assert_eq!(e.backups(&e.state()), 1);

    // 取り込み: PC のレイアウトを名前で選んで repo へ写す (PC のファイルは変えない)
    let before_pc = e.read(&e.fz("custom-layouts.json"));
    let sys = FakeSys::new(|_| RunResult {
        exit: Exit::Code(0),
        output: vec![],
    })
    .with_program("git", "/fake/git");
    let mut out = Vec::new();
    let o = {
        let mut ctx = Ctx {
            repo: e.root().join("repo"),
            roots: Roots::from_home(&e.root().join("win")),
            state_dir: e.state(),
            host: parse(
                RUNNER_HOST,
                Path::new("h.toml"),
                Groups::embedded().unwrap(),
            )
            .unwrap(),
            sys: &sys,
            out: &mut out,
        };
        import(&mut ctx, &["mine".to_string(), "nothing".to_string()])
    };
    let out = String::from_utf8(out).unwrap();
    assert_eq!(o.kind, Kind::Failed, "{out}");
    assert!(out.contains("PC に「nothing」というカスタムレイアウトがありません (PC にあるもの: 4k-43inch、1080p、mine)。"), "{out}");
    assert_eq!(
        e.read(&e.repo_file(LAYOUTS_REL)),
        std::fs::read_to_string(parity::repo_file(LAYOUTS_REL)).ok()
    );
    let mut out = Vec::new();
    let o = {
        let mut ctx = Ctx {
            repo: e.root().join("repo"),
            roots: Roots::from_home(&e.root().join("win")),
            state_dir: e.state(),
            host: parse(
                RUNNER_HOST,
                Path::new("h.toml"),
                Groups::embedded().unwrap(),
            )
            .unwrap(),
            sys: &sys,
            out: &mut out,
        };
        import(&mut ctx, &["mine".to_string()])
    };
    let out = String::from_utf8(out).unwrap();
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert!(out.contains("  mine: 足した"), "{out}");
    let repo = e.read(&e.repo_file(LAYOUTS_REL)).unwrap();
    assert!(repo.contains(UUID_MINE) && repo.contains("\r\n") && !repo.ends_with('\n'));
    assert_eq!(e.read(&e.fz("custom-layouts.json")), before_pc);

    // PC で消した (記録はある): 足し直さずに知らせる
    let e = Env::new();
    e.run(APPLY, None);
    let mut pc = e.doc(&e.fz("custom-layouts.json"));
    let mut list = pc
        .get("custom-layouts")
        .unwrap()
        .as_array()
        .unwrap()
        .clone();
    list.remove(0);
    pc.set("custom-layouts", Jv::Array(list));
    e.put(&e.fz("custom-layouts.json"), &pt_form(&pc));
    let (_, out, _) = e.run(APPLY, None);
    assert!(out.contains("4k-43inch: PC から消えています"), "{out}");
    let (_, out, _) = e.run(FORCE, None);
    assert!(
        out.contains("4k-43inch: 足し直す (--force。PC に無かった)"),
        "{out}"
    );
}

#[test]
fn assigns_layouts_by_resolution_and_creates_groups() {
    let e = Env::new();
    e.run(APPLY, None);
    e.put(
        &e.fz("applied-layouts.json"),
        &applied(vec![
            group(MON_A, INST_A, 1, "0", VD1, &template("priority-grid")),
            group(MON_B, INST_B, 2, "0", VD1, &template("grid")),
            group(MON_C, INST_C, 3, "0", VD1, &template("grid")),
        ]),
    );
    let shows = displays_json(
        &[
            disp(MON_A, INST_A, 1, 3840, 2160),
            disp(MON_B, INST_B, 2, 1920, 1080),
            disp(MON_C, INST_C, 3, 1080, 1920),
        ],
        &[VD1, VD2],
    );
    let (rows, out, sys) = e.run(Mode::Check, Some(&shows));
    assert!(Env::kinds(&rows).contains(&Kind::Fix), "{rows:?}\n{out}");
    assert!(
        out.contains(
            "AAA0001 (UID101)・3840x2160・仮想デスクトップ 11111111: priority-grid → 4k-43inch"
        ),
        "{out}"
    );
    assert!(
        out.contains("AAA0001 (UID101)・3840x2160・仮想デスクトップ 22222222: 組なし → 4k-43inch"),
        "{out}"
    );
    assert!(
        out.contains("BBB0002 (UID202)・1920x1080・仮想デスクトップ 22222222: 組なし → 1080p"),
        "{out}"
    );
    assert!(
        out.contains("つながっていない・縦向きのディスプレイの組 (1 組) には触りません。"),
        "{out}"
    );
    assert!(!e.state().join(ASSIGNED_FILE).exists());
    // ディスプレイは -EncodedCommand で聞く (本文は WSL と同じ)
    let body = sys
        .calls
        .borrow()
        .iter()
        .find_map(ps1::decode_command)
        .unwrap();
    assert_eq!(body, assign::PS_BODY);

    let (rows, out, _) = e.run(APPLY, Some(&shows));
    assert!(rows.iter().all(|r| r.kind == Kind::Ok), "{rows:?}\n{out}");
    let apl = e.doc(&e.fz("applied-layouts.json"));
    let groups = apl.get("applied-layouts").unwrap().as_array().unwrap();
    assert_eq!(groups.len(), 5);
    assert_eq!(
        groups[0].get("applied-layout").unwrap().compact(),
        custom(UUID_4K, 7).replace(' ', "")
    );
    assert_eq!(
        groups[2].get("applied-layout").unwrap().compact(),
        template("grid")
    );
    let created = &groups[3];
    assert_eq!(
        created.get("device").unwrap().compact(),
        format!(
            r#"{{"monitor":"{MON_A}","monitor-instance":"{INST_A}","monitor-number":1,"serial-number":"0","virtual-desktop":"{VD2}"}}"#
        )
    );
    let rec = e.doc(&e.state().join(ASSIGNED_FILE));
    assert_eq!(
        rec.get("assignments").unwrap().as_object().unwrap().len(),
        4,
        "{}",
        rec.compact()
    );
    assert!(!rec.compact().contains("serial"));
    let (_, out, _) = e.run(APPLY, Some(&shows));
    assert!(out.contains("FancyZones のディスプレイへのあて方は揃っています (決まりのレイアウトの組 4 組。つながっていない・縦向きのディスプレイの組 1 組には触りません)。"), "{out}");

    // 解像度が変わった: 前にあてた組を新しい目標へ移す
    let lower = displays_json(
        &[
            disp(MON_A, INST_A, 1, 2560, 1440),
            disp(MON_B, INST_B, 2, 1920, 1080),
        ],
        &[VD1, VD2],
    );
    let (_, out, _) = e.run(APPLY, Some(&lower));
    assert!(out.contains("AAA0001 (UID101)・2560x1440・仮想デスクトップ 11111111: 4k-43inch → 1080p (前に決まりであてたもの)"), "{out}");
    // 手であてた組は残し、--force で上書きする
    let mut apl = e.doc(&e.fz("applied-layouts.json"));
    let mut groups = apl
        .get("applied-layouts")
        .unwrap()
        .as_array()
        .unwrap()
        .clone();
    groups[1].set("applied-layout", Jv::parse(&template("blank")).unwrap());
    apl.set("applied-layouts", Jv::Array(groups));
    e.put(&e.fz("applied-layouts.json"), &pt_form(&apl));
    let (rows, out, _) = e.run(APPLY, Some(&lower));
    assert!(
        out.contains("手であてたカスタムレイアウト・blank の組 (1 組) は残しました"),
        "{out}"
    );
    assert!(rows.iter().all(|r| r.kind == Kind::Ok), "{rows:?}");
    let (_, out, _) = e.run(FORCE, Some(&lower));
    assert!(
        out.contains(
            "BBB0002 (UID202)・1920x1080・仮想デスクトップ 11111111: blank → 1080p (--force)"
        ),
        "{out}"
    );
}

#[test]
fn powershell_failures_write_nothing() {
    let e = Env::new();
    e.run(APPLY, None);
    let apl = applied(vec![group(MON_A, INST_A, 1, "0", VD1, &template("grid"))]);
    e.put(&e.fz("applied-layouts.json"), &apl);
    // PowerShell が無い
    let (rows, out, _) = e.run(APPLY, None);
    assert!(Env::kinds(&rows).contains(&Kind::Failed), "{out}");
    assert_eq!(e.read(&e.fz("applied-layouts.json")).unwrap(), apl);
    // 決めた形の JSON でない
    let (rows, out, _) = e.run(APPLY, Some("{\"displays\":1}"));
    assert!(Env::kinds(&rows).contains(&Kind::Failed), "{out}");
    assert!(out.contains("決めた形の JSON ではありません"), "{out}");
    assert_eq!(e.read(&e.fz("applied-layouts.json")).unwrap(), apl);
}

#[test]
fn reports_fancyzones_off() {
    let e = Env::new();
    e.put(
        &e.global(),
        r#"{"startup":true,"enabled":{"Keyboard Manager":true,"FancyZones":false},"run_elevated":false}"#,
    );
    let (rows, out, _) = e.run(Mode::DryRun { force: false }, None);
    assert_eq!(rows.last().unwrap().kind, Kind::Manual, "{out}");
    assert!(out.contains("FancyZones がオフなので"), "{out}");
    assert!(!e.fz("settings.json").exists());
    // dry-run は何も書かない
    assert!(!e.fz("custom-layouts.json").exists() && !e.state().exists());
}

/// 書いた後に更新時刻を今にする (FancyZones は LastWriteTime の変更しか見ない)
#[test]
fn touch_moves_the_write_time() {
    let e = Env::new();
    let p = e.fz("settings.json");
    e.put(&p, "{}");
    let old = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(946_684_800);
    std::fs::File::options()
        .write(true)
        .open(&p)
        .unwrap()
        .set_modified(old)
        .unwrap();
    touch(&p).unwrap();
    let now = std::fs::metadata(&p).unwrap().modified().unwrap();
    assert!(
        now > old + std::time::Duration::from_secs(3600 * 24 * 365),
        "{now:?}"
    );
    assert!(touch(&e.fz("missing.json")).is_err());
}

/// check も dry-run と同じく、カスタムレイアウトの段が足すレイアウトを PC にあるものとして見る (何も無い PC で、組にあてる・作ると出す)
#[test]
fn check_sees_layouts_it_would_add() {
    let e = Env::new();
    e.put(
        &e.fz("applied-layouts.json"),
        &applied(vec![
            group(MON_A, INST_A, 1, "0", VD1, &template("priority-grid")),
            group(MON_B, INST_B, 2, "0", VD1, &template("priority-grid")),
        ]),
    );
    for mode in [Mode::Check, Mode::DryRun { force: false }] {
        let (rows, out, _) = e.run(mode, Some(&two_displays()));
        assert!(
            rows.iter().all(|r| r.kind != Kind::Manual),
            "{mode:?}: {rows:?}\n{out}"
        );
        assert!(
            out.contains(
                "AAA0001 (UID101)・3840x2160・仮想デスクトップ 11111111: priority-grid → 4k-43inch"
            ),
            "{mode:?}: {out}"
        );
        assert!(out.contains("組なし → 1080p"), "{mode:?}: {out}");
        assert!(!e.fz("custom-layouts.json").exists() && !e.state().exists());
    }
    // 何も足さないなら、check も足りないと出す (PC で消したレイアウト)
    let e = Env::new();
    e.run(APPLY, None);
    let mut pc = e.doc(&e.fz("custom-layouts.json"));
    let mut list = pc
        .get("custom-layouts")
        .unwrap()
        .as_array()
        .unwrap()
        .clone();
    list.remove(1);
    pc.set("custom-layouts", Jv::Array(list));
    e.put(&e.fz("custom-layouts.json"), &pt_form(&pc));
    let (rows, out, _) = e.run(Mode::Check, Some(&two_displays()));
    assert!(
        rows.iter()
            .any(|r| r.kind == Kind::Manual && r.text.contains("1080p")),
        "{rows:?}\n{out}"
    );
}

/// PowerShell の本文・記録と退避の名前・待つ秒数・書く形が WSL の script と同じ (bash の版が流れない Windows の CI でも比べる)
#[test]
fn matches_the_wsl_script_text() {
    let text = std::fs::read_to_string(parity::repo_file(
        "nix/scripts/bootstrap-windows-fancyzones.sh",
    ))
    .unwrap()
    .replace("\r\n", "\n");
    let info = FancyZones.info();
    assert!(
        text.lines()
            .any(|l| l == format!("# order: {}", info.order))
    );
    assert!(!text.lines().any(|l| l.starts_with("# tool: ")));
    assert!(text.contains(&format!("\n{}\nEOS\n", assign::PS_BODY)));
    assert!(text.contains(&format!("managed_rel=\"{MANAGED_REL}\"")));
    assert!(text.contains(&format!("layouts_rel=\"{LAYOUTS_REL}\"")));
    assert!(text.contains(&format!("rules_rel=\"{RULES_REL}\"")));
    assert!(text.contains(&format!("record_file=\"${{state_dir}}/{RECORD_FILE}\"")));
    assert!(text.contains(&format!("assigned_file=\"${{state_dir}}/{ASSIGNED_FILE}\"")));
    assert!(text.contains(&format!("backup_root=\"${{state_dir}}/{BACKUP_REL}\"")));
    assert!(text.contains(&format!("keep_backups={KEEP_BACKUPS}\n")));
    assert!(text.contains(&format!(
        "fz_dir=\"${{windows_home}}/AppData/Local/{FZ_REL}\""
    )));
    assert!(text.contains(&format!(
        "global_json=\"${{windows_home}}/AppData/Local/{GLOBAL_REL}\""
    )));
    assert!(text.contains(&format!(
        "ps_out=$(timeout {} powershell.exe -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand \"${{enc}}\"",
        assign::PS_SECS
    )));
    assert!(text.contains("body=$(jq --indent 2 .) || return 1"));
    assert!(text.contains("printf '%s' \"${body//$'\\n'/$'\\r\\n'}\""));
    assert!(text.contains("jq -ecj --slurpfile m \"${managed_file}\""));
    assert!(text.contains(r#"{uuid: $uuid, type: "custom", "show-spacing": false, spacing: 0, "zone-count": (.info.zones | length),"#));
    assert!(text.contains(r#"{uuid: $tl.uuid, type: "custom", "show-spacing": false, spacing: 0, "zone-count": 0, "sensitivity-radius": 0} as $want"#));
}

/// 本物の Windows PowerShell が、ディスプレイと仮想デスクトップを聞く本文を -EncodedCommand で流し、決めた形の JSON を返す (Windows。読むだけ)
#[cfg(windows)]
#[test]
fn real_powershell_answers_displays() {
    use crate::process::{RealSys, Sys};
    let Some(shell) = RealSys.which("powershell") else {
        return;
    };
    let spec = ps1::encoded_command(shell, assign::PS_BODY, std::time::Duration::from_secs(120))
        .stdout_only();
    let r = RealSys.run(&spec, &mut |_| {});
    assert_eq!(r.exit, Exit::Code(0), "{:?}", r.output);
    let v = Jv::parse(&r.output.join("\n")).unwrap_or_else(|e| panic!("{e}: {:?}", r.output));
    assert!(
        matches!(v.get("displays"), Some(Jv::Array(_))),
        "{}",
        v.compact()
    );
    assert!(
        matches!(v.get("desktops"), Some(Jv::Array(_))),
        "{}",
        v.compact()
    );
}

/// 突き合わせに使う、要るコマンドだけを並べた PATH (本物の powershell.exe を見せない)
#[cfg(unix)]
fn sys_bin(dir: &Path) -> PathBuf {
    let bin = dir.join("sys-bin");
    std::fs::create_dir_all(&bin).unwrap();
    let path = std::env::var_os("PATH").unwrap_or_default();
    for c in [
        "jq", "cat", "mkdir", "rm", "dirname", "sed", "grep", "cp", "mktemp", "date", "diff",
        "git", "timeout", "od", "base64", "tr", "mv", "touch", "bash",
    ] {
        let found = std::env::split_paths(&path)
            .filter(|d| !d.starts_with("/mnt"))
            .map(|d| d.join(c))
            .find(|p| p.is_file())
            .unwrap_or_else(|| panic!("{c} が無い"));
        std::os::unix::fs::symlink(found, bin.join(c)).unwrap();
    }
    bin
}

/// 偽の powershell.exe (FAKE_DISPLAYS のファイルの中身を CRLF で返す) と sleep (待たない)
#[cfg(unix)]
fn fake_bin(dir: &Path, bash: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = dir.join("fake-bin");
    std::fs::create_dir_all(&bin).unwrap();
    for (name, body) in [
        (
            "powershell.exe",
            "if [[ -n ${FAKE_PS_RC-} ]]; then echo boom >&2; exit \"${FAKE_PS_RC}\"; fi\nwhile IFS= read -r l; do printf '%s\\r\\n' \"${l}\"; done <\"${FAKE_DISPLAYS}\"\n",
        ),
        ("sleep", "exit 0\n"),
    ] {
        let p = bin.join(name);
        std::fs::write(&p, format!("#!{}\n{body}", bash.display())).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    bin
}

/// WSL の script を、使い捨ての HOME (`<root>/home`)・Windows のホーム (`<root>/win`)・checkout (`<root>/repo`) で流す
#[cfg(unix)]
fn wsl_run(e: &Env, args: &[&str], displays: Option<&str>) -> (i32, String) {
    let root = e.root();
    let state = root.join("home/.local/state/dotfiles/windows-files.json");
    // WSL の script は Windows のホームが無いと止まる (/mnt/c が見えないとき)
    std::fs::create_dir_all(root.join("win")).unwrap();
    if !state.exists() {
        e.put(
            &state,
            &serde_json::json!({"enable": true, "version": 1, "windowsHome": root.join("win")})
                .to_string(),
        );
        let script = root.join("repo/nix/scripts/bootstrap-windows-fancyzones.sh");
        std::fs::create_dir_all(script.parent().unwrap()).unwrap();
        std::fs::copy(
            parity::repo_file("nix/scripts/bootstrap-windows-fancyzones.sh"),
            &script,
        )
        .unwrap();
    }
    let tools = root.join(format!("tools-{}", std::process::id()));
    let sys = sys_bin(&tools);
    let bash = sys.join("bash");
    let fakes = fake_bin(&tools, &bash);
    let shows = tools.join("displays.json");
    std::fs::write(&shows, format!("{}\n", displays.unwrap_or(""))).unwrap();
    let mut path = format!("{}:{}", fakes.display(), sys.display());
    if displays.is_none() {
        // PowerShell が無い
        std::fs::remove_file(fakes.join("powershell.exe")).unwrap();
        path = format!("{}:{}", fakes.display(), sys.display());
    }
    let o = std::process::Command::new(&bash)
        .arg(root.join("repo/nix/scripts/bootstrap-windows-fancyzones.sh"))
        .args(args)
        .env_clear()
        .env("HOME", root.join("home"))
        .env("PATH", path)
        .env("FAKE_DISPLAYS", &shows)
        .env("TMPDIR", &tools)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let _ = std::fs::remove_dir_all(&tools);
    (
        o.status.code().unwrap_or(-1),
        format!(
            "{}{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        ),
    )
}

/// 打つコマンドを含む行 (受け持ちで替えるので、WSL と runner で字が違う)
#[cfg(unix)]
fn names_a_command(l: &str) -> bool {
    [
        "bootstrap-windows",
        "dotfiles apply",
        "dotfiles import",
        "WSL で",
    ]
    .iter()
    .any(|c| l.contains(c))
}

/// 比べる出力の行 (段の見出し・計画の行 (--force の行も)・揃っている行。置き場所の頭は <root> に、コマンドと退避の行は除く)
#[cfg(unix)]
fn plan_lines(out: &str, root: &Path) -> Vec<String> {
    let r = root.display().to_string();
    out.lines()
        .map(|l| l.replace(&r, "<root>"))
        .filter(|l| {
            (l.starts_with("==> ")
                || (l.starts_with("  ") && !l.starts_with("   "))
                || l.starts_with("FancyZones の"))
                && !l.contains("退避しました")
                && !names_a_command(l)
        })
        .collect()
}

/// 比べる警告の頭の行 (WSL は stderr に出すので、計画の行とは分けて、警告どうしの順で比べる。PowerShell の呼び名が違う警告 (powershell.exe と
/// Windows PowerShell) は除く)
#[cfg(unix)]
fn warn_lines(out: &str, root: &Path) -> Vec<String> {
    let r = root.display().to_string();
    out.lines()
        // 記録の置き場は WSL と runner で違う
        .map(|l| {
            l.replace(&format!("{r}/home/.local/state/dotfiles"), "<state>")
                .replace(&format!("{r}/state"), "<state>")
                .replace(&r, "<root>")
        })
        .filter(|l| {
            l.starts_with("!! ") && !l.to_lowercase().contains("powershell") && !names_a_command(l)
        })
        .collect()
}

/// WSL の script と runner を同じ引数で 1 回ずつ流し、書いた 4 つのファイル・記録・退避の数・比べる出力の行が同じかを見る
#[cfg(unix)]
fn compare(name: &str, wsl: &Env, ours: &Env, args: &[&str], shows: Option<&str>) {
    let (code, wsl_out) = wsl_run(wsl, args, shows);
    assert_eq!(code, 0, "{name}: {wsl_out}");
    let mode = if args.contains(&"--dry-run") {
        Mode::DryRun {
            force: args.contains(&"--force"),
        }
    } else {
        Mode::Apply {
            force: args.contains(&"--force"),
        }
    };
    let (_, out, _) = ours.run(mode, shows);
    let ctx = format!("{name}:\n--- WSL\n{wsl_out}\n--- runner\n{out}");
    for f in [
        "settings.json",
        "custom-layouts.json",
        "default-layouts.json",
        "applied-layouts.json",
    ] {
        assert_eq!(ours.read(&ours.fz(f)), wsl.read(&wsl.fz(f)), "{f} {ctx}");
    }
    let wsl_state = wsl.root().join("home/.local/state/dotfiles");
    for rec in [RECORD_FILE, ASSIGNED_FILE] {
        assert_eq!(
            ours.read(&ours.state().join(rec)),
            wsl.read(&wsl_state.join(rec)),
            "{rec} {ctx}"
        );
    }
    assert_eq!(
        ours.backups(&ours.state()),
        wsl.backups(&wsl_state),
        "退避 {ctx}"
    );
    assert_eq!(
        plan_lines(&out, ours.root()),
        plan_lines(&wsl_out, wsl.root()),
        "{ctx}"
    );
    assert_eq!(
        warn_lines(&out, ours.root()),
        warn_lines(&wsl_out, wsl.root()),
        "{ctx}"
    );
}

/// 両方の場に同じ変更をする
#[cfg(unix)]
fn both(wsl: &Env, ours: &Env, f: impl Fn(&Env)) {
    f(wsl);
    f(ours);
}

/// PC のエディターで作ったレイアウトを足す
#[cfg(unix)]
fn add_mine(e: &Env) {
    let mut pc = e.doc(&e.fz("custom-layouts.json"));
    let mut list = pc
        .get("custom-layouts")
        .unwrap()
        .as_array()
        .unwrap()
        .clone();
    list.push(my_layout());
    pc.set("custom-layouts", Jv::Array(list));
    e.put(&e.fz("custom-layouts.json"), &pt_form(&pc));
}

/// WSL の script と runner を一続きの場面で同じ状態から流し、書いたファイル・記録・退避の数・計画の行が同じかを見る。bash・jq が無ければ飛ばし、
/// CI の Linux の job は飛ばさない
#[cfg(unix)]
#[test]
fn does_what_the_wsl_script_does() {
    if !parity::available() {
        return;
    }
    let wsl = Env::new();
    let ours = Env::new();
    type Change = Box<dyn Fn(&Env)>;
    let none: fn() -> Change = || Box::new(|_| {});
    let shows_two = two_displays();
    let shows_three = displays_json(
        &[
            disp(MON_A, INST_A, 1, 3840, 2160),
            disp(MON_B, INST_B, 2, 1920, 1080),
            disp(MON_C, INST_C, 3, 1080, 1920),
        ],
        &[VD1, VD2, VD3],
    );
    let shows_renumbered = displays_json(
        &[
            disp(MON_A, INST_A, 2, 3840, 2160),
            disp(MON_B, INST_B, 1, 1920, 1080),
        ],
        &[VD1, VD2],
    );
    let shows_lower = displays_json(
        &[
            disp(MON_A, INST_A, 1, 2560, 1440),
            disp(MON_B, INST_B, 2, 1920, 1080),
        ],
        &[VD1, VD2],
    );
    let edit_layout = |rename: bool, drop_first: bool, add_mine: bool| -> Change {
        Box::new(move |e: &Env| {
            let mut pc = e.doc(&e.fz("custom-layouts.json"));
            let mut list = pc
                .get("custom-layouts")
                .unwrap()
                .as_array()
                .unwrap()
                .clone();
            if rename {
                list[1].set("name", Jv::from("1080p-mine"));
            }
            if drop_first {
                list.remove(0);
            }
            if add_mine {
                list.push(my_layout());
            }
            pc.set("custom-layouts", Jv::Array(list));
            e.put(&e.fz("custom-layouts.json"), &pt_form(&pc));
        })
    };
    let set_group = |i: usize, layout: String| -> Change {
        Box::new(move |e: &Env| {
            let mut apl = e.doc(&e.fz("applied-layouts.json"));
            let mut groups = apl
                .get("applied-layouts")
                .unwrap()
                .as_array()
                .unwrap()
                .clone();
            groups[i].set("applied-layout", Jv::parse(&layout).unwrap());
            apl.set("applied-layouts", Jv::Array(groups));
            e.put(&e.fz("applied-layouts.json"), &pt_form(&apl));
        })
    };
    let steps: Vec<(&str, Change, &[&str], Option<String>)> = vec![
        ("何も無い PC", none(), &[], Some(shows_two.clone())),
        ("2 回目", none(), &[], Some(shows_two.clone())),
        (
            "設定画面で変えた・他のキーがある",
            Box::new(|e: &Env| e.put(&e.fz("settings.json"), FZ_SETTINGS)),
            &[],
            Some(shows_two.clone()),
        ),
        (
            "テンプレートの組 (縦向きとシリアル違いも)",
            Box::new(|e: &Env| {
                e.put(
                    &e.fz("applied-layouts.json"),
                    &applied(vec![
                        group(MON_A, INST_A, 1, "0", VD1, &template("priority-grid")),
                        group(MON_A, INST_A, 1, "7", VD1, &template("columns")),
                        group(MON_B, INST_B, 2, "0", VD1, &template("grid")),
                        group(MON_C, INST_C, 3, "0", VD1, &template("grid")),
                        Jv::parse(r#"{"device":"broken"}"#).unwrap(),
                    ]),
                )
            }),
            &["--dry-run"],
            Some(shows_three.clone()),
        ),
        (
            "テンプレートの組を埋めて、組を作る",
            none(),
            &[],
            Some(shows_three.clone()),
        ),
        ("揃っている", none(), &[], Some(shows_three.clone())),
        ("解像度が変わった", none(), &[], Some(shows_lower.clone())),
        (
            "手であてた blank",
            set_group(2, template("blank")),
            &[],
            Some(shows_lower.clone()),
        ),
        (
            "手であてたカスタム",
            set_group(0, custom(UUID_MINE, 1)),
            &["--dry-run", "--force"],
            Some(shows_lower.clone()),
        ),
        (
            "--force で上書き",
            none(),
            &["--force"],
            Some(shows_lower.clone()),
        ),
        (
            "番号の振り直し",
            none(),
            &[],
            Some(shows_renumbered.clone()),
        ),
        (
            "PC で直した・足した",
            edit_layout(true, false, true),
            &[],
            Some(shows_two.clone()),
        ),
        (
            "PC で消した",
            edit_layout(false, true, false),
            &[],
            Some(shows_two.clone()),
        ),
        (
            "--force で足し直す",
            none(),
            &["--force"],
            Some(shows_two.clone()),
        ),
        (
            "横向きの既定を変えた・縦向きがある",
            Box::new(|e: &Env| {
                e.put(
                    &e.fz("default-layouts.json"),
                    "{\r\n  \"default-layouts\": [\r\n    {\r\n      \"monitor-configuration\": \"vertical\",\r\n      \"layout\": {\r\n        \"uuid\": \"{00000000-0000-0000-0000-000000000000}\",\r\n        \"type\": \"rows\",\r\n        \"show-spacing\": true,\r\n        \"spacing\": 16,\r\n        \"zone-count\": 3,\r\n        \"sensitivity-radius\": 20\r\n      }\r\n    },\r\n    {\r\n      \"monitor-configuration\": \"horizontal\",\r\n      \"layout\": {\r\n        \"uuid\": \"{00000000-0000-0000-0000-000000000000}\",\r\n        \"type\": \"priority-grid\",\r\n        \"show-spacing\": true,\r\n        \"spacing\": 16,\r\n        \"zone-count\": 3,\r\n        \"sensitivity-radius\": 20\r\n      }\r\n    }\r\n  ]\r\n}",
                )
            }),
            &[],
            Some(shows_two.clone()),
        ),
        (
            "repo のレイアウトを更新した",
            Box::new(|e: &Env| {
                let p = e.repo_file(LAYOUTS_REL);
                let mut repo = e.doc(&p);
                let mut list = repo
                    .get("custom-layouts")
                    .unwrap()
                    .as_array()
                    .unwrap()
                    .clone();
                let mut info = list[1].get("info").unwrap().clone();
                info.set("sensitivity-radius", Jv::from(30));
                list[1].set("info", info);
                repo.set("custom-layouts", Jv::Array(list));
                e.put(&p, &pt_form(&repo));
            }),
            &[],
            Some(shows_two.clone()),
        ),
        (
            "FancyZones がオフ",
            Box::new(|e: &Env| e.put(&e.global(), r#"{"enabled":{"FancyZones":false}}"#)),
            &[],
            Some(shows_two.clone()),
        ),
        ("PowerShell が無い", none(), &[], None),
        (
            "記録が壊れている",
            Box::new(|e: &Env| {
                let p = if e.root().join("home").exists() {
                    e.root()
                        .join("home/.local/state/dotfiles")
                        .join(ASSIGNED_FILE)
                } else {
                    e.state().join(ASSIGNED_FILE)
                };
                e.put(&p, "[]");
            }),
            &[],
            Some(shows_two.clone()),
        ),
    ];
    for (name, change, args, shows) in &steps {
        change(&wsl);
        change(&ours);
        compare(name, &wsl, &ours, args, shows.as_deref());
    }
}

/// 番号の振り直しの直後で、そのデスクトップの古い組が手であてたもの (カスタム・PC にだけあるレイアウト) なら、作る組はそのレイアウトを写して記録
/// しない (--force なら決まりのレイアウトで作る)
#[cfg(unix)]
#[test]
fn renumbering_keeps_hand_assigned_groups() {
    if !parity::available() {
        return;
    }
    let (wsl, ours) = (Env::new(), Env::new());
    compare("はじめ", &wsl, &ours, &[], Some(&two_displays()));
    both(&wsl, &ours, add_mine);
    let other = "{12345678-1234-1234-1234-123456789ABC}";
    both(&wsl, &ours, |e: &Env| {
        e.put(
            &e.fz("applied-layouts.json"),
            &applied(vec![
                group(MON_A, INST_A, 1, "0", VD1, &custom(UUID_MINE, 1)),
                group(MON_A, INST_A, 1, "0", VD2, &template("grid")),
                group(MON_B, INST_B, 2, "0", VD1, &template("grid")),
                group(MON_B, INST_B, 2, "0", VD2, &custom(other, 2)),
            ]),
        )
    });
    let renumbered = displays_json(
        &[
            disp(MON_A, INST_A, 2, 3840, 2160),
            disp(MON_B, INST_B, 1, 1920, 1080),
        ],
        &[VD1, VD2],
    );
    compare(
        "振り直し (dry-run)",
        &wsl,
        &ours,
        &["--dry-run"],
        Some(&renumbered),
    );
    compare("振り直し", &wsl, &ours, &[], Some(&renumbered));
    compare("もう一度", &wsl, &ours, &[], Some(&renumbered));
    compare("--force", &wsl, &ours, &["--force"], Some(&renumbered));
}

/// 横向きの既定 (決まりの default) があたった 4K の組は目標にし、同じ画面の組がどこにも無い画面には作らず、instance が違えば番号で合わせる
#[cfg(unix)]
#[test]
fn default_layout_groups_nosrc_and_number_fallback() {
    if !parity::available() {
        return;
    }
    let (wsl, ours) = (Env::new(), Env::new());
    compare("はじめ", &wsl, &ours, &[], Some(&two_displays()));
    both(&wsl, &ours, |e: &Env| {
        e.put(
            &e.fz("applied-layouts.json"),
            &applied(vec![
                group(MON_A, INST_A, 1, "0", VD1, &custom(UUID_1080, 3)),
                group(MON_B, "4&99999999&0&UID999", 2, "0", VD1, &template("grid")),
            ]),
        )
    });
    let shows = displays_json(
        &[
            disp(MON_A, INST_A, 1, 3840, 2160),
            disp(MON_B, INST_B, 2, 1920, 1080),
            disp(MON_C, INST_C, 3, 1920, 1080),
        ],
        &[VD1, VD2],
    );
    compare(
        "既定・組の無い画面・番号で合わせる",
        &wsl,
        &ours,
        &[],
        Some(&shows),
    );
    compare("もう一度", &wsl, &ours, &[], Some(&shows));
}

/// 何も無い PC (組はある) の dry-run は、カスタムレイアウトの段が足すものを PC にあるものとして見る。apply は足してからあてる
#[cfg(unix)]
#[test]
fn fresh_pc_with_groups() {
    if !parity::available() {
        return;
    }
    let (wsl, ours) = (Env::new(), Env::new());
    both(&wsl, &ours, |e: &Env| {
        e.put(
            &e.fz("applied-layouts.json"),
            &applied(vec![
                group(MON_A, INST_A, 1, "0", VD1, &template("priority-grid")),
                group(MON_B, INST_B, 2, "0", VD1, &template("priority-grid")),
            ]),
        );
        e.put(&e.fz("default-layouts.json"), "{\"default-layouts\":[]}");
    });
    compare(
        "dry-run",
        &wsl,
        &ours,
        &["--dry-run"],
        Some(&two_displays()),
    );
    compare("apply", &wsl, &ours, &[], Some(&two_displays()));
}

/// 決まりの default のレイアウト (1080p) を PC で消した: 横向きの既定とあて方は飛ばして知らせ、--force で足し直してからあてる
#[cfg(unix)]
#[test]
fn deleted_default_layout() {
    if !parity::available() {
        return;
    }
    let (wsl, ours) = (Env::new(), Env::new());
    compare("はじめ", &wsl, &ours, &[], Some(&two_displays()));
    both(&wsl, &ours, |e: &Env| {
        e.put(
            &e.fz("applied-layouts.json"),
            &applied(vec![
                group(MON_A, INST_A, 1, "0", VD1, &template("grid")),
                group(MON_B, INST_B, 2, "0", VD1, &template("grid")),
                group(MON_B, INST_B, 2, "9", VD1, &template("rows")),
            ]),
        );
        let mut pc = e.doc(&e.fz("custom-layouts.json"));
        let mut list = pc
            .get("custom-layouts")
            .unwrap()
            .as_array()
            .unwrap()
            .clone();
        list.remove(1);
        pc.set("custom-layouts", Jv::Array(list));
        e.put(&e.fz("custom-layouts.json"), &pt_form(&pc));
    });
    compare("1080p を消した", &wsl, &ours, &[], Some(&two_displays()));
    compare(
        "dry-run --force",
        &wsl,
        &ours,
        &["--dry-run", "--force"],
        Some(&two_displays()),
    );
    compare("--force", &wsl, &ours, &["--force"], Some(&two_displays()));
}

/// 変わった値 (小数の番号・null や空の値・重なった仮想デスクトップ・末尾の改行・形の合わない id)
#[cfg(unix)]
#[test]
fn odd_values() {
    if !parity::available() {
        return;
    }
    let (wsl, ours) = (Env::new(), Env::new());
    compare("はじめ", &wsl, &ours, &[], Some(&two_displays()));
    let raw = r#"{"applied-layouts":[
 {"device":{"monitor":"AAA0001","monitor-instance":"4&11111111&0&UID101","monitor-number":1.0,"virtual-desktop":"{11111111-1111-1111-1111-111111111111}"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000000}","type":"grid","show-spacing":true,"spacing":16,"zone-count":3,"sensitivity-radius":20}},
 {"device":{"monitor":"BBB0002","monitor-instance":"","monitor-number":2,"serial-number":null,"virtual-desktop":"{22222222-2222-2222-2222-222222222222}"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000000}","type":"grid","show-spacing":true,"spacing":16,"zone-count":3,"sensitivity-radius":20}},
 {"device":{"monitor":"BBB0002","monitor-instance":"","monitor-number":2,"serial-number":"x","virtual-desktop":"{11111111-1111-1111-1111-111111111111}"},"applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000000}","type":"focus","show-spacing":true,"spacing":16,"zone-count":3,"sensitivity-radius":20}}
]}"#;
    both(&wsl, &ours, |e: &Env| {
        e.put(
            &e.fz("applied-layouts.json"),
            &pt_form(&Jv::parse(raw).unwrap()),
        )
    });
    let shows = r#"{"displays":[{"device":"\\\\.\\DISPLAY1","id":"\\\\?\\DISPLAY#AAA0001#4&11111111&0&UID101#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}","width":3840,"height":2160},{"device":"\\\\.\\DISPLAY2\n","id":"\\\\?\\DISPLAY#BBB0002##{e6f07b5f}","width":1920,"height":1080},{"device":"\\\\.\\DISPLAY3","id":"\\\\?\\DISPLAY#CCC#x","width":1920,"height":1080}],"desktops":["{11111111-1111-1111-1111-111111111111}","{22222222-2222-2222-2222-222222222222}","{22222222-2222-2222-2222-222222222222}","{00000000-0000-0000-0000-000000000000}","{33333333-3333-3333-3333-333333333333}\n","not-a-guid"]}"#;
    compare("変わった値", &wsl, &ours, &[], Some(shows));
    compare("もう一度", &wsl, &ours, &[], Some(shows));
}

/// 設定の端 (途中が object でない・値が null・逃がした字と数・properties が無い・最上位が配列)
#[cfg(unix)]
#[test]
fn settings_edges() {
    if !parity::available() {
        return;
    }
    let cases: Vec<(&str, &str, &[&str])> = vec![
        (
            "途中が object でない (dry-run)",
            r#"{"properties":5,"name":"FancyZones","version":"1.0"}"#,
            &["--dry-run"],
        ),
        (
            "途中が object でない",
            r#"{"properties":5,"name":"FancyZones","version":"1.0"}"#,
            &[],
        ),
        (
            "値が null",
            r#"{"properties":{"fancyzones_overrideSnapHotkeys":{"value":null}},"name":"FancyZones"}"#,
            &[],
        ),
        (
            "逃がした字と数",
            "{\"properties\":{\"a\":{\"value\":\"\\u0026<>\\u00e9\\u007f\\/\"},\"b\":{\"value\":1.50},\"c\":{\"value\":1e2},\"fancyzones_overrideSnapHotkeys\":{\"value\":false}},\"name\":\"FancyZones\",\"version\":\"1.0\"}",
            &[],
        ),
        ("properties が無い", r#"{"name":"FancyZones"}"#, &[]),
        ("最上位が配列", r#"[1]"#, &[]),
    ];
    for (name, body, args) in cases {
        let (wsl, ours) = (Env::new(), Env::new());
        both(&wsl, &ours, |e: &Env| e.put(&e.fz("settings.json"), body));
        compare(name, &wsl, &ours, args, None);
    }
}

/// 取り込みも WSL の --import と同じバイト列の custom-layouts.json を書く (git の checkout にした repo で、本物の git)
#[cfg(unix)]
#[test]
fn imports_the_same_bytes_as_the_wsl_script() {
    if !parity::available() {
        return;
    }
    let git = |dir: &Path, args: &[&str]| {
        let o = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    };
    let envs = [Env::new(), Env::new()];
    for e in &envs {
        e.run(APPLY, None);
        let mut pc = e.doc(&e.fz("custom-layouts.json"));
        let mut list = pc
            .get("custom-layouts")
            .unwrap()
            .as_array()
            .unwrap()
            .clone();
        list[1].set("name", Jv::from("1080p"));
        let mut info = list[1].get("info").unwrap().clone();
        info.set("sensitivity-radius", Jv::from(40));
        list[1].set("info", info);
        list.push(my_layout());
        pc.set("custom-layouts", Jv::Array(list));
        e.put(&e.fz("custom-layouts.json"), &pt_form(&pc));
        git(&e.root().join("repo"), &["init", "-q"]);
        git(&e.root().join("repo"), &["add", "win"]);
        git(
            &e.root().join("repo"),
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@example.invalid",
                "commit",
                "-q",
                "-m",
                "m",
            ],
        );
    }
    let (wsl, ours) = (&envs[0], &envs[1]);
    let (code, out) = wsl_run(wsl, &["--import", "1080p", "--import=mine"], None);
    assert_eq!(code, 0, "{out}");
    let mut buf = Vec::new();
    let o = {
        let mut ctx = Ctx {
            repo: ours.root().join("repo"),
            roots: Roots::from_home(&ours.root().join("win")),
            state_dir: ours.state(),
            host: parse(
                RUNNER_HOST,
                Path::new("h.toml"),
                Groups::embedded().unwrap(),
            )
            .unwrap(),
            sys: &crate::testutil::RealSysPlain,
            out: &mut buf,
        };
        import(&mut ctx, &["1080p".to_string(), "mine".to_string()])
    };
    let out = String::from_utf8(buf).unwrap();
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert!(
        out.contains("  1080p: repo の同じ uuid のレイアウトを置き換えた")
            && out.contains("  mine: 足した"),
        "{out}"
    );
    assert_eq!(
        ours.read(&ours.repo_file(LAYOUTS_REL)),
        wsl.read(&wsl.repo_file(LAYOUTS_REL))
    );
}

/// 取り込みの誤りも WSL の --import と同じ (PC に同じ名前が 2 つ・小文字の uuid・repo の別のレイアウトと同じ名前・無い名前・repo と同じ・' を含む名前)。
/// 誤りがあれば何も書かず、同じ文を出す
#[cfg(unix)]
#[test]
fn import_errors_match_the_wsl_script() {
    if !parity::available() {
        return;
    }
    let git = |dir: &Path, args: &[&str]| {
        let o = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    };
    type Edit = Box<dyn Fn(&mut Vec<Jv>)>;
    let cases: Vec<(&str, Edit, &[&str])> = vec![
        (
            "PC に同じ名前が 2 つ",
            Box::new(|l: &mut Vec<Jv>| {
                let mut a = my_layout();
                a.set("uuid", Jv::from("{AAAAAAAA-0000-0000-0000-000000000001}"));
                l.push(my_layout());
                l.push(a);
            }),
            &["mine"],
        ),
        (
            "小文字の uuid",
            Box::new(|l: &mut Vec<Jv>| {
                let mut a = my_layout();
                a.set("uuid", Jv::from("{aaaaaaaa-0000-0000-0000-000000000001}"));
                l.push(a);
            }),
            &["mine"],
        ),
        (
            "repo の別のレイアウトと同じ名前",
            Box::new(|l: &mut Vec<Jv>| {
                l[1].set("name", Jv::from("4k-43inch"));
                l[0].set("name", Jv::from("old4k"));
            }),
            &["4k-43inch"],
        ),
        (
            "repo と同じと、無い名前",
            Box::new(|_: &mut Vec<Jv>| {}),
            &["1080p", "nothing"],
        ),
        ("repo と同じ", Box::new(|_: &mut Vec<Jv>| {}), &["1080p"]),
        (
            "' を含む名前",
            Box::new(|l: &mut Vec<Jv>| {
                let mut a = my_layout();
                a.set("name", Jv::from("it's"));
                l.push(a);
            }),
            &["it's"],
        ),
    ];
    for (name, edit, names) in &cases {
        let envs = [Env::new(), Env::new()];
        for e in &envs {
            e.run(APPLY, None);
            let mut pc = e.doc(&e.fz("custom-layouts.json"));
            let mut list = pc
                .get("custom-layouts")
                .unwrap()
                .as_array()
                .unwrap()
                .clone();
            edit(&mut list);
            pc.set("custom-layouts", Jv::Array(list));
            e.put(&e.fz("custom-layouts.json"), &pt_form(&pc));
            git(&e.root().join("repo"), &["init", "-q"]);
            git(&e.root().join("repo"), &["add", "win"]);
            git(
                &e.root().join("repo"),
                &[
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@example.invalid",
                    "commit",
                    "-q",
                    "-m",
                    "m",
                ],
            );
        }
        let (wsl, ours) = (&envs[0], &envs[1]);
        let args: Vec<String> = names
            .iter()
            .flat_map(|n| ["--import".to_string(), n.to_string()])
            .collect();
        let argv: Vec<&str> = args.iter().map(String::as_str).collect();
        let (code, wsl_out) = wsl_run(wsl, &argv, None);
        let mut buf = Vec::new();
        let o = {
            let mut ctx = Ctx {
                repo: ours.root().join("repo"),
                roots: Roots::from_home(&ours.root().join("win")),
                state_dir: ours.state(),
                host: parse(
                    RUNNER_HOST,
                    Path::new("h.toml"),
                    Groups::embedded().unwrap(),
                )
                .unwrap(),
                sys: &crate::testutil::RealSysPlain,
                out: &mut buf,
            };
            import(
                &mut ctx,
                &names.iter().map(|n| n.to_string()).collect::<Vec<_>>(),
            )
        };
        let out = String::from_utf8(buf).unwrap();
        let ctx = format!("{name}:\n--- WSL\n{wsl_out}\n--- runner\n{out}");
        assert_eq!(code == 0, o.kind == Kind::Ok, "{ctx}");
        assert_eq!(
            ours.read(&ours.repo_file(LAYOUTS_REL)),
            wsl.read(&wsl.repo_file(LAYOUTS_REL)),
            "{ctx}"
        );
        assert_eq!(
            warn_lines(&out, ours.root()),
            warn_lines(&wsl_out, wsl.root()),
            "{ctx}"
        );
    }
}

/// 受け持ちを切り替えた後の引き継ぎ: WSL の script が書いたものを、記録の無い runner が変えずに読み、記録は WSL の記録と同じになる
#[cfg(unix)]
#[test]
fn takes_over_what_the_wsl_script_wrote() {
    if !parity::available() {
        return;
    }
    let e = Env::new();
    let shows = two_displays();
    wsl_run(&e, &[], Some(&shows));
    e.put(
        &e.fz("applied-layouts.json"),
        &applied(vec![
            group(MON_A, INST_A, 1, "0", VD1, &template("grid")),
            group(MON_B, INST_B, 2, "0", VD1, &template("grid")),
        ]),
    );
    let (code, out) = wsl_run(&e, &[], Some(&shows));
    assert_eq!(code, 0, "{out}");
    let files: Vec<Option<String>> = [
        "settings.json",
        "custom-layouts.json",
        "default-layouts.json",
        "applied-layouts.json",
    ]
    .iter()
    .map(|f| e.read(&e.fz(f)))
    .collect();
    for _ in 0..2 {
        let (rows, out, _) = e.run(APPLY, Some(&shows));
        assert!(rows.iter().all(|r| r.kind == Kind::Ok), "{rows:?}\n{out}");
        let now: Vec<Option<String>> = [
            "settings.json",
            "custom-layouts.json",
            "default-layouts.json",
            "applied-layouts.json",
        ]
        .iter()
        .map(|f| e.read(&e.fz(f)))
        .collect();
        assert_eq!(now, files);
    }
    let wsl_state = e.root().join("home/.local/state/dotfiles");
    for rec in [RECORD_FILE, ASSIGNED_FILE] {
        assert_eq!(
            e.read(&e.state().join(rec)),
            e.read(&wsl_state.join(rec)),
            "{rec}"
        );
    }
    assert_eq!(e.backups(&e.state()), 0);
}
