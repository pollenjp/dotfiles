//! ssh-config (order 91): dotfiles-private の `ssh/*.ssh_config` を `%USERPROFILE%\.ssh\config.d\` へ写し、`%USERPROFILE%\.ssh\config` を置く。WSL の
//! `nix/scripts/bootstrap-windows-ssh-config.sh` を写したもの (書く中身・書く先・記録・判定・退避と消し方・確かめをそろえる。受け持ちを runner に
//! 切り替えた後に、WSL の setup が置いたものを同じものとして引き継ぐため)。
//!
//! Windows の `ssh.exe` は `%USERPROFILE%\.ssh\config` を読む。そこに WSL と同じ形 (`config` は Include の 1 行とこのマシンを名乗る SetEnv、接続先は
//! `config.d\<名前>.ssh_config`) を置く。`config` と `config.d\<名前>.ssh_config` の 1 つずつを、files と同じ判定 (`deploy::judge`) で決める:
//!
//! | 置き先 | すること | 行の種類 (apply の前) |
//! | --- | --- | --- |
//! | 無い | コピーする | missing |
//! | 正本と同じ中身 | 何もしない (記録が無ければ記録だけする) | ok |
//! | 記録と同じ中身 (正本とは違う) | 正本が更新された。上書きする | fix |
//! | `config` が旧経路の `Include ~/dotfiles/ssh_config` の 1 行だけ | 置き換える | fix |
//! | それ以外 | 衝突。diff を出して触らない (`--force` なら元を `<名前>.dotfiles-bak-<日時>` に退避して上書き) | manual |
//!
//! - 記録は `%LOCALAPPDATA%\dotfiles\state\windows-ssh-config.deployed.json` (`{"version":1,"files":{"<.ssh からの相対パス>":"<sha256>"}}`)。名前・形・鍵は
//!   WSL の `~/.local/state/dotfiles/windows-ssh-config.deployed.json` と同じ (`record::FileRecords`)。WSL の記録は読まない (dotfiles-private の
//!   docs/adr/058_win_runner_bootstrap_* §2 H): 受け持ちを切り替えた後の初めての apply は、WSL が置いたファイルを「同じ」と見て記録だけ作る
//! - 記録にあって正本から消えたファイルは、置き先が記録と同じなら消す。違えば衝突 (`--force` なら退避して消す)。記録に無いファイル (ほかの道具が
//!   書いたもの) には触らない
//! - 正本は dotfiles-private の clone (runner の clone の隣か bootstrap の置き場。`Ctx::sibling`) の `ssh/` 直下の `*.ssh_config` (通常のファイル
//!   だけ。`.` で始まる名前は bash の glob と同じく読まない)。無い・空なら何も書かず消さない
//! - check と apply は `ssh -v -G nonexistent.invalid` を流し、読んだファイルを確かめる (WSL は書いた後にいつも流す。dry-run は流さない)。アクセス権で
//!   弾かれる・読み終えられない・置いたファイルが読まれない・旧 clone の `ssh_config` を読んだ、なら manual。ssh を呼べない・応答しないときは、手で
//!   打つコマンドを添えて進む
//!
//! ## SSH の中継 (ホストの値の `[tools] opReasonSshRelay`。1Password の switch も要る)
//!
//! on なら `config.d\00-op-reason-ssh-relay.ssh_config` (中継のファイル) に、どの接続先にも効く `IdentityAgent` (op-reason の中継の pipe
//! `\\.\pipe\op-reason-ssh-agent`) を書き、ほかの config.d のファイルと同じく記録で管理する。名前の頭の `00-` で config.d の最初に読ませ、接続先ごとの
//! `IdentityAgent` より先に効かせる (ssh は最初に得た値を採る)。`config` は変えない (WSL の script と同じ字のまま)。中継は手順 op-reason (90) が
//! logon の task で起こす。置く前に `%LOCALAPPDATA%\Programs\op-reason\op-reason.exe --ssh-agent --status` で答えるかを見る:
//!
//! | 中継 | すること |
//! | --- | --- |
//! | 答える | 置く (記録どおりに上書きもする) |
//! | 答えない・前に置いていない | 置かずに ⚠ (初めての apply で ssh が全部失敗するのを避ける。ssh は今までどおり 1Password に直に行く) |
//! | 答えない・前に置いたものがある | 消さずに ⚠ (中継が落ちている間に、黙って 1Password へ直に回さない。鍵は使えない) |
//!
//! - op-reason.exe が無いのも答えないとみなす。dotfiles-private の `ssh/` に同じ名前のファイルがあれば、中継のファイルは置かずに ⚠
//! - check と dry-run は、中継が今は答えなくても、前に置いていなければ置くと予告する (apply では手順 op-reason が先に中継を起こす)
//! - 正本 (`ssh/`) が空・読めないときは、中継のファイルも置かず消さない。switch が on なのに無い・off なのに残っているときは、黙らずに ⚠
//!   (行は manual。読めないときは failed のまま注記に足す)
//! - switch を切れば、記録にある中継のファイルを、正本から消えたものと同じく消す (Windows で変えていれば衝突)

use super::deploy::{self, Action, Gone, Problem, Tally};
use super::ps1::ps_quote;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::process::{CommandSpec, Exit};
use crate::record::FileRecords;
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// 記録のファイル名 (WSL の `~/.local/state/dotfiles/` の記録と同じ名前)
pub const RECORD_FILE: &str = "windows-ssh-config.deployed.json";
/// `config` の中身 (WSL の script の `config_body` と同じバイト列。Nix 管理の WSL の `~/.ssh/config` の Include と `Host *` の SetEnv に、持ち主を示す
/// コメントを添えたもの。dotfiles-private の docs/adr/016_ssh_config_from_dotfiles_private_*・025_*)
const CONFIG_BODY: &str = "\
# dotfiles の nix/scripts/bootstrap-windows-ssh-config.sh が置く (手で直すと次の setup で衝突になる)。
# マシン固有の Host は config.d\\ に <名前>.ssh_config として置く。
# config.d はファイル名の順に読み、同じキーは先に読んだ値が効く。
Include config.d/*.ssh_config

# ssh 先の herdr が「同じマシンから来た接続」を見分けるのに、このマシンを名乗る (dotfiles の ADR 025)。
# 受け取る側の sshd に AcceptEnv PJP_SSH_CLIENT が要る。ssh は最初に当たった SetEnv の行だけを使うので、
# config.d の Host に SetEnv を書いたら、そこにも PJP_SSH_CLIENT=%u@%L を足す。
Host *
  SetEnv PJP_SSH_CLIENT=%u@%L
";
/// 旧経路が置いた `config` の 1 行 (WSL の script の `legacy_line`)。これだけの `config` は衝突にせず置き換える
const LEGACY_LINE: &str = "Include ~/dotfiles/ssh_config";
/// 確かめで ssh を待つ秒数 (WSL の `check_timeout` の既定)
const CHECK_SECS: u64 = 30;
/// 確かめを手で打つコマンド (WSL の script の manual_check と同じ)
const MANUAL_CHECK: &str =
    "ssh -v -G nonexistent.invalid 2>&1 | Select-String 'Reading configuration'";
/// SSH の中継のファイルの名前と記録の鍵 (`.ssh` からの相対パス。上の「SSH の中継」)
const RELAY_NAME: &str = "00-op-reason-ssh-relay.ssh_config";
const RELAY_KEY: &str = "config.d/00-op-reason-ssh-relay.ssh_config";
/// 中継のファイルの中身。中継の pipe は op-reason の既定 (`\\.\pipe\op-reason-ssh-agent`)。OpenSSH は設定の `\\` を 1 つの `\` と読むので、頭の 2 つを
/// 重ねる (op-reason の README)。置き主・中継が止まると鍵が使えないこと・1 回だけ直につなぐ書き方をコメントに書く
const RELAY_BODY: &str = r"# dotfiles の Windows の runner (dotfiles apply の手順 ssh-config) が置く (ホストの値の [tools] opReasonSshRelay のときだけ。手で直すと次の apply で衝突になる)。
# どの接続先でも、ssh の鍵は op-reason の SSH の中継 (op-reason.exe --ssh-agent。logon の task が起こす) を通す。
# config.d の最初に読まれるので、接続先ごとの IdentityAgent より先に効く。中継が動いていなければ鍵は使えない。
# 1 回だけ 1Password に直につなぐ: ssh -o 'IdentityAgent=\\\\.\pipe\openssh-ssh-agent' <接続先> (dotfiles の win/README.md の「SSH の中継」)。
IdentityAgent \\\\.\pipe\op-reason-ssh-agent
";
/// 1 回だけ 1Password に直につなぐ書き方 (OpenSSH は -o の `\\` も 1 つの `\` と読むので、頭の 2 つを重ねる)
const RELAY_DIRECT: &str = r"ssh -o 'IdentityAgent=\\\\.\pipe\openssh-ssh-agent' <接続先>";
/// 中継の --status を待つ秒数 (WSL の script の timeout 15 と同じ)
const RELAY_STATUS_SECS: u64 = 15;
/// 記録が壊れていたときの直し方 (WSL と同じ)
const BROKEN_HINT: &str = "消してから流し直すと、Windows 側に既にあるファイルは衝突として扱われます (中身を確かめて、dotfiles-private へ取り込むか --force)";

pub struct SshConfig;

impl Step for SshConfig {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "ssh-config",
            order: 91,
            title: "dotfiles-private の ssh の設定を %USERPROFILE%\\.ssh へ写す",
            gate: Gate::Always,
            ported: true,
            windows_only: false,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        sync(ctx, mode)
    }
}

/// 写す 1 件。
struct Item {
    /// 記録の鍵 (`.ssh` からの相対パス。`/` 区切り)
    key: String,
    dst: PathBuf,
    bytes: Vec<u8>,
    /// 正本のファイル (`config` は組み立てた中身なので無い)
    src: Option<PathBuf>,
}

/// 手順の中身。WSL の script と同じ順に確かめる (正本 → 記録 → 1 件ずつの判定 → 正本から消えたもの → 記録を書く → ssh で確かめる)。
/// 行は 1 つ (dotfiles-private の clone の core.autocrlf が true なら、その行を前に足す)。
fn sync(ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
    let private = ctx.sibling("dotfiles-private");
    let src_dir = private.join("ssh");
    let srcs = match sources(&src_dir) {
        Ok(s) => s,
        Err(e) => {
            ctx.say(format!(
                "!! 正本の一覧を読めません: {} ({e})。何も書かず、消しません。",
                src_dir.display()
            ));
            let mut o = Outcome::new(
                Kind::Failed,
                "正本 (dotfiles-private の ssh/) の一覧を読めない (何も書かず、消していない)",
            )
            .note(e.to_string());
            for l in relay_mismatch_without_sources(ctx) {
                say_failed(ctx, std::slice::from_ref(&l));
                o = o.note(l);
            }
            return vec![o];
        }
    };
    if srcs.is_empty() {
        ctx.say(format!(
            "!! Windows の ssh の設定を配りません: 正本の *.ssh_config がありません ({})。",
            src_dir.display()
        ));
        ctx.say(
            "   dotfiles-private を取れていないか、ssh/ が空です。Windows 側のファイルはそのまま残します。",
        );
        // 中継のファイルは正本から来ないので、正本が無くても食い違いを黙らない (置けない・消せないことを ⚠ にする)
        let relay = relay_mismatch_without_sources(ctx);
        for l in &relay {
            say_failed(ctx, std::slice::from_ref(l));
        }
        let kind = if relay.is_empty() {
            Kind::Info
        } else {
            Kind::Manual
        };
        let mut o = Outcome::new(
            kind,
            "正本 (dotfiles-private の ssh/*.ssh_config) が無いので配らない (Windows 側のファイルはそのまま)",
        )
        .note(format!(
            "dotfiles-private の clone を確かめる ({})。bootstrap が %USERPROFILE%\\ghq\\github.com\\pollenjp\\dotfiles-private に clone する",
            src_dir.display()
        ));
        for l in relay {
            o = o.note(l);
        }
        return vec![o];
    }
    let record_path = ctx.state_dir.join(RECORD_FILE);
    let mut records = match FileRecords::load(&record_path, BROKEN_HINT) {
        Ok(r) => r,
        Err(e) => {
            ctx.say(format!("!! {e}"));
            return vec![Outcome::new(Kind::Failed, "配った記録が壊れている").note(e)];
        }
    };
    // clone の core.autocrlf が true だと、正本が CRLF で取り出され、WSL が置いた LF と中身が合わずに全部が衝突に見える (diff では見えない)
    let crlf = deploy::autocrlf_outcome(ctx, &private, "dotfiles-private");
    let ssh_dir = join_segments(&ctx.roots.user_profile, ".ssh");
    let mut tally = Tally::default();

    // 計画: config と、正本の 1 つずつ (読めない正本も鍵は計画に入れる。正本から消えたと読んで消さないため)
    let mut planned = vec!["config".to_string()];
    let mut items = vec![Item {
        key: "config".to_string(),
        dst: ssh_dir.join("config"),
        bytes: CONFIG_BODY.as_bytes().to_vec(),
        src: None,
    }];
    for src in &srcs {
        let Some(name) = src.file_name() else {
            continue;
        };
        let key = format!("config.d/{}", name.to_string_lossy());
        planned.push(key.clone());
        match std::fs::read(src) {
            Ok(bytes) => items.push(Item {
                key,
                dst: ssh_dir.join("config.d").join(name),
                bytes,
                src: Some(src.clone()),
            }),
            Err(e) => {
                ctx.say(format!("!! 正本が読めません: {} ({e})", src.display()));
                tally.errors += 1;
            }
        }
    }

    // SSH の中継のファイル (上の「SSH の中継」)。ほかの config.d のファイルと同じく計画に足す (計画の並びは置く順だけで、ssh が読む順は名前の順)
    let mut relay_notes = Vec::new();
    let mut relay_manual = false;
    if let Some(relay_mode) = ctx.host.ssh_relay().map(str::to_string) {
        let dst = ssh_dir.join("config.d").join(RELAY_NAME);
        let mut warn = |ctx: &mut Ctx, lines: &[String]| {
            say_failed(ctx, lines);
            relay_notes.extend(lines.iter().cloned());
            relay_manual = true;
        };
        let place = if planned.iter().any(|k| k == RELAY_KEY) {
            warn(
                ctx,
                &[
                    format!(
                        "dotfiles-private の ssh/ に、SSH の中継のファイルと同じ名前 ({RELAY_NAME}) があるので、中継の IdentityAgent を置けません。"
                    ),
                    "dotfiles-private のそのファイルの名前を替えてください (それまで Windows と WSL の ssh は、中継を通らずに 1Password に直に行きます)。".to_string(),
                ],
            );
            false
        } else {
            match relay_status(ctx) {
                Ok(()) => true,
                Err(why) if records.get(RELAY_KEY).is_some() && dst.is_file() => {
                    warn(
                        ctx,
                        &[
                            "SSH の中継 (ホストの値の opReasonSshRelay) が答えません。Windows の ssh の設定の IdentityAgent は中継を指したままなので、中継が起きるまで Windows と WSL の ssh は鍵を使えません。".to_string(),
                            format!("中継: {why}"),
                            "op-reason の task が 1 分のうちに中継を起こし直します。中継を止めた (通知領域の鍵のアイコンの「止める」・relay stop) ときは起き直らないので、op-reason.exe --settings relay start で起こす (答えるかは op-reason.exe --ssh-agent --status)".to_string(),
                            format!("1 回だけ 1Password に直につなぐ: {RELAY_DIRECT}"),
                        ],
                    );
                    true
                }
                Err(why) if !mode.writes() => {
                    // check と dry-run: apply では手順 op-reason (90) が先に中継を起こすので、置くと予告する
                    let line = format!(
                        "SSH の中継が今は答えません ({why})。apply では手順 op-reason (90) が中継を起こしてから置きます (起きなければ置かずに知らせます)。"
                    );
                    ctx.say(&line);
                    relay_notes.push(line);
                    true
                }
                Err(why) => {
                    warn(
                        ctx,
                        &[
                            "SSH の中継 (ホストの値の opReasonSshRelay) が答えないので、Windows の ssh の設定に IdentityAgent を書いていません (Windows と WSL の ssh は、今までどおり 1Password に直に行きます)。".to_string(),
                            format!("中継: {why}"),
                            format!(
                                "上の手順 op-reason の出力を見て中継を起こしてから (dotfiles apply --steps op-reason。PowerShell なら Install-OpReason -SshRelay {relay_mode})、dotfiles apply --steps ssh-config を流し直してください。"
                            ),
                        ],
                    );
                    false
                }
            }
        };
        if place {
            planned.push(RELAY_KEY.to_string());
            items.push(Item {
                key: RELAY_KEY.to_string(),
                dst,
                bytes: RELAY_BODY.as_bytes().to_vec(),
                src: None,
            });
        }
    }

    let force = mode.force();
    for item in &items {
        place_one(ctx, mode, force, item, &mut records, &mut tally);
    }
    let planned_files: Vec<PathBuf> = items.iter().map(|i| i.dst.clone()).collect();
    for key in records.keys() {
        if !planned.contains(&key) {
            remove_gone(
                ctx,
                mode,
                force,
                &ssh_dir,
                &key,
                &planned_files,
                &mut records,
                &mut tally,
            );
        }
    }

    if mode.writes()
        && let Err(e) = records.save_if_changed()
    {
        ctx.say(format!(
            "!! 配った記録を書けません: {} ({e})",
            record_path.display()
        ));
        tally.errors += 1;
    }

    // 書いたあとの確かめ: ssh に読ませて、読んだファイルを見る (dry-run は書かないので流さない。WSL と同じ)。check は今の状態を見るが、apply で
    // 書く・消すものが残っていれば、apply の後に確かめる (旧経路の config や、まだ無い config を差と読まないため)
    let pending = tally.copied + tally.updated + tally.removed > 0;
    let verified = if matches!(mode, Mode::DryRun { .. }) {
        None
    } else if mode == Mode::Check && pending {
        ctx.say("ssh.exe で読むファイルの確かめは、apply で書く・消すものが無くなってから流す (今は流さない)。");
        None
    } else {
        let expect: Vec<String> = planned
            .iter()
            .filter(|k| join_segments(&ssh_dir, k).is_file())
            .cloned()
            .collect();
        Some(verify(ctx, &ssh_dir, &expect, planned.len() - 1))
    };

    let mut summary = tally.summary(mode, true);
    ctx.say("");
    ctx.say(&summary);
    let mut kind = tally.kind(mode);
    let mut notes = Vec::new();
    if let Some(v) = verified {
        if !v.failed.is_empty() {
            if kind != Kind::Failed {
                kind = Kind::Manual;
            }
            notes.extend(v.failed.iter().map(|l| l.trim_start().to_string()));
        } else if v.checked {
            summary.push_str(" (ssh.exe が読むことも確かめた)");
        }
        notes.extend(v.unverified);
    }
    if relay_manual && kind != Kind::Failed {
        kind = Kind::Manual;
    }
    notes.extend(relay_notes);
    if tally.conflicts > 0 {
        notes.push(deploy::conflict_note(
            ctx,
            "ssh-config",
            "Windows 側の中身を dotfiles-private の ssh/ へ取り込む",
            "この dotfiles-private の clone",
        ));
    }
    let mut outcome = Outcome::new(kind, summary);
    outcome.notes = notes;
    crlf.into_iter().chain(std::iter::once(outcome)).collect()
}

/// 1 件を判定して、mode のとおりに出す・書く (files と同じ形の出力)。
fn place_one(
    ctx: &mut Ctx,
    mode: Mode,
    force: bool,
    item: &Item,
    records: &mut FileRecords,
    tally: &mut Tally,
) {
    let shown = item.dst.display().to_string();
    let want = fsutil::sha256_bytes(&item.bytes);
    let recorded = records.get(&item.key).map(str::to_string);
    let replaceable: &dyn Fn(&[u8]) -> bool = if item.key == "config" {
        &is_legacy_config
    } else {
        &deploy::never
    };
    let action = match deploy::judge(&item.dst, &want, recorded.as_deref(), force, replaceable) {
        Ok(a) => a,
        Err(Problem::Directory) => {
            ctx.say(format!("!! 置き先がディレクトリです: {shown}"));
            tally.errors += 1;
            return;
        }
        Err(Problem::Unreadable(e)) => {
            ctx.say(format!("!! 置き先が読めません: {shown} ({e})"));
            tally.errors += 1;
            return;
        }
    };
    match action {
        Action::Same => {
            tally.count(action);
            ctx.say(format!("同じです: {shown}"));
            if recorded.as_deref() != Some(want.as_str()) && mode.writes() {
                records.set(&item.key, &want);
            }
        }
        Action::Conflict => {
            tally.count(action);
            if recorded.is_some() {
                ctx.say(format!(
                    "!! 衝突: {shown} は Windows 側で変わっています (前回ここへ置いた中身と違う)。"
                ));
            } else {
                ctx.say(format!(
                    "!! 衝突: {shown} は、置いた記録が無く、正本と中身が違います (置く前から Windows 側にあった。手で書いたものなど。受け持ちを切り替える前なら、WSL が配った中身とこの dotfiles-private の clone の中身が違う)。"
                ));
            }
            match &item.src {
                Some(src) => {
                    deploy::show_diff(ctx, &item.dst, src);
                    ctx.say(format!(
                        "   Windows 側の中身を残すなら: Copy-Item -LiteralPath '{}' -Destination '{}' (PowerShell。取り込んだら dotfiles-private で commit して push する)",
                        ps_quote(&shown),
                        ps_quote(&src.to_string_lossy())
                    ));
                }
                None if item.key == RELAY_KEY => {
                    deploy::show_diff_bytes(ctx, &item.dst, &item.bytes, RELAY_NAME);
                    ctx.say("   Windows 側の中身を残すなら: 中継のファイルは runner が置くので、手で書いた行は dotfiles-private の ssh/ の別の名前のファイルへ移し、commit して push する");
                }
                None => {
                    deploy::show_diff_bytes(ctx, &item.dst, &item.bytes, "config");
                    ctx.say("   Windows 側の中身を残すなら: config に手で書いた Host を config.d\\<名前>.ssh_config へ移し、dotfiles-private の ssh/ へ取り込んで commit して push する");
                }
            }
            let again = deploy::force_command(ctx, "ssh-config");
            ctx.say(format!(
                "   正本で上書きするなら:   {again} (元は <名前>.dotfiles-bak-<日時> に残る)"
            ));
        }
        Action::Copy | Action::Update | Action::Replace | Action::Force => {
            let label = match action {
                Action::Copy => "コピー",
                Action::Update => "上書き (正本が更新された)",
                Action::Replace => "置き換え (旧経路の Include ~/dotfiles/ssh_config)",
                _ => "上書き (--force)",
            };
            match mode {
                Mode::Check => {
                    let what = match action {
                        Action::Copy => "無い (apply でコピーする)",
                        Action::Replace => {
                            "旧経路の Include ~/dotfiles/ssh_config の 1 行だけ (apply で置き換える)"
                        }
                        _ => "正本が更新された (apply で上書きする)",
                    };
                    ctx.say(format!("{what}: {shown}"));
                }
                Mode::DryRun { .. } => ctx.say(format!("[dry-run] {label}: {shown}")),
                Mode::Apply { .. } => {
                    match deploy::write(&item.dst, &item.bytes, action == Action::Force) {
                        Ok(bak) => {
                            records.set(&item.key, &want);
                            ctx.say(format!("{label}: {shown}"));
                            if let Some(bak) = bak {
                                ctx.say(format!("  退避した: {}", bak.display()));
                            }
                        }
                        Err(e) => {
                            ctx.say(format!("!! 書けません: {shown} ({e})"));
                            tally.errors += 1;
                            return;
                        }
                    }
                }
            }
            tally.count(action);
        }
    }
}

/// 記録にあって正本から消えた鍵 `key` の置き先を、記録どおりなら消す (違えば衝突。`--force` なら退避して消す。もう無ければ記録から外すだけ)。
#[allow(clippy::too_many_arguments)]
fn remove_gone(
    ctx: &mut Ctx,
    mode: Mode,
    force: bool,
    ssh_dir: &Path,
    key: &str,
    planned_files: &[PathBuf],
    records: &mut FileRecords,
    tally: &mut Tally,
) {
    let Some(dst) = key_path(ssh_dir, key) else {
        // 記録を手で書き換えでもしない限り無い。.ssh の外を消さないよう触らない
        ctx.say(format!(
            "!! 記録の鍵が .ssh の中のファイルを指していないので、触りません: {key} ({})",
            ssh_dir.display()
        ));
        tally.errors += 1;
        return;
    };
    let shown = dst.display().to_string();
    // 正本で名前の大小文字だけを変えると、NTFS では旧い鍵の置き先が新しい鍵の置き先と同じファイルになる。消すと、いま置いたファイルを消すので、
    // 記録から外すだけにする (WSL の script は消して、次の setup でコピーし直す)
    if same_file_as_planned(&dst, planned_files) {
        if mode.writes() {
            records.remove(key);
        }
        return;
    }
    let recorded = records.get(key).map(str::to_string);
    // 中継のファイルは、正本からではなく SSH の中継を使わなくなって (switch を切って) 消える
    let relay = key == RELAY_KEY;
    match deploy::judge_gone(&dst, recorded.as_deref(), force) {
        Ok(Gone::Missing) => {
            if mode.writes() {
                records.remove(key);
            }
        }
        Ok(Gone::Conflict) => {
            tally.conflicts += 1;
            if relay {
                ctx.say(format!(
                    "!! 衝突: {shown} は消すもの (SSH の中継を使わない) ですが、Windows 側で変わっているので消していません。"
                ));
            } else {
                ctx.say(format!(
                    "!! 衝突: {shown} は正本から消えましたが、Windows 側で変わっているので消していません。"
                ));
            }
            let again = deploy::force_command(ctx, "ssh-config");
            ctx.say(format!(
                "   消してよいなら:   {again} (元は <名前>.dotfiles-bak-<日時> に残る)"
            ));
        }
        Ok(gone @ (Gone::Remove | Gone::Force)) => {
            let why = if relay {
                "SSH の中継を使わない"
            } else {
                "正本から消えた"
            };
            let label = format!("削除 ({why})");
            match mode {
                Mode::Check => ctx.say(format!("{why} (apply で消す): {shown}")),
                Mode::DryRun { .. } => ctx.say(format!("[dry-run] {label}: {shown}")),
                Mode::Apply { .. } => match deploy::remove(&dst, gone == Gone::Force) {
                    Ok(bak) => {
                        records.remove(key);
                        ctx.say(format!("{label}: {shown}"));
                        if let Some(bak) = bak {
                            ctx.say(format!("  退避した: {}", bak.display()));
                        }
                    }
                    Err(e) => {
                        ctx.say(format!("!! 消せません: {shown} ({e})"));
                        tally.errors += 1;
                        return;
                    }
                },
            }
            tally.removed += 1;
        }
        Err(Problem::Directory) => {
            ctx.say(format!("!! 置き先がディレクトリです: {shown}"));
            tally.errors += 1;
        }
        Err(Problem::Unreadable(e)) => {
            ctx.say(format!("!! 置き先が読めません: {shown} ({e})"));
            tally.errors += 1;
        }
    }
}

/// `dst` が、計画の置き先のどれかと同じファイルか (どちらもあって、たどった先のパスが同じ。大小文字を区別しないファイルシステムの名前の違いを含む)。
fn same_file_as_planned(dst: &Path, planned_files: &[PathBuf]) -> bool {
    let Ok(real) = std::fs::canonicalize(dst) else {
        return false;
    };
    planned_files
        .iter()
        .any(|p| std::fs::canonicalize(p).is_ok_and(|q| q == real))
}

/// 記録の鍵 (`.ssh` からの `/` 区切りの相対パス) の置き先。`.ssh` の外や別のドライブを指す鍵 (空の要素・`.`・`..`・`\`・`:`) は None。
fn key_path(ssh_dir: &Path, key: &str) -> Option<PathBuf> {
    let ok = !key.is_empty()
        && key
            .split('/')
            .all(|seg| !seg.is_empty() && seg != "." && seg != ".." && !seg.contains(['\\', ':']));
    ok.then(|| join_segments(ssh_dir, key))
}

/// 正本の `*.ssh_config` (`ssh/` 直下の通常のファイル。symlink と `.` で始まる名前は読まない (WSL の bash の glob と `-f && ! -L`)。名前の順)。
/// `ssh/` が無ければ空。一覧を読めなかったら誤り (欠けた一覧で、正本から消えたと読んで置き先を消さないため)。
fn sources(dir: &Path) -> Result<Vec<PathBuf>, std::io::Error> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    let mut found = Vec::new();
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.ends_with(".ssh_config") && !name.starts_with('.') && entry.file_type()?.is_file() {
            found.push(entry.path());
        }
    }
    found.sort();
    Ok(found)
}

/// `config` が旧経路の Include の 1 行だけか (WSL の is_legacy_config: 頭の BOM・行末の CR・行の前後の空白・空の行は見ない)。
fn is_legacy_config(bytes: &[u8]) -> bool {
    let text = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    // sed の [[:space:]] (C の locale) と同じ空白 (Rust の trim_ascii は VT を落とさない)
    let space = |b: &u8| matches!(b, b' ' | b'\t' | b'\n' | b'\x0b' | b'\x0c' | b'\r');
    let mut lines = text
        .split(|b| *b == b'\n')
        .map(|l| {
            let start = l.iter().position(|b| !space(b)).unwrap_or(l.len());
            let end = l.iter().rposition(|b| !space(b)).map_or(start, |i| i + 1);
            &l[start..end]
        })
        .filter(|l| !l.is_empty());
    lines.next() == Some(LEGACY_LINE.as_bytes()) && lines.next().is_none()
}

/// 確かめの結果。
struct Verified {
    /// 読んだファイルを確かめた (差の有無によらず)
    checked: bool,
    /// 手で直すこと (行は manual。1 つ目が見出し、続きは 2 字下げ)
    failed: Vec<String>,
    /// 確かめられなかったわけと、手で確かめるコマンド (行に ※ で添える。行の種類は変えない)
    unverified: Option<String>,
}

/// `ssh -v -G nonexistent.invalid` を流し、`expect` (`.ssh` からの相対パス) が読まれたかを確かめる (WSL の script と同じ判定)。`n` は config.d の件数。
fn verify(ctx: &mut Ctx, ssh_dir: &Path, expect: &[String], n: usize) -> Verified {
    let unverified = |ctx: &mut Ctx, head: String, extra: &[String], why: String| {
        ctx.say(format!("!! {head}"));
        for l in extra {
            ctx.say(format!("   {l}"));
        }
        ctx.say("   Windows の PowerShell で次を打つと、読んだファイルを確かめられます:");
        ctx.say(format!("     {MANUAL_CHECK}"));
        Verified {
            checked: false,
            failed: Vec::new(),
            unverified: Some(format!("{why}。手で確かめる: {MANUAL_CHECK}")),
        }
    };
    let Some(ssh) = ctx.sys.which("ssh") else {
        return unverified(
            ctx,
            "ssh.exe が見つからないので、Windows の ssh が読むファイルを確かめていません。"
                .to_string(),
            &[],
            "ssh.exe が見つからないので、読むファイルを確かめていない".to_string(),
        );
    };
    // ssh は読んだファイルを stderr に、設定を stdout に書く (WSL は stderr だけを読む)
    let spec = CommandSpec::new(ssh)
        .arg("-v")
        .arg("-G")
        .arg("nonexistent.invalid")
        .timeout(Duration::from_secs(CHECK_SECS))
        .stderr_only();
    let r = ctx.sys.run(&spec, &mut |_| {});
    let out: Vec<&str> = r
        .output
        .iter()
        .map(|l| l.trim_end_matches(['\r', '\n']))
        .collect();
    if out.iter().any(|l| l.contains("Bad owner or permissions")) {
        let mut failed = vec![
            "ssh.exe がアクセス権を理由に設定を読みませんでした (どの接続先でも exit 255 になります):"
                .to_string(),
        ];
        failed.extend(
            out.iter()
                .filter(|l| l.contains("Bad owner") || l.contains("Bad permissions"))
                .map(|l| format!("  {l}")),
        );
        failed.push(format!(
            "  .ssh の ACL を見る: icacls.exe '{}'",
            ps_quote(&ssh_dir.to_string_lossy())
        ));
        say_failed(ctx, &failed);
        return Verified {
            checked: false,
            failed,
            unverified: None,
        };
    }
    let code = r.code();
    // 時間切れと起こせないときは、確かめられなかったものとして扱う (WSL の timeout の 124・137 と bash の 126・127 も)
    let unrunnable =
        !matches!(r.exit, Exit::Code(_)) || matches!(code, Some(124 | 126 | 127 | 137));
    if unrunnable || !out.iter().any(|l| l.contains("Reading configuration data")) {
        let why = match &r.exit {
            Exit::Code(c) => format!("終了コード {c}"),
            Exit::NoCode => "終了コードが無い".to_string(),
            Exit::TimedOut => format!("{CHECK_SECS} 秒たっても終わらなかった"),
            Exit::SpawnFailed(e) => format!("起こせなかった: {e}"),
        };
        let cause = if unrunnable {
            "ssh.exe が応答しないか、起こせません"
        } else {
            "読んだ設定のファイルの行 (debug1: Reading configuration data) が出ていません"
        };
        let head: Vec<String> = out.iter().take(5).map(|l| l.to_string()).collect();
        return unverified(
            ctx,
            format!("ssh.exe で確かめられませんでした ({why}。{cause})。"),
            &head,
            format!("ssh.exe で読むファイルを確かめられなかった ({why}。{cause})"),
        );
    }
    if code != Some(0) {
        // 設定の誤りなどで読み終えられなかった。ssh はどの接続先でも同じように失敗する
        let mut failed = vec![format!(
            "ssh.exe が設定を読み終えられませんでした (終了コード {}。どの接続先でも同じように失敗します):",
            code.unwrap_or(-1)
        )];
        failed.extend(
            out.iter()
                .filter(|l| !l.starts_with("debug"))
                .take(5)
                .map(|l| format!("  {l}")),
        );
        say_failed(ctx, &failed);
        return Verified {
            checked: false,
            failed,
            unverified: None,
        };
    }
    // ssh.exe は C:\Users\<名前>/.ssh/config のように出すので、/ 区切りの小文字に揃えて末尾で比べる
    let read: Vec<String> = out
        .iter()
        .filter_map(|l| l.strip_prefix("debug1: Reading configuration data "))
        .map(normalize)
        .collect();
    let mut failed = Vec::new();
    let missing: Vec<&String> = expect
        .iter()
        .filter(|rel| {
            let suffix = format!("/.ssh/{rel}").to_ascii_lowercase();
            !read.iter().any(|p| p.ends_with(&suffix))
        })
        .collect();
    if !missing.is_empty() {
        failed.push("ssh.exe が読まなかったファイルがあります (Include されていない):".to_string());
        for rel in missing {
            failed.push(format!("  {}", join_segments(ssh_dir, rel).display()));
        }
    }
    if read.iter().any(|p| p.ends_with("/dotfiles/ssh_config")) {
        failed.push(
            "ssh.exe が旧 clone の ssh_config を読んでいます (config が旧経路の Include のまま)。"
                .to_string(),
        );
    }
    if failed.is_empty() {
        ctx.say(format!(
            "確かめ: ssh.exe が config と config.d の {n} 件を読んだ (旧 clone の ssh_config は読んでいない)"
        ));
    } else {
        say_failed(ctx, &failed);
    }
    Verified {
        checked: true,
        failed,
        unverified: None,
    }
}

/// 置き場所 (`%LOCALAPPDATA%\Programs\op-reason`。Install-OpReason.ps1 の既定) の op-reason.exe で、SSH の中継が既定の pipe で答えるかを見る
/// (`op-reason.exe --ssh-agent --status`)。答えれば Ok。答えなければわけ (出力の頭の 3 行か、無ければ終わり方。op-reason.exe が無いのも答えない)
fn relay_status(ctx: &Ctx) -> Result<(), String> {
    let exe = join_segments(
        &ctx.roots.local_app_data,
        "Programs/op-reason/op-reason.exe",
    );
    if !exe.is_file() {
        return Err(format!("op-reason.exe が無い ({})", exe.display()));
    }
    let spec = CommandSpec::new(exe)
        .arg("--ssh-agent")
        .arg("--status")
        .timeout(Duration::from_secs(RELAY_STATUS_SECS));
    let r = ctx.sys.run(&spec, &mut |_| {});
    if r.code() == Some(0) {
        return Ok(());
    }
    let head: Vec<&str> = r
        .output
        .iter()
        .map(|l| l.trim_end_matches(['\r', '\n']))
        .filter(|l| !l.is_empty())
        .take(3)
        .collect();
    if !head.is_empty() {
        return Err(head.join(" / "));
    }
    Err(match &r.exit {
        Exit::Code(c) => format!("op-reason.exe --ssh-agent --status が終了コード {c} で終わった"),
        Exit::NoCode => "op-reason.exe --ssh-agent --status の終了コードが無い".to_string(),
        Exit::TimedOut => {
            format!(
                "op-reason.exe --ssh-agent --status が {RELAY_STATUS_SECS} 秒たっても答えなかった"
            )
        }
        Exit::SpawnFailed(e) => format!("op-reason.exe を起こせなかった: {e}"),
    })
}

/// 正本 (ssh/) が空・読めないときの、中継のファイルの食い違い (正本が無いときは何も書かず消さないので、黙らずに ⚠ の文にする)。
/// switch が on なのに置いていない (Windows の ssh は 1Password に直に行く)・switch が off なのに残っている (中継が止まると鍵を使えない)。
/// 食い違いが無ければ空
fn relay_mismatch_without_sources(ctx: &Ctx) -> Vec<String> {
    let dst = join_segments(&ctx.roots.user_profile, ".ssh")
        .join("config.d")
        .join(RELAY_NAME);
    match (ctx.host.ssh_relay().is_some(), dst.is_file()) {
        (true, false) => vec![
            "SSH の中継 (ホストの値の opReasonSshRelay) が on ですが、正本が無いので中継の IdentityAgent も置いていません (Windows と WSL の ssh は 1Password に直に行きます)。dotfiles-private の ssh/ を確かめてから流し直してください。".to_string(),
        ],
        (false, true) => vec![format!(
            "SSH の中継を使わない (ホストの値の opReasonSshRelay が off) のに、正本が無いので中継のファイルを消していません ({})。中継が止まると Windows と WSL の ssh は鍵を使えません。dotfiles-private の ssh/ を確かめてから流し直すか、そのファイルを手で消してください。",
            dst.display()
        )],
        _ => Vec::new(),
    }
}

/// 確かめの差を出す (1 行目の頭に `!!`、続きの行は字下げ)。
fn say_failed(ctx: &mut Ctx, lines: &[String]) {
    for (i, l) in lines.iter().enumerate() {
        if i == 0 {
            ctx.say(format!("!! {l}"));
        } else {
            ctx.say(format!("   {l}"));
        }
    }
}

/// ssh が出したパスを、`\` を `/` に・重なった `/` を 1 つに・ASCII の大文字を小文字にそろえる (WSL の sed と tr)。
fn normalize(p: &str) -> String {
    let mut out = String::with_capacity(p.len());
    for c in p.chars() {
        let c = if c == '\\' { '/' } else { c };
        if c == '/' && out.ends_with('/') {
            continue;
        }
        out.push(c.to_ascii_lowercase());
    }
    out
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (WSL の nix/tests/bootstrap-windows-ssh-config.test.sh と同じケースに、受け持ちで替える案内を足したもの)
    //!
    //! - 正本 (ssh/) が無い・空なら、何も書かず消さずに · で知らせる
    //! - 初めは config と ssh/ 直下の *.ssh_config (通常のファイル。README・下のディレクトリ・symlink・. で始まる名前は除く) をコピーし、記録を
    //!   相対パスで書く。2 回目は全部「同じ」。ほかの道具の config.d のファイルには触らない
    //! - 旧経路の Include の 1 行 (BOM・CRLF・空白・空の行つき) は置き換える。ほかの行があれば衝突
    //! - 手で書いた config・Windows で変えたファイルは衝突 (記録の有無で文を分ける・diff と解き方)。--force は退避して上書きする
    //! - 正本の更新 (前の版の config を含む) は上書き、正本から消えたファイルは消す (Windows で変えていれば衝突、--force で退避して消す。もう
    //!   無ければ記録から外すだけ)。.ssh の外を指す記録の鍵には触らない
    //! - check と dry-run は何も書かない (dry-run は --force の上書きと削除を予告する)。壊れた記録・ディレクトリの置き先は止める
    //! - 確かめ: 揃っている / アクセス権 / 読まれないファイル / 旧 clone / 読み終えられない / 呼べない・無い・時間切れ / 区切りと大小の違い
    //! - 受け持ちが WSL のホストでは、衝突の解き方に WSL の script の --force を出す
    //! - 順番・on/off・config の中身・旧経路の 1 行・記録の名前・確かめのコマンドと秒数が WSL の script と同じ
    //! - WSL の script と同じ状態から、同じファイルを書き・消し・退避して同じく記録する。WSL の script が置いたものを、記録の無い runner が変えずに
    //!   引き継ぐ (bash の版と突き合わせる。bash と jq がある Linux)
    //! - SSH の中継 (ホストの値の opReasonSshRelay。1Password の switch も要る): off なら中継のファイルを置かず、op-reason.exe も呼ばない。on で
    //!   中継が --status に答えれば config.d/00-op-reason-ssh-relay.ssh_config (IdentityAgent が中継の pipe) を置いて記録し、config は変えない。
    //!   2 回目は揃っている。置いた後に答えなければ残して ⚠ (鍵は使えない)。off に戻すと記録どおりに消す。初めてで答えなければ置かずに ⚠。
    //!   op-reason.exe が無いのも答えないとみなす。dotfiles-private に同じ名前があれば置かずに ⚠。check と dry-run は書かず、中継が今は答えなくても
    //!   置くと予告する (apply では op-reason の手順が先に中継を起こす)。正本が空のときは中継のファイルも置かず消さないが、on なのに無い・
    //!   off なのに残っているときは ⚠

    use super::*;
    use crate::hooks::parity;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::process::RunResult;
    use crate::testutil::{FakeSys, TempDir};

    const RUNNER_HOST: &str = "[runner]\nenable = true\n";
    /// SSH の中継を使うホスト (1Password の switch も要る)
    const RELAY_HOST: &str =
        "[tools]\nonePassword = true\nopReasonSshRelay = true\n[runner]\nenable = true\n";
    const WSL_HOST: &str = "group = \"minimum\"\n";
    const APPLY: Mode = Mode::Apply { force: false };
    const FORCE: Mode = Mode::Apply { force: true };
    const A: &str = "Host a\n  HostName a.example.test\n";
    const B: &str = "Host b\n  HostName b.example.test\n";

    /// 偽の ssh の振る舞い (WSL の試験の FAKE_SSH_MODE と同じ崩し方)
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Ssh {
        /// 読んだファイルを出して 0
        Ok,
        /// config.d の 1 つ目を読まない
        Missing,
        /// パスを \ 区切りの大文字で出す
        Backslash,
        /// config.d の 1 つ目でアクセス権を理由に 255
        BadOwner,
        /// 旧 clone の ssh_config も読む
        Legacy,
        /// 全部読んでから設定の誤りで 255
        BadOpt,
        /// 時間切れ
        Hang,
        /// 起こせない
        Broken,
        /// 0 で終わるが、読んだファイルの行を出さない
        Silent,
    }

    struct Env {
        t: TempDir,
    }

    impl Env {
        /// dotfiles-private の ssh/ に a.ssh_config と "b c.ssh_config"、ほかに無関係なもの (README・下のディレクトリ・. で始まる名前・symlink)
        fn new() -> Self {
            let t = TempDir::new("ssh-config");
            t.write("dotfiles-private/ssh/a.ssh_config", A);
            t.write("dotfiles-private/ssh/b c.ssh_config", B);
            t.write("dotfiles-private/ssh/README.md", "# not a config\n");
            t.write("dotfiles-private/ssh/sub/x.ssh_config", "Host sub\n");
            t.write("dotfiles-private/ssh/.hidden.ssh_config", "Host hidden\n");
            std::fs::create_dir_all(t.path().join("dotfiles")).unwrap();
            #[cfg(unix)]
            std::os::unix::fs::symlink(
                t.path().join("dotfiles-private/ssh/a.ssh_config"),
                t.path().join("dotfiles-private/ssh/link.ssh_config"),
            )
            .unwrap();
            Env { t }
        }

        fn private_ssh(&self) -> PathBuf {
            self.t.path().join("dotfiles-private").join("ssh")
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        fn ssh(&self) -> PathBuf {
            self.home().join(".ssh")
        }

        fn at(&self, rel: &str) -> PathBuf {
            join_segments(&self.ssh(), rel)
        }

        fn read(&self, rel: &str) -> String {
            std::fs::read_to_string(self.at(rel)).unwrap()
        }

        fn put(&self, rel: &str, s: &str) {
            let p = self.at(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, s).unwrap();
        }

        fn record(&self) -> PathBuf {
            self.t.path().join("state").join(RECORD_FILE)
        }

        fn record_json(&self) -> serde_json::Value {
            serde_json::from_str(&std::fs::read_to_string(self.record()).unwrap()).unwrap()
        }

        fn baks(&self) -> Vec<PathBuf> {
            let mut found = Vec::new();
            for dir in [self.ssh(), self.at("config.d")] {
                if let Ok(entries) = std::fs::read_dir(dir) {
                    for e in entries.flatten() {
                        if e.file_name().to_string_lossy().contains(".dotfiles-bak-") {
                            found.push(e.path());
                        }
                    }
                }
            }
            found.sort();
            found
        }

        fn sys(&self, mode: Ssh) -> FakeSys {
            fake_sys(self.ssh(), mode)
        }

        /// 置き場所 (%LOCALAPPDATA%\Programs\op-reason) の op-reason.exe (中身は使わない。答えは `relay_sys` が返す)
        fn relay_exe(&self) -> PathBuf {
            self.home()
                .join("AppData")
                .join("Local")
                .join("Programs")
                .join("op-reason")
                .join("op-reason.exe")
        }

        fn put_relay_exe(&self) {
            let exe = self.relay_exe();
            std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
            std::fs::write(exe, "").unwrap();
        }

        /// 偽の ssh (Ok) と、中継の --status に答えるか (`answers`) を決めた偽の op-reason.exe
        fn relay_sys(&self, answers: bool) -> FakeSys {
            relay_fake_sys(self.ssh(), self.relay_exe(), Ssh::Ok, answers)
        }

        fn run(&self, sys: &FakeSys, host: &str, mode: Mode) -> (Outcome, String) {
            let (mut outcomes, out) = self.run_all(sys, host, mode);
            assert_eq!(outcomes.len(), 1, "{outcomes:?}\n{out}");
            (outcomes.remove(0), out)
        }

        /// 手順を流し、行を全部 (ふつうは 1 つ。dotfiles-private の clone の core.autocrlf が true なら 2 つ) と出力を返す
        fn run_all(&self, sys: &FakeSys, host: &str, mode: Mode) -> (Vec<Outcome>, String) {
            let mut out = Vec::new();
            let outcomes = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.t.path().join("state"),
                    host: parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                    sys,
                    out: &mut out,
                };
                SshConfig.run(&mut ctx, mode)
            };
            (outcomes, String::from_utf8(out).unwrap())
        }

        fn apply(&self) -> (Outcome, String) {
            self.run(&self.sys(Ssh::Ok), RUNNER_HOST, APPLY)
        }
    }

    /// 偽の ssh (読んだファイルを stderr に出す ssh -v -G の形) と git (diff の行を返す)。`ssh` は Windows のホームの .ssh
    fn fake_sys(ssh: PathBuf, mode: Ssh) -> FakeSys {
        relay_fake_sys(ssh, PathBuf::from("/fake/op-reason.exe"), mode, true)
    }

    /// `fake_sys` に、`relay_exe` の op-reason.exe --ssh-agent --status (答えるなら 0 と pid の文、答えないなら 1。行の終わりは CRLF) を足したもの
    fn relay_fake_sys(ssh: PathBuf, relay_exe: PathBuf, mode: Ssh, answers: bool) -> FakeSys {
        FakeSys::new(move |c| {
            if c.program == relay_exe {
                return if answers {
                    RunResult {
                        exit: Exit::Code(0),
                        output: vec![
                            "the SSH relay answers on \\\\.\\pipe\\op-reason-ssh-agent (pid 42)\r".into(),
                        ],
                    }
                } else {
                    RunResult {
                        exit: Exit::Code(1),
                        output: vec!["nothing answers on \\\\.\\pipe\\op-reason-ssh-agent\r".into()],
                    }
                };
            }
            if c.program == Path::new("/fake/git") {
                return RunResult {
                    exit: Exit::Code(1),
                    output: vec![format!("diff {}", c.args_lossy().join(" "))],
                };
            }
            assert!(c.stderr_only, "ssh -v -G は stderr だけを読む");
            let mut output = vec![
                "debug1: OpenSSH_for_Windows_10.0p2 Win32-OpenSSH-GitHub, LibreSSL 4.2.0".to_string(),
            ];
            match mode {
                Ssh::Broken => {
                    return RunResult {
                        exit: Exit::SpawnFailed("Exec format error".into()),
                        output: Vec::new(),
                    };
                }
                Ssh::Hang => {
                    return RunResult {
                        exit: Exit::TimedOut,
                        output: vec!["debug1: Reading configuration data C:\\Users\\tester/.ssh/config".into()],
                    };
                }
                Ssh::Silent => {
                    return RunResult {
                        exit: Exit::Code(0),
                        output,
                    };
                }
                _ => {}
            }
            output.push("debug1: Reading configuration data C:\\Users\\tester/.ssh/config".into());
            let mut names: Vec<String> = std::fs::read_dir(ssh.join("config.d"))
                .map(|es| {
                    es.flatten()
                        .map(|e| e.file_name().to_string_lossy().into_owned())
                        .filter(|n| n.ends_with(".ssh_config"))
                        .collect()
                })
                .unwrap_or_default();
            names.sort();
            for (i, name) in names.iter().enumerate() {
                if mode == Ssh::Missing && i == 0 {
                    continue;
                }
                if mode == Ssh::Backslash {
                    output.push(format!(
                        "debug1: Reading configuration data c:\\users\\TESTER\\.SSH\\config.d\\{name}"
                    ));
                } else {
                    output.push(format!(
                        "debug1: Reading configuration data C:\\Users\\tester/.ssh/config.d/{name}"
                    ));
                }
                if mode == Ssh::BadOwner {
                    output.push(format!(
                        "Bad owner or permissions on C:\\Users\\tester/.ssh/config.d/{name}"
                    ));
                    return RunResult {
                        exit: Exit::Code(255),
                        output,
                    };
                }
            }
            if mode == Ssh::Legacy {
                output.push(
                    "debug1: Reading configuration data C:\\Users\\tester/dotfiles/ssh_config"
                        .into(),
                );
            }
            if mode == Ssh::BadOpt {
                output.push("C:\\Users\\tester/.ssh/config.d/b c.ssh_config: line 2: Bad configuration option: nosuchoption".into());
                output.push("C:\\Users\\tester/.ssh/config.d/b c.ssh_config: terminating, 1 bad configuration options".into());
                return RunResult {
                    exit: Exit::Code(255),
                    output,
                };
            }
            RunResult {
                exit: Exit::Code(0),
                output,
            }
        })
        .with_program("ssh", "/fake/ssh")
        .with_program("git", "/fake/git")
    }

    fn has_note(o: &Outcome, part: &str) -> bool {
        o.notes.iter().any(|n| n.contains(part))
    }

    /// 中継のファイルの記録の鍵と、その置き先の中身
    const RELAY: &str = "config.d/00-op-reason-ssh-relay.ssh_config";

    /// op-reason.exe を呼んだ引数 (1 回 1 行)
    fn relay_calls(sys: &FakeSys, exe: &Path) -> Vec<String> {
        sys.calls
            .borrow()
            .iter()
            .filter(|c| c.program == exe)
            .map(|c| c.args_lossy().join(" "))
            .collect()
    }

    /// 中継の switch が off (書かない・false・1Password が off) なら、中継のファイルを置かず、op-reason.exe も呼ばない
    #[test]
    fn relay_off_places_nothing_and_does_not_call_op_reason() {
        for host in [
            RUNNER_HOST,
            "[tools]\nonePassword = true\nopReasonSshRelay = false\n[runner]\nenable = true\n",
            "[tools]\nopReasonSshRelay = true\n[runner]\nenable = true\n",
        ] {
            let e = Env::new();
            e.put_relay_exe();
            let sys = e.relay_sys(true);
            let (o, out) = e.run(&sys, host, APPLY);
            assert_eq!(o.kind, Kind::Ok, "{host}: {out}");
            assert!(!e.at(RELAY).exists(), "{host}");
            assert!(relay_calls(&sys, &e.relay_exe()).is_empty(), "{host}");
            assert_eq!(e.read("config"), CONFIG_BODY, "{host}");
        }
    }

    /// 中継が答えれば、config.d の最初に読まれる中継のファイルを置いて記録し、config は変えない。2 回目は揃っている
    #[test]
    fn relay_on_places_the_relay_file_first_in_config_d() {
        let e = Env::new();
        e.put_relay_exe();
        let sys = e.relay_sys(true);
        let (o, out) = e.run(&sys, RELAY_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(
            o.text,
            "コピー 4 / 上書き 0 / 同じ 0 / 削除 0 / 衝突 0 (ssh.exe が読むことも確かめた)"
        );
        assert_eq!(e.read(RELAY), RELAY_BODY);
        assert!(
            RELAY_BODY.ends_with("\nIdentityAgent \\\\\\\\.\\pipe\\op-reason-ssh-agent\n"),
            "{RELAY_BODY}"
        );
        assert_eq!(e.read("config"), CONFIG_BODY);
        assert_eq!(
            e.record_json()["files"][RELAY],
            serde_json::json!(fsutil::sha256_bytes(RELAY_BODY.as_bytes()))
        );
        assert_eq!(
            relay_calls(&sys, &e.relay_exe()),
            vec!["--ssh-agent --status"]
        );
        assert!(
            out.contains(&format!("コピー: {}", e.at(RELAY).display())),
            "{out}"
        );
        assert!(
            out.contains("確かめ: ssh.exe が config と config.d の 3 件を読んだ"),
            "{out}"
        );
        // 2 回目は全部同じ
        let (o, out) = e.run(&e.relay_sys(true), RELAY_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            o.text
                .starts_with("コピー 0 / 上書き 0 / 同じ 4 / 削除 0 / 衝突 0"),
            "{}",
            o.text
        );
        assert!(o.notes.is_empty(), "{o:?}");
    }

    /// 置いた後に中継が答えなくなった: 消さずに残し (1Password に直に戻さない)、鍵が使えないことと起こし直し方を ⚠ で出す。off に戻すと記録どおりに消す
    #[test]
    fn relay_down_after_placing_keeps_the_file_until_turned_off() {
        let e = Env::new();
        e.put_relay_exe();
        e.run(&e.relay_sys(true), RELAY_HOST, APPLY);
        let (o, out) = e.run(&e.relay_sys(false), RELAY_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert_eq!(e.read(RELAY), RELAY_BODY);
        for part in [
            "鍵を使えません",
            "中継: nothing answers on",
            "1 分のうちに",
            "op-reason.exe --settings relay start",
            "ssh -o 'IdentityAgent=\\\\\\\\.\\pipe\\openssh-ssh-agent' <接続先>",
        ] {
            assert!(has_note(&o, part), "{part}: {:?}", o.notes);
            assert!(out.contains(part), "{part}: {out}");
        }
        assert!(!o.notes.iter().any(|n| n.contains('\r')), "{:?}", o.notes);
        assert!(!out.contains('\r'), "{out}");
        // check も同じく残して ⚠ (書かない)
        let (o, _) = e.run(&e.relay_sys(false), RELAY_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual);
        assert!(has_note(&o, "鍵を使えません"), "{:?}", o.notes);

        // off に戻すと、記録どおりに消す (check は予告だけ)
        let (o, out) = e.run(&e.relay_sys(true), RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{out}");
        assert!(
            out.contains("SSH の中継を使わない (apply で消す): "),
            "{out}"
        );
        assert!(e.at(RELAY).exists());
        let sys = e.relay_sys(true);
        let (o, out) = e.run(&sys, RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            out.contains(&format!(
                "削除 (SSH の中継を使わない): {}",
                e.at(RELAY).display()
            )),
            "{out}"
        );
        assert!(!e.at(RELAY).exists());
        assert!(e.record_json()["files"].get(RELAY).is_none());
        assert!(relay_calls(&sys, &e.relay_exe()).is_empty());
        // Windows で変えた中継のファイルは、off に戻しても消さない (衝突)
        e.run(&e.relay_sys(true), RELAY_HOST, APPLY);
        e.put(RELAY, "IdentityAgent mine\n");
        let (o, out) = e.run(&e.relay_sys(true), RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains("は消すもの (SSH の中継を使わない) ですが、Windows 側で変わっているので消していません。"),
            "{out}"
        );
        assert_eq!(e.read(RELAY), "IdentityAgent mine\n");
    }

    /// 初めて on にしたのに中継が答えない (op-reason.exe が無いときも): 置かずに ⚠ (ssh は今までどおり 1Password に直に行く)
    #[test]
    fn relay_down_on_first_apply_places_nothing() {
        let e = Env::new();
        e.put_relay_exe();
        let (o, out) = e.run(&e.relay_sys(false), RELAY_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(!e.at(RELAY).exists());
        assert_eq!(e.read("config"), CONFIG_BODY);
        assert!(e.record_json()["files"].get(RELAY).is_none());
        for part in [
            "IdentityAgent を書いていません",
            "1Password に直に行きます",
            "中継: nothing answers on",
            "dotfiles apply --steps op-reason",
        ] {
            assert!(has_note(&o, part), "{part}: {:?}", o.notes);
        }
        // op-reason.exe が無い: 答えないとみなし、呼ばない
        let e = Env::new();
        let sys = e.relay_sys(true);
        let (o, out) = e.run(&sys, RELAY_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(!e.at(RELAY).exists());
        assert!(
            has_note(&o, "IdentityAgent を書いていません"),
            "{:?}",
            o.notes
        );
        assert!(has_note(&o, "op-reason.exe が無い"), "{:?}", o.notes);
        assert!(relay_calls(&sys, &e.relay_exe()).is_empty());
    }

    /// dotfiles-private の ssh/ に同じ名前のファイルがある: 中継のファイルは置かずに ⚠ (dotfiles-private のファイルはふつうに配る)
    #[test]
    fn relay_yields_to_a_private_file_of_the_same_name() {
        let e = Env::new();
        e.put_relay_exe();
        e.t.write(
            "dotfiles-private/ssh/00-op-reason-ssh-relay.ssh_config",
            "Host same\n",
        );
        let sys = e.relay_sys(true);
        let (o, out) = e.run(&sys, RELAY_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert_eq!(e.read(RELAY), "Host same\n");
        assert!(has_note(&o, "同じ名前"), "{:?}", o.notes);
        assert!(relay_calls(&sys, &e.relay_exe()).is_empty());
    }

    /// 正本 (ssh/) が空・読めないときは何も書かず消さないが、中継のファイルの食い違いは黙らずに ⚠ にする: switch が on なのに置いていない
    /// (Windows の ssh は 1Password に直に行く)・switch を切ったのに残っている (鍵を使えない)
    #[test]
    fn relay_mismatch_is_not_silent_without_sources() {
        let empty_sources = |e: &Env| {
            for entry in std::fs::read_dir(e.private_ssh()).unwrap() {
                let p = entry.unwrap().path();
                if p.to_string_lossy().ends_with(".ssh_config") && !p.is_dir() {
                    std::fs::remove_file(p).unwrap();
                }
            }
        };
        // on で、まだ置いていない
        let e = Env::new();
        e.put_relay_exe();
        empty_sources(&e);
        let (o, out) = e.run(&e.relay_sys(true), RELAY_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            has_note(&o, "中継の IdentityAgent も置いていません"),
            "{:?}",
            o.notes
        );
        assert!(!e.at(RELAY).exists());
        // on で、前に置いたものがある (そのまま。黙ってよい)
        let e = Env::new();
        e.put_relay_exe();
        e.run(&e.relay_sys(true), RELAY_HOST, APPLY);
        empty_sources(&e);
        let (o, out) = e.run(&e.relay_sys(true), RELAY_HOST, APPLY);
        assert_eq!(o.kind, Kind::Info, "{out}");
        assert_eq!(e.read(RELAY), RELAY_BODY);
        // switch を切ったのに残っている: 消さずに ⚠ (正本が無いときは何も消さない)
        let (o, out) = e.run(&e.relay_sys(true), RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            has_note(&o, "中継のファイルを消していません"),
            "{:?}",
            o.notes
        );
        assert!(has_note(&o, "鍵を使えません"), "{:?}", o.notes);
        assert!(e.at(RELAY).exists());
        // 中継を使わず、中継のファイルも無いホストは今までどおり Info
        let e = Env::new();
        empty_sources(&e);
        let (o, _) = e.run(&e.relay_sys(true), RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Info);
        assert!(o.notes.iter().all(|n| !n.contains("中継")), "{:?}", o.notes);
    }

    /// check と dry-run は中継のファイルを書かない。中継が今は答えなくても、前に置いていなければ置くと予告する (apply では op-reason の手順 (90) が
    /// 先に中継を起こす)
    #[test]
    fn relay_check_and_dry_run_write_nothing() {
        let e = Env::new();
        e.put_relay_exe();
        for answers in [true, false] {
            let (o, out) = e.run(&e.relay_sys(answers), RELAY_HOST, Mode::Check);
            assert_eq!(o.kind, Kind::Missing, "{answers}: {out}");
            assert!(
                out.contains(&format!(
                    "無い (apply でコピーする): {}",
                    e.at(RELAY).display()
                )),
                "{out}"
            );
            assert_eq!(has_note(&o, "今は答えません"), !answers, "{:?}", o.notes);
            let (_, out) = e.run(
                &e.relay_sys(answers),
                RELAY_HOST,
                Mode::DryRun { force: false },
            );
            assert!(
                out.contains(&format!("[dry-run] コピー: {}", e.at(RELAY).display())),
                "{out}"
            );
            assert!(!e.at(RELAY).exists());
            assert!(!e.record().exists());
        }
    }

    #[test]
    fn without_sources_writes_nothing() {
        let e = Env::new();
        e.put("config", "# mine\n");
        std::fs::remove_dir_all(e.t.path().join("dotfiles-private")).unwrap();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Info, "{out}");
        assert!(
            out.contains("!! Windows の ssh の設定を配りません: 正本の *.ssh_config がありません"),
            "{out}"
        );
        assert_eq!(e.read("config"), "# mine\n");
        assert!(!e.record().exists());
        // ssh/ が空でも同じ
        let e = Env::new();
        for entry in std::fs::read_dir(e.private_ssh()).unwrap() {
            let p = entry.unwrap().path();
            if p.to_string_lossy().ends_with(".ssh_config") && !p.is_dir() {
                std::fs::remove_file(p).unwrap();
            }
        }
        let (o, _) = e.apply();
        assert_eq!(o.kind, Kind::Info);
        assert!(!e.ssh().exists());
    }

    #[test]
    fn first_apply_copies_config_and_sources_and_records_relative_keys() {
        let e = Env::new();
        e.put("config.d/zz-tool.ssh_config", "Host tool\n");
        let (o, out) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert!(out.contains("無い (apply でコピーする): "), "{out}");
        assert!(!e.at("config").exists());

        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(
            o.text,
            "コピー 3 / 上書き 0 / 同じ 0 / 削除 0 / 衝突 0 (ssh.exe が読むことも確かめた)"
        );
        assert_eq!(e.read("config"), CONFIG_BODY);
        assert_eq!(e.read("config.d/a.ssh_config"), A);
        assert_eq!(e.read("config.d/b c.ssh_config"), B);
        for skipped in [
            "README.md",
            "x.ssh_config",
            ".hidden.ssh_config",
            "link.ssh_config",
        ] {
            assert!(!e.at(&format!("config.d/{skipped}")).exists(), "{skipped}");
        }
        assert_eq!(e.read("config.d/zz-tool.ssh_config"), "Host tool\n");
        assert_eq!(
            e.record_json(),
            serde_json::json!({
                "files": {
                    "config": fsutil::sha256_bytes(CONFIG_BODY.as_bytes()),
                    "config.d/a.ssh_config": fsutil::sha256_bytes(A.as_bytes()),
                    "config.d/b c.ssh_config": fsutil::sha256_bytes(B.as_bytes()),
                },
                "version": 1,
            })
        );
        assert!(
            out.contains("確かめ: ssh.exe が config と config.d の 2 件を読んだ (旧 clone の ssh_config は読んでいない)"),
            "{out}"
        );

        // 2 回目は全部同じ。ほかの道具のファイルにはずっと触らない
        let before = std::fs::read_to_string(e.record()).unwrap();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            o.text
                .starts_with("コピー 0 / 上書き 0 / 同じ 3 / 削除 0 / 衝突 0"),
            "{}",
            o.text
        );
        assert_eq!(std::fs::read_to_string(e.record()).unwrap(), before);
        assert_eq!(e.read("config.d/zz-tool.ssh_config"), "Host tool\n");
        assert!(e.baks().is_empty());
    }

    /// 旧経路の Include の 1 行だけの config は、BOM・CRLF・空白・空の行があっても置き換える。ほかの行があれば衝突
    #[test]
    fn legacy_config_is_replaced() {
        let e = Env::new();
        e.put(
            "config",
            "\u{feff}  Include ~/dotfiles/ssh_config  \r\n\r\n\t\n",
        );
        let (o, out) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{out}");
        assert!(
            out.contains(
                "旧経路の Include ~/dotfiles/ssh_config の 1 行だけ (apply で置き換える): "
            ),
            "{out}"
        );
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            out.contains("置き換え (旧経路の Include ~/dotfiles/ssh_config): "),
            "{out}"
        );
        assert_eq!(e.read("config"), CONFIG_BODY);
        assert!(e.baks().is_empty());

        let e = Env::new();
        e.put("config", "Include ~/dotfiles/ssh_config\nHost x\n");
        let (o, _) = e.apply();
        assert_eq!(o.kind, Kind::Manual);
        assert_eq!(e.read("config"), "Include ~/dotfiles/ssh_config\nHost x\n");
        assert!(is_legacy_config(b"Include ~/dotfiles/ssh_config"));
        // sed の [[:space:]] と同じく、VT・FF も前後の空白として落とす
        assert!(is_legacy_config(
            b"\x0b\x0cInclude ~/dotfiles/ssh_config\x0b\r\n"
        ));
        assert!(!is_legacy_config(b"Include ~/dotfiles/ssh_config2\n"));
        assert!(!is_legacy_config(b""));
    }

    /// 手で書いた config は、置いた記録が無いと出して衝突 (diff と解き方)。--force は元を退避して上書きする
    #[test]
    fn handmade_config_conflicts_until_forced() {
        let e = Env::new();
        e.put("config", "Host mine\n");
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains("は、置いた記録が無く、正本と中身が違います"),
            "{out}"
        );
        assert!(!out.contains("前回ここへ置いた中身と違う"), "{out}");
        assert!(
            out.contains("   diff diff --no-index --no-color -- "),
            "{out}"
        );
        assert!(
            out.contains("config に手で書いた Host を config.d\\<名前>.ssh_config へ移し"),
            "{out}"
        );
        assert!(
            out.contains("正本で上書きするなら:   dotfiles apply --steps ssh-config --force"),
            "{out}"
        );
        assert!(
            has_note(&o, "dotfiles apply --steps ssh-config --force"),
            "{o:?}"
        );
        assert_eq!(e.read("config"), "Host mine\n");
        // 衝突の無いファイルは置き、記録する
        assert_eq!(e.read("config.d/a.ssh_config"), A);
        assert!(e.record_json()["files"].get("config").is_none());

        let (o, out) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, Mode::DryRun { force: true });
        assert!(out.contains("[dry-run] 上書き (--force): "), "{out}");
        assert_eq!(o.kind, Kind::Fix);
        assert_eq!(e.read("config"), "Host mine\n");

        let (o, out) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, FORCE);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.read("config"), CONFIG_BODY);
        let baks = e.baks();
        assert_eq!(baks.len(), 1, "{baks:?}");
        assert_eq!(std::fs::read_to_string(&baks[0]).unwrap(), "Host mine\n");
        let bak_name = baks[0].file_name().unwrap().to_string_lossy().into_owned();
        assert!(bak_name.starts_with("config.dotfiles-bak-"), "{bak_name}");
        assert!(
            out.contains(&format!("  退避した: {}", baks[0].display())),
            "{out}"
        );
    }

    /// 正本の更新は上書きする (記録どおりの置き先。前の版の config も同じ)。Windows で変えたファイルは衝突で、--force で退避して上書き
    #[test]
    fn updates_and_conflicts() {
        let e = Env::new();
        e.apply();
        // 前の版の config (SetEnv の無いもの) を置いて記録したマシン
        let old_config = "# old\nInclude config.d/*.ssh_config\n";
        e.put("config", old_config);
        let mut r = FileRecords::load(&e.record(), "x").unwrap();
        r.set("config", &fsutil::sha256_bytes(old_config.as_bytes()));
        r.save_if_changed().unwrap();
        e.t.write("dotfiles-private/ssh/a.ssh_config", "Host a2\n");
        let (o, out) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{out}");
        assert!(
            out.contains("正本が更新された (apply で上書きする): "),
            "{out}"
        );
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            o.text.starts_with("コピー 0 / 上書き 2 / 同じ 1"),
            "{}",
            o.text
        );
        assert_eq!(e.read("config"), CONFIG_BODY);
        assert_eq!(e.read("config.d/a.ssh_config"), "Host a2\n");

        e.put("config.d/a.ssh_config", "Host changed\n");
        let (o, out) = e.run(&e.sys(Ssh::Ok), WSL_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains("は Windows 側で変わっています (前回ここへ置いた中身と違う)。"),
            "{out}"
        );
        assert!(out.contains("Copy-Item -LiteralPath '"), "{out}");
        // 受け持ちが WSL の間は、WSL の script の --force を出す
        assert!(
            out.contains("WSL で nix/scripts/bootstrap-windows-ssh-config.sh --force (受け持ちが WSL の setup の間。runner の apply は ssh-config を流さない)"),
            "{out}"
        );
        assert!(
            has_note(
                &o,
                "衝突を解くのは WSL の側 (bootstrap-windows-ssh-config.sh)"
            ),
            "{o:?}"
        );
        let (o, _) = e.apply();
        assert_eq!(o.kind, Kind::Manual);
        assert_eq!(e.read("config.d/a.ssh_config"), "Host changed\n");
        let (o, out) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, FORCE);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.read("config.d/a.ssh_config"), "Host a2\n");
        assert_eq!(e.baks().len(), 1);
    }

    /// 正本から消えたファイルは、記録どおりなら消す。Windows で変えていれば衝突、--force で退避して消す。もう無ければ記録から外すだけ
    #[test]
    fn removes_files_gone_from_the_source() {
        let e = Env::new();
        // 正本が空になると何もしない (WSL と同じ) ので、残る正本を 1 つ置く
        e.t.write("dotfiles-private/ssh/keep.ssh_config", "Host keep\n");
        e.apply();
        std::fs::remove_file(e.private_ssh().join("b c.ssh_config")).unwrap();
        let (o, out) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{out}");
        assert!(out.contains("正本から消えた (apply で消す): "), "{out}");
        let (o, out) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, Mode::DryRun { force: false });
        assert!(out.contains("[dry-run] 削除 (正本から消えた): "), "{out}");
        assert_eq!(
            o.text,
            "[dry-run] コピー 0 / 上書き 0 / 同じ 3 / 削除 1 / 衝突 0"
        );
        assert!(e.at("config.d/b c.ssh_config").exists());
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            o.text
                .starts_with("コピー 0 / 上書き 0 / 同じ 3 / 削除 1 / 衝突 0"),
            "{}",
            o.text
        );
        assert!(!e.at("config.d/b c.ssh_config").exists());
        assert!(
            e.record_json()["files"]
                .get("config.d/b c.ssh_config")
                .is_none()
        );

        // Windows で変えていれば消さない。--force は退避して消す
        e.put("config.d/a.ssh_config", "Host changed\n");
        std::fs::remove_file(e.private_ssh().join("a.ssh_config")).unwrap();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains("は正本から消えましたが、Windows 側で変わっているので消していません。"),
            "{out}"
        );
        assert_eq!(e.read("config.d/a.ssh_config"), "Host changed\n");
        let (o, out) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, FORCE);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(!e.at("config.d/a.ssh_config").exists());
        let baks = e.baks();
        assert_eq!(baks.len(), 1, "{baks:?}");
        assert_eq!(std::fs::read_to_string(&baks[0]).unwrap(), "Host changed\n");
        assert!(
            e.record_json()["files"]
                .get("config.d/a.ssh_config")
                .is_none()
        );

        // 正本から消え、置き先ももう無い鍵は、記録から外すだけ
        e.t.write("dotfiles-private/ssh/c.ssh_config", "Host c\n");
        e.apply();
        std::fs::remove_file(e.private_ssh().join("c.ssh_config")).unwrap();
        std::fs::remove_file(e.at("config.d/c.ssh_config")).unwrap();
        let (o, _) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok);
        let (o, _) = e.apply();
        assert!(
            o.text
                .starts_with("コピー 0 / 上書き 0 / 同じ 2 / 削除 0 / 衝突 0"),
            "{}",
            o.text
        );
        assert!(
            e.record_json()["files"]
                .get("config.d/c.ssh_config")
                .is_none()
        );
    }

    /// .ssh の外を指す記録の鍵は、中身が合っても消さない
    #[test]
    fn keys_outside_ssh_are_left_alone() {
        let e = Env::new();
        e.apply();
        let outside = e.home().join("outside.txt");
        std::fs::write(&outside, "keep\n").unwrap();
        let mut r = FileRecords::load(&e.record(), "x").unwrap();
        r.set("../outside.txt", &fsutil::sha256_bytes(b"keep\n"));
        r.set("C:/Windows/x", "y");
        r.save_if_changed().unwrap();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains(
                "!! 記録の鍵が .ssh の中のファイルを指していないので、触りません: ../outside.txt"
            ),
            "{out}"
        );
        assert_eq!(std::fs::read_to_string(&outside).unwrap(), "keep\n");
        assert_eq!(
            key_path(&e.ssh(), "config.d/a.ssh_config"),
            Some(e.at("config.d/a.ssh_config"))
        );
        for bad in ["", "/x", "config.d/", "a/./b", "a\\b", "C:x"] {
            assert_eq!(key_path(&e.ssh(), bad), None, "{bad}");
        }
    }

    #[test]
    fn check_and_dry_run_write_nothing() {
        let e = Env::new();
        e.put("config", "Host mine\n");
        for mode in [
            Mode::Check,
            Mode::DryRun { force: false },
            Mode::DryRun { force: true },
        ] {
            let sys = e.sys(Ssh::Ok);
            let (_, out) = e.run(&sys, RUNNER_HOST, mode);
            assert_eq!(e.read("config"), "Host mine\n", "{mode:?}");
            assert!(!e.at("config.d").exists(), "{mode:?}");
            assert!(!e.record().exists(), "{mode:?}");
            // dry-run は ssh で確かめない (WSL と同じ)。check も、apply で書く・消すものが残っている間は確かめない (apply の後に確かめる)
            let ssh_called = sys
                .calls
                .borrow()
                .iter()
                .any(|c| c.program == Path::new("/fake/ssh"));
            assert!(!ssh_called, "{mode:?}: {out}");
            if mode == Mode::Check {
                assert!(
                    out.contains("ssh.exe で読むファイルの確かめは、apply で書く・消すものが無くなってから流す"),
                    "{out}"
                );
            }
        }
    }

    /// check は、apply で直る差 (旧経路の config・まだ無い config) を、ssh の確かめの差 (manual) にしない
    #[test]
    fn check_does_not_verify_what_apply_will_fix() {
        let e = Env::new();
        e.put("config", "Include ~/dotfiles/ssh_config\n");
        let sys = e.sys(Ssh::Legacy);
        let (o, out) = e.run(&sys, RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{out}");
        assert!(o.notes.is_empty(), "{o:?}");
        assert!(
            !sys.calls
                .borrow()
                .iter()
                .any(|c| c.program == Path::new("/fake/ssh")),
            "ssh を呼ばない"
        );
        // apply の後は確かめる
        let (o, out) = e.run(&e.sys(Ssh::Ok), RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            o.text.ends_with("(ssh.exe が読むことも確かめた)"),
            "{}",
            o.text
        );
    }

    /// 正本の一覧を読めないときは、何も書かず消さない (欠けた一覧で、正本から消えたと読まない)
    #[cfg(unix)]
    #[test]
    fn unreadable_source_list_changes_nothing() {
        use std::os::unix::fs::PermissionsExt;
        let e = Env::new();
        e.apply();
        let before = std::fs::read_to_string(e.record()).unwrap();
        std::fs::set_permissions(e.private_ssh(), std::fs::Permissions::from_mode(0o000)).unwrap();
        let readable = std::fs::read_dir(e.private_ssh()).is_ok();
        let r = e.apply();
        std::fs::set_permissions(e.private_ssh(), std::fs::Permissions::from_mode(0o755)).unwrap();
        if readable {
            // root で流すと、権限を外しても読めるので確かめられない
            return;
        }
        let (o, out) = r;
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(out.contains("!! 正本の一覧を読めません: "), "{out}");
        assert_eq!(e.read("config.d/a.ssh_config"), A);
        assert_eq!(e.read("config.d/b c.ssh_config"), B);
        assert_eq!(std::fs::read_to_string(e.record()).unwrap(), before);
    }

    /// 正本から消えた鍵の置き先が、計画の置き先と同じファイル (NTFS で大小文字だけが違う名前。ここでは symlink で真似る) なら、消さずに記録から
    /// 外すだけ
    #[cfg(unix)]
    #[test]
    fn gone_key_pointing_at_a_planned_file_is_only_forgotten() {
        let e = Env::new();
        e.apply();
        std::os::unix::fs::symlink(e.at("config.d/a.ssh_config"), e.at("config.d/A.ssh_config"))
            .unwrap();
        let mut r = FileRecords::load(&e.record(), "x").unwrap();
        r.set("config.d/A.ssh_config", &fsutil::sha256_bytes(A.as_bytes()));
        r.save_if_changed().unwrap();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(o.text.contains(" / 削除 0 / "), "{}", o.text);
        assert_eq!(e.read("config.d/a.ssh_config"), A);
        assert!(
            e.record_json()["files"]
                .get("config.d/A.ssh_config")
                .is_none()
        );
        assert!(same_file_as_planned(
            &e.at("config.d/A.ssh_config"),
            &[e.at("config.d/a.ssh_config")]
        ));
        assert!(!same_file_as_planned(
            &e.at("config.d/b c.ssh_config"),
            &[e.at("config.d/a.ssh_config")]
        ));
        assert!(!same_file_as_planned(
            &e.at("config.d/none.ssh_config"),
            &[e.at("config.d/a.ssh_config")]
        ));
    }

    /// dotfiles-private の clone の core.autocrlf が true なら、ssh-config の行の前に manual の行を出す (作業ツリーでなければ見ない)
    #[test]
    fn warns_when_the_private_clone_converts_line_endings() {
        let e = Env::new();
        let sys = FakeSys::new(|spec| {
            let args = spec.args_lossy();
            let code = if args.iter().any(|a| a == "rev-parse" || a == "config") {
                0
            } else {
                1
            };
            RunResult {
                exit: Exit::Code(code),
                output: vec!["true".to_string()],
            }
        })
        .with_program("git", "/fake/git");
        let (o, out) = e.run_all(&sys, RUNNER_HOST, Mode::Check);
        assert_eq!(o.len(), 2, "{o:?}");
        assert_eq!(o[0].kind, Kind::Manual);
        assert!(
            o[0].text
                .starts_with("dotfiles-private の clone の core.autocrlf が true"),
            "{:?}",
            o[0]
        );
        assert!(
            out.contains(&format!(
                "!! dotfiles-private の clone の core.autocrlf が true です ({})。",
                e.t.path().join("dotfiles-private").display()
            )),
            "{out}"
        );
        assert!(o[1].text.starts_with("コピー "), "{:?}", o[1]);
    }

    #[test]
    fn broken_record_and_directories_stop() {
        let e = Env::new();
        e.t.write(&format!("state/{RECORD_FILE}"), "{\"version\":1}\n");
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("が壊れています (files を持つ JSON の object ではありません)。"),
            "{out}"
        );
        assert!(
            out.contains("dotfiles-private へ取り込むか --force"),
            "{out}"
        );
        assert!(!e.at("config").exists());

        let e = Env::new();
        std::fs::create_dir_all(e.at("config.d/a.ssh_config")).unwrap();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(out.contains("!! 置き先がディレクトリです: "), "{out}");
        assert!(o.text.contains(" / 衝突 0 / エラー 1"), "{}", o.text);
        // ほかのファイルは置く
        assert_eq!(e.read("config"), CONFIG_BODY);
    }

    #[test]
    fn verification_findings() {
        let e = Env::new();
        // 揃っている: 区切り (\ と /) と大文字小文字の違いは同じとみなす
        let (o, out) = e.run(&e.sys(Ssh::Backslash), RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            o.text.ends_with("(ssh.exe が読むことも確かめた)"),
            "{}",
            o.text
        );

        let (o, out) = e.run(&e.sys(Ssh::BadOwner), RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains("!! ssh.exe がアクセス権を理由に設定を読みませんでした"),
            "{out}"
        );
        assert!(
            has_note(
                &o,
                "Bad owner or permissions on C:\\Users\\tester/.ssh/config.d/a.ssh_config"
            ),
            "{o:?}"
        );
        assert!(
            has_note(
                &o,
                &format!(".ssh の ACL を見る: icacls.exe '{}'", e.ssh().display())
            ),
            "{o:?}"
        );

        let (o, out) = e.run(&e.sys(Ssh::Missing), RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            has_note(
                &o,
                "ssh.exe が読まなかったファイルがあります (Include されていない):"
            ),
            "{o:?}"
        );
        assert!(
            has_note(&o, &e.at("config.d/a.ssh_config").display().to_string()),
            "{o:?}"
        );

        let (o, _) = e.run(&e.sys(Ssh::Legacy), RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual);
        assert!(
            has_note(&o, "旧 clone の ssh_config を読んでいます"),
            "{o:?}"
        );

        let (o, out) = e.run(&e.sys(Ssh::BadOpt), RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            has_note(
                &o,
                "ssh.exe が設定を読み終えられませんでした (終了コード 255。"
            ),
            "{o:?}"
        );
        assert!(
            has_note(&o, "Bad configuration option: nosuchoption"),
            "{o:?}"
        );
        assert!(!o.notes.iter().any(|n| n.starts_with("debug")), "{o:?}");

        // 確かめられない (起こせない・時間切れ・ssh が無い) ときは、手で打つコマンドを添えて進む (行の種類は変えない)
        for (sys, why) in [
            (e.sys(Ssh::Broken), "起こせなかった: Exec format error"),
            (e.sys(Ssh::Hang), "30 秒たっても終わらなかった"),
            (FakeSys::new(|_| unreachable!()), "ssh.exe が見つからない"),
            (
                e.sys(Ssh::Silent),
                "終了コード 0。読んだ設定のファイルの行 (debug1: Reading configuration data) が出ていません",
            ),
        ] {
            let (o, out) = e.run(&sys, RUNNER_HOST, Mode::Check);
            assert_eq!(o.kind, Kind::Ok, "{why}: {out}");
            assert!(has_note(&o, why), "{why}: {o:?}");
            assert!(has_note(&o, MANUAL_CHECK), "{o:?}");
            assert!(out.contains(&format!("     {MANUAL_CHECK}")), "{out}");
            assert!(!o.text.contains("確かめた"), "{}", o.text);
        }
        // ssh には WSL と同じ引数と秒数で聞き、stderr だけを読む
        let sys = e.sys(Ssh::Ok);
        e.run(&sys, RUNNER_HOST, Mode::Check);
        let calls = sys.calls.borrow();
        let c = calls
            .iter()
            .find(|c| c.program == Path::new("/fake/ssh"))
            .unwrap();
        assert_eq!(c.args_lossy(), vec!["-v", "-G", "nonexistent.invalid"]);
        assert_eq!(c.timeout, Some(Duration::from_secs(30)));
        assert!(c.stderr_only);
    }

    #[test]
    fn normalizes_paths_like_the_wsl_script() {
        assert_eq!(
            normalize("C:\\\\Users\\\\Tester/.SSH//config"),
            "c:/users/tester/.ssh/config"
        );
        assert_eq!(
            normalize("c:\\users\\TESTER\\.SSH\\config.d\\B C.ssh_config"),
            "c:/users/tester/.ssh/config.d/b c.ssh_config"
        );
    }

    /// 順番・on/off・config の中身・旧経路の 1 行・記録の名前・確かめのコマンドと秒数は WSL の script と同じ (bash の版との突き合わせは Linux でだけ
    /// 流れるので、Windows の CI でも字で比べる)
    #[test]
    fn settings_match_the_wsl_script() {
        // windows-latest の checkout は CRLF なので、改行をそろえてから比べる
        let text = std::fs::read_to_string(parity::repo_file(
            "nix/scripts/bootstrap-windows-ssh-config.sh",
        ))
        .unwrap()
        .replace("\r\n", "\n");
        let info = SshConfig.info();
        assert!(
            text.lines()
                .any(|l| l == format!("# order: {}", info.order))
        );
        assert!(!text.lines().any(|l| l.starts_with("# tool: ")));
        assert_eq!(info.gate, Gate::Always);
        let body = text
            .split_once("config_body() {\n  cat <<'EOF'\n")
            .and_then(|(_, rest)| rest.split_once("\nEOF\n"))
            .map(|(body, _)| format!("{body}\n"))
            .expect("WSL の script に config_body の heredoc が無い");
        assert_eq!(body, CONFIG_BODY, "WSL の script の config_body と違う");
        assert!(text.contains(&format!("legacy_line='{LEGACY_LINE}'")));
        assert!(text.contains(&format!("record_file=\"${{state_dir}}/{RECORD_FILE}\"")));
        assert!(text.contains(&format!(
            "check_timeout=${{BOOTSTRAP_SSH_CHECK_TIMEOUT:-{CHECK_SECS}}}"
        )));
        assert!(text.contains("ssh.exe -v -G nonexistent.invalid </dev/null 2>&1 >/dev/null"));
        assert!(text.contains(&format!("echo \"  {MANUAL_CHECK}\"")));
    }

    /// `.ssh` の下のファイル (相対パス → 中身) と、退避 (退避した元の相対パスと中身。名前の日時は WSL と runner で違うので落とす)
    #[cfg(unix)]
    type Snapshot = (
        std::collections::BTreeMap<String, Vec<u8>>,
        Vec<(String, Vec<u8>)>,
    );

    /// `.ssh` の下のファイルを、退避 (名前に日時が入る) と、それ以外 (相対パス → 中身) に分けて並べる
    #[cfg(unix)]
    fn snapshot(dir: &Path) -> Snapshot {
        let mut files = std::collections::BTreeMap::new();
        let mut baks = Vec::new();
        let mut stack = vec![dir.to_path_buf()];
        while let Some(d) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(&d) else {
                continue;
            };
            for e in entries.flatten() {
                let p = e.path();
                if p.is_dir() {
                    stack.push(p);
                    continue;
                }
                let rel = p.strip_prefix(dir).unwrap().to_string_lossy().into_owned();
                let bytes = std::fs::read(&p).unwrap();
                match rel.split_once(".dotfiles-bak-") {
                    Some((head, _)) => baks.push((head.to_string(), bytes)),
                    None => {
                        files.insert(rel, bytes);
                    }
                }
            }
        }
        baks.sort();
        (files, baks)
    }

    /// WSL の script と runner を同じ状態から流して見比べる 2 つの場所。`root` の下に dotfiles-private・Windows のホーム (`home`)・runner の記録
    /// (`state`)・WSL の HOME (`wsl`)・偽の ssh.exe (`bin`) を置く
    #[cfg(unix)]
    struct Twin {
        wsl: Env,
        runner: Env,
    }

    #[cfg(unix)]
    impl Twin {
        fn new() -> Self {
            Twin {
                wsl: Env::new(),
                runner: Env::new(),
            }
        }

        /// 両方に同じ変更をする (`f` は場所の root を受ける)
        fn both(&self, f: impl Fn(&Path)) {
            f(self.wsl.t.path());
            f(self.runner.t.path());
        }

        /// 両方を apply し、終わり方・.ssh の中身・退避・記録が同じかを見る
        fn apply(&self, force: bool, what: &str) {
            let mut args = Vec::new();
            if force {
                args.push("--force");
            }
            let (code, wsl_out) = wsl_run(self.wsl.t.path(), &args);
            let (o, out) = self.runner.run(
                &self.runner.sys(Ssh::Ok),
                RUNNER_HOST,
                Mode::Apply { force },
            );
            assert_eq!(
                code == 0,
                o.kind == Kind::Ok,
                "{what}: WSL の終了コード {code} と runner の行 {o:?}\n--- WSL\n{wsl_out}\n--- runner\n{out}"
            );
            assert_eq!(
                snapshot(&self.runner.ssh()),
                snapshot(&self.wsl.ssh()),
                "{what}\n--- WSL\n{wsl_out}\n--- runner\n{out}"
            );
            assert_eq!(
                std::fs::read_to_string(self.runner.record()).ok(),
                std::fs::read_to_string(wsl_record(self.wsl.t.path())).ok(),
                "{what}: 記録"
            );
        }
    }

    #[cfg(unix)]
    fn wsl_record(root: &Path) -> PathBuf {
        root.join("wsl/.local/state/dotfiles").join(RECORD_FILE)
    }

    /// WSL の script を、使い捨ての HOME (`<root>/wsl`)・Windows のホーム (`<root>/home`)・dotfiles-private と偽の ssh.exe で流す
    /// (nix/tests/bootstrap-windows-ssh-config.test.sh と同じ形)。偽の ssh.exe を PATH の頭に置くので、WSL の本物の ssh.exe は呼ばれない
    #[cfg(unix)]
    fn wsl_run(root: &Path, args: &[&str]) -> (i32, String) {
        use std::os::unix::fs::PermissionsExt;
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
        let bash = std::env::split_paths(&std::env::var_os("PATH").unwrap())
            .map(|d| d.join("bash"))
            .find(|p| p.is_file())
            .unwrap();
        let fake = root.join("bin").join("ssh.exe");
        if !fake.exists() {
            std::fs::create_dir_all(fake.parent().unwrap()).unwrap();
            std::fs::write(
                &fake,
                format!(
                    "#!{}\n{}",
                    bash.display(),
                    r#"echo "debug1: Reading configuration data C:\\Users\\tester/.ssh/config" >&2
for f in "${FAKE_WIN_HOME}"/.ssh/config.d/*.ssh_config; do
  [[ -f ${f} ]] || continue
  echo "debug1: Reading configuration data C:\\Users\\tester/.ssh/config.d/${f##*/}" >&2
done
exit 0
"#
                ),
            )
            .unwrap();
            std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let mut path = std::ffi::OsString::from(root.join("bin"));
        path.push(":");
        path.push(std::env::var_os("PATH").unwrap());
        let o = std::process::Command::new(&bash)
            .arg(parity::repo_file(
                "nix/scripts/bootstrap-windows-ssh-config.sh",
            ))
            .args(args)
            .env("HOME", root.join("wsl"))
            .env("PATH", path)
            .env("DOTFILES_PRIVATE_DIR", root.join("dotfiles-private"))
            .env("FAKE_WIN_HOME", root.join("home"))
            .env_remove("DOTFILES_SETUP_WARNINGS")
            .env_remove("BOOTSTRAP_SSH_CHECK_TIMEOUT")
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

    /// WSL の script と同じ状態から、同じファイルを書き・消し・退避して同じく記録する (bash の版と突き合わせる。bash と jq が無ければ飛ばし、CI の
    /// Linux の job は DOTFILES_WIN_BASH_PARITY=1 で飛ばさない)
    #[cfg(unix)]
    #[test]
    fn writes_the_same_files_as_the_wsl_script() {
        if !parity::available() {
            return;
        }
        let w = Twin::new();
        w.both(|r| {
            let p = r.join("home/.ssh/config.d/zz-tool.ssh_config");
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, "Host tool\n").unwrap();
        });
        w.apply(false, "初回");
        w.apply(false, "2 回目");
        w.both(|r| {
            std::fs::write(r.join("dotfiles-private/ssh/a.ssh_config"), "Host a2\n").unwrap()
        });
        w.apply(false, "正本の更新");
        w.both(|r| std::fs::remove_file(r.join("dotfiles-private/ssh/b c.ssh_config")).unwrap());
        w.apply(false, "正本から消えた");
        w.both(|r| {
            std::fs::write(r.join("home/.ssh/config.d/a.ssh_config"), "Host changed\n").unwrap();
            std::fs::remove_file(r.join("dotfiles-private/ssh/a.ssh_config")).unwrap();
            std::fs::write(r.join("dotfiles-private/ssh/c.ssh_config"), "Host c\n").unwrap();
        });
        w.apply(false, "Windows で変えたものが正本から消えた (衝突)");
        w.apply(true, "--force で退避して消す");
        w.both(|r| std::fs::write(r.join("home/.ssh/config"), "Host mine\n").unwrap());
        w.apply(false, "手で書いた config (衝突)");
        w.apply(true, "--force で退避して上書き");

        // 旧経路の config・記録の無い同じ中身・記録の無い違う中身
        let w = Twin::new();
        w.both(|r| {
            let ssh = r.join("home/.ssh");
            std::fs::create_dir_all(ssh.join("config.d")).unwrap();
            std::fs::write(
                ssh.join("config"),
                "\u{feff} Include ~/dotfiles/ssh_config \r\n\r\n",
            )
            .unwrap();
            std::fs::write(ssh.join("config.d/a.ssh_config"), A).unwrap();
            std::fs::write(ssh.join("config.d/b c.ssh_config"), "Host other\n").unwrap();
        });
        w.apply(false, "旧経路の config と、記録の無いファイル");
        w.apply(true, "--force");
    }

    /// 受け持ちを切り替えた後の引き継ぎ: WSL の script が置いたものを、記録の無い runner が自分のものとして読む (受け持ちが WSL の間の check は ✔、
    /// 切り替えた後の apply は変えずに記録だけ作り、記録は WSL の記録と同じ。2 回目も変えない)。bash と jq が無ければ飛ばす
    #[cfg(unix)]
    #[test]
    fn takes_over_what_the_wsl_script_wrote() {
        if !parity::available() {
            return;
        }
        let e = Env::new();
        e.put("config.d/zz-tool.ssh_config", "Host tool\n");
        let (code, out) = wsl_run(e.t.path(), &[]);
        assert_eq!(code, 0, "{out}");
        let written = snapshot(&e.ssh());
        assert_eq!(written.0.len(), 4);
        let sys = e.sys(Ssh::Ok);
        let (o, out) = e.run(&sys, WSL_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(out.matches("同じです: ").count(), 3, "{out}");
        assert!(!e.record().exists());
        for _ in 0..2 {
            let (o, out) = e.run(&sys, RUNNER_HOST, APPLY);
            assert_eq!(o.kind, Kind::Ok, "{out}");
            assert_eq!(snapshot(&e.ssh()), written);
        }
        assert_eq!(
            std::fs::read_to_string(e.record()).unwrap(),
            std::fs::read_to_string(wsl_record(e.t.path())).unwrap()
        );
    }
}
