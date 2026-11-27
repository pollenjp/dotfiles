//! winget で入れるもの (openssh・herdr・google-japanese-input・ntn・claude-code・tailscale・ghq・fzf・starship・codex と、bootstrap の git・gh・pwsh・
//! vs-buildtools・rustup) の、
//! 固定した版より新しい版。WSL の `nix/scripts/check-winget-version.sh --json` (出た日を引かない形。setup が使うもの) を写した: ps1 から固定した版と
//! パッケージ ID を、隣の見送りの一覧から見送った版を読み、winget-pkgs の manifest のディレクトリの一覧 (`gh api repos/microsoft/winget-pkgs/contents/…`)
//! の版のうち固定した版より新しいものを、古い順に出す。確かめられなければ、WSL の口が stderr に出す行を返す (文も同じ)。

use super::{
    Found, Newer, Trouble, cannot_check, is_space, newer_than, read_fields, read_lines, remaining,
    run_split, timed_out, version_cmp, version_form,
};
use crate::context::Ctx;
use crate::process::{CommandSpec, Exit};
use std::path::Path;
use std::time::Instant;

/// 名前ごとに違うもの (WSL の check-winget-version.sh の `case ${name}` の写し。試験が script の字と比べる)。
#[derive(Clone, Copy, Debug)]
pub struct WingetSpec {
    pub name: &'static str,
    pub title: &'static str,
    /// 固定した版を書く ps1 (repo からの相対)
    pub ps1: &'static str,
    /// 見送りの一覧 (repo からの相対)
    pub skipped: &'static str,
    /// ps1 の固定した版の param (`[string]$<名前> = '<版>'`)
    pub version_param: &'static str,
    /// ps1 のパッケージ ID の変数 (`$<名前> = '<ID>'`)
    pub id_var: &'static str,
    /// 版の形: `.` で区切った数の欄の数の下限と上限 (WSL の version_re)
    pub version_parts: (usize, usize),
    /// 固定した版に許す形 (WSL の pinned_version_re。None なら version_parts)
    pub pinned_parts: Option<(usize, usize)>,
    /// 版の例 (誤りの文に出す)
    pub version_example: &'static str,
    /// manifest のディレクトリに並ぶ、ID の続く別のパッケージのディレクトリ (版ではない)
    pub nested_dirs: &'static [&'static str],
    /// 候補の線 (WSL の series_re。`^7\.6\.` を `7.6.` の頭の字にしたもの)。Some なら、この字で始まる版だけを読む (線の外の版は新しい版に数えない)
    pub series: Option<&'static str>,
}

/// 版の形 `^[0-9]+(\.[0-9]+){1,3}$`
const PARTS_2_TO_4: (usize, usize) = (2, 4);
/// 版の形 `^[0-9]+\.[0-9]+\.[0-9]+$`
const PARTS_3: (usize, usize) = (3, 3);
/// 版の形 `^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$`
const PARTS_3_TO_4: (usize, usize) = (3, 4);
/// 版の形 `^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$`
const PARTS_4: (usize, usize) = (4, 4);

pub const SPECS: &[WingetSpec] = &[
    WingetSpec {
        name: "openssh",
        title: "Windows の OpenSSH",
        ps1: "win/openssh/Install-OpenSSH.ps1",
        skipped: "win/openssh/skipped-versions.txt",
        version_param: "Version",
        id_var: "packageId",
        version_parts: PARTS_2_TO_4,
        pinned_parts: None,
        version_example: "10.1.0.0",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "herdr",
        title: "Windows の herdr",
        ps1: "win/herdr/Install-Herdr.ps1",
        skipped: "win/herdr/skipped-versions.txt",
        version_param: "Version",
        id_var: "packageId",
        version_parts: PARTS_3,
        pinned_parts: None,
        version_example: "0.9.5",
        nested_dirs: &["Preview"],
        series: None,
    },
    WingetSpec {
        name: "google-japanese-input",
        title: "Google 日本語入力",
        ps1: "win/google-japanese-input/Install-GoogleJapaneseInput.ps1",
        skipped: "win/google-japanese-input/skipped-versions.txt",
        version_param: "Version",
        id_var: "packageId",
        version_parts: PARTS_2_TO_4,
        pinned_parts: None,
        version_example: "3.35.6300.0",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "ntn",
        title: "Windows の ntn",
        ps1: "win/ntn/Install-Ntn.ps1",
        skipped: "win/ntn/skipped-versions.txt",
        version_param: "Version",
        id_var: "packageId",
        version_parts: PARTS_3,
        pinned_parts: None,
        version_example: "0.23.28",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "claude-code",
        title: "Windows の Claude Code",
        ps1: "win/claude-code/Install-ClaudeCode.ps1",
        skipped: "win/claude-code/skipped-versions.txt",
        version_param: "Version",
        id_var: "packageId",
        version_parts: PARTS_3,
        pinned_parts: None,
        version_example: "2.1.318",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "tailscale",
        title: "Windows の Tailscale",
        ps1: "win/tailscale/Install-Tailscale.ps1",
        skipped: "win/tailscale/skipped-versions.txt",
        version_param: "Version",
        id_var: "packageId",
        version_parts: PARTS_3_TO_4,
        pinned_parts: Some(PARTS_3),
        version_example: "1.104.5",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "ghq",
        title: "Windows の ghq",
        ps1: "win/ghq/Install-Ghq.ps1",
        skipped: "win/ghq/skipped-versions.txt",
        version_param: "Version",
        id_var: "packageId",
        version_parts: PARTS_3,
        pinned_parts: None,
        version_example: "1.12.0",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "fzf",
        title: "Windows の fzf",
        ps1: "win/fzf/Install-Fzf.ps1",
        skipped: "win/fzf/skipped-versions.txt",
        version_param: "Version",
        id_var: "packageId",
        version_parts: PARTS_3,
        pinned_parts: None,
        version_example: "0.75.0",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "starship",
        title: "Windows の starship",
        ps1: "win/starship/Install-Starship.ps1",
        skipped: "win/starship/skipped-versions.txt",
        version_param: "Version",
        id_var: "packageId",
        version_parts: PARTS_3,
        pinned_parts: None,
        version_example: "1.27.0",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "codex",
        title: "Windows の Codex CLI",
        ps1: "win/codex/Install-Codex.ps1",
        skipped: "win/codex/skipped-versions.txt",
        version_param: "Version",
        id_var: "packageId",
        version_parts: PARTS_3,
        pinned_parts: None,
        version_example: "0.170.0",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "git",
        title: "Windows の Git for Windows",
        ps1: "win/bootstrap/Install-Bootstrap.ps1",
        skipped: "win/bootstrap/skipped-versions/git.txt",
        version_param: "GitVersion",
        id_var: "gitPackageId",
        version_parts: PARTS_3_TO_4,
        pinned_parts: None,
        version_example: "2.56.0.4",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "gh",
        title: "Windows の GitHub CLI",
        ps1: "win/bootstrap/Install-Bootstrap.ps1",
        skipped: "win/bootstrap/skipped-versions/gh.txt",
        version_param: "GhVersion",
        id_var: "ghPackageId",
        version_parts: PARTS_3,
        pinned_parts: None,
        version_example: "2.103.3",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "pwsh",
        title: "Windows の PowerShell 7",
        ps1: "win/bootstrap/Install-Bootstrap.ps1",
        skipped: "win/bootstrap/skipped-versions/pwsh.txt",
        version_param: "PwshVersion",
        id_var: "pwshPackageId",
        version_parts: PARTS_4,
        pinned_parts: None,
        version_example: "7.6.10.0",
        nested_dirs: &["Preview"],
        // bootstrap が入れる 7.6 (LTS) は、管理者の PC の MSIX (Microsoft.PowerShell-LTS) も管理者でない PC の MSI も 7.7 (MSI が無く、MSIX は
        // 別の package) へ上がらないので、7.6 の線の版だけを読む
        series: Some("7.6."),
    },
    WingetSpec {
        name: "vs-buildtools",
        title: "Windows の Visual Studio Build Tools 2022",
        ps1: "win/bootstrap/Install-Bootstrap.ps1",
        skipped: "win/bootstrap/skipped-versions/vs-buildtools.txt",
        version_param: "VsBuildToolsVersion",
        id_var: "vsBuildToolsPackageId",
        version_parts: PARTS_3,
        pinned_parts: None,
        version_example: "17.14.44",
        nested_dirs: &[],
        series: None,
    },
    WingetSpec {
        name: "rustup",
        title: "Windows の rustup",
        ps1: "win/bootstrap/Install-Bootstrap.ps1",
        skipped: "win/bootstrap/skipped-versions/rustup.txt",
        version_param: "RustupVersion",
        id_var: "rustupPackageId",
        version_parts: PARTS_3,
        pinned_parts: None,
        version_example: "1.29.3",
        nested_dirs: &[],
        series: None,
    },
];

/// ps1 の行の `[string]$<param> = '<版>'` の版 (WSL の pinned_re `^[[:space:]]*\[string\][$]<param>[[:space:]]*=[[:space:]]*'([^']*)'`)。
pub fn pinned_value(line: &str, param: &str) -> Option<String> {
    let rest = line
        .trim_start_matches(is_space)
        .strip_prefix("[string]$")?
        .strip_prefix(param)?;
    let rest = rest.trim_start_matches(is_space).strip_prefix('=')?;
    let rest = rest.trim_start_matches(is_space).strip_prefix('\'')?;
    let end = rest.find('\'')?;
    Some(rest[..end].to_string())
}

/// ps1 の行の `$<var> = '<ID>'` の ID (WSL の id_re `^[[:space:]]*[$]<var>[[:space:]]*=[[:space:]]*'([A-Za-z0-9][A-Za-z0-9.-]*)'`)。
pub fn id_value(line: &str, var: &str) -> Option<String> {
    let rest = line
        .trim_start_matches(is_space)
        .strip_prefix('$')?
        .strip_prefix(var)?;
    let rest = rest.trim_start_matches(is_space).strip_prefix('=')?;
    let rest = rest.trim_start_matches(is_space).strip_prefix('\'')?;
    let id = &rest[..rest.find('\'')?];
    let mut chars = id.chars();
    let first = chars.next()?;
    (first.is_ascii_alphanumeric()
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-'))
    .then(|| id.to_string())
}

/// 見送りの一覧 (「版 理由」。WSL と同じく BOM 付き・CRLF でも読み、`#` で始まる行と空行は読まない)。無ければ空。書き損じの行は WSL と同じ文を返す。
pub fn read_skipped(ctx: &Ctx, spec: &WingetSpec) -> Result<Vec<(String, String)>, Trouble> {
    let path = ctx.repo_path(spec.skipped);
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let text = match std::fs::read(&path) {
        Ok(b) => String::from_utf8_lossy(&b).into_owned(),
        // ファイルはあるが読めない (WSL は bash のリダイレクトの誤りで口が落ちる。文は bash のものなので、runner の文にする)
        Err(e) => {
            return Err(cannot_check(
                &format!("見送りの一覧が読めません ({}): {e}", spec.skipped),
                &[],
            ));
        }
    };
    let mut out = Vec::new();
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
        let f = read_fields(line, 2);
        let (v, reason) = (f[0], f[1]);
        if !version_form(v, spec.version_parts) || reason.is_empty() {
            return Err(cannot_check(
                &format!(
                    "見送りの一覧の {n} 行目が読めません ({}): {line}",
                    spec.skipped
                ),
                &[&format!(
                    "1 行に「版 理由」を空白で区切って書く。版は {} の版の形 (例: {} 試したら設定が読めなかった)。",
                    spec.title, spec.version_example
                )],
            ));
        }
        out.push((v.to_string(), reason.to_string()));
    }
    Ok(out)
}

/// ps1 から固定した版とパッケージ ID を読む (WSL と同じ順に確かめ、同じ文を返す)。
pub fn read_pins(ctx: &Ctx, spec: &WingetSpec) -> Result<(String, String), Trouble> {
    let ps1_name = spec.ps1.rsplit('/').next().unwrap_or(spec.ps1);
    let text = match std::fs::read(ctx.repo_path(spec.ps1)) {
        Ok(b) => String::from_utf8_lossy(&b).into_owned(),
        Err(_) => {
            return Err(cannot_check(
                &format!("{ps1_name} が読めません: {}", spec.ps1),
                &[],
            ));
        }
    };
    let mut pinned = None;
    let mut id = None;
    for line in read_lines(&text) {
        if pinned.is_none()
            && let Some(v) = pinned_value(line, spec.version_param)
        {
            pinned = Some(v);
            continue;
        }
        if id.is_none() {
            id = id_value(line, spec.id_var);
        }
    }
    let Some(pinned) = pinned else {
        return Err(cannot_check(
            &format!(
                "固定した版が読めません: {} に [string]${} = '<版>' の行がありません。",
                spec.ps1, spec.version_param
            ),
            &[],
        ));
    };
    if !version_form(&pinned, spec.pinned_parts.unwrap_or(spec.version_parts)) {
        return Err(cannot_check(
            &format!(
                "固定した版が読めません: {} の -{} の既定値 '{pinned}' が {} の版の形ではありません (例: {})。",
                spec.ps1, spec.version_param, spec.title, spec.version_example
            ),
            &[],
        ));
    }
    let Some(id) = id else {
        return Err(cannot_check(
            &format!(
                "パッケージ ID が読めません: {} に ${} = '<ID>' の行がありません。",
                spec.ps1, spec.id_var
            ),
            &[],
        ));
    };
    Ok((pinned, id))
}

/// winget-pkgs の manifest のディレクトリ (`manifests/<ID の頭文字 (小文字)>/<ID の . を / にしたもの>`)
pub fn manifest_dir(id: &str) -> String {
    let initial: String = id.chars().take(1).flat_map(char::to_lowercase).collect();
    format!("manifests/{initial}/{}", id.replace('.', "/"))
}

/// contents の応答から、ディレクトリの名前を jq の `-r` の出力の行で出す (WSL の
/// `if type == "array" then .[] | select(.type == "dir") | .name else error(…) end`)。JSON の値が続けて並べば、jq と同じく順に読む。
/// 一覧でない・読めなければ None。
fn dir_names(body: &str) -> Option<Vec<String>> {
    use serde_json::Value;
    let mut out = String::new();
    for v in serde_json::Deserializer::from_str(body).into_iter::<Value>() {
        let Value::Array(items) = v.ok()? else {
            return None;
        };
        for e in items {
            match e {
                Value::Object(o) => {
                    if o.get("type") == Some(&Value::String("dir".to_string())) {
                        match o.get("name") {
                            Some(Value::String(s)) => out.push_str(s),
                            Some(other) => out.push_str(&other.to_string()),
                            None => out.push_str("null"),
                        }
                        out.push('\n');
                    }
                }
                // null の .type は null (dir でない)。ほかの型の .type は jq のエラー
                Value::Null => {}
                _ => return None,
            }
        }
    }
    Some(read_lines(&out).into_iter().map(str::to_string).collect())
}

/// 固定した版より新しい winget の版を確かめる (WSL の `check-winget-version.sh --json <名前>`)。
pub fn check(ctx: &Ctx, gh: &Path, spec: &WingetSpec, deadline: Instant) -> Result<Found, Trouble> {
    let (pinned, id) = read_pins(ctx, spec)?;
    let dir = manifest_dir(&id);
    let api = format!("repos/microsoft/winget-pkgs/contents/{dir}");
    let skipped = read_skipped(ctx, spec)?;
    let Some(limit) = remaining(deadline) else {
        return Err(timed_out(&[]));
    };
    let r = run_split(
        ctx,
        CommandSpec::new(gh).arg("api").arg(&api).timeout(limit),
    );
    let gone = |why: &str| {
        cannot_check(
            &format!("{id} が winget-pkgs に無い ({why})。新しい版を出せない"),
            &[],
        )
    };
    match &r.exit {
        Exit::Code(0) => {}
        Exit::TimedOut => return Err(timed_out(&[])),
        Exit::SpawnFailed(e) => {
            return Err(cannot_check(
                &format!("winget-pkgs の {dir} を読めませんでした (gh api {api}):"),
                &[&format!("gh を起こせなかった: {e}")],
            ));
        }
        _ => {
            // 404 はパッケージごと外されたとき。ほかの失敗は確かめられない
            if r.err.iter().any(|l| l.contains("HTTP 404")) {
                return Err(gone(&format!("{dir} が無い")));
            }
            return Err(cannot_check(
                &format!("winget-pkgs の {dir} を読めませんでした (gh api {api}):"),
                &[&r.err.join("\n")],
            ));
        }
    }
    let body = r.out.join("\n");
    let Some(names) = dir_names(&body) else {
        // WSL は応答の頭の 300 バイトを添える (`head -c 300`)
        let bytes = body.as_bytes();
        let head = String::from_utf8_lossy(&bytes[..bytes.len().min(300)]);
        return Err(cannot_check(
            "winget-pkgs の応答が読めませんでした (ディレクトリの一覧ではない):",
            &[head.trim_end_matches('\n')],
        ));
    };
    // ID の続く別のパッケージのディレクトリは、版でもこのパッケージの中身でもないので除く
    let names: Vec<String> = names
        .into_iter()
        .filter(|n| !spec.nested_dirs.contains(&n.as_str()))
        .collect();
    if names.iter().all(|n| n.is_empty()) {
        return Err(gone(&format!("{dir} に版のディレクトリが無い")));
    }
    // 候補の線を決めた名前は、その線の版だけを読む (WSL の `grep -E "${series_re}"`。線の外の版は新しい版に数えない)
    let mut versions: Vec<&String> = names
        .iter()
        .filter(|n| version_form(n, spec.version_parts))
        .filter(|n| spec.series.is_none_or(|prefix| n.starts_with(prefix)))
        .collect();
    versions.sort_by(|a, b| version_cmp(a, b));
    let newer = versions
        .into_iter()
        .filter(|v| !v.is_empty() && newer_than(v, &pinned))
        .map(|v| Newer {
            version: v.clone(),
            // 見送りの一覧の初めの行 (WSL の skip_reason)
            skipped: skipped
                .iter()
                .find(|(s, _)| s == v)
                .map(|(_, reason)| reason.clone()),
        })
        .collect();
    Ok(Found {
        title: spec.title.to_string(),
        pinned,
        newer,
    })
}
