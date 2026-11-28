//! 子のマシンを決める: `--on <machine>|local|wsl|auto` → hub.toml の `default_machine` → 自動。
//!
//! `wsl` (`--on wsl`・`default_machine = "wsl"`) は手元の WSL の machine ([`wsl`])。`hc machine ls` のうち `--via` の
//! コマンドが wsl.exe の machine を、名前によらず選ぶ (WSL の machine の名前は PC ごとに違う)。`local`・`auto` と同じく語が
//! machine の名前より先で、名前が wsl の machine が WSL でなければ (SSH 先)、`--on wsl` ではその machine を選ばない。
//!
//! 自動 (`--on auto`・`default_machine = "auto"`・どちらも無いとき) は、`hc machine ls` の machine を種類 (SSH 先・手元の WSL・
//! このマシン) に分け、hub.toml の `[auto]` の `order` (既定 `["ssh", "wsl"]`) の順に見る。種類の中では、connected で、`hc exec`
//! 1 回で測った値 (`uname -s`・`nproc`・`/proc/loadavg`・MemAvailable) が Linux の machine を、空きコア (コア数 - 1 分の負荷。
//! 0.1 の桁) の多い順・空きメモリの多い順に並べ、子を立てるアカウントの用意 ([`account::ready`]) が通った最初の machine を選ぶ。
//! SSH 先には下限 (空きコア 1・空きメモリ 4 GiB。`min_free_cores`・`min_free_mem_gib`) を効かせ、手元 (WSL・このマシン) は落ち先
//! なので効かせない。種類に選べる machine が無ければ次の種類へ進み、どこにも無ければ止まる。`--chrome` の子は WSL だけから選ぶ
//! (Claude in Chrome は WSL の子で確かめた。pjp-hc-child の `references/chrome.md`)。

use std::path::Path;

use pjp_core::{Error, Result};
use serde_json::Value;

use super::account::{self, Account, Ready};
use super::{Probe, probe};
use crate::hc::{Hc, Runner, first_line, is_wsl_machine, is_wsl_target, strings};

/// `--on`・`default_machine` で自動を選ぶ値。
const AUTO: &str = "auto";

/// `--on`・`default_machine` で手元の WSL の machine を選ぶ値。
const WSL: &str = "wsl";

/// 手元の WSL を hc の machine に足すコマンド (Windows のハブで打つ。名前は自由)。pjp-hc-hub の `pjp hub hello` も同じ形を出す。
pub const WSL_ADD: &str =
    "hc machine add --via 'wsl.exe -d <ディストリビューション> --cd ~ -e bash -lc' --name <名前>";

/// 子のマシンの決め方。
pub(super) enum Target {
    /// `--on <machine>`・`default_machine = "<machine>"`・`local` (None はこのマシン)。
    Fixed(Option<String>),
    /// `--on wsl`・`default_machine = "wsl"`: 手元の WSL の machine ([`wsl`] で引く)。中身はそうしたわけ (出力に出す)。
    Wsl(String),
    /// 自動で選ぶ。
    Auto(Auto),
}

/// 子のマシンの種類。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// SSH 先 (target が wsl.exe でない machine。`--via` の machine も)。
    Ssh,
    /// 手元の WSL (target が wsl.exe で始まる machine)。
    Wsl,
    /// このマシン (`hc exec` に `--on` を付けない)。order に書いたときだけ見る (Linux のハブ向け)。
    Local,
}

impl Kind {
    const ALL: [Kind; 3] = [Kind::Ssh, Kind::Wsl, Kind::Local];

    /// hub.toml の order に書く名前。
    fn key(self) -> &'static str {
        match self {
            Kind::Ssh => "ssh",
            Kind::Wsl => "wsl",
            Kind::Local => "local",
        }
    }

    /// 出力に出す名前。
    fn label(self) -> &'static str {
        match self {
            Kind::Ssh => "SSH 先",
            Kind::Wsl => "WSL",
            Kind::Local => "このマシン",
        }
    }

    /// 下限 (空きコア・空きメモリ) を効かせるか。手元 (WSL・このマシン) は、使える SSH 先が無いときの落ち先なので効かせない。
    fn has_floor(self) -> bool {
        self == Kind::Ssh
    }

    fn from_key(key: &str) -> Option<Kind> {
        Kind::ALL.into_iter().find(|k| k.key() == key)
    }
}

/// 自動の選び方 (hub.toml の `[auto]`)。
pub(super) struct Auto {
    /// 自動にしたわけ (出力に出す)。
    why: String,
    /// `--on auto` で頼まれたか (hub.toml の既定でなく、打った人が自動を選んだ)。
    explicit: bool,
    /// hub.toml のパス (出力に出す)。
    path: String,
    order: Vec<Kind>,
    /// 選ばない machine の名前。
    exclude: Vec<String>,
    /// SSH 先の空きコアの下限。
    min_cores: f64,
    /// SSH 先の空きメモリの下限 (GiB)。
    min_mem_gib: f64,
}

impl Auto {
    /// `--on auto` と打って自動を選んだか (`--on` を省いた・hub.toml の `default_machine = "auto"` は false)。
    pub(super) fn explicit(&self) -> bool {
        self.explicit
    }
}

/// `[auto]` に書ける鍵。
const AUTO_KEYS: [&str; 4] = ["order", "exclude", "min_free_cores", "min_free_mem_gib"];

/// `hc exec` で測るのを待つ秒。
const MEASURE_TIMEOUT: u64 = 20;

/// 1 GiB を MemAvailable の単位 (kB = KiB) で。
const KIB_PER_GIB: f64 = 1024.0 * 1024.0;

/// 子のマシンで、OS・コア数・負荷・空きメモリを 1 回で測る `sh` の script。
const MEASURE: &str = r#"printf 'os=%s\n' "$(uname -s 2>/dev/null)"
printf 'nproc=%s\n' "$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
if [ -r /proc/loadavg ]; then printf 'loadavg=%s\n' "$(cat /proc/loadavg)"; fi
if [ -r /proc/meminfo ]; then sed -n 's/^MemAvailable:[[:space:]]*\([0-9][0-9]*\) kB$/memavail_kb=\1/p' /proc/meminfo; fi
"#;

/// 子のマシンを決める: `--on` → hub.toml の `default_machine` → 自動。`local` はこのマシン (None)、`wsl` は手元の WSL の
/// machine。hub.toml は `<config>/hub.toml` (`~/.config/pjp/hub.toml`)。自動なら、測る前に `[auto]` を読んで確かめる。
pub(super) fn resolve(r: &dyn Runner, on: Option<&str>) -> Result<Target> {
    if let Some(m) = on.filter(|m| *m != AUTO) {
        return Ok(named(m, || format!("--on {WSL}")));
    }
    let path = r.config_dir()?.join("hub.toml");
    let table = read_hub(&path)?;
    let shown = path.display();
    let why = match (on, &table) {
        (Some(_), _) => format!("--on {AUTO}"),
        (None, None) => format!("--on も {shown} も無い"),
        (None, Some(t)) => match t.get("default_machine") {
            None => format!("--on も {shown} の default_machine も無い"),
            Some(v) => match v.as_str() {
                Some(AUTO) => format!("{shown} の default_machine が {AUTO}"),
                Some(m) => {
                    return Ok(named(m, || format!("{shown} の default_machine が {WSL}")));
                }
                None => {
                    return Err(Error::config(format!(
                        "{shown} の default_machine は文字列 (machine の名前・local・wsl・auto) にする ({})",
                        toml_text(v)
                    )));
                }
            },
        },
    };
    // ここまで来た --on は auto だけ
    Ok(Target::Auto(auto_from(
        table.as_ref(),
        &path,
        why,
        on.is_some(),
    )?))
}

/// auto でない値の決め方: `wsl` は手元の WSL の machine (`why` はそうしたわけ)、`local` と空はこのマシン (None)、ほかは
/// machine の名前。語は machine の名前より先 (名前が local・wsl・auto の machine は、この値では名指しできない)。
fn named(m: &str, why: impl FnOnce() -> String) -> Target {
    match m {
        WSL => Target::Wsl(why()),
        "local" | "" => Target::Fixed(None),
        _ => Target::Fixed(Some(m.to_owned())),
    }
}

/// hub.toml を読む (無ければ None)。
fn read_hub(path: &Path) -> Result<Option<toml::Table>> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(Error::io(format!("{} を読めません", path.display()), &e)),
    };
    toml::from_str(&text)
        .map(Some)
        .map_err(|e| Error::config(format!("{} を TOML として読めません: {e}", path.display())))
}

/// hub.toml の `[auto]` から選び方を作る (無い鍵は既定)。知らない鍵・形の違う値は止まる (綴りの誤りを黙って読み飛ばさない)。
fn auto_from(
    table: Option<&toml::Table>,
    path: &Path,
    why: String,
    explicit: bool,
) -> Result<Auto> {
    let shown = path.display().to_string();
    let mut auto = Auto {
        why,
        explicit,
        path: shown.clone(),
        order: vec![Kind::Ssh, Kind::Wsl],
        exclude: Vec::new(),
        min_cores: 1.0,
        min_mem_gib: 4.0,
    };
    let Some(section) = table.and_then(|t| t.get("auto")) else {
        return Ok(auto);
    };
    let bad = |what: String| {
        Error::config(format!(
            "{shown} の [auto] の{what} (書ける鍵は {}。pjp child --help)",
            AUTO_KEYS.join("・")
        ))
    };
    let Some(section) = section.as_table() else {
        return Err(Error::config(format!(
            "{shown} の auto は表 ([auto]) にする"
        )));
    };
    if let Some(key) = section.keys().find(|k| !AUTO_KEYS.contains(&k.as_str())) {
        return Err(bad(format!(" {key} は知らない鍵です")));
    }
    if let Some(v) = section.get("order") {
        let items = v
            .as_array()
            .ok_or_else(|| bad(format!(" order は配列にする ({})", toml_text(v))))?;
        let mut order = Vec::new();
        for item in items {
            let kind = item.as_str().and_then(Kind::from_key).ok_or_else(|| {
                bad(format!(
                    " order の {} は ssh・wsl・local のどれかにする",
                    toml_text(item)
                ))
            })?;
            if order.contains(&kind) {
                return Err(bad(format!(" order に {} が 2 つある", kind.key())));
            }
            order.push(kind);
        }
        if order.is_empty() {
            return Err(bad(" order が空です".to_owned()));
        }
        auto.order = order;
    }
    if let Some(v) = section.get("exclude") {
        let items = v.as_array().ok_or_else(|| {
            bad(format!(
                " exclude は machine の名前の配列にする ({})",
                toml_text(v)
            ))
        })?;
        auto.exclude = items
            .iter()
            .map(|i| {
                i.as_str().map(str::to_owned).ok_or_else(|| {
                    bad(format!(
                        " exclude の {} は machine の名前 (文字列) にする",
                        toml_text(i)
                    ))
                })
            })
            .collect::<Result<_>>()?;
    }
    for (key, slot) in [
        ("min_free_cores", &mut auto.min_cores),
        ("min_free_mem_gib", &mut auto.min_mem_gib),
    ] {
        if let Some(v) = section.get(key) {
            *slot = v
                .as_float()
                .or_else(|| v.as_integer().map(|i| i as f64))
                .filter(|x| x.is_finite() && *x >= 0.0)
                .ok_or_else(|| bad(format!(" {key} は 0 以上の数にする ({})", toml_text(v))))?;
        }
    }
    Ok(auto)
}

/// hub.toml の値を、止まるときの文に出す形に (toml の crate は display の feature を入れていない)。
fn toml_text(v: &toml::Value) -> String {
    match v {
        toml::Value::String(s) => format!("\"{s}\""),
        toml::Value::Integer(i) => i.to_string(),
        toml::Value::Float(f) => f.to_string(),
        toml::Value::Boolean(b) => b.to_string(),
        toml::Value::Array(a) => format!(
            "[{}]",
            a.iter().map(toml_text).collect::<Vec<_>>().join(", ")
        ),
        other => other.type_str().to_owned(),
    }
}

/// machine の種類を決める: target が手元の WSL ([`is_wsl_target`]。`--via` のコマンドが wsl.exe) なら WSL、ほかは SSH 先
/// (`~/.ssh/config` の Host が wsl の SSH 先も、`--via` でないので SSH 先)。
fn kind_of(target: &str, via: bool) -> Kind {
    if is_wsl_target(target, via) {
        Kind::Wsl
    } else {
        Kind::Ssh
    }
}

/// machine が connected でなければ、その状態とわけ (`unreachable: wsl.exe exited`)。
fn down_of(m: &Value) -> Option<String> {
    let state = m["state"].as_str().unwrap_or("?");
    (state != "connected").then(
        || match m["why"].as_str().filter(|w| !w.trim().is_empty()) {
            Some(why) => format!("{state}: {}", first_line(why)),
            None => state.to_owned(),
        },
    )
}

/// `--on wsl` で引いた手元の WSL の machine。
pub(super) struct WslPick {
    /// 選んだ machine の名前。
    pub(super) machine: String,
    /// 出力の頭に出す行 (選んだ machine とわけ・選ばなかった machine)。
    pub(super) lines: Vec<String>,
}

/// 手元の WSL の machine を引く (`--on wsl`・`default_machine = "wsl"`)。`hc machine ls` の WSL の machine
/// ([`is_wsl_machine`]。一時の machine は自動と同じく選ばない) が 1 つならそれ、2 つ以上なら名前が wsl のもの (語と名前が
/// 同じ machine を指す)。無ければ足し方を出して止まり、1 つに決まらない・connected でないときは候補を並べて止まる。名前が wsl の
/// machine が WSL でない (SSH 先) ときは、語が先なので選ばない (その machine に立てるなら名前を替えて名指しする)。
pub(super) fn wsl(hc: &Hc<'_>, why: &str) -> Result<WslPick> {
    let listed = hc.json(&strings(&["machine", "ls", "--json"]))?;
    let all: Vec<&Value> = listed["machines"]
        .as_array()
        .into_iter()
        .flatten()
        .collect();
    let name_of = |m: &Value| m["name"].as_str().unwrap_or("?").to_owned();
    let shown = |m: &Value| match down_of(m) {
        Some(down) => format!("{} ({down})", name_of(m)),
        None => format!("{} (connected)", name_of(m)),
    };
    // 名前の無い machine は選ばない (自動と同じ。控えの空の machine はこのマシンと読まれる)
    let (temporary, usable): (Vec<&Value>, Vec<&Value>) = all
        .iter()
        .copied()
        .filter(|m| m["name"].as_str().is_some_and(|n| !n.is_empty()) && is_wsl_machine(m))
        .partition(|m| m["temporary"].as_bool() == Some(true));
    // 選ばなかった machine (選べたときも止まるときも出す)
    let mut skipped: Vec<String> = Vec::new();
    if let Some(m) = all
        .iter()
        .find(|m| m["name"].as_str() == Some(WSL) && !is_wsl_machine(m))
    {
        skipped.push(format!(
            "  - 名前が {WSL} の machine は WSL でない (SSH 先。target {}) ので選ばない (--on {WSL} は手元の WSL を選ぶ語)。\
             その machine に立てるなら、hc machine rename {WSL} <新しい名前> で名前を替えて --on <新しい名前> で名指しする \
             (替えると、その machine の端末の住所も替わる)",
            m["target"].as_str().unwrap_or("?")
        ));
    }
    if !temporary.is_empty() {
        let names: Vec<String> = temporary.iter().map(|m| name_of(m)).collect();
        // 名前が wsl の一時の machine は、--on wsl が語として読むので名指しできない
        let named_wsl = if names.iter().any(|n| n == WSL) {
            format!(
                "。名前が {WSL} のものは語と同じで名指しできないので、hc machine rename {WSL} <新しい名前> で名前を替える"
            )
        } else {
            String::new()
        };
        skipped.push(format!(
            "  - 一時の machine (temporary) の WSL は選ばない: {} (使うなら --on <machine> で名指しする{named_wsl})",
            names.join("・")
        ));
    }
    let with_skipped = |mut msg: String| -> String {
        for line in &skipped {
            msg.push('\n');
            msg.push_str(line);
        }
        msg
    };
    let chosen = match usable.as_slice() {
        [] => {
            return Err(Error::config(with_skipped(format!(
                "手元の WSL の machine が hc machine ls にありません (--on {WSL} は、--via のコマンドが wsl.exe の machine を名前に\
                 よらず選ぶ)。Windows のハブなら WSL を hc の machine に足してから打ち直す (名前は自由。ディストリビューションの\
                 名前は wsl.exe -l -v で見る):\n  {WSL_ADD}\n\
                 このマシンが WSL (WSL の中の Linux のハブ) なら、--on local でこのマシンに立てる"
            ))));
        }
        [one] => *one,
        many => match many.iter().find(|m| m["name"].as_str() == Some(WSL)) {
            Some(m) => *m,
            None => {
                let listed: Vec<String> = many.iter().map(|m| shown(m)).collect();
                return Err(Error::config(with_skipped(format!(
                    "手元の WSL の machine が {} つあり、--on {WSL} では 1 つに決まりません: {}。--on <machine> で名指しして\
                     打ち直す (名前が {WSL} の WSL の machine があれば、--on {WSL} はそれを選ぶ)",
                    many.len(),
                    listed.join("・")
                ))));
            }
        },
    };
    let machine = name_of(chosen);
    let others: Vec<String> = usable
        .iter()
        .filter(|m| name_of(m) != machine)
        .map(|m| shown(m))
        .collect();
    if let Some(down) = down_of(chosen) {
        let mut msg = format!(
            "手元の WSL の machine {machine} は connected でない ({down})。hc machine ls で状態を確かめてから打ち直す"
        );
        if !others.is_empty() {
            msg.push_str(&format!(
                "\n  - ほかの WSL の machine: {} (使うなら --on <machine> で名指しする)",
                others.join("・")
            ));
        }
        return Err(Error::failure(with_skipped(msg)));
    }
    let mut lines = vec![format!("子のマシン: {machine} (手元の WSL。{why})")];
    if !others.is_empty() {
        lines.push(format!(
            "  - ほかの WSL の machine: {} (名前が {WSL} の machine を選んだ。ほかを使うなら --on <machine> で名指しする)",
            others.join("・")
        ));
    }
    lines.extend(skipped);
    Ok(WslPick { machine, lines })
}

/// 自動で選んだ子のマシン。
pub(super) struct Chosen {
    /// 選んだ machine (None はこのマシン)。
    pub(super) machine: Option<String>,
    /// 選んだ machine の探り (`new` がそのまま使う。二度探らない)。
    pub(super) probe: Probe,
    /// 選んだ machine で確かめたアカウントの用意。
    pub(super) ready: Ready,
    /// 出力に出す行 (選んだ machine と測った値・自動にしたわけ・ほかの machine を 1 行ずつ)。
    pub(super) lines: Vec<String>,
    /// note 用の行に足す文。
    pub(super) note: String,
}

/// hc machine ls の 1 台 (order に local があれば、このマシンも)。
struct Seen {
    name: String,
    /// `hc exec --on` に渡す名前 (このマシンは None)。
    on: Option<String>,
    kind: Kind,
    /// connected でなければ、その状態とわけ。
    down: Option<String>,
    temporary: bool,
}

/// 測った値。
#[derive(Debug, Clone, PartialEq)]
struct Values {
    nproc: u32,
    /// 1 分の負荷 (/proc/loadavg の字のまま。出力に出す)。
    load1: String,
    load1_value: f64,
    /// MemAvailable (kB)。
    mem_kb: u64,
}

impl Values {
    /// 空きコア (コア数 - 1 分の負荷) を 0.1 の桁で。出力と同じ桁で比べる (同じに見える値を同じに扱う)。
    fn free_tenths(&self) -> i64 {
        tenths(f64::from(self.nproc) - self.load1_value)
    }

    /// 空きメモリ (GiB) を 0.1 の桁で。
    fn mem_tenths(&self) -> i64 {
        tenths(self.mem_kb as f64 / KIB_PER_GIB)
    }

    fn describe(&self) -> String {
        format!(
            "空きコア {} = {} コア - 1 分の負荷 {}・空きメモリ {} GiB",
            fmt_tenths(self.free_tenths()),
            self.nproc,
            self.load1,
            fmt_tenths(self.mem_tenths())
        )
    }

    fn short(&self) -> String {
        format!(
            "空きコア {}・空きメモリ {} GiB",
            fmt_tenths(self.free_tenths()),
            fmt_tenths(self.mem_tenths())
        )
    }
}

/// 子のマシンを自動で選ぶ。選べなければ、見た machine ごとのわけを並べて止まる (machine が 1 台も無ければ設定の誤り)。
pub(super) fn choose(
    hc: &Hc<'_>,
    auto: &Auto,
    repo: &str,
    account: &Account,
    chrome: bool,
) -> Result<Chosen> {
    let order: Vec<Kind> = if chrome {
        vec![Kind::Wsl]
    } else {
        auto.order.clone()
    };
    let listed = hc.json(&strings(&["machine", "ls", "--json"]))?;
    let mut seen: Vec<Seen> = listed["machines"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| {
            let name = m["name"].as_str()?.to_owned();
            Some(Seen {
                on: Some(name.clone()),
                name,
                kind: kind_of(
                    m["target"].as_str().unwrap_or_default(),
                    m["via"].as_bool() == Some(true),
                ),
                down: down_of(m),
                temporary: m["temporary"].as_bool() == Some(true),
            })
        })
        .collect();
    if order.contains(&Kind::Local) {
        seen.push(Seen {
            name: "local".to_owned(),
            on: None,
            kind: Kind::Local,
            down: None,
            temporary: false,
        });
    }
    if !seen.iter().any(|s| order.contains(&s.kind)) {
        let mut msg = format!(
            "子のマシンを自動で選べません (hc machine ls に {}ありません)。--on <machine> (local はこのマシン) で選ぶか、\
             {} に default_machine = \"<machine>\" のように書く",
            all_of(&order),
            auto.path
        );
        if order.contains(&Kind::Wsl) {
            msg.push_str(&format!(
                "。Windows のハブで手元の WSL を足すなら (名前は自由。ディストリビューションの名前は wsl.exe -l -v で見る):\n  {WSL_ADD}"
            ));
        }
        return Err(Error::config(msg));
    }

    let why = why_line(auto, &order, chrome);
    // order に無い種類の machine (見ない)
    let unlooked: Vec<String> = seen
        .iter()
        .filter(|s| !order.contains(&s.kind))
        .map(|s| {
            let why = if chrome {
                "--chrome の子は WSL から選ぶ"
            } else {
                "hub.toml の [auto] の order に無い"
            };
            format!("  - 見ていない {} ({}): {why}", s.name, s.kind.label())
        })
        .collect();
    // hc machine ls に無い exclude の名前 (綴りの誤りかもしれない。止めずに知らせる)
    let unknown: Vec<String> = auto
        .exclude
        .iter()
        .filter(|x| !seen.iter().any(|s| s.name == **x))
        .map(|x| format!("  - hub.toml の exclude の {x} は hc machine ls に無い (綴りを確かめる)"))
        .collect();
    let mut lines: Vec<String> = Vec::new();
    // 探り・アカウントで外した machine の文 (止まるときに、用意の手として出す)
    let mut details: Vec<String> = Vec::new();
    for (i, &kind) in order.iter().enumerate() {
        let mut ranked: Vec<(&Seen, Values)> = Vec::new();
        for s in seen.iter().filter(|s| s.kind == kind) {
            match screen(hc, auto, s) {
                Ok(v) => ranked.push((s, v)),
                Err(why) => lines.push(excluded(s, &why)),
            }
        }
        ranked.sort_by(|(a, va), (b, vb)| {
            vb.free_tenths()
                .cmp(&va.free_tenths())
                .then(vb.mem_kb.cmp(&va.mem_kb))
                .then(a.name.cmp(&b.name))
        });
        let mut rest = ranked.into_iter();
        let mut chosen = None;
        for (s, v) in rest.by_ref() {
            let m = s.on.as_deref();
            let got = probe(hc, m, repo).and_then(|pr| {
                // --repo の子は、checkout か ghq (無ければ取ってくる) が要る (無いと、選んだ後の worktree の用意で止まる)
                if !repo.is_empty() && pr.checkout.is_empty() && pr.ghq.is_empty() {
                    return Err(Error::failure(format!("{repo} の checkout も ghq も無い")));
                }
                account::ready(hc, m, &pr.claude, &pr.claude_account, account)
                    .map(|ready| (pr, ready))
            });
            match got {
                Ok((pr, ready)) => {
                    chosen = Some((s, v, pr, ready));
                    break;
                }
                Err(e) => {
                    lines.push(excluded(s, &headline(e.message())));
                    details.push(format!(
                        "  {} ({}):\n{}",
                        s.name,
                        s.kind.label(),
                        indent(e.message())
                    ));
                }
            }
        }
        let Some((s, v, pr, ready)) = chosen else {
            continue;
        };
        for (other, ov) in rest {
            lines.push(format!(
                "  - 次点 {} ({}): {}",
                other.name,
                kind.label(),
                ov.describe()
            ));
        }
        for later in &order[i + 1..] {
            for other in seen.iter().filter(|x| x.kind == *later) {
                lines.push(format!(
                    "  - 見ていない {} ({}): {}",
                    other.name,
                    later.label(),
                    ja(kind.label(), "から選んだ")
                ));
            }
        }
        let fallback = if i == 0 {
            String::new()
        } else {
            let tried: Vec<&str> = order[..i].iter().map(|k| k.label()).collect();
            format!("・使える {}", ja(&tried.join("・"), "が無い"))
        };
        let mut out = vec![
            format!(
                "子のマシンを自動で選んだ: {} ({}{fallback}・{})",
                s.name,
                kind.label(),
                v.describe()
            ),
            why,
        ];
        out.extend(lines);
        out.extend(unlooked);
        out.extend(unknown);
        if !details.is_empty() {
            out.push(
                "  (探り・アカウントの確かめで外した machine の細部は pjp child new --on <machine> --dry-run で出る)"
                    .to_owned(),
            );
        }
        return Ok(Chosen {
            machine: s.on.clone(),
            probe: pr,
            ready,
            lines: out,
            note: format!(
                "マシンは自動で {} ({}・{})",
                s.name,
                kind.label(),
                v.short()
            ),
        });
    }

    let mut msg = format!(
        "子のマシンを自動で選べません (使える {}ありません)\n{why}",
        all_of(&order)
    );
    for line in lines.iter().chain(&unlooked).chain(&unknown) {
        msg.push('\n');
        msg.push_str(line);
    }
    if !details.is_empty() {
        msg.push_str("\n探り・アカウントの確かめで外した machine の文:\n");
        msg.push_str(&details.join("\n"));
    }
    msg.push_str(&format!(
        "\n--on <machine> で選ぶか、{} の [auto] (order・exclude・min_free_cores・min_free_mem_gib) を直して打ち直す",
        auto.path
    ));
    Err(Error::failure(msg))
}

/// 「自動にしたわけ」の行 (見る順と、SSH 先を見るなら下限も)。
fn why_line(auto: &Auto, order: &[Kind], chrome: bool) -> String {
    let labels: Vec<&str> = order.iter().map(|k| k.label()).collect();
    let mut s = format!(
        "  自動にしたわけ: {}。見る順: {}",
        auto.why,
        labels.join(" → ")
    );
    if chrome {
        s.push_str(" (--chrome の子は WSL から選ぶ)");
    }
    if order.contains(&Kind::Ssh) {
        s.push_str(&format!(
            "。SSH 先の下限: 空きコア {}・空きメモリ {} GiB",
            fmt_min(auto.min_cores),
            fmt_min(auto.min_mem_gib)
        ));
    }
    s
}

/// 「外した」の行。
fn excluded(s: &Seen, why: &str) -> String {
    format!("  - 外した {} ({}): {why}", s.name, s.kind.label())
}

/// machine を測り、使えるか (Linux か・下限を越えるか) を見る。使えなければ、そのわけ。
fn screen(hc: &Hc<'_>, auto: &Auto, s: &Seen) -> std::result::Result<Values, String> {
    if auto.exclude.contains(&s.name) {
        return Err("hub.toml の exclude にある".to_owned());
    }
    if s.temporary {
        return Err("一時の machine (temporary)".to_owned());
    }
    if let Some(down) = &s.down {
        return Err(format!("connected でない ({down})"));
    }
    let out = hc
        .exec(
            s.on.as_deref(),
            None,
            MEASURE_TIMEOUT,
            &["sh", "-c", MEASURE, "sh"],
        )
        .map_err(|e| format!("測れない ({})", first_line(e.message())))?;
    if !out.ok() {
        return Err(format!("測れない ({})", out.why()));
    }
    let (os, values) = read_measure(&out.stdout);
    if os != "Linux" {
        return Err(if os.is_empty() {
            "Linux でない (uname -s が空)".to_owned()
        } else {
            format!("Linux でない ({os})")
        });
    }
    let v = values?;
    if s.kind.has_floor() {
        let mut short = Vec::new();
        if v.free_tenths() < tenths(auto.min_cores) {
            short.push(format!(
                "空きコア {} が下限の {} より少ない",
                fmt_tenths(v.free_tenths()),
                fmt_min(auto.min_cores)
            ));
        }
        if v.mem_tenths() < tenths(auto.min_mem_gib) {
            short.push(format!(
                "空きメモリ {} GiB が下限の {} GiB より少ない",
                fmt_tenths(v.mem_tenths()),
                fmt_min(auto.min_mem_gib)
            ));
        }
        if !short.is_empty() {
            return Err(short.join("・"));
        }
    }
    Ok(v)
}

/// 測る script の出力を読む: OS (`uname -s`。読めなければ空) と、測った値 (足りなければ、そのわけ)。
fn read_measure(stdout: &str) -> (String, std::result::Result<Values, String>) {
    let mut os = String::new();
    let mut nproc = None;
    let mut load = None;
    let mut mem_kb = None;
    for line in stdout.lines() {
        match line.split_once('=') {
            Some(("os", v)) => v.trim().clone_into(&mut os),
            Some(("nproc", v)) => nproc = v.trim().parse::<u32>().ok().filter(|n| *n > 0),
            Some(("loadavg", v)) => {
                load = v.split_whitespace().next().and_then(|f| {
                    f.parse::<f64>()
                        .ok()
                        .filter(|x| x.is_finite() && *x >= 0.0)
                        .map(|x| (f.to_owned(), x))
                });
            }
            Some(("memavail_kb", v)) => mem_kb = v.trim().parse::<u64>().ok(),
            _ => {}
        }
    }
    let values = match (nproc, load, mem_kb) {
        (Some(nproc), Some((load1, load1_value)), Some(mem_kb)) => Ok(Values {
            nproc,
            load1,
            load1_value,
            mem_kb,
        }),
        (nproc, load, mem_kb) => {
            let missing: Vec<&str> = [
                (nproc.is_none(), "nproc"),
                (load.is_none(), "/proc/loadavg"),
                (mem_kb.is_none(), "MemAvailable"),
            ]
            .into_iter()
            .filter_map(|(gone, what)| gone.then_some(what))
            .collect();
            Err(format!(
                "測った値を読めない ({})",
                ja(&missing.join("・"), "が無い")
            ))
        }
    };
    (os, values)
}

/// 0.1 の桁の整数にする (6.66 → 67)。
fn tenths(x: f64) -> i64 {
    (x * 10.0).round() as i64
}

/// 0.1 の桁の整数を小数 1 桁で (67 → `6.7`・-3 → `-0.3`)。
fn fmt_tenths(t: i64) -> String {
    format!("{:.1}", t as f64 / 10.0)
}

/// 下限の値 (整数なら小数を付けない: 4 → `4`・8.5 → `8.5`)。
fn fmt_min(x: f64) -> String {
    let t = tenths(x);
    if t % 10 == 0 {
        (t / 10).to_string()
    } else {
        fmt_tenths(t)
    }
}

/// 種類の名前・語と、後ろに続く仮名をつなぐ (英数字で終わる語の後ろには半角の空白を挟む: `WSL から`・`SSH 先から`)。
fn ja(word: &str, rest: &str) -> String {
    if word
        .chars()
        .last()
        .is_some_and(|c| c.is_ascii_alphanumeric())
    {
        format!("{word} {rest}")
    } else {
        format!("{word}{rest}")
    }
}

/// 種類を「SSH 先も WSL も」「SSH 先が」の形に (「…ありません」の前)。英数字で始まる語の前にだけ半角の空白を挟む
/// (`SSH 先も WSL もこのマシンも`)。
fn all_of(order: &[Kind]) -> String {
    match order {
        [one] => ja(one.label(), "が"),
        many => {
            let mut s = String::new();
            for k in many {
                let word = ja(k.label(), "も");
                if !s.is_empty() && word.starts_with(|c: char| c.is_ascii_alphanumeric()) {
                    s.push(' ');
                }
                s.push_str(&word);
            }
            s
        }
    }
}

/// 止まったわけの見出し: 1 行目の最初の文 (括弧の外の「。」まで)。後ろに続く手の案内 (「次の…をしてから打ち直す:」) や
/// claude-account の答えの前置き (「…の答え (終了コード 1):」) は、選べたときの行には出さない (止まるときの文に全部出す)。
fn headline(msg: &str) -> String {
    let line = first_line(msg);
    let mut depth = 0i32;
    for (i, c) in line.char_indices() {
        match c {
            '(' | '（' => depth += 1,
            ')' | '）' => depth -= 1,
            '。' if depth <= 0 => return line[..i].to_owned(),
            _ => {}
        }
    }
    line.to_owned()
}

/// 行ごとに 4 字下げる。
fn indent(text: &str) -> String {
    text.lines()
        .map(|l| {
            if l.trim().is_empty() {
                String::new()
            } else {
                format!("    {l}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_is_wsl_when_the_via_command_is_wsl_exe() {
        for target in [
            "wsl.exe -d wsl1 --cd ~ -e bash -lc",
            "WSL.EXE -d wsl1 -e sh -c",
            "wsl -d Ubuntu -e sh -c",
            r"C:\Windows\System32\wsl.exe -d wsl1 -e sh -c",
            r#""C:\Program Files\WSL\wsl.exe" -d wsl1 -e sh -c"#,
            "'/mnt/c/Windows/System32/wsl.exe' -d wsl1",
            "  wsl.exe -d wsl1",
        ] {
            assert_eq!(kind_of(target, true), Kind::Wsl, "{target}");
            // --via でない machine の target は ssh の行き先 (Host が wsl でも SSH 先)
            assert_eq!(kind_of(target, false), Kind::Ssh, "{target}");
        }
        assert_eq!(kind_of("wsl", false), Kind::Ssh);
        for target in [
            "ssh -p 2222 host-a.local",
            "wsl.example.com",
            "my-wsl.exe-host",
            r#""C:\Program Files\OpenSSH\ssh.exe" box"#,
            "",
        ] {
            assert_eq!(kind_of(target, true), Kind::Ssh, "{target}");
        }
        for target in ["host-a.local", "pjp@host-a.local"] {
            assert_eq!(kind_of(target, false), Kind::Ssh, "{target}");
        }
    }

    #[test]
    fn read_measure_takes_the_one_minute_load() {
        let (os, v) = read_measure(
            "os=Linux\nnproc=8\nloadavg=1.30 5.66 7.03 2/345 6789\nmemavail_kb=8388608\n",
        );
        assert_eq!(os, "Linux");
        let v = v.unwrap();
        assert_eq!(
            (v.nproc, v.load1.as_str(), v.mem_kb),
            (8, "1.30", 8_388_608)
        );
        assert_eq!((v.free_tenths(), v.mem_tenths()), (67, 80));
        assert_eq!(
            v.describe(),
            "空きコア 6.7 = 8 コア - 1 分の負荷 1.30・空きメモリ 8.0 GiB"
        );
        assert_eq!(v.short(), "空きコア 6.7・空きメモリ 8.0 GiB");
        // 負荷がコア数を超えると、空きコアは負になる
        let (_, v) = read_measure("os=Linux\nnproc=4\nloadavg=4.30 4 4\nmemavail_kb=1\n");
        assert_eq!(v.unwrap().free_tenths(), -3);
    }

    #[test]
    fn read_measure_names_what_is_missing() {
        let (os, v) = read_measure("os=Linux\nnproc=2\n");
        assert_eq!(os, "Linux");
        assert_eq!(
            v.unwrap_err(),
            "測った値を読めない (/proc/loadavg・MemAvailable が無い)"
        );
        let (os, v) = read_measure("os=\nnproc=0\nloadavg=x\nmemavail_kb=\n");
        assert_eq!(os, "");
        assert_eq!(
            v.unwrap_err(),
            "測った値を読めない (nproc・/proc/loadavg・MemAvailable が無い)"
        );
    }

    #[test]
    fn numbers_and_japanese_spacing() {
        assert_eq!(fmt_tenths(103), "10.3");
        assert_eq!(fmt_tenths(-3), "-0.3");
        assert_eq!(fmt_tenths(0), "0.0");
        assert_eq!(fmt_min(4.0), "4");
        assert_eq!(fmt_min(8.5), "8.5");
        assert_eq!(fmt_min(0.0), "0");
        // 0.1 の桁で丸める (浮動小数の 8 - 7.9 = 0.0999… も 0.1)
        assert_eq!(tenths(8.0 - 7.9), 1);
        assert_eq!(ja("WSL", "から選んだ"), "WSL から選んだ");
        assert_eq!(ja("SSH 先", "から選んだ"), "SSH 先から選んだ");
        assert_eq!(all_of(&[Kind::Ssh, Kind::Wsl]), "SSH 先も WSL も");
        assert_eq!(
            all_of(&[Kind::Ssh, Kind::Wsl, Kind::Local]),
            "SSH 先も WSL もこのマシンも"
        );
        assert_eq!(all_of(&[Kind::Local, Kind::Wsl]), "このマシンも WSL も");
        assert_eq!(all_of(&[Kind::Ssh]), "SSH 先が");
        assert_eq!(all_of(&[Kind::Wsl]), "WSL が");
    }

    #[test]
    fn headline_drops_the_fix_list() {
        assert_eq!(
            headline(
                "子のマシン (host-a) に claude-work がありません (PATH にも無い)。次のどちらかをしてから打ち直す:\n  - a\n  - b"
            ),
            "子のマシン (host-a) に claude-work がありません (PATH にも無い)"
        );
        assert_eq!(
            headline("子のマシン (host-a) を探れません: x"),
            "子のマシン (host-a) を探れません: x"
        );
        // claude-account の答えの前置き (コロンで終わる) と、思わぬ終わり方の「…戻らずに止まる」は出さない
        assert_eq!(
            headline(
                "子のマシン (host-a) の claude-work は用意ができていません。claude-account check work の答え (終了コード 1):\n    手"
            ),
            "子のマシン (host-a) の claude-work は用意ができていません"
        );
        assert_eq!(
            headline(
                "子のマシン (host-a) の claude-account check work が思わぬ終わり方をしました (60 秒で時間切れ)。用意のファイルの有る無しの見分けには戻らずに止まる。"
            ),
            "子のマシン (host-a) の claude-account check work が思わぬ終わり方をしました (60 秒で時間切れ)"
        );
        // 括弧の中の「。」では切らない
        assert_eq!(headline("a (b。c) d。e"), "a (b。c) d");
    }

    /// 測る script を本物の sh で流す (Linux の CI とこのマシン)。
    #[cfg(target_os = "linux")]
    #[test]
    fn measure_script_runs_in_real_sh() {
        let out = std::process::Command::new("sh")
            .args(["-c", MEASURE, "sh"])
            .output()
            .unwrap();
        assert!(out.status.success(), "{out:?}");
        let stdout = String::from_utf8(out.stdout).unwrap();
        let (os, v) = read_measure(&stdout);
        assert_eq!(os, "Linux", "{stdout}");
        let v = v.unwrap_or_else(|e| panic!("{e}\n{stdout}"));
        assert!(v.nproc >= 1, "{stdout}");
        assert!(v.mem_kb > 0, "{stdout}");
    }
}
