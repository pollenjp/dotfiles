//! ホストの値 (手元の `%USERPROFILE%\.config\dotfiles\host.toml` か、dotfiles-private の `win/hosts/<Windows のユーザー名>@<PC の名前>.toml`) と、
//! 設定グループの写し (`groups.json`)。
//!
//! 引く順は `--host-file` → 手元の `host.toml` (雛形 `win/templates/host.minimum.toml` を bootstrap が写す。gh にログインできない PC 向け) →
//! dotfiles-private (`resolve`)。手元と dotfiles-private の両方があれば、値は手元のものを読み、check は ⚠・apply は止める (どちらを使うか
//! 決まらない。`Source::Both`)。on の道具の要る道具 (`groups.json` の `requires`。道具の switch `privateRepos` (pollenjp の private な repo と gh の
//! ログイン。runner だけが読む道具) が要る道具や、集約ハブ `herdrHub` が要る windowsClaudeCode・windowsHerdr) が off なら、読むときに止める
//! (dotfiles-private の docs/adr/111_win_runner_without_gh_*・docs/adr/124_*)。
//!
//! ホストの値は WSL の Nix のホスト (`nix/hosts/<user>@<hostname>.nix`) に当たる。書けるのは設定グループ (`group`)・道具の switch の上書き
//! (`[tools]`。`group.json` の `tools` と同じ名前)・受け持ちの印 (`[runner] enable`)・op-reason の SSH の中継のモード (`[opReason]`)・
//! sshd に入れる公開鍵 (`[sshd] authorizedKeys`。Nix の `wsl.windowsFiles.sshd.authorizedKeys` と同じ意味)・sshd の AllowUsers のユーザーと
//! 入ってよい送り元 (`[sshd] allowUsers`・`allowFrom`。Nix には無い)・
//! T3 Code の Claude に `CLAUDE_CODE_ENTRYPOINT=""` を渡すか (`[t3Code]`)・Notion へ書く skill の宛先 (`[claude.notion]`。Nix の `dotfiles.claude.notion` と同じ名前と形)・
//! claude の setup-token の token の置き場の宣言 (`[claude.tokens]`。Nix の `dotfiles.claude.tokens` と同じ名前と形。ただし素の claude の `default` は書けない) だけ。書いていない道具の既定は、Nix が表 (`nix/lib/groups.nix`) から書き出した `groups.json`
//! (`nix eval --raw ./nix#lib.windowsGroupsJson`) から引く (dotfiles-private の docs/adr/058_win_runner_bootstrap_* §2 H・
//! docs/adr/064_win_w02_claude_skills_hub_*)。設定グループは道具の集合で、minimum (既定) と all の 2 つ (docs/adr/109_host_groups_minimum_all_*)。
//! 前のグループの名前 (personal・company・client。ADR 057) は、書き直し方を案内して止める。
//!
//! ```toml
//! group = "minimum"             # minimum (既定)・all (dotfiles の nix/README.md の「設定グループ」)
//!
//! [tools]
//! windowsTypeClipboard = true
//!
//! [runner]
//! enable = false                # true で apply を許す (WSL の windowsFiles.enable = false と同じ PR で変える)
//!
//! [opReason]
//! sshRelayMode = "per-call"     # SSH の中継のモード (per-call・show-only。書かなければ per-call)。効くのは [tools] opReasonSshRelay = true のとき
//!
//! [sshd]
//! authorizedKeys = ["from=\"100.64.0.1\" ssh-ed25519 AAAA… iphone"]   # sshd に入れる公開鍵 (1 つが authorized_keys の 1 行)。書かなければ null
//! allowUsers = ["alice"]        # AllowUsers に書くユーザー。書かなければ null (Install-Sshd を流したユーザー)、[] は誰も入れない
//! allowFrom = ["100.64.0.0/10", "127.0.0.1"]   # 入ってよい送り元 (IPv4・IPv6 のアドレスか CIDR)。書かなければ null (tailnet と localhost)、[] はどこからも入れない
//!
//! [t3Code]
//! clearClaudeEntrypoint = true  # T3 Code の Claude に CLAUDE_CODE_ENTRYPOINT="" を渡す (書かなければ false)。効くのは [tools] windowsT3Code = true のとき
//!
//! [claude.notion]
//! profile = "personal"          # Notion へ書く skill がこのマシンで既定に使うプロファイル (書かなければ null)
//! routes = { "pollenjp/x" = "work" }   # このマシンだけの宛先の規則
//!
//! [claude.notion.override.personal]    # プロファイルの値を、このマシンだけ差し替える
//! scanData = "https://app.notion.com/p/…"
//!
//! [claude.notion.tokens.personal]      # このマシンで Notion の API キーを使うプロファイルと種類 (Nix の dotfiles.claude.notion.tokens と同じ)
//! kind = "personal"                    # integration (integration の API キー)・personal (個人用アクセストークン)
//! item = "op://<vault>/<項目>/<欄>"     # 元の値の 1Password の参照 (欄まで。値ではない)。書かなければ null
//!
//! [claude.tokens.alt]                  # この PC のアカウント alt (claude-account add alt --mode token) に置いた claude setup-token の token (Nix の dotfiles.claude.tokens と同じ)
//! label = "alt"                        # token の呼び名 (同じ token を置いたホスト・アカウントで同じにする)。書かなければアカウントの名前
//! item = "op://<vault>/<項目>/<欄>"     # 元の token の 1Password の参照 (欄まで。値ではない)。書かなければ null
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Notion へ書く skill の宛先 (ホストの値の `[claude.notion]`)。claude-skills の pjp-notion-profile が読む
/// `~/.local/state/dotfiles/claude-notion.json` の中身になる。綴り (プロファイルがあるか・知らないキー) は claude-skills の resolver が
/// 使うときに確かめる (Nix の option と同じ)。
///
/// Notion の API キーの宣言 (`[claude.notion.tokens.<名前>]`) は別のファイル `~/.local/state/dotfiles/notion-tokens.json` になる
/// (`tokens_json`。Linux の home/modules/claude.nix と同じく、古い resolver が知らないキーで止まらないように分ける)。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct NotionValues {
    /// このマシンの既定のプロファイル (無ければ JSON の null)
    pub profile: Option<String>,
    /// このマシンだけの宛先の規則 (`owner/*`・`owner/repo` → プロファイル)
    pub routes: BTreeMap<String, String>,
    /// プロファイルごとの値の上書き (JSON に写したもの)
    pub overrides: serde_json::Map<String, serde_json::Value>,
    /// このマシンで Notion の API キーを使うプロファイルと、その種類の宣言 (名前 → 宣言。値 (token) は持たない)
    pub tokens: BTreeMap<String, NotionToken>,
}

/// Notion の API キーの種類 (Nix の `dotfiles.claude.notion.tokens.<名前>.kind` と同じ 2 つ)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TokenKind {
    /// integration の API キー (接続したページにだけ届く。秘密を作り直せば古いものが無効になる)
    Integration,
    /// 個人用アクセストークン (Notion の web で発行する。ユーザーの権限が届く範囲)
    Personal,
}

impl TokenKind {
    /// TOML と JSON に書く字
    pub fn as_str(self) -> &'static str {
        match self {
            TokenKind::Integration => "integration",
            TokenKind::Personal => "personal",
        }
    }

    /// 知らせに出す名前 (Linux の nix/scripts/bootstrap-notion-tokens.sh の kind_label と同じ)
    pub fn label(self) -> &'static str {
        match self {
            TokenKind::Integration => "integration の API キー",
            TokenKind::Personal => "個人用アクセストークン",
        }
    }
}

/// Notion の API キーの宣言 1 つ (`[claude.notion.tokens.<名前>]` の `kind`・`item`)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NotionToken {
    pub kind: TokenKind,
    /// 元の値を置いた 1Password の参照 (欄まで書いた `op://…`。値ではない)。書かなければ None (JSON の null)。dotfiles は読まず、
    /// claude-skills の棚卸しと回す手順と、手順 notion-tokens の入れ方の知らせが使う
    pub item: Option<String>,
}

/// claude の setup-token の token の置き場の宣言 1 つ (`[claude.tokens.<名前>]` の `label`・`item`。Linux の `dotfiles.claude.tokens.<名前>` と同じ)。
/// 値 (token) は持たない。`~/.local/state/dotfiles/claude-tokens.json` (`claude_tokens_json`) になり、`claude-account audit` が読む
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClaudeToken {
    /// token の呼び名 (同じ token を置いたホスト・アカウントで同じにする)。書かなければアカウントの名前
    pub label: String,
    /// 元の token を置いた 1Password の参照 (欄まで書いた `op://…`。値ではない)。書かなければ None (JSON の null)
    pub item: Option<String>,
}

/// 素の claude (`~/.claude`) の名前。Linux では宣言すると素の claude が token で起きるが、Windows の素の claude は /login のままなので、
/// ホストの値には書けない (dotfiles-private の docs/adr/123_claude_token_watch_*)
pub const BARE_NAME: &str = "default";

/// claude-tokens.json の中身。Linux の nix/lib/claude-tokens.nix の stateText (`builtins.toJSON { accounts = …; } + "\n"`) と同じバイト列
/// (名前の順・キーの順・空白なしの 1 行と改行)。宣言が無くても `{"accounts":{}}`:
///
/// `{"accounts":{"alt":{"item":null,"label":"alt"}}}`
pub fn claude_tokens_json(tokens: &BTreeMap<String, ClaudeToken>) -> String {
    let accounts: serde_json::Map<String, serde_json::Value> = tokens
        .iter()
        .map(|(name, t)| {
            let mut e = serde_json::Map::new();
            e.insert(
                "item".to_string(),
                t.item
                    .clone()
                    .map_or(serde_json::Value::Null, serde_json::Value::String),
            );
            e.insert(
                "label".to_string(),
                serde_json::Value::String(t.label.clone()),
            );
            (name.clone(), serde_json::Value::Object(e))
        })
        .collect();
    let mut top = serde_json::Map::new();
    top.insert("accounts".to_string(), serde_json::Value::Object(accounts));
    format!("{}\n", serde_json::Value::Object(top))
}

/// `[claude.tokens]` のキー (アカウントの名前) の形: claude-account の名前 (英小文字・数字で始まり、英小文字・数字・- と _ だけで 32 字まで。
/// sk-ant- で始まらない) で、管理のコマンド・claude-selector の名前 (account・selector) でない。Linux の nix/lib/claude-tokens.nix の nameOk と同じ
pub fn claude_token_name_ok(name: &str) -> bool {
    crate::accounts::name_ok(name) && !crate::accounts::RESERVED.contains(&name)
}

/// token の呼び名の形: 英小文字・数字で始まり、英小文字・数字・. - _ だけで 64 字まで。sk-ant- で始まらない (token の値を書いたとき)。
/// Linux の nix/lib/claude-tokens.nix の labelOk と同じ
pub fn claude_token_label_ok(label: &str) -> bool {
    let mut chars = label.chars();
    let lead_ok = chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    lead_ok
        && label.len() <= 64
        && !label.starts_with("sk-ant-")
        && chars
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-'))
}

/// `~/.config/pjp/env` の変数名。名前を大文字にし、`-` を `_` にして頭に `PJP_NOTION_TOKEN_` を付ける (Linux の nix/lib/notion-tokens.nix の
/// var と、claude-skills の resolver と同じ規則。personal → `PJP_NOTION_TOKEN_PERSONAL`、my-ws → `PJP_NOTION_TOKEN_MY_WS`)
pub fn token_var(name: &str) -> String {
    format!(
        "PJP_NOTION_TOKEN_{}",
        name.to_ascii_uppercase().replace('-', "_")
    )
}

/// 欄まで書いた 1Password の参照か (`op://<vault>/<項目>/<欄>`、セクションがあれば `op://<vault>/<項目>/<セクション>/<欄>`)。区切りの間は空でなく、
/// `/` と制御文字を含まない (空白と ASCII でない字は通す)。Linux の nix/lib/notion-tokens.nix の
/// `op://[^/[:cntrl:]]+/[^/[:cntrl:]]+/[^/[:cntrl:]]+(/[^/[:cntrl:]]+)?` と、bootstrap-notion-tokens.sh の jq の形と同じ
pub fn item_ref_ok(item: &str) -> bool {
    let Some(rest) = item.strip_prefix("op://") else {
        return false;
    };
    let parts: Vec<&str> = rest.split('/').collect();
    matches!(parts.len(), 3 | 4)
        && parts
            .iter()
            .all(|p| !p.is_empty() && !p.chars().any(char::is_control))
}

impl NotionValues {
    /// notion-tokens.json の中身。Linux の nix/lib/notion-tokens.nix の stateText (`builtins.toJSON { tokens = …; } + "\n"`) と同じバイト列
    /// (名前の順・キーの順・空白なしの 1 行と改行)。宣言が無くても `{"tokens":{}}`:
    ///
    /// `{"tokens":{"personal":{"item":null,"kind":"integration","var":"PJP_NOTION_TOKEN_PERSONAL"}}}`
    pub fn tokens_json(&self) -> String {
        let tokens: serde_json::Map<String, serde_json::Value> = self
            .tokens
            .iter()
            .map(|(name, t)| {
                let mut e = serde_json::Map::new();
                e.insert(
                    "item".to_string(),
                    t.item
                        .clone()
                        .map_or(serde_json::Value::Null, serde_json::Value::String),
                );
                e.insert(
                    "kind".to_string(),
                    serde_json::Value::String(t.kind.as_str().to_string()),
                );
                e.insert(
                    "var".to_string(),
                    serde_json::Value::String(token_var(name)),
                );
                (name.clone(), serde_json::Value::Object(e))
            })
            .collect();
        let mut top = serde_json::Map::new();
        top.insert("tokens".to_string(), serde_json::Value::Object(tokens));
        format!("{}\n", serde_json::Value::Object(top))
    }

    /// claude-notion.json の中身。Linux の home/modules/claude.nix の `builtins.toJSON { inherit profile routes override; } + "\n"` と同じ
    /// バイト列 (キーの順・空白なしの 1 行と改行)。
    pub fn json(&self) -> String {
        let routes: serde_json::Map<String, serde_json::Value> = self
            .routes
            .iter()
            .map(|(k, v)| (k.clone(), serde_json::Value::String(v.clone())))
            .collect();
        let mut top = serde_json::Map::new();
        top.insert(
            "override".to_string(),
            serde_json::Value::Object(self.overrides.clone()),
        );
        top.insert(
            "profile".to_string(),
            match &self.profile {
                Some(p) => serde_json::Value::String(p.clone()),
                None => serde_json::Value::Null,
            },
        );
        top.insert("routes".to_string(), serde_json::Value::Object(routes));
        format!("{}\n", serde_json::Value::Object(top))
    }
}

/// プロファイルの名前の形 (`[a-z0-9][a-z0-9_-]*`。Nix の option の strMatching と claude-skills の NAME_RE と同じ)
fn profile_name_ok(name: &str) -> bool {
    let mut chars = name.chars();
    let lead_ok = chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    lead_ok && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// TOML の値を JSON に写す (`where_` は誤りの文に出す場所)。日時は JSON に無いので誤り、小数は有限のものだけ。
fn toml_to_json(v: &toml::Value, where_: &str) -> Result<serde_json::Value, String> {
    Ok(match v {
        toml::Value::String(s) => serde_json::Value::String(s.clone()),
        toml::Value::Integer(i) => serde_json::Value::from(*i),
        toml::Value::Float(f) => serde_json::Number::from_f64(*f)
            .map(serde_json::Value::Number)
            .ok_or_else(|| format!("{where_} は有限の数で書いてください"))?,
        toml::Value::Boolean(b) => serde_json::Value::Bool(*b),
        toml::Value::Datetime(_) => {
            return Err(format!(
                "{where_} は日時で書けません (JSON に写せない。文字列にする)"
            ));
        }
        toml::Value::Array(items) => serde_json::Value::Array(
            items
                .iter()
                .enumerate()
                .map(|(i, item)| toml_to_json(item, &format!("{where_}[{i}]")))
                .collect::<Result<_, _>>()?,
        ),
        toml::Value::Table(t) => serde_json::Value::Object(
            t.iter()
                .map(|(k, item)| Ok((k.clone(), toml_to_json(item, &format!("{where_}.{k}"))?)))
                .collect::<Result<_, String>>()?,
        ),
    })
}

/// `[claude]` の表を読む (書けるのは `[claude.notion]` と `[claude.tokens]`)。
fn parse_claude(v: &toml::Value) -> Result<(NotionValues, BTreeMap<String, ClaudeToken>), String> {
    let toml::Value::Table(claude) = v else {
        return Err("claude は [claude.notion]・[claude.tokens] の表で書いてください".to_string());
    };
    let unknown: Vec<&str> = claude
        .keys()
        .map(String::as_str)
        .filter(|k| !["notion", "tokens"].contains(k))
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "[claude] に知らないキーがあります: {} (書けるのは [claude.notion]・[claude.tokens])",
            shown_keys(&unknown)
        ));
    }
    let tokens = match claude.get("tokens") {
        None => BTreeMap::new(),
        Some(toml::Value::Table(t)) => parse_claude_tokens(t)?,
        Some(_) => {
            return Err(
                "[claude] の tokens は表で書いてください ([claude.tokens.<アカウントの名前>])"
                    .to_string(),
            );
        }
    };
    let notion = match claude.get("notion") {
        None => NotionValues::default(),
        Some(n) => parse_notion(n)?,
    };
    Ok((notion, tokens))
}

/// `[claude.tokens]` を読む (Linux の nix/lib/claude-tokens.nix の assertions と同じ見方に、Nix では型が見るもの (表でない値・label が文字列で
/// ない・知らないキー) と、Windows では書けない素の claude (`default`) を足す)。止める文に、規則に合わない名前・label・item・知らないキーの字を
/// 出さない (token の値を書いてしまったときに、端末やログへ値が出ないように。名前は数だけ、label と item は宣言の名前だけを出す)。
fn parse_claude_tokens(t: &toml::Table) -> Result<BTreeMap<String, ClaudeToken>, String> {
    let bad = t.keys().filter(|n| !claude_token_name_ok(n)).count();
    if bad > 0 {
        return Err(format!(
            "[claude.tokens] のキー (アカウントの名前) のうち {bad} 個が、アカウントの名前の形ではありません (書いた字は出しません)。英小文字・数字で始め、英小文字・数字・- と _ だけで 32 字までにしてください (sk-ant- で始まる字・account・selector は使えない)。token の値そのものを書いたのなら、その行を消して、token を作り直してください"
        ));
    }
    if t.contains_key(BARE_NAME) {
        return Err(format!(
            "[claude.tokens] の {BARE_NAME} (素の claude) は Windows のホストの値には書けません (Windows の素の claude は token を読まず、/login で使う。dotfiles-private の ADR 123)。素の claude を token で起こすのは Linux のホスト (Nix の dotfiles.claude.tokens.{BARE_NAME}) だけです"
        ));
    }
    let mut out = BTreeMap::new();
    for (name, v) in t {
        let toml::Value::Table(e) = v else {
            return Err(format!(
                "[claude.tokens] の {name} は表で書いてください ([claude.tokens.{name}] に label と item。どちらも省ける)"
            ));
        };
        let unknown = e
            .keys()
            .filter(|k| !["label", "item"].contains(&k.as_str()))
            .count();
        if unknown > 0 {
            return Err(format!(
                "[claude.tokens.{name}] に知らないキーが {unknown} 個あります (書けるのは label・item。書いた字は出しません)"
            ));
        }
        let label = match e.get("label") {
            None => name.clone(),
            Some(toml::Value::String(l)) if claude_token_label_ok(l) => l.clone(),
            Some(_) => {
                return Err(format!(
                    "[claude.tokens.{name}] の label が、token の呼び名の形ではありません (書いた字は出しません)。英小文字・数字で始め、英小文字・数字・. - _ だけで 64 字までにしてください (sk-ant- で始まる字は使えない)。同じ token を置いたホスト・アカウントで同じ呼び名にします (書かなければアカウントの名前)。token の値そのものを書いたのなら、その行を消して、token を作り直してください (commit した値は履歴に残ります)"
                ));
            }
        };
        let item = match e.get("item") {
            None => None,
            Some(toml::Value::String(s)) if item_ref_ok(s) => Some(s.clone()),
            Some(_) => {
                return Err(format!(
                    "[claude.tokens.{name}] の item が、欄まで書いた 1Password の参照 (op://<vault の ID>/<項目の ID>/<欄の ID>。セクションがあれば op://<vault>/<項目>/<セクション>/<欄>) の形ではありません (書いた字は出しません)。pjp-op-ref が出す ID の形の参照を書くか、分かるまで item を書かないでください。token の値そのものを書いたのなら、その行を消して、token を作り直してください (commit した値は履歴に残ります)"
                ));
            }
        };
        out.insert(name.clone(), ClaudeToken { label, item });
    }
    Ok(out)
}

/// `[claude.notion]` の表を読む。
fn parse_notion(notion: &toml::Value) -> Result<NotionValues, String> {
    let toml::Value::Table(notion) = notion else {
        return Err("[claude] の notion は [claude.notion] の表で書いてください".to_string());
    };
    let unknown: Vec<&str> = notion
        .keys()
        .map(String::as_str)
        .filter(|k| !["profile", "routes", "override", "tokens"].contains(k))
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "[claude.notion] に知らないキーがあります: {} (書けるのは profile・routes・override・tokens)",
            unknown.join(", ")
        ));
    }
    let profile = match notion.get("profile") {
        None => None,
        Some(toml::Value::String(p)) if profile_name_ok(p) => Some(p.clone()),
        Some(other) => {
            let shown = match other {
                toml::Value::String(s) => format!("\"{s}\""),
                other => format!("{other:?}"),
            };
            return Err(format!(
                "[claude.notion] の profile は、英小文字・数字で始まり英小文字・数字・- と _ だけの名前 (profiles.toml のプロファイルの名前) で書いてください: {shown}"
            ));
        }
    };
    let mut routes = BTreeMap::new();
    match notion.get("routes") {
        None => {}
        Some(toml::Value::Table(t)) => {
            for (k, v) in t {
                let Some(s) = v.as_str() else {
                    return Err(format!(
                        "[claude.notion] の routes の {k} は文字列 (プロファイルの名前) で書いてください"
                    ));
                };
                routes.insert(k.clone(), s.to_string());
            }
        }
        Some(_) => {
            return Err(
                "[claude.notion] の routes は表で書いてください ({ \"owner/*\" = \"<プロファイル>\" })"
                    .to_string(),
            );
        }
    }
    let overrides = match notion.get("override") {
        None => serde_json::Map::new(),
        Some(v @ toml::Value::Table(_)) => match toml_to_json(v, "[claude.notion] の override")? {
            serde_json::Value::Object(m) => m,
            _ => unreachable!("表は object に写る"),
        },
        Some(_) => {
            return Err(
                "[claude.notion] の override は表で書いてください ([claude.notion.override.<プロファイル>])"
                    .to_string(),
            );
        }
    };
    let tokens = match notion.get("tokens") {
        None => BTreeMap::new(),
        Some(toml::Value::Table(t)) => parse_tokens(t)?,
        Some(_) => {
            return Err(
                "[claude.notion] の tokens は表で書いてください ([claude.notion.tokens.<プロファイル>])"
                    .to_string(),
            );
        }
    };
    Ok(NotionValues {
        profile,
        routes,
        overrides,
        tokens,
    })
}

/// `[claude.notion.tokens]` を読む (Linux の nix/lib/notion-tokens.nix の assertions と同じ見方)。止める文に `kind` と `item` の字を出さない
/// (token の値を書いてしまったときに、端末やログへ値が出ないように。名前とキーの名前だけを出す)。
fn parse_tokens(t: &toml::Table) -> Result<BTreeMap<String, NotionToken>, String> {
    // 名前の形 (profiles.toml の名前と同じ)。変数名と ~/.config/pjp/env の行が壊れる
    let bad: Vec<String> = t
        .keys()
        .filter(|n| !profile_name_ok(n))
        .map(|n| serde_json::Value::String(n.clone()).to_string())
        .collect();
    if !bad.is_empty() {
        return Err(format!(
            "[claude.notion.tokens] のキー (プロファイルの名前) が profiles.toml の名前の形ではありません: {}。英小文字か数字で始め、英小文字・数字・- と _ だけにしてください (変数名 PJP_NOTION_TOKEN_<名前> を作るため)",
            bad.join(" ")
        ));
    }
    // 同じ変数になる名前の組 (my-ws と my_ws)。~/.config/pjp/env の 1 行を 2 つのプロファイルで取り合う
    let mut by_var: BTreeMap<String, Vec<&str>> = BTreeMap::new();
    for n in t.keys() {
        by_var.entry(token_var(n)).or_default().push(n);
    }
    let same: Vec<String> = by_var
        .iter()
        .filter(|(_, ns)| ns.len() > 1)
        .map(|(var, ns)| format!("{} → {var}", ns.join("・")))
        .collect();
    if !same.is_empty() {
        return Err(format!(
            "[claude.notion.tokens] の次の名前は、同じ変数になります (- は _ に読み替える): {}。どれか 1 つにしてください",
            same.join("; ")
        ));
    }
    let mut out = BTreeMap::new();
    for (name, v) in t {
        let toml::Value::Table(e) = v else {
            return Err(format!(
                "[claude.notion.tokens] の {name} は表で書いてください ([claude.notion.tokens.{name}] に kind と item)"
            ));
        };
        let unknown: Vec<&str> = e
            .keys()
            .map(String::as_str)
            .filter(|k| !["kind", "item"].contains(k))
            .collect();
        if !unknown.is_empty() {
            return Err(format!(
                "[claude.notion.tokens.{name}] に知らないキーがあります: {} (書けるのは kind・item)",
                unknown.join(", ")
            ));
        }
        let kind = match e.get("kind") {
            None => {
                return Err(format!(
                    "[claude.notion.tokens.{name}] の kind を書いてください (\"integration\" か \"personal\")"
                ));
            }
            Some(toml::Value::String(s)) if s == "integration" => TokenKind::Integration,
            Some(toml::Value::String(s)) if s == "personal" => TokenKind::Personal,
            Some(_) => {
                return Err(format!(
                    "[claude.notion.tokens.{name}] の kind は \"integration\" か \"personal\" で書いてください (書いた字は出しません)"
                ));
            }
        };
        let item = match e.get("item") {
            None => None,
            Some(toml::Value::String(s)) if item_ref_ok(s) => Some(s.clone()),
            Some(_) => {
                return Err(format!(
                    "[claude.notion.tokens.{name}] の item が、欄まで書いた 1Password の参照 (op://<vault の ID>/<項目の ID>/<欄の ID>。セクションがあれば op://<vault>/<項目>/<セクション>/<欄>) の形ではありません (書いた字は出しません)。pjp-op-ref が出す ID の形の参照を書くか、分かるまで item を書かないでください。token の値そのものを書いたのなら、その行を消して、token を作り直してください (commit した値は履歴に残ります)"
                ));
            }
        };
        out.insert(name.clone(), NotionToken { kind, item });
    }
    Ok(out)
}

/// `groups.json` の中身 (グループごとの道具の switch の既定・runner の止める条件・skill の依存)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Groups {
    pub default: String,
    groups: BTreeMap<String, BTreeMap<String, bool>>,
    /// runner の止める条件 (道具 → 要る道具の並び。`nix/lib/groups.nix` の runnerDeps)。on の道具の要る道具が off なら、ホストの値を読むときに止める
    requires: BTreeMap<String, Vec<String>>,
    /// 同じ組のわけ (道具 → 要る道具 → わけ)。止める文に添える (無い組は添えない)
    requires_why: BTreeMap<String, BTreeMap<String, String>>,
    /// skill の依存 (skill → Windows で要る道具の並び。`nix/lib/groups.nix` の skills の windows)
    skills: BTreeMap<String, Vec<String>>,
}

/// 文字列の配列を読む (要る道具の並び・skill の依存)
fn string_list(v: &serde_json::Value) -> Option<Vec<String>> {
    v.as_array()?
        .iter()
        .map(|x| x.as_str().map(str::to_string))
        .collect()
}

impl Groups {
    /// build に埋めた `win/runner/groups.json`。
    pub fn embedded() -> Result<Self, String> {
        Self::parse(include_str!("../groups.json"))
    }

    pub fn parse(text: &str) -> Result<Self, String> {
        let bad = |what: &str| {
            format!(
                "win/runner/groups.json が読めません ({what})。dotfiles の root で出し直す: nix eval --raw ./nix#lib.windowsGroupsJson > win/runner/groups.json"
            )
        };
        let v: serde_json::Value = serde_json::from_str(text).map_err(|e| bad(&e.to_string()))?;
        if v["version"] != 3 {
            return Err(bad("version が 3 でない"));
        }
        let default = v["default"]
            .as_str()
            .ok_or_else(|| bad("default が無い"))?
            .to_string();
        let mut groups = BTreeMap::new();
        for (name, g) in v["groups"]
            .as_object()
            .ok_or_else(|| bad("groups が無い"))?
        {
            let mut tools = BTreeMap::new();
            for (k, t) in g["tools"]
                .as_object()
                .ok_or_else(|| bad(&format!("{name} の tools が無い")))?
            {
                let b = t
                    .as_bool()
                    .ok_or_else(|| bad(&format!("{name} の tools.{k} が bool でない")))?;
                tools.insert(k.clone(), b);
            }
            groups.insert(name.clone(), tools);
        }
        if !groups.contains_key(&default) {
            return Err(bad("default のグループが groups に無い"));
        }
        let known = |k: &str| groups.values().any(|t| t.contains_key(k));
        let mut requires = BTreeMap::new();
        for (tool, list) in v["requires"]
            .as_object()
            .ok_or_else(|| bad("requires が無い"))?
        {
            let list = string_list(list)
                .ok_or_else(|| bad(&format!("requires.{tool} が文字列の配列でない")))?;
            if let Some(k) = std::iter::once(tool).chain(&list).find(|k| !known(k)) {
                return Err(bad(&format!(
                    "requires.{tool} の道具 {k} が groups の tools に無い"
                )));
            }
            requires.insert(tool.clone(), list);
        }
        let mut requires_why = BTreeMap::new();
        for (tool, whys) in v["requiresWhy"]
            .as_object()
            .ok_or_else(|| bad("requiresWhy が無い"))?
        {
            let mut m = BTreeMap::new();
            for (req, why) in whys
                .as_object()
                .ok_or_else(|| bad(&format!("requiresWhy.{tool} が表でない")))?
            {
                if !requires.get(tool).is_some_and(|l| l.contains(req)) {
                    return Err(bad(&format!(
                        "requiresWhy.{tool}.{req} が requires に無い組"
                    )));
                }
                let why = why
                    .as_str()
                    .ok_or_else(|| bad(&format!("requiresWhy.{tool}.{req} が文字列でない")))?;
                m.insert(req.clone(), why.to_string());
            }
            requires_why.insert(tool.clone(), m);
        }
        let mut skills = BTreeMap::new();
        for (name, s) in v["skills"]
            .as_object()
            .ok_or_else(|| bad("skills が無い"))?
        {
            let list = string_list(&s["windows"])
                .ok_or_else(|| bad(&format!("skills.{name}.windows が文字列の配列でない")))?;
            if let Some(k) = list.iter().find(|k| !known(k)) {
                return Err(bad(&format!(
                    "skills.{name}.windows の道具 {k} が groups の tools に無い"
                )));
            }
            skills.insert(name.clone(), list);
        }
        Ok(Groups {
            default,
            groups,
            requires,
            requires_why,
            skills,
        })
    }

    pub fn names(&self) -> Vec<&str> {
        self.groups.keys().map(String::as_str).collect()
    }

    fn tools(&self, group: &str) -> Option<&BTreeMap<String, bool>> {
        self.groups.get(group)
    }

    fn knows_tool(&self, key: &str) -> bool {
        self.groups.values().any(|t| t.contains_key(key))
    }
}

/// ホストの値をどこから読んだか。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    /// このファイルを読んだ
    File(PathBuf),
    /// 手元の host.toml (`used`。値はここから読んだ) と dotfiles-private のファイル (`other`) の両方がある。どちらを使うか決まらないので、
    /// check は ⚠ を出し、apply は止める
    Both { used: PathBuf, other: PathBuf },
    /// どのファイルも無い (グループの既定で確かめる)。見た場所を引く順に並べる (`--host-file` なら 1 つ)
    Missing(Vec<PathBuf>),
}

/// ホストの値 (グループの既定と上書きを合わせたもの)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostValues {
    pub group: String,
    pub overrides: BTreeMap<String, bool>,
    pub runner_enable: bool,
    /// op-reason の SSH の中継のモード (`[opReason] sshRelayMode`。`SSH_RELAY_MODES` のどれか。書かなければ per-call)。
    /// 効くかは `ssh_relay` で引く
    ssh_relay_mode: String,
    /// sshd に入れる公開鍵 (`[sshd] authorizedKeys`。1 つが authorized_keys の 1 行)。None は書いていない (dotfiles は鍵を置かない。Nix の
    /// null と同じ)、空の Vec は鍵 0 本。使うのは受け持ちが runner のホストの手順 sshd だけ (`steps::sshd_keys`)
    pub sshd_keys: Option<Vec<String>>,
    /// sshd_config の AllowUsers に書くユーザー (`[sshd] allowUsers`)。None は書いていない (Install-Sshd.ps1 の既定: 流したユーザー)、空の Vec は
    /// 誰も入れない。使うのは受け持ちが runner のホストの手順 sshd だけ (`steps::sshd_allow`)
    pub sshd_allow_users: Option<Vec<String>>,
    /// 入ってよい送り元 (`[sshd] allowFrom`。sshd_config の Match Address に書く IPv4・IPv6 のアドレスか CIDR)。None は書いていない
    /// (Install-Sshd.ps1 の既定: tailnet と localhost)、空の Vec はどこからも入れない。使うのは `allow_users` と同じ
    pub sshd_allow_from: Option<Vec<String>>,
    /// T3 Code の Claude に `CLAUDE_CODE_ENTRYPOINT=""` を渡すか (`[t3Code] clearClaudeEntrypoint`。書かなければ false)。クレジットを使う間
    /// だけの手当て (dotfiles-private の docs/adr/091_t3_code_opt_in_*)。Linux の `dotfiles.t3Code.clearClaudeEntrypoint` と同じ
    pub t3_clear_claude_entrypoint: bool,
    /// Notion へ書く skill の宛先 (`[claude.notion]`)
    pub notion: NotionValues,
    /// claude の setup-token の token の置き場の宣言 (`[claude.tokens]`。アカウントの名前 → 宣言。値 (token) は持たない)
    pub claude_tokens: BTreeMap<String, ClaudeToken>,
    pub source: Source,
    groups: Groups,
}

impl HostValues {
    /// ファイルが無いときの値 (グループの既定・受け持ちは WSL・Notion の宛先は選んでいない)。
    pub fn missing(path: &Path, groups: Groups) -> Self {
        Self::missing_at(vec![path.to_path_buf()], groups)
    }

    /// どのファイルも無いときの値 (`missing` と同じ。見た場所を引く順に並べる)。
    pub fn missing_at(paths: Vec<PathBuf>, groups: Groups) -> Self {
        HostValues {
            group: groups.default.clone(),
            overrides: BTreeMap::new(),
            runner_enable: false,
            ssh_relay_mode: SSH_RELAY_MODES[0].to_string(),
            sshd_keys: None,
            sshd_allow_users: None,
            sshd_allow_from: None,
            t3_clear_claude_entrypoint: false,
            notion: NotionValues::default(),
            claude_tokens: BTreeMap::new(),
            source: Source::Missing(paths),
            groups,
        }
    }

    /// 道具の switch の値 (上書き → グループの既定 → false)。
    pub fn tool(&self, key: &str) -> bool {
        if let Some(b) = self.overrides.get(key) {
            return *b;
        }
        self.groups
            .tools(&self.group)
            .and_then(|t| t.get(key))
            .copied()
            .unwrap_or(false)
    }

    /// op-reason の SSH の中継 (道具の switch `opReasonSshRelay` と `[opReason] sshRelayMode`)。on ならモード (`per-call`・`show-only`)、
    /// off なら None。1Password (`onePassword`) が off なら効かない (Nix の groups.nix の requires と同じ。op-reason の手順も走らない)
    pub fn ssh_relay(&self) -> Option<&str> {
        (self.tool("onePassword") && self.tool("opReasonSshRelay"))
            .then_some(self.ssh_relay_mode.as_str())
    }

    /// skill name を Claude Code の一覧に出すか (`groups.json` の skills の windows の道具が全部 on。表に無い skill はいつも出す)
    pub fn skill_on(&self, name: &str) -> bool {
        self.groups
            .skills
            .get(name)
            .is_none_or(|tools| tools.iter().all(|k| self.tool(k)))
    }

    /// skill の依存の表 (`groups.json` の skills) にある skill の名前 (名前の順)
    pub fn table_skills(&self) -> Vec<&str> {
        self.groups.skills.keys().map(String::as_str).collect()
    }

    /// skill name が Windows で要る道具のうち、このホストで off のもの (表の並び。表に無い skill・全部 on なら空)
    pub fn skill_off_tools(&self, name: &str) -> Vec<&str> {
        self.groups
            .skills
            .get(name)
            .into_iter()
            .flatten()
            .filter(|k| !self.tool(k))
            .map(String::as_str)
            .collect()
    }

    /// 道具の switch の値がどこで決まったか (一覧と off の行に添える)。
    pub fn tool_origin(&self, key: &str) -> String {
        if self.overrides.contains_key(key) {
            "ホストの値".to_string()
        } else {
            format!("グループ {} の既定", self.group)
        }
    }
}

/// やめた設定グループの名前 (dotfiles-private の ADR 057 の 3 つ)。書いたホストは、書き直し方を案内して止める (ADR 109)
const REMOVED_GROUPS: [&str; 3] = ["personal", "company", "client"];

/// 道具の switch `privateRepos` (pollenjp の private な repo (dotfiles-private・claude-skills) と gh のログインを使うホストか)。Nix の option を
/// 持たない runner だけの道具 (`nix/lib/groups.nix` の runnerOnlyTools)。off なら ssh-config・port-forward・pin-updates と google-ime の辞書は
/// 流さず、手順 bootstrap は `-Private` を付けずに確かめる (ADR 111)
pub const PRIVATE_REPOS: &str = "privateRepos";

/// on の道具の要る道具 (`groups.json` の requires) が off なら、その誤りの文 (要る道具ごとに 1 つ。要る道具の名前の順。無ければ空)。黙って手順を
/// 飛ばさず、ホストの値を読むときに止める。privateRepos の文は bootstrap の `-Private` を案内する
fn requires_errors(h: &HostValues) -> Vec<String> {
    let mut by_req: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    for (tool, reqs) in &h.groups.requires {
        if !h.tool(tool) {
            continue;
        }
        for req in reqs.iter().filter(|r| !h.tool(r)) {
            let shown = match h.groups.requires_why.get(tool).and_then(|w| w.get(req)) {
                Some(why) => format!("{tool} ({why})"),
                None => tool.clone(),
            };
            by_req.entry(req.as_str()).or_default().push(shown);
        }
    }
    by_req
        .into_iter()
        .map(|(req, on)| {
            let origin = h.tool_origin(req);
            let on = on.join("・");
            if req == PRIVATE_REPOS {
                format!(
                    "[tools] {PRIVATE_REPOS} が off ({origin}) なのに、private な repo を要る道具が on です: {on}。gh にログインして private な repo を取る PC なら [tools] に {PRIVATE_REPOS} = true を書き (bootstrap は -Private で流す)、取らない PC なら、その道具を false にしてください (dotfiles の win/README.md の「ホストの値」)"
                )
            } else {
                format!(
                    "[tools] {req} が off ({origin}) なのに、それを要る道具が on です: {on}。[tools] に {req} = true を書くか、その道具を false にしてください (dotfiles の win/README.md の「ホストの値」)"
                )
            }
        })
        .collect()
}

/// op-reason の SSH の中継のモード (`op-reason.exe --ssh-agent --mode` の値。先頭が書かなかったときの既定)
pub const SSH_RELAY_MODES: [&str; 2] = ["per-call", "show-only"];

/// `[opReason]` を読む (中継のモード)。書けるのは sshRelayMode だけ
fn parse_op_reason(v: &toml::Value) -> Result<String, String> {
    let toml::Value::Table(t) = v else {
        return Err("opReason は [opReason] の表で書いてください".to_string());
    };
    let unknown: Vec<&str> = t
        .keys()
        .map(String::as_str)
        .filter(|k| *k != "sshRelayMode")
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "[opReason] に知らないキーがあります: {} (書けるのは sshRelayMode だけ)",
            unknown.join(", ")
        ));
    }
    match t.get("sshRelayMode") {
        None => Ok(SSH_RELAY_MODES[0].to_string()),
        Some(toml::Value::String(m)) if SSH_RELAY_MODES.contains(&m.as_str()) => Ok(m.clone()),
        Some(other) => {
            let shown = match other {
                toml::Value::String(s) => s.clone(),
                other => format!("{other:?}"),
            };
            Err(format!(
                "[opReason] の sshRelayMode は {} で書いてください: {shown}",
                SSH_RELAY_MODES.join(" か ")
            ))
        }
    }
}

/// authorized_keys の鍵の種類 (win/openssh/Install-Sshd.ps1 の `$script:KeyTypePattern` と同じ)
pub const SSH_KEY_TYPES: [&str; 7] = [
    "ssh-ed25519",
    "ssh-rsa",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com",
    "sk-ecdsa-sha2-nistp256@openssh.com",
];

/// authorized_keys の 1 行として読めるか (Install-Sshd.ps1 の `Test-AuthorizedKeyLine` と、コメントの行として読み飛ばされない
/// こと)。改行を含まず、`#` で始まらず、鍵の種類と base64 (16 字以上と `=` 3 つまで) が空白を挟んで並ぶ。前にオプション (`from="…"`
/// など) が付いてよい
pub fn authorized_key_line_ok(line: &str) -> bool {
    if line.contains(['\r', '\n']) || line.trim_start().starts_with('#') {
        return false;
    }
    let base64_ok = |t: &str| {
        let body = t.trim_end_matches('=');
        t.len() - body.len() <= 3
            && body.len() >= 16
            && body
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
    };
    let tokens: Vec<&str> = line.split_whitespace().collect();
    tokens
        .windows(2)
        .any(|w| SSH_KEY_TYPES.contains(&w[0]) && base64_ok(w[1]))
}

/// sshd_config の AllowUsers に書けるユーザー名か (Install-Sshd.ps1 の `Test-SshdUserName` と同じ見方): 英小文字・数字で始まり、英小文字・
/// 数字・`.` `_` `-` だけ。空白・パターンの字 (`*` `?` `!` `,`)・`@`・`"`・`/` を含む名前は sshd_config の 1 語に書けない (Windows の sshd は
/// ログインの名前を小文字にして比べるので、大文字は小文字にして書く)
pub fn sshd_user_ok(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && chars
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-'))
}

/// sshd_config の Match Address に書ける送り元か (Install-Sshd.ps1 の `Test-SshdFromAddress` と同じ見方)。IPv4・IPv6 のアドレスか CIDR
/// (`<アドレス>/<長さ>`) だけ。IPv4 は 10 進の 4 つの組 (頭に 0 を付けない)、長さは IPv4 で 0〜32・IPv6 で 0〜128 (頭に 0 を付けない)、
/// CIDR のアドレスは範囲の頭 (長さより後ろのビットが 0)。sshd は長さの誤りと後ろのビットが立った CIDR を Match Address の書き方の誤りとして
/// 断り、起動しなくなる (OpenSSH の addr.c の `addr_pton_cidr`)。`!` `*` `,` と空白・ゾーン (`%`) は書けない (sshd のパターン・否定・区切りに
/// しない)。誤りなら、そのわけ
pub fn sshd_from_check(s: &str) -> Result<(), &'static str> {
    const NOT_AN_ADDRESS: &str =
        "IPv4・IPv6 のアドレスか CIDR として読めない (! * , と空白・% は書けない。名前も書けない)";
    let (addr, len) = match s.split_once('/') {
        Some((a, l)) => (a, Some(l)),
        None => (s, None),
    };
    // 字の形 (Install-Sshd.ps1 の正規表現と同じ): 16 進の字・: と . だけ
    if addr.is_empty()
        || !addr
            .bytes()
            .all(|b| b.is_ascii_hexdigit() || b == b':' || b == b'.')
    {
        return Err(NOT_AN_ADDRESS);
    }
    // std の Ipv4Addr は頭に 0 の付いた組を断る (8 進と読み違えない)。Ipv6Addr は % (ゾーン) を断る
    let (bits, value): (u32, u128) = if let Ok(v4) = addr.parse::<std::net::Ipv4Addr>() {
        (32, u128::from(u32::from(v4)))
    } else if addr.contains(':')
        && let Ok(v6) = addr.parse::<std::net::Ipv6Addr>()
    {
        (128, u128::from(v6))
    } else {
        return Err(NOT_AN_ADDRESS);
    };
    let Some(len) = len else {
        return Ok(());
    };
    let digits_ok = !len.is_empty()
        && len.len() <= 3
        && len.bytes().all(|b| b.is_ascii_digit())
        && (len == "0" || !len.starts_with('0'));
    let Some(len) = digits_ok.then(|| len.parse::<u32>().ok()).flatten() else {
        return Err("CIDR の長さは、頭に 0 を付けない 10 進の数で書く");
    };
    if len > bits {
        return Err(if bits == 32 {
            "CIDR の長さは IPv4 で 0〜32"
        } else {
            "CIDR の長さは IPv6 で 0〜128"
        });
    }
    let host_bits = bits - len;
    let mask = if host_bits >= 128 {
        u128::MAX
    } else {
        (1u128 << host_bits) - 1
    };
    if value & mask != 0 {
        return Err(
            "CIDR のアドレスに、長さより後ろのビットが立っている (範囲の頭のアドレスで書く。sshd が起動しなくなる)",
        );
    }
    Ok(())
}

/// `[sshd]` の値 (公開鍵・AllowUsers のユーザー・入ってよい送り元)。どれも書かなければ None
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct SshdValues {
    keys: Option<Vec<String>>,
    allow_users: Option<Vec<String>>,
    allow_from: Option<Vec<String>>,
}

/// `[sshd]` の文字列の配列の欄を読む。書かなければ None。`check` は 1 つの値の検め (誤りなら、そのわけ)、`empty` は配列の形の誤りに添える
/// 0 のときの書き方
fn parse_sshd_list(
    t: &toml::Table,
    key: &str,
    empty: &str,
    check: impl Fn(&str) -> Result<(), String>,
) -> Result<Option<Vec<String>>, String> {
    let Some(v) = t.get(key) else {
        return Ok(None);
    };
    let toml::Value::Array(items) = v else {
        return Err(format!(
            "[sshd] の {key} は文字列の配列で書いてください ({empty})"
        ));
    };
    let mut out = Vec::new();
    for (i, item) in items.iter().enumerate() {
        let toml::Value::String(s) = item else {
            return Err(format!(
                "[sshd] の {key} の {} 番目が文字列ではありません",
                i + 1
            ));
        };
        check(s).map_err(|why| format!("[sshd] の {key} の {} 番目: {why}", i + 1))?;
        out.push(s.clone());
    }
    Ok(Some(out))
}

/// `[sshd] authorizedKeys` を読む (公開鍵)。書かなければ None
fn parse_sshd_keys(t: &toml::Table) -> Result<Option<Vec<String>>, String> {
    let Some(keys) = t.get("authorizedKeys") else {
        return Ok(None);
    };
    let toml::Value::Array(items) = keys else {
        return Err(
            "[sshd] の authorizedKeys は文字列の配列で書いてください (鍵 0 本なら [])".to_string(),
        );
    };
    let mut out = Vec::new();
    for (i, item) in items.iter().enumerate() {
        let toml::Value::String(line) = item else {
            return Err(format!(
                "[sshd] の authorizedKeys の {} 番目が文字列ではありません",
                i + 1
            ));
        };
        if line.contains(['\r', '\n']) {
            return Err(format!(
                "[sshd] の authorizedKeys の {} 番目が改行を含みます (1 つの文字列が authorized_keys の 1 行。鍵ごとに分けて書く)",
                i + 1
            ));
        }
        if !authorized_key_line_ok(line) {
            return Err(format!(
                "[sshd] の authorizedKeys の {} 番目を authorized_keys の行として読めません (鍵の種類と base64 が要る。# で始めない): {}",
                i + 1,
                shorten(line)
            ));
        }
        out.push(line.clone());
    }
    Ok(Some(out))
}

/// `[sshd]` を読む (公開鍵・AllowUsers のユーザー・入ってよい送り元)。書けるのは authorizedKeys・allowUsers・allowFrom だけ。書かなければ None
fn parse_sshd(v: &toml::Value) -> Result<SshdValues, String> {
    let toml::Value::Table(t) = v else {
        return Err("sshd は [sshd] の表で書いてください".to_string());
    };
    let unknown: Vec<&str> = t
        .keys()
        .map(String::as_str)
        .filter(|k| !["authorizedKeys", "allowUsers", "allowFrom"].contains(k))
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "[sshd] に知らないキーがあります: {} (書けるのは authorizedKeys・allowUsers・allowFrom)",
            unknown.join(", ")
        ));
    }
    let keys = parse_sshd_keys(t)?;
    let allow_users = parse_sshd_list(t, "allowUsers", "誰も入れないなら []", |name| {
        if sshd_user_ok(name) {
            Ok(())
        } else {
            Err(format!(
                "英小文字・数字で始まり英小文字・数字・. _ - だけの Windows のユーザー名で書いてください (Windows の sshd はログインの名前を小文字にして比べる): {}",
                shorten_escaped(name)
            ))
        }
    })?;
    let allow_from = parse_sshd_list(
        t,
        "allowFrom",
        "どこからも入れないなら []",
        |addr| sshd_from_check(addr).map_err(|why| format!("{why}: {}", shorten_escaped(addr))),
    )?;
    Ok(SshdValues {
        keys,
        allow_users,
        allow_from,
    })
}

/// 誤りの文に添える値で、改行などの制御文字を `\n` の字にしてから 40 字で切る (値の改行で誤りの文が割れないように)
fn shorten_escaped(s: &str) -> String {
    shorten(&s.escape_debug().to_string())
}

/// 誤りの文に添える値 (長ければ 40 字で切る)
fn shorten(s: &str) -> String {
    let mut it = s.chars();
    let head: String = it.by_ref().take(40).collect();
    if it.next().is_some() {
        format!("{head}…")
    } else {
        head
    }
}

/// `[t3Code]` を読む (Claude の CLAUDE_CODE_ENTRYPOINT を空にするか)。書けるのは clearClaudeEntrypoint だけ
fn parse_t3_code(v: &toml::Value) -> Result<bool, String> {
    let toml::Value::Table(t) = v else {
        return Err("t3Code は [t3Code] の表で書いてください".to_string());
    };
    let unknown: Vec<&str> = t
        .keys()
        .map(String::as_str)
        .filter(|k| *k != "clearClaudeEntrypoint")
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "[t3Code] に知らないキーがあります: {} (書けるのは clearClaudeEntrypoint だけ)",
            unknown.join(", ")
        ));
    }
    match t.get("clearClaudeEntrypoint") {
        None => Ok(false),
        Some(v) => v.as_bool().ok_or_else(|| {
            "[t3Code] の clearClaudeEntrypoint は true か false で書いてください".to_string()
        }),
    }
}

/// ホストの値の既定の置き場所: dotfiles-private の clone の `win/hosts/<user>@<pc>.toml`。dotfiles-private は dotfiles の clone の隣、
/// 無ければ bootstrap の置き場 (`%USERPROFILE%\ghq\github.com\pollenjp\dotfiles-private`) で探す (`context::clone_dir`)。
pub fn default_path(repo: &Path, user_profile: Option<&Path>, user: &str, pc: &str) -> PathBuf {
    crate::context::clone_dir(repo, user_profile, "dotfiles-private")
        .join("win")
        .join("hosts")
        .join(format!("{user}@{pc}.toml"))
}

/// 手元のホストの値の置き場所: `%USERPROFILE%\.config\dotfiles\host.toml` (gh にログインできない PC で、bootstrap が雛形
/// `win/templates/host.minimum.toml` を写す所)。
pub fn local_path(user_profile: &Path) -> PathBuf {
    crate::context::join_segments(user_profile, ".config/dotfiles/host.toml")
}

/// `--host-file` が無いときのホストの値: 手元 (`local`) → dotfiles-private (`private`) の順に引く。両方あれば手元のものを読み、
/// `Source::Both` にする (check は ⚠、apply は止める)。どちらも無ければ `Source::Missing` に 2 つの場所を並べる。
pub fn resolve(local: &Path, private: &Path, groups: Groups) -> Result<HostValues, String> {
    match (local.exists(), private.exists()) {
        (true, true) => {
            let mut h = load(local, groups)?;
            h.source = Source::Both {
                used: local.to_path_buf(),
                other: private.to_path_buf(),
            };
            Ok(h)
        }
        (true, false) => load(local, groups),
        (false, true) => load(private, groups),
        (false, false) => Ok(HostValues::missing_at(
            vec![local.to_path_buf(), private.to_path_buf()],
            groups,
        )),
    }
}

/// ホストの値を読む。ファイルが無ければ `Source::Missing` の値 (誤りではない)。読めない・誤りがあれば文を返す。
pub fn load(path: &Path, groups: Groups) -> Result<HostValues, String> {
    match std::fs::read_to_string(path) {
        Ok(text) => parse(&text, path, groups),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(HostValues::missing(path, groups)),
        Err(e) => Err(format!("{}: 読めません ({e})", path.display())),
    }
}

/// 知らないキーを文に出す形。名前らしいキー (英字で始まり、英数字・`-`・`_` だけで 32 字まで。`sk-` で始まらない) はそのまま並べ、ほかの
/// キー (token の値を貼ってしまったものかもしれない) は字を出さずに数だけを足す (dotfiles-private の docs/adr/123_claude_token_watch_*)
fn shown_keys(keys: &[&str]) -> String {
    let plain = |k: &str| {
        let mut cs = k.chars();
        cs.next().is_some_and(|c| c.is_ascii_alphabetic())
            && cs.all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
            && k.len() <= 32
            && !k.starts_with("sk-")
    };
    let mut shown: Vec<String> = keys
        .iter()
        .filter(|k| plain(k))
        .map(|k| k.to_string())
        .collect();
    let hidden = keys.iter().filter(|k| !plain(k)).count();
    if hidden > 0 {
        shown.push(format!("ほか {hidden} 個 (書いた字は出しません)"));
    }
    shown.join(", ")
}

/// TOML の構文の誤りの文。行と桁と誤りのわけだけを出し、toml の文が添える行の写しは出さない (宣言に token の値を引用符なしで貼ったときに、
/// その行を端末やログへ出さない。dotfiles-private の docs/adr/123_claude_token_watch_*)。わけに、その行の字 (10 字以上のつながり) の写しが
/// 入っていれば、わけも出さない
fn toml_error(text: &str, e: &toml::de::Error) -> String {
    let at = e
        .span()
        .and_then(|span| text.get(..span.start))
        .map(|before| {
            let line = before.matches('\n').count() + 1;
            let col = before.rsplit('\n').next().map_or(0, |l| l.chars().count()) + 1;
            (line, col)
        });
    let line_text = at
        .and_then(|(line, _)| text.split('\n').nth(line - 1))
        .unwrap_or("");
    let message = e.message().trim();
    let copies_line = line_text
        .split(|c: char| c.is_whitespace() || c == '=' || c == '"' || c == '\'')
        .any(|w| w.chars().count() >= 10 && message.contains(w));
    let why = if message.is_empty() || copies_line {
        "書いた字は出しません".to_string()
    } else {
        format!("{}。書いた字は出しません", message.replace('\n', " "))
    };
    match at {
        Some((line, col)) => format!("TOML として読めません ({line} 行目 {col} 桁: {why})"),
        None => format!("TOML として読めません ({why})"),
    }
}

/// ホストの値の文を読む (`load` の中身)。
pub fn parse(text: &str, path: &Path, groups: Groups) -> Result<HostValues, String> {
    let fail = |msg: String| format!("{}: {msg}", path.display());
    let t: toml::Table = text.parse().map_err(|e| fail(toml_error(text, &e)))?;
    let unknown: Vec<&str> = t
        .keys()
        .map(String::as_str)
        .filter(|k| {
            ![
                "group", "tools", "runner", "opReason", "sshd", "t3Code", "claude",
            ]
            .contains(k)
        })
        .collect();
    if !unknown.is_empty() {
        return Err(fail(format!(
            "知らないキーがあります: {} (書けるのは group・[tools]・[runner]・[opReason]・[sshd]・[t3Code]・[claude.notion]・[claude.tokens])",
            shown_keys(&unknown)
        )));
    }
    let group = match t.get("group") {
        None => groups.default.clone(),
        Some(toml::Value::String(g)) if groups.tools(g).is_some() => g.clone(),
        Some(toml::Value::String(g)) if REMOVED_GROUPS.contains(&g.as_str()) => {
            return Err(fail(format!(
                "group = \"{g}\" は、もう使えません。設定グループは {} の 2 つ (道具の集合) になりました (dotfiles-private の ADR 109)。group = \"minimum\" にして、使う道具を [tools] に書いてください (前の {g} と同じ道具にする書き方は dotfiles の win/README.md の「ホストの値」)",
                groups.names().join("・")
            )));
        }
        Some(v) => {
            // toml の Value は display の feature が無いと Display を持たない
            let shown = match v {
                toml::Value::String(s) => s.clone(),
                other => format!("{other:?}"),
            };
            return Err(fail(format!(
                "group は {} のどれかで書いてください: {shown}",
                groups.names().join("・")
            )));
        }
    };
    let mut overrides = BTreeMap::new();
    match t.get("tools") {
        None => {}
        Some(toml::Value::Table(tools)) => {
            for (k, v) in tools {
                if !groups.knows_tool(k) {
                    return Err(fail(format!(
                        "[tools] に知らない道具があります: {k} (書けるのは win/runner/groups.json の tools の名前)"
                    )));
                }
                let Some(b) = v.as_bool() else {
                    return Err(fail(format!(
                        "[tools] の {k} は true か false で書いてください"
                    )));
                };
                overrides.insert(k.clone(), b);
            }
        }
        Some(_) => return Err(fail("tools は [tools] の表で書いてください".to_string())),
    }
    let runner_enable = match t.get("runner") {
        None => false,
        Some(toml::Value::Table(r)) => {
            let unknown: Vec<&str> = r
                .keys()
                .map(String::as_str)
                .filter(|k| *k != "enable")
                .collect();
            if !unknown.is_empty() {
                return Err(fail(format!(
                    "[runner] に知らないキーがあります: {} (書けるのは enable だけ)",
                    unknown.join(", ")
                )));
            }
            match r.get("enable") {
                None => false,
                Some(v) => v.as_bool().ok_or_else(|| {
                    fail("[runner] の enable は true か false で書いてください".to_string())
                })?,
            }
        }
        Some(_) => return Err(fail("runner は [runner] の表で書いてください".to_string())),
    };
    let ssh_relay_mode = match t.get("opReason") {
        None => SSH_RELAY_MODES[0].to_string(),
        Some(v) => parse_op_reason(v).map_err(fail)?,
    };
    let sshd = match t.get("sshd") {
        None => SshdValues::default(),
        Some(v) => parse_sshd(v).map_err(fail)?,
    };
    let t3_clear_claude_entrypoint = match t.get("t3Code") {
        None => false,
        Some(v) => parse_t3_code(v).map_err(fail)?,
    };
    let (notion, claude_tokens) = match t.get("claude") {
        None => (NotionValues::default(), BTreeMap::new()),
        Some(v) => parse_claude(v).map_err(fail)?,
    };
    let h = HostValues {
        group,
        overrides,
        runner_enable,
        ssh_relay_mode,
        sshd_keys: sshd.keys,
        sshd_allow_users: sshd.allow_users,
        sshd_allow_from: sshd.allow_from,
        t3_clear_claude_entrypoint,
        notion,
        claude_tokens,
        source: Source::File(path.to_path_buf()),
        groups,
    };
    let errors = requires_errors(&h);
    if !errors.is_empty() {
        return Err(errors.into_iter().map(fail).collect::<Vec<_>>().join("\n"));
    }
    Ok(h)
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 埋めた groups.json が読め、グループは minimum と all の 2 つ。runner が読む道具は、minimum では全部 off、all では全部 on
    //! - group を書かなければ minimum、上書きはグループの既定より先に効く、runner.enable の既定は false
    //! - 前のグループの名前 (personal・company・client) は、書き直し方 (group = "minimum" と [tools]) を案内して止まる
    //! - 知らないキー・グループ・道具と、bool でない値は誤り。ファイルが無いのは誤りでなく「無い」
    //! - op-reason の SSH の中継 (道具の switch opReasonSshRelay。minimum では既定で off、all では on) は、on なら [opReason] sshRelayMode のモード
    //!   (書かなければ per-call)、off か 1Password (onePassword) が off なら無し。sshRelayMode の知らない値・[opReason] の知らないキーは誤り
    //! - sshd の公開鍵 ([sshd] authorizedKeys) は、書かなければ None (null)、[] は鍵 0 本、list はその行のまま。改行を含む値・
    //!   authorized_keys の行として読めない値 (鍵の種類か base64 が無い・# で始まる)・文字列でない値・[sshd] の知らないキーは誤り
    //! - sshd の AllowUsers のユーザーと入ってよい送り元 ([sshd] allowUsers・allowFrom) も、書かなければ None (null)、[] は 0、list はその値の
    //!   まま。ユーザー名は英小文字・数字・. _ - だけ (Install-Sshd.ps1 の Test-SshdUserName と同じ)。送り元は IPv4・IPv6 のアドレスか CIDR だけ
    //!   (IPv4 の組と CIDR の長さは頭に 0 を付けない・長さは 32 と 128 まで・CIDR のアドレスは範囲の頭。Install-Sshd.ps1 の
    //!   Test-SshdFromAddress と同じ例で確かめる)。! * , と空白・末尾や頭の改行・ゾーン・名前は誤り (誤りの文の値は改行を \n の字にする)。
    //!   配列でない値・文字列でない値は誤り
    //! - Notion の API キーの宣言 ([claude.notion.tokens.<名前>] の kind・item) から、notion-tokens.json の中身 (Linux の nix/lib/notion-tokens.nix の
    //!   stateText と同じ 1 行の JSON。名前の順・キーの順、item は書かなければ null、var は名前を大文字にし - を _ にして頭に PJP_NOTION_TOKEN_)
    //!   を作る。宣言が無くても {"tokens":{}}。表を入れ子に書いても inline table で書いても同じ。claude-notion.json には入れない
    //! - 宣言の誤り (tokens・名前ごとの値が表でない・名前の形・知らないキー・kind が無い・2 つの外・item が欄まで書いた op:// の参照でない・同じ
    //!   変数になる 2 つの名前) は止める。止める文に item と kind の字を出さない (値を書いてしまったときに端末やログへ出ないように)
    //! - claude の token の置き場の宣言 ([claude.tokens.<名前>] の label・item) から、claude-tokens.json の中身 (Linux の nix/lib/claude-tokens.nix
    //!   の stateText と同じ 1 行の JSON。名前の順・キーの順、label は書かなければアカウントの名前、item は書かなければ null) を作る。宣言が無くても
    //!   {"accounts":{}}。inline table で書いても同じ。[claude.notion] と一緒に書いても互いに混ざらない
    //! - その宣言の誤り (tokens・名前ごとの値が表でない・名前の形 (大文字・- で始まる・空白・33 字・sk-ant- で始まる・account・selector)・素の
    //!   claude の default (Windows の素の claude は token を読まない)・知らないキー・label の形・item の形) は止める。止める文に、規則に合わない
    //!   名前・label・item・知らないキーの字を出さない (名前は数だけ)

    use super::*;
    use crate::testutil::TempDir;

    fn groups() -> Groups {
        Groups::embedded().unwrap()
    }

    fn host(text: &str) -> Result<HostValues, String> {
        parse(text, Path::new("h.toml"), groups())
    }

    /// runner が手順の gate で読む道具 (Nix の lib/groups.nix の runnerTools と同じ。最後の privateRepos は runner だけが読む道具)
    const RUNNER_TOOLS: [&str; 18] = [
        "windowsClaudeCode",
        "windowsHerdr",
        "windowsT3Code",
        "claudePrivateSkills",
        "herdrHub",
        "windowsClaudeAccounts",
        "windowsClaudeDesktop",
        "devTracker",
        "onePassword",
        "opReasonSshRelay",
        "windowsNtn",
        "windowsCodex",
        "windowsOpenssh",
        "windowsTailscale",
        "windowsSshd",
        "windowsTypeClipboard",
        "gitIdentity",
        "privateRepos",
    ];

    #[test]
    fn embedded_groups_are_sets() {
        let g = groups();
        assert_eq!(g.default, "minimum");
        assert_eq!(g.names(), vec!["all", "minimum"]);
        let tool =
            |group: &str, key: &str| host(&format!("group = \"{group}\"")).unwrap().tool(key);
        // グループは道具の集合: runner が読む道具は minimum に入らず (使うホストが [tools] に書く)、all には全部入る
        for key in RUNNER_TOOLS {
            assert!(!tool("minimum", key), "{key}");
            assert!(tool("all", key), "{key}");
        }
    }

    #[test]
    fn old_group_names_are_rejected_with_a_guide() {
        for old in ["personal", "company", "client"] {
            let e = host(&format!("group = \"{old}\"\n")).unwrap_err();
            assert!(e.starts_with("h.toml: "), "{e}");
            assert!(
                e.contains(&format!("group = \"{old}\" は、もう使えません")),
                "{e}"
            );
            assert!(
                e.contains("group = \"minimum\" にして、使う道具を [tools] に書いてください"),
                "{e}"
            );
            assert!(e.contains("ADR 109"), "{e}");
        }
    }

    #[test]
    fn t3_code_is_a_known_tool_and_the_entrypoint_value_defaults_to_false() {
        let h = host("[tools]\nwindowsT3Code = true\n[t3Code]\nclearClaudeEntrypoint = true\n")
            .unwrap();
        assert!(h.tool("windowsT3Code"));
        assert_eq!(h.tool_origin("windowsT3Code"), "ホストの値");
        assert!(h.t3_clear_claude_entrypoint);
        let h = host("").unwrap();
        assert!(!h.tool("windowsT3Code"));
        assert!(!h.t3_clear_claude_entrypoint);
        assert!(!HostValues::missing(Path::new("h.toml"), groups()).t3_clear_claude_entrypoint);
        assert!(!host("[t3Code]\n").unwrap().t3_clear_claude_entrypoint);
        let e = host("[t3Code]\nclearClaudeEntrypoint = \"yes\"\n").unwrap_err();
        assert!(e.contains("true か false"), "{e}");
        let e = host("[t3Code]\nentrypoint = true\n").unwrap_err();
        assert!(
            e.contains("[t3Code] に知らないキーがあります: entrypoint"),
            "{e}"
        );
        let e = host("t3Code = true\n").unwrap_err();
        assert!(e.contains("[t3Code] の表"), "{e}");
    }

    #[test]
    fn ssh_relay_follows_the_switch_and_the_mode() {
        // 書かなければ off (モードを書いても、switch が off なら無し)
        assert_eq!(host("").unwrap().ssh_relay(), None);
        assert_eq!(
            host("[opReason]\nsshRelayMode = \"show-only\"\n")
                .unwrap()
                .ssh_relay(),
            None
        );
        // on ならモード。書かなければ per-call (1Password の switch と、中継のファイルを置く ssh-config に要る privateRepos は minimum では既定が
        // off なので、入れるホストが一緒に書く)
        let h = host("[tools]\nonePassword = true\nopReasonSshRelay = true\nprivateRepos = true\n")
            .unwrap();
        assert_eq!(h.ssh_relay(), Some("per-call"));
        assert_eq!(h.tool_origin("opReasonSshRelay"), "ホストの値");
        assert_eq!(
            host("[tools]\nonePassword = true\nopReasonSshRelay = true\nprivateRepos = true\n[opReason]\nsshRelayMode = \"show-only\"\n")
                .unwrap()
                .ssh_relay(),
            Some("show-only")
        );
        assert_eq!(
            host("[tools]\nonePassword = true\nopReasonSshRelay = true\nprivateRepos = true\n[opReason]\nsshRelayMode = \"per-call\"\n")
                .unwrap()
                .ssh_relay(),
            Some("per-call")
        );
        // 1Password が off なら効かない (groups.nix の requires。op-reason の手順も走らない)
        assert_eq!(
            host("[tools]\nopReasonSshRelay = true\nprivateRepos = true\nonePassword = false\n")
                .unwrap()
                .ssh_relay(),
            None
        );
        // ファイルが無いときも off
        assert_eq!(
            HostValues::missing(Path::new("h.toml"), groups()).ssh_relay(),
            None
        );
    }

    #[test]
    fn windows_sshd_is_a_known_tool_that_hosts_turn_on() {
        let h = host("[tools]\nwindowsSshd = true\n").unwrap();
        assert!(h.tool("windowsSshd"));
        assert_eq!(h.tool_origin("windowsSshd"), "ホストの値");
        let h = host("").unwrap();
        assert!(!h.tool("windowsSshd"));
        assert_eq!(h.tool_origin("windowsSshd"), "グループ minimum の既定");
    }

    /// windowsOpenssh (OpenSSH を固定した版に入れ替える) は minimum では off (Windows に初めからある OpenSSH のまま)。使うホストが [tools] に書く
    #[test]
    fn windows_openssh_is_a_known_tool_that_hosts_turn_on() {
        let h = host("[tools]\nwindowsOpenssh = true\n").unwrap();
        assert!(h.tool("windowsOpenssh"));
        assert_eq!(h.tool_origin("windowsOpenssh"), "ホストの値");
        let h = host("").unwrap();
        assert!(!h.tool("windowsOpenssh"));
        assert_eq!(h.tool_origin("windowsOpenssh"), "グループ minimum の既定");
    }

    #[test]
    fn windows_tailscale_is_a_known_tool_that_hosts_turn_on() {
        let h = host("[tools]\nwindowsTailscale = true\n").unwrap();
        assert!(h.tool("windowsTailscale"));
        assert_eq!(h.tool_origin("windowsTailscale"), "ホストの値");
        let h = host("").unwrap();
        assert!(!h.tool("windowsTailscale"));
        assert_eq!(h.tool_origin("windowsTailscale"), "グループ minimum の既定");
    }

    /// privateRepos は runner だけが読む道具 (groups.json の tools にある)。minimum では off、all では on
    #[test]
    fn private_repos_is_off_in_minimum_and_on_in_all() {
        let h = host("").unwrap();
        assert!(!h.tool(PRIVATE_REPOS));
        assert_eq!(h.tool_origin(PRIVATE_REPOS), "グループ minimum の既定");
        assert!(host("group = \"all\"\n").unwrap().tool(PRIVATE_REPOS));
        let h = host("[tools]\nprivateRepos = true\n").unwrap();
        assert!(h.tool(PRIVATE_REPOS));
        assert_eq!(h.tool_origin(PRIVATE_REPOS), "ホストの値");
        assert!(!HostValues::missing(Path::new("h.toml"), groups()).tool(PRIVATE_REPOS));
    }

    /// privateRepos が off なのに、それが要る道具 (groups.json の requires。claudePrivateSkills・opReasonSshRelay) が on なら、どの道具がなぜ要るかを
    /// 出して止める。文は前の版 (要る道具を手で並べていた版) と同じ
    #[test]
    fn tools_needing_private_repos_stop_without_it() {
        for (key, why) in [
            ("claudePrivateSkills", "claude-skills の clone を読む"),
            (
                "opReasonSshRelay",
                "中継のファイルを置く手順 ssh-config が dotfiles-private の ssh/ を読む",
            ),
        ] {
            let e = host(&format!("[tools]\n{key} = true\n")).unwrap_err();
            assert_eq!(
                e,
                format!(
                    "h.toml: [tools] privateRepos が off (グループ minimum の既定) なのに、private な repo を要る道具が on です: {key} ({why})。gh にログインして private な repo を取る PC なら [tools] に privateRepos = true を書き (bootstrap は -Private で流す)、取らない PC なら、その道具を false にしてください (dotfiles の win/README.md の「ホストの値」)"
                )
            );
            let h = host(&format!("[tools]\n{key} = true\nprivateRepos = true\n")).unwrap();
            assert!(h.tool(key));
        }
        // all に privateRepos = false だけを書くと、要る道具の既定 (on) が並ぶ (名前の順)
        let e = host("group = \"all\"\n[tools]\nprivateRepos = false\n").unwrap_err();
        assert!(
            e.contains("[tools] privateRepos が off (ホストの値) なのに"),
            "{e}"
        );
        assert!(
            e.contains("claudePrivateSkills (claude-skills の clone を読む)・opReasonSshRelay ("),
            "{e}"
        );
        let h = host(
            "group = \"all\"\n[tools]\nprivateRepos = false\nclaudePrivateSkills = false\nopReasonSshRelay = false\n",
        )
        .unwrap();
        assert!(!h.tool(PRIVATE_REPOS));
        // 要らない道具 (devTracker・集約ハブなど) は privateRepos が off でも on にできる
        assert!(host("[tools]\ndevTracker = true\nwindowsClaudeCode = true\n").is_ok());
        assert!(
            host("[tools]\nwindowsClaudeCode = true\nwindowsHerdr = true\nherdrHub = true\n")
                .is_ok()
        );
    }

    /// 集約ハブ (herdrHub) は privateRepos が要らず、windowsClaudeCode と windowsHerdr が要る (groups.json の requires。dotfiles-private の
    /// ADR 124)。要る道具が off なら、要る道具ごとに 1 行ずつ、どの道具がなぜ要るかと直し方を出して止める
    #[test]
    fn hub_needs_claude_code_and_herdr() {
        // minimum に 3 つを足したホスト (privateRepos は既定の off) は通る
        let h = host("[tools]\nwindowsClaudeCode = true\nwindowsHerdr = true\nherdrHub = true\n")
            .unwrap();
        assert!(h.tool("herdrHub"));
        assert!(!h.tool(PRIVATE_REPOS));
        let e = host("[tools]\nwindowsClaudeCode = true\nherdrHub = true\n").unwrap_err();
        assert_eq!(
            e,
            "h.toml: [tools] windowsHerdr が off (グループ minimum の既定) なのに、それを要る道具が on です: herdrHub (mod pjp-spaces と hc を入れる herdr-app)。[tools] に windowsHerdr = true を書くか、その道具を false にしてください (dotfiles の win/README.md の「ホストの値」)"
        );
        // 2 つとも off なら 2 行 (要る道具の名前の順)。どちらの行もファイルの名前で始まる
        let e = host("[tools]\nherdrHub = true\n").unwrap_err();
        let lines: Vec<&str> = e.lines().collect();
        assert_eq!(lines.len(), 2, "{e}");
        assert!(
            lines[0].starts_with("h.toml: [tools] windowsClaudeCode が off (グループ minimum の既定) なのに、それを要る道具が on です: herdrHub (ハブの会話の Claude Code と、土台の skill を置く手順 claude-files)。"),
            "{e}"
        );
        assert!(
            lines[1].starts_with("h.toml: [tools] windowsHerdr が off"),
            "{e}"
        );
        // all は通り、all で windowsHerdr だけを外すと止まる
        assert!(host("group = \"all\"\n").is_ok());
        let e = host("group = \"all\"\n[tools]\nwindowsHerdr = false\n").unwrap_err();
        assert!(
            e.starts_with("h.toml: [tools] windowsHerdr が off (ホストの値) なのに、それを要る道具が on です: herdrHub ("),
            "{e}"
        );
        assert!(host("group = \"all\"\n[tools]\nwindowsHerdr = false\nherdrHub = false\n").is_ok());
    }

    /// 埋めた groups.json の skill の依存 (skills の windows): 表の skill は要る道具が全部 on のときだけ出し、表に無い skill はいつも出す
    #[test]
    fn skill_on_follows_the_table() {
        let minimum = host("").unwrap();
        let hub = host("[tools]\nwindowsClaudeCode = true\nwindowsHerdr = true\nherdrHub = true\n")
            .unwrap();
        for name in [
            "pjp-hc-hub",
            "pjp-hc-child",
            "pjp-hc-hub-panel",
            "pjp-pack-hc",
        ] {
            assert!(!minimum.skill_on(name), "{name}");
            assert!(hub.skill_on(name), "{name}");
        }
        assert!(minimum.skill_on("pjp-nix-flake"));
        assert!(host("group = \"all\"\n").unwrap().skill_on("pjp-hc-hub"));
    }

    /// skill の依存の表の skill の名前と、このホストで off の要る道具 (claude-files が表の skill を張り分けるときに読む)
    #[test]
    fn skill_table_and_off_tools() {
        let minimum = host("").unwrap();
        assert_eq!(
            minimum.table_skills(),
            vec![
                "pjp-hc-child",
                "pjp-hc-hub",
                "pjp-hc-hub-panel",
                "pjp-pack-hc"
            ]
        );
        assert_eq!(minimum.skill_off_tools("pjp-hc-hub"), vec!["herdrHub"]);
        assert!(
            minimum.skill_off_tools("pjp-nix-flake").is_empty(),
            "表に無い"
        );
        let hub = host("[tools]\nwindowsClaudeCode = true\nwindowsHerdr = true\nherdrHub = true\n")
            .unwrap();
        assert!(hub.skill_off_tools("pjp-hc-hub").is_empty());
    }

    /// --host-file が無いときは、手元の host.toml → dotfiles-private の順に引く。両方あれば手元を読んで Both、どちらも無ければ 2 つの場所を並べる
    #[test]
    fn resolve_reads_local_then_private() {
        let t = TempDir::new("host-resolve");
        let local = local_path(&t.path().join("home"));
        assert_eq!(
            local,
            t.path()
                .join("home")
                .join(".config")
                .join("dotfiles")
                .join("host.toml")
        );
        let private = t.path().join("private").join("alice@example-host.toml");
        let h = resolve(&local, &private, groups()).unwrap();
        assert_eq!(
            h.source,
            Source::Missing(vec![local.clone(), private.clone()])
        );
        assert_eq!(h.group, "minimum");

        t.write("private/alice@example-host.toml", "group = \"all\"\n");
        let h = resolve(&local, &private, groups()).unwrap();
        assert_eq!(h.source, Source::File(private.clone()));
        assert_eq!(h.group, "all");

        t.write(
            "home/.config/dotfiles/host.toml",
            "[runner]\nenable = true\n",
        );
        let h = resolve(&local, &private, groups()).unwrap();
        assert_eq!(
            h.source,
            Source::Both {
                used: local.clone(),
                other: private.clone()
            }
        );
        // 値は引く順の先 (手元) のもの
        assert_eq!(h.group, "minimum");
        assert!(h.runner_enable);

        std::fs::remove_file(&private).unwrap();
        let h = resolve(&local, &private, groups()).unwrap();
        assert_eq!(h.source, Source::File(local.clone()));
        // 手元のファイルの誤りは、ほかのホストの値の誤りと同じく止める
        t.write(
            "home/.config/dotfiles/host.toml",
            "[tools]\nclaudePrivateSkills = true\n",
        );
        let e = resolve(&local, &private, groups()).unwrap_err();
        assert!(e.contains("host.toml: [tools] privateRepos が off"), "{e}");
    }

    /// 雛形 (win/templates/host.minimum.toml。bootstrap が手元の host.toml に写す) は minimum で道具を足さず、受け持ちは runner
    #[test]
    fn template_is_minimum_with_runner_enabled() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("templates")
            .join("host.minimum.toml");
        let h = load(&path, groups()).unwrap();
        assert_eq!(h.source, Source::File(path.clone()));
        assert_eq!(h.group, "minimum");
        assert!(h.overrides.is_empty());
        assert!(h.runner_enable);
        assert!(!h.tool(PRIVATE_REPOS));
        assert_eq!(h.sshd_keys, None);
        assert_eq!(h.notion, NotionValues::default());
    }

    #[test]
    fn defaults_and_overrides() {
        let h = host("").unwrap();
        assert_eq!(h.group, "minimum");
        assert!(!h.runner_enable);
        assert_eq!(h.source, Source::File(PathBuf::from("h.toml")));
        assert_eq!(h.tool_origin("windowsNtn"), "グループ minimum の既定");

        let h = host("group = \"minimum\"\n[tools]\nwindowsNtn = true\nwindowsTypeClipboard = true\n[runner]\nenable = true\n").unwrap();
        assert!(h.tool("windowsNtn"));
        assert!(h.tool("windowsTypeClipboard"));
        assert!(!h.tool("windowsClaudeCode"));
        assert!(h.runner_enable);
        assert_eq!(h.tool_origin("windowsNtn"), "ホストの値");
        assert!(!h.tool("no-such-tool"));
    }

    /// [claude.notion] から ~/.local/state/dotfiles/claude-notion.json の中身 (Linux の home/modules/claude.nix と同じ 1 行の JSON) を作る
    #[test]
    fn notion_values() {
        assert_eq!(
            host("").unwrap().notion.json(),
            "{\"override\":{},\"profile\":null,\"routes\":{}}\n"
        );
        assert_eq!(
            HostValues::missing(Path::new("h.toml"), groups())
                .notion
                .json(),
            "{\"override\":{},\"profile\":null,\"routes\":{}}\n"
        );
        let h = host(
            "[claude.notion]\nprofile = \"personal\"\nroutes = { \"pollenjp/x\" = \"work\", \"a/*\" = \"personal\" }\n\n[claude.notion.override.personal]\nscanData = \"u\"\ndevTracker = { linkFromRepo = false }\nn = [1, 2.5, true]\n",
        )
        .unwrap();
        assert_eq!(h.notion.profile.as_deref(), Some("personal"));
        assert_eq!(
            h.notion.json(),
            "{\"override\":{\"personal\":{\"devTracker\":{\"linkFromRepo\":false},\"n\":[1,2.5,true],\"scanData\":\"u\"}},\"profile\":\"personal\",\"routes\":{\"a/*\":\"personal\",\"pollenjp/x\":\"work\"}}\n"
        );
    }

    #[test]
    fn rejects_notion_mistakes() {
        for (text, want) in [
            (
                "claude = 1",
                "claude は [claude.notion]・[claude.tokens] の表で書いてください",
            ),
            ("[claude]\nx = 1", "[claude] に知らないキーがあります: x"),
            (
                "[claude.notion]\nprofil = \"a\"",
                "[claude.notion] に知らないキーがあります: profil",
            ),
            (
                "[claude.notion]\nprofile = \"Personal\"",
                "[claude.notion] の profile は",
            ),
            (
                "[claude.notion]\nprofile = 1",
                "[claude.notion] の profile は",
            ),
            (
                "[claude.notion]\nprofile = \"\"",
                "[claude.notion] の profile は",
            ),
            (
                "[claude.notion]\nroutes = { a = 1 }",
                "[claude.notion] の routes の a は文字列",
            ),
            (
                "[claude.notion]\nroutes = 1",
                "[claude.notion] の routes は表で書いてください",
            ),
            (
                "[claude.notion]\noverride = 1",
                "[claude.notion] の override は表で書いてください",
            ),
            (
                "[claude.notion.override.p]\nt = 1979-05-27T07:32:00Z",
                "[claude.notion] の override.p.t は日時で書けません",
            ),
        ] {
            let e = host(text).unwrap_err();
            assert!(e.starts_with("h.toml: "), "{e}");
            assert!(e.contains(want), "{text}: {e}");
        }
    }

    /// [claude.notion.tokens.<名前>] から ~/.local/state/dotfiles/notion-tokens.json の中身 (Linux の nix/lib/notion-tokens.nix の stateText と
    /// 同じ 1 行の JSON) を作る
    #[test]
    fn notion_tokens_json() {
        let empty = "{\"tokens\":{}}\n";
        assert_eq!(host("").unwrap().notion.tokens_json(), empty);
        assert_eq!(
            HostValues::missing(Path::new("h.toml"), groups())
                .notion
                .tokens_json(),
            empty
        );
        assert_eq!(
            host("[claude.notion]\nprofile = \"personal\"\n")
                .unwrap()
                .notion
                .tokens_json(),
            empty
        );
        let h = host(
            "[claude.notion]\nprofile = \"personal\"\n\n[claude.notion.tokens.personal]\nkind = \"personal\"\nitem = \"op://vvvv/iiii/ffff\"\n\n[claude.notion.tokens.my-ws]\nkind = \"integration\"\n\n[claude.notion.tokens.sec_1]\nkind = \"integration\"\nitem = \"op://Private Vault/My Item/s1/credential\"\n",
        )
        .unwrap();
        assert_eq!(
            h.notion.tokens_json(),
            "{\"tokens\":{\"my-ws\":{\"item\":null,\"kind\":\"integration\",\"var\":\"PJP_NOTION_TOKEN_MY_WS\"},\"personal\":{\"item\":\"op://vvvv/iiii/ffff\",\"kind\":\"personal\",\"var\":\"PJP_NOTION_TOKEN_PERSONAL\"},\"sec_1\":{\"item\":\"op://Private Vault/My Item/s1/credential\",\"kind\":\"integration\",\"var\":\"PJP_NOTION_TOKEN_SEC_1\"}}}\n"
        );
        // 手順が読む形: 名前ごとの種類・item・変数名
        let personal = &h.notion.tokens["personal"];
        assert_eq!(personal.kind, TokenKind::Personal);
        assert_eq!(personal.item.as_deref(), Some("op://vvvv/iiii/ffff"));
        assert_eq!(h.notion.tokens["my-ws"].item, None);
        assert_eq!(token_var("my-ws"), "PJP_NOTION_TOKEN_MY_WS");
        // claude-notion.json には入れない (古い resolver が知らないキーで止まらないよう、Linux と同じく別のファイル)
        assert_eq!(
            h.notion.json(),
            "{\"override\":{},\"profile\":\"personal\",\"routes\":{}}\n"
        );
        // inline table で書いても同じ
        let inline = host(
            "[claude.notion]\ntokens = { personal = { kind = \"personal\", item = \"op://vvvv/iiii/ffff\" } }\n",
        )
        .unwrap();
        assert_eq!(
            inline.notion.tokens_json(),
            "{\"tokens\":{\"personal\":{\"item\":\"op://vvvv/iiii/ffff\",\"kind\":\"personal\",\"var\":\"PJP_NOTION_TOKEN_PERSONAL\"}}}\n"
        );
    }

    /// 名前・item の受ける形 (Linux の nix/lib/notion-tokens.nix と同じ: 名前は profiles.toml の名前の形、item は欄まで書いた op:// の参照で、
    /// 区切りの間に空白と ASCII でない字を許す)
    #[test]
    fn accepts_notion_token_forms() {
        for item in [
            "op://a/b/c",
            "op://a/b/s/c",
            "op://Private Vault/My Item/credential",
            "op://金庫/項目/欄",
        ] {
            let h = host(&format!(
                "[claude.notion.tokens.0a-b_c]\nkind = \"integration\"\nitem = \"{item}\"\n"
            ))
            .unwrap();
            let t = &h.notion.tokens["0a-b_c"];
            assert_eq!(t.kind, TokenKind::Integration, "{item}");
            assert_eq!(t.item.as_deref(), Some(item));
        }
    }

    /// 書けない宣言は止める。止める文に item と kind の字を出さない (token の値を書いてしまったときに、端末やログへ出ないように)
    #[test]
    fn rejects_notion_token_mistakes() {
        const SECRET: &str = "ntn_secret_value_do_not_print";
        let with_item = |item: &str| {
            format!("[claude.notion.tokens.personal]\nkind = \"personal\"\nitem = {item}\n")
        };
        let item_shape = "[claude.notion.tokens.personal] の item が、欄まで書いた 1Password の参照 (op://<vault の ID>/<項目の ID>/<欄の ID>";
        let kind_shape = "[claude.notion.tokens.personal] の kind は \"integration\" か \"personal\" で書いてください";
        let cases: Vec<(String, &str)> = vec![
            (
                "[claude.notion]\ntokens = 1".to_string(),
                "[claude.notion] の tokens は表で書いてください ([claude.notion.tokens.<プロファイル>])",
            ),
            (
                format!("[claude.notion.tokens]\npersonal = \"{SECRET}\""),
                "[claude.notion.tokens] の personal は表で書いてください ([claude.notion.tokens.personal] に kind と item)",
            ),
            (
                "[claude.notion.tokens.Personal]\nkind = \"personal\"".to_string(),
                "[claude.notion.tokens] のキー (プロファイルの名前) が profiles.toml の名前の形ではありません: \"Personal\"",
            ),
            (
                "[claude.notion.tokens.-x]\nkind = \"personal\"".to_string(),
                "の名前の形ではありません: \"-x\"",
            ),
            (
                "[claude.notion.tokens.\"a b\"]\nkind = \"personal\"".to_string(),
                "の名前の形ではありません: \"a b\"",
            ),
            (
                "[claude.notion.tokens.personal]\nkind = \"personal\"\nkin = 1".to_string(),
                "[claude.notion.tokens.personal] に知らないキーがあります: kin (書けるのは kind・item)",
            ),
            (
                "[claude.notion.tokens.personal]\nitem = \"op://a/b/c\"".to_string(),
                "[claude.notion.tokens.personal] の kind を書いてください (\"integration\" か \"personal\")",
            ),
            (
                format!("[claude.notion.tokens.personal]\nkind = \"{SECRET}\""),
                kind_shape,
            ),
            (
                "[claude.notion.tokens.personal]\nkind = 1".to_string(),
                kind_shape,
            ),
            // 値そのもの・欄の無い参照・区切りが 5 つ以上・前に空白・改行やタブ・空の区切り・末尾の /・空・大文字の頭・文字列でない
            (with_item(&format!("\"{SECRET}\"")), item_shape),
            (with_item(&format!("\"op://v/{SECRET}\"")), item_shape),
            (with_item(&format!("\"op://v/i/s/f/{SECRET}\"")), item_shape),
            (with_item(&format!("\" op://v/i/{SECRET}\"")), item_shape),
            (with_item(&format!("\"op://v/i/{SECRET}\\n\"")), item_shape),
            (with_item(&format!("\"op://v/i/{SECRET}\\tx\"")), item_shape),
            (with_item(&format!("\"op://v//{SECRET}\"")), item_shape),
            (with_item(&format!("\"op://v/i/{SECRET}/\"")), item_shape),
            (with_item("\"\""), item_shape),
            (with_item(&format!("\"OP://v/i/{SECRET}\"")), item_shape),
            (with_item("1"), item_shape),
            (
                "[claude.notion.tokens.my-ws]\nkind = \"personal\"\n[claude.notion.tokens.my_ws]\nkind = \"integration\"\n"
                    .to_string(),
                "[claude.notion.tokens] の次の名前は、同じ変数になります (- は _ に読み替える): my-ws・my_ws → PJP_NOTION_TOKEN_MY_WS",
            ),
        ];
        for (text, want) in cases {
            let e = host(&text).unwrap_err();
            assert!(e.starts_with("h.toml: "), "{e}");
            assert!(e.contains(want), "{text}: {e}");
            assert!(!e.contains(SECRET), "{text}: {e}");
        }
        // item の文は、値を書いてしまったときの直し方を添える
        let e = host(&with_item(&format!("\"{SECRET}\""))).unwrap_err();
        assert!(e.contains("書いた字は出しません"), "{e}");
        assert!(e.contains("token を作り直してください"), "{e}");
    }

    /// TOML の構文の誤りは行と桁とわけだけを出し、行の写しを出さない。名前らしくない知らないキーは字を出さずに数だけを足す (token の値を
    /// 引用符なしで貼った・キーの所に貼ったときに、端末やログへ出さない)
    #[test]
    fn toml_errors_and_unknown_keys_do_not_copy_the_text() {
        const SECRET: &str = "sk-ant-oat01-secret-value-do-not-print";
        let cases: Vec<(String, &str)> = vec![
            (
                format!("[claude.tokens.alt]\nitem = {SECRET}\n"),
                "TOML として読めません (2 行目",
            ),
            (format!("{SECRET}\n"), "TOML として読めません (1 行目"),
            (
                format!("group = \"minimum\"\n{SECRET}\n"),
                "TOML として読めません (2 行目",
            ),
            (
                format!("[claude]\n\"{SECRET}\" = 1\n"),
                "[claude] に知らないキーがあります: ほか 1 個 (書いた字は出しません)",
            ),
            (
                format!("[claude]\n{SECRET} = 1\nnotio = 2\n"),
                "[claude] に知らないキーがあります: notio, ほか 1 個 (書いた字は出しません)",
            ),
            (
                format!("{SECRET} = 1\n"),
                "知らないキーがあります: ほか 1 個 (書いた字は出しません)",
            ),
        ];
        for (text, want) in cases {
            let e = host(&text).unwrap_err();
            assert!(e.starts_with("h.toml: "), "{e}");
            assert!(e.contains(want), "{text}: {e}");
            assert!(!e.contains(SECRET), "{text}: {e}");
            assert!(!e.contains("secret-value"), "{text}: {e}");
        }
        // 名前らしいキーは今までどおり並べる
        let e = host("[claude]\nx = 1").unwrap_err();
        assert!(e.contains("[claude] に知らないキーがあります: x ("), "{e}");
    }

    /// [claude.tokens.<名前>] から ~/.local/state/dotfiles/claude-tokens.json の中身 (Linux の nix/lib/claude-tokens.nix の stateText と同じ
    /// 1 行の JSON) を作る
    #[test]
    fn claude_tokens_json_is_like_nix() {
        let empty = "{\"accounts\":{}}\n";
        assert_eq!(claude_tokens_json(&host("").unwrap().claude_tokens), empty);
        assert_eq!(
            claude_tokens_json(&HostValues::missing(Path::new("h.toml"), groups()).claude_tokens),
            empty
        );
        let h = host(
            "[claude.notion]\nprofile = \"personal\"\n\n[claude.tokens.alt]\n\n[claude.tokens.b2]\nlabel = \"shared.v2_x-1\"\nitem = \"op://Private Vault/My Item/credential\"\n",
        )
        .unwrap();
        assert_eq!(
            claude_tokens_json(&h.claude_tokens),
            "{\"accounts\":{\"alt\":{\"item\":null,\"label\":\"alt\"},\"b2\":{\"item\":\"op://Private Vault/My Item/credential\",\"label\":\"shared.v2_x-1\"}}}\n"
        );
        // [claude.notion] とは混ざらない
        assert_eq!(h.notion.profile.as_deref(), Some("personal"));
        assert_eq!(h.notion.tokens_json(), "{\"tokens\":{}}\n");
        // inline table で書いても同じ
        let inline = host("[claude]\ntokens = { alt = {} }\n").unwrap();
        assert_eq!(
            claude_tokens_json(&inline.claude_tokens),
            "{\"accounts\":{\"alt\":{\"item\":null,\"label\":\"alt\"}}}\n"
        );
    }

    /// 書けない [claude.tokens] は止める。止める文に、規則に合わない名前・label・item・知らないキーの字を出さない
    #[test]
    fn rejects_claude_token_mistakes() {
        const SECRET: &str = "sk-ant-oat01-secret-value-do-not-print";
        let label_shape = "[claude.tokens.alt] の label が、token の呼び名の形ではありません (書いた字は出しません)";
        let item_shape = "[claude.tokens.alt] の item が、欄まで書いた 1Password の参照";
        let name_shape = "[claude.tokens] のキー (アカウントの名前) のうち 1 個が、アカウントの名前の形ではありません (書いた字は出しません)";
        let cases: Vec<(String, &str)> = vec![
            (
                "[claude]\ntokens = 1".to_string(),
                "[claude] の tokens は表で書いてください ([claude.tokens.<アカウントの名前>])",
            ),
            (
                format!("[claude.tokens]\nalt = \"{SECRET}\""),
                "[claude.tokens] の alt は表で書いてください ([claude.tokens.alt] に label と item。どちらも省ける)",
            ),
            ("[claude.tokens.Alt]".to_string(), name_shape),
            ("[claude.tokens.-x]".to_string(), name_shape),
            ("[claude.tokens.\"a b\"]".to_string(), name_shape),
            (
                "[claude.tokens.a23456789012345678901234567890123]".to_string(),
                name_shape,
            ),
            (format!("[claude.tokens.{SECRET}]"), name_shape),
            ("[claude.tokens.account]".to_string(), name_shape),
            ("[claude.tokens.selector]".to_string(), name_shape),
            (
                "[claude.tokens.default]".to_string(),
                "[claude.tokens] の default (素の claude) は Windows のホストの値には書けません",
            ),
            (
                format!("[claude.tokens.alt]\nlable = \"{SECRET}\""),
                "[claude.tokens.alt] に知らないキーが 1 個あります (書けるのは label・item。書いた字は出しません)",
            ),
            (
                format!("[claude.tokens.alt]\n\"{SECRET}\" = 1"),
                "[claude.tokens.alt] に知らないキーが 1 個あります",
            ),
            ("[claude.tokens.alt]\nlabel = \"Main\"".to_string(), label_shape),
            ("[claude.tokens.alt]\nlabel = \"a b\"".to_string(), label_shape),
            ("[claude.tokens.alt]\nlabel = \"\"".to_string(), label_shape),
            (
                "[claude.tokens.alt]\nlabel = \"a2345678901234567890123456789012345678901234567890123456789012345\""
                    .to_string(),
                label_shape,
            ),
            (format!("[claude.tokens.alt]\nlabel = \"{SECRET}\""), label_shape),
            ("[claude.tokens.alt]\nlabel = 1".to_string(), label_shape),
            (format!("[claude.tokens.alt]\nitem = \"{SECRET}\""), item_shape),
            (
                format!("[claude.tokens.alt]\nitem = \"op://v/{SECRET}\""),
                item_shape,
            ),
            ("[claude.tokens.alt]\nitem = \"\"".to_string(), item_shape),
            ("[claude.tokens.alt]\nitem = 1".to_string(), item_shape),
        ];
        for (text, want) in cases {
            let e = host(&text).unwrap_err();
            assert!(e.starts_with("h.toml: "), "{e}");
            assert!(e.contains(want), "{text}: {e}");
            assert!(!e.contains(SECRET), "{text}: {e}");
            assert!(!e.contains("lable"), "{text}: {e}");
        }
        // 受ける形: label は書かなければアカウントの名前、. と _ と - を含む呼び名、セクションのある参照
        let h = host(
            "[claude.tokens.a-b_c]\n[claude.tokens.x]\nlabel = \"m.v2_x-1\"\nitem = \"op://a/b/s/c\"\n",
        )
        .unwrap();
        assert_eq!(h.claude_tokens["a-b_c"].label, "a-b_c");
        assert_eq!(h.claude_tokens["a-b_c"].item, None);
        assert_eq!(h.claude_tokens["x"].label, "m.v2_x-1");
        assert_eq!(h.claude_tokens["x"].item.as_deref(), Some("op://a/b/s/c"));
    }

    #[test]
    fn rejects_mistakes() {
        for (text, want) in [
            (
                "grop = \"x\"",
                "知らないキーがあります: grop (書けるのは group・[tools]・[runner]・[opReason]・[sshd]・[t3Code]・[claude.notion]・[claude.tokens])",
            ),
            (
                "group = \"home\"",
                "group は all・minimum のどれかで書いてください",
            ),
            ("group = 1", "group は"),
            (
                "[tools]\nwindowsNtnn = true",
                "[tools] に知らない道具があります: windowsNtnn",
            ),
            (
                "[tools]\nwindowsNtn = \"yes\"",
                "[tools] の windowsNtn は true か false で書いてください",
            ),
            ("tools = 1", "tools は [tools] の表で書いてください"),
            (
                "[runner]\nenabled = true",
                "[runner] に知らないキーがあります: enabled",
            ),
            (
                "[runner]\nenable = 1",
                "[runner] の enable は true か false で書いてください",
            ),
            ("runner = true", "runner は [runner] の表で書いてください"),
            (
                "[opReason]\nsshRelayMode = \"always\"",
                "[opReason] の sshRelayMode は per-call か show-only で書いてください: always",
            ),
            (
                "[opReason]\nsshRelayMode = 1",
                "[opReason] の sshRelayMode は per-call か show-only で書いてください",
            ),
            (
                "[opReason]\nmode = \"per-call\"",
                "[opReason] に知らないキーがあります: mode (書けるのは sshRelayMode だけ)",
            ),
            (
                "opReason = \"per-call\"",
                "opReason は [opReason] の表で書いてください",
            ),
            ("sshd = 1", "sshd は [sshd] の表で書いてください"),
            (
                "[sshd]\nkeys = []",
                "[sshd] に知らないキーがあります: keys (書けるのは authorizedKeys・allowUsers・allowFrom)",
            ),
            (
                "[sshd]\nallowUsers = \"alice\"",
                "[sshd] の allowUsers は文字列の配列で書いてください (誰も入れないなら [])",
            ),
            (
                "[sshd]\nallowUsers = [1]",
                "[sshd] の allowUsers の 1 番目が文字列ではありません",
            ),
            (
                "[sshd]\nallowUsers = [\"alice\", \"Alice\"]",
                "[sshd] の allowUsers の 2 番目: 英小文字・数字で始まり英小文字・数字・. _ - だけの Windows のユーザー名で書いてください (Windows の sshd はログインの名前を小文字にして比べる): Alice",
            ),
            (
                "[sshd]\nallowUsers = [\"john doe\"]",
                "[sshd] の allowUsers の 1 番目: 英小文字・数字で始まり",
            ),
            (
                "[sshd]\nallowFrom = \"100.64.0.0/10\"",
                "[sshd] の allowFrom は文字列の配列で書いてください (どこからも入れないなら [])",
            ),
            (
                "[sshd]\nallowFrom = [\"100.64.0.0/10\", \"!127.0.0.1\"]",
                "[sshd] の allowFrom の 2 番目: IPv4・IPv6 のアドレスか CIDR として読めない (! * , と空白・% は書けない。名前も書けない): !127.0.0.1",
            ),
            (
                "[sshd]\nallowFrom = [\"100.64.0.0/33\"]",
                "[sshd] の allowFrom の 1 番目: CIDR の長さは IPv4 で 0〜32: 100.64.0.0/33",
            ),
            (
                "[sshd]\nallowFrom = [\"fd7a:115c:a1e0::/129\"]",
                "[sshd] の allowFrom の 1 番目: CIDR の長さは IPv6 で 0〜128",
            ),
            (
                "[sshd]\nallowFrom = [\"100.64.0.1/10\"]",
                "[sshd] の allowFrom の 1 番目: CIDR のアドレスに、長さより後ろのビットが立っている (範囲の頭のアドレスで書く。sshd が起動しなくなる): 100.64.0.1/10",
            ),
            (
                "[sshd]\nallowFrom = [\"100.64.0.0/010\"]",
                "[sshd] の allowFrom の 1 番目: CIDR の長さは、頭に 0 を付けない 10 進の数で書く",
            ),
            (
                "[sshd]\nallowFrom = [true]",
                "[sshd] の allowFrom の 1 番目が文字列ではありません",
            ),
            // 末尾の改行 (Install-Sshd.ps1 の検めも \z で終えて断る。値の改行は \n の字にして出す)
            (
                "[sshd]\nallowUsers = [\"alice\\n\", \"bob\"]",
                "[sshd] の allowUsers の 1 番目: 英小文字・数字で始まり英小文字・数字・. _ - だけの Windows のユーザー名で書いてください (Windows の sshd はログインの名前を小文字にして比べる): alice\\n",
            ),
            (
                "[sshd]\nallowFrom = [\"100.64.0.0/10\\n\", \"127.0.0.1\"]",
                "[sshd] の allowFrom の 1 番目: CIDR の長さは、頭に 0 を付けない 10 進の数で書く: 100.64.0.0/10\\n",
            ),
            (
                "[sshd]\nallowFrom = [\"127.0.0.1\\n\"]",
                "[sshd] の allowFrom の 1 番目: IPv4・IPv6 のアドレスか CIDR として読めない (! * , と空白・% は書けない。名前も書けない): 127.0.0.1\\n",
            ),
            (
                "[sshd]\nauthorizedKeys = \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE\"",
                "[sshd] の authorizedKeys は文字列の配列で書いてください",
            ),
            (
                "[sshd]\nauthorizedKeys = [1]",
                "[sshd] の authorizedKeys の 1 番目が文字列ではありません",
            ),
            (
                "[sshd]\nauthorizedKeys = [\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE a\", \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE b\\nssh-rsa AAAAB3NzaC1yc2EAAAADFAKEFAKE c\"]",
                "[sshd] の authorizedKeys の 2 番目が改行を含みます",
            ),
            (
                "[sshd]\nauthorizedKeys = [\"from=\\\"100.64.0.1\\\" AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE herdr\"]",
                "[sshd] の authorizedKeys の 1 番目を authorized_keys の行として読めません",
            ),
            ("= broken", "TOML として読めません"),
        ] {
            let e = host(text).unwrap_err();
            assert!(e.starts_with("h.toml: "), "{e}");
            assert!(e.contains(want), "{text}: {e}");
        }
    }

    /// [sshd] authorizedKeys: 書かなければ None、[] は鍵 0 本、list はその行のまま (from= のオプションが付いてよい)
    #[test]
    fn sshd_keys_follow_the_null_and_list_meanings() {
        assert_eq!(host("").unwrap().sshd_keys, None);
        assert_eq!(host("[sshd]\n").unwrap().sshd_keys, None);
        assert_eq!(
            HostValues::missing(Path::new("h.toml"), groups()).sshd_keys,
            None
        );
        assert_eq!(
            host("[sshd]\nauthorizedKeys = []\n").unwrap().sshd_keys,
            Some(vec![])
        );
        let a = r#"from="100.64.0.1,fd7a:115c:a1e0::1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKEFAKEFAKEFAKE herdr@phone"#;
        let b = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABFAKE==";
        let text = format!("[sshd]\nauthorizedKeys = [\n  '{a}',\n  '{b}',\n]\n");
        assert_eq!(
            host(&text).unwrap().sshd_keys,
            Some(vec![a.to_string(), b.to_string()])
        );
    }

    /// [sshd] allowUsers・allowFrom: 書かなければ None、[] は 0、list はその値のまま (authorizedKeys と同じ流儀)。片方だけ書いてよい
    #[test]
    fn sshd_allow_values_follow_the_null_and_list_meanings() {
        let h = host("").unwrap();
        assert_eq!((h.sshd_allow_users, h.sshd_allow_from), (None, None));
        let h = host("[sshd]\nauthorizedKeys = []\n").unwrap();
        assert_eq!((h.sshd_allow_users, h.sshd_allow_from), (None, None));
        let h = HostValues::missing(Path::new("h.toml"), groups());
        assert_eq!((h.sshd_allow_users, h.sshd_allow_from), (None, None));
        let h = host("[sshd]\nallowUsers = []\nallowFrom = []\n").unwrap();
        assert_eq!(
            (h.sshd_allow_users, h.sshd_allow_from),
            (Some(vec![]), Some(vec![]))
        );
        let h = host(
            "[sshd]\nallowUsers = [\"alice\", \"b.o_b-2\"]\nallowFrom = [\"100.64.0.0/10\", \"fd7a:115c:a1e0::/48\", \"127.0.0.1\", \"::1\"]\n",
        )
        .unwrap();
        assert_eq!(
            h.sshd_allow_users,
            Some(vec!["alice".to_string(), "b.o_b-2".to_string()])
        );
        assert_eq!(
            h.sshd_allow_from,
            Some(
                ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "127.0.0.1", "::1"]
                    .map(String::from)
                    .to_vec()
            )
        );
        // 片方だけ書けば、もう片方は None (既定)
        let h = host("[sshd]\nallowFrom = [\"100.64.0.1\"]\n").unwrap();
        assert_eq!(h.sshd_allow_users, None);
        assert_eq!(h.sshd_allow_from, Some(vec!["100.64.0.1".to_string()]));
    }

    /// AllowUsers に書けるユーザー名 (Install-Sshd.ps1 の Test-SshdUserName と同じ例)
    #[test]
    fn sshd_user_names() {
        for ok in ["alice", "a.b_c-1", "0day"] {
            assert!(sshd_user_ok(ok), "{ok}");
        }
        for bad in [
            "Alice", "john doe", "a@b", "a*", "", "-a", ".a", "a/b", "a\\b", "ä",
        ] {
            assert!(!sshd_user_ok(bad), "{bad}");
        }
        // 末尾・頭の改行 (Install-Sshd.ps1 の Test-SshdUserName も \z で終えて断る。.NET の $ は末尾の改行の前でも当たる)
        for bad in ["alice\n", "alice\r\n", "\nalice"] {
            assert!(!sshd_user_ok(bad), "{bad:?}");
        }
    }

    /// Match Address に書ける送り元 (Install-Sshd.ps1 の Test-SshdFromAddress と同じ例)
    #[test]
    fn sshd_from_addresses() {
        for ok in [
            "100.64.0.0/10",
            "fd7a:115c:a1e0::/48",
            "127.0.0.1",
            "::1",
            "192.0.2.10",
            "192.0.2.0/24",
            "2001:db8::1",
            "2001:db8::/32",
            "0.0.0.0/0",
            "::ffff:192.0.2.1",
            "100.64.0.1/32",
            "fd7a:115c:a1e0::1/128",
            "FD7A:115C:A1E0::/48",
        ] {
            assert_eq!(sshd_from_check(ok), Ok(()), "{ok}");
        }
        for bad in [
            // 長さの誤り・頭の 0
            "100.64.0.0/33",
            "fd7a:115c:a1e0::/129",
            "100.64.0.0/010",
            "010.0.0.1",
            "100.64.0.0/",
            "100.64.0.0/+10",
            // 範囲の頭でない CIDR
            "100.64.0.1/10",
            "fd7a:115c:a1e0::1/48",
            // 否定・パターン・区切り・空白・ゾーン・名前・欠けた形・空
            "!100.64.0.0/10",
            "*",
            "100.64.*",
            "127.0.0.1,::1",
            " 127.0.0.1",
            "127.0.0.1 ",
            "fe80::1%eth0",
            "example.com",
            "1.2.3",
            "",
            "::ffff:01.2.3.4",
            // 末尾の改行 (Install-Sshd.ps1 の Test-SshdFromAddress も \z で終えて断る)
            "100.64.0.0/10\n",
            "127.0.0.1\n",
            "::1\n",
            "fd7a:115c:a1e0::/48\r\n",
        ] {
            assert!(sshd_from_check(bad).is_err(), "{bad:?}");
        }
    }

    /// authorized_keys の 1 行として読めるか (Install-Sshd.ps1 の Test-AuthorizedKeyLine と同じ見方に、# の行を足したもの)
    #[test]
    fn authorized_key_lines() {
        for ok in [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE herdr@phone",
            r#"from="100.64.0.1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE"#,
            "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAy= x",
            "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9w x",
        ] {
            assert!(authorized_key_line_ok(ok), "{ok}");
        }
        for bad in [
            "",
            "   ",
            "AAAAC3NzaC1lZDI1NTE5AAAAIFAKE",
            "ssh-ed25519",
            "ssh-ed25519 short",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE====",
            "ssh-dss AAAAB3NzaC1kc3MAAACBAFAKE",
            "# ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE",
            "  # ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE\r",
        ] {
            assert!(!authorized_key_line_ok(bad), "{bad:?}");
        }
    }

    /// Windows のエディタ (Windows PowerShell 5.1 の Set-Content -Encoding UTF8 など) が付ける頭の BOM は読み飛ばす
    #[test]
    fn leading_bom_is_ignored() {
        let h = host("\u{feff}group = \"all\"\n").unwrap();
        assert_eq!(h.group, "all");
    }

    #[test]
    fn missing_file_is_not_an_error() {
        let t = TempDir::new("host");
        let path = t.path().join("alice@example-host.toml");
        let h = load(&path, groups()).unwrap();
        assert_eq!(h.source, Source::Missing(vec![path.clone()]));
        assert_eq!(h.group, "minimum");
        assert!(!h.runner_enable);
        std::fs::write(&path, "[runner]\nenable = true\n").unwrap();
        assert!(load(&path, groups()).unwrap().runner_enable);
    }

    #[test]
    fn default_path_is_next_to_the_clone() {
        let repo = Path::new("/g/github.com/pollenjp/dotfiles");
        assert_eq!(
            default_path(repo, None, "alice", "example-host"),
            Path::new("/g/github.com/pollenjp/dotfiles-private")
                .join("win")
                .join("hosts")
                .join("alice@example-host.toml")
        );
    }

    #[test]
    fn rejects_broken_groups_json() {
        let ok = r#"{"version":3,"default":"minimum","groups":{"minimum":{"tools":{"a":false,"b":true}}},"requires":{"a":["b"]},"requiresWhy":{"a":{"b":"わけ"}},"skills":{"s":{"windows":["a"],"linux":["x"]}}}"#;
        assert!(Groups::parse(ok).is_ok());
        assert!(Groups::parse("{}").is_err());
        assert!(Groups::parse("not json").is_err());
        // 前の版 (段の tiers を持っていた version 1 と、要る道具の表を持たない version 2) は読まない
        for old in [1, 2] {
            let text = ok.replace("\"version\":3", &format!("\"version\":{old}"));
            assert!(Groups::parse(&text).is_err(), "{text}");
        }
        let broken = [
            ("\"default\":\"minimum\"", "\"default\":\"x\""),
            ("\"a\":false", "\"a\":1"),
            // requires・skills の道具は groups の tools にある名前で、並びは文字列の配列
            (
                "\"requires\":{\"a\":[\"b\"]}",
                "\"requires\":{\"a\":[\"c\"]}",
            ),
            (
                "\"requires\":{\"a\":[\"b\"]}",
                "\"requires\":{\"c\":[\"b\"]}",
            ),
            ("\"requires\":{\"a\":[\"b\"]}", "\"requires\":{\"a\":\"b\"}"),
            ("\"requires\":{\"a\":[\"b\"]},", ""),
            (
                "\"skills\":{\"s\":{\"windows\":[\"a\"]",
                "\"skills\":{\"s\":{\"windows\":[\"c\"]",
            ),
            (
                "\"skills\":{\"s\":{\"windows\":[\"a\"]",
                "\"skills\":{\"s\":{\"windows\":[1]",
            ),
            (
                ",\"skills\":{\"s\":{\"windows\":[\"a\"],\"linux\":[\"x\"]}}",
                "",
            ),
            // わけは要る道具の表と同じ組の文字列
            (
                "\"requiresWhy\":{\"a\":{\"b\":\"わけ\"}}",
                "\"requiresWhy\":{\"a\":{\"c\":\"わけ\"}}",
            ),
            (
                "\"requiresWhy\":{\"a\":{\"b\":\"わけ\"}}",
                "\"requiresWhy\":{\"a\":{\"b\":1}}",
            ),
        ];
        for (from, to) in broken {
            let text = ok.replace(from, to);
            assert_ne!(text, ok, "{from}");
            assert!(Groups::parse(&text).is_err(), "{text}");
        }
        // わけの無い組は読める (文にわけを添えない)
        assert!(Groups::parse(&ok.replace("{\"a\":{\"b\":\"わけ\"}}", "{}")).is_ok());
    }
}
