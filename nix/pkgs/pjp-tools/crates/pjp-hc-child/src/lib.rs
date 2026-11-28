//! pjp-hc-child の道具 (spec: `docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md` の §7.4〜§7.8)。
//!
//! - `pjp child`: 子のマシンに worktree と herdr-app の space を作り、`hc run` で子の Claude Code を立てる・読む・送る・片付ける
//! - `pjp mark`: 会話の端末に label の印 (`pjp.ticket`・`pjp.role`・`pjp.finished`・`pjp.asking`・解説動画の `pjp.video.<id>`) を
//!   付け、space の名前を替える
//! - `pjp pack`: skill の pack (話題ごとの組) から、子の `--settings` の JSON を作る・割り当てを確かめる (pack.py の移植)
//!
//! herdr-app の無いマシン (Linux のハブ) では、space を hc の core の doc `herdr-app` で読み書きする ([`appdoc`])。
//!
//! 外とのやりとり (hc・herdr-app・gh・git) は [`hc::Runner`] を通す (テストは偽物に差し替える)。子のマシンのパスは
//! `String` のまま扱う (ハブの Windows の `PathBuf` に混ぜると `\` が入る)。

pub mod appdoc;
pub mod args;
pub mod child;
pub mod hc;
pub mod ledger;
pub mod mark;
pub mod pack;
mod pyfmt;

#[cfg(test)]
mod testutil;
