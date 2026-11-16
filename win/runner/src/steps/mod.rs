//! 手順の骨組みと一覧。
//!
//! 手順は trait `Step` を持つ型。`all()` が WSL の `# order:` と同じ順番に並べる (同じ数は WSL と同じく script の名前の辞書順)。
//! 手順を足すときは、この下に module を 1 つ書き、`all()` に 1 行足す (win/README.md の「runner の手順を足す」)。

pub mod bootstrap;
pub mod files;
pub mod pending;
pub mod ps1;

use crate::context::Ctx;
use crate::host::HostValues;
use crate::report::Kind;

/// その手順がこのホストで on かの決め方。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gate {
    /// いつも on
    Always,
    /// 道具の switch (`groups.json` の tools の名前) が true のとき
    Tool(&'static str),
    /// 設定グループがこのどれかのとき
    Groups(&'static [&'static str]),
}

impl Gate {
    /// on なら None、off ならわけ (締めの表に出す)。
    pub fn off_reason(&self, host: &HostValues) -> Option<String> {
        match self {
            Gate::Always => None,
            Gate::Tool(key) => {
                if host.tool(key) {
                    None
                } else {
                    Some(format!(
                        "このホストでは off ({key} = false。{})",
                        host.tool_origin(key)
                    ))
                }
            }
            Gate::Groups(groups) => {
                if groups.contains(&host.group.as_str()) {
                    None
                } else {
                    Some(format!(
                        "このホストでは off (グループ {}。この手順は {} だけ)",
                        host.group,
                        groups.join("・")
                    ))
                }
            }
        }
    }

    /// 一覧に出す on/off の決め方
    pub fn describe(&self) -> String {
        match self {
            Gate::Always => "いつも".to_string(),
            Gate::Tool(key) => key.to_string(),
            Gate::Groups(groups) => format!("グループ {}", groups.join("・")),
        }
    }
}

/// 手順の名札。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StepInfo {
    /// `--steps` に渡す名前
    pub id: &'static str,
    /// 順番 (WSL の `# order:` と同じ数)
    pub order: u16,
    pub title: &'static str,
    pub gate: Gate,
    /// runner に移したか (false は WSL にしか無い手順)
    pub ported: bool,
}

/// 流し方。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// 確かめるだけ (何も書かない)
    Check,
    /// apply がすることを出すだけ (何も書かない)
    DryRun,
    /// 揃える。`force` は files の衝突も上書きする
    Apply { force: bool },
}

impl Mode {
    pub fn writes(self) -> bool {
        matches!(self, Mode::Apply { .. })
    }
}

/// 手順の結果 (締めの表の 1 行の中身)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Outcome {
    pub kind: Kind,
    pub text: String,
    pub notes: Vec<String>,
}

impl Outcome {
    pub fn new(kind: Kind, text: impl Into<String>) -> Self {
        Outcome {
            kind,
            text: text.into(),
            notes: Vec::new(),
        }
    }

    pub fn note(mut self, n: impl Into<String>) -> Self {
        self.notes.push(n.into());
        self
    }
}

pub trait Step {
    fn info(&self) -> StepInfo;
    /// 手順を流す。出力は `ctx.say`、結果は締めの表の行 (ふつうは 1 つ)。
    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome>;
}

/// 手順の一覧 (順番どおり)。
pub fn all() -> Vec<Box<dyn Step>> {
    let mut steps: Vec<Box<dyn Step>> =
        vec![Box::new(bootstrap::Bootstrap), Box::new(files::Files)];
    for spec in ps1::SPECS {
        steps.push(Box::new(ps1::Ps1Step(spec)));
    }
    for p in pending::PENDING {
        steps.push(Box::new(pending::Pending(p)));
    }
    // 同じ order は WSL と同じく script の名前 (bootstrap-windows-<id>.sh) の辞書順。id だけで比べると herdr が herdr-app より先に
    // なるが、script の名前では herdr-app.sh が先 ('-' が '.' より前)
    steps.sort_by_key(|s| (s.info().order, format!("{}.sh", s.info().id)));
    steps
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 一覧の順番が WSL の setup と同じ (order・同じ order は script の名前の辞書順)・id が重ならない
    //! - 移した手順と、まだ無い手順の id が WSL の bootstrap-windows-*.sh の名前と同じ
    //! - on/off の決め方 (道具の switch・グループ)

    use super::*;
    use crate::host::{Groups, parse};
    use std::path::Path;

    #[test]
    fn order_matches_wsl_setup() {
        let ids: Vec<(u16, &str)> = all()
            .iter()
            .map(|s| (s.info().order, s.info().id))
            .collect();
        assert_eq!(
            ids,
            vec![
                (5, "bootstrap"),
                (90, "files"),
                (91, "powertoys"),
                (91, "ssh-config"),
                (92, "fancyzones"),
                (95, "google-ime-install"),
                (95, "powershell-profile"),
                (96, "openssh"),
                (97, "claude-code"),
                (97, "herdr-app"),
                (97, "herdr"),
                (97, "ntn"),
                (97, "pin-updates"),
                (97, "type-clipboard"),
                (98, "google-ime"),
                (99, "international"),
                (99, "port-forward"),
                (99, "terminal"),
            ]
        );
    }

    #[test]
    fn wsl_scripts_exist_for_every_windows_step() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        for s in all() {
            let info = s.info();
            if info.id == "bootstrap" {
                continue;
            }
            let script = repo
                .join("nix")
                .join("scripts")
                .join(format!("bootstrap-windows-{}.sh", info.id));
            assert!(script.is_file(), "{} が無い", script.display());
        }
        // WSL の Windows の手順は全部、一覧にある (移したか、まだ無いかのどちらか)
        let ids: Vec<&str> = all().iter().map(|s| s.info().id).collect();
        for entry in std::fs::read_dir(repo.join("nix").join("scripts")).unwrap() {
            let name = entry.unwrap().file_name().to_string_lossy().into_owned();
            if let Some(id) = name
                .strip_prefix("bootstrap-windows-")
                .and_then(|n| n.strip_suffix(".sh"))
            {
                assert!(ids.contains(&id), "{name} が一覧に無い");
            }
        }
    }

    #[test]
    fn gates() {
        let h = parse(
            "group = \"company\"",
            Path::new("h.toml"),
            Groups::embedded().unwrap(),
        )
        .unwrap();
        assert_eq!(Gate::Always.off_reason(&h), None);
        assert_eq!(Gate::Tool("windowsHerdr").off_reason(&h), None);
        assert_eq!(
            Gate::Tool("windowsNtn").off_reason(&h).unwrap(),
            "このホストでは off (windowsNtn = false。グループ company の既定)"
        );
        assert_eq!(
            Gate::Groups(&["personal"]).off_reason(&h).unwrap(),
            "このホストでは off (グループ company。この手順は personal だけ)"
        );
    }
}
