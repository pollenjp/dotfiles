//! pin-updates (order 97): Windows に固定した版で入れているものに、固定した版より新しい版 (見送っていないもの) が出ていないかを GitHub で
//! 確かめ、あれば名前ごとに 1 行と、上げるかを決める頼み方を知らせる。WSL の `nix/scripts/bootstrap-windows-pin-updates.sh` の setup の手順
//! (引数なし) を写したもの (確かめる名前・新しい版の判定・見送り・知らせる文・keys.json の注意・確かめられないときの文をそろえる)。新しい版の
//! 一覧は、WSL が呼ぶ `check-winget-version.sh --json` (`winget.rs`) と `check-herdr-app-version.sh --json` (`herdr.rs`) を、setup と同じく出た日を
//! 引かない形で写した。移し方は dotfiles-private の docs/adr/060_win_runner_core_* の spec §8 の 6。
//!
//! - 確かめる名前は WSL と同じ順 (`NAMES`)。on/off は、WSL の記録 (windows-files.json の ntn・claudeCode、group.json の tools.windowsHerdr・
//!   windowsTailscale・windowsCodex) の代わりに、同じものを入れる手順と同じ道具の switch (ntn は windowsNtn、claude-code は windowsClaudeCode、herdr・
//!   herdr-app・herdr-core は windowsHerdr、tailscale は windowsTailscale、codex は windowsCodex)。bootstrap の 5 つ (git・gh・pwsh・vs-buildtools・rustup) と、runner の手順 ghq・fzf・
//!   starship が入れる ghq・fzf・starship は、WSL と同じく Windows の ghq に dotfiles の clone がある (`%USERPROFILE%\ghq\github.com\pollenjp\dotfiles\.git`。
//!   bootstrap を流した) ときだけ
//! - GitHub は Windows の gh で読む (`gh api`。HTTP の crate を足さない)。herdr-app・herdr-core は、版ごとの Windows の成果物が releases.herdr.dev に
//!   あるかを HEAD で見る (無い版は数えない)。gh では読めない所なので、WSL と同じ引数の curl (PATH で最初に見つかるもの。Windows はふつう System32 の
//!   curl.exe。Install-HerdrApp.ps1 も同じ探し方で、同じ取得元を落とす) を打つ
//! - 待つ上限は WSL と同じく名前ごとに 60 秒 (herdr-app と herdr-core は 2 つで 1 回)。gh が無い・ログインしていない (`gh auth token` の終了コード。
//!   token は写しに取らず、流す口は受けた行を捨てる) ときは、名前を確かめずに知らせる
//! - 行: 見送っていない新しい版があれば · (知らせるだけ。終了コードに数えない。ps1 の手順が winget の新しい版を ✔ の行の ※ で出すのと同じく、
//!   直すことではない)、無ければ ✔。gh が無い・ログインしていない → manual、確かめられなかった名前がある → failed (WSL はどれも警告して exit 0。
//!   runner には setup を止めることが無いので、前の手順と同じく ⚠ の行にした)
//! - 出力 (手順の見出しの下) は WSL の script の出力と同じ字 (`!!` の行と字下げした続き)。違うのは、gh が無いときの直し方 (WSL は home-manager
//!   switch、runner は bootstrap)・確かめられなかったときの「setup は続けます。」を書かないこと・releases.json の誤りの文のパス (runner の clone の
//!   Windows のパス)・runner にしか無い失敗の文 (見送りの一覧が読めない・gh や curl を起こせない・curl が無い)
//! - 空白の読み方 (見送りの一覧の注釈と空行・ps1 の行頭と `=` の前後・わけの行頭) は、WSL の setup が流れる C.UTF-8 の bash の `[[:space:]]` と同じ
//!   (`is_space`。全角の空白なども数える)
//! - 依存の更新の skill が読む JSON の口 (`--list --json`・`--candidates --json`) と、人が読む `--candidates` は写さない (WSL の script に残す)。
//!   読む側は Linux の会話から repo の root で打ち、口は WSL の記録を見ないので、受け持ちを runner に切り替えた後も Linux で動く
//! - Windows にも記録の置き場にも何も書かない。check・dry-run・apply は同じことをする (GitHub を読んで知らせるだけ)
//! - on/off は道具の switch `privateRepos` (gh にログインして pollenjp の private な repo を使うホスト。dotfiles-private の
//!   docs/adr/111_win_runner_without_gh_*)。gh にログインできない PC (客先の PC など) では流さない (↷)

mod herdr;
mod winget;

#[cfg(test)]
mod tests;

use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, ghq_owner_dir};
use crate::host::PRIVATE_REPOS;
use crate::process::{CommandSpec, Exit};
use crate::report::Kind;
use std::cmp::Ordering;
use std::path::Path;
use std::time::{Duration, Instant};

/// 確かめる名前 (WSL の `all_names` と同じ順)
pub const NAMES: &[&str] = &[
    "openssh",
    "herdr",
    "google-japanese-input",
    "ntn",
    "claude-code",
    "tailscale",
    "ghq",
    "fzf",
    "starship",
    "codex",
    "git",
    "gh",
    "pwsh",
    "vs-buildtools",
    "rustup",
    "herdr-app",
    "herdr-core",
];

/// 名前ごとの待つ上限 (WSL の `fetch` の `timeout 60`。herdr-app と herdr-core は 2 つで 1 回)
pub const LIMIT_SECS: u64 = 60;
/// `gh auth token` を待つ上限 (WSL は上限を置かない。手元の資格情報を読むだけなので、claude-env と同じ 30 秒)
const AUTH_SECS: u64 = 30;

/// 新しい版があるときの見出し (WSL と同じ字)
pub const HEADING: &str = "Windows に固定した版より新しい版があります → Claude Code に「dotfiles の Windows に固定した版を上げて」と頼み、上げるか (どの版か) を決める";
/// herdr-app に見送っていない新しい版があるときに、続きの行の末尾に添える keys.json の注意 (WSL と同じ字。dotfiles-private の
/// docs/adr/075_win_herdr_app_keys_upgrade_notice_*)
pub const KEYS_NOTE: [&str; 2] = [
    "※ herdr-app を上げるなら、新しい既定のキーも足す (dotfiles がキーを書き足した keys.json には、herdr-app を上げても新しい既定のキーが足されない)",
    "  → 上げる版までの更新ノート (What's new。中身は herdrdev/herdr-app の CHANGELOG.md) で keys.json に触れた項 (「if you edited keys.json, add …」など) を探し、Windows で効くキーを win/herdr-app/keys.json に足す (dotfiles のキーと重なる既定のキーは、その既定の値を keys.defaults.json に書く。win/README.md の「固定した版を上げる」)",
];
/// gh が見つからないとき (WSL の「home-manager switch の後に流し直す」は Windows では bootstrap)
pub const NO_GH: &str = "Windows に固定した版より新しい版があるかを確かめられませんでした (gh が見つからない。gh は -Private の bootstrap (win/bootstrap/Install-Bootstrap.ps1 -Private) が入れる。入れた後に流し直す)。";
/// gh がログインしていないとき (WSL と同じ字)
pub const NOT_LOGGED_IN: &str = "Windows に固定した版より新しい版があるかを確かめられませんでした (gh にログインしていない。gh auth login の後に流し直す)。";
/// 新しい版が無いとき (WSL と同じ字。後ろに確かめた名前と「)。」)
pub const NONE_PREFIX: &str =
    "Windows に固定した版より新しい版は無い (見送った版を除く。確かめたもの: ";
/// 確かめられなかった名前があるとき (WSL と同じ字。後ろに名前とわけ。WSL の末尾の「setup は続けます。」は書かない)
pub const FAILED_PREFIX: &str =
    "Windows に固定した版より新しい版があるかを確かめられなかったもの: ";
/// SSH の会話の中で gh がログインしていないと読んだときに添える (確かめていない見込み)
const SSH_NOTE: &str = "SSH の会話の中 (SSH_CONNECTION・SSH_CLIENT がある) では、鍵で入った会話が Windows の資格情報マネージャーを読めず、gh がログインしていないように見えることがある (確かめていない)。デスクトップの端末で流す";

/// 名前ごとの on/off (WSL は windows-files.json・group.json で決める)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NameGate {
    /// いつも確かめる
    Always,
    /// 道具の switch が true なら (同じものを入れる手順と同じ switch)
    Tool(&'static str),
    /// Windows の ghq に dotfiles の clone がある (bootstrap を流した) なら (bootstrap の 5 つと、bootstrap の clone の runner が入れる ghq・fzf・starship)
    Bootstrapped,
}

/// 名前の on/off の決め方。
pub fn name_gate(name: &str) -> NameGate {
    match name {
        "ntn" => NameGate::Tool("windowsNtn"),
        "claude-code" => NameGate::Tool("windowsClaudeCode"),
        "herdr" | "herdr-app" | "herdr-core" => NameGate::Tool("windowsHerdr"),
        "tailscale" => NameGate::Tool("windowsTailscale"),
        "codex" => NameGate::Tool("windowsCodex"),
        "git" | "gh" | "pwsh" | "vs-buildtools" | "rustup" | "ghq" | "fzf" | "starship" => {
            NameGate::Bootstrapped
        }
        _ => NameGate::Always,
    }
}

/// 固定した版より新しい版の 1 つ (WSL の `--json` の newer の 1 つのうち、setup が使うもの)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Newer {
    pub version: String,
    /// 見送った理由 (見送りの一覧にあれば)
    pub skipped: Option<String>,
}

/// 1 つの名前を確かめた結果 (WSL の `--json` の 1 行のうち、setup が使うもの)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Found {
    pub title: String,
    pub pinned: String,
    /// 固定した版より新しい版 (古い順。見送った版も理由つきで入れる)
    pub newer: Vec<Newer>,
}

impl Found {
    /// setup が出す 1 行 (WSL の jq の式と同じ: 見送っていない版が 3 つまでは並べ、4 つ以上は頭と末尾と個数)。無ければ None。
    pub fn line(&self) -> Option<String> {
        let n: Vec<&str> = self
            .newer
            .iter()
            .filter(|x| x.skipped.is_none())
            .map(|x| x.version.as_str())
            .collect();
        match n.len() {
            0 => None,
            1..=3 => Some(format!(
                "{}: {} → {}",
                self.title,
                self.pinned,
                n.join("・")
            )),
            k => Some(format!(
                "{}: {} → {}・…・{} (新しい版 {k} 個)",
                self.title,
                self.pinned,
                n[0],
                n[k - 1]
            )),
        }
    }
}

/// 確かめられなかったときに WSL の口が stderr に出す行 (呼ぶ側はここから `reason_of` でわけを作る)。
pub type Trouble = Vec<String>;

pub struct PinUpdates;

impl Step for PinUpdates {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "pin-updates",
            order: 97,
            title: "固定した版より新しい版が出ていないかを知らせる",
            // GitHub は gh (ログイン) で読む。privateRepos (gh のログインを使うホスト) が off なら流さない (ADR 111)
            gate: Gate::Tool(PRIVATE_REPOS),
            ported: true,
            windows_only: false,
        }
    }

    /// check・dry-run・apply は同じ (GitHub を読んで知らせるだけで、何も書かない)
    fn run(&self, ctx: &mut Ctx, _mode: Mode) -> Vec<Outcome> {
        notify(ctx)
    }
}

/// このホストで確かめる名前 (WSL の setup の手順が windows-files.json・group.json で決めるのと同じ並び)。
pub fn selected(ctx: &Ctx) -> Vec<&'static str> {
    let bootstrapped = ghq_owner_dir(&ctx.roots.user_profile)
        .join("dotfiles")
        .join(".git")
        .exists();
    NAMES
        .iter()
        .copied()
        .filter(|n| match name_gate(n) {
            NameGate::Always => true,
            NameGate::Tool(key) => ctx.host.tool(key),
            NameGate::Bootstrapped => bootstrapped,
        })
        .collect()
}

/// WSL の `warn` と同じ形で出す (1 行目の頭に `!! `、続きの行は 3 つの空白で字下げ)。
fn warn(ctx: &mut Ctx, lines: &[String]) {
    if let Some((first, rest)) = lines.split_first() {
        ctx.say(format!("!! {first}"));
        for l in rest {
            ctx.say(format!("   {l}"));
        }
    }
}

/// gh が github.com にログインしているか (WSL と同じく `gh auth token` の終了コードで見る。手元の資格情報を読むだけ)。token (stdout) は写しに
/// 取らず (`stderr_only`)、流す口は受けた行を捨てる。
fn logged_in(ctx: &Ctx, gh: &Path) -> bool {
    let spec = CommandSpec::new(gh)
        .arg("auth")
        .arg("token")
        .stderr_only()
        .timeout(Duration::from_secs(AUTH_SECS));
    ctx.sys.run(&spec, &mut |_| {}).code() == Some(0)
}

/// 新しい版を確かめて知らせる (WSL の setup の手順の本体)。
pub fn notify(ctx: &mut Ctx) -> Vec<Outcome> {
    let names = selected(ctx);
    let Some(gh) = ctx.sys.which("gh") else {
        warn(ctx, &[NO_GH.to_string()]);
        return vec![
            Outcome::new(
                Kind::Manual,
                "固定した版より新しい版があるかを確かめられない (gh が見つからない)",
            )
            .note("gh は bootstrap が入れる (win/bootstrap/Install-Bootstrap.ps1 を流す)。入れた後に dotfiles check --steps pin-updates で確かめる"),
        ];
    };
    if !logged_in(ctx, &gh) {
        warn(ctx, &[NOT_LOGGED_IN.to_string()]);
        let mut o = Outcome::new(
            Kind::Manual,
            "固定した版より新しい版があるかを確かめられない (gh にログインしていない)",
        )
        .note("gh auth login の後に dotfiles check --steps pin-updates で確かめる");
        if ctx.in_ssh() {
            o = o.note(SSH_NOTE);
        }
        return vec![o];
    }
    let curl = ctx.sys.which("curl");
    let limit = Duration::from_secs(LIMIT_SECS);
    // herdr-app と herdr-core は 1 回で読む (WSL も check-herdr-app-version.sh を 1 回だけ呼ぶ)
    let mut herdr_both: Option<Result<(Found, Found), Trouble>> = None;
    let mut newer_lines = Vec::new();
    let mut failed: Vec<(&str, String)> = Vec::new();
    let mut herdr_app_newer = false;
    let c: &Ctx = ctx;
    for name in &names {
        let result = match *name {
            "herdr-app" | "herdr-core" => {
                let both = herdr_both.get_or_insert_with(|| {
                    herdr::check(c, &gh, curl.as_deref(), Instant::now() + limit)
                });
                match both {
                    Ok((app, core)) => Ok(if *name == "herdr-app" {
                        app.clone()
                    } else {
                        core.clone()
                    }),
                    Err(e) => Err(e.clone()),
                }
            }
            other => match winget::SPECS.iter().find(|s| s.name == other) {
                Some(spec) => winget::check(c, &gh, spec, Instant::now() + limit),
                None => Err(vec![format!("!! 知らない名前です: {other}")]),
            },
        };
        match result {
            Ok(found) => {
                if let Some(line) = found.line() {
                    newer_lines.push(line);
                    if *name == "herdr-app" {
                        herdr_app_newer = true;
                    }
                }
            }
            Err(trouble) => failed.push((name, reason_of(&trouble))),
        }
    }

    let mut outcomes = Vec::new();
    if !newer_lines.is_empty() {
        let mut lines = vec![HEADING.to_string()];
        lines.extend(newer_lines.iter().cloned());
        let mut notes = newer_lines;
        // keys.json の注意は、警告のまとめが長い警告の間を省いても残る末尾に置く (WSL と同じ)
        if herdr_app_newer {
            lines.extend(KEYS_NOTE.iter().map(|s| s.to_string()));
            notes.push(KEYS_NOTE[0].trim_start_matches("※ ").to_string());
            notes.push(KEYS_NOTE[1].trim_start().to_string());
        }
        warn(ctx, &lines);
        let mut o = Outcome::new(Kind::Info, HEADING);
        o.notes = notes;
        outcomes.push(o);
    } else if failed.is_empty() {
        ctx.say(format!("{NONE_PREFIX}{})。", names.join("・")));
        outcomes.push(Outcome::new(
            Kind::Ok,
            format!(
                "固定した版より新しい版は無い (見送った版を除く。{} 個を確かめた)",
                names.len()
            ),
        ));
    }
    if !failed.is_empty() {
        let which: Vec<&str> = failed.iter().map(|(n, _)| *n).collect();
        warn(
            ctx,
            &[format!(
                "{FAILED_PREFIX}{} ({})。",
                which.join("・"),
                failed[0].1
            )],
        );
        let mut o = Outcome::new(
            Kind::Failed,
            format!(
                "固定した版より新しい版があるかを確かめられなかったもの: {}",
                which.join("・")
            ),
        );
        for (n, why) in &failed {
            o = o.note(format!("{n}: {why}"));
        }
        outcomes
            .push(o.note("直したら・時間をおいて dotfiles check --steps pin-updates で確かめ直す"));
    }
    outcomes
}

/// 確かめられなかったわけを 1 行にする (WSL の `reason_of`: 行ごとに頭の `!! ` と空白を落とし、空でない最初の 2 行を「 / 」でつなぐ)。
pub fn reason_of(lines: &[String]) -> String {
    lines
        .iter()
        .map(|l| l.strip_prefix("!! ").unwrap_or(l))
        .map(|l| l.trim_start_matches(is_space))
        .filter(|l| !l.is_empty())
        .take(2)
        .collect::<Vec<_>>()
        .join(" / ")
}

/// WSL の口が確かめられなかったときに stderr へ出す行 (`cannot_check`: 1 つめの引数を `!! ` で、残りを 3 つの空白で字下げして行ごとに)。
pub fn cannot_check(first: &str, rest: &[&str]) -> Trouble {
    let mut lines = vec![format!("!! {first}")];
    for r in rest {
        for l in r.split('\n') {
            lines.push(format!("   {l}"));
        }
    }
    lines
}

/// 待つ上限を過ぎたとき (WSL は `timeout` が口を止め、それまでに stderr に出た行があればそれを、無ければ「60 秒で返らなかった」をわけにする)。
pub fn timed_out(err: &[String]) -> Trouble {
    if err.is_empty() {
        vec![format!("{LIMIT_SECS} 秒で返らなかった")]
    } else {
        err.to_vec()
    }
}

/// 待つ上限までの残り (過ぎていれば None)
pub fn remaining(deadline: Instant) -> Option<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
}

/// 打った結果 (stdout と stderr を分けたもの)。
pub struct Split {
    pub exit: Exit,
    pub out: Vec<String>,
    pub err: Vec<String>,
}

/// コマンドを打ち、stdout と stderr を分けて受ける (gh api は失敗したときも stdout に応答の本文を、stderr にわけを書く)。stdout だけを写しに取り、
/// 流す口で受けた全部の行から写しの行を順に除いたものを stderr とする (流す口には届いた順に全部が来る)。同じ字の行が stdout と stderr の両方に
/// あると、stderr の中の並びが入れ替わりうる (中身は変わらない)。gh・curl の stdout (JSON・ヘッダ) と stderr (わけ) は同じ字にならない。
pub fn run_split(ctx: &Ctx, spec: CommandSpec) -> Split {
    let mut all = Vec::new();
    let r = ctx
        .sys
        .run(&spec.stdout_only(), &mut |l| all.push(l.to_string()));
    let mut err = Vec::new();
    let mut j = 0;
    for l in all {
        if j < r.output.len() && r.output[j] == l {
            j += 1;
        } else {
            err.push(l);
        }
    }
    Split {
        exit: r.exit,
        out: r.output,
        err,
    }
}

/// bash の `[[:space:]]` (WSL の script の正規表現・注釈の行・`reason_of` の空白)。WSL の setup が流れる C.UTF-8 の glibc の space の字: ASCII の空白
/// (タブ〜CR と空白) と U+1680・U+2000〜U+2006・U+2008〜U+200A・U+2028・U+2029・U+205F・U+3000 (全角の空白)。改行しない空白 (U+00A0・U+2007・
/// U+202F) と U+0085 は入らない (C.UTF-8 の bash で確かめた。試験も比べる)
pub fn is_space(c: char) -> bool {
    matches!(
        c,
        '\t'..='\r'
            | ' '
            | '\u{1680}'
            | '\u{2000}'..='\u{2006}'
            | '\u{2008}'..='\u{200a}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{205f}'
            | '\u{3000}'
    )
}

/// bash の `while IFS= read -r line || [[ -n ${line} ]]` が読む行 (改行で区切る。最後の改行の後ろの空は読まない。CR は残す)
pub fn read_lines(text: &str) -> Vec<&str> {
    let mut lines: Vec<&str> = text.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop();
    }
    lines
}

/// bash の `read -r a b … <<<"${line}"` (既定の IFS の空白はスペースとタブ): 前後の空白を落とし、空白で区切った頭の `n - 1` 個と、残り (間の空白は
/// 残す) を返す。
pub fn read_fields(line: &str, n: usize) -> Vec<&str> {
    let ifs = |c: char| c == ' ' || c == '\t';
    let mut rest = line.trim_matches(ifs);
    let mut fields = Vec::with_capacity(n);
    while fields.len() + 1 < n {
        match rest.find(ifs) {
            Some(i) => {
                fields.push(&rest[..i]);
                rest = rest[i..].trim_start_matches(ifs);
            }
            None => {
                fields.push(rest);
                rest = "";
            }
        }
    }
    fields.push(rest);
    fields
}

/// 版の形 (`.` で区切った数の欄が `min` 個から `max` 個。WSL の `^[0-9]+(\.[0-9]+){1,3}$` は 2〜4、`^[0-9]+\.[0-9]+\.[0-9]+$` は 3)
pub fn version_form(v: &str, (min, max): (usize, usize)) -> bool {
    let parts: Vec<&str> = v.split('.').collect();
    (min..=max).contains(&parts.len())
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

/// WSL の `newer_than`: `a` が `b` と違い、`sort -V` で後ろに来るか。
pub fn newer_than(a: &str, b: &str) -> bool {
    a != b && version_cmp(a, b) == Ordering::Greater
}

/// GNU の `sort -V` の比べ方: gnulib の filevercmp で比べ、同じなら sort の最後の比べ方 (バイト列) で比べる。並べるのは版の形の正規表現を通った
/// 数と `.` だけの字で、その範囲では coreutils の版によらず同じ (`.` で始まる名前と、英字や `~` の拡張子の扱いは、新しい filevercmp に合わせた。
/// 古い coreutils の sort とは違う)
pub fn version_cmp(a: &str, b: &str) -> Ordering {
    match filevercmp(a.as_bytes(), b.as_bytes()) {
        Ordering::Equal => a.as_bytes().cmp(b.as_bytes()),
        o => o,
    }
}

/// gnulib の filevercmp (coreutils の `sort -V`・`ls -v`)。
fn filevercmp(a: &[u8], b: &[u8]) -> Ordering {
    if a.is_empty() {
        return if b.is_empty() {
            Ordering::Equal
        } else {
            Ordering::Less
        };
    }
    if b.is_empty() {
        return Ordering::Greater;
    }
    // 頭の "." は "." → ".." → ほかの "." で始まるもの → ほかの順
    if a[0] == b'.' {
        if b[0] != b'.' {
            return Ordering::Less;
        }
        let (adot, bdot) = (a.len() == 1, b.len() == 1);
        if adot {
            return if bdot {
                Ordering::Equal
            } else {
                Ordering::Less
            };
        }
        if bdot {
            return Ordering::Greater;
        }
        let adotdot = a[1] == b'.' && a.len() == 2;
        let bdotdot = b[1] == b'.' && b.len() == 2;
        if adotdot {
            return if bdotdot {
                Ordering::Equal
            } else {
                Ordering::Less
            };
        }
        if bdotdot {
            return Ordering::Greater;
        }
    } else if b[0] == b'.' {
        return Ordering::Greater;
    }
    let ap = file_prefixlen(a);
    let bp = file_prefixlen(b);
    let one_pass_only = ap == a.len() && bp == b.len();
    let r = verrevcmp(&a[..ap], &b[..bp]);
    if r != 0 || one_pass_only {
        r.cmp(&0)
    } else {
        verrevcmp(a, b).cmp(&0)
    }
}

/// 末尾の拡張子 (`(\.[A-Za-z~][A-Za-z0-9~]*)*$`) を除いた長さ。
fn file_prefixlen(s: &[u8]) -> usize {
    let n = s.len();
    let mut prefixlen = 0;
    let mut i = 0;
    loop {
        if i == n {
            return prefixlen;
        }
        i += 1;
        prefixlen = i;
        while i + 1 < n && s[i] == b'.' && (s[i + 1].is_ascii_alphabetic() || s[i + 1] == b'~') {
            i += 2;
            while i < n && (s[i].is_ascii_alphanumeric() || s[i] == b'~') {
                i += 1;
            }
        }
    }
}

/// 版の字の並べ方での 1 字の重み (終わりは `~` のほかの全部より前)。
fn order(s: &[u8], pos: usize) -> i32 {
    if pos >= s.len() {
        return -1;
    }
    let c = s[pos];
    if c.is_ascii_digit() {
        0
    } else if c.is_ascii_alphabetic() {
        i32::from(c)
    } else if c == b'~' {
        -2
    } else {
        i32::from(c) + 256
    }
}

/// dpkg の verrevcmp (数でない所は字の重みで、数の所は頭の 0 を落として値で比べる)。
fn verrevcmp(s1: &[u8], s2: &[u8]) -> i32 {
    let (mut p1, mut p2) = (0, 0);
    while p1 < s1.len() || p2 < s2.len() {
        let mut first_diff = 0;
        while (p1 < s1.len() && !s1[p1].is_ascii_digit())
            || (p2 < s2.len() && !s2[p2].is_ascii_digit())
        {
            let c1 = order(s1, p1);
            let c2 = order(s2, p2);
            if c1 != c2 {
                return c1 - c2;
            }
            p1 += 1;
            p2 += 1;
        }
        while p1 < s1.len() && s1[p1] == b'0' {
            p1 += 1;
        }
        while p2 < s2.len() && s2[p2] == b'0' {
            p2 += 1;
        }
        while p1 < s1.len() && p2 < s2.len() && s1[p1].is_ascii_digit() && s2[p2].is_ascii_digit() {
            if first_diff == 0 {
                first_diff = i32::from(s1[p1]) - i32::from(s2[p2]);
            }
            p1 += 1;
            p2 += 1;
        }
        if p1 < s1.len() && s1[p1].is_ascii_digit() {
            return 1;
        }
        if p2 < s2.len() && s2[p2].is_ascii_digit() {
            return -1;
        }
        if first_diff != 0 {
            return first_diff;
        }
    }
    0
}
