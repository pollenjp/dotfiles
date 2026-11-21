//! ## 確かめること (WSL の nix/tests/bootstrap-windows-google-ime.test.sh と nix/pkgs/pjp-google-ime/test_google_ime.py のケースを、runner だけの
//! 試験と、WSL の版との突き合わせに分けたもの)
//!
//! runner だけの試験 (偽の Sys。Windows の CI でも流れる):
//! - config.txtpb が無い・Google 日本語入力が入っていないなら飛ばす。入っているがまだ使っていない (置き先が無い) なら知らせる (Program Files の
//!   64 ビットと x86 のどちらも。exe が無ければ入っていない扱い)
//! - tasklist が無い・失敗するなら置かない。設定画面が開いていれば置かない。壊れたテキストは行を出して何も置かない
//! - 初めては 2 つとも置いて記録し、taskkill /F /IM で変換サーバーを 1 回落とす。2 回目は同じで落とさない。時刻だけ違う・空の語だけ違うのは同じ扱い
//! - repo 側が進んだら退避して上書きし落とす。画面で変えていたら衝突として diff (- が Windows 側) と解き方を出し、触らない。--force は置き直す。
//!   読めない Windows 側のファイルは衝突
//! - 辞書のテキストが無ければ辞書は飛ばす (Windows 側の辞書は残す)。退避は新しい方から 10 回分
//! - 変換サーバーが動いていない (128) のは成功。落とせなければ印を残し、次の apply が落とし直して消す。印のある回の dry-run・tasklist が使えない回・
//!   取り込みは印に触らず落とさない。印のある回の衝突には古い設定の書き戻しかもしれないと添える
//! - check と dry-run は何も書かず、tasklist も taskkill も打たない。check の行の種類 (置く → missing・上書き → fix・衝突 → manual)
//! - 辞書の衝突は語を出さず辞書ごとの行の数だけ (--show-words なら diff)。TSV に出ない項目だけの違いはそう出す
//! - 取り込み: Windows 側をテキストへ写して記録し、次は同じ。commit していない変更があれば何も書かずに止まる。テキストが変わった repo でだけ commit を
//!   促す。単語登録の形 (コメントの無い語) の辞書も取り込める
//! - 受け持ちが WSL のホストでは、記録が無いことと衝突の解き方を WSL の側で出す
//!
//! WSL の版との突き合わせ (Linux。pjp-google-ime は nix で repo の flake から作る。`DOTFILES_WIN_NIX_PARITY=1` なら作れないと落ちる):
//! - 組み立てたバイト列・digest・テキストへ戻したもの・取り込んだテキストが pjp-google-ime と 1 バイトも違わない (作り物のテキストと、作ったバイナリ。
//!   repo の config.txtpb・keymap.tsv も)
//! - WSL の script (偽の tasklist.exe・taskkill.exe は WSL の試験から毎回抜き出す) と runner を同じ状態から一続きの場面で流し、Windows 側の
//!   2 つのファイル・記録・印・退避・tasklist と taskkill に渡したもの・取り込んだテキストが同じ。WSL が置いたものを、記録の無い runner が置き直さずに
//!   引き継ぐ

use super::*;
use crate::host::{Groups, parse};
use crate::manifest::Roots;
use crate::process::{RunResult, Sys};
use crate::testutil::TempDir;
use std::cell::RefCell;
use std::rc::Rc;

const RUNNER_HOST: &str = "[runner]\nenable = true\n";
const WSL_HOST: &str = "group = \"personal\"\n";
const APPLY: Mode = Mode::Apply { force: false };
const FORCE: Mode = Mode::Apply { force: true };
const DRY: Mode = Mode::DryRun { force: false };
const CHECK: Mode = Mode::Check;

// テキスト (WSL の試験と同じ作り物)
const TXTPB: &str = "session_keymap: CUSTOM\npunctuation_method: TOUTEN_KUTEN\n";
const KEYMAP: &str = "status\tkey\tcommand\nDirectInput\tF13\tIMEOn\nPrecomposition\tF13\tIMEOff\n";
const KEYMAP2: &str = "status\tkey\tcommand\nDirectInput\tF13\tIMEOn\nPrecomposition\tF13\tIMEOff\nComposition\tF13\tIMEOff\n";
/// 画面でキー設定を変えた形 (Precomposition の行を消した)
const KEYMAP_GUI: &str = "status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n";
const DICT: &str = "てすと\tテスト\t名詞\t\n";

/// 偽の外のコマンドの振る舞いと、打たれたものの控え。
#[derive(Default)]
struct Fake {
    /// tasklist と taskkill が無い (WSL の interop が無いのに当たる)
    no_interop: bool,
    tool_running: bool,
    tasklist_rc: i32,
    taskkill_rc: i32,
    /// 打たれた tasklist・taskkill (名前と引数)
    calls: Vec<String>,
    /// git が答える `status --porcelain`・`--short` の行 (-C のディレクトリごと)。無いディレクトリは変更なし
    dirty: Vec<(PathBuf, Vec<String>, Vec<String>)>,
    /// git が「checkout ではない」で落ちる
    git_fails: bool,
    /// git の status を打った回数 (`dirty` は `dirty_from` 回目からだけ返す。取り込みの後でだけ変更があるように見せる)
    status_calls: usize,
    dirty_from: usize,
    /// git が stderr に出す warning の行 (stdout だけを読むなら、写しに入らない)
    git_warnings: Vec<String>,
    /// taskkill が出す行
    taskkill_out: Vec<String>,
    env: Vec<(String, String)>,
}

/// 偽の Sys (tasklist・taskkill・git を真似る)。
struct TestSys(Rc<RefCell<Fake>>);

impl Sys for TestSys {
    fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult {
        let mut f = self.0.borrow_mut();
        let name = spec.program.to_string_lossy().into_owned();
        let args = spec.args_lossy();
        let (code, out): (i32, Vec<String>) = match name.as_str() {
            "tasklist" => {
                f.calls.push(format!("tasklist {}", args.join(" ")));
                let line = if f.tool_running {
                    "\"GoogleIMEJaTool.exe\",\"4242\",\"Console\",\"3\",\"25,000 K\""
                } else {
                    "情報: 指定された条件に一致するタスクは実行されていません。"
                };
                (f.tasklist_rc, vec![line.to_string()])
            }
            "taskkill" => {
                f.calls.push(format!("taskkill {}", args.join(" ")));
                (f.taskkill_rc, f.taskkill_out.clone())
            }
            "git" => {
                if f.git_fails {
                    (128, vec!["fatal: not a git repository".to_string()])
                } else {
                    let dir = args
                        .iter()
                        .position(|a| a == "-C")
                        .map(|i| PathBuf::from(&args[i + 1]))
                        .unwrap_or_default();
                    let short = args.iter().any(|a| a == "--short");
                    if args.iter().any(|a| a == "--porcelain") {
                        f.status_calls += 1;
                    }
                    let lines = f
                        .dirty
                        .iter()
                        .find(|(d, _, _)| *d == dir && f.status_calls >= f.dirty_from)
                        .map(|(_, p, s)| if short { s.clone() } else { p.clone() })
                        .unwrap_or_default();
                    // diff --no-index は差の行を返す (中身は試験で見ない)
                    if args.iter().any(|a| a == "diff") {
                        (1, vec!["--- Windows 側/x".to_string()])
                    } else {
                        // stderr の warning は流す口には渡し、stdout だけを読むなら写しに入れない (本物の口と同じ)
                        for w in &f.git_warnings {
                            on_line(w);
                        }
                        let mut out = lines;
                        if !spec.stdout_only {
                            out.extend(f.git_warnings.iter().cloned());
                        }
                        (0, out)
                    }
                }
            }
            other => panic!("打たないはずのコマンド: {other}"),
        };
        for l in &out {
            on_line(l);
        }
        RunResult {
            exit: Exit::Code(code),
            output: out,
        }
    }

    fn which(&self, name: &str) -> Option<PathBuf> {
        let f = self.0.borrow();
        match name {
            "tasklist" | "taskkill" if !f.no_interop => Some(PathBuf::from(name)),
            "git" => Some(PathBuf::from("git")),
            _ => None,
        }
    }

    fn env(&self, name: &str) -> Option<String> {
        self.0
            .borrow()
            .env
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.clone())
    }
}

/// 偽の PC (repo・dotfiles-private・Windows のホーム・記録の置き場を 1 つの一時ディレクトリに作る)。
struct Pc {
    t: TempDir,
    fake: Rc<RefCell<Fake>>,
    host: &'static str,
}

impl Pc {
    /// `installed` なら置き先 (Google 日本語入力を一度使った) を作る
    fn new(installed: bool) -> Pc {
        let t = TempDir::new("google-ime");
        let pc = Pc {
            t,
            fake: Rc::new(RefCell::new(Fake::default())),
            host: RUNNER_HOST,
        };
        pc.write_config(TXTPB, KEYMAP);
        pc.write_dict("テスト辞書", DICT);
        std::fs::create_dir_all(pc.root().join("win")).unwrap();
        if installed {
            std::fs::create_dir_all(pc.ime()).unwrap();
        }
        pc
    }

    fn root(&self) -> &Path {
        self.t.path()
    }

    fn config_dir(&self) -> PathBuf {
        join_segments(&self.root().join("repo"), CONFIG_REL)
    }

    fn dict_dir(&self) -> PathBuf {
        join_segments(&self.root().join("dotfiles-private"), DICT_REL)
    }

    fn ime(&self) -> PathBuf {
        join_segments(&self.root().join("win"), IME_REL)
    }

    fn state(&self) -> PathBuf {
        self.root().join("state").join(STATE_REL)
    }

    fn record(&self) -> PathBuf {
        self.state().join(RECORD_FILE)
    }

    fn pending(&self) -> bool {
        self.state().join(PENDING_FILE).exists()
    }

    fn write_config(&self, txtpb: &str, keymap: &str) {
        std::fs::create_dir_all(self.config_dir()).unwrap();
        std::fs::write(self.config_dir().join("config.txtpb"), txtpb).unwrap();
        std::fs::write(self.config_dir().join("keymap.tsv"), keymap).unwrap();
    }

    fn write_dict(&self, name: &str, text: &str) {
        std::fs::create_dir_all(self.dict_dir()).unwrap();
        std::fs::write(self.dict_dir().join(format!("{name}.tsv")), text).unwrap();
    }

    fn win_file(&self, name: &str) -> Option<Vec<u8>> {
        std::fs::read(self.ime().join(name)).ok()
    }

    /// Windows 側の設定を、`keymap` のキー設定で画面で作ったものにする
    fn put_windows_config(&self, keymap: &str) {
        let c = ime::config_from_text(TXTPB, Some(keymap), None).unwrap();
        std::fs::write(self.ime().join(ime::CONFIG_DB), c.encode()).unwrap();
    }

    /// Windows 側の辞書を、{名前: TSV} から組み立てたものにする
    fn put_windows_dictionaries(&self, pairs: &[(&str, &str)]) {
        let files = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let s = ime::dictionaries_from_tsv(&files).unwrap();
        std::fs::write(self.ime().join(ime::DICTIONARY_DB), s.encode()).unwrap();
    }

    fn kills(&self) -> usize {
        self.fake
            .borrow()
            .calls
            .iter()
            .filter(|c| c.starts_with("taskkill"))
            .count()
    }

    fn tasklists(&self) -> usize {
        self.fake
            .borrow()
            .calls
            .iter()
            .filter(|c| c.starts_with("tasklist"))
            .count()
    }

    fn backups(&self) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(self.state().join("backup"))
            .map(|r| {
                r.filter_map(|e| e.ok())
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        v.sort();
        v
    }

    fn ctx_run<T>(&self, f: impl FnOnce(&mut Ctx) -> T) -> (T, String) {
        let sys = TestSys(self.fake.clone());
        let mut out = Vec::new();
        let r = {
            let mut ctx = Ctx {
                repo: self.root().join("repo"),
                roots: Roots::from_home(&self.root().join("win")),
                state_dir: self.root().join("state"),
                host: parse(self.host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                sys: &sys,
                out: &mut out,
            };
            f(&mut ctx)
        };
        (r, String::from_utf8(out).unwrap())
    }

    fn run(&self, mode: Mode) -> (Outcome, String) {
        self.run_words(mode, false)
    }

    fn run_words(&self, mode: Mode, show_words: bool) -> (Outcome, String) {
        self.ctx_run(|ctx| GoogleIme { show_words }.run(ctx, mode).remove(0))
    }

    fn import(&self) -> (Outcome, String) {
        self.ctx_run(import)
    }
}

#[test]
fn skips_when_the_checkout_has_no_config_or_ime_is_not_installed() {
    let pc = Pc::new(true);
    std::fs::remove_file(pc.config_dir().join("config.txtpb")).unwrap();
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Info, "{out}");
    assert!(out.contains("飛ばします"));
    assert_eq!(pc.tasklists(), 0);

    // 入っていない (置き先も exe も無い。Program Files にディレクトリだけ残っていても入っていない扱い)
    let pc = Pc::new(false);
    let pf = pc.root().join("pf");
    std::fs::create_dir_all(pf.join("Google").join("Google Japanese Input")).unwrap();
    pc.fake
        .borrow_mut()
        .env
        .push(("ProgramFiles".into(), pf.to_string_lossy().into_owned()));
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Info, "{out}");
    assert!(out.contains("入っていません") && !out.contains("まだ使われていません"));
    assert_eq!(pc.tasklists(), 0);
    assert!(!pc.ime().exists());
}

#[test]
fn installed_but_unused_asks_to_type_once() {
    for var in ["ProgramFiles", "ProgramFiles(x86)", "ProgramW6432"] {
        let pc = Pc::new(false);
        let pf = pc.root().join("pf");
        let dir = pf.join("Google").join("Google Japanese Input");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(CONVERTER), "exe").unwrap();
        pc.fake
            .borrow_mut()
            .env
            .push((var.into(), pf.to_string_lossy().into_owned()));
        let (o, out) = pc.run(APPLY);
        assert_eq!(o.kind, Kind::Manual, "{var}: {out}");
        assert!(out.contains("まだ使われていません") && out.contains("一度何か打ってから"));
        assert!(!pc.ime().exists(), "置き先は作らない");
        assert_eq!(pc.tasklists(), 0);
    }
}

#[test]
fn tasklist_missing_or_failing_places_nothing() {
    let pc = Pc::new(true);
    pc.fake.borrow_mut().no_interop = true;
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Failed, "{out}");
    assert!(out.contains("置きません") && pc.win_file(ime::CONFIG_DB).is_none());
    let pc = Pc::new(true);
    pc.fake.borrow_mut().tasklist_rc = 126;
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Failed, "{out}");
    assert!(out.contains("置きません") && pc.win_file(ime::CONFIG_DB).is_none());
    assert!(!pc.record().exists());
}

#[test]
fn open_settings_dialog_stops_before_placing() {
    let pc = Pc::new(true);
    pc.fake.borrow_mut().tool_running = true;
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Manual, "{out}");
    assert!(out.contains("GoogleIMEJaTool.exe") && out.contains("閉じてから"));
    assert!(pc.win_file(ime::CONFIG_DB).is_none());
    assert_eq!(pc.kills(), 0);
    assert_eq!(
        pc.fake.borrow().calls[0],
        "tasklist /FI IMAGENAME eq GoogleIMEJaTool.exe /FO CSV /NH"
    );
}

#[test]
fn broken_text_places_nothing_and_names_the_line() {
    let pc = Pc::new(true);
    pc.write_config(TXTPB, &format!("{KEYMAP}Composition\tF13\n"));
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Failed, "{out}");
    assert!(out.contains("keymap.tsv:4:") && out.contains("何も置いていません"));
    assert!(pc.win_file(ime::CONFIG_DB).is_none());
    assert_eq!(pc.kills(), 0);
}

#[test]
fn first_apply_places_both_records_and_kills_once_then_stays_same() {
    let pc = Pc::new(true);
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    let config = pc.win_file(ime::CONFIG_DB).unwrap();
    let dict = pc.win_file(ime::DICTIONARY_DB).unwrap();
    assert_eq!(pc.kills(), 1);
    assert_eq!(
        pc.fake.borrow().calls.last().unwrap(),
        "taskkill /F /IM GoogleIMEJaConverter.exe"
    );
    let record = std::fs::read_to_string(pc.record()).unwrap();
    let want = format!(
        "{{\n  \"config1.db\": \"{}\",\n  \"user_dictionary.db\": \"{}\"\n}}\n",
        ime::digest(Db::Config, &config, "c").unwrap(),
        ime::digest(Db::Dictionary, &dict, "d").unwrap()
    );
    assert_eq!(record, want);
    assert!(!pc.pending());
    assert!(out.contains("置く: ") && out.contains("落としました"));

    // 2 回目: 同じなので何もしない (落とさない)
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert_eq!(out.matches("同じです: ").count(), 2);
    assert_eq!(pc.kills(), 1);

    // 画面で OK を押しただけ (general_config だけが入った): 同じ扱いで、Windows 側のファイルに触らない
    let mut c = config.clone();
    c.extend([0x0a, 0x02, 0x18, 0x01]);
    std::fs::write(pc.ime().join(ime::CONFIG_DB), &c).unwrap();
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert_eq!(pc.win_file(ime::CONFIG_DB).unwrap(), c);
    assert_eq!(pc.kills(), 1);
}

#[test]
fn repo_update_backs_up_and_overwrites_and_gui_change_conflicts() {
    let pc = Pc::new(true);
    pc.run(APPLY);
    // repo 側が進んだ: 退避して上書きし、落とす
    pc.write_config(TXTPB, KEYMAP2);
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert!(out.contains("上書き (repo 側が進んだ): "));
    assert_eq!(pc.kills(), 2);
    let backups = pc.backups();
    assert_eq!(backups.len(), 1);
    assert!(
        pc.state()
            .join("backup")
            .join(&backups[0])
            .join(ime::CONFIG_DB)
            .is_file()
    );
    assert!(out.contains("退避しました"));
    // 画面で変えた (記録とも組み立てたものとも違う): 衝突。diff と解き方を出し、触らない
    pc.put_windows_config(KEYMAP_GUI);
    let before = pc.win_file(ime::CONFIG_DB).unwrap();
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Manual, "{out}");
    assert_eq!(pc.win_file(ime::CONFIG_DB).unwrap(), before);
    assert_eq!(pc.kills(), 2);
    assert!(out.contains("!! 衝突: ") && out.contains("dotfiles import google-ime"));
    // 設定だけの衝突には、辞書の語の diff の出し方を添えない
    assert!(
        !o.notes.iter().any(|n| n.contains("--show-words")),
        "{:?}",
        o.notes
    );
    assert!(out.contains("dotfiles apply --steps google-ime --force"));
    assert!(
        pc.fake
            .borrow()
            .calls
            .iter()
            .all(|c| !c.contains("diff") || c.contains("Windows 側")),
        "diff は Windows 側と repo を比べる"
    );
    // dry-run: 判定だけ (書かない・落とさない・tasklist も打たない)
    let calls = pc.fake.borrow().calls.len();
    let (o, out) = pc.run(DRY);
    assert_eq!(o.kind, Kind::Manual, "{out}");
    assert_eq!(pc.fake.borrow().calls.len(), calls);
    assert_eq!(pc.win_file(ime::CONFIG_DB).unwrap(), before);
    // --force: 衝突でも置き直す
    let (o, out) = pc.run(FORCE);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert!(out.contains("上書き (--force): "));
    let t = ime::config_to_text(
        &pb::decode(&pb::CONFIG, &pc.win_file(ime::CONFIG_DB).unwrap()).unwrap(),
    )
    .unwrap();
    assert_eq!(t.keymap.as_deref(), Some(KEYMAP2));
    assert_eq!(pc.backups().len(), 2);
}

#[test]
fn unreadable_windows_file_is_a_conflict_and_force_replaces_it() {
    let pc = Pc::new(true);
    std::fs::write(pc.ime().join(ime::CONFIG_DB), [0xff, 0xff, 0xff]).unwrap();
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Manual, "{out}");
    assert!(out.contains("衝突") && out.contains("読めないので diff は出せません"));
    let (o, out) = pc.run(FORCE);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert_ne!(pc.win_file(ime::CONFIG_DB).unwrap(), vec![0xff, 0xff, 0xff]);
}

#[test]
fn a_directory_in_place_of_the_file_fails_without_killing() {
    let pc = Pc::new(true);
    std::fs::create_dir_all(pc.ime().join(ime::CONFIG_DB)).unwrap();
    let (o, out) = pc.run(FORCE);
    assert_eq!(o.kind, Kind::Failed, "{out}");
    assert!(out.contains("置けませんでした"));
    assert!(pc.ime().join(ime::CONFIG_DB).is_dir() && pc.kills() == 0 && !pc.pending());
}

#[test]
fn missing_dictionary_texts_skip_the_dictionary_only() {
    let pc = Pc::new(true);
    std::fs::remove_dir_all(pc.root().join("dotfiles-private")).unwrap();
    std::fs::write(pc.ime().join(ime::DICTIONARY_DB), "windows-dictionary").unwrap();
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Manual, "{out}");
    assert!(out.contains("辞書は飛ばします") && o.text.contains("辞書は飛ばした"));
    assert!(pc.win_file(ime::CONFIG_DB).is_some());
    assert_eq!(
        pc.win_file(ime::DICTIONARY_DB).unwrap(),
        b"windows-dictionary"
    );
}

#[test]
fn keeps_the_newest_ten_backups() {
    let pc = Pc::new(true);
    pc.run(APPLY);
    for i in 1..=11 {
        std::fs::create_dir_all(
            pc.state()
                .join("backup")
                .join(format!("20000101T0000{i:02}Z-1")),
        )
        .unwrap();
    }
    pc.write_config(TXTPB, KEYMAP2);
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    let b = pc.backups();
    assert_eq!(b.len(), 10);
    assert_eq!(b[0], "20000101T000003Z-1");
}

#[test]
fn kill_results_and_restart_pending() {
    // 動いていない (128) のは成功
    let pc = Pc::new(true);
    pc.fake.borrow_mut().taskkill_rc = 128;
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert!(out.contains("動いていませんでした") && !pc.pending());

    // 落とせない: 印を残して failed。次の回は 2 つとも同じでも落とし直して印を消し、その次は落とさない
    let pc = Pc::new(true);
    pc.fake.borrow_mut().taskkill_rc = 1;
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Failed, "{out}");
    assert!(out.contains("タスクマネージャー") && out.contains("次の apply でも落とし直します"));
    assert!(pc.pending() && pc.kills() == 1);

    // 印がある回の check・dry-run・tasklist が使えない回・取り込みは、印を残して落とさない
    let (o, out) = pc.run(CHECK);
    assert_eq!(o.kind, Kind::Fix, "{out}");
    assert!(out.contains("前回は変換サーバーを落とせていません"));
    let (o, out) = pc.run(DRY);
    assert_eq!(o.kind, Kind::Fix, "{out}");
    assert!(out.contains("[dry-run] 変換サーバーを落とし直します (前回落とせなかった)"));
    pc.fake.borrow_mut().tasklist_rc = 126;
    let (o, _) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Failed);
    pc.fake.borrow_mut().tasklist_rc = 0;
    let (o, out) = pc.import();
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert!(pc.pending() && pc.kills() == 1);

    // 印がある回の衝突には、古い設定の書き戻しかもしれないと添える
    pc.put_windows_config(KEYMAP_GUI);
    let (o, out) = pc.run(DRY);
    assert_eq!(o.kind, Kind::Manual, "{out}");
    assert!(out.contains("古い設定が書き戻されたものかもしれません"));
    pc.write_config(TXTPB, KEYMAP_GUI);

    pc.fake.borrow_mut().taskkill_rc = 0;
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert!(out.contains("前回は変換サーバーを落とせなかったので、落とし直します。"));
    assert_eq!(out.matches("同じです: ").count(), 2);
    assert!(!pc.pending() && pc.kills() == 2);
    pc.run(APPLY);
    assert_eq!(pc.kills(), 2);
}

#[test]
fn check_and_dry_run_write_nothing() {
    let pc = Pc::new(true);
    let (o, out) = pc.run(CHECK);
    assert_eq!(o.kind, Kind::Missing, "{out}");
    assert!(out.contains("apply で置く: "));
    let (o, out) = pc.run(DRY);
    assert_eq!(o.kind, Kind::Missing, "{out}");
    assert!(out.contains("[dry-run] 置く: ") && o.text.starts_with("[dry-run] "));
    assert!(pc.fake.borrow().calls.is_empty());
    assert!(!pc.state().exists() && pc.win_file(ime::CONFIG_DB).is_none());
    pc.run(APPLY);
    pc.write_config(TXTPB, KEYMAP2);
    let (o, out) = pc.run(CHECK);
    assert_eq!(o.kind, Kind::Fix, "{out}");
    assert!(out.contains("apply で上書き (repo 側が進んだ): "));
    let (o, _) = pc.run(Mode::DryRun { force: true });
    assert_eq!(o.kind, Kind::Fix);
    assert_eq!(pc.kills(), 1);
}

#[test]
fn dictionary_conflicts_show_counts_but_no_words() {
    let pc = Pc::new(true);
    let secret = "ひみつのよみ\t秘密の単語\t名詞\t\n";
    let one = "いちのよみ\t一の単語\t名詞\t\n";
    let two = "にのよみ\t二の単語\t名詞\t\n";
    let out_only = "そとのよみ\t外の単語\t名詞\t\nそとのよみに\t外の単語に\t名詞\t\n";
    let in_only = "うちのよみ\t内の単語\t名詞\t\n";
    pc.write_dict("手元の辞書", in_only);
    pc.write_dict("並びの辞書", &format!("{one}{two}"));
    pc.put_windows_config(KEYMAP);
    pc.put_windows_dictionaries(&[
        ("テスト辞書", &format!("{DICT}{secret}")),
        ("並びの辞書", &format!("{two}{one}")),
        ("窓の辞書", out_only),
    ]);
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Manual, "{out}");
    let report = format!("{out}\n{}\n{}", o.text, o.notes.join("\n"));
    for w in [
        "てすと",
        "ひみつのよみ",
        "秘密の単語",
        "いちのよみ",
        "一の単語",
        "にのよみ",
        "二の単語",
        "そとのよみ",
        "外の単語",
        "うちのよみ",
        "内の単語",
    ] {
        assert!(
            !report.contains(w),
            "語が出た ({w} の位置: {:?})",
            report.find(w)
        );
    }
    for line in [
        "辞書「テスト辞書」: Windows 側にだけある行 1・repo 側にだけある行 0",
        "辞書「並びの辞書」: 行は同じで、並びだけが違う",
        "辞書「手元の辞書」: repo 側にだけある (1 語)",
        "辞書「窓の辞書」: Windows 側にだけある (2 語)",
        "dotfiles check --steps google-ime --show-words",
    ] {
        assert!(report.contains(line), "{line} が無い");
    }
    // --show-words なら diff を出す (偽の git なので、diff を打ったことだけを見る)
    let (o, out) = pc.run_words(DRY, true);
    assert_eq!(o.kind, Kind::Manual);
    assert!(!out.contains("辞書「") && out.contains("--- Windows 側/x"));
}

#[test]
fn tsv_invisible_differences_and_blank_entries() {
    // 辞書の TSV に出ない項目 (UserDictionaryStorage の version) だけが違う
    let pc = Pc::new(true);
    pc.put_windows_config(KEYMAP);
    let mut s =
        ime::dictionaries_from_tsv(&[("テスト辞書".to_string(), DICT.to_string())].into()).unwrap();
    s.set("version", pb::Value::I32(1));
    std::fs::write(pc.ime().join(ime::DICTIONARY_DB), s.encode()).unwrap();
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Manual, "{out}");
    assert!(!out.contains("辞書「") && out.contains("どの辞書も TSV に出る中身は同じです"));

    // 読みも単語も空の語だけが違う: 同じ扱いで触らず、落とさない
    let pc = Pc::new(true);
    pc.put_windows_config(KEYMAP);
    let mut s =
        ime::dictionaries_from_tsv(&[("テスト辞書".to_string(), DICT.to_string())].into()).unwrap();
    let mut d = match &s.values("dictionaries")[0] {
        pb::Value::Msg(d) => d.clone(),
        _ => unreachable!(),
    };
    d.set("id", pb::Value::U64(11_262_860_659_733_797_146));
    let mut blank = pb::Message::new(&pb::ENTRY);
    blank.set("pos", pb::Value::I32(1));
    d.push("entries", pb::Value::Msg(blank));
    s.clear("dictionaries");
    s.push("dictionaries", pb::Value::Msg(d));
    std::fs::write(pc.ime().join(ime::DICTIONARY_DB), s.encode()).unwrap();
    let before = pc.win_file(ime::DICTIONARY_DB).unwrap();
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert_eq!(out.matches("同じです: ").count(), 2);
    assert_eq!(pc.win_file(ime::DICTIONARY_DB).unwrap(), before);
    assert_eq!(pc.kills(), 0);
}

#[test]
fn import_writes_texts_and_records_and_prompts_only_for_changed_repos() {
    let pc = Pc::new(true);
    pc.run(APPLY);
    pc.put_windows_config(KEYMAP_GUI);
    // テキストが変わった repo を git が返す (取り込む前は変更なし)
    let (o, out) = pc.import();
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert_eq!(
        std::fs::read_to_string(pc.config_dir().join("keymap.tsv")).unwrap(),
        KEYMAP_GUI
    );
    assert!(
        out.contains("取り込んでもテキストは変わらなかった"),
        "偽の git は変更なしを返す: {out}"
    );
    // 記録は Windows 側の digest: 次の apply は同じ
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert_eq!(out.matches("同じです: ").count(), 2);

    // テキストが変わった repo でだけ commit を促す (取り込みの前の確かめ (2 回) は変更なし、取り込みの後に変更があると git が返す)
    for (want, conf, dict) in [
        (
            "取り込みました。git diff を見て、dotfiles で commit してください。",
            true,
            false,
        ),
        (
            "取り込みました。git diff を見て、dotfiles-private で commit してください (diff には辞書の語が出るので、自分の端末で見てください)。",
            false,
            true,
        ),
        (
            "取り込みました。git diff を見て、dotfiles と dotfiles-private の両方で commit してください (dotfiles-private の diff には辞書の語が出るので、自分の端末で見てください)。",
            true,
            true,
        ),
    ] {
        let pc = Pc::new(true);
        pc.run(APPLY);
        let mut dirty = Vec::new();
        if conf {
            dirty.push((
                pc.config_dir(),
                vec![" M keymap.tsv".to_string()],
                Vec::new(),
            ));
        }
        if dict {
            dirty.push((pc.dict_dir(), vec!["?? x.tsv".to_string()], Vec::new()));
        }
        {
            let mut f = pc.fake.borrow_mut();
            f.dirty = dirty;
            f.dirty_from = 3;
        }
        let (o, out) = pc.import();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(out.lines().last(), Some(want), "{out}");
        assert!(o.notes.iter().any(|n| n.contains("commit して push する")));
    }
}

/// git が stderr に warning を出しても、変更の行とは数えない (取り込みは止まらず、commit も促さない)
#[test]
fn git_warnings_are_not_changes() {
    let pc = Pc::new(true);
    pc.run(APPLY);
    pc.fake.borrow_mut().git_warnings =
        vec!["warning: unable to access '/x/.config/git/attributes'".to_string()];
    let (o, out) = pc.import();
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert!(out.contains("commit するものはありません"), "{out}");
}

/// taskkill が UTF-8 でない文字コード (日本語の Windows の CP932) で書いた行は、化けたまま出さない
#[test]
fn garbled_taskkill_output_is_not_shown() {
    let pc = Pc::new(true);
    {
        let mut f = pc.fake.borrow_mut();
        f.taskkill_rc = 1;
        f.taskkill_out = vec![
            "\u{fffd}\u{fffd}: \u{fffd}\u{fffd}".to_string(),
            "ERROR: access denied".to_string(),
        ];
    }
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Failed, "{out}");
    assert!(!out.contains('\u{fffd}') && out.contains("ERROR: access denied"));
    assert!(
        out.contains("UTF-8 で読めない行は出していない") && out.contains("taskkill の終了コード 1")
    );
}

#[test]
fn import_refuses_uncommitted_changes_and_unknown_checkouts() {
    let pc = Pc::new(true);
    pc.run(APPLY);
    let record = std::fs::read(pc.record()).unwrap();
    pc.put_windows_config(KEYMAP_GUI);
    pc.fake.borrow_mut().dirty = vec![(
        pc.config_dir(),
        vec![" M win/google-japanese-input/keymap.tsv".to_string()],
        vec![" M keymap.tsv".to_string()],
    )];
    let (o, out) = pc.import();
    assert_eq!(o.kind, Kind::Failed, "{out}");
    assert!(
        out.contains("google-japanese-input に commit していない変更があります")
            && out.contains("M keymap.tsv")
    );
    assert_eq!(
        std::fs::read_to_string(pc.config_dir().join("keymap.tsv")).unwrap(),
        KEYMAP
    );
    assert_eq!(std::fs::read(pc.record()).unwrap(), record);
    // dotfiles-private の側
    pc.fake.borrow_mut().dirty = vec![(
        pc.dict_dir(),
        vec!["?? 新しい辞書.tsv".to_string()],
        vec!["?? 新しい辞書.tsv".to_string()],
    )];
    let (o, out) = pc.import();
    assert_eq!(o.kind, Kind::Failed, "{out}");
    assert!(out.contains("dictionaries に commit していない変更があります"));
    // git の checkout か確かめられない
    pc.fake.borrow_mut().dirty.clear();
    pc.fake.borrow_mut().git_fails = true;
    let (o, out) = pc.import();
    assert_eq!(o.kind, Kind::Failed, "{out}");
    assert!(out.contains("確かめられません"));
    assert_eq!(
        std::fs::read_to_string(pc.config_dir().join("keymap.tsv")).unwrap(),
        KEYMAP
    );
}

#[test]
fn word_registered_dictionary_conflicts_then_imports_cleanly() {
    let pc = Pc::new(true);
    pc.put_windows_config(KEYMAP);
    // 単語登録の形 (comment の無い語) と、表で編集した語 (空のコメントがある)
    let mut d = pb::Message::new(&pb::USER_DICTIONARY);
    d.set("id", pb::Value::U64(11_262_860_659_733_797_146));
    d.set("name", pb::Value::Bytes("テスト辞書".as_bytes().to_vec()));
    for (k, v, comment) in [
        ("てすと", "テスト", Some("")),
        ("かくうのよみ", "架空の単語", None),
    ] {
        let mut e = pb::Message::new(&pb::ENTRY);
        e.set("key", pb::Value::Bytes(k.as_bytes().to_vec()));
        e.set("value", pb::Value::Bytes(v.as_bytes().to_vec()));
        if let Some(c) = comment {
            e.set("comment", pb::Value::Bytes(c.as_bytes().to_vec()));
        }
        e.set("pos", pb::Value::I32(1));
        d.push("entries", pb::Value::Msg(e));
    }
    let mut s = pb::Message::new(&pb::STORAGE);
    s.push("dictionaries", pb::Value::Msg(d));
    std::fs::write(pc.ime().join(ime::DICTIONARY_DB), s.encode()).unwrap();
    let (o, _) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Manual);
    let (o, out) = pc.import();
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert_eq!(
        std::fs::read_to_string(pc.dict_dir().join("テスト辞書.tsv")).unwrap(),
        "てすと\tテスト\t名詞\t\nかくうのよみ\t架空の単語\t名詞\t\n"
    );
    let (o, out) = pc.run(APPLY);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert_eq!(out.matches("同じです: ").count(), 2);
    assert_eq!(pc.kills(), 0);
}

#[test]
fn wsl_host_check_explains_missing_runner_records_and_wsl_side_fixes() {
    let mut pc = Pc::new(true);
    pc.host = RUNNER_HOST;
    pc.run(APPLY);
    std::fs::remove_file(pc.record()).unwrap();
    pc.host = WSL_HOST;
    let (o, out) = pc.run(CHECK);
    assert_eq!(o.kind, Kind::Ok, "{out}");
    assert!(out.contains("runner の記録はまだありません (2 件。") && out.contains("deployed.json"));
    pc.put_windows_config(KEYMAP_GUI);
    let (o, out) = pc.run(CHECK);
    assert_eq!(o.kind, Kind::Manual, "{out}");
    assert!(out.contains("bootstrap-windows-google-ime.sh --import"));
    assert!(
        o.notes
            .iter()
            .any(|n| n.contains("受け持ちは WSL の setup"))
    );
    // 受け持ちが runner なら、記録だけ作ると出す
    pc.host = RUNNER_HOST;
    pc.put_windows_config(KEYMAP);
    let (_, out) = pc.run(CHECK);
    assert!(out.contains("置いた記録がまだ無いファイルが"), "{out}");
}

#[test]
fn texts_and_names_match_the_wsl_script() {
    let script = std::fs::read_to_string(crate::hooks::parity::repo_file(
        "nix/scripts/bootstrap-windows-google-ime.sh",
    ))
    .unwrap()
    .replace("\r\n", "\n");
    for want in [
        "record_file=\"${state_dir}/deployed.json\"",
        "pending_file=\"${state_dir}/restart-pending\"",
        "state_dir=\"${HOME}/.local/state/dotfiles/google-japanese-input\"",
        "keep_backups=10",
        "timeout 30 tasklist.exe /FI \"IMAGENAME eq GoogleIMEJaTool.exe\" /FO CSV /NH",
        "timeout 30 taskkill.exe /F /IM GoogleIMEJaConverter.exe",
        "config_dir=\"${repo_dir}/win/google-japanese-input\"",
        "dict_dir=\"$(private_dir)/google-japanese-input/dictionaries\"",
        "ime_dir=\"${windows_home}/AppData/LocalLow/Google/Google Japanese Input\"",
        "watched=(config.txtpb keymap.tsv romaji.tsv)",
        "backup_dir=\"${state_dir}/backup/$(date -u +%Y%m%dT%H%M%SZ)-$$\"",
    ] {
        assert!(script.contains(want), "WSL の script に {want} が無い");
    }
    assert_eq!(
        (
            RECORD_FILE,
            PENDING_FILE,
            STATE_REL,
            KEEP_BACKUPS,
            TASK_SECS
        ),
        (
            "deployed.json",
            "restart-pending",
            "google-japanese-input",
            10,
            30
        )
    );
    assert_eq!(WATCHED, ["config.txtpb", "keymap.tsv", "romaji.tsv"]);
    assert_eq!(CONFIG_REL, "win/google-japanese-input");
    assert_eq!(DICT_REL, "google-japanese-input/dictionaries");
    assert_eq!(IME_REL, "AppData/LocalLow/Google/Google Japanese Input");
    // config.txtpb の頭は google_ime.py と同じ字
    let py = std::fs::read_to_string(crate::hooks::parity::repo_file(
        "nix/pkgs/pjp-google-ime/google_ime.py",
    ))
    .unwrap()
    .replace("\r\n", "\n");
    for line in ime::TXTPB_HEADER.lines() {
        assert!(
            py.contains(&format!("\"{line}\\n\"")),
            "google_ime.py に {line} が無い"
        );
    }
}

// ------------------------------------------------------------------ pjp-google-ime (WSL の Python の版) との突き合わせ

#[cfg(unix)]
mod parity {
    use super::super::*;
    use super::{DICT, KEYMAP, KEYMAP_GUI, KEYMAP2, RUNNER_HOST, TXTPB};
    use crate::hooks::parity as bash;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::process::{CommandSpec, RunResult};
    use crate::testutil::TempDir;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::OnceLock;

    /// pjp-google-ime の exe。`PJP_GOOGLE_IME` があればそれ、無ければ repo の flake から nix で作る (nix が無ければ飛ばす。
    /// `DOTFILES_WIN_NIX_PARITY=1` なら飛ばさずに落ちる。CI の Linux の job)
    fn tool() -> Option<PathBuf> {
        static TOOL: OnceLock<Option<PathBuf>> = OnceLock::new();
        TOOL.get_or_init(|| {
            let must = std::env::var("DOTFILES_WIN_NIX_PARITY").is_ok_and(|v| v == "1");
            if let Some(p) = std::env::var_os("PJP_GOOGLE_IME") {
                return Some(PathBuf::from(p));
            }
            let flake = std::fs::canonicalize(bash::repo_file("nix")).unwrap();
            let out = Command::new("nix")
                .arg("build")
                .arg("--no-link")
                .arg("--print-out-paths")
                .arg(format!("path:{}#pjp-google-ime", flake.display()))
                .stdin(std::process::Stdio::null())
                .output();
            match out {
                Ok(o) if o.status.success() => {
                    let p = String::from_utf8(o.stdout).unwrap();
                    Some(PathBuf::from(p.trim()).join("bin").join("pjp-google-ime"))
                }
                other => {
                    assert!(
                        !must,
                        "DOTFILES_WIN_NIX_PARITY=1 なのに pjp-google-ime を作れない: {other:?}"
                    );
                    None
                }
            }
        })
        .clone()
    }

    /// pjp-google-ime を流す (終了コードと stdout)
    fn py(args: &[&str]) -> (i32, String) {
        let o = Command::new(tool().unwrap())
            .args(args)
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        (
            o.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&o.stdout).into_owned(),
        )
    }

    fn write_texts(dir: &Path, files: &[(&str, &str)]) {
        std::fs::create_dir_all(dir).unwrap();
        for (n, t) in files {
            std::fs::write(dir.join(n), t).unwrap();
        }
    }

    /// 設定のテキストの組 (名前と、config_dir に置くファイル)。作り物で、repo のものも入れる
    fn config_cases() -> Vec<(String, Vec<(String, String)>)> {
        let repo = bash::repo_file("win/google-japanese-input");
        let read = |n: &str| std::fs::read_to_string(repo.join(n)).unwrap();
        let mut c: Vec<(String, Vec<(String, String)>)> = Vec::new();
        let mut add = |name: &str, files: &[(&str, &str)]| {
            c.push((
                name.to_string(),
                files
                    .iter()
                    .map(|(a, b)| (a.to_string(), b.to_string()))
                    .collect(),
            ))
        };
        add(
            "repo",
            &[
                ("config.txtpb", &read("config.txtpb")),
                ("keymap.tsv", &read("keymap.tsv")),
            ],
        );
        add("min", &[("config.txtpb", TXTPB), ("keymap.tsv", KEYMAP)]);
        add(
            "crlf",
            &[
                ("config.txtpb", &TXTPB.replace('\n', "\r\n")),
                ("keymap.tsv", &KEYMAP2.replace('\n', "\r\n")),
            ],
        );
        add(
            "romaji",
            &[
                ("config.txtpb", TXTPB),
                ("keymap.tsv", KEYMAP),
                ("romaji.tsv", "a\tあ\nka\tか\nnn\tん\tn\nx\t\ty\n"),
            ],
        );
        add(
            "no-keymap",
            &[("config.txtpb", "session_keymap: MSIME\nverbose_level: 1\n")],
        );
        add(
            "every-kind",
            &[(
                "config.txtpb",
                "# コメント\nverbose_level: -3\nsession_keymap: NONE\noverlay_keymaps: [ATOK, OVERLAY_FOR_TEST]\noverlay_keymaps: 2\n\
                     character_form_rules < group: 'x\\'y' preedit_character_form: HALF_WIDTH >\ncharacter_form_rules { group: \"\\u3042\\x41\\101\" \"\\\"\\\\\" }\n\
                     character_form_rules { group: \"\\t\\001\\177é😀\" conversion_character_form: 3 }\n\
                     information_list_config: { }\nauto_conversion_key: 0x0f, suggestions_size: 010; composing_timeout_threshold_msec: -2147483648\n\
                     incognito_mode: t use_mode_indicator: False\n",
            )],
        );
        add(
            "custom-without-keymap",
            &[("config.txtpb", "session_keymap: CUSTOM\n")],
        );
        add(
            "bad-enum",
            &[
                ("config.txtpb", "session_keymap: 6\n"),
                ("keymap.tsv", KEYMAP),
            ],
        );
        add(
            "bad-field",
            &[("config.txtpb", "nosuch: 1\n"), ("keymap.tsv", KEYMAP)],
        );
        add(
            "general-config",
            &[
                ("config.txtpb", "general_config { config_version: 1 }\n"),
                ("keymap.tsv", KEYMAP),
            ],
        );
        add(
            "table-in-txtpb",
            &[
                ("config.txtpb", "custom_roman_table: \"a\"\n"),
                ("keymap.tsv", KEYMAP),
            ],
        );
        add(
            "dup",
            &[("config.txtpb", "verbose_level: 1\nverbose_level: 1\n")],
        );
        add(
            "bad-keymap-state",
            &[
                ("config.txtpb", TXTPB),
                (
                    "keymap.tsv",
                    "status\tkey\tcommand\nDirect input\tF13\tIMEOn\n",
                ),
            ],
        );
        add(
            "bad-keymap-header",
            &[
                ("config.txtpb", TXTPB),
                ("keymap.tsv", "DirectInput\tF13\tIMEOn\n"),
            ],
        );
        add(
            "empty-keymap",
            &[
                ("config.txtpb", TXTPB),
                ("keymap.tsv", "status\tkey\tcommand\n"),
            ],
        );
        add(
            "bad-romaji",
            &[
                ("config.txtpb", TXTPB),
                ("keymap.tsv", KEYMAP),
                ("romaji.tsv", "a\n"),
            ],
        );
        add("bom", &[("config.txtpb", "\u{feff}verbose_level: 1\n")]);
        add(
            "bad-escape",
            &[(
                "config.txtpb",
                "character_form_rules { group: \"\\xe3\\x81\" }\n",
            )],
        );
        add(
            "unicode-space",
            &[("config.txtpb", "verbose_level:\u{3000}1\r\n")],
        );
        add(
            "lone-cr",
            &[
                ("config.txtpb", TXTPB),
                ("keymap.tsv", &KEYMAP.replace('\n', "\r")),
            ],
        );
        c
    }

    /// 辞書の組 (名前と、{辞書の名前: TSV})。語は作り物
    fn dictionary_cases() -> Vec<(String, Vec<(String, String)>)> {
        let mut c: Vec<(String, Vec<(String, String)>)> = Vec::new();
        let mut add = |name: &str, files: &[(&str, &str)]| {
            c.push((
                name.to_string(),
                files
                    .iter()
                    .map(|(a, b)| (a.to_string(), b.to_string()))
                    .collect(),
            ))
        };
        add("one", &[("テスト辞書", DICT)]);
        add("none", &[]);
        add("empty", &[("空の辞書", "")]);
        add(
            "many",
            &[
                ("b", "よみ\tたんご\t名詞\tこめんと\nあ\tア\t固有名詞\n"),
                ("a", "かお\t(^_^)\t顔文字\t\r\nき\t記\t記号\n"),
                ("名前に 空白", "x\ty\t抑制単語\tz\n"),
                ("😀", "え\t絵\t品詞なし\t\n"),
            ],
        );
        add("three-columns", &[("d", "あ\tア\t名詞\n")]);
        add("lone-cr", &[("d", "あ\tア\t名詞\t\rい\tイ\t名詞\t\r")]);
        add("bad-columns", &[("d", "あ\tア\n")]);
        add("bad-pos", &[("d", "あ\tア\t名詞もどき\n")]);
        add("empty-reading", &[("d", "\tア\t名詞\n")]);
        add("hidden-name", &[(".d", "あ\tア\t名詞\n")]);
        add("blank-line", &[("d", "あ\tア\t名詞\n\n")]);
        c
    }

    /// 組み立てたバイト列が pjp-google-ime build と同じ。読めないテキストは両方が止める
    #[test]
    fn builds_like_pjp_google_ime() {
        if tool().is_none() {
            return;
        }
        let t = TempDir::new("ime-parity-build");
        for (i, (name, files)) in config_cases().into_iter().enumerate() {
            let dir = t.path().join(format!("c{i}"));
            let files: Vec<(&str, &str)> = files
                .iter()
                .map(|(a, b)| (a.as_str(), b.as_str()))
                .collect();
            write_texts(&dir.join("conf"), &files);
            let out = dir.join("out");
            let (rc, _) = py(&[
                "build",
                "--config-dir",
                dir.join("conf").to_str().unwrap(),
                "--out",
                out.to_str().unwrap(),
            ]);
            let ours = ime::build(&dir.join("conf"), None);
            match ours {
                Ok(b) => {
                    assert_eq!(rc, 0, "{name}: pjp-google-ime は止めた");
                    assert_eq!(
                        std::fs::read(out.join("config1.db")).unwrap(),
                        b.config,
                        "{name}"
                    );
                }
                Err(e) => assert_ne!(rc, 0, "{name}: runner だけが止めた ({e})"),
            }
        }
        for (i, (name, dicts)) in dictionary_cases().into_iter().enumerate() {
            let dir = t.path().join(format!("d{i}"));
            write_texts(
                &dir.join("conf"),
                &[("config.txtpb", TXTPB), ("keymap.tsv", KEYMAP)],
            );
            std::fs::create_dir_all(dir.join("dict")).unwrap();
            for (n, text) in &dicts {
                std::fs::write(dir.join("dict").join(format!("{n}.tsv")), text).unwrap();
            }
            let out = dir.join("out");
            let (rc, _) = py(&[
                "build",
                "--config-dir",
                dir.join("conf").to_str().unwrap(),
                "--dictionary-dir",
                dir.join("dict").to_str().unwrap(),
                "--out",
                out.to_str().unwrap(),
            ]);
            match ime::build(&dir.join("conf"), Some(&dir.join("dict"))) {
                Ok(b) => {
                    assert_eq!(rc, 0, "{name}: pjp-google-ime は止めた");
                    assert_eq!(
                        std::fs::read(out.join("config1.db")).unwrap(),
                        b.config,
                        "{name}"
                    );
                    assert_eq!(
                        std::fs::read(out.join("user_dictionary.db")).unwrap(),
                        b.dictionary.unwrap(),
                        "{name}"
                    );
                }
                Err(e) => assert_ne!(rc, 0, "{name}: runner だけが止めた ({e})"),
            }
        }
    }

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    /// 作ったバイナリ (画面で作った形・知らない項目・壊れたものなど) の digest とテキストへ戻したものが、pjp-google-ime digest・decode と同じ
    #[test]
    fn digests_and_decodes_like_pjp_google_ime() {
        if tool().is_none() {
            return;
        }
        let base_cfg = ime::config_from_text(TXTPB, Some(KEYMAP), None)
            .unwrap()
            .encode();
        let gui_cfg = ime::config_from_text(TXTPB, Some(KEYMAP_GUI), None)
            .unwrap()
            .encode();
        let configs: Vec<(&str, Vec<u8>)> = vec![
            ("base", base_cfg.clone()),
            ("gui", gui_cfg),
            // general_config { config_version: 1 last_modified_product_version: "2.29" } を後ろに足した
            (
                "general-config",
                [base_cfg.clone(), hex("0a0808011204322e3239")].concat(),
            ),
            ("unknown-field", [base_cfg, hex("f80701")].concat()),
            ("unknown-enum", hex("c80206")),
            ("empty-tables", hex("5000d20200da0200")),
            ("no-verbose", hex("c80202")),
            ("bad-utf8-group", hex("b203040a02e381")),
            ("bad-utf8-table", hex("d20201ff")),
            ("broken", vec![0xff, 0xff, 0xff]),
            ("empty", Vec::new()),
            ("negative", hex("50feffffff0f")),
            ("packed-unknown", hex("a204020107")),
            ("packed-truncated", hex("a204020180")),
        ];
        let d = |pairs: &[(&str, &str)]| {
            ime::dictionaries_from_tsv(
                &pairs
                    .iter()
                    .map(|(a, b)| (a.to_string(), b.to_string()))
                    .collect(),
            )
            .unwrap()
            .encode()
        };
        let entry = |fields: &[(&str, &[u8])], pos: Option<i32>| {
            let mut e = pb::Message::new(&pb::ENTRY);
            for (k, v) in fields {
                e.set(k, pb::Value::Bytes(v.to_vec()));
            }
            if let Some(p) = pos {
                e.set("pos", pb::Value::I32(p));
            }
            pb::Value::Msg(e)
        };
        let storage = |name: Option<&[u8]>, id: Option<u64>, entries: Vec<pb::Value>| {
            let mut dict = pb::Message::new(&pb::USER_DICTIONARY);
            if let Some(i) = id {
                dict.set("id", pb::Value::U64(i));
            }
            if let Some(n) = name {
                dict.set("name", pb::Value::Bytes(n.to_vec()));
            }
            for e in entries {
                dict.push("entries", e);
            }
            let mut s = pb::Message::new(&pb::STORAGE);
            s.push("dictionaries", pb::Value::Msg(dict));
            s.encode()
        };
        let dicts: Vec<(&str, Vec<u8>)> = vec![
            ("one", d(&[("テスト辞書", DICT)])),
            ("two", d(&[("b", "い\tイ\t名詞\tc\n"), ("a", DICT)])),
            // 単語登録の形 (comment の無い語)・空の語・乱数の id
            (
                "wordreg",
                storage(
                    Some("テスト辞書".as_bytes()),
                    Some(11_262_860_659_733_797_146),
                    vec![
                        entry(
                            &[
                                ("key", "かくうのよみ".as_bytes()),
                                ("value", "架空の単語".as_bytes()),
                            ],
                            Some(1),
                        ),
                        entry(&[], Some(1)),
                    ],
                ),
            ),
            (
                "locale",
                storage(
                    Some(b"d"),
                    None,
                    vec![entry(
                        &[("key", b"a"), ("value", b"b"), ("locale", b"ja")],
                        None,
                    )],
                ),
            ),
            (
                "no-pos",
                storage(
                    Some(b"d"),
                    None,
                    vec![entry(&[("key", b"a"), ("value", b"b")], None)],
                ),
            ),
            (
                "tab",
                storage(
                    Some(b"d"),
                    None,
                    vec![entry(&[("key", b"a\tb"), ("value", b"c")], Some(1))],
                ),
            ),
            (
                "bad-utf8-word",
                storage(
                    Some(b"d"),
                    None,
                    vec![entry(&[("key", b"\xff"), ("value", b"c")], Some(1))],
                ),
            ),
            (
                "dup-names",
                [
                    storage(Some(b"d"), None, vec![]),
                    storage(Some(b"d"), None, vec![]),
                ]
                .concat(),
            ),
            ("unknown-pos", hex("12071a016422022863")),
            ("blank", hex("12071a016422020a00")),
            ("no-name", hex("120822060a0161120162")),
            ("broken", vec![0x12, 0x05]),
            ("version", hex("0801")),
            ("bad-utf8-name", hex("12031a01ff")),
            ("mixed-names", hex("12031a016112031a01ff")),
        ];

        let t = TempDir::new("ime-parity-digest");
        for (kind, cases) in [(Db::Config, &configs), (Db::Dictionary, &dicts)] {
            let k = if kind == Db::Config {
                "config"
            } else {
                "dictionary"
            };
            for (name, bytes) in cases {
                let file = t.path().join(format!("{k}-{name}.db"));
                std::fs::write(&file, bytes).unwrap();
                let (rc, out) = py(&["digest", "--kind", k, file.to_str().unwrap()]);
                match ime::digest(kind, bytes, "x") {
                    Ok(dg) => assert_eq!((rc, out.trim()), (0, dg.as_str()), "{k} {name}"),
                    Err(e) => {
                        assert_ne!(rc, 0, "{k} {name}: runner だけが digest を出せない ({e})")
                    }
                }
                let dec = t.path().join(format!("dec-{k}-{name}"));
                let (rc, _) = py(&[
                    "decode",
                    "--kind",
                    k,
                    file.to_str().unwrap(),
                    "--out",
                    dec.to_str().unwrap(),
                ]);
                match ime::decode(kind, bytes, "x") {
                    Ok(ime::Decoded::Config(c)) => {
                        assert_eq!(rc, 0, "{k} {name}: pjp-google-ime は戻せない");
                        let rd = |n: &str| std::fs::read_to_string(dec.join(n)).ok();
                        assert_eq!(
                            rd("config.txtpb").as_deref(),
                            Some(c.txtpb.as_str()),
                            "{k} {name}"
                        );
                        assert_eq!(rd("keymap.tsv"), c.keymap, "{k} {name}");
                        assert_eq!(rd("romaji.tsv"), c.romaji, "{k} {name}");
                    }
                    Ok(ime::Decoded::Dictionaries(m)) => {
                        assert_eq!(rc, 0, "{k} {name}: pjp-google-ime は戻せない");
                        let theirs: BTreeMap<String, String> =
                            ime::tsv_files(&dec.join("dictionaries"))
                                .unwrap()
                                .into_iter()
                                .map(|(n, p)| (n, std::fs::read_to_string(p).unwrap()))
                                .collect();
                        assert_eq!(theirs, m, "{k} {name}");
                    }
                    Err(e) => assert_ne!(rc, 0, "{k} {name}: runner だけが戻せない ({e})"),
                }
            }
        }
    }

    /// 取り込みで書くテキストが pjp-google-ime import と同じ (書いた・消したファイルの行も)
    #[test]
    fn imports_like_pjp_google_ime() {
        if tool().is_none() {
            return;
        }
        let t = TempDir::new("ime-parity-import");
        let cfg = ime::config_from_text(TXTPB, Some(KEYMAP_GUI), Some("a\tあ\n")).unwrap();
        let dicts = ime::dictionaries_from_tsv(
            &[
                ("テスト辞書".to_string(), DICT.to_string()),
                ("新しい辞書".to_string(), "あ\tア\t名詞\tx\n".to_string()),
            ]
            .into(),
        )
        .unwrap();
        for side in ["py", "rn"] {
            let w = t.path().join(side).join("win");
            std::fs::create_dir_all(&w).unwrap();
            std::fs::write(w.join("config1.db"), cfg.encode()).unwrap();
            std::fs::write(w.join("user_dictionary.db"), dicts.encode()).unwrap();
            write_texts(
                &t.path().join(side).join("conf"),
                &[("config.txtpb", TXTPB), ("keymap.tsv", KEYMAP)],
            );
            write_texts(
                &t.path().join(side).join("dict"),
                &[
                    ("テスト辞書.tsv", "古い\t語\t名詞\t\n"),
                    ("消える辞書.tsv", ""),
                ],
            );
        }
        let p = |s: &str, n: &str| t.path().join(s).join(n);
        let (rc, out) = py(&[
            "import",
            "--windows-dir",
            p("py", "win").to_str().unwrap(),
            "--config-dir",
            p("py", "conf").to_str().unwrap(),
            "--dictionary-dir",
            p("py", "dict").to_str().unwrap(),
        ]);
        assert_eq!(rc, 0);
        let r = ime::import(&p("rn", "win"), &p("rn", "conf"), Some(&p("rn", "dict"))).unwrap();
        let ours: Vec<String> = r
            .lines
            .iter()
            .map(|l| l.replace(&format!("{}/rn/", t.path().display()), ""))
            .collect();
        let theirs: Vec<String> = out
            .lines()
            .map(|l| l.replace(&format!("{}/py/", t.path().display()), ""))
            .collect();
        assert_eq!(ours, theirs);
        for dir in ["conf", "dict"] {
            let list = |s: &str| -> Vec<(String, Vec<u8>)> {
                let mut v: Vec<(String, Vec<u8>)> = std::fs::read_dir(p(s, dir))
                    .unwrap()
                    .map(|e| e.unwrap())
                    .map(|e| {
                        (
                            e.file_name().to_string_lossy().into_owned(),
                            std::fs::read(e.path()).unwrap(),
                        )
                    })
                    .collect();
                v.sort();
                v
            };
            assert_eq!(list("py"), list("rn"), "{dir}");
        }
    }

    // ---------------------------------------------------------- WSL の script との突き合わせ

    /// WSL の試験から、偽の tasklist.exe・taskkill.exe の本体を抜き出す (写しを持たない)
    fn fake_exes() -> (String, String) {
        let text = std::fs::read_to_string(bash::repo_file(
            "nix/tests/bootstrap-windows-google-ime.test.sh",
        ))
        .unwrap()
        .replace("\r\n", "\n");
        let open = "    cat <<'EOF'\n";
        let mut bodies = Vec::new();
        let mut rest = text.as_str();
        while let Some(i) = rest.find(open) {
            let after = &rest[i + open.len()..];
            let end = after.find("\nEOF\n").expect("heredoc の終わりが無い") + 1;
            bodies.push(after[..end].to_string());
            rest = &after[end..];
        }
        let pick = |needle: &str| {
            let v: Vec<&String> = bodies.iter().filter(|b| b.contains(needle)).collect();
            assert_eq!(
                v.len(),
                1,
                "WSL の試験に {needle} の偽物が 1 つだけあるはず"
            );
            v[0].clone()
        };
        (pick("tasklist-calls"), pick("taskkill-calls"))
    }

    /// runner の側の外のコマンドの口: 本物の口で打つ (偽の tasklist.exe・taskkill.exe は bash の script)。HOME と PATH は WSL の側と同じ形
    struct ParitySys {
        home: PathBuf,
        path: String,
        sys_bin: PathBuf,
        envs: Vec<(String, String)>,
    }

    impl crate::process::Sys for ParitySys {
        fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult {
            let mut s = spec.clone().env("HOME", &self.home).env("PATH", &self.path);
            for (k, v) in &self.envs {
                s = s.env(k, v);
            }
            crate::process::RealSys.run(&s, on_line)
        }

        fn which(&self, name: &str) -> Option<PathBuf> {
            match name {
                "tasklist" => Some(self.home.join("bin").join("tasklist.exe")),
                "taskkill" => Some(self.home.join("bin").join("taskkill.exe")),
                "git" => Some(self.sys_bin.join("git")),
                _ => None,
            }
        }

        fn env(&self, _name: &str) -> Option<String> {
            None
        }
    }

    #[derive(Clone, Copy, Debug)]
    enum Run {
        Apply,
        Force,
        Dry,
        Import,
    }

    /// WSL の script と runner を、別々の (同じ中身の) 偽の Windows・checkout・記録で流す組。`wsl/` と `rn/` に分ける
    struct Pair {
        t: TempDir,
        sys_bin: PathBuf,
        /// 両側の git に渡す env (GIT_CONFIG_GLOBAL など)
        base: Vec<(String, String)>,
        /// 場面ごとに偽の exe に渡す env (FAKE_TASKKILL_RC など)
        extra: std::cell::RefCell<Vec<(String, String)>>,
    }

    impl Pair {
        fn new() -> Pair {
            use std::os::unix::fs::PermissionsExt;
            let t = TempDir::new("google-ime-parity");
            let sys_bin = t.path().join("sys-bin");
            std::fs::create_dir_all(&sys_bin).unwrap();
            let path = std::env::var_os("PATH").unwrap_or_default();
            for c in [
                "bash", "env", "jq", "grep", "sed", "tr", "cat", "head", "tail", "mkdir", "mktemp",
                "mv", "rm", "cp", "dirname", "basename", "chmod", "date", "sort", "find", "diff",
                "cmp", "comm", "wc", "timeout", "git",
            ] {
                let found = std::env::split_paths(&path)
                    .filter(|d| !d.starts_with("/mnt"))
                    .map(|d| d.join(c))
                    .find(|p| p.is_file())
                    .unwrap_or_else(|| panic!("{c} が無い"));
                std::os::unix::fs::symlink(found, sys_bin.join(c)).unwrap();
            }
            std::os::unix::fs::symlink(tool().unwrap(), sys_bin.join("pjp-google-ime")).unwrap();
            let (tasklist, taskkill) = fake_exes();
            let bash = sys_bin.join("bash");
            for side in ["wsl", "rn"] {
                let home = t.path().join(side).join("home");
                std::fs::create_dir_all(home.join("bin")).unwrap();
                for (name, body) in [("tasklist.exe", &tasklist), ("taskkill.exe", &taskkill)] {
                    let f = home.join("bin").join(name);
                    std::fs::write(&f, format!("#!{}\n{body}", bash.display())).unwrap();
                    std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o755)).unwrap();
                }
                std::fs::create_dir_all(
                    t.path()
                        .join(side)
                        .join("win")
                        .join("AppData/LocalLow/Google/Google Japanese Input"),
                )
                .unwrap();
            }
            let wsl_state = t.path().join("wsl/home/.local/state/dotfiles");
            std::fs::create_dir_all(&wsl_state).unwrap();
            std::fs::write(
                wsl_state.join("windows-files.json"),
                format!(
                    "{{\"enable\":true,\"version\":1,\"windowsHome\":\"{}\"}}\n",
                    t.path().join("wsl/win").display()
                ),
            )
            .unwrap();
            let scripts = t.path().join("wsl/repo/nix/scripts");
            std::fs::create_dir_all(&scripts).unwrap();
            std::fs::copy(
                bash::repo_file("nix/scripts/bootstrap-windows-google-ime.sh"),
                scripts.join("bootstrap-windows-google-ime.sh"),
            )
            .unwrap();
            let base = vec![
                ("GIT_CONFIG_GLOBAL".to_string(), "/dev/null".to_string()),
                ("GIT_CONFIG_SYSTEM".to_string(), "/dev/null".to_string()),
                (
                    "GIT_CEILING_DIRECTORIES".to_string(),
                    t.path().display().to_string(),
                ),
                ("GIT_AUTHOR_NAME".to_string(), "test".to_string()),
                (
                    "GIT_AUTHOR_EMAIL".to_string(),
                    "test@example.com".to_string(),
                ),
                ("GIT_COMMITTER_NAME".to_string(), "test".to_string()),
                (
                    "GIT_COMMITTER_EMAIL".to_string(),
                    "test@example.com".to_string(),
                ),
            ];
            let p = Pair {
                t,
                sys_bin,
                base,
                extra: std::cell::RefCell::new(Vec::new()),
            };
            p.set_config(TXTPB, KEYMAP);
            p.set_dict("テスト辞書", DICT);
            p.git(&["init", "-q", "-b", "main"]);
            p.commit("init");
            p
        }

        /// 偽の exe に渡す env を替える (渡したものだけにする)
        fn with(&self, extra: &[(&str, &str)]) {
            *self.extra.borrow_mut() = extra
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect();
        }

        fn envs(&self) -> Vec<(String, String)> {
            let mut v = self.base.clone();
            v.extend(self.extra.borrow().iter().cloned());
            v
        }

        /// 両側の repo と dotfiles-private の変更を全部 commit する (変更が無くても commit を作る)
        fn commit(&self, message: &str) {
            self.git(&["add", "-A"]);
            self.git(&["commit", "-q", "--allow-empty", "-m", message]);
        }

        /// 両側の keymap.tsv の末尾に行を足す (commit しない)
        fn append_keymap(&self, line: &str) {
            for s in ["wsl", "rn"] {
                let k = self.config_dir(s).join("keymap.tsv");
                let mut text = std::fs::read_to_string(&k).unwrap();
                text.push_str(line);
                std::fs::write(&k, text).unwrap();
            }
        }

        fn side(&self, s: &str) -> PathBuf {
            self.t.path().join(s)
        }

        fn config_dir(&self, s: &str) -> PathBuf {
            join_segments(&self.side(s).join("repo"), CONFIG_REL)
        }

        fn private(&self, s: &str) -> PathBuf {
            self.side(s).join(if s == "wsl" {
                "private"
            } else {
                "dotfiles-private"
            })
        }

        fn dict_dir(&self, s: &str) -> PathBuf {
            join_segments(&self.private(s), DICT_REL)
        }

        fn ime(&self, s: &str) -> PathBuf {
            join_segments(&self.side(s).join("win"), IME_REL)
        }

        fn state(&self, s: &str) -> PathBuf {
            if s == "wsl" {
                self.side(s)
                    .join("home/.local/state/dotfiles/google-japanese-input")
            } else {
                self.side(s).join("state").join(STATE_REL)
            }
        }

        fn set_config(&self, txtpb: &str, keymap: &str) {
            for s in ["wsl", "rn"] {
                std::fs::create_dir_all(self.config_dir(s)).unwrap();
                std::fs::write(self.config_dir(s).join("config.txtpb"), txtpb).unwrap();
                std::fs::write(self.config_dir(s).join("keymap.tsv"), keymap).unwrap();
            }
        }

        fn set_dict(&self, name: &str, text: &str) {
            for s in ["wsl", "rn"] {
                std::fs::create_dir_all(self.dict_dir(s)).unwrap();
                std::fs::write(self.dict_dir(s).join(format!("{name}.tsv")), text).unwrap();
            }
        }

        /// 両側の repo と dotfiles-private で git を打つ
        fn git(&self, args: &[&str]) {
            for s in ["wsl", "rn"] {
                for dir in [self.side(s).join("repo"), self.private(s)] {
                    let o = Command::new(self.sys_bin.join("git"))
                        .arg("-C")
                        .arg(&dir)
                        .args(args)
                        .env_clear()
                        .env("HOME", self.side(s))
                        .env("PATH", &self.sys_bin)
                        .envs(self.base.iter().map(|(k, v)| (k.as_str(), v.as_str())))
                        .output()
                        .unwrap();
                    assert!(o.status.success(), "git {args:?}: {o:?}");
                }
            }
        }

        /// 両側の Windows に同じバイト列を置く
        fn put_windows(&self, name: &str, bytes: &[u8]) {
            for s in ["wsl", "rn"] {
                std::fs::write(self.ime(s).join(name), bytes).unwrap();
            }
        }

        fn wsl(&self, run: Run) -> (i32, String) {
            let args: &[&str] = match run {
                Run::Apply => &[],
                Run::Force => &["--force"],
                Run::Dry => &["--dry-run"],
                Run::Import => &["--import"],
            };
            let home = self.side("wsl").join("home");
            let o = Command::new(self.sys_bin.join("bash"))
                .arg(
                    self.side("wsl")
                        .join("repo/nix/scripts/bootstrap-windows-google-ime.sh"),
                )
                .args(args)
                .env_clear()
                .env("HOME", &home)
                .env(
                    "PATH",
                    format!("{}:{}", home.join("bin").display(), self.sys_bin.display()),
                )
                .env("DOTFILES_PRIVATE_DIR", self.private("wsl"))
                .envs(self.envs())
                .stdin(std::process::Stdio::null())
                .output()
                .unwrap();
            (
                o.status.code().unwrap_or(-1),
                format!(
                    "{}{}",
                    String::from_utf8_lossy(&o.stdout),
                    String::from_utf8_lossy(&o.stderr)
                ),
            )
        }

        fn runner(&self, run: Run) -> (Outcome, String) {
            let home = self.side("rn").join("home");
            let sys = ParitySys {
                path: format!("{}:{}", home.join("bin").display(), self.sys_bin.display()),
                sys_bin: self.sys_bin.clone(),
                envs: self.envs(),
                home,
            };
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.side("rn").join("repo"),
                    roots: Roots::from_home(&self.side("rn").join("win")),
                    state_dir: self.side("rn").join("state"),
                    host: parse(
                        RUNNER_HOST,
                        Path::new("h.toml"),
                        Groups::embedded().unwrap(),
                    )
                    .unwrap(),
                    sys: &sys,
                    out: &mut out,
                };
                match run {
                    Run::Apply => GoogleIme::default()
                        .run(&mut ctx, Mode::Apply { force: false })
                        .remove(0),
                    Run::Force => GoogleIme::default()
                        .run(&mut ctx, Mode::Apply { force: true })
                        .remove(0),
                    Run::Dry => GoogleIme::default()
                        .run(&mut ctx, Mode::DryRun { force: false })
                        .remove(0),
                    Run::Import => import(&mut ctx),
                }
            };
            (o, String::from_utf8(out).unwrap())
        }

        fn read(p: &Path) -> Option<Vec<u8>> {
            std::fs::read(p).ok()
        }

        /// 退避の回の数と、それぞれのファイルの名前
        fn backups(&self, s: &str) -> Vec<Vec<String>> {
            let mut dirs: Vec<PathBuf> = std::fs::read_dir(self.state(s).join("backup"))
                .map(|r| r.filter_map(|e| e.ok()).map(|e| e.path()).collect())
                .unwrap_or_default();
            dirs.sort();
            dirs.iter()
                .map(|d| {
                    let mut v: Vec<String> = std::fs::read_dir(d)
                        .unwrap()
                        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                        .collect();
                    v.sort();
                    v
                })
                .collect()
        }

        /// ディレクトリのファイル (名前と中身。無ければ空)
        fn files(dir: &Path) -> Vec<(String, Vec<u8>)> {
            let mut v: Vec<(String, Vec<u8>)> = std::fs::read_dir(dir)
                .map(|r| {
                    r.filter_map(|e| e.ok())
                        .filter(|e| e.path().is_file())
                        .map(|e| {
                            (
                                e.file_name().to_string_lossy().into_owned(),
                                std::fs::read(e.path()).unwrap(),
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
            v.sort();
            v
        }

        /// 両側を同じ流し方で流し、WSL の終了コードと runner の行の種類を確かめ、書いたもの・打ったものが同じかを比べる
        fn step(&self, label: &str, run: Run, rc: i32, kind: Kind) {
            let (wrc, wout) = self.wsl(run);
            let (o, rout) = self.runner(run);
            assert_eq!(wrc, rc, "{label}: WSL の終了コード\n{wout}");
            assert_eq!(o.kind, kind, "{label}: runner の行\n{rout}");
            let ctx = format!("\n--- WSL\n{wout}\n--- runner\n{rout}");
            for f in [ime::CONFIG_DB, ime::DICTIONARY_DB] {
                assert_eq!(
                    Self::read(&self.ime("wsl").join(f)),
                    Self::read(&self.ime("rn").join(f)),
                    "{label}: Windows 側の {f} が違う{ctx}"
                );
            }
            assert_eq!(
                Self::read(&self.state("wsl").join(RECORD_FILE))
                    .map(|b| String::from_utf8(b).unwrap()),
                Self::read(&self.state("rn").join(RECORD_FILE))
                    .map(|b| String::from_utf8(b).unwrap()),
                "{label}: 記録が違う{ctx}"
            );
            assert_eq!(
                self.state("wsl").join(PENDING_FILE).exists(),
                self.state("rn").join(PENDING_FILE).exists(),
                "{label}: 落とし直しの印が違う{ctx}"
            );
            for f in ["tasklist-calls", "taskkill-calls"] {
                assert_eq!(
                    Self::read(&self.side("wsl").join("home").join(f)),
                    Self::read(&self.side("rn").join("home").join(f)),
                    "{label}: {f} が違う{ctx}"
                );
            }
            assert_eq!(
                self.backups("wsl"),
                self.backups("rn"),
                "{label}: 退避が違う{ctx}"
            );
            assert_eq!(
                Self::files(&self.config_dir("wsl")),
                Self::files(&self.config_dir("rn")),
                "{label}: 設定のテキストが違う{ctx}"
            );
            assert_eq!(
                Self::files(&self.dict_dir("wsl")),
                Self::files(&self.dict_dir("rn")),
                "{label}: 辞書のテキストが違う{ctx}"
            );
        }
    }

    /// WSL の script と同じ状態から流し、同じものを置き、同じ記録・印・退避を書き、同じく tasklist・taskkill を打ち、同じく取り込む (一続きの流れ)
    #[test]
    fn does_what_the_wsl_script_does() {
        if !bash::available() || tool().is_none() {
            return;
        }
        let p = Pair::new();
        p.step("dry-run (何も無い)", Run::Dry, 0, Kind::Missing);
        p.step("初めて置く", Run::Apply, 0, Kind::Ok);
        p.step("同じ", Run::Apply, 0, Kind::Ok);
        // 画面で OK を押しただけ (general_config だけが入った)
        let mut c = std::fs::read(p.ime("wsl").join(ime::CONFIG_DB)).unwrap();
        c.extend([0x0a, 0x02, 0x18, 0x01]);
        p.put_windows(ime::CONFIG_DB, &c);
        p.step("時刻だけ違う", Run::Apply, 0, Kind::Ok);
        // repo 側が進んだ
        p.set_config(TXTPB, KEYMAP2);
        p.step("repo 側が進んだ", Run::Apply, 0, Kind::Ok);
        // 画面で変えた
        let gui = ime::config_from_text(TXTPB, Some(KEYMAP_GUI), None)
            .unwrap()
            .encode();
        p.put_windows(ime::CONFIG_DB, &gui);
        p.step("画面で変えた (衝突)", Run::Apply, 1, Kind::Manual);
        p.step("衝突の dry-run", Run::Dry, 1, Kind::Manual);
        // 取り込む (repo 側の変更を先に commit する)
        p.commit("repo 側を進めた");
        p.step("取り込み", Run::Import, 0, Kind::Ok);
        p.step("取り込んだ後は同じ", Run::Apply, 0, Kind::Ok);
        p.commit("取り込んだ");
        // --force
        p.put_windows(
            ime::CONFIG_DB,
            &ime::config_from_text(TXTPB, Some(KEYMAP2), None)
                .unwrap()
                .encode(),
        );
        p.step("--force", Run::Force, 0, Kind::Ok);
        // 読めない Windows 側のファイル
        p.put_windows(ime::CONFIG_DB, &[0xff, 0xff, 0xff]);
        p.step("読めないファイル (衝突)", Run::Apply, 1, Kind::Manual);
        p.step("読めないファイルを --force", Run::Force, 0, Kind::Ok);
        // 変換サーバーを落とせない → 印 → 次は落とし直す (repo の変更を commit しておく。取り込みは commit していない変更で止まる)
        p.set_config(TXTPB, KEYMAP);
        p.commit("戻した");
        p.with(&[("FAKE_TASKKILL_RC", "1")]);
        p.step("落とせない", Run::Apply, 1, Kind::Failed);
        p.step("印がある回の dry-run", Run::Dry, 0, Kind::Fix);
        p.with(&[("FAKE_TASKLIST_RC", "126")]);
        p.step("tasklist が落ちる回", Run::Apply, 0, Kind::Failed);
        p.with(&[]);
        p.step("印がある回の取り込み", Run::Import, 0, Kind::Ok);
        p.commit("取り込んだ 2");
        p.step("落とし直す", Run::Apply, 0, Kind::Ok);
        p.step("落とし直した後", Run::Apply, 0, Kind::Ok);
        // 設定画面が開いている
        p.with(&[("FAKE_TOOL_RUNNING", "1")]);
        p.set_config(TXTPB, KEYMAP2);
        p.step("設定画面が開いている", Run::Apply, 1, Kind::Manual);
        p.with(&[]);
        p.step("閉じた", Run::Apply, 0, Kind::Ok);
        // 動いていない (128)
        p.with(&[("FAKE_TASKKILL_RC", "128")]);
        p.set_config(TXTPB, KEYMAP);
        p.step("動いていない", Run::Apply, 0, Kind::Ok);
        p.with(&[]);
        // set_config は頭のコメントの無い config.txtpb を書くので、取り込みの前に commit しておく
        p.commit("戻した 2");
        // 辞書: 単語登録の形 (comment の無い語) → 衝突 → 取り込み → 同じ
        let mut d = pb::Message::new(&pb::USER_DICTIONARY);
        d.set("id", pb::Value::U64(11_262_860_659_733_797_146));
        d.set("name", pb::Value::Bytes("テスト辞書".as_bytes().to_vec()));
        for (k, v, cm) in [
            ("てすと", "テスト", Some("")),
            ("かくうのよみ", "架空の単語", None),
        ] {
            let mut e = pb::Message::new(&pb::ENTRY);
            e.set("key", pb::Value::Bytes(k.as_bytes().to_vec()));
            e.set("value", pb::Value::Bytes(v.as_bytes().to_vec()));
            if let Some(cm) = cm {
                e.set("comment", pb::Value::Bytes(cm.as_bytes().to_vec()));
            }
            e.set("pos", pb::Value::I32(1));
            d.push("entries", pb::Value::Msg(e));
        }
        let mut s = pb::Message::new(&pb::STORAGE);
        s.push("dictionaries", pb::Value::Msg(d));
        p.put_windows(ime::DICTIONARY_DB, &s.encode());
        p.step("単語登録の形の辞書 (衝突)", Run::Apply, 1, Kind::Manual);
        p.step("辞書の取り込み", Run::Import, 0, Kind::Ok);
        p.step("辞書の取り込みの後", Run::Apply, 0, Kind::Ok);
        p.commit("辞書");
        // 辞書を足す・消す (repo 側)
        p.set_dict("足した辞書", "あ\tア\t名詞\t\n");
        p.step("辞書を足した", Run::Apply, 0, Kind::Ok);
        for s in ["wsl", "rn"] {
            std::fs::remove_file(p.dict_dir(s).join("足した辞書.tsv")).unwrap();
        }
        p.step("辞書を消した", Run::Apply, 0, Kind::Ok);
        // 退避は 10 回分
        for i in 1..=11 {
            for s in ["wsl", "rn"] {
                std::fs::create_dir_all(
                    p.state(s)
                        .join("backup")
                        .join(format!("20000101T0000{i:02}Z-1")),
                )
                .unwrap();
            }
        }
        p.set_config(TXTPB, KEYMAP2);
        p.step("退避の間引き", Run::Apply, 0, Kind::Ok);
        // 取り込みは commit していない変更で止まる (何も書かない)
        p.commit("進めた");
        p.put_windows(ime::CONFIG_DB, &gui);
        p.append_keymap("Composition\tF14\tIMEOff\n");
        p.step(
            "commit していない変更で取り込みを止める",
            Run::Import,
            1,
            Kind::Failed,
        );
    }

    /// WSL が置いたものを、記録の無い runner が置き直さずに引き継ぐ (同じ commit の clone なら「同じ」で記録だけ作り、WSL と同じ記録になる)
    #[test]
    fn runner_takes_over_what_wsl_placed() {
        if !bash::available() || tool().is_none() {
            return;
        }
        let p = Pair::new();
        let (rc, out) = p.wsl(Run::Apply);
        assert_eq!(rc, 0, "{out}");
        // 同じ PC を runner が見る: WSL が置いたファイルを runner の側へ写す
        for f in [ime::CONFIG_DB, ime::DICTIONARY_DB] {
            std::fs::copy(p.ime("wsl").join(f), p.ime("rn").join(f)).unwrap();
        }
        let before = std::fs::read(p.ime("rn").join(ime::CONFIG_DB)).unwrap();
        let (o, out) = p.runner(Run::Apply);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(out.matches("同じです: ").count(), 2, "{out}");
        assert_eq!(
            std::fs::read(p.ime("rn").join(ime::CONFIG_DB)).unwrap(),
            before
        );
        assert!(
            !p.side("rn").join("home/taskkill-calls").exists(),
            "落とさない"
        );
        assert_eq!(
            std::fs::read(p.state("wsl").join(RECORD_FILE)).unwrap(),
            std::fs::read(p.state("rn").join(RECORD_FILE)).unwrap()
        );
        // WSL の後に画面で変えたものは、runner でも衝突 (記録が無いので「前回置いた記録が無い」側)
        let gui = ime::config_from_text(TXTPB, Some(KEYMAP_GUI), None)
            .unwrap()
            .encode();
        std::fs::write(p.ime("rn").join(ime::CONFIG_DB), &gui).unwrap();
        std::fs::remove_file(p.state("rn").join(RECORD_FILE)).unwrap();
        let (o, out) = p.runner(Run::Apply);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        // repo の更新が WSL に届く前に切り替えると、更新も衝突になる (WSL の記録は読まない)
        std::fs::copy(
            p.ime("wsl").join(ime::CONFIG_DB),
            p.ime("rn").join(ime::CONFIG_DB),
        )
        .unwrap();
        std::fs::write(p.config_dir("rn").join("keymap.tsv"), KEYMAP2).unwrap();
        let (o, out) = p.runner(Run::Apply);
        assert_eq!(o.kind, Kind::Manual, "{out}");
    }
}
