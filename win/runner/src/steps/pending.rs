//! runner にまだ無い手順 (WSL の `bootstrap-windows-*.sh` にしか無いもの)。
//!
//! 一覧 (`list`) と締めの表 (`check`・`apply`) に出し、受け持ちを切り替える前に取りこぼしに気づけるようにする。受け持ちが WSL のホスト
//! (`runner.enable` が true でない) では知らせるだけ (WSL が流す)。切り替えたホストでは誰も流さないので、runner では直らない差として
//! 終了コードに数える。移す順と移し方は dotfiles-private の docs/adr/060_win_runner_core_* (spec の §8)。

use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::report::Kind;

/// まだ無い手順の名札。
#[derive(Clone, Copy, Debug)]
pub struct PendingSpec {
    pub id: &'static str,
    pub order: u16,
    pub title: &'static str,
}

pub const PENDING: &[PendingSpec] = &[
    PendingSpec {
        id: "powertoys",
        order: 91,
        title: "PowerToys を入れ、Keyboard Manager と自動起動をオンにして割り当てを読み直させる",
    },
    PendingSpec {
        id: "ssh-config",
        order: 91,
        title: "dotfiles-private の ssh の設定を %USERPROFILE%\\.ssh へ写す",
    },
    PendingSpec {
        id: "fancyzones",
        order: 92,
        title: "FancyZones の持つキー・カスタムレイアウト・ディスプレイへのあて方を書く",
    },
    PendingSpec {
        id: "powershell-profile",
        order: 95,
        title: "$PROFILE から dotfiles.ps1 を読ませる",
    },
    PendingSpec {
        id: "pin-updates",
        order: 97,
        title: "固定した版より新しい版が出ていないかを知らせる",
    },
    PendingSpec {
        id: "google-ime",
        order: 98,
        title: "Google 日本語入力の設定とユーザー辞書を組み立てて置く",
    },
    PendingSpec {
        id: "international",
        order: 99,
        title: "日付と時刻の形式 (HKCU\\Control Panel\\International) を書く",
    },
    PendingSpec {
        id: "port-forward",
        order: 99,
        title: "dotfiles-private の port forwarding の組を JSON にして置く",
    },
    PendingSpec {
        id: "terminal",
        order: 99,
        title: "Windows Terminal の settings.json に持つキーを書き足す",
    },
];

pub struct Pending(pub &'static PendingSpec);

impl Step for Pending {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: self.0.id,
            order: self.0.order,
            title: self.0.title,
            gate: Gate::Always,
            ported: false,
        }
    }

    fn run(&self, ctx: &mut Ctx, _mode: Mode) -> Vec<Outcome> {
        let script = format!("bootstrap-windows-{}.sh", self.0.id);
        if ctx.host.runner_enable {
            vec![
                Outcome::new(
                    Kind::Manual,
                    format!("runner にまだ無いので、受け持ちを切り替えたこのホストでは誰も流さない (WSL の {script})"),
                )
                .note("移すまでは、このホストの受け持ちを WSL の setup に戻すか (runner.enable = false と windowsFiles.enable = true)、手で揃える"),
            ]
        } else {
            vec![Outcome::new(
                Kind::Info,
                format!("runner にまだ無い (WSL の {script} が受け持つ)"),
            )]
        }
    }
}
