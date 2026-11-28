//! ハブと子の道具 (pjp-tools) が共有する土台 (claude-skills の pjp-core から分かれた写し。workspace の README.md)。
//!
//! OS の違い (パス・プロセス・ロック・時刻・文字コード) と、エラーと終了コードはここに閉じる
//! (spec: claude-skills の `docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md` の §6.6)。道具の crate は
//! `cfg(windows)` を書かずに、ここの関数を使う。private な足し分 (claude-skills) があるかは [`extras`] で見る。

pub mod exit;
pub mod extras;
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
