//! dotfiles の Windows 側の runner (dotfiles-private の docs/adr/058_win_runner_bootstrap_* §2 H と docs/adr/060_win_runner_core_*)。
//!
//! Windows の環境を Windows の側から作る。手順 (`steps`) を順に確かめ (`check`)、`runner.enable = true` のホストでは揃える (`apply`)。
//! 手順は WSL の `nix/scripts/bootstrap-windows-*.sh` を 1 つずつ写したもので、判定と文言をそろえる。使い方は `win/README.md` の
//! 「runner」。

pub mod cli;
pub mod host;
pub mod manifest;
pub mod report;

#[cfg(test)]
mod testutil;
