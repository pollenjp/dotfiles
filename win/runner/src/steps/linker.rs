//! repo の中身を 1 つずつ `~/.claude/<種類>/` へつなぐ道具 (claude-skills と claude-files の手順が共有する。claude-accounts は同じ道具で
//! `~/.claude/<種類>/` の中身を `~/.claude-<名前>/<種類>/` へ写す)。
//!
//! ディレクトリは junction (`cmd /c mklink /J`。権限が要らない)、ファイルはコピー (ファイルの symlink は開発者モードか管理者が要り、hard link は
//! git が取り出し直すと切れる)。コピーは files と同じ記録で判定する: 置き先が無い → コピー・同じ中身 → 何もしない・記録と同じ中身 → 上書き・
//! ほか → 衝突 (`--force` で上書き)。repo から消えたものは片付ける (リンクは外し、先は消さない。コピーは中身が記録どおりなら消す)。選び方は Linux の
//! `nix/scripts/bootstrap-claude-skills.sh` と同じ (dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*・docs/adr/065_win_claude_config_*)。
//! 張らない skill (`skip_skills`・わけを添える `hold`) と、先が無ければ張り替えてよいほかの手順のリンク (`adopt_dangling`) は呼ぶ側が渡す
//! (claude-files が、skill の依存の表で外す skill と claude-skills の写しに譲る skill に使う)。

use super::{Mode, Outcome};
use crate::context::Ctx;
use crate::fsutil;
use crate::link::{create_junction, is_link, is_under, link_target, remove_link, same_path};
use crate::record::Records;
use crate::report::Kind;
use std::path::{Path, PathBuf};

/// junction を張る・コピーする名前か (cmd が特別に読む文字を、名前で持ち込まない)。
fn name_ok(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

#[derive(Default)]
pub struct Tally {
    pub added: usize,
    pub updated: usize,
    pub removed: usize,
    pub same: usize,
    pub skipped: Vec<String>,
    pub errors: usize,
}

/// どこから何をつなぐか。
pub struct Source {
    /// つなぐ元の根 (`<root>/<種類>/<名前>`)
    pub root: PathBuf,
    /// 前に使った根 (そこを指すリンクも、この手順が張ったものとして扱う)
    pub prev: Option<PathBuf>,
    /// ほかの clone の同じ場所 (`<どこか>/<この印>/<種類>/<名前>`) を指すリンクも、この手順が張ったものとして扱う (dotfiles の `nix/files/claude`)
    pub foreign_suffix: Option<&'static str>,
    /// つなぐ種類
    pub kinds: &'static [&'static str],
    /// skills のうち張らない名前 (前に張ったものは外す)
    pub skip_skills: Vec<String>,
    /// 写すものを絞る (種類と元のパスを受けて、写すなら true)。None は全部 (README.md と skip_skills を除く)。外れたものは張らず写さず
    /// (何も出さない)、前にこの手順が張ったリンクと写したコピーは片付ける
    pub select: Option<fn(&str, &Path) -> bool>,
    /// 元の呼び名 (片付けの文の「<origin> に無い」・「<origin> から消えた」)
    pub origin: &'static str,
    /// 衝突したコピーの中身を取り込む先 (締めの文に出す repo の名前)
    pub absorb: &'static str,
    /// 手順の id (締めの文の `dotfiles apply --steps <id> --force`)
    pub step: &'static str,
}

pub struct Linker {
    pub src: Source,
    pub claude: PathBuf,
    /// `~/.claude/<種類>` そのものがリンクの種類 (手でつないだ場所。触らない)
    pub linked_kinds: Vec<&'static str>,
    pub mode: Mode,
    pub records: Records,
    pub tally: Tally,
    /// skills のうち、わけを添えて張らない名前とそのわけ (`hold`。claude-files が skill の依存の表で外すもの・claude-skills の写しに譲るもの)
    held: Vec<(String, String)>,
    /// 先が無ければ (片付けた後の残り)、この手順が張り替えてよいリンクの先 (`adopt_dangling`)
    adopt: Vec<PathBuf>,
}

impl Linker {
    pub fn new(src: Source, claude: PathBuf, mode: Mode, records: Records) -> Self {
        let linked_kinds = src
            .kinds
            .iter()
            .copied()
            .filter(|k| is_link(&claude.join(k)))
            .collect();
        Linker {
            src,
            claude,
            linked_kinds,
            mode,
            records,
            tally: Tally::default(),
            held: Vec::new(),
            adopt: Vec::new(),
        }
    }

    /// skills の `name` を、わけ `why` を添えて張らない (skip_skills と同じく、前にこの手順が張ったリンクは外し、ほかのリンクには触らない)。
    pub fn hold(&mut self, name: &str, why: impl Into<String>) {
        self.held.push((name.to_string(), why.into()));
    }

    /// `target` (とその下) を指すリンクで先が無いもの (ほかの手順が張って、元を片付けた後の残り) を、この手順のものとして張り替える。
    pub fn adopt_dangling(&mut self, target: PathBuf) {
        self.adopt.push(target);
    }

    /// この手順が張ったリンクの先か (今の根か前の根の中。印があれば、ほかの clone の同じ場所も)。
    fn is_ours(&self, target: &Path) -> bool {
        if is_under(target, &self.src.root)
            || self.src.prev.as_ref().is_some_and(|p| is_under(target, p))
        {
            return true;
        }
        let Some(suffix) = self.src.foreign_suffix else {
            return false;
        };
        let suffix: PathBuf = suffix.split('/').collect();
        let kind = target.parent();
        let root = kind.and_then(Path::parent);
        let kind_ok = kind.and_then(Path::file_name).is_some_and(|k| {
            self.src
                .kinds
                .iter()
                .any(|x| k.to_string_lossy().eq_ignore_ascii_case(x))
        });
        kind_ok && root.is_some_and(|r| ends_with_ignore_case(r, &suffix))
    }

    /// 張らない名前なら、そのわけ (skip_skills は「このマシンでは使わない」、hold は添えたわけ)。
    fn skip_reason(&self, kind: &str, name: &str) -> Option<String> {
        if kind != "skills" {
            return None;
        }
        if self.src.skip_skills.iter().any(|s| s == name) {
            return Some("このマシンでは使わない".to_string());
        }
        self.held
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, why)| why.clone())
    }

    /// 先が無く、`adopt_dangling` で張り替えてよいとしたリンクの先か。
    fn adoptable(&self, target: &Path) -> bool {
        !target.exists()
            && self
                .adopt
                .iter()
                .any(|a| same_path(target, a) || is_under(target, a))
    }

    /// `select` で写すものか (絞り込みが無ければいつも)。
    fn selected(&self, kind: &str, src: &Path) -> bool {
        self.src.select.is_none_or(|f| f(kind, src))
    }

    pub fn skip(&mut self, ctx: &mut Ctx, why: String) {
        ctx.say(format!("!! 飛ばす: {why}"));
        self.tally.skipped.push(why);
    }

    pub fn fail(&mut self, ctx: &mut Ctx, why: String) {
        ctx.say(format!("!! {why}"));
        self.tally.errors += 1;
    }

    /// 全部の種類をつなぎ、片付ける。
    pub fn run(&mut self, ctx: &mut Ctx) {
        // つなぐ先の dir の名前 (~/.claude・~/.claude-<名前>)
        let dest = self
            .claude
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        for kind in self.linked_kinds.clone() {
            self.skip(
                ctx,
                format!("{kind} (~/{dest}/{kind} がリンク。手でつないだ場所なので、この種類には触らない)"),
            );
        }
        for kind in self.src.kinds {
            self.link_kind(ctx, kind);
        }
        for kind in self.src.kinds {
            self.prune_links(ctx, kind);
        }
        self.prune_copies(ctx);
    }

    /// 根の `<kind>/` の中身を 1 つずつつなぐ (README.md と張らない名前は除く)。`~/.claude/<kind>` そのものがリンクなら触らない。
    fn link_kind(&mut self, ctx: &mut Ctx, kind: &str) {
        if self.linked_kinds.contains(&kind) {
            return;
        }
        let src_dir = self.src.root.join(kind);
        let Ok(entries) = std::fs::read_dir(&src_dir) else {
            return;
        };
        let mut names: Vec<String> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        for name in names {
            if name == "README.md" {
                continue;
            }
            let label = format!("{kind}/{name}");
            if let Some(why) = self.skip_reason(kind, &name) {
                ctx.say(format!("張らない ({why}): {label}"));
                continue;
            }
            let src = src_dir.join(&name);
            if !self.selected(kind, &src) {
                continue;
            }
            if !name_ok(&name) {
                self.skip(
                    ctx,
                    format!("{label} (名前に英数字・. _ - の外の文字がある)"),
                );
                continue;
            }
            let dest = self.claude.join(kind).join(&name);
            if src.is_dir() {
                self.link_dir(ctx, &src, &dest, &label);
            } else if src.is_file() {
                match std::fs::read(&src) {
                    Ok(bytes) => self.copy_bytes(ctx, &bytes, &dest, &label),
                    Err(e) => self.fail(ctx, format!("{label} のコピー元が読めない ({e})")),
                }
            } else {
                self.skip(ctx, format!("{label} (ディレクトリでもファイルでもない)"));
            }
        }
    }

    /// ディレクトリを junction でつなぐ。
    fn link_dir(&mut self, ctx: &mut Ctx, src: &Path, dest: &Path, label: &str) {
        if let Some(target) = link_target(dest) {
            if same_path(&target, src) {
                self.tally.same += 1;
                return;
            }
            if !self.is_ours(&target) && !self.adoptable(&target) {
                self.skip(
                    ctx,
                    format!("{label} (別のリンクがある: -> {})", target.display()),
                );
                return;
            }
            match self.mode {
                Mode::Check => ctx.say(format!(
                    "張り替える (apply で): {label} (今は -> {})",
                    target.display()
                )),
                Mode::DryRun { .. } => ctx.say(format!(
                    "[dry-run] 張り替える: {label} -> {}",
                    src.display()
                )),
                Mode::Apply { .. } => {
                    if let Err(e) = remove_link(dest) {
                        self.fail(ctx, format!("{label} のリンクを外せない ({e})"));
                        return;
                    }
                    if let Err(e) = create_junction(ctx.sys, dest, src) {
                        self.fail(ctx, format!("{label} を張れない ({e})"));
                        return;
                    }
                    ctx.say(format!("張り替えました: {label} -> {}", src.display()));
                }
            }
            self.tally.updated += 1;
            return;
        }
        if dest.symlink_metadata().is_ok() {
            self.skip(
                ctx,
                format!("{label} (実体がある。手で置いたものか、Anthropic の配信と同じ名前)"),
            );
            return;
        }
        match self.mode {
            Mode::Check => ctx.say(format!("無い (apply で張る): {label}")),
            Mode::DryRun { .. } => ctx.say(format!("[dry-run] 張る: {label} -> {}", src.display())),
            Mode::Apply { .. } => {
                if let Some(parent) = dest.parent()
                    && let Err(e) = std::fs::create_dir_all(parent)
                {
                    self.fail(ctx, format!("{} を作れない ({e})", parent.display()));
                    return;
                }
                if let Err(e) = create_junction(ctx.sys, dest, src) {
                    self.fail(ctx, format!("{label} を張れない ({e})"));
                    return;
                }
                ctx.say(format!("張りました: {label} -> {}", src.display()));
            }
        }
        self.tally.added += 1;
    }

    /// 中身 `want_bytes` を `dest` にコピーする (files と同じ記録の判定)。
    pub fn copy_bytes(&mut self, ctx: &mut Ctx, want_bytes: &[u8], dest: &Path, label: &str) {
        if is_link(dest) {
            self.skip(ctx, format!("{label} (リンクがある)"));
            return;
        }
        if dest.is_dir() {
            self.skip(ctx, format!("{label} (ディレクトリがある)"));
            return;
        }
        let want = fsutil::sha256_bytes(want_bytes);
        let key = dest.to_string_lossy().into_owned();
        let recorded = self.records.get(&key).map(str::to_string);
        let copy = if !dest.exists() {
            true
        } else {
            match fsutil::sha256_file(dest) {
                Err(e) => {
                    self.fail(ctx, format!("{label} の置き先が読めない ({e})"));
                    return;
                }
                Ok(have) if have == want => {
                    self.tally.same += 1;
                    if self.mode.writes() && recorded.as_deref() != Some(want.as_str()) {
                        self.records.set(&key, &want);
                    }
                    return;
                }
                Ok(have) if recorded.as_deref() == Some(have.as_str()) || self.mode.force() => {
                    false
                }
                Ok(_) => {
                    let why = if recorded.is_some() {
                        "Windows 側で変わった"
                    } else {
                        "置いた記録が無い"
                    };
                    let (absorb, step) = (self.src.absorb, self.src.step);
                    self.skip(
                        ctx,
                        format!(
                            "{label} (中身が違う。{why}。Windows 側の中身を残すなら {absorb} へ取り込む・上書きするなら dotfiles apply --steps {step} --force)"
                        ),
                    );
                    return;
                }
            }
        };
        let (todo, done) = if copy {
            ("コピーする", "コピーしました")
        } else {
            ("上書きする", "上書きしました")
        };
        match self.mode {
            Mode::Check => ctx.say(format!("{todo} (apply で): {label}")),
            Mode::DryRun { .. } => ctx.say(format!("[dry-run] {todo}: {label}")),
            Mode::Apply { .. } => match fsutil::write_atomic(dest, want_bytes) {
                Ok(()) => {
                    self.records.set(&key, &want);
                    ctx.say(format!("{done}: {label}"));
                }
                Err(e) => {
                    self.fail(ctx, format!("{label} を書けない ({e})"));
                    return;
                }
            },
        }
        if copy {
            self.tally.added += 1;
        } else {
            self.tally.updated += 1;
        }
    }

    /// `~/.claude/<kind>/` のリンクのうち、この手順が張ったもので、今の根に無い (か張らない) ものを外す (先は消さない)。
    fn prune_links(&mut self, ctx: &mut Ctx, kind: &str) {
        let dest_dir = self.claude.join(kind);
        if is_link(&dest_dir) {
            return;
        }
        let Ok(entries) = std::fs::read_dir(&dest_dir) else {
            return;
        };
        let mut names: Vec<String> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        for name in names {
            let dest = dest_dir.join(&name);
            let Some(target) = link_target(&dest) else {
                continue;
            };
            let skipped = self.skip_reason(kind, &name);
            let src = self.src.root.join(kind).join(&name);
            // 根にあっても写さないもの (select で外れた) は、前に張ったリンクを外す
            let unselected = src.exists() && !self.selected(kind, &src);
            // 今の根にある名前は link_kind が受け持つ (張り替えを二度数えない)
            if skipped.is_none() && !unselected && name != "README.md" && src.exists() {
                continue;
            }
            if !self.is_ours(&target)
                || (skipped.is_none()
                    && !unselected
                    && is_under(&target, &self.src.root)
                    && target.exists())
            {
                continue;
            }
            let label = format!("{kind}/{name}");
            let why = if let Some(why) = skipped {
                why
            } else if unselected {
                "写すものでない".to_string()
            } else {
                format!("{} に無い", self.src.origin)
            };
            match self.mode {
                Mode::Check => ctx.say(format!(
                    "外す (apply で): {label} (-> {}。{why})",
                    target.display()
                )),
                Mode::DryRun { .. } => ctx.say(format!("[dry-run] 外す: {label}")),
                Mode::Apply { .. } => {
                    if let Err(e) = remove_link(&dest) {
                        self.fail(ctx, format!("{label} のリンクを外せない ({e})"));
                        continue;
                    }
                    ctx.say(format!("外しました: {label} (先は残す)"));
                }
            }
            self.tally.removed += 1;
        }
    }

    /// 記録にあるコピーのうち、根からコピー元が消えたもの (と select で外れたもの) を消す (中身を変えていれば残して知らせる)。
    fn prune_copies(&mut self, ctx: &mut Ctx) {
        for key in self.records.keys() {
            let dest = PathBuf::from(&key);
            let Some((kind, name)) = self.split_dest(&dest) else {
                continue;
            };
            let src = self.src.root.join(&kind).join(&name);
            // 根にあっても写さないもの (select で外れた) は、前に写したコピーを片付ける
            let unselected = src.is_file() && !self.selected(&kind, &src);
            if self.linked_kinds.contains(&kind.as_str()) || (src.is_file() && !unselected) {
                continue;
            }
            let label = format!("{kind}/{name}");
            let why = if unselected {
                "写すものでない".to_string()
            } else {
                format!("{} から消えた", self.src.origin)
            };
            if !dest.exists() || is_link(&dest) {
                if self.mode.writes() {
                    self.records.remove(&key);
                }
                continue;
            }
            let recorded = self.records.get(&key).map(str::to_string);
            match fsutil::sha256_file(&dest) {
                Ok(have) if recorded.as_deref() == Some(have.as_str()) => {
                    match self.mode {
                        Mode::Check => ctx.say(format!("消す (apply で): {label} ({why})")),
                        Mode::DryRun { .. } => ctx.say(format!("[dry-run] 消す: {label}")),
                        Mode::Apply { .. } => {
                            if let Err(e) = std::fs::remove_file(&dest) {
                                self.fail(ctx, format!("{label} を消せない ({e})"));
                                continue;
                            }
                            self.records.remove(&key);
                            ctx.say(format!("消しました: {label} ({why})"));
                        }
                    }
                    self.tally.removed += 1;
                }
                Ok(_) => {
                    self.skip(
                        ctx,
                        format!(
                            "{label} ({why}が、Windows 側で変わっているので消さない。要らなければ手で消す)"
                        ),
                    );
                    if self.mode.writes() {
                        self.records.remove(&key);
                    }
                }
                Err(e) => self.fail(ctx, format!("{label} が読めない ({e})")),
            }
        }
    }

    /// 記録の鍵 (`~/.claude/<kind>/<name>`) を種類と名前に分ける。`~/.claude` の下の、この手順の種類のディレクトリでなければ None。
    fn split_dest(&self, dest: &Path) -> Option<(String, String)> {
        let name = dest.file_name()?.to_string_lossy().into_owned();
        let kind_dir = dest.parent()?;
        let kind = kind_dir.file_name()?.to_string_lossy().into_owned();
        if !self.src.kinds.contains(&kind.as_str()) || !same_path(kind_dir.parent()?, &self.claude)
        {
            return None;
        }
        Some((kind, name))
    }

    /// 記録を書き (apply で変わっていれば)、締めの行を作る。`extra` はほかに直すことの種類 (控えのファイル・hook の口など)。
    pub fn finish(
        &mut self,
        ctx: &mut Ctx,
        record_path: &Path,
        extra: Option<Kind>,
    ) -> Vec<Outcome> {
        if self.mode.writes()
            && let Err(e) = self.records.save_if_changed()
        {
            let why = format!("コピーの記録を書けない: {} ({e})", record_path.display());
            self.fail(ctx, why);
        }
        let t = &self.tally;
        let mut summary = format!(
            "追加 {} / 更新 {} / 削除 {} / 同じ {} / 飛ばした {}",
            t.added,
            t.updated,
            t.removed,
            t.same,
            t.skipped.len()
        );
        if t.errors > 0 {
            summary.push_str(&format!(" / エラー {}", t.errors));
        }
        if matches!(self.mode, Mode::DryRun { .. }) {
            summary = format!("[dry-run] {summary}");
        }
        ctx.say("");
        ctx.say(&summary);
        let kind = if t.errors > 0 || extra == Some(Kind::Failed) {
            Kind::Failed
        } else if self.mode.writes() {
            Kind::Ok
        } else if t.updated + t.removed > 0 || extra == Some(Kind::Fix) {
            Kind::Fix
        } else if t.added > 0 || extra == Some(Kind::Missing) {
            Kind::Missing
        } else {
            Kind::Ok
        };
        let mut outcomes = vec![Outcome::new(kind, summary)];
        if !t.skipped.is_empty() {
            let mut o = Outcome::new(
                Kind::Manual,
                format!(
                    "飛ばした {} (同じ名前の実体・別のリンク・中身の違うコピー) → ※ の名前を見て直す",
                    t.skipped.len()
                ),
            );
            for s in &t.skipped {
                o = o.note(s.clone());
            }
            outcomes.push(o);
        }
        outcomes
    }
}

/// `p` の終わりの要素が `suffix` と同じか (Windows のパスは大文字小文字を区別しない)。
fn ends_with_ignore_case(p: &Path, suffix: &Path) -> bool {
    let a: Vec<String> = p
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_lowercase())
        .collect();
    let b: Vec<String> = suffix
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_lowercase())
        .collect();
    a.len() >= b.len() && a[a.len() - b.len()..] == b[..]
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (claude-skills・claude-files の試験が見ない、絞り込みと呼び名)
    //!
    //! - `select` で外したものは張らず写さず (「張らない」も出さない)、前にこの手順が張ったリンクと写したコピーは片付ける
    //! - 片付けの文は元の呼び名 (`origin`) を使う
    //! - つなぐ先の種類の dir がリンクなら、つなぐ先の dir の名前 (`~/<名前>/<種類>`) で知らせて触らない
    //! - `hold` した skill は、わけを添えて張らず、前にこの手順が張ったリンクは外し、ほかの先へのリンクには触らない
    //! - `adopt_dangling` の先を指すリンクは、先が無ければ張り替え、先があれば別のリンクとして飛ばす

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir, fake_mklink};

    /// 名前が pjp- で始まるものだけを写す
    fn only_pjp(_kind: &str, src: &Path) -> bool {
        src.file_name()
            .is_some_and(|n| n.to_string_lossy().starts_with("pjp-"))
    }

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            let t = TempDir::new("linker");
            t.write("base/skills/pjp-a/SKILL.md", "a\n");
            t.write("base/skills/mine/SKILL.md", "mine\n");
            t.write("base/rules/pjp-r.md", "r\n");
            t.write("base/rules/other.md", "o\n");
            std::fs::create_dir_all(t.path().join("home").join(".claude-work")).unwrap();
            Env { t }
        }

        fn base(&self) -> PathBuf {
            self.t.path().join("base")
        }

        fn dest(&self, rel: &str) -> PathBuf {
            crate::context::join_segments(&self.t.path().join("home").join(".claude-work"), rel)
        }

        fn record_path(&self) -> PathBuf {
            self.t.path().join("state").join("r.json")
        }

        /// apply で流し、記録を書き、(tally, 出力) を返す
        fn apply(&self) -> (Tally, String) {
            self.run(Mode::Apply { force: false })
        }

        /// 流し (apply なら記録を書き)、(tally, 出力) を返す
        fn run(&self, mode: Mode) -> (Tally, String) {
            self.run_with(mode, |_| {})
        }

        /// `prepare` で Linker を整えてから流す
        fn run_with(&self, mode: Mode, prepare: impl FnOnce(&mut Linker)) -> (Tally, String) {
            let sys = FakeSys::new(|c| fake_mklink(c).expect("mklink だけを打つ"));
            let mut out = Vec::new();
            let mut ctx = Ctx {
                repo: self.t.path().join("dotfiles"),
                roots: Roots::from_home(&self.t.path().join("home")),
                state_dir: self.t.path().join("state"),
                host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                sys: &sys,
                out: &mut out,
            };
            let src = Source {
                root: self.base(),
                prev: None,
                foreign_suffix: None,
                kinds: &["skills", "rules"],
                skip_skills: Vec::new(),
                select: Some(only_pjp),
                origin: "~/.claude",
                absorb: "~/.claude",
                step: "claude-accounts",
            };
            let records = Records::load(&self.record_path()).unwrap();
            let mut w = Linker::new(
                src,
                self.t.path().join("home").join(".claude-work"),
                mode,
                records,
            );
            prepare(&mut w);
            w.run(&mut ctx);
            if mode.writes() {
                w.records.save_if_changed().unwrap();
            }
            let tally = std::mem::take(&mut w.tally);
            drop(ctx);
            (tally, String::from_utf8(out).unwrap())
        }
    }

    #[test]
    fn select_skips_and_prunes() {
        let e = Env::new();
        // 前に張ったリンク (今は写さない名前) と、前に写したコピー (今は写さない名前。中身は記録どおり)
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        std::fs::create_dir_all(e.dest("skills")).unwrap();
        create_junction(
            &sys,
            &e.dest("skills/mine"),
            &e.base().join("skills").join("mine"),
        )
        .unwrap();
        e.t.write("home/.claude-work/rules/other.md", "o\n");
        let mut r = Records::load(&e.record_path()).unwrap();
        r.set(
            &e.dest("rules/other.md").to_string_lossy(),
            &fsutil::sha256_bytes(b"o\n"),
        );
        r.save_if_changed().unwrap();

        let (tally, out) = e.apply();
        assert_eq!(
            (
                tally.added,
                tally.removed,
                tally.skipped.len(),
                tally.errors
            ),
            (2, 2, 0, 0),
            "{out}"
        );
        assert!(same_path(
            &link_target(&e.dest("skills/pjp-a")).unwrap(),
            &e.base().join("skills").join("pjp-a")
        ));
        assert_eq!(
            std::fs::read_to_string(e.dest("rules/pjp-r.md")).unwrap(),
            "r\n"
        );
        assert!(!is_link(&e.dest("skills/mine")) && !e.dest("skills/mine").exists());
        assert!(!e.dest("rules/other.md").exists());
        // 元は消さない
        assert!(
            e.base()
                .join("skills")
                .join("mine")
                .join("SKILL.md")
                .is_file()
        );
        assert!(e.base().join("rules").join("other.md").is_file());
        assert!(!out.contains("張らない"), "{out}");
        assert!(out.contains("写すものでない"), "{out}");
    }

    #[test]
    fn prune_messages_use_the_origin_name() {
        let e = Env::new();
        e.apply();
        // 元から消えた: リンクは外し、Windows 側で変えたコピーは残して知らせる
        std::fs::remove_dir_all(e.base().join("skills").join("pjp-a")).unwrap();
        std::fs::remove_file(e.base().join("rules").join("pjp-r.md")).unwrap();
        std::fs::write(e.dest("rules/pjp-r.md"), "changed\n").unwrap();
        // check はわけを出す (apply は「外しました」だけ)
        let (_, out) = e.run(Mode::Check);
        assert!(out.contains("~/.claude に無い"), "{out}");
        let (tally, out) = e.apply();
        assert_eq!(tally.removed, 1, "{out}");
        assert!(
            tally
                .skipped
                .iter()
                .any(|s| s.starts_with("rules/pjp-r.md (~/.claude から消えたが、")),
            "{:?}",
            tally.skipped
        );
    }

    /// hold した skill は、わけを添えて張らず、前にこの手順が張ったリンクは外す (ほかの先へのリンクには触らない)
    #[test]
    fn held_skills_are_not_linked_and_ours_are_removed() {
        let e = Env::new();
        e.t.write("base/skills/pjp-b/SKILL.md", "b\n");
        let elsewhere = e.t.path().join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        std::fs::create_dir_all(e.dest("skills")).unwrap();
        create_junction(
            &sys,
            &e.dest("skills/pjp-a"),
            &e.base().join("skills").join("pjp-a"),
        )
        .unwrap();
        create_junction(&sys, &e.dest("skills/pjp-b"), &elsewhere).unwrap();
        let hold = |w: &mut Linker| {
            w.hold("pjp-a", "わけ A");
            w.hold("pjp-b", "わけ B");
        };
        let (_, out) = e.run_with(Mode::Check, hold);
        assert!(out.contains("張らない (わけ A): skills/pjp-a"), "{out}");
        assert!(out.contains("外す (apply で): skills/pjp-a"), "{out}");
        assert!(out.contains("わけ A)"), "{out}");
        let (tally, out) = e.run_with(Mode::Apply { force: false }, hold);
        assert_eq!((tally.removed, tally.skipped.len()), (1, 0), "{out}");
        assert!(!is_link(&e.dest("skills/pjp-a")));
        assert!(same_path(
            &link_target(&e.dest("skills/pjp-b")).unwrap(),
            &elsewhere
        ));
        assert!(
            e.base()
                .join("skills")
                .join("pjp-a")
                .join("SKILL.md")
                .is_file()
        );
    }

    /// adopt_dangling の先を指すリンクは、先が無ければ (片付けた後の残り) 張り替え、先があれば別のリンクとして飛ばす
    #[test]
    fn adopts_dangling_links_only() {
        let e = Env::new();
        let other = e.t.path().join("other").join("skills");
        std::fs::create_dir_all(other.join("pjp-a")).unwrap();
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        std::fs::create_dir_all(e.dest("skills")).unwrap();
        create_junction(&sys, &e.dest("skills/pjp-a"), &other.join("pjp-a")).unwrap();
        let adopt = |w: &mut Linker| w.adopt_dangling(other.join("pjp-a"));
        let (tally, out) = e.run_with(Mode::Apply { force: false }, adopt);
        assert_eq!(tally.skipped.len(), 1, "先があるうちは別のリンク: {out}");
        assert!(same_path(
            &link_target(&e.dest("skills/pjp-a")).unwrap(),
            &other.join("pjp-a")
        ));
        std::fs::remove_dir_all(other.join("pjp-a")).unwrap();
        let (tally, out) = e.run_with(Mode::Apply { force: false }, adopt);
        assert_eq!((tally.updated, tally.skipped.len()), (1, 0), "{out}");
        assert!(same_path(
            &link_target(&e.dest("skills/pjp-a")).unwrap(),
            &e.base().join("skills").join("pjp-a")
        ));
    }

    #[test]
    fn a_linked_kind_dir_is_named_by_the_dest_dir() {
        let e = Env::new();
        let elsewhere = e.t.path().join("my-rules");
        std::fs::create_dir_all(&elsewhere).unwrap();
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        create_junction(&sys, &e.dest("rules"), &elsewhere).unwrap();
        let (tally, out) = e.apply();
        assert!(
            tally
                .skipped
                .iter()
                .any(|s| s.starts_with("rules (~/.claude-work/rules がリンク")),
            "{:?}\n{out}",
            tally.skipped
        );
        assert!(std::fs::read_dir(&elsewhere).unwrap().next().is_none());
    }
}
