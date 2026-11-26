//! port-forward (order 99): dotfiles-private の `ssh/port-forward.toml` (ssh の Host 名ごとの port forwarding の組) を JSON にして、
//! `%USERPROFILE%\.config\port-forward\hosts.json` に置く。WSL の `nix/scripts/bootstrap-windows-port-forward.sh` を写したもの (確かめ・書く中身・
//! 書く先・記録・判定と退避をそろえる。受け持ちを runner に切り替えた後に、WSL の setup が置いたものを同じものとして引き継ぐため)。
//!
//! PowerShell 7 のコマンド pf (`win/port-forward/Start-PortForward.ps1`) は、ssh の Host を選んだ次の画面にこの組を出す。その PC で足した組は pf が
//! 同じ場所の `local.json` に持ち、この手順は触らない。
//!
//! - 正本は dotfiles-private の clone (runner の clone の隣か bootstrap の置き場。`Ctx::sibling`) の `ssh/port-forward.toml`。無ければ何も書かない
//!   (置いてある hosts.json も消さない)。WSL は Nix の `builtins.fromTOML` で読むが、Windows には Nix が無いので、runner は toml の crate で読む
//!   (TOML 1.1。Nix が止める `\e` などを通すのは win/manifest.toml と同じ)
//! - 確かめ (WSL の jq と同じ決まりと文): 最上位のキーは `hosts` だけ・Host 名は空でなく空白と `* ? !` を含まず `-` で始まらない・値は文字列の配列・
//!   組は `<手元の port>[:[<つなぎ先>:]<向こうの port>][ <メモ>]` (port は 1〜65535。pf の ConvertFrom-PortSpec と同じ)・同じ Host の中で手元の port
//!   が重ならない。誤りがあれば何も書かずに全部を並べる (failed)
//! - 書く中身は `{"version":1,"note":…,"hosts":{…}}` を jq の `--indent 2` と同じ形で (Host 名はバイト列の順・組は前後の空白だけ落とす・文字列は jq と
//!   同じ逃がし方)。WSL が書いた hosts.json とバイト列までそろう (試験が bash の版と突き合わせる)
//! - 判定は files・ssh-config と同じ (`deploy::judge`)。衝突は diff を出して触らず、`--force` なら元を `hosts.json.dotfiles-bak-<日時>` に退避して
//!   上書きする
//! - 記録は `%LOCALAPPDATA%\dotfiles\state\windows-port-forward.deployed.json` (`{"version":1,"files":{"hosts.json":"<sha256>"}}`。WSL の
//!   `~/.local/state/dotfiles/` の記録と同じ名前・形・鍵。`record::FileRecords`)。WSL の記録は読まない: 切り替えた後の初めての apply は、WSL が
//!   置いた hosts.json を「同じ」と見て記録だけ作る

use super::deploy::{self, Action, Problem, Tally};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::jv::jq_string;
use crate::record::FileRecords;
use crate::report::Kind;
use std::path::Path;

/// 記録のファイル名 (WSL の `~/.local/state/dotfiles/` の記録と同じ名前)
pub const RECORD_FILE: &str = "windows-port-forward.deployed.json";
/// 記録の鍵 (WSL と同じ)
const KEY: &str = "hosts.json";
/// 置き先 (ホームからの相対)
const DST: &str = ".config/port-forward/hosts.json";
/// hosts.json の `note` (WSL の script の `note` と同じ字。書く中身に入るので、変えると WSL が置いたものと揃わない)
const NOTE: &str = "dotfiles の nix/scripts/bootstrap-windows-port-forward.sh が dotfiles-private の ssh/port-forward.toml から書く。手で直すと次の setup で衝突になる。この PC だけの組は pf の画面で足す (local.json に残る)";
/// 記録が壊れていたときの直し方 (WSL と同じ)
const BROKEN_HINT: &str = "消してから流し直すと、Windows 側に既にある hosts.json は衝突として扱われます (中身を確かめて、dotfiles-private へ取り込むか --force)";

pub struct PortForward;

impl Step for PortForward {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "port-forward",
            order: 99,
            title: "dotfiles-private の port forwarding の組を JSON にして置く",
            gate: Gate::Always,
            ported: true,
            windows_only: false,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        vec![sync(ctx, mode)]
    }
}

/// 確かめた組 (Host 名はバイト列の順。組は前後の空白を落としたもの)。
type Hosts = Vec<(String, Vec<String>)>;

/// 手順の中身。WSL の script と同じ順に確かめる (正本 → 記録 → 正本を読んで確かめる → 判定)。
fn sync(ctx: &mut Ctx, mode: Mode) -> Outcome {
    let src = ctx
        .sibling("dotfiles-private")
        .join("ssh")
        .join("port-forward.toml");
    if !src.is_file() {
        ctx.say(format!(
            "port forwarding の組の正本がないので、Windows へは写しません ({})。",
            src.display()
        ));
        return Outcome::new(
            Kind::Info,
            "正本 (dotfiles-private の ssh/port-forward.toml) が無いので写さない (置いてある hosts.json はそのまま)",
        );
    }
    let record_path = ctx.state_dir.join(RECORD_FILE);
    let mut records = match FileRecords::load(&record_path, BROKEN_HINT) {
        Ok(r) => r,
        Err(e) => {
            ctx.say(format!("!! {e}"));
            return Outcome::new(Kind::Failed, "配った記録が壊れている").note(e);
        }
    };
    let hosts = match read_source(&src) {
        Ok(h) => h,
        Err(SourceError::Unreadable(lines)) => {
            ctx.say(format!(
                "!! {} を TOML として読めませんでした。何も書いていません:",
                src.display()
            ));
            for l in &lines {
                ctx.say(format!("   {l}"));
            }
            let mut o = Outcome::new(
                Kind::Failed,
                "正本 (ssh/port-forward.toml) を TOML として読めない (何も書いていない)",
            );
            o.notes = lines;
            return o;
        }
        Err(SourceError::Invalid(errors)) => {
            ctx.say(format!(
                "!! {} に誤りがあります。何も書いていません:",
                src.display()
            ));
            for e in &errors {
                ctx.say(format!("   {e}"));
            }
            let mut o = Outcome::new(
                Kind::Failed,
                format!(
                    "正本 (ssh/port-forward.toml) に誤りがある ({} 件。何も書いていない)",
                    errors.len()
                ),
            );
            o.notes = errors;
            return o;
        }
    };
    let bytes = render(&hosts).into_bytes();
    let counts = counts(&hosts);
    let dst = join_segments(&ctx.roots.user_profile, DST);
    let shown = dst.display().to_string();
    let want = fsutil::sha256_bytes(&bytes);
    let recorded = records.get(KEY).map(str::to_string);
    let mut tally = Tally::default();
    let action = match deploy::judge(
        &dst,
        &want,
        recorded.as_deref(),
        mode.force(),
        &deploy::never,
    ) {
        Ok(a) => Some(a),
        Err(Problem::Directory) => {
            ctx.say(format!("!! 置き先がディレクトリです: {shown}"));
            tally.errors += 1;
            None
        }
        Err(Problem::Unreadable(e)) => {
            ctx.say(format!("!! 置き先が読めません: {shown} ({e})"));
            tally.errors += 1;
            None
        }
    };
    let mut save = false;
    match action {
        None => {}
        Some(Action::Same) => {
            tally.count(Action::Same);
            ctx.say(format!("同じです: {shown}"));
            save = true;
        }
        Some(Action::Conflict) => {
            tally.count(Action::Conflict);
            if recorded.is_some() {
                ctx.say(format!(
                    "!! 衝突: {shown} は Windows 側で変わっています (前回ここへ置いた中身と違う)。"
                ));
            } else {
                ctx.say(format!(
                    "!! 衝突: {shown} は、置いた記録が無く、正本と中身が違います (置く前から Windows 側にあった。手で書いたものなど。受け持ちを切り替える前なら、WSL が置いた中身とこの dotfiles-private の clone の中身が違う)。"
                ));
            }
            deploy::show_diff_bytes(ctx, &dst, &bytes, KEY);
            ctx.say("   Windows 側の中身を残すなら: dotfiles-private の ssh/port-forward.toml へ取り込み、commit して push する (その PC だけの組は、pf の画面で足すと local.json に残る)");
            let again = deploy::force_command(ctx, "port-forward");
            ctx.say(format!(
                "   正本で上書きするなら:   {again} (元は hosts.json.dotfiles-bak-<日時> に残る)"
            ));
        }
        Some(action) => {
            let label = match action {
                Action::Copy => format!("新しく置く ({counts})"),
                Action::Update | Action::Replace => "上書き (正本が更新された)".to_string(),
                _ => "上書き (--force)".to_string(),
            };
            match mode {
                Mode::Check => ctx.say(format!(
                    "{}: {shown}",
                    if action == Action::Copy {
                        "無い (apply で置く)"
                    } else {
                        "正本が更新された (apply で上書きする)"
                    }
                )),
                Mode::DryRun { .. } => ctx.say(format!("[dry-run] {label}: {shown}")),
                Mode::Apply { .. } => match deploy::write(&dst, &bytes, action == Action::Force) {
                    Ok(bak) => {
                        ctx.say(format!("{label}: {shown}"));
                        if let Some(bak) = bak {
                            ctx.say(format!("  退避した: {}", bak.display()));
                        }
                        save = true;
                    }
                    Err(e) => {
                        ctx.say(format!("!! 書けません: {shown} ({e})"));
                        tally.errors += 1;
                    }
                },
            }
            if tally.errors == 0 {
                tally.count(action);
            }
        }
    }
    // 記録は、揃っている・書いたときだけ (WSL の save_record。衝突では書かない)
    if save && mode.writes() {
        records.set(KEY, &want);
        if let Err(e) = records.save_if_changed() {
            ctx.say(format!(
                "!! 配った記録を書けません: {} ({e})",
                record_path.display()
            ));
            tally.errors += 1;
        }
    }

    let summary = format!("{} ({counts})", tally.summary(mode, false));
    ctx.say("");
    ctx.say(&summary);
    let mut outcome = Outcome::new(tally.kind(mode), summary);
    if tally.conflicts > 0 {
        outcome = outcome.note(deploy::conflict_note(
            ctx,
            "port-forward",
            "Windows 側の中身を dotfiles-private の ssh/port-forward.toml へ取り込む",
            "この dotfiles-private の clone",
        ));
    }
    outcome
}

/// 正本を読めなかったわけ。
#[derive(Debug, PartialEq)]
enum SourceError {
    /// ファイルか TOML として読めない (わけの行)
    Unreadable(Vec<String>),
    /// 決まりに合わない (WSL の jq と同じ文を、出てくる順に)
    Invalid(Vec<String>),
}

fn read_source(src: &Path) -> Result<Hosts, SourceError> {
    let text =
        std::fs::read_to_string(src).map_err(|e| SourceError::Unreadable(vec![e.to_string()]))?;
    let table: toml::Table = text
        .parse()
        .map_err(|e: toml::de::Error| SourceError::Unreadable(toml_error_lines(&e)))?;
    check_source(&table).map_err(SourceError::Invalid)
}

/// toml の誤りの文から、位置の印の行 (`  |`・`1 | …`・`^`) を除いた行 (どこの何が誤りか)。
fn toml_error_lines(e: &toml::de::Error) -> Vec<String> {
    e.to_string()
        .lines()
        .map(str::trim)
        .filter(|l| {
            !l.is_empty()
                && !l.starts_with('|')
                && !l
                    .split_once(" |")
                    .is_some_and(|(n, _)| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        })
        .map(str::to_string)
        .collect()
}

/// 正本を確かめて組を取り出す (WSL の `jq_errors` と同じ決まり・文・順。キーは Nix の attrset と同じくバイト列の順に見る)。
fn check_source(table: &toml::Table) -> Result<Hosts, Vec<String>> {
    let mut errors = Vec::new();
    for key in sorted_keys(table) {
        if key != "hosts" {
            errors.push(format!(
                "知らないキーがあります: {key} (書けるのは [hosts] の表だけ)"
            ));
        }
    }
    let hosts = match table.get("hosts") {
        None => {
            errors.push("[hosts] の表がありません".to_string());
            return Err(errors);
        }
        Some(toml::Value::Table(t)) => t,
        Some(_) => {
            errors.push("hosts は表にする ([hosts] の下に Host 名 = [\"3000\", …])".to_string());
            return Err(errors);
        }
    };
    let mut found = Vec::new();
    for host in sorted_keys(hosts) {
        if host.is_empty() {
            errors.push("Host 名が空です".to_string());
        } else if host
            .chars()
            .any(|c| c.is_whitespace() || matches!(c, '*' | '?' | '!'))
        {
            errors.push(format!("Host 名に空白・* ? ! は使えません: {host}"));
        } else if host.starts_with('-') {
            errors.push(format!("Host 名は - で始められません: {host}"));
        }
        let items = match &hosts[host] {
            toml::Value::Table(_) => {
                errors.push(format!(
                    "{host}: 値が配列ではありません (Host 名に . を含むなら \"…\" で囲む。囲まないと TOML の入れ子の表になる)"
                ));
                continue;
            }
            toml::Value::Array(items) => items,
            _ => {
                errors.push(format!("{host}: 値は文字列の配列にする"));
                continue;
            }
        };
        let mut specs = Vec::new();
        let mut locals = Vec::new();
        for (i, item) in items.iter().enumerate() {
            let toml::Value::String(s) = item else {
                errors.push(format!(
                    "{host}: {} 番目が文字列ではありません: {}",
                    i + 1,
                    to_json(item)
                ));
                continue;
            };
            match parse_spec(s) {
                None => errors.push(format!("{host}: 書き方が違います: {s}")),
                Some((l, r)) if !in_range(l) || !in_range(r.unwrap_or(l)) => {
                    errors.push(format!("{host}: port は 1〜65535 で書いてください: {s}"));
                }
                Some((l, _)) => locals.push(l.parse::<u32>().unwrap_or(0)),
            }
            specs.push(s.trim_matches(char::is_whitespace).to_string());
        }
        locals.sort_unstable();
        let mut dups: Vec<u32> = locals
            .windows(2)
            .filter(|w| w[0] == w[1])
            .map(|w| w[0])
            .collect();
        dups.dedup();
        for d in dups {
            errors.push(format!("{host}: 手元の port が重なっています: {d}"));
        }
        found.push((host.clone(), specs));
    }
    if errors.is_empty() {
        Ok(found)
    } else {
        Err(errors)
    }
}

/// 表のキーをバイト列の順に (Nix の attrset と jq が出す順)。
fn sorted_keys(t: &toml::Table) -> Vec<&String> {
    let mut keys: Vec<&String> = t.keys().collect();
    keys.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    keys
}

/// 誤りの文に出す値 (jq の tojson に当たるもの)。
fn to_json(v: &toml::Value) -> String {
    fn conv(v: &toml::Value) -> serde_json::Value {
        match v {
            toml::Value::String(s) => serde_json::Value::String(s.clone()),
            toml::Value::Integer(i) => serde_json::Value::from(*i),
            toml::Value::Float(f) => serde_json::Number::from_f64(*f)
                .map(serde_json::Value::Number)
                .unwrap_or(serde_json::Value::Null),
            toml::Value::Boolean(b) => serde_json::Value::Bool(*b),
            toml::Value::Datetime(d) => serde_json::Value::String(d.to_string()),
            toml::Value::Array(items) => serde_json::Value::Array(items.iter().map(conv).collect()),
            toml::Value::Table(t) => {
                serde_json::Value::Object(t.iter().map(|(k, v)| (k.clone(), conv(v))).collect())
            }
        }
    }
    conv(v).to_string()
}

/// port の字が 1〜65535 か (WSL の `in_range`。頭の 0 は数として読む)。
fn in_range(p: &str) -> bool {
    p.parse::<u32>().is_ok_and(|n| (1..=65535).contains(&n))
}

/// 組の書き方 (WSL の `spec_re` と pf の ConvertFrom-PortSpec と同じ:
/// `^\s*(?<l>[0-9]{1,5})(?::(?:(?<h>\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+):)?(?<r>[0-9]{1,5}))?(?:\s+(?<m>.*?))?\s*$`)。合えば手元の port と、書いてあれば
/// 向こうの port の字。`\s` は jq (Oniguruma) と同じく Unicode の空白、`.` は改行のほかの 1 字、`^`・`$` は文字列の頭と終わり。
fn parse_spec(s: &str) -> Option<(&str, Option<&str>)> {
    let rest = s.trim_start_matches(char::is_whitespace);
    let (l, rest) = digits(rest)?;
    let Some(after) = rest.strip_prefix(':') else {
        return tail_ok(rest).then_some((l, None));
    };
    // つなぎ先を書いた形 (`<つなぎ先>:<向こうの port>`) を先に、書かない形 (`<向こうの port>`) を後に試す (regex の `?` と同じ順)
    if let Some(n) = host_len(after)
        && let Some(after_host) = after[n..].strip_prefix(':')
        && let Some((r, rest)) = digits(after_host)
        && tail_ok(rest)
    {
        return Some((l, Some(r)));
    }
    let (r, rest) = digits(after)?;
    tail_ok(rest).then_some((l, Some(r)))
}

/// 頭の ASCII の数字 1〜5 字と、その後ろ (6 字以上続くなら合わない: 後ろに数字が残り、続きの形に合わない)。
fn digits(s: &str) -> Option<(&str, &str)> {
    let n = s.bytes().take_while(u8::is_ascii_digit).count();
    (1..=5).contains(&n).then(|| s.split_at(n))
}

/// 頭のつなぎ先 (`[` と `]` で囲んだ IPv6 か、`A-Za-z0-9._-` の並び) の長さ。
fn host_len(s: &str) -> Option<usize> {
    if let Some(inner) = s.strip_prefix('[') {
        let n = inner
            .bytes()
            .take_while(|b| b.is_ascii_hexdigit() || matches!(b, b':' | b'.'))
            .count();
        (n > 0 && inner[n..].starts_with(']')).then_some(n + 2)
    } else {
        let n = s
            .bytes()
            .take_while(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
            .count();
        (n > 0).then_some(n)
    }
}

/// 組の後ろ (`(?:\s+(?<m>.*?))?\s*$`) に合うか: 空白だけか、空白で始まり、前後の空白を除いた中身 (メモ) に改行が無い。
fn tail_ok(rest: &str) -> bool {
    rest.chars().all(char::is_whitespace)
        || (rest.starts_with(char::is_whitespace)
            && !rest.trim_matches(char::is_whitespace).contains('\n'))
}

/// hosts.json の中身 (WSL の `jq --indent 2 --arg note … '{version: 1, note: $note, hosts: …}'` と同じバイト列)。
fn render(hosts: &Hosts) -> String {
    let mut s = String::from("{\n  \"version\": 1,\n  \"note\": ");
    s.push_str(&jq_string(NOTE));
    s.push_str(",\n  \"hosts\": ");
    if hosts.is_empty() {
        s.push_str("{}");
    } else {
        s.push_str("{\n");
        for (i, (host, specs)) in hosts.iter().enumerate() {
            if i > 0 {
                s.push_str(",\n");
            }
            s.push_str("    ");
            s.push_str(&jq_string(host));
            s.push_str(": ");
            if specs.is_empty() {
                s.push_str("[]");
                continue;
            }
            s.push_str("[\n");
            for (j, spec) in specs.iter().enumerate() {
                if j > 0 {
                    s.push_str(",\n");
                }
                s.push_str("      ");
                s.push_str(&jq_string(spec));
            }
            s.push_str("\n    ]");
        }
        s.push_str("\n  }");
    }
    s.push_str("\n}\n");
    s
}

/// Host と組の数 (WSL の counts と同じ字)。
fn counts(hosts: &Hosts) -> String {
    let pairs: usize = hosts.iter().map(|(_, specs)| specs.len()).sum();
    format!("Host {} 件・組 {pairs} 件", hosts.len())
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (WSL の nix/tests/bootstrap-windows-port-forward.test.sh と同じケースに、受け持ちで替える案内を足したもの)
    //!
    //! - 正本 (dotfiles-private の ssh/port-forward.toml) が無ければ、何も書かず消さずに · で知らせる
    //! - 初めは hosts.json (version・note・hosts。日本語のメモはそのまま・組の前後の空白は落とす。jq の --indent 2 の形) と記録を書く。2 回目は同じ
    //! - 正本の更新 (置き先が記録どおり) は上書きする。Windows で直したものと、置く前からあったものは衝突 (触らない・diff と解き方。記録の有無で文を
    //!   分ける)。記録が無く中身が同じなら記録だけ。--force は退避して上書き、check と dry-run は何も書かない
    //! - 正本の誤り (hosts の外のキー・hosts が無い / 表でない・値が配列でない (. の Host 名を囲み忘れた入れ子の表を含む)・文字列でない要素・書き方の
    //!   誤り・port の範囲・同じ手元の port・Host 名の空白・ワイルドカード・- の頭・全角の数字) は、何も書かずに全部を並べる。TOML として読めないときも
    //! - 組の書き方の読み取りが WSL の正規表現と同じ (つなぎ先・IPv6・メモ・空白と改行の扱い)・文字列の逃がし方が jq と同じ
    //! - 壊れた記録・ディレクトリの置き先は止める。受け持ちが WSL のホストでは、衝突の解き方に WSL の script の --force を出す
    //! - 順番・on/off・note・記録の名前が WSL の script と同じ
    //! - WSL の script (本物の nix-instantiate と jq) と同じ正本から、同じバイト列の hosts.json と記録を書き、誤りの文も同じ。WSL の script が置いた
    //!   hosts.json を、記録の無い runner が変えずに引き継ぐ (bash・jq・nix-instantiate がある Linux)

    use super::*;
    use crate::hooks::parity;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::process::{Exit, RunResult};
    use crate::testutil::{FakeSys, TempDir};
    use std::path::PathBuf;

    const RUNNER_HOST: &str = "[runner]\nenable = true\n";
    const WSL_HOST: &str = "group = \"minimum\"\n";
    const APPLY: Mode = Mode::Apply { force: false };
    const OK_TOML: &str = "[hosts]\nexample-a = [\"3000\", \"8080 api\"]\nexample-b = [\" 15432:db:5432  ポスグレ \"]\n";

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new(toml: Option<&str>) -> Self {
            let t = TempDir::new("port-forward");
            std::fs::create_dir_all(t.path().join("dotfiles")).unwrap();
            std::fs::create_dir_all(t.path().join("dotfiles-private").join("ssh")).unwrap();
            let e = Env { t };
            if let Some(s) = toml {
                e.set_toml(s);
            }
            e
        }

        fn set_toml(&self, s: &str) {
            self.t.write("dotfiles-private/ssh/port-forward.toml", s);
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        fn dst(&self) -> PathBuf {
            join_segments(&self.home(), DST)
        }

        fn read(&self) -> String {
            std::fs::read_to_string(self.dst()).unwrap()
        }

        fn put(&self, s: &str) {
            std::fs::create_dir_all(self.dst().parent().unwrap()).unwrap();
            std::fs::write(self.dst(), s).unwrap();
        }

        fn record(&self) -> PathBuf {
            self.t.path().join("state").join(RECORD_FILE)
        }

        fn recorded(&self) -> Option<String> {
            let text = std::fs::read_to_string(self.record()).ok()?;
            let v: serde_json::Value = serde_json::from_str(&text).unwrap();
            v["files"][KEY].as_str().map(str::to_string)
        }

        fn baks(&self) -> Vec<PathBuf> {
            let mut found: Vec<PathBuf> = std::fs::read_dir(self.dst().parent().unwrap())
                .map(|es| {
                    es.flatten()
                        .map(|e| e.path())
                        .filter(|p| {
                            p.file_name()
                                .unwrap()
                                .to_string_lossy()
                                .starts_with("hosts.json.dotfiles-bak-")
                        })
                        .collect()
                })
                .unwrap_or_default();
            found.sort();
            found
        }

        fn run(&self, host: &str, mode: Mode) -> (Outcome, String) {
            let sys = FakeSys::new(|c| RunResult {
                exit: Exit::Code(1),
                output: vec![format!("diff {}", c.args_lossy().join(" "))],
            })
            .with_program("git", "/fake/git");
            let mut out = Vec::new();
            let mut outcomes = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.t.path().join("state"),
                    host: parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                    sys: &sys,
                    out: &mut out,
                };
                PortForward.run(&mut ctx, mode)
            };
            let out = String::from_utf8(out).unwrap();
            assert_eq!(outcomes.len(), 1, "{outcomes:?}\n{out}");
            (outcomes.remove(0), out)
        }

        fn apply(&self) -> (Outcome, String) {
            self.run(RUNNER_HOST, APPLY)
        }
    }

    fn has_note(o: &Outcome, part: &str) -> bool {
        o.notes.iter().any(|n| n.contains(part))
    }

    fn hosts_of(toml: &str) -> Result<Hosts, Vec<String>> {
        check_source(&toml.parse::<toml::Table>().unwrap())
    }

    #[test]
    fn without_source_writes_nothing() {
        let e = Env::new(None);
        e.put("old\n");
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Info, "{out}");
        assert!(
            out.contains("port forwarding の組の正本がないので、Windows へは写しません"),
            "{out}"
        );
        assert_eq!(e.read(), "old\n");
        assert!(!e.record().exists());
        // dotfiles-private が無くても同じ
        std::fs::remove_dir_all(e.t.path().join("dotfiles-private")).unwrap();
        let (o, _) = e.apply();
        assert_eq!(o.kind, Kind::Info);
        assert_eq!(e.read(), "old\n");
    }

    #[test]
    fn first_apply_writes_hosts_json_and_record() {
        let e = Env::new(Some(OK_TOML));
        let (o, out) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert!(out.contains("無い (apply で置く): "), "{out}");
        let (o, out) = e.run(RUNNER_HOST, Mode::DryRun { force: false });
        assert!(
            out.contains("[dry-run] 新しく置く (Host 2 件・組 3 件): "),
            "{out}"
        );
        assert_eq!(
            o.text,
            "[dry-run] コピー 1 / 上書き 0 / 同じ 0 / 衝突 0 (Host 2 件・組 3 件)"
        );
        assert!(!e.dst().exists());
        assert!(!e.record().exists());

        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(
            o.text,
            "コピー 1 / 上書き 0 / 同じ 0 / 衝突 0 (Host 2 件・組 3 件)"
        );
        assert_eq!(
            e.read(),
            format!(
                "{{\n  \"version\": 1,\n  \"note\": \"{NOTE}\",\n  \"hosts\": {{\n    \"example-a\": [\n      \"3000\",\n      \"8080 api\"\n    ],\n    \"example-b\": [\n      \"15432:db:5432  ポスグレ\"\n    ]\n  }}\n}}\n"
            )
        );
        assert_eq!(e.recorded(), Some(fsutil::sha256_file(&e.dst()).unwrap()));
        assert_eq!(
            std::fs::read_to_string(e.record()).unwrap(),
            format!(
                "{{\n  \"files\": {{\n    \"hosts.json\": \"{}\"\n  }},\n  \"version\": 1\n}}\n",
                fsutil::sha256_file(&e.dst()).unwrap()
            )
        );
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(out.contains("同じです: "), "{out}");
        assert_eq!(
            o.text,
            "コピー 0 / 上書き 0 / 同じ 1 / 衝突 0 (Host 2 件・組 3 件)"
        );
    }

    #[test]
    fn updates_conflicts_and_force() {
        let e = Env::new(Some(OK_TOML));
        e.apply();
        e.set_toml("[hosts]\nexample-a = [\"3000\", \"8080 api\", \"9000\"]\n");
        let (o, out) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{out}");
        assert!(
            out.contains("正本が更新された (apply で上書きする): "),
            "{out}"
        );
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(out.contains("上書き (正本が更新された): "), "{out}");
        assert!(e.read().contains("\"9000\""));
        assert_eq!(e.recorded(), Some(fsutil::sha256_file(&e.dst()).unwrap()));

        let changed = "{\"hosts\":{\"example-a\":[\"1\"]}}\n";
        e.put(changed);
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains("は Windows 側で変わっています (前回ここへ置いた中身と違う)。"),
            "{out}"
        );
        assert!(
            out.contains("   diff diff --no-index --no-color -- "),
            "{out}"
        );
        assert!(out.contains("ssh/port-forward.toml へ取り込み"), "{out}");
        assert!(
            out.contains("正本で上書きするなら:   dotfiles apply --steps port-forward --force"),
            "{out}"
        );
        assert!(
            has_note(&o, "dotfiles apply --steps port-forward --force"),
            "{o:?}"
        );
        assert_eq!(e.read(), changed);
        // 受け持ちが WSL の間は、WSL の script の --force を出す
        let (o, out) = e.run(WSL_HOST, Mode::Check);
        assert!(
            out.contains("WSL で nix/scripts/bootstrap-windows-port-forward.sh --force"),
            "{out}"
        );
        assert!(
            has_note(
                &o,
                "衝突を解くのは WSL の側 (bootstrap-windows-port-forward.sh)"
            ),
            "{o:?}"
        );

        let (o, out) = e.run(RUNNER_HOST, Mode::DryRun { force: true });
        assert!(out.contains("[dry-run] 上書き (--force): "), "{out}");
        assert_eq!(o.kind, Kind::Fix);
        assert_eq!(e.read(), changed);
        let (o, out) = e.run(RUNNER_HOST, Mode::Apply { force: true });
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(e.read().contains("\"9000\""));
        let baks = e.baks();
        assert_eq!(baks.len(), 1, "{baks:?}");
        assert_eq!(std::fs::read_to_string(&baks[0]).unwrap(), changed);
        assert!(
            out.contains(&format!("  退避した: {}", baks[0].display())),
            "{out}"
        );
    }

    #[test]
    fn handmade_and_same_without_record() {
        let e = Env::new(Some(OK_TOML));
        e.put("{\"hosts\":{}}\n");
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(out.contains("置いた記録が無く"), "{out}");
        assert!(!out.contains("前回ここへ置いた中身と違う"), "{out}");
        assert!(!e.record().exists());

        // 記録が無くても中身が同じなら、記録だけする
        let first = Env::new(Some(OK_TOML));
        first.apply();
        let e = Env::new(Some(OK_TOML));
        e.put(&first.read());
        let (o, out) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(!e.record().exists());
        let (o, _) = e.apply();
        assert_eq!(o.kind, Kind::Ok);
        assert_eq!(e.recorded(), Some(fsutil::sha256_file(&e.dst()).unwrap()));
    }

    #[test]
    fn source_errors_write_nothing() {
        let e = Env::new(Some(
            "other = 1\n[hosts]\n\"bad host\" = [\"3000\"]\n\"web-*\" = [\"1\"]\n\"-x\" = [\"1\"]\nn = \"3000\"\nexample-c = [3000, \"0\", \"65536\", \"3000:\", \"x\", \"1:db:2 ok\", \"1\", \"2:[::1]:3\"]\n[hosts.example]\ntest = [\"1\"]\n",
        ));
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert_eq!(
            o.notes,
            vec![
                "知らないキーがあります: other (書けるのは [hosts] の表だけ)",
                "Host 名は - で始められません: -x",
                "Host 名に空白・* ? ! は使えません: bad host",
                "example: 値が配列ではありません (Host 名に . を含むなら \"…\" で囲む。囲まないと TOML の入れ子の表になる)",
                "example-c: 1 番目が文字列ではありません: 3000",
                "example-c: port は 1〜65535 で書いてください: 0",
                "example-c: port は 1〜65535 で書いてください: 65536",
                "example-c: 書き方が違います: 3000:",
                "example-c: 書き方が違います: x",
                "example-c: 手元の port が重なっています: 1",
                "n: 値は文字列の配列にする",
                "Host 名に空白・* ? ! は使えません: web-*",
            ]
        );
        assert!(
            out.contains("に誤りがあります。何も書いていません:"),
            "{out}"
        );
        assert!(!e.dst().exists());
        assert!(!e.record().exists());

        for (toml, msg) in [
            ("", "[hosts] の表がありません"),
            ("hosts = [\"x\"]\n", "hosts は表にする"),
            ("[[hosts]]\na = 1\n", "hosts は表にする"),
        ] {
            assert!(hosts_of(toml).unwrap_err()[0].contains(msg), "{toml}");
        }
        // 全角の数字は書き方の誤り (jq の \d は Unicode の数字に合う。正規表現は [0-9] で書く)
        assert_eq!(
            hosts_of("[hosts]\nexample-a = [\"３０００\", \"3000:db:５４３２\"]\n").unwrap_err(),
            vec![
                "example-a: 書き方が違います: ３０００",
                "example-a: 書き方が違います: 3000:db:５４３２",
            ]
        );

        let e = Env::new(Some("[hosts\n"));
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("を TOML として読めませんでした。何も書いていません:"),
            "{out}"
        );
        // 位置の印の行 (`  |`・`1 | [hosts`) は除き、どこの何が誤りかを残す
        assert!(o.notes[0].contains("line 1"), "{o:?}");
        assert!(!o.notes.iter().any(|n| n.contains('|')), "{o:?}");
        assert!(!e.dst().exists());
    }

    #[test]
    fn broken_record_and_directory_stop() {
        let e = Env::new(Some(OK_TOML));
        e.t.write(&format!("state/{RECORD_FILE}"), "not json\n");
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("既にある hosts.json は衝突として扱われます"),
            "{out}"
        );
        assert!(!e.dst().exists());

        let e = Env::new(Some(OK_TOML));
        std::fs::create_dir_all(e.dst()).unwrap();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(out.contains("!! 置き先がディレクトリです: "), "{out}");
        assert!(!e.record().exists());
    }

    /// 組の書き方の読み取り (WSL の spec_re と、jq で確かめた改行の扱い)
    #[test]
    fn parses_specs_like_the_wsl_regex() {
        for (s, want) in [
            ("3000", Some(("3000", None))),
            ("  3000  ", Some(("3000", None))),
            ("13000:3000", Some(("13000", Some("3000")))),
            ("15432:db:5432 postgres", Some(("15432", Some("5432")))),
            ("1:db:2 ok", Some(("1", Some("2")))),
            ("2:[::1]:3", Some(("2", Some("3")))),
            ("4:host-name.local:5 memo\twith tab", Some(("4", Some("5")))),
            ("\u{3000} 9000 全角の空白\u{3000}", Some(("9000", None))),
            ("3000\n", Some(("3000", None))),
            ("3000 a\n", Some(("3000", None))),
            (" 3000\n x", Some(("3000", None))),
            ("3000\nmemo", Some(("3000", None))),
            ("00080", Some(("00080", None))),
            ("0", Some(("0", None))),
            ("3000:", None),
            ("x", None),
            ("", None),
            ("123456", None),
            ("1:123456", None),
            ("3000x", None),
            ("3000:abc", None),
            ("1:a:b:2", None),
            ("1:[zz]:2", None),
            ("1:[]:2", None),
            ("x\n3000", None),
            ("3000 a\nb", None),
            ("3000 a\r\nb", None),
            ("３０００", None),
            ("127.0.0.1:3000:db:5432", None),
        ] {
            assert_eq!(parse_spec(s), want, "{s:?}");
        }
        assert!(in_range("1") && in_range("65535") && in_range("00080"));
        assert!(!in_range("0") && !in_range("65536") && !in_range("00000"));
    }

    #[test]
    fn writes_strings_like_jq() {
        assert_eq!(jq_string("a\"b\\c"), "\"a\\\"b\\\\c\"");
        assert_eq!(
            jq_string("\u{8}\t\n\u{c}\r\u{1}\u{1f}\u{7f}"),
            "\"\\b\\t\\n\\f\\r\\u0001\\u001f\\u007f\""
        );
        assert_eq!(jq_string("日本 / \u{2028}"), "\"日本 / \u{2028}\"");
        assert_eq!(
            render(&vec![("Zeta".to_string(), Vec::new())]),
            format!(
                "{{\n  \"version\": 1,\n  \"note\": \"{NOTE}\",\n  \"hosts\": {{\n    \"Zeta\": []\n  }}\n}}\n"
            )
        );
        assert_eq!(
            render(&Vec::new()),
            format!("{{\n  \"version\": 1,\n  \"note\": \"{NOTE}\",\n  \"hosts\": {{}}\n}}\n")
        );
        // Host 名はバイト列の順 (大文字が先、日本語は後ろ)
        let hosts = hosts_of("[hosts]\n\"z日本\" = []\nexample = [\" 1 \"]\nZeta = []\n").unwrap();
        let names: Vec<&str> = hosts.iter().map(|(h, _)| h.as_str()).collect();
        assert_eq!(names, vec!["Zeta", "example", "z日本"]);
        assert_eq!(hosts[1].1, vec!["1"]);
    }

    /// 順番・on/off・note・記録の名前・置き先は WSL の script と同じ (bash の版との突き合わせは Linux でだけ流れるので、Windows の CI でも字で比べる)
    #[test]
    fn settings_match_the_wsl_script() {
        let text = std::fs::read_to_string(parity::repo_file(
            "nix/scripts/bootstrap-windows-port-forward.sh",
        ))
        .unwrap()
        .replace("\r\n", "\n");
        let info = PortForward.info();
        assert!(
            text.lines()
                .any(|l| l == format!("# order: {}", info.order))
        );
        assert!(!text.lines().any(|l| l.starts_with("# tool: ")));
        assert_eq!(info.gate, Gate::Always);
        assert!(
            text.contains(&format!("\nnote='{NOTE}'\n")),
            "WSL の script の note と違う"
        );
        assert!(text.contains(&format!("record_file=\"${{state_dir}}/{RECORD_FILE}\"")));
        assert!(text.contains(&format!("dst=\"${{windows_home}}/{DST}\"")));
        assert!(text.contains(&format!(".files[\"{KEY}\"]")));
        assert!(text.contains(
            r#"def spec_re: "^\\s*(?<l>[0-9]{1,5})(?::(?:(?<h>\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9._-]+):)?(?<r>[0-9]{1,5}))?(?:\\s+(?<m>.*?))?\\s*$";"#
        ), "WSL の script の spec_re が変わった (parse_spec も直す)");
    }

    /// nix-instantiate が使えるか (WSL の script は正本を Nix の fromTOML で読む)。DOTFILES_WIN_NIX_PARITY=1 なら無いと落ちる (CI の Linux の job)
    #[cfg(unix)]
    fn nix_available() -> bool {
        let found = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
            .any(|d| d.join("nix-instantiate").is_file());
        if !found && std::env::var("DOTFILES_WIN_NIX_PARITY").as_deref() == Ok("1") {
            panic!("DOTFILES_WIN_NIX_PARITY=1 なのに nix-instantiate が PATH にありません");
        }
        found
    }

    /// WSL の script を、使い捨ての HOME (`<root>/wsl`)・Windows のホーム (`<root>/home`)・dotfiles-private で流す (本物の nix-instantiate と jq)
    #[cfg(unix)]
    fn wsl_run(root: &Path, args: &[&str]) -> (i32, String) {
        let state = root.join("wsl/.local/state/dotfiles/windows-files.json");
        // WSL の script は Windows のホームが無いと止まる (/mnt/c が見えないとき)
        std::fs::create_dir_all(root.join("home")).unwrap();
        if !state.exists() {
            std::fs::create_dir_all(state.parent().unwrap()).unwrap();
            std::fs::write(
                &state,
                serde_json::json!({"enable": true, "version": 1, "windowsHome": root.join("home")})
                    .to_string(),
            )
            .unwrap();
        }
        let o = std::process::Command::new("bash")
            .arg(parity::repo_file(
                "nix/scripts/bootstrap-windows-port-forward.sh",
            ))
            .args(args)
            .env("HOME", root.join("wsl"))
            .env("DOTFILES_PRIVATE_DIR", root.join("dotfiles-private"))
            .env_remove("DOTFILES_SETUP_WARNINGS")
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

    #[cfg(unix)]
    fn wsl_record(root: &Path) -> PathBuf {
        root.join("wsl/.local/state/dotfiles").join(RECORD_FILE)
    }

    /// WSL の script (本物の nix-instantiate と jq) と同じ正本から、同じバイト列の hosts.json と記録を書く。誤りのある正本は、どちらも何も書かずに同じ
    /// 誤りの文を並べる (bash・jq・nix-instantiate が無ければ飛ばし、CI の Linux の job は飛ばさない)
    #[cfg(unix)]
    #[test]
    fn writes_the_same_bytes_as_the_wsl_script() {
        if !parity::available() || !nix_available() {
            return;
        }
        let ok = [
            OK_TOML,
            "[hosts]\n",
            "[hosts]\nexample-a = [\"3000\", \" 8080 api \"]\n\"example.b\" = [\"15432:db:5432  ポスグレ\", \"2:[::1]:3\", \"4:host-name.local:5 memo\\twith tab\", \"\\u3000 9000 全角の空白\\u3000\"]\nZeta = []\n\"z日本\" = [\"7 x\\u007fy\", \"8 \\\"q\\\" \\\\ b\", \" 3000\\n x\"]\n",
        ];
        for toml in ok {
            let wsl = Env::new(Some(toml));
            let (code, out) = wsl_run(wsl.t.path(), &[]);
            assert_eq!(code, 0, "{toml}: {out}");
            let e = Env::new(Some(toml));
            let (o, out) = e.apply();
            assert_eq!(o.kind, Kind::Ok, "{toml}: {out}");
            assert_eq!(e.read(), wsl.read(), "{toml}");
            assert_eq!(
                std::fs::read_to_string(e.record()).unwrap(),
                std::fs::read_to_string(wsl_record(wsl.t.path())).unwrap(),
                "{toml}"
            );
            // --check の数も同じ
            let (_, checked) = wsl_run(wsl.t.path(), &["--check"]);
            assert!(
                checked.contains(&format!(
                    "ssh/port-forward.toml: OK ({})",
                    counts(&hosts_of(toml).unwrap())
                )),
                "{checked}"
            );
        }

        let bad = [
            "other = 1\n[hosts]\n\"bad host\" = [\"3000\"]\n\"web-*\" = [\"1\"]\n\"-x\" = [\"1\"]\nn = \"3000\"\nexample-c = [3000, \"0\", \"65536\", \"3000:\", \"x\", \"1:db:2 ok\", \"1\", \"2:[::1]:3\"]\n[hosts.example]\ntest = [\"1\"]\n",
            "",
            "hosts = [\"x\"]\n",
            "[hosts]\nexample-a = [\"３０００\", \"3000:db:５４３２\", \"x\\n3000\", \"3000 a\\nb\"]\n\"\" = []\n",
        ];
        for toml in bad {
            let wsl = Env::new(Some(toml));
            let (code, out) = wsl_run(wsl.t.path(), &[]);
            assert_eq!(code, 1, "{toml}: {out}");
            let wsl_errors: Vec<&str> = out
                .lines()
                .skip_while(|l| !l.contains("に誤りがあります。何も書いていません:"))
                .skip(1)
                .map(|l| l.trim_start_matches("   "))
                .collect();
            let e = Env::new(Some(toml));
            let (o, out) = e.apply();
            assert_eq!(o.kind, Kind::Failed, "{toml}: {out}");
            // 改行を含む組の誤りは、WSL では 2 行に割れて出る (行ごとに字下げする) ので、つないで比べる
            assert_eq!(o.notes.join("\n"), wsl_errors.join("\n"), "{toml}");
            assert!(!e.dst().exists() && !wsl.dst().exists(), "{toml}");
        }
    }

    /// 受け持ちを切り替えた後の引き継ぎ: WSL の script が置いた hosts.json を、記録の無い runner が自分のものとして読む (受け持ちが WSL の間の check は
    /// ✔、切り替えた後の apply は変えずに記録だけ作り、記録は WSL の記録と同じ)
    #[cfg(unix)]
    #[test]
    fn takes_over_what_the_wsl_script_wrote() {
        if !parity::available() || !nix_available() {
            return;
        }
        let e = Env::new(Some(OK_TOML));
        let (code, out) = wsl_run(e.t.path(), &[]);
        assert_eq!(code, 0, "{out}");
        let written = e.read();
        let (o, out) = e.run(WSL_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(!e.record().exists());
        for _ in 0..2 {
            let (o, out) = e.apply();
            assert_eq!(o.kind, Kind::Ok, "{out}");
            assert_eq!(e.read(), written);
        }
        assert_eq!(
            std::fs::read_to_string(e.record()).unwrap(),
            std::fs::read_to_string(wsl_record(e.t.path())).unwrap()
        );
    }
}
