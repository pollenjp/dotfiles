//! `pjp hub bake`: panel (herdr-app の mod `pjp-hub-panel`) に載せた図 (panel.json の image の節) の marks を、SVG の中の
//! CSS の動き (`@keyframes`) に焼き込んだ写しを作る。ハブの会話が、panel に載せた図を panel の外 (足し分があれば会話のチケット
//! (Notion) など) にも上げる・見せるときに使う。panel の SVG には動きが無く (marks は panel.json の節にあり、mod が図の上に重ねて
//! 描く)、SVG をそのまま上げると図から動きが落ちる。
//!
//! 写しは `--out` のディレクトリに、panel の図と同じ名前で書く。panel に載せた SVG は書き換えず、写しは panel に載せない
//! (panel の image は SVG の中の動きを描かない)。標準出力には、節ごとに書いた写しのパス・焼いた marks の数・チケットの図の
//! キャプション (載せた日時の入った 1 行) を出す。private な足し分 (claude-skills の `pjp-skills`) があるときだけ、写しの
//! Windows のパスを WSL から見たパス (`wsl:` の行。WSL のハブの `ticket.sh figure` に渡す) も添える。ミニ絵 (markdown の節と Q&A の答えの絵の行 `![説明](<パス>)`) は marks を
//! 持たないので、図のパスを渡すと焼かずに写し、付けた項目の見出しと説明からキャプションを作る。
//!
//! marks の形と既定値は mod (dotfiles の `win/herdr-app/mods/pjp-hub-panel/main.js` の `mark()`) に合わせる:
//! - flow: x1,y1 → x2,y2 の向きに speed px/s (既定 40) で流れる点。点は半径 4 で、間は 2π·292/45 px (mod の ring.svg の、
//!   半径 292 の円に並べた 45 個の点)。線の外接矩形 (線と直角の向きにだけ 5 px 広げる) で切り抜き、点は mod と同じく線の端で
//!   切れる。mod の点は半径 292 の弧を走るが、写しでは線の上をまっすぐ走る (長い線でも欠けない)
//! - pulse: x,y,w,h の矩形の内側の 2 px の枠 (角の丸みは radius。既定 8)。opacity が 0.15 と 1 の間を period ms (既定 1600)
//!   で 1 往復する
//! - dot: x1,y1 と x2,y2 を行き来する点 (直径 size。既定 9)。period ms (既定 2200) で 1 往復する
//! - label: x,y を字の左上にした字 (size は既定 12 で、9 より小さくしない)。焼いた時点の字を SVG の text にする (動かない)
//!
//! mod の `loop` (pulse・dot) の period が 1 往復か片道かは mod の文書に無いので、1 往復とみた。動きを減らす設定
//! (`prefers-reduced-motion: reduce`) では動きを止め、点と枠を素の位置 (flow は線のまん中に点が 1 つ来る並び・pulse は濃い
//! 枠・dot は x1,y1) に出す。動きを描かない道具 (resvg など) も素の位置を描く。SMIL でなく CSS で焼くのは、pjp-diagram-motion の README の動く SVG (`references/readme-svg.md`) と同じわけ
//! (動きを減らす設定で止められる・時刻を止めてコマを撮れる)。Notion に上げた写しが img で動くことは、Chrome で確かめた。

use std::collections::HashSet;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use pjp_core::exit;
use pjp_core::time::JstDateTime;
use pjp_core::{Error, Result};
use serde_json::{Map, Value};

/// panel の図の置き場所 (herdr-app の home の下。mod の `MEDIA`)。
pub const MEDIA: &str = "pjp-hub-panel-media";
/// 焼いた marks を入れる g の id。これがある SVG は焼いた写しなので、もう焼かない。
pub const GROUP_ID: &str = "pjp-marks";
/// flow の点の半径 (mod の ring.svg の点の r)。
const DOT_RADIUS: f64 = 4.0;
/// flow の切り抜きを、線と直角の向きに広げる幅 (mod の `pad` = 点の半径 + 1)。
const CLIP_PAD: f64 = 5.0;
/// mod の ring.svg の、点を並べた円の半径と点の数。
const RING_RADIUS: f64 = 292.0;
const RING_DOTS: f64 = 45.0;
/// label の字体 (panel の図の雛形と同じ。`references/panel-figures.md` の「大きさと字」)。
const LABEL_FONT: &str = "'Yu Gothic UI', 'Meiryo UI', Meiryo, 'Segoe UI', sans-serif";
/// theme の名前で書かれた color を置き換える色 (`references/panel-figures.md` の「色」の暗い theme の色)。
const THEME: &[(&str, &str)] = &[
    ("accent", "#61afef"),
    ("ok", "#98c379"),
    ("warn", "#e5c07b"),
    ("blocked", "#e06c75"),
    ("fg", "#d7dae0"),
    ("muted", "#9aa2ae"),
    ("dim", "#7f8794"),
    ("border", "#5c6370"),
];

/// `pjp hub bake` の引数。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Options {
    /// panel.json のパス。
    pub panel: PathBuf,
    /// 写すもの (1 つ以上): 焼く image の節の id (panel.json の sections の id) か、`.svg` で終わる図のパス (image の節の src。
    /// ミニ絵の行の図のパスなら、焼かずに写す)。
    pub ids: Vec<String>,
    /// 写しを書くディレクトリ (scratchpad の、panel のフォルダの外)。
    pub out: PathBuf,
    /// herdr-app の home。省くと [`herdr_app_home`]。
    pub home: Option<PathBuf>,
    /// 写しの WSL から見たパス (`wsl:` の行) を添えるか (private な足し分があるときだけ。cli が [`pjp_core::extras`] で決める)。
    pub wsl: bool,
}

/// herdr-app の home: `HERDR_APP_HOME` → `<XDG_CONFIG_HOME>/herdr-app` → `~/.config/herdr-app` (`references/panel.md` の
/// 「置き場所」の 1 行と同じ順)。
pub fn herdr_app_home() -> Result<PathBuf> {
    if let Some(v) = std::env::var_os("HERDR_APP_HOME").filter(|v| !v.is_empty()) {
        return Ok(PathBuf::from(v));
    }
    Ok(pjp_core::paths::xdg_config_home()?.join("herdr-app"))
}

/// 焼いた結果。
#[derive(Debug, Clone, PartialEq)]
pub struct Baked {
    /// 書く SVG の中身。焼く mark が 1 つも無ければ、元の中身のまま。
    pub svg: String,
    /// 節の marks の数 (焼けなかったものも)。
    pub tried: usize,
    /// 焼いた mark の種類ごとの数 (出てきた順)。
    pub counts: Vec<(&'static str, usize)>,
    /// 直すべき合図 (焼けなかった mark・theme の名前で書いた色・節と SVG の大きさの違い)。報告の `!!` の行。panel の図でも
    /// ずれている。
    pub warnings: Vec<String>,
    /// 知らせ (label を焼いた時点の字)。報告の `note:` の行。直すものは無い。
    pub notes: Vec<String>,
}

impl Baked {
    /// 標準出力に出す、焼いたものの 1 句。
    pub fn summary(&self) -> String {
        if self.counts.is_empty() {
            return if self.tried == 0 {
                "marks なし。SVG をそのまま写した".to_owned()
            } else {
                "marks を 1 つも焼けなかった (!! の行)。SVG をそのまま写した".to_owned()
            };
        }
        let parts: Vec<String> = self
            .counts
            .iter()
            .map(|(k, n)| format!("{k} {n}"))
            .collect();
        format!("{} を焼いた", parts.join("・"))
    }
}

/// `pjp hub bake` を打つ。節ごとに写しを書いて報告を出し、焼けなかった節があれば終了コード 1。
pub fn run(opts: &Options) -> Result<u8> {
    let panel_text = read_text(&opts.panel)?;
    let panel: Value = serde_json::from_str(&panel_text).map_err(|e| {
        Error::failure(format!(
            "{} を JSON として読めません: {e}",
            opts.panel.display()
        ))
    })?;
    let sections = panel
        .get("sections")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            Error::failure(format!(
                "{} に sections の配列がありません",
                opts.panel.display()
            ))
        })?;
    let home = match &opts.home {
        Some(h) => h.clone(),
        None => herdr_app_home()?,
    };
    let out_dir = std::path::absolute(&opts.out)
        .map_err(|e| Error::io(format!("{} を絶対パスにできません", opts.out.display()), &e))?;
    check_out_dir(&out_dir, &opts.panel, &home)?;
    let now = pjp_core::time::now()?.to_jst();

    let mut failed = false;
    let mut names = HashSet::new();
    let to = Target {
        home: &home,
        out_dir: &out_dir,
        now: &now,
        wsl: opts.wsl,
    };
    for id in &opts.ids {
        match bake_target(id, sections, &to, &mut names) {
            Ok(report) => print!("{report}"),
            Err(message) => {
                eprintln!("pjp hub bake: {id}: {message}");
                failed = true;
            }
        }
    }
    Ok(if failed { exit::FAILURE } else { exit::OK })
}

/// 写しの読み書きの場所と、キャプションの日時。
struct Target<'a> {
    home: &'a Path,
    out_dir: &'a Path,
    now: &'a JstDateTime,
    /// `wsl:` の行を添えるか ([`Options::wsl`])。
    wsl: bool,
}

fn read_text(path: &Path) -> Result<String> {
    let bytes = std::fs::read(path)
        .map_err(|e| Error::io(format!("{} を読めません", path.display()), &e))?;
    Ok(pjp_core::text::decode_text(&bytes))
}

/// 写しを書かない所: panel.json のフォルダ (panel はそのフォルダを見張り、何か変わると読み直す) と、herdr-app の home の中
/// (図のフォルダの同じ名前は panel の図そのもの。mod のフォルダは書き換えると mod ごと読み直す)。
fn check_out_dir(out_dir: &Path, panel: &Path, home: &Path) -> Result<()> {
    let out = resolved(out_dir);
    let panel_dir = std::path::absolute(panel)
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf));
    if let Some(dir) = panel_dir
        && pjp_core::paths::same_path_here(&out, &resolved(&dir))
    {
        return Err(Error::config(format!(
            "--out の {} は panel.json のフォルダです (panel が読み直す)。scratchpad の別のフォルダ (例 <scratchpad>\\ticket-fig) を渡す",
            out_dir.display()
        )));
    }
    if inside(&out, &resolved(home)) {
        return Err(Error::config(format!(
            "--out の {} は herdr-app の home ({}) の中です (panel の図を上書きしうる・mod が読み直す)。scratchpad のフォルダ (例 <scratchpad>\\ticket-fig) を渡す",
            out_dir.display(),
            home.display()
        )));
    }
    Ok(())
}

/// symlink を解いたパス。無いパスは、あるところまで解いて残りを足す (まだ無い --out も、解いた home と比べられるように)。
fn resolved(path: &Path) -> PathBuf {
    let abs = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    let mut rest: Vec<std::ffi::OsString> = Vec::new();
    let mut cur = abs.as_path();
    loop {
        if let Ok(real) = pjp_core::paths::real_path(cur) {
            return rest.iter().rev().fold(real, |p, c| p.join(c));
        }
        match (cur.parent(), cur.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name.to_os_string());
                cur = parent;
            }
            _ => return abs,
        }
    }
}

/// `child` が `parent` と同じか、その下か (このマシンの決まりで比べる。Windows は大文字小文字と `\`・`/` を見ない)。
fn inside(child: &Path, parent: &Path) -> bool {
    let windows = cfg!(windows);
    let c = pjp_core::paths::normalize_for_compare(&child.to_string_lossy(), windows);
    let p = pjp_core::paths::normalize_for_compare(&parent.to_string_lossy(), windows);
    !p.is_empty() && (c == p || c.starts_with(&format!("{p}/")))
}

/// 引数 1 つを写しにし、報告の文を返す。写せなければ、そのわけ。引数は image の節の id か、`.svg` で終わる図のパス
/// (image の節の src なら、その節を焼く。ほかは markdown の節・Q&A の答えのミニ絵の行 `![説明](<パス>)` の図を、焼かずに写す)。
fn bake_target(
    arg: &str,
    sections: &[Value],
    to: &Target<'_>,
    names: &mut HashSet<String>,
) -> std::result::Result<String, String> {
    let image = |s: &&Value| s.get("type").and_then(Value::as_str) == Some("image");
    if arg.ends_with(".svg") {
        let by_src = sections
            .iter()
            .filter(image)
            .find(|s| s.get("src").and_then(Value::as_str).map(str::trim) == Some(arg));
        if let Some(section) = by_src {
            return bake_image(arg, section, to, names);
        }
        let (heading, alt) = find_mini(sections, arg).ok_or(
            "panel.json に、この図の image の節 (src) もミニ絵の行 (![説明](<パス>)) もありません",
        )?;
        let source = media_path(to.home, arg)?;
        let svg = read_figure(&source)?;
        let out = write_copy(arg, &source, &svg, to.out_dir, names)?;
        let mut report = String::new();
        let _ = writeln!(
            report,
            "{arg}: {} に写した (ミニ絵。marks は無いので、そのまま)",
            out.display()
        );
        let _ = writeln!(
            report,
            "  caption: {}",
            mini_caption(heading.as_deref(), &alt, to.now)
        );
        if to.wsl {
            push_wsl(&mut report, &out);
        }
        return Ok(report);
    }
    let section = sections
        .iter()
        .find(|s| s.get("id").and_then(Value::as_str) == Some(arg))
        .ok_or("panel.json の sections に、この id の節がありません")?;
    if !image(&section) {
        let kind = section.get("type").and_then(Value::as_str).unwrap_or("");
        return Err(format!(
            "image の節ではありません (type {kind:?})。ミニ絵は、絵の行の図のパス (<会話のチケット>/mini-<名前>.svg) を渡す"
        ));
    }
    bake_image(arg, section, to, names)
}

/// image の節の図を焼いて写しを書き、報告の文を返す。
fn bake_image(
    label: &str,
    section: &Value,
    to: &Target<'_>,
    names: &mut HashSet<String>,
) -> std::result::Result<String, String> {
    let src = section
        .get("src")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let source = media_path(to.home, src)?;
    let svg = read_figure(&source)?;
    let baked = bake(&svg, section)?;
    let out = write_copy(src, &source, &baked.svg, to.out_dir, names)?;
    let mut report = String::new();
    let _ = writeln!(
        report,
        "{label}: {} に書いた ({})",
        out.display(),
        baked.summary()
    );
    let _ = writeln!(report, "  caption: {}", caption(section, src, to.now));
    if to.wsl {
        push_wsl(&mut report, &out);
    }
    for n in &baked.notes {
        let _ = writeln!(report, "  note: {n}");
    }
    for w in &baked.warnings {
        let _ = writeln!(report, "  !! {w}");
    }
    Ok(report)
}

fn read_figure(source: &Path) -> std::result::Result<String, String> {
    let bytes =
        std::fs::read(source).map_err(|e| format!("図 {} を読めません: {e}", source.display()))?;
    Ok(pjp_core::text::decode_text(&bytes))
}

/// 写しを `out_dir` に、図と同じ名前で書く。書いたパスを返す。panel の図そのものと、1 回の中で同じ名前の 2 つめは書かない。
fn write_copy(
    src: &str,
    source: &Path,
    text: &str,
    out_dir: &Path,
    names: &mut HashSet<String>,
) -> std::result::Result<PathBuf, String> {
    let name = file_name(src).ok_or_else(|| format!("src {src:?} にファイルの名前がありません"))?;
    if !names.insert(name.clone()) {
        return Err(format!(
            "同じ名前の図 {name} を 1 回で 2 つ書けません (打ち分ける)"
        ));
    }
    let out = out_dir.join(&name);
    if let (Ok(a), Ok(b)) = (
        pjp_core::paths::real_path(&out),
        pjp_core::paths::real_path(source),
    ) && pjp_core::paths::same_path_here(&a, &b)
    {
        return Err(format!(
            "写しの {} が panel の図そのものです (上書きしない)。--out に scratchpad のフォルダを渡す",
            out.display()
        ));
    }
    pjp_core::text::write_atomic(&out, text).map_err(|e| e.to_string())?;
    Ok(out)
}

fn push_wsl(report: &mut String, out: &Path) {
    if let Some(wsl) = wsl_path(&out.to_string_lossy()) {
        let _ = writeln!(report, "  wsl: {wsl}");
    }
}

/// markdown の節の text と Q&A の答え (items の a) から、図が `path` のミニ絵の行を探し、(付けた項目の見出しの字, 説明) を返す。
/// 見出しは、その行より上で一番近い、字下げの無い太字の見出しの項目 (`- **見出し**`。字下げした詳細の太字は見出しにしない)。
/// 無ければ None。絵の行とコードの囲みの見分け方は mod (`MINI_LINE`・`FENCE`) と同じ。
pub fn find_mini(sections: &[Value], path: &str) -> Option<(Option<String>, String)> {
    let mut texts: Vec<&str> = Vec::new();
    for s in sections {
        match s.get("type").and_then(Value::as_str) {
            Some("markdown") => texts.extend(s.get("text").and_then(Value::as_str)),
            Some("qa") => {
                for it in s
                    .get("items")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    texts.extend(it.get("a").and_then(Value::as_str));
                }
            }
            _ => {}
        }
    }
    for text in texts {
        let mut heading: Option<String> = None;
        let mut fence: Option<(char, usize)> = None;
        for line in text.lines() {
            let f = fence_marker(line);
            if let Some((ch, len)) = fence {
                // 閉じるのは、同じ字で同じ長さ以上の囲み
                if f.is_some_and(|(c, n)| c == ch && n >= len) {
                    fence = None;
                }
                continue;
            }
            if f.is_some() {
                fence = f;
                continue;
            }
            if let Some(h) = heading_item(line) {
                heading = Some(h);
                continue;
            }
            if let Some((alt, p)) = picture_line(line)
                && p == path
            {
                return Some((heading, alt.to_owned()));
            }
        }
    }
    None
}

/// コードの囲みの行 (前の空白 3 つまでの、3 つ以上の ``` か ~~~。mod の `FENCE`) の (字, 長さ)。
fn fence_marker(line: &str) -> Option<(char, usize)> {
    let rest = line.trim_start_matches(' ');
    if line.len() - rest.len() > 3 {
        return None;
    }
    let ch = rest.chars().next().filter(|c| *c == '`' || *c == '~')?;
    let n = rest.chars().take_while(|c| *c == ch).count();
    (n >= 3).then_some((ch, n))
}

/// 字下げの無い、太字の見出しの項目 (`- **見出し**`。記号は `-`・`*`・`+`) の見出しの字 (`**` を除く)。
fn heading_item(line: &str) -> Option<String> {
    let rest = line.strip_prefix(['-', '*', '+'])?.strip_prefix(' ')?;
    let (h, _) = rest
        .trim_start_matches(' ')
        .strip_prefix("**")?
        .split_once("**")?;
    let h = h.trim();
    (!h.is_empty()).then(|| h.to_owned())
}

/// 絵だけの行 `![説明](パス)` の (説明, パス)。mod の `MINI_LINE` と同じく、前後は空白とタブだけ、説明に `]` を、パスに空白と
/// 括弧を含めない (説明は空でもよい)。
fn picture_line(line: &str) -> Option<(&str, &str)> {
    let t = line.trim_matches([' ', '\t']);
    let rest = t.strip_prefix("![")?;
    let (alt, rest) = rest.split_once(']')?;
    let path = rest.strip_prefix('(')?.strip_suffix(')')?;
    let ok = !path.contains(|c: char| c.is_whitespace() || c == ')' || c == '(');
    ok.then_some((alt, path))
}

/// ミニ絵のキャプション: `<YYYY/MM/DD hh:mm> の panel のミニ絵: <付けた項目の見出し> — <説明>` (見出しが無ければ説明だけ)。
pub fn mini_caption(heading: Option<&str>, alt: &str, now: &JstDateTime) -> String {
    let alt = alt.trim();
    let body = match heading.map(str::trim).filter(|h| !h.is_empty()) {
        Some(h) if !alt.is_empty() => format!("{h} — {alt}"),
        Some(h) => h.to_owned(),
        None => alt.to_owned(),
    };
    format!("{} の panel のミニ絵: {}", stamp(now), quote_safe(&body))
}

/// キャプションの頭の日時 (`YYYY/MM/DD hh:mm`。日本時間)。
fn stamp(now: &JstDateTime) -> String {
    format!(
        "{:04}/{:02}/{:02} {:02}:{:02}",
        now.year, now.month, now.day, now.hour, now.minute
    )
}

/// 節の src (panel.json の。`pjp-hub-panel-media/` からの相対パス。`mods/` で始まれば home から) を、図のパスにする
/// (mod の `imagePath` と同じ)。絶対パス・`..`・URL は決まりの外として断る。
pub fn media_path(home: &Path, src: &str) -> std::result::Result<PathBuf, String> {
    if src.is_empty() {
        return Err("src が空です".to_owned());
    }
    let parts: Vec<&str> = src.split(['/', '\\']).filter(|p| !p.is_empty()).collect();
    let absolute = src.starts_with(['/', '\\']) || src.as_bytes().get(1) == Some(&b':');
    if absolute || src.contains("://") || parts.contains(&"..") {
        return Err(format!(
            "src {src:?} は {MEDIA}/ からの相対パスにする (絶対パス・..・URL は panel の決まりの外)"
        ));
    }
    let base = if src.starts_with("mods/") {
        home.to_path_buf()
    } else {
        home.join(MEDIA)
    };
    Ok(parts.iter().fold(base, |p, c| p.join(c)))
}

fn file_name(src: &str) -> Option<String> {
    src.rsplit(['/', '\\'])
        .next()
        .filter(|n| !n.is_empty())
        .map(str::to_owned)
}

/// チケットの図のキャプション: `<YYYY/MM/DD hh:mm> の panel の図: <title> — <caption>` (日時は日本時間。題が無ければ図の名前)。
/// WSL のハブで打つ `bash -lc '… --caption "…"'` と PowerShell の一重引用符の中にそのまま書けるよう、引用符・`` ` ``・`$`・`\` を
/// 置き換える ([`quote_safe`])。
pub fn caption(section: &Value, src: &str, now: &JstDateTime) -> String {
    let text = |k: &str| {
        section
            .get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_owned()
    };
    let title = text("title");
    let note = text("caption");
    let name = if title.is_empty() {
        let n = file_name(src).unwrap_or_default();
        n.strip_suffix(".svg").map(str::to_owned).unwrap_or(n)
    } else {
        title
    };
    let body = if note.is_empty() {
        name
    } else {
        format!("{name} — {note}")
    };
    format!("{} の panel の図: {}", stamp(now), quote_safe(&body))
}

/// 引用符の中に書けない字を置き換える: 一重引用符 (`'` と、PowerShell が一重引用符として読む `‘` `’` `‚` `‛`) → `＇`、
/// 二重引用符 (`"` と、PowerShell が二重引用符として読む `“` `”` `„`) → `＂`、`$` → `＄`、`\` → `＼`、`` ` `` は外す (Notion の
/// inline code は諦める)、改行とタブは空白にする。PowerShell 7.6 で、`'x’y'` と `"x”y"` が文字列の終わりを見失って読めず、
/// `＇`・`＂` は字のまま通ると確かめた。
pub fn quote_safe(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\'' | '\u{2018}' | '\u{2019}' | '\u{201a}' | '\u{201b}' => out.push('＇'),
            '"' | '\u{201c}' | '\u{201d}' | '\u{201e}' => out.push('＂'),
            '$' => out.push('＄'),
            '\\' => out.push('＼'),
            '`' => {}
            '\n' | '\r' | '\t' => out.push(' '),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

/// Windows のドライブのパス (`C:\…`) を、同じ PC の WSL から見たパス (`/mnt/c/…`) にする。ほかの形なら None。
/// 足し分の道具 (`pjp ticket figure`) が Windows で動くまで、WSL のハブの `ticket.sh figure` に写しを渡すのに使う (報告の `wsl:` の
/// 行は、足し分があるときだけ出す)。figure が Windows で動くようになったら、この関数と報告の `wsl:` の行は消す。
pub fn wsl_path(path: &str) -> Option<String> {
    let p = path.strip_prefix(r"\\?\").unwrap_or(path);
    let b = p.as_bytes();
    if b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/')
    {
        let drive = char::from(b[0]).to_ascii_lowercase();
        return Some(format!("/mnt/{drive}/{}", p[3..].replace('\\', "/")));
    }
    None
}

/// SVG の中身と panel.json の image の節から、marks を焼いた SVG を作る (ファイルには触らない)。
pub fn bake(svg: &str, section: &Value) -> std::result::Result<Baked, String> {
    if svg.contains(&format!("id=\"{GROUP_ID}\"")) {
        return Err(format!(
            "もう焼いてある SVG です (g#{GROUP_ID} がある)。panel に載せた SVG を渡す"
        ));
    }
    let root = svg_root(svg).ok_or("SVG の <svg> の始まりがありません")?;
    let close = svg
        .rfind("</svg")
        .filter(|&i| svg[i + "</svg".len()..].trim_start().starts_with('>'))
        .ok_or("SVG の </svg> がありません")?;
    let width = size_or(section.get("width"), 520.0);
    let height = size_or(section.get("height"), 300.0);
    let mut warnings = Vec::new();
    let mut notes = Vec::new();
    let transform = frame(&root, width, height, &mut warnings);
    let marks: &[Value] = match section.get("marks") {
        None | Some(Value::Null) => &[],
        Some(Value::Array(a)) => a,
        Some(_) => {
            warnings.push("marks が配列ではないので焼かない".to_owned());
            &[]
        }
    };

    let mut parts = Parts::default();
    let mut counts: Vec<(&'static str, usize)> = Vec::new();
    for (i, m) in marks.iter().enumerate() {
        match mark(i, m, &mut parts) {
            Ok((kind, warns, infos)) => {
                match counts.iter_mut().find(|(k, _)| *k == kind) {
                    Some((_, n)) => *n += 1,
                    None => counts.push((kind, 1)),
                }
                warnings.extend(
                    warns
                        .into_iter()
                        .map(|w| format!("marks[{i}] ({kind}): {w}")),
                );
                notes.extend(infos.into_iter().map(|n| format!("marks[{i}]: {n}")));
            }
            Err(why) => warnings.push(format!("marks[{i}]: {why}")),
        }
    }
    if counts.is_empty() {
        return Ok(Baked {
            svg: svg.to_owned(),
            tried: marks.len(),
            counts,
            warnings,
            notes,
        });
    }

    let head = &svg[..close];
    let mut text = String::with_capacity(svg.len() + parts.len() + 512);
    text.push_str(head);
    if !head.ends_with('\n') {
        text.push('\n');
    }
    text.push_str(&parts.assemble(transform.as_deref()));
    text.push_str(&svg[close..]);
    Ok(Baked {
        svg: text,
        tried: marks.len(),
        counts,
        warnings,
        notes,
    })
}

/// 焼いた marks の部品 (CSS・切り抜き・図形)。
#[derive(Default)]
struct Parts {
    style: Vec<String>,
    defs: Vec<String>,
    body: Vec<String>,
}

impl Parts {
    fn len(&self) -> usize {
        [&self.style, &self.defs, &self.body]
            .iter()
            .flat_map(|v| v.iter())
            .map(String::len)
            .sum()
    }

    /// `</svg>` の前に入れる g。
    fn assemble(&self, transform: Option<&str>) -> String {
        let mut s = String::new();
        let attr = transform.map_or(String::new(), |t| format!(" transform=\"{t}\""));
        let _ = writeln!(s, "  <g id=\"{GROUP_ID}\"{attr}>");
        let _ = writeln!(
            s,
            "    <!-- pjp hub bake: panel.json の節の marks を CSS の動きに焼いた写し (チケットに上げる。panel には載せない) -->"
        );
        if !self.style.is_empty() {
            s.push_str("    <style>\n");
            for line in &self.style {
                let _ = writeln!(s, "      {line}");
            }
            s.push_str(
                "      @media (prefers-reduced-motion: reduce) { .pjp-mk { animation: none !important } }\n",
            );
            s.push_str("    </style>\n");
        }
        if !self.defs.is_empty() {
            s.push_str("    <defs>\n");
            for line in &self.defs {
                let _ = writeln!(s, "      {line}");
            }
            s.push_str("    </defs>\n");
        }
        for line in &self.body {
            let _ = writeln!(s, "    {line}");
        }
        s.push_str("  </g>\n");
        s
    }
}

/// 1 つの mark を焼いたもの: 種類・直すべき合図 (`!!`)・知らせ (`note:`)。
type Marked = (&'static str, Vec<String>, Vec<String>);

/// 1 つの mark を焼く。焼かないなら、そのわけ。
///
/// 見た目の値 (塗り・線・字体) は、属性でなく要素の `style` に書く。元の SVG の `<style>` の要素の規則 (`line { stroke-width: 2 }`
/// など) は属性より強く、属性で書くと焼いた marks の見た目を上書きする (要素の style は規則より強い)。動き (`animation`) は
/// `<style>` の class の規則に書き、keyframes の値は要素の style より強い (動きを減らす設定では style の素の値に戻る)。
fn mark(i: usize, m: &Value, parts: &mut Parts) -> std::result::Result<Marked, String> {
    let o = m.as_object().ok_or("オブジェクトではないので焼かない")?;
    let kind = o.get("kind").and_then(Value::as_str).unwrap_or("");
    let class = format!("pjp-mk-{i}");
    let mut warns = Vec::new();
    let mut notes = Vec::new();
    match kind {
        "flow" => {
            let [x1, y1, x2, y2] = coords(o, ["x1", "y1", "x2", "y2"])?;
            let len = (x2 - x1).hypot(y2 - y1);
            if len < 1e-9 {
                return Err("長さ 0 の flow は焼かない".to_owned());
            }
            let speed = positive(o, "speed", 40.0, &mut warns);
            let color = color_of(o, "#61afef", &mut warns);
            let gap = 2.0 * std::f64::consts::PI * RING_RADIUS / RING_DOTS;
            // 素の位置 (動きを減らす設定・静止画にする道具) で、点の 1 つが線のまん中に来る位相。点は dashoffset を d とした
            // とき、線の始めから p (p + d が gap の倍数) の所に出る。d を gap だけ減らすと、点が線の向きに 1 間進む
            let phase = (gap - (len / 2.0) % gap) % gap;
            let (ux, uy) = ((x2 - x1) / len, (y2 - y1) / len);
            let (pad_x, pad_y) = (CLIP_PAD * uy.abs(), CLIP_PAD * ux.abs());
            parts.style.push(format!(
                "@keyframes {class} {{ 0% {{ stroke-dashoffset: {}px }} 100% {{ stroke-dashoffset: {}px }} }}",
                num(phase + gap),
                num(phase)
            ));
            parts.style.push(format!(
                ".{class} {{ animation: {class} {}s linear infinite }}",
                num(gap / speed)
            ));
            parts.defs.push(format!(
                "<clipPath id=\"{class}-clip\"><rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\"/></clipPath>",
                num(x1.min(x2) - pad_x),
                num(y1.min(y2) - pad_y),
                num((x2 - x1).abs() + 2.0 * pad_x),
                num((y2 - y1).abs() + 2.0 * pad_y)
            ));
            parts.body.push(format!(
                "<line class=\"pjp-mk {class}\" x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\" style=\"fill: none; stroke: {color}; stroke-width: {}px; stroke-linecap: round; stroke-dasharray: 0 {}px; stroke-dashoffset: {}px; clip-path: url(#{class}-clip); opacity: 1\"/>",
                num(x1),
                num(y1),
                num(x2),
                num(y2),
                num(2.0 * DOT_RADIUS),
                num(gap),
                num(phase)
            ));
            Ok(("flow", warns, notes))
        }
        "pulse" => {
            let [x, y, w, h] = coords(o, ["x", "y", "w", "h"])?;
            if w <= 2.0 || h <= 2.0 {
                return Err(format!(
                    "幅 {}・高さ {} の pulse は小さすぎるので焼かない",
                    num(w),
                    num(h)
                ));
            }
            let radius = non_negative(o, "radius", 8.0, &mut warns);
            let period = positive(o, "period", 1600.0, &mut warns);
            let color = color_of(o, "#61afef", &mut warns);
            parts.style.push(format!(
                "@keyframes {class} {{ 0%, 100% {{ opacity: 0.15 }} 50% {{ opacity: 1 }} }}"
            ));
            parts.style.push(format!(
                ".{class} {{ animation: {class} {}s ease-in-out infinite }}",
                num(period / 1000.0)
            ));
            // mod の枠は矩形の内側に描く 2 px の border。SVG の線は輪郭の両側に出るので、1 px 内へ寄せる
            parts.body.push(format!(
                "<rect class=\"pjp-mk {class}\" x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" rx=\"{}\" style=\"fill: none; stroke: {color}; stroke-width: 2px; opacity: 1\"/>",
                num(x + 1.0),
                num(y + 1.0),
                num(w - 2.0),
                num(h - 2.0),
                num((radius - 1.0).max(0.0))
            ));
            Ok(("pulse", warns, notes))
        }
        "dot" => {
            let [x1, y1, x2, y2] = coords(o, ["x1", "y1", "x2", "y2"])?;
            let size = positive(o, "size", 9.0, &mut warns);
            let period = positive(o, "period", 2200.0, &mut warns);
            let color = color_of(o, "#61afef", &mut warns);
            let (dx, dy) = (x2 - x1, y2 - y1);
            if dx != 0.0 || dy != 0.0 {
                parts.style.push(format!(
                    "@keyframes {class} {{ 0%, 100% {{ transform: translate(0px, 0px) }} 50% {{ transform: translate({}px, {}px) }} }}",
                    num(dx),
                    num(dy)
                ));
                parts.style.push(format!(
                    ".{class} {{ animation: {class} {}s linear infinite }}",
                    num(period / 1000.0)
                ));
            }
            parts.body.push(format!(
                "<circle class=\"pjp-mk {class}\" cx=\"{}\" cy=\"{}\" r=\"{}\" style=\"fill: {color}; stroke: none; opacity: 1\"/>",
                num(x1),
                num(y1),
                num(size / 2.0)
            ));
            Ok(("dot", warns, notes))
        }
        "label" => {
            let [x, y] = coords(o, ["x", "y"])?;
            let text = match o.get("text") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Number(n)) => n.to_string(),
                Some(Value::Bool(b)) => b.to_string(),
                _ => String::new(),
            };
            if text.trim().is_empty() {
                return Err("字の無い label は焼かない".to_owned());
            }
            let size = positive(o, "size", 12.0, &mut warns).max(9.0);
            let color = color_of(o, "#d7dae0", &mut warns);
            // mod の label は x,y を左上にした字。SVG の text の y は字の下の線なので、字の大きさだけ下げる。字体は panel の図の
            // 雛形と同じ (元の SVG が字体を要素ごとに書いていても、焼いた字が既定の字体に落ちない)
            let mut lines = text.split('\n');
            let mut el = format!(
                "<text class=\"pjp-mk {class}\" x=\"{}\" y=\"{}\" style=\"fill: {color}; stroke: none; font-family: {LABEL_FONT}; font-size: {}px; font-weight: normal; font-style: normal; opacity: 1\">{}",
                num(x),
                num(y + size),
                num(size),
                xml_text(lines.next().unwrap_or(""))
            );
            for line in lines {
                let _ = write!(
                    el,
                    "<tspan x=\"{}\" dy=\"1.25em\">{}</tspan>",
                    num(x),
                    xml_text(line)
                );
            }
            el.push_str("</text>");
            parts.body.push(el);
            notes.push(format!(
                "label の字は焼いた時点の {text:?} (panel で替えても、上げた写しは替わらない)"
            ));
            Ok(("label", warns, notes))
        }
        "" => Err("kind が無いので焼かない".to_owned()),
        other => Err(format!(
            "知らない kind {other:?} は焼かない (mod も描かない)"
        )),
    }
}

/// 座標の数 (mod と同じく、数の字も数とみる)。1 つでも無ければ、そのわけ。
fn coords<const N: usize>(
    o: &Map<String, Value>,
    keys: [&str; N],
) -> std::result::Result<[f64; N], String> {
    let mut out = [0.0; N];
    for (slot, key) in out.iter_mut().zip(keys) {
        *slot = number(o.get(key)).ok_or_else(|| format!("{key} が数でないので焼かない"))?;
    }
    Ok(out)
}

fn number(v: Option<&Value>) -> Option<f64> {
    let n = match v? {
        Value::Number(n) => n.as_f64()?,
        Value::String(s) => s.trim().parse::<f64>().ok()?,
        _ => return None,
    };
    n.is_finite().then_some(n)
}

/// 0 より大きい数。無ければ既定、決まりの外 (0 以下・数でない) なら既定にして注意を足す。
fn positive(o: &Map<String, Value>, key: &str, default: f64, notes: &mut Vec<String>) -> f64 {
    match o.get(key) {
        None | Some(Value::Null) => default,
        v => match number(v) {
            Some(n) if n > 0.0 => n,
            _ => {
                notes.push(format!(
                    "{key} が 0 より大きい数でないので {} にした",
                    num(default)
                ));
                default
            }
        },
    }
}

fn non_negative(o: &Map<String, Value>, key: &str, default: f64, notes: &mut Vec<String>) -> f64 {
    match o.get(key) {
        None | Some(Value::Null) => default,
        v => match number(v) {
            Some(n) if n >= 0.0 => n,
            _ => {
                notes.push(format!(
                    "{key} が 0 以上の数でないので {} にした",
                    num(default)
                ));
                default
            }
        },
    }
}

/// mark の color を SVG に書く色にする。`#` で始まる 16 進の色はそのまま、theme の名前は暗い theme の色 (注意を足す)、
/// 無ければ既定、ほかは既定にして注意を足す。
fn color_of(o: &Map<String, Value>, default: &str, notes: &mut Vec<String>) -> String {
    let Some(v) = o.get("color").filter(|v| !v.is_null()) else {
        return default.to_owned();
    };
    let s = v.as_str().unwrap_or("").trim();
    if s.is_empty() {
        return default.to_owned();
    }
    if let Some(hex) = s.strip_prefix('#')
        && matches!(hex.len(), 3 | 4 | 6 | 8)
        && hex.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return s.to_owned();
    }
    if let Some((_, c)) = THEME.iter().find(|(name, _)| *name == s) {
        notes.push(format!(
            "color {s:?} は theme の名前なので {c} で焼いた (marks の color は #rrggbb で書く)"
        ));
        return (*c).to_owned();
    }
    notes.push(format!(
        "color {s:?} を色として読めないので {default} にした"
    ));
    default.to_owned()
}

/// 節の width・height (mod の `sizeOr` と同じく、JSON の数で 0 より大きいときだけ。数の字・0 以下なら 520・300)。
fn size_or(v: Option<&Value>, default: f64) -> f64 {
    v.and_then(Value::as_f64)
        .filter(|n| n.is_finite() && *n > 0.0)
        .unwrap_or(default)
}

/// SVG の大きさと viewBox。
#[derive(Debug, Clone, Copy, PartialEq)]
struct Root {
    width: Option<f64>,
    height: Option<f64>,
    view_box: Option<[f64; 4]>,
}

/// `<svg …>` の始まりの tag から、width・height・viewBox を読む。
fn svg_root(svg: &str) -> Option<Root> {
    let mut from = 0;
    let start = loop {
        let i = from + svg[from..].find("<svg")?;
        let next = svg[i + 4..].chars().next()?;
        if next.is_whitespace() || next == '>' || next == '/' {
            break i;
        }
        from = i + 4;
    };
    let end = start + svg[start..].find('>')?;
    let tag = &svg[start..end];
    let length = |name: &str| {
        attr(tag, name)
            .map(|v| v.trim().trim_end_matches("px").trim())
            .and_then(|v| v.parse::<f64>().ok())
            .filter(|n| n.is_finite() && *n > 0.0)
    };
    let view_box = attr(tag, "viewBox").and_then(|v| {
        let n: Vec<f64> = v
            .split([' ', ',', '\t', '\n', '\r'])
            .filter(|p| !p.is_empty())
            .filter_map(|p| p.parse::<f64>().ok())
            .collect();
        (n.len() == 4 && n[2] > 0.0 && n[3] > 0.0).then(|| [n[0], n[1], n[2], n[3]])
    });
    Some(Root {
        width: length("width"),
        height: length("height"),
        view_box,
    })
}

/// tag の中の属性 `name="…"` か `name='…'` の値。
fn attr<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    let mut from = 0;
    while let Some(off) = tag[from..].find(name) {
        let i = from + off;
        from = i + name.len();
        let before = tag[..i].chars().next_back();
        if !before.is_some_and(char::is_whitespace) {
            continue;
        }
        let rest = tag[i + name.len()..].trim_start();
        let Some(rest) = rest.strip_prefix('=') else {
            continue;
        };
        let rest = rest.trim_start();
        let quote = rest.chars().next()?;
        if quote != '"' && quote != '\'' {
            continue;
        }
        let body = &rest[1..];
        return body.find(quote).map(|j| &body[..j]);
    }
    None
}

/// marks の座標 (節の width×height の px) を SVG の座標 (viewBox) に写す transform。同じ空間なら None。
///
/// 写すこと自体は正しい (SVG の width・height が節と同じで viewBox だけが違う図も、写せば panel と同じ所に出る) ので黙って
/// 写す。注意を足すのは、SVG の大きさ (width・height。無ければ viewBox の幅と高さ) が節の width・height と違うときだけ
/// (`references/panel.md` の「図」: panel.json の width・height は SVG の width・height と同じにする)。
fn frame(root: &Root, width: f64, height: f64, warnings: &mut Vec<String>) -> Option<String> {
    let size = match (root.width, root.height, root.view_box) {
        (Some(w), Some(h), _) => Some((w, h)),
        (_, _, Some(vb)) => Some((vb[2], vb[3])),
        _ => None,
    };
    let same = |a: f64, b: f64| (a - b).abs() < 1e-9;
    if let Some((w, h)) = size
        && !(same(w, width) && same(h, height))
    {
        warnings.push(format!(
            "節の大きさ {}x{} と SVG の大きさ {}x{} が違う (marks は SVG に合わせて焼いた。panel.json の width・height は SVG と同じにする)",
            num(width),
            num(height),
            num(w),
            num(h)
        ));
    }
    let vb = root
        .view_box
        .or_else(|| size.map(|(w, h)| [0.0, 0.0, w, h]))?;
    if same(vb[0], 0.0) && same(vb[1], 0.0) && same(vb[2], width) && same(vb[3], height) {
        return None;
    }
    Some(format!(
        "translate({} {}) scale({} {})",
        num(vb[0]),
        num(vb[1]),
        num(vb[2] / width),
        num(vb[3] / height)
    ))
}

/// 数を短く書く (小数は 3 桁まで、末尾の 0 と点を落とす。-0 は 0)。
pub fn num(v: f64) -> String {
    let s = format!("{v:.3}");
    let s = if s.contains('.') {
        s.trim_end_matches('0').trim_end_matches('.').to_owned()
    } else {
        s
    };
    if s == "-0" { "0".to_owned() } else { s }
}

/// XML の文 (要素の中身) に書ける形にする。`&`・`<`・`>` を逃がし、XML 1.0 に書けない制御文字を外す。
fn xml_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '\t' => out.push(' '),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn template(name: &str) -> String {
        // 図の雛形 (skill pjp-hc-hub の assets/panel。dotfiles の nix/files/claude/skills/pjp-hc-hub/assets/panel)
        let p = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../../files/claude/skills/pjp-hc-hub/assets/panel")
            .join(name);
        std::fs::read_to_string(&p)
            .unwrap_or_else(|e| panic!("{}: {e}", p.display()))
            .replace("\r\n", "\n")
    }

    fn template_section(id: &str) -> Value {
        let v: Value = serde_json::from_str(&template("sections.json")).unwrap();
        v["sections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["id"] == id)
            .unwrap()
            .clone()
    }

    fn svg460x300() -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"460\" height=\"300\" viewBox=\"0 0 460 300\">\n  <rect width=\"460\" height=\"300\" fill=\"#1e2228\"/>\n</svg>\n".to_owned()
    }

    fn section(marks: Value) -> Value {
        json!({ "type": "image", "id": "x", "src": "ABC-1/x.svg", "width": 460, "height": 300, "marks": marks })
    }

    fn jst() -> JstDateTime {
        pjp_core::time::parse_time("2026-11-23T22:40:00+09:00")
            .unwrap()
            .to_jst()
    }

    #[test]
    fn numbers_are_short() {
        assert_eq!(num(460.0), "460");
        assert_eq!(num(40.771_681), "40.772");
        assert_eq!(num(1.274_115), "1.274");
        assert_eq!(num(0.15), "0.15");
        assert_eq!(num(-0.0001), "0");
        assert_eq!(num(-5.5), "-5.5");
    }

    #[test]
    fn act_template_is_baked_on_top_and_keeps_the_figure() {
        let svg = template("act.svg");
        let baked = bake(&svg, &template_section("act")).unwrap();
        assert_eq!(baked.counts, vec![("flow", 2), ("pulse", 2)]);
        assert!(baked.warnings.is_empty(), "{:?}", baked.warnings);
        let close = svg.rfind("</svg>").unwrap();
        // 元の図はそのまま。焼いた g は </svg> の前 (図の上) に入る
        assert!(baked.svg.starts_with(&svg[..close]));
        assert!(baked.svg.ends_with(&svg[close..]));
        let block = &baked.svg[close..baked.svg.len() - (svg.len() - close)];
        assert!(block.starts_with("  <g id=\"pjp-marks\">\n"), "{block}");
        // 点の間は 2π·292/45 = 40.7709 px。speed 32 で 1 間を 1.274 秒。42 px の線では、素の位置で点が 21 px の所に来る
        // 位相 40.771 - 21 = 19.771 から、1 間ぶん進める
        assert!(block.contains("@keyframes pjp-mk-0 { 0% { stroke-dashoffset: 60.542px } 100% { stroke-dashoffset: 19.771px } }"));
        assert!(block.contains(".pjp-mk-0 { animation: pjp-mk-0 1.274s linear infinite }"));
        assert!(block.contains("<clipPath id=\"pjp-mk-0-clip\"><rect x=\"128\" y=\"147\" width=\"42\" height=\"10\"/></clipPath>"));
        assert!(block.contains("<line class=\"pjp-mk pjp-mk-1\" x1=\"290\" y1=\"152\" x2=\"332\" y2=\"152\" style=\"fill: none; stroke: #61afef; stroke-width: 8px; stroke-linecap: round; stroke-dasharray: 0 40.771px; stroke-dashoffset: 19.771px; clip-path: url(#pjp-mk-1-clip); opacity: 1\"/>"));
        // pulse は雛形の黄の箱 (140,14 180x70 rx 8) の内側の 2 px の枠
        assert!(block.contains("<rect class=\"pjp-mk pjp-mk-2\" x=\"141\" y=\"15\" width=\"178\" height=\"68\" rx=\"7\" style=\"fill: none; stroke: #e5c07b; stroke-width: 2px; opacity: 1\"/>"));
        assert!(block.contains(".pjp-mk-3 { animation: pjp-mk-3 1.6s ease-in-out infinite }"));
        assert!(block.contains("prefers-reduced-motion: reduce"));
        assert!(baked.notes.is_empty(), "{:?}", baked.notes);
    }

    #[test]
    fn looks_are_in_the_element_style_so_the_figures_own_rules_do_not_win() {
        // 元の SVG の <style> の要素の規則は属性より強い。焼いた marks の見た目は要素の style に書き、属性では書かない
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"460\" height=\"300\"><style>line{stroke-width:2;stroke-dasharray:4 3} rect{fill:#2c323c} text{font-family:serif}</style><rect width=\"460\" height=\"300\"/></svg>";
        let baked = bake(
            svg,
            &section(json!([
                { "kind": "flow", "x1": 10, "y1": 10, "x2": 60, "y2": 10 },
                { "kind": "pulse", "x": 10, "y": 30, "w": 50, "h": 30 },
                { "kind": "dot", "x1": 10, "y1": 80, "x2": 60, "y2": 80 },
                { "kind": "label", "x": 10, "y": 100, "text": "3 件" }
            ])),
        )
        .unwrap();
        let block = &baked.svg[baked.svg.find("<g id=\"pjp-marks\"").unwrap()..];
        for el in ["<line ", "<rect class", "<circle ", "<text "] {
            let start = block.find(el).unwrap_or_else(|| panic!("{el}"));
            let tag = &block[start..start + block[start..].find('>').unwrap()];
            assert!(tag.contains(" style=\""), "{tag}");
            for presentation in [
                " fill=",
                " stroke=",
                " stroke-width=",
                " font-size=",
                " font-family=",
            ] {
                assert!(!tag.contains(presentation), "{presentation} in {tag}");
            }
        }
        assert!(block.contains("font-family: 'Yu Gothic UI', 'Meiryo UI', Meiryo, 'Segoe UI', sans-serif; font-size: 12px"));
    }

    #[test]
    fn vertical_flow_is_clipped_sideways() {
        let baked = bake(&template("route.svg"), &template_section("route")).unwrap();
        assert_eq!(baked.counts, vec![("flow", 2), ("pulse", 1)]);
        assert!(baked.svg.contains("<clipPath id=\"pjp-mk-0-clip\"><rect x=\"108\" y=\"64\" width=\"10\" height=\"40\"/></clipPath>"));
    }

    #[test]
    fn figure_without_marks_is_copied_as_is() {
        let svg = template("compare.svg");
        let baked = bake(&svg, &template_section("compare")).unwrap();
        assert_eq!(baked.svg, svg);
        assert!(baked.counts.is_empty());
        assert_eq!(baked.summary(), "marks なし。SVG をそのまま写した");
        let none = bake(&svg460x300(), &json!({ "type": "image", "src": "a/b.svg" })).unwrap();
        assert_eq!(none.svg, svg460x300());
    }

    #[test]
    fn baked_svg_is_not_baked_again() {
        let svg = template("act.svg");
        let once = bake(&svg, &template_section("act")).unwrap();
        let err = bake(&once.svg, &template_section("act")).unwrap_err();
        assert!(err.contains("もう焼いてある"), "{err}");
    }

    #[test]
    fn dot_label_and_theme_colors() {
        let baked = bake(
            &svg460x300(),
            &section(json!([
                { "kind": "dot", "x1": 100, "y1": 50, "x2": 140, "y2": 50, "color": "ok" },
                { "kind": "label", "x": 20, "y": 30, "text": "3 件 <済> & 次", "size": 8 },
                { "kind": "label", "x": 20, "y": 60, "text": "1 行目\n2 行目", "color": "#e5c07b" },
                { "kind": "dot", "x1": "10", "y1": "10", "x2": "10", "y2": "10", "period": 0 }
            ])),
        )
        .unwrap();
        assert_eq!(baked.counts, vec![("dot", 2), ("label", 2)]);
        let s = &baked.svg;
        assert!(s.contains(
            "<circle class=\"pjp-mk pjp-mk-0\" cx=\"100\" cy=\"50\" r=\"4.5\" style=\"fill: #98c379; stroke: none; opacity: 1\"/>"
        ));
        assert!(s.contains("50% { transform: translate(40px, 0px) }"));
        assert!(s.contains(".pjp-mk-0 { animation: pjp-mk-0 2.2s linear infinite }"));
        // label の字は小さくても 9 px。逃がした字で書く
        assert!(s.contains("<text class=\"pjp-mk pjp-mk-1\" x=\"20\" y=\"39\" style=\"fill: #d7dae0; stroke: none; font-family: 'Yu Gothic UI', 'Meiryo UI', Meiryo, 'Segoe UI', sans-serif; font-size: 9px; font-weight: normal; font-style: normal; opacity: 1\">3 件 &lt;済&gt; &amp; 次</text>"));
        assert!(s.contains(">1 行目<tspan x=\"20\" dy=\"1.25em\">2 行目</tspan></text>"));
        // 動かない dot には動きを付けない
        assert!(!s.contains("@keyframes pjp-mk-3"));
        let w = baked.warnings.join("\n");
        assert!(
            w.contains("color \"ok\" は theme の名前なので #98c379 で焼いた"),
            "{w}"
        );
        assert!(
            w.contains("period が 0 より大きい数でないので 2200 にした"),
            "{w}"
        );
        // label の字は直すものでないので、!! でなく note
        assert!(!w.contains("label の字"), "{w}");
        assert_eq!(
            baked.notes,
            vec![
                "marks[1]: label の字は焼いた時点の \"3 件 <済> & 次\" (panel で替えても、上げた写しは替わらない)".to_owned(),
                "marks[2]: label の字は焼いた時点の \"1 行目\\n2 行目\" (panel で替えても、上げた写しは替わらない)".to_owned(),
            ]
        );
    }

    #[test]
    fn marks_that_cannot_be_baked_are_reported() {
        let baked = bake(
            &svg460x300(),
            &section(json!([
                { "kind": "spin", "x": 1 },
                { "kind": "flow", "x1": 10, "y1": 10, "x2": 10, "y2": 10 },
                { "kind": "flow", "x1": 10, "y1": 10, "x2": 60 },
                { "kind": "pulse", "x": 0, "y": 0, "w": 2, "h": 30 },
                { "kind": "label", "x": 0, "y": 0, "text": "  " },
                "flow",
                { "kind": "flow", "x1": 10, "y1": 10, "x2": 60, "y2": 10, "color": "red" }
            ])),
        )
        .unwrap();
        assert_eq!(baked.counts, vec![("flow", 1)]);
        let w = baked.warnings.join("\n");
        for want in [
            "marks[0]: 知らない kind \"spin\"",
            "marks[1]: 長さ 0 の flow",
            "marks[2]: y2 が数でない",
            "marks[3]: 幅 2・高さ 30 の pulse は小さすぎる",
            "marks[4]: 字の無い label",
            "marks[5]: オブジェクトではない",
            "marks[6] (flow): color \"red\" を色として読めないので #61afef にした",
        ] {
            assert!(w.contains(want), "{want}\n---\n{w}");
        }
        // 1 つも焼けなければ、そのまま写したと「焼けなかった」で知らせる
        let none = bake(&svg460x300(), &section(json!([{ "kind": "spin" }]))).unwrap();
        assert_eq!(none.svg, svg460x300());
        assert_eq!(
            none.summary(),
            "marks を 1 つも焼けなかった (!! の行)。SVG をそのまま写した"
        );
    }

    #[test]
    fn size_mismatch_maps_marks_into_the_svg() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"920\" height=\"600\" viewBox=\"0 0 920 600\"><rect width=\"920\" height=\"600\"/></svg>";
        let baked = bake(
            svg,
            &section(json!([{ "kind": "pulse", "x": 10, "y": 10, "w": 50, "h": 30 }])),
        )
        .unwrap();
        assert!(
            baked
                .svg
                .contains("<g id=\"pjp-marks\" transform=\"translate(0 0) scale(2 2)\">")
        );
        assert_eq!(
            baked.warnings,
            vec![
                "節の大きさ 460x300 と SVG の大きさ 920x600 が違う (marks は SVG に合わせて焼いた。panel.json の width・height は SVG と同じにする)".to_owned()
            ]
        );
        // </svg> が同じ行にあっても、改行を挟んで入れる
        assert!(baked.svg.contains("/>\n  <g id=\"pjp-marks\""));
        assert!(baked.svg.ends_with("  </g>\n</svg>"));
        let pulse = section(json!([{ "kind": "pulse", "x": 10, "y": 10, "w": 50, "h": 30 }]));
        // viewBox が無ければ width・height で比べる
        let plain = bake("<svg width=\"460px\" height=\"300\"><rect/></svg>", &pulse).unwrap();
        assert!(plain.warnings.is_empty(), "{:?}", plain.warnings);
        assert!(plain.svg.contains("<g id=\"pjp-marks\">"));
        // 大きさは節と同じで viewBox だけ違う図は、黙って viewBox に写す (誤った注意を出さない)
        let half = bake(
            "<svg width=\"460\" height=\"300\" viewBox=\"0 0 230 150\"><rect/></svg>",
            &pulse,
        )
        .unwrap();
        assert!(half.warnings.is_empty(), "{:?}", half.warnings);
        assert!(
            half.svg
                .contains("<g id=\"pjp-marks\" transform=\"translate(0 0) scale(0.5 0.5)\">")
        );
        // width・height が無ければ viewBox の大きさで比べる
        let vb_only = bake("<svg viewBox=\"0 0 460 300\"><rect/></svg>", &pulse).unwrap();
        assert!(vb_only.warnings.is_empty(), "{:?}", vb_only.warnings);
        // 節の width・height は JSON の数だけを読む (mod の sizeOr と同じく、数の字は 520x300 とみる)
        let text_size = json!({ "type": "image", "width": "460", "height": "300", "marks": [{ "kind": "pulse", "x": 10, "y": 10, "w": 50, "h": 30 }] });
        let by_text = bake(&svg460x300(), &text_size).unwrap();
        assert!(
            by_text.warnings[0].contains("節の大きさ 520x300 と SVG の大きさ 460x300 が違う"),
            "{:?}",
            by_text.warnings
        );
    }

    #[test]
    fn broken_svg_is_refused() {
        let s = section(json!([]));
        assert!(bake("<html></html>", &s).unwrap_err().contains("<svg>"));
        assert!(
            bake("<svg width=\"1\">", &s)
                .unwrap_err()
                .contains("</svg>")
        );
        // <svgfoo は svg の始まりではない
        assert!(bake("<svgfoo></svg>", &s).is_err());
    }

    #[test]
    fn root_attributes() {
        let r = svg_root("<?xml version=\"1.0\"?>\n<svg xmlns='http://www.w3.org/2000/svg'\n  data-width=\"9\" width = '460' height=\"300px\" viewBox=\"0,0 460 300\">").unwrap();
        assert_eq!(
            r,
            Root {
                width: Some(460.0),
                height: Some(300.0),
                view_box: Some([0.0, 0.0, 460.0, 300.0])
            }
        );
        assert_eq!(svg_root("<svg>").unwrap().width, None);
    }

    #[test]
    fn caption_has_the_time_and_is_safe_in_quotes() {
        let now = jst();
        let s = json!({ "title": "R1 中継を通して承認する (① ②)", "caption": "私が端末 A から `ssh` を打つ \"$HOME\" 'x' C:\\a" });
        assert_eq!(
            caption(&s, "ABC-1/r1.svg", &now),
            "2026/11/23 22:40 の panel の図: R1 中継を通して承認する (① ②) — 私が端末 A から ssh を打つ ＂＄HOME＂ ＇x＇ C:＼a"
        );
        // PowerShell が引用符として読む字 (‘ ’ ‚ ‛ と “ ” „) も全角の引用符にする
        assert_eq!(
            quote_safe("Claude’s ‘plan’ ‚x‛ “a” „b"),
            "Claude＇s ＇plan＇ ＇x＇ ＂a＂ ＂b"
        );
        assert_eq!(
            caption(&json!({ "caption": "" }), "ABC-1/r1-approve.svg", &now),
            "2026/11/23 22:40 の panel の図: r1-approve"
        );
    }

    #[test]
    fn windows_paths_have_a_wsl_twin() {
        assert_eq!(
            wsl_path(r"C:\Users\user\AppData\Local\Temp\claude\x\scratchpad\ticket-fig\r1.svg")
                .as_deref(),
            Some("/mnt/c/Users/user/AppData/Local/Temp/claude/x/scratchpad/ticket-fig/r1.svg")
        );
        assert_eq!(
            wsl_path(r"\\?\D:\a\b.svg").as_deref(),
            Some("/mnt/d/a/b.svg")
        );
        assert_eq!(wsl_path("/tmp/x/r1.svg"), None);
        assert_eq!(wsl_path(r"\\wsl.localhost\wsl1\home\x.svg"), None);
    }

    #[test]
    fn src_is_resolved_like_the_mod() {
        let home = Path::new("/h");
        assert_eq!(
            media_path(home, "ABC-1/x.svg").unwrap(),
            Path::new("/h").join(MEDIA).join("ABC-1").join("x.svg")
        );
        assert_eq!(
            media_path(home, "mods/pjp-hub-panel/ring.svg").unwrap(),
            Path::new("/h")
                .join("mods")
                .join("pjp-hub-panel")
                .join("ring.svg")
        );
        for bad in [
            "",
            "/abs/x.svg",
            r"C:\x.svg",
            "../x.svg",
            "a/../../x.svg",
            "https://e.com/x.svg",
        ] {
            assert!(media_path(home, bad).is_err(), "{bad}");
        }
        assert_eq!(file_name("ABC-1/x.svg").as_deref(), Some("x.svg"));
        assert_eq!(file_name("ABC-1/"), None);
    }

    #[test]
    fn mini_lines_are_found_with_their_heading() {
        let sections: Vec<Value> = serde_json::from_str::<Value>(&template("sections.json"))
            .unwrap()["sections"]
            .as_array()
            .unwrap()
            .clone();
        assert_eq!(
            find_mini(&sections, "TKT-n/mini-before-after.svg"),
            Some((
                Some("見出しの項目 (前と後)".to_owned()),
                "前と後の説明".to_owned()
            ))
        );
        assert_eq!(find_mini(&sections, "TKT-n/mini-none.svg"), None);
        // Q&A の答えの中のミニ絵と、見出しの無い絵・コードの中の絵の行。字下げした詳細の太字は見出しにしない
        let qa = vec![json!({ "type": "qa", "id": "qa", "items": [
            { "id": "qa-1", "a": "```\n![コード](T/mini-a.svg)\n```\n![見出しなし](T/mini-b.svg)\n- **畳み方**\n  - **詳細の太字**\n  ![畳む前と後](T/mini-a.svg)" }
        ] })];
        assert_eq!(
            find_mini(&qa, "T/mini-a.svg"),
            Some((Some("畳み方".to_owned()), "畳む前と後".to_owned()))
        );
        assert_eq!(
            find_mini(&qa, "T/mini-b.svg"),
            Some((None, "見出しなし".to_owned()))
        );
        // コードの囲みは mod の FENCE と同じ: 閉じは同じ字で同じ長さ以上、4 つ以上字下げした ``` は囲みでない
        let fenced = vec![json!({ "type": "markdown", "id": "m", "text":
            "````\n```\n![中](T/mini-in.svg)\n~~~\n````\n    ```\n- **後**\n  ![外](T/mini-out.svg)" })];
        assert_eq!(find_mini(&fenced, "T/mini-in.svg"), None);
        assert_eq!(
            find_mini(&fenced, "T/mini-out.svg"),
            Some((Some("後".to_owned()), "外".to_owned()))
        );
        // 後ろに字が続く行・パスに空白のある行は絵の行でない。説明は空でもよい (mod の MINI_LINE)
        assert_eq!(picture_line("![a](T/x.svg) 続き"), None);
        assert_eq!(picture_line("![a](T/x y.svg)"), None);
        assert_eq!(picture_line("\t![](T/x.svg) "), Some(("", "T/x.svg")));
        assert_eq!(
            heading_item("* **見出し** の続き").as_deref(),
            Some("見出し")
        );
        assert_eq!(heading_item("  - **詳細**"), None);
        assert_eq!(heading_item("- 太字でない"), None);
    }

    #[test]
    fn out_dirs_inside_a_dir_are_found() {
        let p = Path::new("/a/b");
        assert!(inside(Path::new("/a/b"), p));
        assert!(inside(Path::new("/a/b/c/d"), p));
        assert!(!inside(Path::new("/a/bc"), p));
        assert!(!inside(Path::new("/a"), p));
    }

    #[test]
    fn mini_caption_has_the_heading_and_the_description() {
        let now = jst();
        assert_eq!(
            mini_caption(Some("畳み方"), "畳む前と後 `x`", &now),
            "2026/11/23 22:40 の panel のミニ絵: 畳み方 — 畳む前と後 x"
        );
        assert_eq!(
            mini_caption(None, "流れ", &now),
            "2026/11/23 22:40 の panel のミニ絵: 流れ"
        );
        assert_eq!(
            mini_caption(Some("畳み方"), "", &now),
            "2026/11/23 22:40 の panel のミニ絵: 畳み方"
        );
    }
}
