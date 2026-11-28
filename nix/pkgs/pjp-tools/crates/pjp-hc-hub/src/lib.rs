//! `pjp hub` (bin `pjp-hub`): herdr-app と hc のハブ (pjp-hc-hub) の道具 (spec: `docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md`
//! の §6.2・§7.3)。
//!
//! - `pjp hub init` / `check`: ハブ (既定は `~/h`。Windows は `%USERPROFILE%\h`) を作る・雛形との差を見る (`hub-init.sh` の写し)
//! - `pjp hub guard`: Claude Code の PreToolUse の hook。ハブの会話が、ハブの中と repo の中にファイルを書くのを止める
//!   (`hub-guard.sh` の写しに、Windows のパスと `\\wsl.localhost\…` を足したもの)
//! - `pjp hub hello`: ハブの会話の始めの点検 (ハブの中か・雛形・今の端末・見回り役・hc の machine。T3 Code の会話では、今の
//!   端末の代わりに T3 のスレッド・T3 のリンク・T3 の設定。spec: `docs/superpowers/specs/2026-11-22-t3-code-hub-design.md` の §4.3)
//! - `pjp hub bake`: panel に載せた図 (panel.json の image の節) の marks を SVG の中の CSS の動きに焼き込んだ写しを作る
//!   (会話のチケットにも図を上げるため。`references/panel.md` の「チケットにも上げる」)

pub mod bake;
pub mod cli;
pub mod git;
pub mod guard;
pub mod hello;
pub mod init;
pub mod pathx;
pub mod templates;
