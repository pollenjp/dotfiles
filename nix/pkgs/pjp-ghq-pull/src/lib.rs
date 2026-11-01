//! pjp-ghq-pull: ghq の repo を選び、既定 branch を fetch と fast-forward で最新にする TUI。
//! 何をどう決めるかは nix/pkgs/pjp-ghq-pull/default.nix の冒頭と nix/README.md の節にある。

pub mod cli;
pub mod discover;
pub mod flow;
pub mod git;
pub mod repo;
pub mod run;
pub mod runner;
pub mod selection;
pub mod state;
pub mod summary;
pub mod ui;
pub mod via_gh;

/// Cargo.toml の版
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
