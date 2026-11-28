//! claude-skills の Rust の道具が共有する土台。
//!
//! OS の違い (パス・プロセス・ロック・時刻・文字コード) と、エラーと終了コードはここに閉じる
//! (spec: `docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md` の §6.6)。道具の crate は
//! `cfg(windows)` を書かずに、ここの関数を使う。

pub mod exit;
pub mod fs;
pub mod lock;
pub mod paths;
pub mod process;
pub mod sleep;
mod sys;
pub mod term;
pub mod text;
pub mod time;

#[cfg(test)]
mod testutil;

pub use exit::{Error, Result};
