//! herdr-app-mods (order 98): dotfiles の herdr-app の mod (`win/herdr-app/mods/<名前>/`) を、herdr-app の home の `mods\<名前>\` へ
//! 記録つきのコピーで置く。herdr-app は Windows だけなので、WSL の setup に同じ手順は無い (Windows にしか無い手順)。
//!
//! - herdr-app の home は `HERDR_APP_HOME` → `%XDG_CONFIG_HOME%\herdr-app` → `%USERPROFILE%\.config\herdr-app` の順に決める
//!   (`win/herdr-app/Install-HerdrApp.ps1` の Get-HerdrAppLocations と同じ)。どれにしたかは出力の頭に出す
//! - repo の `win/herdr-app/mods/` の下のディレクトリ 1 つが mod 1 つ。その中のファイル (サブディレクトリの中も) を、置き先の同じパスへ置く。
//!   herdr-app が mod を読むと mod のフォルダに書くファイル (`gpui-kit.d.ts`・`jsconfig.json`) は、どの深さでも配らず、置き先のものにも触らない。
//!   名前が `.` で始まるもの (エディタの設定など。herdr-app も読まない) も配らない。home のほかの場所 (ハブの Claude が図を置く
//!   `pjp-hub-panel-media` など) にも触らない
//! - コピーの判定は claude-files と同じ (`linker`): 無い → コピー・同じ → 記録だけ (手で置いた同じ中身も引き取る)・記録どおり → 上書き・
//!   ほか → 衝突 (`--force` で上書き)。repo から消えたファイルは、中身が記録どおりなら消す (今の home の `mods\` の下の記録だけを見る。今も
//!   置くファイルかは `mods\` からの相対パスの要素で比べ、home の綴りの違い (`/` と `\`・Windows の大文字小文字) では消さない)
//! - 置き先の mod のフォルダがリンク (手でつないだ場所) なら、その mod には触らない
//!
//! 記録は `%LOCALAPPDATA%\dotfiles\state\herdr-app-mods.deployed.json`。clone を pull したら `dotfiles apply` で配り直す (herdr-app は
//! mod のフォルダを見張っていて、書き換えると mod を読み直す)。dotfiles-private の docs/adr/068_win_herdr_app_mods_*。

use super::linker::{Linker, Source};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::link::is_link;
use crate::record::Records;
use crate::report::Kind;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// repo の mod の置き場 (`/` 区切り)。この下のディレクトリ 1 つが mod 1 つ (直下のファイルは mod ではない)
pub const MODS: &str = "win/herdr-app/mods";
/// コピーの記録 (`%LOCALAPPDATA%\dotfiles\state\` の下)
pub const RECORD_FILE: &str = "herdr-app-mods.deployed.json";
/// herdr-app (gpui-shell) が mod を読むと書くファイル。`gpui-kit.d.ts` は gpui-kit を import するディレクトリごとに毎回書き直し、
/// `jsconfig.json` は無ければ 1 度だけ書く (その後はユーザーのもので、書き直さない)。どの深さでも配らず、置き先のものにも触らない
/// (repo には `.gitignore` で入れない)
pub const APP_WRITES: [&str; 2] = ["gpui-kit.d.ts", "jsconfig.json"];

pub struct HerdrAppMods;

impl Step for HerdrAppMods {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "herdr-app-mods",
            // herdr-app を入れる手順 (97) の後。herdr-app の skill (98) と並べる
            order: 98,
            title: "dotfiles の herdr-app の mod (win/herdr-app/mods/) を herdr-app の home の mods\\ へ置く",
            // herdr-app を入れる手順・herdr-app の skill と同じ switch
            gate: Gate::Tool("windowsHerdr"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let root = ctx.repo_path(MODS);
        let (home, why) = app_home(ctx);
        ctx.say(format!("dotfiles: {}", root.display()));
        ctx.say(format!("herdr-app の home: {} ({why})", home.display()));
        let mods = match list_mods(&root) {
            Ok(m) => m,
            Err(why) => {
                ctx.say(format!("!! {why}"));
                return vec![Outcome::new(Kind::Failed, why)];
            }
        };
        let record_path = ctx.state_dir.join(RECORD_FILE);
        let records = match Records::load(&record_path) {
            Ok(r) => r,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![
                    Outcome::new(Kind::Failed, "herdr-app-mods のコピーの記録が壊れている").note(e),
                ];
            }
        };
        let mods_dir = home.join("mods");
        let src = Source {
            root: root.clone(),
            prev: None,
            foreign_suffix: None,
            kinds: &[],
            skip_skills: Vec::new(),
            select: None,
            origin: "clone",
            absorb: "dotfiles の win/herdr-app/mods",
            step: "herdr-app-mods",
        };
        let mut w = Linker::new(src, mods_dir.clone(), mode, records);
        let mut keep = Keep::new();
        for m in &mods {
            copy_mod(ctx, &mut w, &root.join(&m.name), m, &mods_dir, &mut keep);
        }
        prune(ctx, &mut w, &mods_dir, &keep);
        w.finish(ctx, &record_path, None)
    }
}

/// 今も置くファイル: `mods\` からの相対パスの鍵 → 今の綴りの置き先 (記録の鍵)
pub type Keep = BTreeMap<Vec<String>, String>;

/// mod 1 つ (`src` は元の mod のフォルダ) のファイルを `mods_dir\<名前>\` の同じパスへ記録つきのコピーで置き、置くファイルを `keep` に足す。
/// 置き先の mod のフォルダがリンク (手でつないだ場所) なら、その mod には触らない。mod.json を先に置く (herdr-app は初めて見た mod のフォルダを、
/// mod.json の place に従って表示中の layout へ差し込むので、place より先に main.js を見せない)。herdr-app-pjp-spaces (claude-skills の mod) も使う。
pub fn copy_mod(
    ctx: &mut Ctx,
    w: &mut Linker,
    src: &Path,
    m: &ModFiles,
    mods_dir: &Path,
    keep: &mut Keep,
) {
    for why in &m.odd {
        w.skip(ctx, format!("mods/{}/{why}", m.name));
    }
    let dest_mod = mods_dir.join(&m.name);
    if is_link(&dest_mod) {
        w.skip(
            ctx,
            format!(
                "mods/{} (置き先がリンク。手でつないだ場所なので、この mod には触らない)",
                m.name
            ),
        );
        return;
    }
    let mut files: Vec<&String> = m.files.iter().collect();
    files.sort_by_key(|rel| rel.as_str() != "mod.json");
    for rel in files {
        let label = format!("mods/{}/{rel}", m.name);
        let dest = join_segments(&dest_mod, rel);
        keep.insert(
            rel_key(&join_segments(Path::new(&m.name), rel)),
            dest.to_string_lossy().into_owned(),
        );
        match std::fs::read(join_segments(src, rel)) {
            Ok(bytes) => w.copy_bytes(ctx, &bytes, &dest, &label),
            Err(e) => w.fail(ctx, format!("{label} のコピー元が読めない ({e})")),
        }
    }
}

/// herdr-app の home と、そう決めたわけ。`win/herdr-app/Install-HerdrApp.ps1` の Get-HerdrAppLocations と同じ順 (`HERDR_APP_HOME` →
/// `%XDG_CONFIG_HOME%\herdr-app` → `%USERPROFILE%\.config\herdr-app`)。空の値は無いものとして読む。
pub fn app_home(ctx: &Ctx) -> (PathBuf, &'static str) {
    let set = |name: &str| ctx.sys.env(name).filter(|v| !v.trim().is_empty());
    if let Some(h) = set("HERDR_APP_HOME") {
        return (PathBuf::from(h), "HERDR_APP_HOME");
    }
    if let Some(x) = set("XDG_CONFIG_HOME") {
        return (PathBuf::from(x).join("herdr-app"), "XDG_CONFIG_HOME の下");
    }
    (
        join_segments(&ctx.roots.user_profile, ".config/herdr-app"),
        "既定",
    )
}

/// repo の mod 1 つ。
#[derive(Debug, PartialEq, Eq)]
pub struct ModFiles {
    /// mod の名前 (ディレクトリの名前)
    pub name: String,
    /// 置くファイルの mod の中のパス (`/` 区切り。名前の順)
    pub files: Vec<String>,
    /// 置かないもの (ファイルでもディレクトリでもない) と、そのわけ
    pub odd: Vec<String>,
}

/// 配らない名前か (`.` で始まるもの・herdr-app が書くもの)。
fn skipped_name(name: &str) -> bool {
    name.starts_with('.') || APP_WRITES.contains(&name)
}

/// repo の mod を名前の順に並べる。`root` が無ければ空 (mod が 1 つも無い)。リンクはたどらない (mod にも、mod の中のディレクトリにも数えない)。
/// 名前が `.` で始まるディレクトリは mod に数えない。
pub fn list_mods(root: &Path) -> Result<Vec<ModFiles>, String> {
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("{} が読めない ({e})", root.display())),
    };
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with('.'))
        .collect();
    names.sort();
    names.iter().map(|name| list_mod(root, name)).collect()
}

/// `root\<name>\` の mod 1 つのファイルを並べる (配らない名前は除く。名前の順)。
pub fn list_mod(root: &Path, name: &str) -> Result<ModFiles, String> {
    let mut m = ModFiles {
        name: name.to_string(),
        files: Vec::new(),
        odd: Vec::new(),
    };
    walk(&root.join(name), "", &mut m)?;
    m.files.sort();
    m.odd.sort();
    Ok(m)
}

/// `dir` (mod の中の `prefix`) の中のファイルを `m` に足す。配らない名前 (`skipped_name`) は、ファイルもディレクトリも除く。
fn walk(dir: &Path, prefix: &str, m: &mut ModFiles) -> Result<(), String> {
    let entries =
        std::fs::read_dir(dir).map_err(|e| format!("{} が読めない ({e})", dir.display()))?;
    for e in entries.filter_map(|e| e.ok()) {
        let name = e.file_name().to_string_lossy().into_owned();
        if skipped_name(&name) {
            continue;
        }
        let rel = format!("{prefix}{name}");
        match e.file_type() {
            Ok(t) if t.is_dir() => walk(&e.path(), &format!("{rel}/"), m)?,
            Ok(t) if t.is_file() => m.files.push(rel),
            _ => m
                .odd
                .push(format!("{rel} (ファイルでもディレクトリでもない)")),
        }
    }
    Ok(())
}

/// `mods\` からの相対パスを比べる鍵 (要素ごと。Windows は大文字小文字を区別しない)。要素に分けるので、`/` と `\`・重なった区切りの違いは
/// 消える。
fn rel_key(rel: &Path) -> Vec<String> {
    rel.components()
        .map(|c| {
            let s = c.as_os_str().to_string_lossy();
            if cfg!(windows) {
                s.to_lowercase()
            } else {
                s.into_owned()
            }
        })
        .collect()
}

/// 記録にあるコピーのうち、今の home の `mods\` の下にあって、今は置かないもの (repo から消えたファイル・mod) を消す。中身が記録どおりで
/// なければ残して知らせる (記録からは外す)。今も置くファイルかは `mods\` からの相対パスの鍵で比べる (`keep`)。同じファイルを別の綴りで書いた
/// 鍵 (home を `/` で書いた・大文字小文字が違う) は消さず、apply では今の綴りの鍵が記録にあれば外す。置き先の mod のフォルダがリンクなら、その
/// 中は見ない。ほかの home の下の記録 (`HERDR_APP_HOME` を替えた前の home) と、`mods\` の外の記録 (herdr-app-pjp-spaces の layout) は、
/// そのまま残す。
pub fn prune(ctx: &mut Ctx, w: &mut Linker, mods_dir: &Path, keep: &Keep) {
    for key in w.records.keys() {
        let dest = PathBuf::from(&key);
        let Ok(rel) = dest.strip_prefix(mods_dir) else {
            continue;
        };
        if let Some(current) = keep.get(&rel_key(rel)) {
            if *current != key && w.mode.writes() && w.records.get(current).is_some() {
                w.records.remove(&key);
            }
            continue;
        }
        let Some(first) = rel.components().next() else {
            continue;
        };
        if is_link(&mods_dir.join(first)) {
            continue;
        }
        let parts: Vec<String> = rel
            .components()
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
            .collect();
        let shown = format!("mods/{}", parts.join("/"));
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
                    Mode::Check => ctx.say(format!("消す (apply で): {shown} (repo から消えた)")),
                    Mode::DryRun { .. } => ctx.say(format!("[dry-run] 消す: {shown}")),
                    Mode::Apply { .. } => {
                        if let Err(e) = std::fs::remove_file(&dest) {
                            w.fail(ctx, format!("{shown} を消せない ({e})"));
                            continue;
                        }
                        w.records.remove(&key);
                        ctx.say(format!("消しました: {shown} (repo から消えた)"));
                    }
                }
                w.tally.removed += 1;
            }
            Ok(_) => {
                w.skip(
                    ctx,
                    format!(
                        "{shown} (repo から消えたが、Windows 側で変わっているので消さない。要らなければ手で消す)"
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

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 記録つきのコピー: 無い → missing (check と dry-run は書かない)・apply で置いて記録する・同じ → ok。repo を変えると fix で上書きする
    //! - 手で置いた同じ中身は引き取る (check は ok、apply は記録だけ作る)。記録の無い違う中身・Windows 側で変えたものは衝突 (--force で上書き)
    //! - herdr-app が書くファイル (gpui-kit.d.ts・jsconfig.json) は、repo の作業ツリーにあっても (サブディレクトリの中も) 配らず、置き先のものにも
    //!   触らない。名前が . で始まるもの (mod のディレクトリも、mod の中も) は配らない。home のほかの場所 (pjp-hub-panel-media) にも触らない
    //! - repo から消えたファイルは、中身が記録どおりなら消す (変わっていれば残して知らせる)。置き先の mod のフォルダがリンクなら、その mod に触らない
    //! - 同じ home を別の綴り (Unix は重なった /、Windows は / と \) で書いても、今も置くファイルは消さない。apply は記録の鍵を今の綴りに寄せる
    //! - サブディレクトリの中のファイルも同じパスへ置く。mod の置き場が無ければ何もしない
    //! - home は HERDR_APP_HOME → XDG_CONFIG_HOME の下 → %USERPROFILE%\.config\herdr-app (空の値は無いものとして読む)
    //! - 本物の repo の mod (pjp-hub-panel) と .gitignore (herdr-app が書くファイルを入れない)
    //! - 本物の repo の mod が開く自作の mod (`openOverlay` の `mod: "pjp-…"`。prefix の小窓の d が開く pjp-worktree-remove) が repo の mod にある

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir, fake_mklink};

    const MAIN: &str = "// main\n";
    const MODJSON: &str = "{ \"place\": \"none\" }\n";
    const RING: &str = "<svg/>\n";

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            let t = TempDir::new("herdr-app-mods");
            t.write("dotfiles/win/herdr-app/mods/.gitignore", "jsconfig.json\n");
            t.write("dotfiles/win/herdr-app/mods/pjp-hub-panel/main.js", MAIN);
            t.write(
                "dotfiles/win/herdr-app/mods/pjp-hub-panel/mod.json",
                MODJSON,
            );
            t.write("dotfiles/win/herdr-app/mods/pjp-hub-panel/ring.svg", RING);
            Env { t }
        }

        /// 既定の home の下のパス
        fn home(&self, rel: &str) -> PathBuf {
            join_segments(
                &self.t.path().join("home"),
                &format!(".config/herdr-app/{rel}"),
            )
        }

        fn read(&self, rel: &str) -> String {
            std::fs::read_to_string(self.home(rel)).unwrap()
        }

        fn record(&self) -> serde_json::Map<String, serde_json::Value> {
            let text =
                std::fs::read_to_string(self.t.path().join("state").join(RECORD_FILE)).unwrap();
            match serde_json::from_str(&text).unwrap() {
                serde_json::Value::Object(m) => m,
                other => panic!("{other:?}"),
            }
        }

        fn run_with(&self, mode: Mode, sys: FakeSys) -> (Vec<Outcome>, String) {
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.t.path().join("home")),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys: &sys,
                    out: &mut out,
                };
                HerdrAppMods.run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        }

        fn run(&self, mode: Mode) -> (Vec<Outcome>, String) {
            self.run_with(mode, FakeSys::new(|_| unreachable!("コマンドは打たない")))
        }
    }

    fn kinds(o: &[Outcome]) -> Vec<Kind> {
        o.iter().map(|x| x.kind).collect()
    }

    const APPLY: Mode = Mode::Apply { force: false };

    #[test]
    fn places_and_records() {
        let e = Env::new();
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let (o, out) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Missing], "{mode:?} {o:?}\n{out}");
            assert!(!e.home("").exists(), "{mode:?} は書かない");
        }
        let (_, out) = e.run(Mode::Check);
        assert!(
            out.contains("コピーする (apply で): mods/pjp-hub-panel/main.js"),
            "{out}"
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].text
                .starts_with("追加 3 / 更新 0 / 削除 0 / 同じ 0 / 飛ばした 0"),
            "{o:?}"
        );
        assert_eq!(e.read("mods/pjp-hub-panel/main.js"), MAIN);
        assert_eq!(e.read("mods/pjp-hub-panel/mod.json"), MODJSON);
        assert_eq!(e.read("mods/pjp-hub-panel/ring.svg"), RING);
        assert!(
            !e.home("mods/.gitignore").exists(),
            "mods の直下のファイルは mod ではない"
        );
        let rec = e.record();
        assert_eq!(rec.len(), 3, "{rec:?}");
        assert_eq!(
            rec.get(&*e.home("mods/pjp-hub-panel/main.js").to_string_lossy())
                .and_then(|v| v.as_str()),
            Some(fsutil::sha256_bytes(MAIN.as_bytes()).as_str())
        );
        let (o, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(o[0].text.contains("同じ 3"), "{o:?}");
        // repo を変えると (記録どおりの置き先なので) 上書きする
        e.t.write(
            "dotfiles/win/herdr-app/mods/pjp-hub-panel/main.js",
            "// v2\n",
        );
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}");
        assert!(
            out.contains("上書きする (apply で): mods/pjp-hub-panel/main.js"),
            "{out}"
        );
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert_eq!(e.read("mods/pjp-hub-panel/main.js"), "// v2\n");
    }

    /// example-host の初めての apply: 手で置いた同じ 3 つと、herdr-app が書いた 2 つがある
    #[test]
    fn adopts_identical_hand_placed_files() {
        let e = Env::new();
        for (name, text) in [("main.js", MAIN), ("mod.json", MODJSON), ("ring.svg", RING)] {
            e.t.write(
                &format!("home/.config/herdr-app/mods/pjp-hub-panel/{name}"),
                text,
            );
        }
        e.t.write(
            "home/.config/herdr-app/mods/pjp-hub-panel/gpui-kit.d.ts",
            "declare module \"gpui-kit\";\n",
        );
        e.t.write(
            "home/.config/herdr-app/mods/pjp-hub-panel/jsconfig.json",
            "{}\n",
        );
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("同じ 3"), "{o:?}");
        assert!(!e.t.path().join("state").join(RECORD_FILE).exists());
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        // 置き先を書き換えない (herdr-app が mod を読み直さない)
        assert!(
            o[0].text
                .starts_with("追加 0 / 更新 0 / 削除 0 / 同じ 3 / 飛ばした 0"),
            "{o:?}"
        );
        assert_eq!(e.record().len(), 3, "記録だけを作る");
        assert_eq!(
            e.read("mods/pjp-hub-panel/gpui-kit.d.ts"),
            "declare module \"gpui-kit\";\n"
        );
        assert_eq!(e.read("mods/pjp-hub-panel/jsconfig.json"), "{}\n");
    }

    #[test]
    fn leaves_app_files_and_media_alone() {
        let e = Env::new();
        // 作業ツリーに写し戻した herdr-app のファイル (.gitignore で repo には入らない) は配らない
        e.t.write(
            "dotfiles/win/herdr-app/mods/pjp-hub-panel/gpui-kit.d.ts",
            "repo の写し\n",
        );
        e.t.write(
            "dotfiles/win/herdr-app/mods/pjp-hub-panel/jsconfig.json",
            "repo の写し\n",
        );
        // gpui-kit.d.ts は gpui-kit を import するディレクトリごとに書かれる (サブディレクトリの中も配らない)
        e.t.write(
            "dotfiles/win/herdr-app/mods/pjp-hub-panel/lib/util.js",
            "// u\n",
        );
        e.t.write(
            "dotfiles/win/herdr-app/mods/pjp-hub-panel/lib/gpui-kit.d.ts",
            "repo の写し\n",
        );
        e.t.write(
            "home/.config/herdr-app/mods/pjp-hub-panel/gpui-kit.d.ts",
            "app\n",
        );
        e.t.write(
            "home/.config/herdr-app/mods/pjp-hub-panel/lib/gpui-kit.d.ts",
            "app lib\n",
        );
        e.t.write(
            "home/.config/herdr-app/pjp-hub-panel-media/chat-1/x.svg",
            "<svg/>\n",
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.starts_with("追加 4 /"), "{o:?}");
        assert_eq!(e.read("mods/pjp-hub-panel/lib/util.js"), "// u\n");
        assert_eq!(e.read("mods/pjp-hub-panel/gpui-kit.d.ts"), "app\n");
        assert_eq!(e.read("mods/pjp-hub-panel/lib/gpui-kit.d.ts"), "app lib\n");
        assert!(!e.home("mods/pjp-hub-panel/jsconfig.json").exists());
        assert_eq!(e.read("pjp-hub-panel-media/chat-1/x.svg"), "<svg/>\n");
        assert!(
            e.record()
                .keys()
                .all(|k| !k.ends_with("gpui-kit.d.ts") && !k.ends_with("jsconfig.json")),
            "{:?}",
            e.record()
        );
        // mod を repo から消しても、herdr-app のファイルと図は残る
        std::fs::remove_dir_all(e.t.path().join("dotfiles/win/herdr-app/mods/pjp-hub-panel"))
            .unwrap();
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("削除 4"), "{o:?}");
        assert!(!e.home("mods/pjp-hub-panel/main.js").exists());
        assert_eq!(e.read("mods/pjp-hub-panel/gpui-kit.d.ts"), "app\n");
        assert_eq!(e.read("mods/pjp-hub-panel/lib/gpui-kit.d.ts"), "app lib\n");
        assert_eq!(e.read("pjp-hub-panel-media/chat-1/x.svg"), "<svg/>\n");
        assert!(e.record().is_empty());
    }

    #[test]
    fn skips_hidden_entries() {
        let e = Env::new();
        e.t.write("dotfiles/win/herdr-app/mods/.vscode/settings.json", "{}\n");
        e.t.write(
            "dotfiles/win/herdr-app/mods/pjp-hub-panel/.eslintrc",
            "{}\n",
        );
        e.t.write(
            "dotfiles/win/herdr-app/mods/pjp-hub-panel/.cache/x.js",
            "// x\n",
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.starts_with("追加 3 /"), "{o:?}");
        assert!(!e.home("mods/.vscode").exists());
        assert!(!e.home("mods/pjp-hub-panel/.eslintrc").exists());
        assert!(!e.home("mods/pjp-hub-panel/.cache").exists());
    }

    /// 同じ home を別の綴りで書いても (XDG_CONFIG_HOME・HERDR_APP_HOME を / で書いた Windows など)、今も置くファイルは消さない
    #[test]
    fn same_home_spelled_differently_keeps_files() {
        let e = Env::new();
        let custom = e.t.path().join("custom-home");
        let plain = custom.to_string_lossy().into_owned();
        let other = if cfg!(windows) {
            plain.replace('\\', "/")
        } else {
            plain.replacen("/custom-home", "//custom-home", 1)
        };
        assert_ne!(plain, other);
        let sys = |home: &str| FakeSys::new(|_| unreachable!()).with_env("HERDR_APP_HOME", home);
        let (o, _) = e.run_with(APPLY, sys(&plain));
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        let (o, out) = e.run_with(Mode::Check, sys(&other));
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("削除 0 / 同じ 3"), "{o:?}");
        assert!(!out.contains("消す"), "{out}");
        let (o, out) = e.run_with(APPLY, sys(&other));
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("削除 0 / 同じ 3"), "{o:?}");
        for f in ["main.js", "mod.json", "ring.svg"] {
            assert!(
                join_segments(&custom, &format!("mods/pjp-hub-panel/{f}")).is_file(),
                "{f} を消した"
            );
        }
        // 記録の鍵は今の綴りに寄る (前の綴りの鍵は外す)
        let rec = e.record();
        assert_eq!(rec.len(), 3, "{rec:?}");
        assert!(rec.keys().all(|k| k.starts_with(&other)), "{rec:?}");
        // 戻しても消さない
        let (o, out) = e.run_with(APPLY, sys(&plain));
        assert!(o[0].text.contains("削除 0 / 同じ 3"), "{o:?}\n{out}");
    }

    #[test]
    fn edited_files_conflict() {
        let e = Env::new();
        // 記録の無い違う中身
        e.t.write(
            "home/.config/herdr-app/mods/pjp-hub-panel/main.js",
            "// 手で直した\n",
        );
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes.iter().any(|n| n
                .starts_with("mods/pjp-hub-panel/main.js (中身が違う。置いた記録が無い")
                && n.contains("dotfiles の win/herdr-app/mods へ取り込む")
                && n.contains("--steps herdr-app-mods --force")),
            "{o:?}"
        );
        assert_eq!(e.read("mods/pjp-hub-panel/main.js"), "// 手で直した\n");
        let (o, _) = e.run(Mode::Apply { force: true });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert_eq!(e.read("mods/pjp-hub-panel/main.js"), MAIN);
        // 置いた後に Windows 側で変えたもの
        std::fs::write(e.home("mods/pjp-hub-panel/ring.svg"), "<svg>手</svg>\n").unwrap();
        let (o, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.contains("ring.svg (中身が違う。Windows 側で変わった")),
            "{o:?}"
        );
    }

    #[test]
    fn removes_files_gone_from_the_repo() {
        let e = Env::new();
        e.run(APPLY);
        std::fs::remove_file(
            e.t.path()
                .join("dotfiles/win/herdr-app/mods/pjp-hub-panel/ring.svg"),
        )
        .unwrap();
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}");
        assert!(
            out.contains("消す (apply で): mods/pjp-hub-panel/ring.svg (repo から消えた)"),
            "{out}"
        );
        assert!(e.home("mods/pjp-hub-panel/ring.svg").exists());
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(o[0].text.contains("削除 1"), "{o:?}");
        assert!(!e.home("mods/pjp-hub-panel/ring.svg").exists());
        assert_eq!(e.record().len(), 2);
        // 変えてあれば消さずに知らせ、記録から外す
        std::fs::write(e.home("mods/pjp-hub-panel/mod.json"), "{}\n").unwrap();
        std::fs::remove_file(
            e.t.path()
                .join("dotfiles/win/herdr-app/mods/pjp-hub-panel/mod.json"),
        )
        .unwrap();
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes.iter().any(|n| n.starts_with(
                "mods/pjp-hub-panel/mod.json (repo から消えたが、Windows 側で変わっているので消さない"
            )),
            "{o:?}"
        );
        assert_eq!(e.read("mods/pjp-hub-panel/mod.json"), "{}\n");
        assert_eq!(e.record().len(), 1);
    }

    #[test]
    fn linked_mod_folder_is_left_alone() {
        let e = Env::new();
        let elsewhere = e.t.path().join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        std::fs::create_dir_all(e.home("mods")).unwrap();
        let mk = FakeSys::new(|c| fake_mklink(c).unwrap());
        crate::link::create_junction(&mk, &e.home("mods/pjp-hub-panel"), &elsewhere).unwrap();
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}\n{out}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("mods/pjp-hub-panel (置き先がリンク")),
            "{o:?}"
        );
        assert_eq!(std::fs::read_dir(&elsewhere).unwrap().count(), 0);
        // 前に置いた記録があっても、リンクの中は消さない
        std::fs::write(elsewhere.join("old.js"), "x").unwrap();
        let key = e
            .home("mods/pjp-hub-panel/old.js")
            .to_string_lossy()
            .into_owned();
        let mut r = Records::load(&e.t.path().join("state").join(RECORD_FILE)).unwrap();
        r.set(&key, &fsutil::sha256_bytes(b"x"));
        r.save_if_changed().unwrap();
        e.run(APPLY);
        assert!(elsewhere.join("old.js").exists());
    }

    #[test]
    fn copies_nested_files_and_handles_no_mods() {
        let e = Env::new();
        e.t.write(
            "dotfiles/win/herdr-app/mods/pjp-hub-panel/icons/a.svg",
            "<svg>a</svg>\n",
        );
        e.t.write("dotfiles/win/herdr-app/mods/other/main.js", "// other\n");
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.starts_with("追加 5 /"), "{o:?}");
        assert_eq!(e.read("mods/pjp-hub-panel/icons/a.svg"), "<svg>a</svg>\n");
        assert_eq!(e.read("mods/other/main.js"), "// other\n");

        let e = Env::new();
        std::fs::remove_dir_all(e.t.path().join("dotfiles/win/herdr-app/mods")).unwrap();
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].text.starts_with("追加 0 / 更新 0 / 削除 0 / 同じ 0"),
            "{o:?}"
        );
    }

    #[test]
    fn home_follows_the_environment() {
        let e = Env::new();
        let custom = e.t.path().join("custom-home");
        let sys = FakeSys::new(|_| unreachable!())
            .with_env("HERDR_APP_HOME", &custom.to_string_lossy())
            .with_env("XDG_CONFIG_HOME", "/xdg");
        let (o, out) = e.run_with(APPLY, sys);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            out.contains(&format!(
                "herdr-app の home: {} (HERDR_APP_HOME)",
                custom.display()
            )),
            "{out}"
        );
        assert!(join_segments(&custom, "mods/pjp-hub-panel/main.js").is_file());
        assert!(!e.home("").exists());

        let xdg = e.t.path().join("xdg");
        let sys = FakeSys::new(|_| unreachable!())
            .with_env("HERDR_APP_HOME", " ")
            .with_env("XDG_CONFIG_HOME", &xdg.to_string_lossy());
        let (o, out) = e.run_with(APPLY, sys);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(out.contains("(XDG_CONFIG_HOME の下)"), "{out}");
        assert!(join_segments(&xdg, "herdr-app/mods/pjp-hub-panel/main.js").is_file());
        // 前の home (HERDR_APP_HOME) の記録とファイルは残す
        assert!(join_segments(&custom, "mods/pjp-hub-panel/main.js").is_file());
        assert_eq!(e.record().len(), 6);

        let (_, out) = e.run(Mode::Check);
        assert!(
            out.contains(&format!(
                "herdr-app の home: {} (既定)",
                e.home("").display()
            )),
            "{out}"
        );
    }

    /// 本物の repo の mod の置き場: pjp-hub-panel の 3 つのファイルを置く。.gitignore が herdr-app の書くファイルを入れない
    #[test]
    fn real_repo_mods() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let root = join_segments(&repo, MODS);
        let mods = list_mods(&root).unwrap();
        let hub = mods
            .iter()
            .find(|m| m.name == "pjp-hub-panel")
            .expect("pjp-hub-panel がある");
        for f in ["main.js", "mod.json", "ring.svg"] {
            assert!(hub.files.iter().any(|x| x == f), "{f} が無い: {hub:?}");
        }
        assert!(hub.odd.is_empty(), "{hub:?}");
        for m in &mods {
            let text = std::fs::read_to_string(root.join(&m.name).join("mod.json"))
                .unwrap_or_else(|e| panic!("{} の mod.json が読めない ({e})", m.name));
            let v = serde_json::from_str::<serde_json::Value>(&text);
            assert!(
                v.as_ref().is_ok_and(|v| v.is_object()),
                "{} の mod.json が JSON の object でない",
                m.name
            );
            // herdr-app は初めて見た mod を place に従って表示中の layout へ差し込むので、dotfiles の mod は layout・ほかの mod が置く所にだけ出す
            assert_eq!(
                v.ok().and_then(|v| v.get("place").cloned()),
                Some(serde_json::Value::from("none")),
                "{} の mod.json の place が none でない",
                m.name
            );
        }
        let ignore = std::fs::read_to_string(root.join(".gitignore"))
            .unwrap()
            .replace("\r\n", "\n");
        // どの深さにも当たる形 (gpui-kit.d.ts は gpui-kit を import するディレクトリごとに書かれる)
        for name in APP_WRITES {
            assert!(
                ignore.lines().any(|l| l == name),
                ".gitignore に {name} が無い"
            );
        }
    }

    /// 本物の repo の mod が `openOverlay({ mod: "pjp-…" })` で開く自作の mod が、repo の mod にある (開く側か開かれる側の名前だけを
    /// 替えると、herdr-app-mods が配らない mod を開こうとして何も出ない)。prefix の小窓の d は pjp-worktree-remove を開く
    #[test]
    fn real_repo_mods_open_mods_in_the_repo() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let root = join_segments(&repo, MODS);
        let mods = list_mods(&root).unwrap();
        let names: Vec<&str> = mods.iter().map(|m| m.name.as_str()).collect();
        let head = "mod: \"";
        let mut opened = Vec::new();
        for m in &mods {
            let main = std::fs::read_to_string(root.join(&m.name).join("main.js"))
                .unwrap_or_else(|e| panic!("{} の main.js が読めない ({e})", m.name));
            for (at, _) in main.match_indices("mod: \"pjp-") {
                let rest = &main[at + head.len()..];
                let name = &rest[..rest.find('"').expect("閉じる \" がある")];
                assert!(
                    names.contains(&name),
                    "{} の main.js が開く mod {name} が {MODS} に無い",
                    m.name
                );
                opened.push((m.name.clone(), name.to_string()));
            }
        }
        assert!(
            opened
                .iter()
                .any(|(from, to)| from == "pjp-prefix" && to == "pjp-worktree-remove"),
            "{opened:?}"
        );
    }

    #[test]
    fn step_info() {
        let i = HerdrAppMods.info();
        assert_eq!(
            (i.id, i.order, i.gate),
            ("herdr-app-mods", 98, Gate::Tool("windowsHerdr"))
        );
        assert!(i.ported && i.windows_only);
    }
}
