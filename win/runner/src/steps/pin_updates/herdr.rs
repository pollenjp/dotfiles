//! herdr-app・herdr-core の、固定した版より新しい版。WSL の `nix/scripts/check-herdr-app-version.sh --json` を写した: `nix/pkgs/herdr-core/releases.json`
//! から固定した版を読んで確かめ (sha256 の形も)、隣の見送りの一覧を読み、GitHub の tag (`vX.Y.Z`) のうち固定した版より新しく、Windows の成果物が
//! releases.herdr.dev にある (HEAD が 404 でない) ものを、古い順に出す。見送った版は HEAD を打たない。確かめられなければ、WSL の口の stderr に
//! 当たる行 (gh・curl の stderr と口の `!!` の行。届いた順) を返す。

use super::{
    Found, Newer, Trouble, is_space, newer_than, read_fields, read_lines, remaining, run_split,
    timed_out, version_cmp, version_form,
};
use crate::context::Ctx;
use crate::jv::Jv;
use crate::process::{CommandSpec, Exit};
use std::path::Path;
use std::time::Instant;

/// 固定した版と sha256 (repo からの相対)
pub const RELEASES_REL: &str = "nix/pkgs/herdr-core/releases.json";
/// 見送りの一覧 (「app か core・版・理由」)
pub const SKIPPED_REL: &str = "nix/pkgs/herdr-core/skipped-versions.txt";
/// 版つきの成果物の置き場
pub const RELEASES_URL: &str = "https://releases.herdr.dev";
/// sha256 の形を確かめる部品と target。並びは WSL が誤りの文に並べる順 (bash の連想配列の鍵の並び)
pub const SHA_KEYS: &[(&str, &str)] = &[
    ("core", "linux-aarch64"),
    ("app", "windows-x86_64"),
    ("core", "windows-x86_64"),
    ("core", "linux-x86_64"),
];
/// 版の形 (`^[0-9]+\.[0-9]+\.[0-9]+$`)
const PARTS_3: (usize, usize) = (3, 3);

/// releases.json の値 (WSL の `jq -r "<式> // \"\" | tostring"`。無い・null・false・途中が object でないなら空)
fn pin(doc: &Jv, path: &[&str]) -> String {
    let mut v = doc;
    for k in path {
        v = match v {
            Jv::Object(_) => v.get(k).unwrap_or(&Jv::Null),
            _ => return String::new(),
        };
    }
    match v {
        Jv::Null | Jv::Bool(false) => String::new(),
        other => other.tostring(),
    }
}

/// `^[1-9][0-9]*$`
fn generation_form(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty() && (b'1'..=b'9').contains(&b[0]) && b.iter().all(u8::is_ascii_digit)
}

/// `^[0-9a-f]{64}$`
fn sha_form(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// `title_of` (herdr-core は Linux にも入るので「Windows の」を付けない)
pub fn title_of(name: &str) -> String {
    if name == "herdr-core" {
        name.to_string()
    } else {
        format!("Windows の {name}")
    }
}

/// 版つきの Windows の成果物の URL (WSL の `artifact_url <app か core> <版> windows-x86_64`)
pub fn artifact_url(kind: &str, version: &str) -> String {
    match kind {
        "app" => format!("{RELEASES_URL}/app/{version}/herdr-app-windows-x86_64.tar.gz"),
        _ => format!("{RELEASES_URL}/core/{version}/herdr-core-windows-x86_64.zip"),
    }
}

/// curl -sSIL の応答の、最後の状態 (redirect の先まで見て、最後の `HTTP/… <3 桁>`)
pub fn final_status(lines: &[String]) -> Option<String> {
    let mut status = None;
    for l in lines {
        let l = l.strip_suffix('\r').unwrap_or(l);
        let Some(rest) = l.strip_prefix("HTTP/") else {
            continue;
        };
        let ver_len = rest
            .bytes()
            .take_while(|b| b.is_ascii_digit() || *b == b'.')
            .count();
        if ver_len == 0 {
            continue;
        }
        let Some(code) = rest[ver_len..].strip_prefix(' ') else {
            continue;
        };
        if code.len() >= 3 && code.as_bytes()[..3].iter().all(u8::is_ascii_digit) {
            status = Some(code[..3].to_string());
        }
    }
    status
}

/// 見送りの一覧 (鍵は (app か core, 版)。同じ鍵は後の行の理由。WSL の連想配列と同じ)。
type Skipped = Vec<((String, String), String)>;

fn read_skipped(ctx: &Ctx) -> Result<Skipped, Trouble> {
    let path = ctx.repo_path(SKIPPED_REL);
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let text = match std::fs::read(&path) {
        Ok(b) => String::from_utf8_lossy(&b).into_owned(),
        Err(e) => {
            return Err(vec![format!(
                "!! 確かめられなかった: 見送りの一覧が読めません ({SKIPPED_REL}): {e}"
            )]);
        }
    };
    let mut out: Skipped = Vec::new();
    for (i, raw) in read_lines(&text).into_iter().enumerate() {
        let n = i + 1;
        let line = if n == 1 {
            raw.strip_prefix('\u{feff}').unwrap_or(raw)
        } else {
            raw
        };
        let line = line.strip_suffix('\r').unwrap_or(line);
        let t = line.trim_start_matches(is_space);
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        let f = read_fields(line, 3);
        let (kind, v, reason) = (f[0], f[1], f[2]);
        if !(kind == "app" || kind == "core") || !version_form(v, PARTS_3) || reason.is_empty() {
            return Err(vec![
                format!(
                    "!! 確かめられなかった: 見送りの一覧の {n} 行目が読めません ({SKIPPED_REL}): {line}"
                ),
                "   1 行に「app か core・版・理由」を空白で区切って書く (例: app 0.1.14 試したら窓が開かなかった)。".to_string(),
            ]);
        }
        let key = (kind.to_string(), v.to_string());
        match out.iter_mut().find(|(k, _)| *k == key) {
            Some((_, r)) => *r = reason.to_string(),
            None => out.push((key, reason.to_string())),
        }
    }
    Ok(out)
}

/// 外のコマンドの口と、待つ上限・stderr に出た行。
struct Reader<'a, 'b> {
    ctx: &'a Ctx<'b>,
    gh: &'a Path,
    curl: Option<&'a Path>,
    deadline: Instant,
    /// WSL の口の stderr に当たる行 (gh・curl の stderr と、口の `!!` の行)
    err: Vec<String>,
}

/// HEAD の結果
enum Head {
    /// 成果物が無い (404)
    Missing,
    /// あるか、確かめられない (どちらも数える。WSL も 404 のほかは版を入れる)
    Other,
}

impl Reader<'_, '_> {
    /// GitHub の repo の、版の形の tag (`vX.Y.Z`) の版を古い順に (WSL の `tag_versions`)。読めなければ口の行を返す。
    fn tag_versions(&mut self, repo: &str) -> Result<Vec<String>, Trouble> {
        let Some(limit) = remaining(self.deadline) else {
            return Err(timed_out(&self.err));
        };
        let r = run_split(
            self.ctx,
            CommandSpec::new(self.gh)
                .arg("api")
                .arg("--paginate")
                .arg(format!("repos/{repo}/tags?per_page=100"))
                .arg("--jq")
                .arg(".[].name")
                .timeout(limit),
        );
        self.err.extend(r.err);
        match &r.exit {
            Exit::Code(0) => {}
            Exit::TimedOut => return Err(timed_out(&self.err)),
            other => {
                if let Exit::SpawnFailed(e) = other {
                    self.err.push(format!("gh を起こせなかった: {e}"));
                }
                self.err.push(format!(
                    "!! 確かめられなかった: GitHub の {repo} の tag を読めない (gh api repos/{repo}/tags)"
                ));
                return Err(self.err.clone());
            }
        }
        let mut versions: Vec<String> = r
            .out
            .iter()
            .filter_map(|l| l.strip_prefix('v'))
            .filter(|v| version_form(v, PARTS_3))
            .map(str::to_string)
            .collect();
        versions.sort_by(|a, b| version_cmp(a, b));
        Ok(versions)
    }

    /// 成果物の HEAD (WSL の `published_at` のうち、setup が使う「無い (404)」かどうか)。上限を過ぎたら口の行を返す。
    fn head(&mut self, url: &str) -> Result<Head, Trouble> {
        let Some(curl) = self.curl else {
            // WSL は bash の「curl: command not found」を stderr に出し、版を入れる
            self.err.push("curl が見つからない".to_string());
            return Ok(Head::Other);
        };
        let Some(limit) = remaining(self.deadline) else {
            return Err(timed_out(&self.err));
        };
        let r = run_split(
            self.ctx,
            CommandSpec::new(curl)
                .arg("-sSIL")
                .arg("--max-time")
                .arg("60")
                .arg(url)
                .timeout(limit),
        );
        self.err.extend(r.err);
        match &r.exit {
            Exit::TimedOut => Err(timed_out(&self.err)),
            Exit::Code(0) if final_status(&r.out).as_deref() == Some("404") => Ok(Head::Missing),
            // 起こせない (WSL は bash の誤りを stderr に出し、版を入れる)
            Exit::SpawnFailed(e) => {
                self.err.push(format!("curl を起こせなかった: {e}"));
                Ok(Head::Other)
            }
            _ => Ok(Head::Other),
        }
    }

    /// 1 つの部品の新しい版 (WSL の `json_component`)。
    fn component(
        &mut self,
        kind: &str,
        pinned: &str,
        repo: &str,
        name: &str,
        skipped: &Skipped,
    ) -> Result<Found, Trouble> {
        let mut newer = Vec::new();
        for v in self.tag_versions(repo)? {
            if v.is_empty() || !newer_than(&v, pinned) {
                continue;
            }
            // 見送った版は数えない (成果物の HEAD も打たない)
            if let Some((_, reason)) = skipped.iter().find(|((k, sv), _)| k == kind && *sv == v) {
                newer.push(Newer {
                    version: v,
                    skipped: Some(reason.clone()),
                });
                continue;
            }
            // Windows の成果物が無い版は入れない
            if let Head::Missing = self.head(&artifact_url(kind, &v))? {
                continue;
            }
            newer.push(Newer {
                version: v,
                skipped: None,
            });
        }
        Ok(Found {
            title: title_of(name),
            pinned: pinned.to_string(),
            newer,
        })
    }
}

/// herdr-app と herdr-core の新しい版を 1 回で確かめる (WSL の `check-herdr-app-version.sh --json`)。
pub fn check(
    ctx: &Ctx,
    gh: &Path,
    curl: Option<&Path>,
    deadline: Instant,
) -> Result<(Found, Found), Trouble> {
    let file = ctx.repo_path(RELEASES_REL);
    let label = file.display().to_string();
    let doc = std::fs::read(&file)
        .ok()
        .and_then(|b| Jv::parse(&String::from_utf8_lossy(&b)).ok())
        .filter(Jv::is_object);
    let Some(doc) = doc else {
        return Err(vec![format!(
            "!! releases.json が読めません (無い・JSON でない): {label}"
        )]);
    };
    let app_version = pin(&doc, &["app", "version"]);
    let core_version = pin(&doc, &["core", "version"]);
    let core_generation = pin(&doc, &["core", "generation"]);
    let mut bad = String::new();
    if !version_form(&app_version, PARTS_3) {
        bad.push_str(&format!(" app.version={app_version}"));
    }
    if !version_form(&core_version, PARTS_3) {
        bad.push_str(&format!(" core.version={core_version}"));
    }
    if !generation_form(&core_generation) {
        bad.push_str(&format!(" core.generation={core_generation}"));
    }
    for (kind, target) in SHA_KEYS {
        let sha = pin(&doc, &[kind, "sha256", target]);
        if !sha_form(&sha) {
            bad.push_str(&format!(" {kind}.sha256.{target}={sha}"));
        }
    }
    if !bad.is_empty() {
        return Err(vec![format!(
            "!! releases.json から固定した版と sha256 を読めません ({}): {label}",
            &bad[1..]
        )]);
    }
    let skipped = read_skipped(ctx)?;
    let mut reader = Reader {
        ctx,
        gh,
        curl,
        deadline,
        err: Vec::new(),
    };
    let app = reader.component(
        "app",
        &app_version,
        "herdrdev/herdr-app",
        "herdr-app",
        &skipped,
    )?;
    let core = reader.component(
        "core",
        &core_version,
        "herdrdev/herdr-core",
        "herdr-core",
        &skipped,
    )?;
    Ok((app, core))
}
