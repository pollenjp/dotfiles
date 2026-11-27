//! 項目ごとの選択肢と既定、選んだものから claude に渡す引数を組み立てる。
//!
//! 引数の並びは選ぶ画面のコマンド行と同じ `--effort` → `--model` → 権限 → `--remote-control` の順 ([`Part::ALL`]) で、cs の後ろに
//! 打った引数 (`cs -c`・`cs "質問"`) をそのまま最後に足す (見せる行と起こす行を同じにするため)。c (nix/home/modules/fish.nix の
//! abbr・bash.nix の alias・win/powershell/dotfiles.ps1 の function) の権限 → `--effort` → `--model` → `--remote-control` とは並びだけが
//! 違う (claude は option の並びを問わない)。既定 (打ってすぐ Enter) は c から `--remote-control=` を外した中身。

use std::ffi::OsString;

/// 起こすもの (アカウント)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    /// 素の `claude`
    Plain,
    /// `claude-<名前>` (claude-account の launcher。CLAUDE_CONFIG_DIR などの env は launcher が決める)
    Account(String),
}

impl Target {
    /// コマンドの名前 (`claude`・`claude-<名前>`)
    pub fn command(&self) -> String {
        match self {
            Target::Plain => "claude".to_string(),
            Target::Account(name) => format!("claude-{name}"),
        }
    }
}

/// 権限の確認の扱い (`claude --help` の `--permission-mode` の choices のうち 4 つと、付けない)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Permission {
    /// `--dangerously-skip-permissions` (既定。c と同じ)
    Skip,
    /// `--permission-mode auto`
    Auto,
    /// 付けない (settings.json の既定の確認)
    Ask,
    /// `--permission-mode acceptEdits`
    AcceptEdits,
    /// `--permission-mode plan`
    Plan,
}

impl Permission {
    /// 選ぶ画面の並び
    pub const ALL: [Permission; 5] = [
        Permission::Skip,
        Permission::Auto,
        Permission::Ask,
        Permission::AcceptEdits,
        Permission::Plan,
    ];
    pub const DEFAULT: Permission = Permission::Skip;

    /// claude に渡す引数
    pub fn args(self) -> &'static [&'static str] {
        match self {
            Permission::Skip => &["--dangerously-skip-permissions"],
            Permission::Auto => &["--permission-mode", "auto"],
            Permission::Ask => &[],
            Permission::AcceptEdits => &["--permission-mode", "acceptEdits"],
            Permission::Plan => &["--permission-mode", "plan"],
        }
    }

    /// 一覧に出す字 (引数。付けないなら「付けない」)
    pub fn label(self) -> String {
        match self.args() {
            [] => "付けない".to_string(),
            args => args.join(" "),
        }
    }

    /// 添える説明
    pub fn note(self) -> &'static str {
        match self {
            Permission::Skip => "確認をすべて飛ばす",
            Permission::Auto => "auto モード (安全と見た操作は確認しない)",
            Permission::Ask => "ふつうの確認 (settings.json の既定)",
            Permission::AcceptEdits => "ファイルの編集は確認しない",
            Permission::Plan => "計画だけ立てる (書き換えない)",
        }
    }
}

/// effort の選択肢 (`claude --help` の並び)
pub const EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];
/// effort の既定 (c と同じ)
pub const DEFAULT_EFFORT: &str = "max";

/// モデルの選択肢。ほかの名前 (別名の opus・fable など) は「手で打つ」で入れる (`model_ok` で確かめる)
pub const MODELS: [&str; 5] = [
    "claude-opus-5-5",
    "claude-sonnet-5-5",
    "claude-haiku-5-5",
    "claude-fable-5-2",
    "claude-fable-5-1",
];
/// モデルの既定 (c と同じ)
pub const DEFAULT_MODEL: &str = "claude-opus-5-5";

/// Remote Control。付けるときは `--remote-control=<名前>` の形で 1 つの引数にする (`--remote-control [name]` は後ろの語を名前と
/// して読むので、`=` で値を閉じ、cs の後ろの引数を名前に取らせない。空の値は名前なしと同じに読まれる。理由の元は fish.nix の c の注記)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RemoteControl {
    /// 付けない (既定)
    Off,
    /// `--remote-control=` (名前なし)
    Unnamed,
    /// `--remote-control=<名前>`
    Named(String),
}

impl RemoteControl {
    /// claude に渡す引数 (付けないなら None)
    pub fn arg(&self) -> Option<String> {
        match self {
            RemoteControl::Off => None,
            RemoteControl::Unnamed => Some("--remote-control=".to_string()),
            RemoteControl::Named(name) => Some(format!("--remote-control={name}")),
        }
    }

    /// 打った名前から作る (前後の空白を外す。空なら名前なし)
    pub fn from_name(name: &str) -> RemoteControl {
        match name.trim() {
            "" => RemoteControl::Unnamed,
            n => RemoteControl::Named(n.to_string()),
        }
    }
}

/// claude に渡す引数の組 (選ぶ画面のコマンド行の項目のうち、アカウントのほかの 4 つ)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Part {
    Effort,
    Model,
    Permission,
    RemoteControl,
}

impl Part {
    /// 並び (claude に渡す引数も、選ぶ画面のコマンド行も、アカウントの後ろはこの並び)
    pub const ALL: [Part; 4] = [
        Part::Effort,
        Part::Model,
        Part::Permission,
        Part::RemoteControl,
    ];

    /// option の名前 (付けないときに、選ぶ画面のコマンド行へ灰色の括弧で出す)
    pub fn flag(self) -> &'static str {
        match self {
            Part::Effort => "--effort",
            Part::Model => "--model",
            Part::Permission => "--permission-mode",
            Part::RemoteControl => "--remote-control",
        }
    }
}

/// 選んだもの。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub target: Target,
    pub permission: Permission,
    pub effort: &'static str,
    pub model: String,
    pub remote_control: RemoteControl,
}

impl Default for Selection {
    /// どの項目も既定のまま (打ってすぐ Enter)
    fn default() -> Self {
        Selection {
            target: Target::Plain,
            permission: Permission::DEFAULT,
            effort: DEFAULT_EFFORT,
            model: DEFAULT_MODEL.to_string(),
            remote_control: RemoteControl::Off,
        }
    }
}

impl Selection {
    /// 組 `part` の引数 (付けないなら空)
    pub fn part_args(&self, part: Part) -> Vec<String> {
        match part {
            Part::Effort => vec!["--effort".to_string(), self.effort.to_string()],
            Part::Model => vec!["--model".to_string(), self.model.clone()],
            Part::Permission => self
                .permission
                .args()
                .iter()
                .map(|a| a.to_string())
                .collect(),
            Part::RemoteControl => self.remote_control.arg().into_iter().collect(),
        }
    }

    /// claude (か claude-<名前>) に渡す引数。`extra` (cs の後ろに打った引数) は最後にそのまま足す
    pub fn args(&self, extra: &[OsString]) -> Vec<OsString> {
        let mut args: Vec<OsString> = Part::ALL
            .iter()
            .flat_map(|p| self.part_args(*p))
            .map(OsString::from)
            .collect();
        args.extend(extra.iter().cloned());
        args
    }
}

/// 手で打ったモデルの名前を確かめる。だめならわけ。名前の中身 (あるモデルか) は claude が確かめる
pub fn model_ok(name: &str) -> Result<(), &'static str> {
    if name.is_empty() {
        return Err("モデルの名前を入れてください");
    }
    if name.starts_with('-') {
        return Err("- で始まる名前は使えません (claude が option として読む)");
    }
    if name.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("空白は使えません");
    }
    Ok(())
}
