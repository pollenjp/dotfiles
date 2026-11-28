//! 外とのやりとり: hc と herdr-app の CLI (と gh・git)。テストは [`Runner`] を偽物に差し替える。
//!
//! hc の CLI は `--json` で答えを JSON にし、落ちると stderr に `{"error": {"kind", "message", "hint"}}` を出す (終了コードは
//! 3 not_found・9 blocked・11 finished など。`hc --skill`)。子のマシンのコマンドは `hc exec --json [--on <m>]` で打ち、
//! ExecResult (`stdout`・`stderr`・`code`・`timed_out`) を読む。CLI に subcommand の無い API の method (`doc.get`・`doc.set`) は、
//! `hc connect` の stdin に JSON-RPC 2.0 の要求を 1 行書いて打つ ([`Hc::api`])。herdr-app は `herdr-app do <command> <JSON>` で
//! 打ち、作ったものの id か `{"error": …}` を受ける。

use std::path::PathBuf;
use std::time::Duration;

use pjp_core::process::{Cmd, Output};
use pjp_core::time::Timestamp;
use pjp_core::{Error, Result};
use serde_json::{Value, json};

/// hc に聞くのを待つ長さ (別のマシンにつながらないと待たされる)。
pub const HC_TIMEOUT: Duration = Duration::from_secs(30);
/// herdr-app を待つ長さ。
pub const APP_TIMEOUT: Duration = Duration::from_secs(30);
/// `hc run` を待つ長さ (別のマシンに端末を立てる)。
const RUN_TIMEOUT: Duration = Duration::from_secs(90);
/// `hc exec` の時間切れに足す余白 (hc が子のマシンとやりとりする分)。
const EXEC_MARGIN: Duration = Duration::from_secs(20);

/// 外とのやりとり。
pub trait Runner {
    /// コマンドを起こして終わりを待つ (stdin は閉じる)。起こせなければ Err (見つからないときは終了コード 2)。
    fn run(&self, cmd: &Cmd) -> Result<Output>;
    fn which(&self, name: &str) -> Option<PathBuf>;
    /// env の値 (空は無いとみる)。
    fn env(&self, key: &str) -> Option<String>;
    fn cwd(&self) -> Result<PathBuf>;
    fn now(&self) -> Result<Timestamp>;
    fn sleep(&self, d: Duration);
    /// pjp の控えの置き場 (`<XDG_STATE_HOME>/pjp`)。
    fn state_dir(&self) -> Result<PathBuf>;
    /// pjp の設定の置き場 (`<XDG_CONFIG_HOME>/pjp`)。
    fn config_dir(&self) -> Result<PathBuf>;
    /// pack の JSON を作るときに読む skill の置き場 (`${CLAUDE_CONFIG_DIR:-~/.claude}/skills`)。
    fn skill_roots(&self) -> Result<Vec<PathBuf>>;
    /// stdin を終わりまで読む (Claude Code の hook の入力)。stdin が端末なら読まずに None (人が打ったときに待たない)。
    fn read_stdin(&self) -> Result<Option<Vec<u8>>>;
    /// 新しい id (herdr-app の space・tab・ペイン) に使う 128 bit の乱数。テストの偽物は決まった値を返す。
    fn random_u128(&self) -> u128 {
        random_u128()
    }
}

/// 128 bit の乱数 (std の `RandomState` の鍵は OS の乱数で決まり、作るたびに進む。今の時刻も混ぜる)。暗号には使わない
/// (id が重ならなければよい)。
pub fn random_u128() -> u128 {
    use std::hash::{BuildHasher, Hasher};
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let half = |salt: u8| -> u64 {
        let mut h = std::hash::RandomState::new().build_hasher();
        h.write_u128(nanos);
        h.write_u8(salt);
        h.finish()
    };
    (u128::from(half(1)) << 64) | u128::from(half(2))
}

/// 本物の Runner。
pub struct SystemRunner;

impl Runner for SystemRunner {
    fn run(&self, cmd: &Cmd) -> Result<Output> {
        cmd.output()
    }

    fn which(&self, name: &str) -> Option<PathBuf> {
        pjp_core::process::find_in_path(name)
    }

    fn env(&self, key: &str) -> Option<String> {
        std::env::var(key).ok().filter(|v| !v.is_empty())
    }

    fn cwd(&self) -> Result<PathBuf> {
        std::env::current_dir().map_err(|e| Error::io("今のディレクトリが分かりません", &e))
    }

    fn now(&self) -> Result<Timestamp> {
        pjp_core::time::now()
    }

    fn sleep(&self, d: Duration) {
        pjp_core::sleep::sleep(d);
    }

    fn state_dir(&self) -> Result<PathBuf> {
        pjp_core::paths::pjp_state_dir()
    }

    fn config_dir(&self) -> Result<PathBuf> {
        Ok(pjp_core::paths::xdg_config_home()?.join("pjp"))
    }

    fn skill_roots(&self) -> Result<Vec<PathBuf>> {
        crate::pack::default_roots()
    }

    fn read_stdin(&self) -> Result<Option<Vec<u8>>> {
        use std::io::{IsTerminal, Read};
        let mut stdin = std::io::stdin();
        if stdin.is_terminal() {
            return Ok(None);
        }
        let mut bytes = Vec::new();
        stdin
            .read_to_end(&mut bytes)
            .map_err(|e| Error::io("stdin を読めません", &e))?;
        Ok(Some(bytes))
    }
}

/// hc が自分の判断で断った・落ちたとき (`{"error": {…}}`)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HcFail {
    pub code: Option<i32>,
    /// `not_found`・`blocked` など (読めなければ空)。
    pub kind: String,
    pub message: String,
}

impl HcFail {
    fn from_output(out: &Output) -> Self {
        let v: Value = serde_json::from_str(out.stderr.trim()).unwrap_or(Value::Null);
        let err = &v["error"];
        let kind = err["kind"].as_str().unwrap_or_default().to_owned();
        let mut message = err["message"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| first_line(&out.stderr).to_owned());
        if let Some(hint) = err["hint"].as_str().filter(|h| !h.is_empty()) {
            message = format!("{message} ({hint})");
        }
        if out.timed_out {
            message = "時間切れ".to_owned();
        } else if message.is_empty() {
            message = format!(
                "終了コード {}",
                out.code.map_or("?".to_owned(), |c| c.to_string())
            );
        }
        Self {
            code: out.code,
            kind,
            message,
        }
    }

    /// API の返りの error (`{"code", "message", "data": {"kind", "hint"}}`。[`Hc::api`])。`code` (終了コード) は None。
    fn from_rpc(err: &Value) -> Self {
        let kind = err["data"]["kind"].as_str().unwrap_or_default().to_owned();
        let mut message = err["message"].as_str().unwrap_or_default().to_owned();
        if message.is_empty() {
            message = err.to_string();
        }
        if let Some(hint) = err["data"]["hint"].as_str().filter(|h| !h.is_empty()) {
            message = format!("{message} ({hint})");
        }
        Self {
            code: None,
            kind,
            message,
        }
    }

    pub fn not_found(&self) -> bool {
        self.kind == "not_found" || self.code == Some(3)
    }

    pub fn blocked(&self) -> bool {
        self.kind == "blocked" || self.code == Some(9)
    }

    pub fn finished(&self) -> bool {
        self.kind == "finished" || self.code == Some(11)
    }

    /// `hc <what> が落ちました: …` の失敗 (終了コード 1)。
    pub fn into_error(self, what: &str) -> Error {
        Error::failure(format!("hc {what} が落ちました: {}", self.message))
    }
}

/// core の doc (`doc.get` の返り)。hc の core は、名前ごとに版つきの JSON を 1 つ持つ (1 MiB まで。中身は読まない)。
#[derive(Debug, Clone, PartialEq)]
pub struct Doc {
    pub value: Value,
    /// 書くたびに 1 つ進む。一度も書いていない doc は 0。
    pub version: u64,
}

/// `hc exec` の結果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecOut {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

impl ExecOut {
    pub fn ok(&self) -> bool {
        !self.timed_out && self.code == Some(0)
    }

    /// 落ちたわけの 1 行。
    pub fn why(&self) -> String {
        if self.timed_out {
            return "時間切れ".to_owned();
        }
        let line = first_line(&self.stderr);
        if line.is_empty() {
            format!(
                "終了コード {}",
                self.code.map_or("?".to_owned(), |c| c.to_string())
            )
        } else {
            line.to_owned()
        }
    }
}

/// base64 (RFC 4648 の標準の字。`=` の埋めは有っても無くてもよい) を読む。読めなければ None。
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let value = |c: u8| -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some(u32::from(c - b'A')),
            b'a'..=b'z' => Some(u32::from(c - b'a') + 26),
            b'0'..=b'9' => Some(u32::from(c - b'0') + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    };
    let body = text.trim_end_matches('=').as_bytes();
    if text.len() - body.len() > 2 || body.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(body.len() * 3 / 4);
    for chunk in body.chunks(4) {
        let mut n = 0u32;
        for (i, &c) in chunk.iter().enumerate() {
            n |= value(c)? << (18 - 6 * i);
        }
        let bytes = n.to_be_bytes();
        out.extend_from_slice(&bytes[1..chunk.len()]);
    }
    Some(out)
}

/// 文の最初の空でない行。
pub fn first_line(text: &str) -> &str {
    text.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("")
}

/// hc の呼び口。
pub struct Hc<'a> {
    r: &'a dyn Runner,
    /// `get`・`json` (`label`・`ls`)・`kill`・`rm` の待ち。
    timeout: Duration,
}

impl<'a> Hc<'a> {
    pub fn new(r: &'a dyn Runner) -> Self {
        Self::with_timeout(r, HC_TIMEOUT)
    }

    /// 待ちを替えた呼び口 (Claude Code の hook は、hook の打ち切りより前に終えるよう短く待つ)。
    pub fn with_timeout(r: &'a dyn Runner, timeout: Duration) -> Self {
        Self { r, timeout }
    }

    /// hc が PATH にあるか。無ければ設定の誤り。
    pub fn require(&self) -> Result<()> {
        if self.r.which("hc").is_some() {
            Ok(())
        } else {
            Err(Error::config(
                "hc が見つかりません (herdr-core の hc を PATH に入れる)",
            ))
        }
    }

    fn call(&self, args: &[String], timeout: Duration) -> Result<Output> {
        self.r.run(&Cmd::new("hc").args(args).timeout(timeout))
    }

    /// hc を打ち、成功なら stdout を JSON で読む。hc が断った・落ちたら内側の Err。
    pub fn try_json(
        &self,
        args: &[String],
        timeout: Duration,
    ) -> Result<std::result::Result<Value, HcFail>> {
        let out = self.call(args, timeout)?;
        if !out.success() {
            return Ok(Err(HcFail::from_output(&out)));
        }
        let text = out.stdout.trim();
        if text.is_empty() {
            return Ok(Ok(Value::Null));
        }
        serde_json::from_str(text).map(Ok).map_err(|e| {
            Error::failure(format!(
                "hc {} の出力を JSON として読めません: {e}",
                args.first().map_or("", String::as_str)
            ))
        })
    }

    /// hc を打って JSON を受ける。断られたら失敗。
    pub fn json(&self, args: &[String]) -> Result<Value> {
        let what = args.first().cloned().unwrap_or_default();
        self.try_json(args, self.timeout)?
            .map_err(|f| f.into_error(&what))
    }

    /// 子のマシン (None はこのマシン) で argv を打つ (`hc exec --json`。shell を通さない)。
    pub fn exec(
        &self,
        machine: Option<&str>,
        cwd: Option<&str>,
        timeout_secs: u64,
        argv: &[&str],
    ) -> Result<ExecOut> {
        self.exec_env(machine, cwd, &[], timeout_secs, argv)
    }

    /// [`Hc::exec`] に、core の env の上に足す env (`K=V`。`hc exec --env`) を付けて打つ。
    pub fn exec_env(
        &self,
        machine: Option<&str>,
        cwd: Option<&str>,
        env: &[String],
        timeout_secs: u64,
        argv: &[&str],
    ) -> Result<ExecOut> {
        let mut args = vec!["exec".to_owned(), "--json".to_owned()];
        if let Some(m) = machine {
            args.extend(["--on".to_owned(), m.to_owned()]);
        }
        if let Some(dir) = cwd {
            args.extend(["--cwd".to_owned(), dir.to_owned()]);
        }
        for kv in env {
            args.extend(["--env".to_owned(), kv.clone()]);
        }
        args.extend([
            "--timeout".to_owned(),
            timeout_secs.to_string(),
            "--".to_owned(),
        ]);
        args.extend(argv.iter().map(|a| (*a).to_owned()));
        let timeout = Duration::from_secs(timeout_secs) + EXEC_MARGIN;
        let v = self
            .try_json(&args, timeout)?
            .map_err(|f| f.into_error(&format!("exec {}", argv.first().copied().unwrap_or(""))))?;
        // ExecResult の stdout・stderr は base64 (hc 0.1.21 の schema: "What it wrote, base64")
        let text = |k: &str| -> String {
            let raw = v[k].as_str().unwrap_or_default();
            match base64_decode(raw) {
                Some(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
                None => raw.to_owned(),
            }
        };
        Ok(ExecOut {
            code: v["code"].as_i64().and_then(|c| i32::try_from(c).ok()),
            stdout: text("stdout"),
            stderr: text("stderr"),
            timed_out: v["timed_out"].as_bool().unwrap_or(false),
        })
    }

    /// 端末を 1 つ読む。無ければ None。
    pub fn get(&self, addr: &str) -> Result<Option<Value>> {
        match self.try_json(&strings(&["get", addr, "--json"]), self.timeout)? {
            Ok(v) => Ok(Some(v)),
            Err(f) if f.not_found() => Ok(None),
            Err(f) => Err(f.into_error("get")),
        }
    }

    /// 生きている端末の一覧 (`hc ls --json` の terminals。label は載らない)。
    pub fn ls(&self, all: bool) -> Result<Vec<Value>> {
        let mut args = strings(&["ls", "--json"]);
        if all {
            args.push("--all".to_owned());
        }
        let v = self.json(&args)?;
        Ok(v["terminals"].as_array().cloned().unwrap_or_default())
    }

    /// label を付ける・外す (`key=` で外す)。
    pub fn label(&self, addr: &str, pairs: &[String]) -> Result<Value> {
        let mut args = strings(&["label", addr]);
        args.extend(pairs.iter().cloned());
        args.push("--json".to_owned());
        self.json(&args)
    }

    /// 端末の program を終える (hangup から順に強める)。もう終わっていれば何もしない。
    pub fn kill(&self, addr: &str) -> Result<()> {
        match self.try_json(&strings(&["kill", addr, "--json"]), self.timeout)? {
            Ok(_) => Ok(()),
            Err(f) if f.finished() => Ok(()),
            Err(f) => Err(f.into_error("kill")),
        }
    }

    /// 終わった端末を消す。
    pub fn rm(&self, addr: &str) -> std::result::Result<(), HcFail> {
        match self.try_json(&strings(&["rm", addr, "--json"]), self.timeout) {
            Ok(Ok(_)) => Ok(()),
            Ok(Err(f)) => Err(f),
            Err(e) => Err(HcFail {
                code: None,
                kind: String::new(),
                message: e.message().to_owned(),
            }),
        }
    }

    /// 端末が働き終わる (か終わる) まで、最長 `secs` 秒待つ。結果は読まない (時間切れも返る)。
    pub fn wait(&self, addr: &str, secs: u64) -> Result<()> {
        let args = strings(&["wait", addr, "--timeout", &secs.to_string(), "--json"]);
        // 断られても (blocked など) 構わない。続きで状態を読む
        let _ = self.try_json(&args, Duration::from_secs(secs) + EXEC_MARGIN)?;
        Ok(())
    }

    /// 画面と履歴の文。`complete` が false (working・blocked の間) なら、わけを末尾に添える。
    pub fn read(&self, addr: &str, lines: u32) -> Result<String> {
        let v = self.json(&strings(&[
            "read",
            addr,
            "--lines",
            &lines.to_string(),
            "--json",
        ]))?;
        let mut text = v["text"].as_str().unwrap_or_default().to_owned();
        if v["complete"].as_bool() == Some(false) {
            let why = v["why"].as_str().unwrap_or("?");
            text.push_str(&format!("\n(履歴は読めず、画面だけ: {why})\n"));
        }
        Ok(text)
    }

    /// 文を貼って Enter を押す。相手が blocked なら hc が断る (`--force` は使わない)。
    /// 文の前に `--` を置く (`- ` で始まる Markdown の箇条書きを、hc が option と読んで断る。hc 0.1.21 で確かめた)。
    pub fn send(&self, addr: &str, text: &str) -> Result<std::result::Result<Value, HcFail>> {
        self.try_json(
            &strings(&["send", "--json", addr, "--", text]),
            Duration::from_secs(120),
        )
    }

    /// hc の API (JSON-RPC 2.0) の method を 1 つ打つ。CLI に subcommand の無い method (`doc.get`・`doc.set`) のため。
    /// `hc connect` (API を stdin・stdout で話す口) の stdin に 1 行の要求を書き、返りの行のうち id の合うものを読む
    /// (hc 0.1.21 は `hello` なしで答え、stdin が閉じると返りを書いてから終わる)。core の選び方は、ほかの hc のコマンドと
    /// 同じ (`hc get`・`hc label` と同じ core に届く)。core が error を返した・`hc connect` が落ちたら内側の Err
    /// (`kind` は error の `data.kind`)、返りを読めなければ失敗。
    pub fn api(&self, method: &str, params: &Value) -> Result<std::result::Result<Value, HcFail>> {
        const ID: u64 = 1;
        let request = json!({"jsonrpc": "2.0", "id": ID, "method": method, "params": params});
        let cmd = Cmd::new("hc")
            .arg("connect")
            .stdin_bytes(format!("{request}\n"))
            .timeout(self.timeout);
        let out = self.r.run(&cmd)?;
        if !out.success() {
            return Ok(Err(HcFail::from_output(&out)));
        }
        let reply = out
            .stdout
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
            .find(|v| v["id"] == json!(ID))
            .ok_or_else(|| {
                let got = first_line(&out.stdout);
                Error::failure(format!(
                    "hc connect ({method}) の返りを読めません ({})",
                    if got.is_empty() { "空" } else { got }
                ))
            })?;
        if let Some(err) = reply.get("error") {
            return Ok(Err(HcFail::from_rpc(err)));
        }
        Ok(Ok(reply["result"].clone()))
    }

    /// core の doc を読む (`doc.get`)。一度も書いていない doc は値 null・版 0。`on` は別のマシンの core の doc (None はこの
    /// core。`on` を渡さない)。
    pub fn doc_get(
        &self,
        name: &str,
        on: Option<&str>,
    ) -> Result<std::result::Result<Doc, HcFail>> {
        let mut params = json!({"name": name});
        if let Some(m) = on {
            params["on"] = json!(m);
        }
        let result = match self.api("doc.get", &params)? {
            Ok(v) => v,
            Err(f) => return Ok(Err(f)),
        };
        let version = result["version"].as_u64().ok_or_else(|| {
            Error::failure(format!("doc.get ({name}) の返りに版がありません: {result}"))
        })?;
        Ok(Ok(Doc {
            value: result["value"].clone(),
            version,
        }))
    }

    /// core の doc を書く (`doc.set`)。`version` が今の版と合うときだけ書き、新しい版を返す。合わなければ `kind` が
    /// `conflict` の内側の Err (読み直して打ち直す)。`on` は [`Hc::doc_get`] と同じ。
    pub fn doc_set(
        &self,
        name: &str,
        on: Option<&str>,
        value: &Value,
        version: u64,
    ) -> Result<std::result::Result<u64, HcFail>> {
        let mut params = json!({"name": name, "value": value, "version": version});
        if let Some(m) = on {
            params["on"] = json!(m);
        }
        let result = match self.api("doc.set", &params)? {
            Ok(v) => v,
            Err(f) => return Ok(Err(f)),
        };
        let version = result["version"].as_u64().ok_or_else(|| {
            Error::failure(format!("doc.set ({name}) の返りに版がありません: {result}"))
        })?;
        Ok(Ok(version))
    }

    /// `hc run` を打って RunResult を受ける (別のマシンに立てるのを待つので、ほかの hc より長く待つ)。
    pub fn run(&self, args: &[String]) -> Result<Value> {
        let mut full = strings(&["run"]);
        full.extend(args.iter().cloned());
        self.try_json(&full, RUN_TIMEOUT)?
            .map_err(|f| f.into_error("run"))
    }
}

/// herdr-app の呼び口 (画面の space を作る・閉じる・名前を替える)。
pub struct HerdrApp<'a> {
    r: &'a dyn Runner,
}

impl<'a> HerdrApp<'a> {
    pub fn new(r: &'a dyn Runner) -> Self {
        Self { r }
    }

    pub fn available(&self) -> bool {
        self.r.which("herdr-app").is_some()
    }

    /// `herdr-app do <command> <JSON>`。返りの JSON を受ける。herdr-app が `{"error": …}` を返した・落ちたら失敗。
    pub fn run(&self, command: &str, args: &Value) -> Result<Value> {
        let cmd = Cmd::new("herdr-app")
            .args(["do", command, &args.to_string()])
            .timeout(APP_TIMEOUT);
        let out = self.r.run(&cmd)?;
        let v: Value = serde_json::from_str(out.stdout.trim()).unwrap_or(Value::Null);
        if let Some(err) = v.get("error") {
            let msg = err.as_str().map_or_else(|| err.to_string(), str::to_owned);
            return Err(Error::failure(format!("herdr-app do {command}: {msg}")));
        }
        if !out.success() {
            let why = if out.timed_out {
                "時間切れ".to_owned()
            } else {
                first_line(&out.stderr).to_owned()
            };
            return Err(Error::failure(format!(
                "herdr-app do {command} が落ちました: {why}"
            )));
        }
        Ok(v)
    }

    /// `space.new` が引数 `focus` を知っているか (herdr-app 0.1.16 から)。`herdr-app commands` (窓が無くても答える。
    /// 要素が `{name, args: [{name, required}], about}` の JSON の配列) を 1 回読む。落ちた・読めないときは
    /// [`SpaceFocus::Unknown`] (渡さない側に倒す。知らない引数を渡すと space.new が落ちる)。
    pub fn space_focus(&self) -> SpaceFocus {
        let cmd = Cmd::new("herdr-app").arg("commands").timeout(APP_TIMEOUT);
        let out = match self.r.run(&cmd) {
            Ok(out) => out,
            Err(e) => return SpaceFocus::Unknown(e.message().to_owned()),
        };
        if !out.success() {
            let why = if out.timed_out {
                "時間切れ".to_owned()
            } else {
                let line = first_line(&out.stderr);
                let line = if line.is_empty() {
                    first_line(&out.stdout)
                } else {
                    line
                };
                format!("終了コード {}: {line}", out.code.unwrap_or(-1))
            };
            return SpaceFocus::Unknown(why);
        }
        let Ok(Value::Array(list)) = serde_json::from_str::<Value>(out.stdout.trim()) else {
            return SpaceFocus::Unknown("JSON の配列でない".to_owned());
        };
        let Some(space_new) = list
            .iter()
            .find(|c| c.get("name").and_then(Value::as_str) == Some("space.new"))
        else {
            return SpaceFocus::Unknown("space.new が載っていない".to_owned());
        };
        let has_focus = space_new
            .get("args")
            .and_then(Value::as_array)
            .is_some_and(|args| {
                args.iter()
                    .any(|a| a.get("name").and_then(Value::as_str) == Some("focus"))
            });
        if has_focus {
            SpaceFocus::Supported
        } else {
            SpaceFocus::Unsupported
        }
    }

    /// space を作る。返りの space と tab の id (herdr-app の形のまま) を返す。`focus` が
    /// [`SpaceFocus::Supported`] のときだけ `"focus": false` を渡す (表示中の space と打ち込み先のペインを動かさない)。
    pub fn space_new(
        &self,
        name: &str,
        folder: &str,
        machine: Option<&str>,
        focus: &SpaceFocus,
    ) -> Result<(Option<String>, Option<String>)> {
        let mut args = json!({ "name": name, "folder": folder });
        if let Some(m) = machine {
            args["machine"] = json!(m);
        }
        if *focus == SpaceFocus::Supported {
            args["focus"] = json!(false);
        }
        let v = self.run("space.new", &args)?;
        let pick = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
        Ok((pick("space"), pick("tab")))
    }
}

/// `space.new` が引数 `focus` を知っているか ([`HerdrApp::space_focus`])。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SpaceFocus {
    /// 知っている (herdr-app 0.1.16 から)。`"focus": false` を渡して画面を移さない。
    Supported,
    /// 知らない (0.1.15 まで)。渡さないので、画面は作った space に移る。
    Unsupported,
    /// `herdr-app commands` が落ちた・読めない (わけ)。渡さない。
    Unknown(String),
}

impl SpaceFocus {
    /// 渡せないときに出す 1 行 (渡すときは None)。
    pub fn note(&self) -> Option<String> {
        match self {
            Self::Supported => None,
            Self::Unsupported => Some(
                "note: herdr-app の版が space.new の focus を知らない (0.1.16 から) ので、画面は子の space に移る"
                    .to_owned(),
            ),
            Self::Unknown(why) => Some(format!(
                "note: herdr-app commands を読めない ({why}) ので space.new に focus を渡さない。画面は子の space に移る"
            )),
        }
    }

    /// `--dry-run` の space.new の行に添える句。
    pub fn dry_run_hint(&self) -> String {
        match self {
            Self::Supported => "focus: false。画面は移さない".to_owned(),
            Self::Unsupported => {
                "focus を渡さない (herdr-app の版が知らない)。画面は子の space に移る".to_owned()
            }
            Self::Unknown(why) => format!(
                "focus を渡さない (herdr-app commands を読めない: {why})。画面は子の space に移る"
            ),
        }
    }
}

/// herdr-app の id から、そのマシンの中の id (label に書く形) を取り出す: `<machine>/sp1` → `sp1`。
pub fn local_id(id: &str) -> &str {
    id.rsplit_once('/').map_or(id, |(_, rest)| rest)
}

/// herdr-app に渡す id。別のマシンの space なら `<m>/<id>` (spec §4)。
pub fn app_id(id: &str, machine: Option<&str>) -> String {
    match machine {
        Some(m) if !id.contains('/') => format!("{m}/{id}"),
        _ => id.to_owned(),
    }
}

/// 端末の住所をマシンと、そのマシンの中の住所に分ける: `<machine>/t13` → (Some("<machine>"), "t13")。
pub fn split_addr(addr: &str) -> (Option<&str>, &str) {
    match addr.rsplit_once('/') {
        Some((m, t)) => (Some(m), t),
        None => (None, addr),
    }
}

/// 端末の label の値。
pub fn label_of<'v>(term: &'v Value, key: &str) -> Option<&'v str> {
    term["labels"][key].as_str().filter(|v| !v.is_empty())
}

/// 端末の状態 (`status.state`。報告が無ければ None)。
pub fn state_of(term: &Value) -> Option<&str> {
    term["status"]["state"].as_str()
}

/// 端末が終わっているか (`state` が live でない)。
pub fn finished(term: &Value) -> bool {
    term["state"].as_str().is_some_and(|s| s != "live")
}

pub fn strings(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_owned()).collect()
}

/// `hc machine ls --json` の 1 台が手元の WSL か ([`is_wsl_target`])。名前は見ない (WSL の machine の名前は PC ごとに
/// 違う)。`pjp child` の `--on wsl` と自動の選び方が使う。pjp-hc-hub の `pjp hub hello` も同じ見分けを写して持つ (そちらの
/// テストがこの関数と突き合わせる)。
pub fn is_wsl_machine(m: &Value) -> bool {
    is_wsl_target(
        m["target"].as_str().unwrap_or_default(),
        m["via"].as_bool() == Some(true),
    )
}

/// machine の target が手元の WSL か。`--via` の machine (target が、ssh の代わりに打つコマンド) で、その最初の語 (引用符で
/// 囲んでいれば囲みの中) のパスの名前が wsl.exe か wsl なら WSL (`hc machine add --via 'wsl.exe -d Ubuntu-24.04 --cd ~ -e bash -lc'
/// --name <名前>` で足した machine の target は `wsl.exe -d Ubuntu-24.04 --cd ~ -e bash -lc`)。`--via` でない machine は、
/// `~/.ssh/config` の Host が wsl でも SSH 先。受け付ける形を変えたら、pjp-hc-hub の hello.rs の写し `is_wsl` と、それを突き合わせる
/// テスト `wsl_check_matches_pjp_child` の入力にも足す。
pub fn is_wsl_target(target: &str, via: bool) -> bool {
    if !via {
        return false;
    }
    let t = target.trim_start();
    let first = match t.chars().next() {
        Some(q @ ('"' | '\'')) => t[1..].split(q).next().unwrap_or_default(),
        _ => t.split_whitespace().next().unwrap_or_default(),
    };
    let base = first.rsplit(['/', '\\']).next().unwrap_or(first);
    base.eq_ignore_ascii_case("wsl.exe") || base.eq_ignore_ascii_case("wsl")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{Fake, OutputExt, fail, ok};

    #[test]
    fn exec_builds_hc_exec_and_reads_result() {
        let fake = Fake::new(|argv| {
            assert_eq!(
                argv.join(" "),
                "hc exec --json --on wsl1 --cwd /home/u/x --timeout 60 -- git -C /home/u/x status --short"
            );
            // stdout は base64 (" M a.txt\n")
            ok(
                r#"{"stdout":"IE0gYS50eHQK","stderr":"","code":0,"timed_out":false,"truncated":false,"ms":3}"#,
            )
        });
        let hc = Hc::new(&fake);
        let out = hc
            .exec(
                Some("wsl1"),
                Some("/home/u/x"),
                60,
                &["git", "-C", "/home/u/x", "status", "--short"],
            )
            .unwrap();
        assert!(out.ok());
        assert_eq!(out.stdout, " M a.txt\n");
    }

    #[test]
    fn hc_error_json_becomes_message() {
        let fake = Fake::new(|_| {
            fail(
                9,
                r#"{"error":{"kind":"blocked","message":"t7 is blocked","hint":"read it first"}}"#,
            )
        });
        let hc = Hc::new(&fake);
        let f = hc.send("t7", "hi").unwrap().unwrap_err();
        assert!(f.blocked());
        assert_eq!(f.message, "t7 is blocked (read it first)");
        let e = hc.json(&strings(&["get", "t7"])).unwrap_err();
        assert_eq!(
            e.message(),
            "hc get が落ちました: t7 is blocked (read it first)"
        );
    }

    #[test]
    fn get_missing_terminal_is_none() {
        let fake = Fake::new(|_| fail(3, r#"{"error":{"kind":"not_found","message":"no t9"}}"#));
        assert_eq!(Hc::new(&fake).get("t9").unwrap(), None);
    }

    #[test]
    fn missing_hc_is_config_error() {
        let fake = Fake::new(|_| ok("{}")).without("hc");
        assert_eq!(
            Hc::new(&fake).require().unwrap_err().code(),
            pjp_core::exit::CONFIG
        );
    }

    #[test]
    fn herdr_app_error_json_is_failure() {
        let fake = Fake::new(|argv| {
            assert_eq!(argv[..3], ["herdr-app", "do", "space.close"]);
            let v: Value = serde_json::from_str(&argv[3]).unwrap();
            assert_eq!(v, json!({"id": "wsl1/sp1", "confirmed": true}));
            fail(1, "").with_stdout(r#"{"error":"no such space"}"#)
        });
        let e = HerdrApp::new(&fake)
            .run("space.close", &json!({"id": "wsl1/sp1", "confirmed": true}))
            .unwrap_err();
        assert_eq!(e.message(), "herdr-app do space.close: no such space");
    }

    /// `hc connect` の stdin に書いた要求 (偽の Runner は stdin の中身を argv の最後に足す)。改行で終わる 1 行の JSON を読む。
    fn request_of(argv: &[String]) -> Value {
        let [hc, connect, line] = argv else {
            panic!("hc connect に stdin を 1 つ渡していない: {argv:?}");
        };
        assert_eq!([hc.as_str(), connect.as_str()], ["hc", "connect"]);
        assert!(
            line.ends_with('\n') && line.matches('\n').count() == 1,
            "1 行で書いていない: {line:?}"
        );
        serde_json::from_str(line).unwrap()
    }

    #[test]
    fn api_writes_one_jsonrpc_line_to_hc_connect() {
        let fake = Fake::new(|argv| {
            assert_eq!(
                request_of(argv),
                json!({"jsonrpc": "2.0", "id": 1, "method": "doc.get", "params": {"name": "herdr-app"}})
            );
            // hc 0.1.21 の core が、一度も書いていない doc に返した値
            ok("{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"value\":null,\"version\":0}}\n")
        });
        let v = Hc::new(&fake)
            .api("doc.get", &json!({"name": "herdr-app"}))
            .unwrap()
            .unwrap();
        assert_eq!(v, json!({"value": null, "version": 0}));
        assert_eq!(fake.timeouts(), [Some(HC_TIMEOUT)]);
    }

    #[test]
    fn api_error_reply_carries_kind_and_hint() {
        // hc 0.1.21 の core が、版の合わない doc.set に返した値
        let fake = Fake::new(|_| {
            ok(
                r#"{"error":{"code":-32000,"data":{"hint":"read doc.get and retry with its version","kind":"conflict"},"message":"document \"herdr-app\" is at version 1, not 0"},"id":1,"jsonrpc":"2.0"}"#,
            )
        });
        let f = Hc::new(&fake)
            .api("doc.set", &json!({"name": "herdr-app"}))
            .unwrap()
            .unwrap_err();
        assert_eq!(f.kind, "conflict");
        assert_eq!(
            f.message,
            "document \"herdr-app\" is at version 1, not 0 (read doc.get and retry with its version)"
        );
    }

    #[test]
    fn api_when_hc_connect_itself_fails_is_hcfail() {
        let fake = Fake::new(|_| {
            fail(
                1,
                r#"{"error":{"kind":"unavailable","message":"core does not answer"}}"#,
            )
        });
        let f = Hc::new(&fake)
            .api("doc.get", &json!({"name": "herdr-app"}))
            .unwrap()
            .unwrap_err();
        assert_eq!(
            (f.kind.as_str(), f.message.as_str()),
            ("unavailable", "core does not answer")
        );
    }

    #[test]
    fn api_without_its_reply_is_failure() {
        // 空・JSON でない・別の id の返り
        for stdout in [
            "",
            "not json\n",
            "{\"id\":2,\"jsonrpc\":\"2.0\",\"result\":{}}\n",
        ] {
            let fake = Fake::new(move |_| ok(stdout));
            let e = Hc::new(&fake)
                .api("doc.get", &json!({"name": "herdr-app"}))
                .unwrap_err();
            assert!(
                e.message().contains("hc connect"),
                "{stdout:?}: {}",
                e.message()
            );
        }
    }

    #[test]
    fn doc_get_and_doc_set() {
        let fake = Fake::new(|argv| {
            let req = request_of(argv);
            match req["method"].as_str() {
                Some("doc.get") => {
                    assert_eq!(req["params"], json!({"name": "herdr-app"}));
                    ok(r#"{"id":1,"jsonrpc":"2.0","result":{"value":{"spaces":[]},"version":66}}"#)
                }
                Some("doc.set") => {
                    assert_eq!(
                        req["params"],
                        json!({"name": "herdr-app", "value": {"spaces": [{"id": "sp1"}]}, "version": 66})
                    );
                    ok(r#"{"id":1,"jsonrpc":"2.0","result":{"version":67}}"#)
                }
                m => panic!("知らない method: {m:?}"),
            }
        });
        let hc = Hc::new(&fake);
        let doc = hc.doc_get("herdr-app", None).unwrap().unwrap();
        assert_eq!((doc.value, doc.version), (json!({"spaces": []}), 66));
        let version = hc
            .doc_set("herdr-app", None, &json!({"spaces": [{"id": "sp1"}]}), 66)
            .unwrap()
            .unwrap();
        assert_eq!(version, 67);
    }

    #[test]
    fn doc_on_another_machine_passes_on() {
        // doc.get・doc.set の on は別のマシンの core の doc (hc 0.1.21 の schema。省けばこの core)
        let fake = Fake::new(|argv| {
            let req = request_of(argv);
            assert_eq!(req["params"]["on"], "wsl1", "{req}");
            match req["method"].as_str() {
                Some("doc.get") => {
                    ok(r#"{"id":1,"jsonrpc":"2.0","result":{"value":{"spaces":[]},"version":3}}"#)
                }
                _ => ok(r#"{"id":1,"jsonrpc":"2.0","result":{"version":4}}"#),
            }
        });
        let hc = Hc::new(&fake);
        assert_eq!(
            hc.doc_get("herdr-app", Some("wsl1"))
                .unwrap()
                .unwrap()
                .version,
            3
        );
        assert_eq!(
            hc.doc_set("herdr-app", Some("wsl1"), &json!({"spaces": []}), 3)
                .unwrap()
                .unwrap(),
            4
        );
    }

    #[test]
    fn doc_get_without_version_is_failure() {
        let fake = Fake::new(|_| ok(r#"{"id":1,"jsonrpc":"2.0","result":{"value":{}}}"#));
        let e = Hc::new(&fake).doc_get("herdr-app", None).unwrap_err();
        assert!(e.message().contains("doc.get"), "{}", e.message());
    }

    #[test]
    fn base64_roundtrip() {
        use crate::testutil::base64_encode;
        // hc 0.1.21 の `hc exec --json` が実際に返した値
        assert_eq!(
            base64_decode("aG9tZT0vdG1wL2NsYXVkZS0xMDAwL3cyMmhjL2hvbWUKc2Vjb25kCg==").unwrap(),
            b"home=/tmp/claude-1000/w22hc/home\nsecond\n"
        );
        for s in ["", "a", "ab", "abc", "abcd", "日本語と絵文字 🌳\n"] {
            let enc = base64_encode(s.as_bytes());
            assert_eq!(base64_decode(&enc).unwrap(), s.as_bytes(), "{s:?} → {enc}");
            assert_eq!(
                base64_decode(enc.trim_end_matches('=')).unwrap(),
                s.as_bytes()
            );
        }
        assert_eq!(base64_decode("a"), None);
        assert_eq!(base64_decode("ab$d"), None);
        assert_eq!(base64_decode("a==="), None);
    }

    #[test]
    fn ids_and_addresses() {
        assert_eq!(local_id("wsl1/sp1"), "sp1");
        assert_eq!(local_id("sp1"), "sp1");
        assert_eq!(app_id("sp1", Some("wsl1")), "wsl1/sp1");
        assert_eq!(app_id("wsl1/sp1", Some("wsl1")), "wsl1/sp1");
        assert_eq!(app_id("sp1", None), "sp1");
        assert_eq!(split_addr("wsl1/t13"), (Some("wsl1"), "t13"));
        assert_eq!(split_addr("t8"), (None, "t8"));
    }

    #[test]
    fn wsl_machine_is_told_by_the_via_command_not_the_name() {
        let m = |name: &str, target: &str, via: bool| json!({"name": name, "target": target, "via": via, "state": "connected"});
        for wsl in [
            m("ubuntu", "wsl.exe -d Ubuntu-24.04 --cd ~ -e bash -lc", true),
            m("wsl1", "wsl.exe -d wsl1 --cd ~ -e bash -lc", true),
            m("wsl", "wsl -d Ubuntu -e sh -c", true),
        ] {
            assert!(is_wsl_machine(&wsl), "{wsl}");
        }
        for other in [
            // ~/.ssh/config の Host wsl (--via でない) と、wsl.exe でない --via
            m("wsl", "wsl", false),
            m("wsl", "ssh -p 2222 box.local", true),
            m("host-a", "host-a.local", false),
            // target・via の無い答え
            json!({"name": "x", "state": "connected"}),
        ] {
            assert!(!is_wsl_machine(&other), "{other}");
        }
    }
}
