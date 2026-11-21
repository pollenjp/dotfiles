//! claude-selector (cs): claude のアカウントと option を矢印キーで段ごとに選び、組み立てたコマンドで Claude Code を起こす。
//! 何をどう決めたかは nix/pkgs/claude-selector/default.nix の冒頭、使い方は nix/README.md と win/README.md の
//! 「claude-selector (cs)」の節。
//!
//! | module | 役目 |
//! | --- | --- |
//! | `choice` | 段ごとの選択肢と既定、選んだものから claude に渡す引数を組み立てる |
//! | `accounts` | 選べるアカウント (既定と claude-account の登録) と、PATH の launcher |
//! | `ui` | 選ぶ画面の状態機械 (キー → 状態) と、描く中身 (`Frame`)。端末には触らない |
//! | `term` | 端末 (crossterm): raw mode・キーを読む・`Frame` を今の行から下に描く |
//! | `quote` | 見せるコマンド行の引用 (unix は POSIX の shell、Windows は PowerShell) |
//! | `launch` | 起こす (unix は exec、Windows は子 process を待って終了コードで終わる) |
//! | `app` | 入口の流れ |

pub mod accounts;
pub mod app;
pub mod choice;
pub mod launch;
pub mod quote;
pub mod term;
pub mod ui;
