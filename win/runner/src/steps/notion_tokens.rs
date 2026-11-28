//! notion-tokens (order 55): ホストの値の Notion の API キーの宣言 (`[claude.notion.tokens.<名前>]` の `kind`・`item`) を
//! `%USERPROFILE%\.local\state\dotfiles\notion-tokens.json` に書き、宣言したプロファイルごとに `~/.config/pjp/env` (`XDG_CONFIG_HOME` があれば
//! その下。手順 local-env と同じ置き場所) に変数の行があるかと、そのファイルの ACL を、値を出さずに確かめて知らせる。Windows にしか無い手順
//! (dotfiles-private の docs/adr/114_win_notion_api_token_*。ADR 112 の範囲を Windows へ広げたもの)。
//!
//! Linux の 2 つを 1 つの手順にしたもの:
//!
//! - notion-tokens.json: home/modules/claude.nix が `dotfiles.claude.notion.tokens` から書く中身と同じ (nix/lib/notion-tokens.nix の stateText。
//!   `host::NotionValues::tokens_json`)。dotfiles が持つ生成物なので、違えば書き直す (claude-notion.json と同じ `generated::sync`)。読むのは
//!   claude-skills の棚卸しの道具 (`pjp notion-token-audit`)。宣言が無くても `{"tokens":{}}` を書く (ファイルが無いのは、dotfiles が古い印)
//! - 知らせ: setup の nix/scripts/bootstrap-notion-tokens.sh (order 55) と同じ判定と文。違うのは次だけ:
//!   - 行の数え方は、Windows でこのファイルを読む pjp と棚卸しの道具 (claude-skills の pjp-notion-profile の `count_token_lines`) に合わせる。
//!     ファイルの頭の UTF-8 の BOM を外し、= の後ろの値の末尾の空白 (Python の rstrip と同じ字) を落として空なら数えない (bash の版は BOM を
//!     外さず、値の末尾の CR だけを落とす)
//!   - 権限は mode でなく ACL で見る。読む権限を許す規則が、本人 (今のユーザー)・SYSTEM・Administrators のほかにもあれば知らせる
//!     (`%USERPROFILE%` の下は、継いだ ACL でこの 3 つだけが読める。dotfiles-private の ADR 105)。ACL は PowerShell の Get-Acl で読み、
//!     書き換えない (直し方を添える。ADR 105 で ACL を書き換えないと決めた)
//!   - env が symlink なら見ない (local-env と `pjp notion-profile set-token` も symlink には書かない)。NUL がある (UTF-16 などで保存した) なら、
//!     pjp が読めないので行を数えずに知らせる
//!
//! 値は出力にも締めの表にも出さない (行は数えるだけ。ACL の答えは SID と名前だけ)。env は書き換えない (欄を書き直すのは local-env、値を入れる
//! のは set-token)。入れてからの日数は出さない (Linux の setup の知らせも出さない。棚卸しの道具が set-token の控えから出す)。

use super::{Gate, Mode, Outcome, Step, StepInfo, generated, local_env, ps1};
use crate::context::{Ctx, join_segments};
use crate::host::{NotionToken, token_var};
use crate::process::{CommandSpec, Sys};
use crate::report::Kind;
use std::path::Path;
use std::time::Duration;

/// 置き先 (ホームからの相対。claude-skills は `XDG_STATE_HOME` を見ずに、ホームからの固定の場所で読む)
pub const REL: &str = ".local/state/dotfiles/notion-tokens.json";
/// 締めの表に出す env の名前
const WHAT: &str = "~/.config/pjp/env";
/// Windows のエディタが頭に付ける UTF-8 の BOM
const BOM: &[u8] = b"\xef\xbb\xbf";

/// 中身を読む権限 (FILE_READ_DATA・GENERIC_READ・GENERIC_ALL)。ReadPermissions・ReadAttributes だけでは中身を読めない
const READ_BITS: u32 = 0x0000_0001 | 0x8000_0000 | 0x1000_0000;
/// 今のユーザーのほかに読めてよい人 (SYSTEM・Administrators)
const TRUSTED: [&str; 2] = ["S-1-5-18", "S-1-5-32-544"];
/// 自分には効かず、下に継がせるときに作った人へ置き換わる人 (CREATOR OWNER・CREATOR GROUP)
const CREATORS: [&str; 2] = ["S-1-3-0", "S-1-3-1"];
/// 持ち主に効く人 (OWNER RIGHTS)
const OWNER_RIGHTS: &str = "S-1-3-4";
/// 規則の継がせ方の InheritOnly (自分に効かず、下に継がせるだけ。PropagationFlags の 2)
const INHERIT_ONLY: i64 = 2;

/// `DOTFILES_ACL_PATH` のファイルの ACL を読み、今のユーザーの SID (`me=`)・持ち主の SID (`owner=`。読めなければ空)・規則 (`rule=` に
/// 許すか拒むか (Allow・Deny)|権限 (FileSystemRights の数)|継がせ方 (PropagationFlags の数)|SID|名前 (読めなければ空)) を 1 行ずつ出す。誤りなら
/// `error:` の行を出して 1 で終わる。パスは env で渡し、script は ASCII だけにする (引用符と文字コードに頼らない。t3_code_settings・user_path と同じ)
const READ_ACL: &str = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $ErrorActionPreference = 'Stop'; try { $acl = Get-Acl -LiteralPath ([string]$env:DOTFILES_ACL_PATH); Write-Output ('me=' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value); $owner = ''; try { $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { }; Write-Output ('owner=' + $owner); foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) { $name = ''; try { $name = $r.IdentityReference.Translate([Security.Principal.NTAccount]).Value } catch { }; Write-Output ('rule=' + $r.AccessControlType + '|' + [int]$r.FileSystemRights + '|' + [int]$r.PropagationFlags + '|' + $r.IdentityReference.Value + '|' + $name) }; exit 0 } catch { Write-Output ('error: ' + $_.Exception.Message); exit 1 }";

pub struct NotionTokens;

impl Step for NotionTokens {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "notion-tokens",
            order: 55,
            title: "Notion の API キーの宣言 ([claude.notion.tokens]) を notion-tokens.json に書き、~/.config/pjp/env の行と ACL を値を出さずに確かめる",
            // Linux の bootstrap-notion-tokens.sh の # tool: claude と、home/modules/claude.nix が notion-tokens.json を置くホスト (claude.enable)
            gate: Gate::Tool("windowsClaudeCode"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let path = join_segments(&ctx.roots.user_profile, REL);
        let desired = ctx.host.notion.tokens_json();
        let mut rows = vec![generated::sync(
            ctx,
            mode,
            &path,
            desired.as_bytes(),
            "notion-tokens.json",
        )];
        rows.extend(env_rows(ctx));
        rows
    }
}

/// env の様子 (普通のファイルか無いとき)。
enum EnvFile {
    Missing,
    Bytes(Vec<u8>),
    /// NUL がある (UTF-16 などで保存された。pjp も読めない)
    Nul,
}

/// 宣言したプロファイルごとの行の有る無しの行と、env の ACL の行 (env が無いときは ACL の行を出さない)。Linux の bootstrap-notion-tokens.sh
/// と同じ順に確かめる (宣言 → 置き場所 → 普通のファイルか → 行 → 権限)。
fn env_rows(ctx: &mut Ctx) -> Vec<Outcome> {
    let tokens: Vec<(String, NotionToken)> = ctx
        .host
        .notion
        .tokens
        .iter()
        .map(|(n, t)| (n.clone(), t.clone()))
        .collect();
    if tokens.is_empty() {
        ctx.say(format!(
            "Notion の API キーの宣言はありません ([claude.notion.tokens])。{WHAT} は見ません。"
        ));
        return vec![Outcome::new(
            Kind::Ok,
            "Notion の API キーの宣言は無い ([claude.notion.tokens])",
        )];
    }
    let path = match local_env::env_path(ctx) {
        Ok(p) => p,
        Err(rel) => {
            local_env::warn(
                ctx,
                &[
                    format!(
                        "XDG_CONFIG_HOME ({rel}) が相対パスなので、{WHAT} に Notion の API キーの行があるかを確かめません。"
                    ),
                    "pjp は打った場所から読むことになるので、絶対パスにするか外してください。"
                        .to_string(),
                ],
            );
            return vec![
                Outcome::new(
                    Kind::Manual,
                    format!("XDG_CONFIG_HOME が相対パス → {WHAT} の Notion の API キーを確かめない"),
                )
                .note(
                    "XDG_CONFIG_HOME を絶対パスにするか外して、dotfiles apply --steps local-env,notion-tokens",
                ),
            ];
        }
    };
    let shown = path.display().to_string();
    let file = match std::fs::symlink_metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => EnvFile::Missing,
        Err(e) => {
            ctx.say(format!("!! 確かめられません: {shown} ({e})"));
            return vec![Outcome::new(
                Kind::Failed,
                format!("{WHAT} を確かめられない ({e})"),
            )];
        }
        Ok(m) if m.file_type().is_symlink() => {
            local_env::warn(
                ctx,
                &[
                    format!("{shown} は symlink なので、Notion の API キーの行があるかを確かめません。"),
                    "local-env と pjp notion-profile set-token も symlink には書きません。symlink をやめて、実体のファイルを置いてください。".to_string(),
                ],
            );
            return vec![
                Outcome::new(
                    Kind::Manual,
                    format!("{WHAT} が symlink → Notion の API キーを確かめない"),
                )
                .note("symlink をやめて実体のファイルを置いてから dotfiles apply --steps local-env,notion-tokens"),
            ];
        }
        Ok(m) if !m.is_file() => {
            local_env::warn(
                ctx,
                &[
                    format!("{shown} が普通のファイルではないので、Notion の API キーの行があるかを確かめられません。"),
                    "普通のファイルにしてから、pjp notion-profile set-token <名前> で入れてください。".to_string(),
                ],
            );
            return vec![Outcome::new(
                Kind::Manual,
                format!("{WHAT} が普通のファイルではない → Notion の API キーを確かめない"),
            )];
        }
        Ok(_) => match std::fs::read(&path) {
            Ok(b) if b.contains(&0) => EnvFile::Nul,
            Ok(b) => EnvFile::Bytes(b),
            Err(e) => {
                local_env::warn(
                    ctx,
                    &[
                        format!(
                            "{shown} を読めないので、Notion の API キーの行があるかを確かめられません ({e})。"
                        ),
                        format!("icacls \"{shown}\" で持ち主と ACL を見てください。"),
                    ],
                );
                return vec![Outcome::new(
                    Kind::Failed,
                    format!("{WHAT} を読めない ({e})"),
                )];
            }
        },
    };

    ctx.say(format!(
        "Notion の API キーの宣言 ([claude.notion.tokens]) を {shown} で確かめます (値は出しません)。"
    ));
    let presence = match &file {
        EnvFile::Nul => {
            local_env::warn(
                ctx,
                &[
                    format!(
                        "{shown} に NUL があるので、Notion の API キーの行を数えません (UTF-16 で保存された、など。pjp も読めません)。"
                    ),
                    "メモ帳の「名前を付けて保存」で文字コードを UTF-8 にして保存し直してください (local-env の知らせと同じ)。".to_string(),
                ],
            );
            Outcome::new(
                Kind::Manual,
                format!(
                    "{WHAT} が UTF-16 などで保存されている (NUL がある) → pjp が読めないので、Notion の API キーの行を数えない"
                ),
            )
            .note("メモ帳で UTF-8 にして保存し直してから dotfiles apply --steps local-env,notion-tokens")
        }
        EnvFile::Bytes(b) => presence_row(ctx, &shown, &tokens, Some(b)),
        EnvFile::Missing => presence_row(ctx, &shown, &tokens, None),
    };
    let mut rows = vec![presence];
    if !matches!(file, EnvFile::Missing) {
        let vars: Vec<String> = tokens.iter().map(|(n, _)| token_var(n)).collect();
        rows.push(acl_row(ctx, &path, &vars));
    }
    rows
}

/// 宣言したプロファイルごとに行を数え、入っていれば「入っています」、無ければ入れ方を `!!` で出す (bash の版と同じ文)。`data` は env の
/// 中身 (None は env が無い)。
fn presence_row(
    ctx: &mut Ctx,
    shown: &str,
    tokens: &[(String, NotionToken)],
    data: Option<&[u8]>,
) -> Outcome {
    let mut present = Vec::new();
    let mut missing = Vec::new();
    for (name, t) in tokens {
        let var = token_var(name);
        let label = t.kind.label();
        if data.is_some_and(|d| count_lines(d, &var) > 0) {
            ctx.say(format!("  入っています: {name} ({label}) の {var} の行"));
            present.push(format!("{name} ({var})"));
            continue;
        }
        let where_ = if data.is_some() {
            format!("{shown} にその行が無い")
        } else {
            format!("{shown} が無い")
        };
        let how = set_token_how(name, t);
        local_env::warn(
            ctx,
            &[
                format!(
                    "Notion の API キーが入っていません: プロファイル {name} ({label}) の {var} ({where_})。ホストの値の [claude.notion.tokens] で宣言したプロファイルです。"
                ),
                format!("入れ方: {how}。"),
            ],
        );
        missing.push((format!("{name} ({var})"), format!("{name}: {how}")));
    }
    if missing.is_empty() {
        return Outcome::new(
            Kind::Ok,
            format!("Notion の API キーは入っている: {}", present.join("・")),
        );
    }
    let what: Vec<&str> = missing.iter().map(|(w, _)| w.as_str()).collect();
    let mut o = Outcome::new(
        Kind::Manual,
        format!("Notion の API キーが入っていない: {}", what.join("・")),
    );
    for (_, how) in missing {
        o = o.note(how);
    }
    o
}

/// 入れ方 (bash の版と同じ字)。値はユーザーが自分の端末で入れ、Claude には打たせない (dotfiles-private の ADR 112)
fn set_token_how(name: &str, t: &NotionToken) -> String {
    let source = match &t.item {
        Some(item) => format!("値は 1Password の {item}"),
        None => "値は 1Password に置いた元の値".to_string(),
    };
    format!(
        "ユーザーが自分の端末で pjp notion-profile set-token {name} を打つ ({source}。Claude には打たせない)"
    )
}

/// `var` の行の数。claude-skills の pjp-notion-profile の `count_token_lines` と同じ数え方: ファイルの頭の BOM を外し、`<var>=` で始まり、= の後ろの
/// 値の末尾の空白 (Python の rstrip と同じ字) を落として空でない行。値は持たず、数だけを返す
fn count_lines(data: &[u8], var: &str) -> usize {
    let head = format!("{var}=");
    let body = data.strip_prefix(BOM).unwrap_or(data);
    body.split(|b| *b == b'\n')
        .filter(|l| {
            l.strip_prefix(head.as_bytes()).is_some_and(|rest| {
                !String::from_utf8_lossy(rest)
                    .trim_end_matches(py_space)
                    .is_empty()
            })
        })
        .count()
}

/// Python の `str.isspace` と同じ字 (Unicode の空白と、`\x1c`〜`\x1f`。claude-skills の pycompat の is_space と同じ)
fn py_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// env の ACL の行。読む権限を許す規則が本人と SYSTEM・Administrators だけなら ✔、ほかにもあれば ⚠ と直し方 (書き換えない)。
fn acl_row(ctx: &mut Ctx, path: &Path, vars: &[String]) -> Outcome {
    let shown = path.display().to_string();
    let look = format!(
        "icacls \"{shown}\" で、本人と SYSTEM・Administrators のほかに読める人がいないかを見る"
    );
    let Some(shell) = ps1::find_powershell(ctx) else {
        ctx.say(format!(
            "!! PowerShell が見つからない (pwsh・powershell) ので、{shown} の ACL を確かめられません。"
        ));
        return Outcome::new(
            Kind::Failed,
            format!(
                "PowerShell が見つからない (pwsh・powershell) ので、{WHAT} の ACL を確かめられない"
            ),
        )
        .note(look);
    };
    let acl = match read_acl(ctx.sys, &shell, path) {
        Ok(a) => a,
        Err(e) => {
            ctx.say(format!(
                "!! {shown} の ACL を確かめられませんでした ({e})。"
            ));
            return Outcome::new(
                Kind::Failed,
                format!("{WHAT} の ACL を確かめられない ({e})"),
            )
            .note(look);
        }
    };
    let wide = wide_readers(&acl);
    if wide.is_empty() {
        ctx.say("  ACL: 本人と SYSTEM・Administrators だけが読めます");
        return Outcome::new(
            Kind::Ok,
            format!("{WHAT} を読めるのは本人と SYSTEM・Administrators だけ"),
        );
    }
    let who = wide.join("・");
    let dir = path
        .parent()
        .map(|d| d.display().to_string())
        .unwrap_or_default();
    let mut lines = vec![
        format!(
            "{shown} を、本人と SYSTEM・Administrators のほかに {who} も読めます (Notion の API キー {} を置くファイル)。",
            vars.join("・")
        ),
        format!(
            "env は書き直すたびに置き場所のディレクトリ ({dir}) の ACL を継ぎます。{dir} の ACL から、その人たちの読む権限を外してください (icacls \"{dir}\" と icacls \"{shown}\" で見る)。"
        ),
    ];
    let mut o = Outcome::new(
        Kind::Manual,
        format!("{WHAT} を本人と SYSTEM・Administrators のほかも読める: {who}"),
    )
    .note(format!(
        "置き場所のディレクトリの ACL から {who} の読む権限を外す (env は書き直すたびにディレクトリの ACL を継ぐ。icacls \"{dir}\" で見る。runner は ACL を書き換えない)"
    ));
    if ctx
        .sys
        .env("XDG_CONFIG_HOME")
        .is_some_and(|v| !v.is_empty())
    {
        lines.push(
            "XDG_CONFIG_HOME で %USERPROFILE% の外に置いているなら、XDG_CONFIG_HOME を外して %USERPROFILE%\\.config\\pjp\\env に移すのが早い道です (%USERPROFILE% の下は、継いだ ACL で本人と SYSTEM・Administrators だけが読めます)。".to_string(),
        );
        o = o.note(
            "XDG_CONFIG_HOME を外して %USERPROFILE%\\.config\\pjp\\env に移す (%USERPROFILE% の下は継いだ ACL で本人と SYSTEM・Administrators だけ)",
        );
    }
    local_env::warn(ctx, &lines);
    o
}

/// ACL の答え (`READ_ACL`)。`claude-account audit` も token のファイルの ACL をこれで読む (同じ「広い」の数え方)。
#[derive(Debug)]
pub(crate) struct Acl {
    /// 今のユーザーの SID
    me: String,
    /// 持ち主の SID (読めなければ空)
    owner: String,
    rules: Vec<AclRule>,
}

/// ACL の規則 1 つ。
#[derive(Debug)]
struct AclRule {
    /// 許す規則か (false は拒む規則)
    allow: bool,
    /// 権限 (FileSystemRights のビット)
    rights: u32,
    /// 自分に効かず、下に継がせるだけの規則か
    inherit_only: bool,
    sid: String,
    /// 名前 (読めなければ空)
    name: String,
}

/// PowerShell でファイルの ACL を読む。
pub(crate) fn read_acl(sys: &dyn Sys, shell: &Path, path: &Path) -> Result<Acl, String> {
    let spec = CommandSpec::new(shell)
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-Command")
        .arg(READ_ACL)
        .env("DOTFILES_ACL_PATH", path)
        .timeout(Duration::from_secs(60));
    let r = sys.run(&spec, &mut |_| {});
    if r.code() != Some(0) {
        return Err(format!("{:?}: {}", r.exit, r.output.join(" / ")));
    }
    parse_acl(&r.output)
}

/// `READ_ACL` の出力を読む (行末の CR は外す)。今のユーザーの SID が無い・規則の行の形が違うなら誤り。
fn parse_acl(lines: &[String]) -> Result<Acl, String> {
    let mut me = String::new();
    let mut owner = String::new();
    let mut rules = Vec::new();
    for line in lines {
        let l = line.trim_end_matches('\r');
        if let Some(v) = l.strip_prefix("me=") {
            me = v.to_string();
        } else if let Some(v) = l.strip_prefix("owner=") {
            owner = v.to_string();
        } else if let Some(v) = l.strip_prefix("rule=") {
            let bad = || format!("ACL の規則の行を読めない: {l}");
            let fields: Vec<&str> = v.splitn(5, '|').collect();
            let [kind, rights, propagation, sid, name] = fields.as_slice() else {
                return Err(bad());
            };
            let rights: i64 = rights.parse().map_err(|_| bad())?;
            let propagation: i64 = propagation.parse().map_err(|_| bad())?;
            rules.push(AclRule {
                allow: *kind == "Allow",
                // [int] の FileSystemRights は GENERIC_READ (0x80000000) などで負になる。下の 32 ビットがそのままビット
                rights: rights as u32,
                inherit_only: propagation & INHERIT_ONLY != 0,
                sid: sid.to_string(),
                name: name.to_string(),
            });
        }
    }
    if me.is_empty() {
        return Err(format!(
            "今のユーザーの SID (me=) が答えに無い: {}",
            lines.join(" / ")
        ));
    }
    Ok(Acl { me, owner, rules })
}

/// 中身を読む権限を許されている人 (OWNER RIGHTS は持ち主の SID に読み替えた SID と、名前 (無ければ規則の SID)。規則の順で、同じ人も並ぶ)。
/// 拒む規則・自分に効かない規則 (InheritOnly・CREATOR OWNER・CREATOR GROUP) は数えない。拒む規則を差し引かないので、読める側に寄せる
fn readers(acl: &Acl) -> Vec<(&str, String)> {
    let mut out = Vec::new();
    for r in &acl.rules {
        if !r.allow
            || r.inherit_only
            || r.rights & READ_BITS == 0
            || CREATORS.contains(&r.sid.as_str())
        {
            continue;
        }
        let sid = if r.sid == OWNER_RIGHTS {
            acl.owner.as_str()
        } else {
            r.sid.as_str()
        };
        let shown = if r.name.is_empty() {
            r.sid.clone()
        } else {
            r.name.clone()
        };
        out.push((sid, shown));
    }
    out
}

/// 本人 (今のユーザー)・SYSTEM・Administrators のほかに、中身を読む権限を許されている人 (名前、無ければ SID。並びは規則の順で、同じ人は 1 度)。
/// 数え方は `readers` (拒む規則・自分に効かない規則は数えない。OWNER RIGHTS は持ち主として見る。読める側に寄せて知らせる)
pub(crate) fn wide_readers(acl: &Acl) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for (sid, shown) in readers(acl) {
        if sid == acl.me || TRUSTED.contains(&sid) {
            continue;
        }
        if !out.contains(&shown) {
            out.push(shown);
        }
    }
    out
}

/// 読める人の要約 (棚卸しの表の権限の列。claude-skills の棚卸しの道具と同じ字): 広ければ「ACL 広い」、そうでなければ読める人を SYSTEM・
/// Administrators・本人の順に並べ (本人だけなら「ACL 本人だけ」。set-token が付ける形)、誰も読めなければ「ACL 読める人なし」
pub(crate) fn acl_summary(acl: &Acl) -> String {
    if !wide_readers(acl).is_empty() {
        return "ACL 広い".to_string();
    }
    let rs = readers(acl);
    let has = |want: &str| rs.iter().any(|(sid, _)| *sid == want);
    let mut parts = Vec::new();
    if has(TRUSTED[0]) {
        parts.push("SYSTEM");
    }
    if has(TRUSTED[1]) {
        parts.push("Administrators");
    }
    if has(acl.me.as_str()) {
        parts.push("本人");
    }
    match parts.as_slice() {
        [] => "ACL 読める人なし".to_string(),
        ["本人"] => "ACL 本人だけ".to_string(),
        _ => format!("ACL {}", parts.join("・")),
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! notion-tokens.json:
    //!
    //! - ホストの値の [claude.notion.tokens] から %USERPROFILE%\.local\state\dotfiles\notion-tokens.json を書く (check と dry-run は書かない。
    //!   同じなら揃っている)。宣言が無くても {"tokens":{}} を書く
    //!
    //! env の行 (Linux の nix/tests/bootstrap-notion-tokens.test.sh を写したもの):
    //!
    //! - 宣言したプロファイルの変数の行 (頭が <var>= で、= の後ろの値が空白だけでない行) があれば「入っています」と変数名を出し、無ければ
    //!   プロファイルの名前・種類・変数名と、入れ方 (ユーザーが自分の端末で pjp notion-profile set-token <名前> を打つ。item があればその
    //!   1Password の参照) を !! で出し、行を ⚠ (manual) にする。2 つのうち 1 つだけ無ければ、その 1 つだけを知らせる
    //! - 数えない行: # で始まる・頭に空白がある・<var>X=・export <var>=・= の後ろが空か CR・空白だけ (CRLF の行の末尾の CR は値に数えない)。
    //!   ファイルの頭の UTF-8 の BOM は外して読む (pjp と棚卸しの count_token_lines と同じ。bash の版とは、この 2 つだけ違う)
    //! - env が無くても、行が無いのと同じく知らせる (ファイルは作らない。ACL は見ない)
    //! - 宣言が無ければ「宣言はありません」と出して ✔ にし、env を見ない (ACL も見ない)
    //! - XDG_CONFIG_HOME (空でない絶対パス) があれば <XDG_CONFIG_HOME>\pjp\env を見る。相対パスなら見ない (⚠)
    //! - env が symlink・普通のファイルでないなら見ない (⚠)。NUL がある (UTF-16 など) なら行を数えずに ⚠ にする (pjp も読めない)。ACL は見る
    //!
    //! env の ACL:
    //!
    //! - 読む権限 (ReadData・GENERIC_READ・GENERIC_ALL) を許す規則が、本人 (今のユーザーの SID)・SYSTEM・Administrators だけなら ✔、ほかにも
    //!   あれば、その名前 (無ければ SID) を !! で出して ⚠ (manual) にし、直し方 (置き場所のディレクトリの ACL・icacls) を添える
    //! - 数えない規則: 拒否・InheritOnly (自分に効かない)・読む権限の無いもの (ReadPermissions だけなど)・CREATOR OWNER と CREATOR GROUP。
    //!   OWNER RIGHTS は持ち主の SID として見る
    //! - PowerShell に渡すのは env のパス (env の DOTFILES_ACL_PATH) だけで、PowerShell が無い・落ちた・読めない答えは ⚠ (failed) と icacls の手
    //! - Windows では本物の PowerShell と icacls で、継承を切って本人と SYSTEM・Administrators だけにしたディレクトリのファイルを ✔、Everyone に
    //!   読む権限を足したファイルを ⚠ と読む
    //!
    //! どのときも:
    //!
    //! - env を書き換えない (中身が変わらない)。値 (作り物の値) は出力にも締めの行にも ※ にも出さない
    //! - Linux の CI で、bash の版 (nix/scripts/bootstrap-notion-tokens.sh) と同じ notion-tokens.json と env から、入っている・いないとした
    //!   プロファイル・入れ方の行・宣言が無いときの知らせが同じ

    use super::*;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::process::{Exit, RunResult};
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::{Path, PathBuf};

    /// 値を出していないかを確かめるための、試験用の秘密の値
    const SECRET: &str = "ntn_test_secret_do_not_print";
    /// 試験の今のユーザーの SID
    const ME: &str = "S-1-5-21-1000-2000-3000-1001";
    /// 作り物の 1Password の参照 (vault・項目の ID の形の字。本物ではない)
    const ITEM: &str = "op://abcdefghijklmnopqrstuvwxyz/zyxwvutsrqponmlkjihgfedcba/credential";
    const APPLY: Mode = Mode::Apply { force: false };
    const DRY: Mode = Mode::DryRun { force: false };

    fn personal() -> String {
        format!("[claude.notion.tokens.personal]\nkind = \"personal\"\nitem = \"{ITEM}\"\n")
    }

    /// PowerShell が返す ACL: 本人と SYSTEM・Administrators の継いだ規則 (%USERPROFILE% の下の形) に `extra` を足したもの
    fn acl_lines(owner: &str, extra: &[&str]) -> Vec<String> {
        let mut v = vec![
            format!("me={ME}"),
            format!("owner={owner}"),
            "rule=Allow|2032127|0|S-1-5-18|NT AUTHORITY\\SYSTEM".to_string(),
            "rule=Allow|2032127|0|S-1-5-32-544|BUILTIN\\Administrators".to_string(),
            format!("rule=Allow|2032127|0|{ME}|PC\\alice"),
        ];
        v.extend(extra.iter().map(|s| s.to_string()));
        v
    }

    /// `lines` を返す偽の pwsh
    fn pwsh(lines: Vec<String>) -> FakeSys {
        FakeSys::new(move |_| RunResult {
            exit: Exit::Code(0),
            output: lines.clone(),
        })
        .with_program("pwsh", "C:/Program Files/PowerShell/7/pwsh.exe")
    }

    /// 本人と SYSTEM・Administrators だけが読める env の偽の pwsh
    fn trusted() -> FakeSys {
        pwsh(acl_lines(ME, &[]))
    }

    /// 打たれない口 (env と ACL を見ないとき)
    fn untouched() -> FakeSys {
        FakeSys::new(|c| panic!("打たないはず: {:?}", c.args_lossy()))
            .with_program("pwsh", "C:/Program Files/PowerShell/7/pwsh.exe")
    }

    /// 1 ケースぶんの場所 (ホーム) とホストの値。
    struct Case {
        t: TempDir,
        host: String,
    }

    impl Case {
        fn new(tag: &str, host: &str) -> Self {
            Case {
                t: TempDir::new(tag),
                host: host.to_string(),
            }
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        fn env_file(&self) -> PathBuf {
            self.home().join(".config").join("pjp").join("env")
        }

        fn json(&self) -> PathBuf {
            self.home()
                .join(".local")
                .join("state")
                .join("dotfiles")
                .join("notion-tokens.json")
        }

        fn put(&self, bytes: &[u8]) {
            std::fs::create_dir_all(self.env_file().parent().unwrap()).unwrap();
            std::fs::write(self.env_file(), bytes).unwrap();
        }

        /// 手順を流し、行と出力を返す (値が出ていないことも確かめる)
        fn run(&self, sys: &FakeSys, mode: Mode) -> (Vec<Outcome>, String) {
            let mut out = Vec::new();
            let rows = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.t.path().join("state"),
                    host: parse(&self.host, Path::new("h.toml"), Groups::embedded().unwrap())
                        .unwrap(),
                    sys,
                    out: &mut out,
                };
                NotionTokens.run(&mut ctx, mode)
            };
            let out = String::from_utf8(out).unwrap();
            assert!(!out.contains(SECRET), "出力に値が出た: {out}");
            for o in &rows {
                assert!(!o.text.contains(SECRET), "行に値が出た: {o:?}");
                for n in &o.notes {
                    assert!(!n.contains(SECRET), "※ に値が出た: {n}");
                }
            }
            (rows, out)
        }
    }

    #[test]
    fn info() {
        let i = NotionTokens.info();
        assert_eq!(i.id, "notion-tokens");
        assert_eq!(i.order, 55);
        // Linux の bootstrap-notion-tokens.sh の # tool: claude と、claude-notion.json を書く手順 claude-notion と同じ道具
        assert_eq!(i.gate, Gate::Tool("windowsClaudeCode"));
        assert!(i.ported && i.windows_only);
    }

    /// 宣言から notion-tokens.json を書き、入っている行と ACL を ✔ にする (check と dry-run は書かない。env には触れない)
    #[test]
    fn writes_the_json_and_sees_the_line() {
        let c = Case::new("notion-tokens-ok", &personal());
        let env = format!("# メモ\nPJP_NOTION_TOKEN_PERSONAL={SECRET}\n");
        c.put(env.as_bytes());
        let want = format!(
            "{{\"tokens\":{{\"personal\":{{\"item\":\"{ITEM}\",\"kind\":\"personal\",\"var\":\"PJP_NOTION_TOKEN_PERSONAL\"}}}}}}\n"
        );

        for mode in [Mode::Check, DRY] {
            let (rows, _) = c.run(&trusted(), mode);
            assert_eq!(rows.len(), 3, "{rows:?}");
            assert_eq!(rows[0].kind, Kind::Missing, "{rows:?}");
            assert!(!c.json().exists());
        }
        let sys = trusted();
        let (rows, out) = c.run(&sys, APPLY);
        assert_eq!(rows[0].kind, Kind::Ok, "{rows:?}");
        assert_eq!(std::fs::read_to_string(c.json()).unwrap(), want);
        assert_eq!(rows[1].kind, Kind::Ok, "{rows:?}");
        assert!(
            rows[1]
                .text
                .contains("personal (PJP_NOTION_TOKEN_PERSONAL)"),
            "{rows:?}"
        );
        assert_eq!(rows[2].kind, Kind::Ok, "{rows:?}");
        assert!(
            out.contains(&format!(
                "Notion の API キーの宣言 ([claude.notion.tokens]) を {} で確かめます (値は出しません)。",
                c.env_file().display()
            )),
            "{out}"
        );
        assert!(
            out.contains("  入っています: personal (個人用アクセストークン) の PJP_NOTION_TOKEN_PERSONAL の行"),
            "{out}"
        );
        assert!(!out.contains("!! "), "{out}");
        // PowerShell に渡すのは env のパスだけ
        let calls = sys.calls.borrow();
        assert_eq!(calls.len(), 1);
        assert_eq!(
            calls[0].env_value("DOTFILES_ACL_PATH").as_deref(),
            Some(c.env_file().to_str().unwrap())
        );
        drop(calls);
        assert_eq!(std::fs::read(c.env_file()).unwrap(), env.as_bytes());

        let (rows, _) = c.run(&trusted(), Mode::Check);
        assert_eq!(rows[0].kind, Kind::Ok, "{rows:?}");
    }

    /// 宣言が無ければ {"tokens":{}} を書き、env を見ない (無くても知らせない)
    #[test]
    fn no_declarations_do_not_look_at_env() {
        let c = Case::new(
            "notion-tokens-none",
            "[claude.notion]\nprofile = \"personal\"\n",
        );
        let (rows, out) = c.run(&untouched(), APPLY);
        assert_eq!(rows.len(), 2, "{rows:?}");
        assert_eq!(rows[0].kind, Kind::Ok, "{rows:?}");
        assert_eq!(
            std::fs::read_to_string(c.json()).unwrap(),
            "{\"tokens\":{}}\n"
        );
        assert_eq!(rows[1].kind, Kind::Ok, "{rows:?}");
        assert!(
            out.contains("Notion の API キーの宣言はありません"),
            "{out}"
        );
        assert!(!out.contains("!! "), "{out}");
        assert!(!c.env_file().exists());
    }

    /// 行が無ければ、プロファイル・種類・変数名と入れ方 (item の参照) を知らせて ⚠ にする。ACL は見る
    #[test]
    fn missing_line_tells_how_to_set_it() {
        let c = Case::new("notion-tokens-missing", &personal());
        c.put(format!("# PJP_NOTION_TOKEN_PERSONAL={SECRET}\nOTHER_KEY={SECRET}\n").as_bytes());
        let (rows, out) = c.run(&trusted(), Mode::Check);
        assert_eq!(rows.len(), 3, "{rows:?}");
        assert_eq!(rows[1].kind, Kind::Manual, "{rows:?}");
        assert!(
            rows[1]
                .text
                .contains("Notion の API キーが入っていない: personal (PJP_NOTION_TOKEN_PERSONAL)"),
            "{rows:?}"
        );
        assert!(
            rows[1].notes[0].contains("pjp notion-profile set-token personal"),
            "{rows:?}"
        );
        assert!(rows[1].notes[0].contains(ITEM), "{rows:?}");
        assert!(
            rows[1].notes[0].contains("Claude には打たせない"),
            "{rows:?}"
        );
        assert!(
            out.contains(&format!(
                "!! Notion の API キーが入っていません: プロファイル personal (個人用アクセストークン) の PJP_NOTION_TOKEN_PERSONAL ({} にその行が無い)。ホストの値の [claude.notion.tokens] で宣言したプロファイルです。",
                c.env_file().display()
            )),
            "{out}"
        );
        assert!(
            out.contains(&format!(
                "\n   入れ方: ユーザーが自分の端末で pjp notion-profile set-token personal を打つ (値は 1Password の {ITEM}。Claude には打たせない)。\n"
            )),
            "{out}"
        );
        assert_eq!(rows[2].kind, Kind::Ok, "{rows:?}");

        // item を書いていなければ、1Password に置いた元の値と添える
        let c = Case::new(
            "notion-tokens-missing-noitem",
            "[claude.notion.tokens.personal]\nkind = \"integration\"\n",
        );
        c.put(b"");
        let (rows, out) = c.run(&trusted(), Mode::Check);
        assert_eq!(rows[1].kind, Kind::Manual, "{rows:?}");
        assert!(
            out.contains("pjp notion-profile set-token personal を打つ (値は 1Password に置いた元の値。Claude には打たせない)。"),
            "{out}"
        );
        assert!(out.contains("(integration の API キー)"), "{out}");
    }

    /// env が無くても行が無いのと同じく知らせ、作らない (ACL は見ない)
    #[test]
    fn missing_env_file() {
        let c = Case::new("notion-tokens-noenv", &personal());
        let (rows, out) = c.run(&untouched(), APPLY);
        assert_eq!(rows.len(), 2, "{rows:?}");
        assert_eq!(rows[1].kind, Kind::Manual, "{rows:?}");
        assert!(
            out.contains(&format!("({} が無い)", c.env_file().display())),
            "{out}"
        );
        assert!(!c.env_file().exists());
    }

    /// 2 つのプロファイルのうち、行の無い 1 つだけを知らせる
    #[test]
    fn only_the_missing_profile_is_told() {
        let c = Case::new(
            "notion-tokens-two",
            &format!(
                "{}[claude.notion.tokens.work]\nkind = \"integration\"\n",
                personal()
            ),
        );
        c.put(format!("PJP_NOTION_TOKEN_WORK={SECRET}\r\n").as_bytes());
        let (rows, out) = c.run(&trusted(), Mode::Check);
        assert_eq!(rows[1].kind, Kind::Manual, "{rows:?}");
        assert!(rows[1].text.contains("personal"), "{rows:?}");
        assert!(!rows[1].text.contains("work"), "{rows:?}");
        assert_eq!(rows[1].notes.len(), 1, "{rows:?}");
        assert!(
            out.contains(
                "  入っています: work (integration の API キー) の PJP_NOTION_TOKEN_WORK の行"
            ),
            "{out}"
        );
        assert_eq!(
            out.matches("!! Notion の API キーが入っていません").count(),
            1
        );
    }

    /// pjp が読む行だけを数える (Linux の試験の数えない形と、Windows の BOM・空白だけの値)
    #[test]
    fn counts_only_lines_pjp_reads() {
        let var = "PJP_NOTION_TOKEN_PERSONAL";
        for (env, want) in [
            ("PJP_NOTION_TOKEN_PERSONAL=x\n", 1),
            ("PJP_NOTION_TOKEN_PERSONAL=x\r\n", 1),
            ("A=1\nPJP_NOTION_TOKEN_PERSONAL=x", 1),
            (
                "PJP_NOTION_TOKEN_PERSONAL=x\nPJP_NOTION_TOKEN_PERSONAL=y\n",
                2,
            ),
            ("\u{feff}PJP_NOTION_TOKEN_PERSONAL=x\n", 1),
            ("# PJP_NOTION_TOKEN_PERSONAL=x\n", 0),
            (" PJP_NOTION_TOKEN_PERSONAL=x\n", 0),
            ("PJP_NOTION_TOKEN_PERSONALX=x\n", 0),
            ("export PJP_NOTION_TOKEN_PERSONAL=x\n", 0),
            ("PJP_NOTION_TOKEN_PERSONAL=\n", 0),
            ("PJP_NOTION_TOKEN_PERSONAL=\r\n", 0),
            ("PJP_NOTION_TOKEN_PERSONAL= \t\r\n", 0),
            ("A=1\n\u{feff}PJP_NOTION_TOKEN_PERSONAL=x\n", 0),
            ("", 0),
        ] {
            assert_eq!(count_lines(env.as_bytes(), var), want, "{env:?}");
        }
    }

    /// 本人と SYSTEM・Administrators のほかに読める人がいれば、名前と直し方を知らせて ⚠ にする
    #[test]
    fn wide_acl_is_told() {
        let c = Case::new("notion-tokens-wide", &personal());
        c.put(format!("PJP_NOTION_TOKEN_PERSONAL={SECRET}\n").as_bytes());
        let sys = pwsh(acl_lines(
            ME,
            &[
                "rule=Allow|1179785|0|S-1-1-0|Everyone",
                "rule=Allow|-2147483648|0|S-1-5-32-545|BUILTIN\\Users",
                "rule=Allow|1179785|0|S-1-5-21-9-9-9-1002|",
            ],
        ));
        let (rows, out) = c.run(&sys, Mode::Check);
        assert_eq!(rows[1].kind, Kind::Ok, "{rows:?}");
        assert_eq!(rows[2].kind, Kind::Manual, "{rows:?}");
        assert!(
            rows[2]
                .text
                .contains("Everyone・BUILTIN\\Users・S-1-5-21-9-9-9-1002"),
            "{rows:?}"
        );
        let dir = c.env_file().parent().unwrap().display().to_string();
        assert!(
            rows[2]
                .notes
                .iter()
                .any(|n| n.contains(&format!("icacls \"{dir}\""))),
            "{rows:?}"
        );
        assert!(
            out.contains(&format!(
                "!! {} を、本人と SYSTEM・Administrators のほかに Everyone・BUILTIN\\Users・S-1-5-21-9-9-9-1002 も読めます (Notion の API キー PJP_NOTION_TOKEN_PERSONAL を置くファイル)。",
                c.env_file().display()
            )),
            "{out}"
        );
        // XDG_CONFIG_HOME で外に置いていなければ、外す案は出さない
        assert!(!out.contains("XDG_CONFIG_HOME"), "{out}");
    }

    /// 読ませない規則・自分に効かない規則は数えない。OWNER RIGHTS は持ち主として見る
    #[test]
    fn rules_that_do_not_let_others_read() {
        let ok = |owner: &str, extra: &[&str]| {
            let acl = parse_acl(&acl_lines(owner, extra)).unwrap();
            wide_readers(&acl)
        };
        let none: Vec<String> = Vec::new();
        // 拒否・InheritOnly・ReadPermissions と WriteData だけ・CREATOR OWNER と CREATOR GROUP・持ち主が本人の OWNER RIGHTS
        assert_eq!(
            ok(
                ME,
                &[
                    "rule=Deny|1179785|0|S-1-1-0|Everyone",
                    "rule=Allow|1179785|2|S-1-1-0|Everyone",
                    "rule=Allow|131074|0|S-1-5-32-545|BUILTIN\\Users",
                    "rule=Allow|2032127|0|S-1-3-0|CREATOR OWNER",
                    "rule=Allow|2032127|0|S-1-3-1|CREATOR GROUP",
                    "rule=Allow|2032127|0|S-1-3-4|OWNER RIGHTS",
                ],
            ),
            none
        );
        // GENERIC_ALL と、持ち主がほかの人の OWNER RIGHTS は読める人に数える。同じ人は 1 度だけ
        assert_eq!(
            ok(
                "S-1-5-21-9-9-9-1002",
                &[
                    "rule=Allow|268435456|0|S-1-5-11|NT AUTHORITY\\Authenticated Users",
                    "rule=Allow|1|0|S-1-5-11|NT AUTHORITY\\Authenticated Users",
                    "rule=Allow|1179785|0|S-1-3-4|OWNER RIGHTS",
                ],
            ),
            vec![
                "NT AUTHORITY\\Authenticated Users".to_string(),
                "OWNER RIGHTS".to_string()
            ]
        );
        // CRLF の行 (Windows の PowerShell の出力) も読む
        let acl = parse_acl(&[
            format!("me={ME}\r"),
            "owner=\r".to_string(),
            "rule=Allow|1179785|0|S-1-1-0|Everyone\r".to_string(),
        ])
        .unwrap();
        assert_eq!(acl.me, ME);
        assert_eq!(wide_readers(&acl), vec!["Everyone".to_string()]);
        // 今のユーザーが分からない・規則の形が違う答えは誤り
        assert!(parse_acl(&["owner=x".to_string()]).is_err());
        assert!(parse_acl(&[format!("me={ME}"), "rule=Allow|x|0|S-1-1-0|".to_string()]).is_err());
        assert!(parse_acl(&[format!("me={ME}"), "rule=Allow|1|0".to_string()]).is_err());
    }

    /// ACL を読めないとき (PowerShell が無い・落ちた・答えの形が違う) は ⚠ (failed) と icacls の手
    #[test]
    fn acl_failures_are_failed() {
        let c = Case::new("notion-tokens-acl-fail", &personal());
        c.put(format!("PJP_NOTION_TOKEN_PERSONAL={SECRET}\n").as_bytes());
        let failed = FakeSys::new(|_| RunResult {
            exit: Exit::Code(1),
            output: vec!["error: Attempted to perform an unauthorized operation.".to_string()],
        })
        .with_program("pwsh", "C:/pwsh.exe");
        let garbled = pwsh(vec!["hello".to_string()]);
        let no_shell = FakeSys::new(|_| unreachable!());
        for sys in [failed, garbled, no_shell] {
            let (rows, out) = c.run(&sys, Mode::Check);
            assert_eq!(rows[1].kind, Kind::Ok, "{rows:?}");
            assert_eq!(rows[2].kind, Kind::Failed, "{rows:?}");
            assert!(
                rows[2]
                    .notes
                    .iter()
                    .any(|n| n.contains(&format!("icacls \"{}\"", c.env_file().display()))),
                "{rows:?}"
            );
            assert!(out.contains("!! "), "{out}");
        }
    }

    /// symlink・普通のファイルでない env は見ない (ACL も見ない)。NUL のある env は行を数えずに知らせ、ACL は見る
    #[test]
    fn odd_env_files() {
        let c = Case::new("notion-tokens-dir", &personal());
        std::fs::create_dir_all(c.env_file()).unwrap();
        let (rows, out) = c.run(&untouched(), Mode::Check);
        assert_eq!(rows.len(), 2, "{rows:?}");
        assert_eq!(rows[1].kind, Kind::Manual, "{rows:?}");
        assert!(rows[1].text.contains("普通のファイルではない"), "{rows:?}");
        assert!(out.contains("!! "), "{out}");

        let c = Case::new("notion-tokens-link", &personal());
        let target = c.t.path().join("real-env");
        std::fs::write(&target, format!("PJP_NOTION_TOKEN_PERSONAL={SECRET}\n")).unwrap();
        std::fs::create_dir_all(c.env_file().parent().unwrap()).unwrap();
        let made = crate::testutil::fake_file_symlink(
            c.env_file().to_str().unwrap(),
            target.to_str().unwrap(),
        );
        // Windows で symlink を張れない (開発者モードでも管理者でもない) なら飛ばす
        if made.exit == Exit::Code(0) {
            let (rows, _) = c.run(&untouched(), Mode::Check);
            assert_eq!(rows.len(), 2, "{rows:?}");
            assert_eq!(rows[1].kind, Kind::Manual, "{rows:?}");
            assert!(rows[1].text.contains("symlink"), "{rows:?}");
        }

        let c = Case::new("notion-tokens-nul", &personal());
        c.put(b"P\0J\0P\0_\0=\0x\0\n\0");
        let (rows, out) = c.run(&trusted(), Mode::Check);
        assert_eq!(rows.len(), 3, "{rows:?}");
        assert_eq!(rows[1].kind, Kind::Manual, "{rows:?}");
        assert!(rows[1].text.contains("UTF-16"), "{rows:?}");
        assert!(!out.contains("入っていません"), "{out}");
        assert_eq!(rows[2].kind, Kind::Ok, "{rows:?}");
    }

    /// XDG_CONFIG_HOME (空でない絶対パス) の下を見る。相対パスなら見ない
    #[test]
    fn xdg_config_home() {
        let c = Case::new("notion-tokens-xdg", &personal());
        let xdg = c.t.path().join("xdg");
        let env = xdg.join("pjp").join("env");
        std::fs::create_dir_all(env.parent().unwrap()).unwrap();
        std::fs::write(&env, format!("PJP_NOTION_TOKEN_PERSONAL={SECRET}\n")).unwrap();
        let sys = pwsh(acl_lines(
            ME,
            &["rule=Allow|1179785|0|S-1-5-32-545|BUILTIN\\Users"],
        ))
        .with_env("XDG_CONFIG_HOME", xdg.to_str().unwrap());
        let (rows, out) = c.run(&sys, Mode::Check);
        assert_eq!(rows[1].kind, Kind::Ok, "{rows:?}");
        assert!(out.contains(&env.display().to_string()), "{out}");
        assert_eq!(
            sys.calls.borrow()[0]
                .env_value("DOTFILES_ACL_PATH")
                .as_deref(),
            Some(env.to_str().unwrap())
        );
        // %USERPROFILE% の外に置いているなら、外して既定の置き場へ移す案も添える
        assert_eq!(rows[2].kind, Kind::Manual, "{rows:?}");
        assert!(
            rows[2].notes.iter().any(|n| n.contains("XDG_CONFIG_HOME")),
            "{rows:?}"
        );

        let rel = untouched().with_env("XDG_CONFIG_HOME", "rel/dir");
        let (rows, out) = c.run(&rel, Mode::Check);
        assert_eq!(rows.len(), 2, "{rows:?}");
        assert_eq!(rows[1].kind, Kind::Manual, "{rows:?}");
        assert!(rows[1].text.contains("XDG_CONFIG_HOME"), "{rows:?}");
        assert!(out.contains("!! "), "{out}");
    }

    /// 本物の PowerShell と icacls で ACL を読む (Windows だけ)
    #[cfg(windows)]
    #[test]
    fn reads_a_real_acl() {
        use crate::process::{CommandSpec, RealSys};
        let Some(shell) = RealSys
            .which("pwsh")
            .or_else(|| RealSys.which("powershell"))
        else {
            return;
        };
        let t = TempDir::new("notion-tokens-real-acl");
        let dir = t.path().join("pjp");
        std::fs::create_dir_all(&dir).unwrap();
        // 継承を切り、本人と SYSTEM・Administrators だけが (下にも継いで) 持つディレクトリにする (%USERPROFILE% の下と同じ形)
        let protect = "$ErrorActionPreference = 'Stop'; $acl = New-Object System.Security.AccessControl.DirectorySecurity; $acl.SetAccessRuleProtection($true, $false); foreach ($s in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')) { $rule = New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($s)), [System.Security.AccessControl.FileSystemRights]::FullControl, ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'), [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow); $acl.AddAccessRule($rule) }; Set-Acl -LiteralPath ([string]$env:DOTFILES_ACL_DIR) -AclObject $acl";
        let r = RealSys.run(
            &CommandSpec::new(&shell)
                .arg("-NoProfile")
                .arg("-NonInteractive")
                .arg("-Command")
                .arg(protect)
                .env("DOTFILES_ACL_DIR", &dir),
            &mut |_| {},
        );
        assert_eq!(r.exit, Exit::Code(0), "{:?}", r.output);
        let file = dir.join("env");
        std::fs::write(&file, b"X=1\n").unwrap();
        let acl = read_acl(&RealSys, &shell, &file).unwrap();
        assert!(acl.me.starts_with("S-1-5-"), "{acl:?}");
        assert_eq!(wide_readers(&acl), Vec::<String>::new(), "{acl:?}");
        // Everyone に読む権限を足すと、読める人に数える
        let icacls = RealSys.which("icacls").expect("icacls が無い");
        let r = RealSys.run(
            &CommandSpec::new(icacls)
                .arg(&file)
                .arg("/grant")
                .arg("*S-1-1-0:(R)"),
            &mut |_| {},
        );
        assert_eq!(r.exit, Exit::Code(0), "{:?}", r.output);
        let acl = read_acl(&RealSys, &shell, &file).unwrap();
        assert_eq!(wide_readers(&acl).len(), 1, "{acl:?}");
        assert!(
            acl.rules.iter().any(|r| r.allow && r.sid == "S-1-1-0"),
            "{acl:?}"
        );
    }

    /// bash の版 (nix/scripts/bootstrap-notion-tokens.sh) と同じ notion-tokens.json と env から流し、入っている・いないとしたプロファイル・
    /// 入れ方の行・宣言が無いときの知らせが同じかを見る。Windows だけの決まり (頭の BOM・空白だけの値) の入力と、権限 (Linux は mode、
    /// Windows は ACL) は比べない
    #[cfg(unix)]
    #[test]
    fn matches_bash() {
        use crate::hooks::parity;
        use std::os::unix::fs::PermissionsExt;
        if !parity::available() {
            return;
        }
        let script = parity::repo_file("nix/scripts/bootstrap-notion-tokens.sh");
        let two = format!(
            "{}[claude.notion.tokens.work]\nkind = \"integration\"\n",
            personal()
        );
        let cases: Vec<(&str, String, Option<String>)> = vec![
            ("none", String::new(), None),
            ("none-env", String::new(), Some(format!("PJP_NOTION_TOKEN_PERSONAL={SECRET}\n"))),
            ("present", personal(), Some(format!("PJP_NOTION_TOKEN_PERSONAL={SECRET}\n"))),
            ("no-env", personal(), None),
            ("empty", personal(), Some(String::new())),
            (
                "two",
                two.clone(),
                Some(format!(
                    "# PJP_NOTION_TOKEN_PERSONAL={SECRET}\n PJP_NOTION_TOKEN_PERSONAL={SECRET}\nexport PJP_NOTION_TOKEN_PERSONAL={SECRET}\nPJP_NOTION_TOKEN_PERSONALX={SECRET}\nPJP_NOTION_TOKEN_PERSONAL=\r\nPJP_NOTION_TOKEN_WORK={SECRET}\r\n"
                )),
            ),
            (
                "two-both",
                two,
                Some(format!(
                    "PJP_NOTION_TOKEN_WORK={SECRET}\nPJP_NOTION_TOKEN_PERSONAL={SECRET}"
                )),
            ),
            (
                "dash",
                "[claude.notion.tokens.my-ws]\nkind = \"personal\"\nitem = \"op://Private Vault/My Item/s1/credential\"\n".to_string(),
                Some(format!("PJP_NOTION_TOKEN_MY_WS={SECRET}\n")),
            ),
        ];
        for (tag, host, env) in cases {
            let c = Case::new(&format!("notion-tokens-parity-{tag}"), &host);
            if let Some(e) = &env {
                c.put(e.as_bytes());
                std::fs::set_permissions(c.env_file(), std::fs::Permissions::from_mode(0o600))
                    .unwrap();
            }
            let (_, ours) = c.run(&trusted(), APPLY);
            let out = std::process::Command::new("bash")
                .arg(&script)
                .env("HOME", c.home())
                .env_remove("XDG_CONFIG_HOME")
                .env_remove("DOTFILES_SETUP_WARNINGS")
                .output()
                .unwrap();
            assert_eq!(
                out.status.code(),
                Some(0),
                "{tag}: bash の版が 0 で終わらない"
            );
            let bash = format!(
                "{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            assert!(!bash.contains(SECRET), "{tag}: bash の版が値を出した");
            let what = format!("{tag}\n--- bash\n{bash}\n--- runner\n{ours}");
            assert_eq!(
                names(&ours, "  入っています: "),
                names(&bash, "  入っています: "),
                "{what}"
            );
            let missing = "Notion の API キーが入っていません: プロファイル ";
            assert_eq!(names(&ours, missing), names(&bash, missing), "{what}");
            assert_eq!(how(&ours), how(&bash), "{what}");
            let none = "Notion の API キーの宣言はありません";
            assert_eq!(ours.contains(none), bash.contains(none), "{what}");
            assert!(!bash.contains("形が違います"), "{what}");
        }
    }

    /// `head` の後ろから ` (` の手前までの名前 (行ごと)
    #[cfg(unix)]
    fn names(out: &str, head: &str) -> Vec<String> {
        out.lines()
            .filter_map(|l| {
                let rest = &l[l.find(head)? + head.len()..];
                Some(rest[..rest.find(" (")?].to_string())
            })
            .collect()
    }

    /// 入れ方の行 (頭の空白を外したもの)
    #[cfg(unix)]
    fn how(out: &str) -> Vec<String> {
        out.lines()
            .map(str::trim_start)
            .filter(|l| l.starts_with("入れ方: "))
            .map(str::to_string)
            .collect()
    }
}
