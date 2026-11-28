//! テストの小さな道具: 偽の [`Runner`] と一時ディレクトリと、偽の core の doc herdr-app ([`DocSim`])。

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use pjp_core::process::{Cmd, Output};
use pjp_core::time::Timestamp;
use pjp_core::{Error, Result};
use serde_json::{Value, json};

use crate::hc::Runner;

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// テストごとの一時ディレクトリ。Drop で消す。
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(name: &str) -> Self {
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!(
            "pjp-hc-child-test-{}-{n}-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("一時ディレクトリを作れない");
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// `rel` (`/` 区切り) にファイルを書く。親のディレクトリも作る。
    pub fn write(&self, rel: &str, contents: impl AsRef<[u8]>) -> PathBuf {
        let p = rel.split('/').fold(self.path.clone(), |p, c| p.join(c));
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, contents).unwrap();
        p
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

pub fn ok(stdout: &str) -> Output {
    Output {
        code: Some(0),
        stdout: stdout.to_owned(),
        stderr: String::new(),
        timed_out: false,
    }
}

pub fn fail(code: i32, stderr: &str) -> Output {
    Output {
        code: Some(code),
        stdout: String::new(),
        stderr: stderr.to_owned(),
        timed_out: false,
    }
}

/// `hc exec --json` の答え (ExecResult。本物と同じく stdout・stderr は base64)。
pub fn exec_ok(stdout: &str) -> Output {
    exec_result(0, stdout, "")
}

pub fn exec_result(code: i32, stdout: &str, stderr: &str) -> Output {
    ok(&serde_json::json!({
        "stdout": base64_encode(stdout.as_bytes()),
        "stderr": base64_encode(stderr.as_bytes()),
        "code": code,
        "timed_out": false,
        "truncated": false,
        "ms": 1,
    })
    .to_string())
}

/// base64 (RFC 4648 の標準の字と `=` の埋め)。
pub fn base64_encode(bytes: &[u8]) -> String {
    const ABC: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let mut n = 0u32;
        for (i, &b) in chunk.iter().enumerate() {
            n |= u32::from(b) << (16 - 8 * i);
        }
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(char::from(ABC[((n >> (18 - 6 * i)) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

pub trait OutputExt {
    fn with_stdout(self, stdout: &str) -> Output;
}

impl OutputExt for Output {
    fn with_stdout(mut self, stdout: &str) -> Output {
        self.stdout = stdout.to_owned();
        self
    }
}

type Respond = Box<dyn Fn(&[String]) -> Output>;

/// 偽の Runner。打たれた argv (program と引数) を控え、閉包で答える。stdin を渡したコマンド (`hc connect`) は、stdin の
/// 中身 (UTF-8 として読んだもの) を argv の最後に 1 つ足して控え、閉包にもそう渡す (`["hc", "connect", "<要求の 1 行>\n"]`)。
pub struct Fake {
    respond: Respond,
    calls: RefCell<Vec<Vec<String>>>,
    /// 打たれたコマンドごとの時間切れ (`calls` と同じ順)。
    timeouts: RefCell<Vec<Option<Duration>>>,
    missing: HashSet<String>,
    env: HashMap<String, String>,
    cwd: PathBuf,
    now: Timestamp,
    /// `now` に足す秒 (テストが進める。[`Fake::clock`])。
    clock: Rc<Cell<i64>>,
    slept: RefCell<Vec<Duration>>,
    /// `read_stdin` の答え (None は stdin が端末)。
    stdin: Option<Vec<u8>>,
    /// `random_u128` が次に返す値 (1 から 1 つずつ進む。id を決まった値にする)。
    ids: Cell<u128>,
    /// private な足し分 (pjp-skills) があるか (既定は無い。[`Fake::with_extras`])。
    extras: bool,
    dir: TempDir,
}

impl Fake {
    pub fn new(respond: impl Fn(&[String]) -> Output + 'static) -> Self {
        let dir = TempDir::new("fake");
        Self {
            respond: Box::new(respond),
            calls: RefCell::default(),
            timeouts: RefCell::default(),
            missing: HashSet::new(),
            env: HashMap::new(),
            cwd: dir.path().join("cwd"),
            // 2026-11-16T10:05:00+09:00
            now: Timestamp {
                secs: 1_794_791_100,
                nanos: 0,
            },
            clock: Rc::default(),
            slept: RefCell::default(),
            stdin: None,
            ids: Cell::new(1),
            extras: false,
            dir,
        }
    }

    /// private な足し分 (pjp-skills) があることにする。
    pub fn with_extras(mut self) -> Self {
        self.extras = true;
        self
    }

    /// その program を PATH に無いことにする。
    pub fn without(mut self, program: &str) -> Self {
        self.missing.insert(program.to_owned());
        self
    }

    pub fn env(mut self, key: &str, value: &str) -> Self {
        self.env.insert(key.to_owned(), value.to_owned());
        self
    }

    pub fn cwd(mut self, dir: &Path) -> Self {
        self.cwd = dir.to_path_buf();
        self
    }

    /// `now` を進める秒の入れ物 (閉包からも進められるよう、外で作って渡す。渡さなければ時刻は進まない)。
    pub fn clock(mut self, clock: Rc<Cell<i64>>) -> Self {
        self.clock = clock;
        self
    }

    /// stdin に流れてくるバイト (渡さなければ stdin は端末)。
    pub fn stdin(mut self, bytes: &[u8]) -> Self {
        self.stdin = Some(bytes.to_vec());
        self
    }

    /// 打たれたコマンドごとの時間切れ。
    pub fn timeouts(&self) -> Vec<Option<Duration>> {
        self.timeouts.borrow().clone()
    }

    pub fn calls(&self) -> Vec<Vec<String>> {
        self.calls.borrow().clone()
    }

    /// 打たれた argv を空白でつないだもの。
    pub fn lines(&self) -> Vec<String> {
        self.calls.borrow().iter().map(|c| c.join(" ")).collect()
    }

    pub fn slept(&self) -> Vec<Duration> {
        self.slept.borrow().clone()
    }

    pub fn base(&self) -> &Path {
        self.dir.path()
    }
}

impl Runner for Fake {
    fn run(&self, cmd: &Cmd) -> Result<Output> {
        let program = cmd.program().to_string_lossy().into_owned();
        let mut argv = vec![program.clone()];
        argv.extend(
            cmd.get_args()
                .iter()
                .map(|a| a.to_string_lossy().into_owned()),
        );
        if let Some(input) = cmd.get_stdin() {
            argv.push(String::from_utf8_lossy(input).into_owned());
        }
        self.calls.borrow_mut().push(argv.clone());
        self.timeouts.borrow_mut().push(cmd.get_timeout());
        if self.missing.contains(&program) {
            return Err(Error::config(format!(
                "{program} が見つかりません (PATH を確かめてください)"
            )));
        }
        Ok((self.respond)(&argv))
    }

    fn which(&self, name: &str) -> Option<PathBuf> {
        (!self.missing.contains(name)).then(|| PathBuf::from(format!("/fake/bin/{name}")))
    }

    fn env(&self, key: &str) -> Option<String> {
        self.env.get(key).filter(|v| !v.is_empty()).cloned()
    }

    fn cwd(&self) -> Result<PathBuf> {
        Ok(self.cwd.clone())
    }

    fn now(&self) -> Result<Timestamp> {
        Ok(Timestamp {
            secs: self.now.secs + self.clock.get(),
            nanos: self.now.nanos,
        })
    }

    fn sleep(&self, d: Duration) {
        self.slept.borrow_mut().push(d);
    }

    fn state_dir(&self) -> Result<PathBuf> {
        Ok(self.dir.path().join("state").join("pjp"))
    }

    fn config_dir(&self) -> Result<PathBuf> {
        Ok(self.dir.path().join("config").join("pjp"))
    }

    fn skill_roots(&self) -> Result<Vec<PathBuf>> {
        Ok(vec![self.dir.path().join("skills")])
    }

    fn read_stdin(&self) -> Result<Option<Vec<u8>>> {
        Ok(self.stdin.clone())
    }

    fn random_u128(&self) -> u128 {
        let n = self.ids.get();
        self.ids.set(n + 1);
        n
    }

    fn extras(&self) -> bool {
        self.extras
    }
}

/// 偽の hc の core の doc herdr-app と、それを読み書きする偽の herdr-app。`hc connect` に書かれた 1 行の要求
/// (doc.get・doc.set) に、hc 0.1.21 の core と同じ形で答える。
///
/// 偽の herdr-app が動いていれば ([`DocSim::running`])、label `herdr.space`・`herdr.tab` の付いた端末が立つと、その space・tab に
/// ペインを置き (知らない id なら space・tab を作る。doc にもうその端末のペインがあれば置かない)、
/// 端末が消えるとペインを外し、空になった tab と space を消す (E10)。どちらも `lag` 回の doc.get に答えてから書く (herdr-app が
/// 少し遅れて書くのを真似る)。
#[derive(Debug, Default)]
pub struct DocSim {
    pub value: Value,
    pub version: u64,
    /// doc.get・doc.set の `on` に来るはずの値 (None なら `on` を渡さない)。違えば panic。
    pub on: Option<String>,
    /// 偽の herdr-app が動いているか。
    pub app: bool,
    /// 偽の herdr-app が書く前に答える doc.get の回数。
    pub lag: u32,
    /// この先の doc.set を conflict で断る回数。断るとき、偽の herdr-app の書き待ちがあれば先に書かせ (無ければ版だけ進める)、
    /// ほかの書き手が先に書いたことにする。
    pub conflicts: u32,
    /// doc.get に返す error の `data.kind` (None なら値を返す)。
    pub get_error: Option<&'static str>,
    /// 初めのこの回数の doc.get を、`unavailable` の error で断る (core が一時的に答えない)。
    pub get_fails: u32,
    /// doc.set に返す error の `data.kind` (版が合っていても返す)。
    pub set_error: Option<&'static str>,
    /// 偽の herdr-app が、終えただけ (`hc kill`) の端末のペインもすぐ外すか (確かめていない振る舞い。子のテストの偽の hc が見る)。
    pub drop_on_kill: bool,
    /// 偽の herdr-app の書き待ち (あと何回の doc.get で書くか、書くこと)。`..DocSim::at(…)` で作れるよう pub にしてある。
    pub pending: Vec<(u32, AppWrite)>,
    /// 偽の herdr-app が作ったペインの数 (ペインの id に使う)。
    pub panes: u32,
}

/// 偽の herdr-app が doc に書くこと。
#[derive(Debug, Clone)]
pub enum AppWrite {
    /// label の付いた端末が立った: その space・tab にペインを置く。
    Place {
        space: String,
        tab: String,
        terminal: String,
        folder: String,
    },
    /// 端末が消えた: ペインを外す。
    Drop { terminal: String },
}

impl DocSim {
    /// 値と版の doc (偽の herdr-app は動いていない)。
    pub fn at(value: Value, version: u64) -> Self {
        Self {
            value,
            version,
            ..Self::default()
        }
    }

    /// 偽の herdr-app を動かす (`lag` 回の doc.get の後に書く)。
    pub fn running(mut self, lag: u32) -> Self {
        self.app = true;
        self.lag = lag;
        self
    }

    /// doc.get・doc.set に `on` で来るマシン。
    pub fn on(mut self, machine: &str) -> Self {
        self.on = Some(machine.to_owned());
        self
    }

    /// label `herdr.space`・`herdr.tab` の付いた端末が立った (偽の herdr-app が動いていれば、ペインを置く)。
    pub fn placed(&mut self, space: &str, tab: &str, terminal: &str, folder: &str) {
        if self.app {
            self.pending.push((
                self.lag,
                AppWrite::Place {
                    space: space.to_owned(),
                    tab: tab.to_owned(),
                    terminal: terminal.to_owned(),
                    folder: folder.to_owned(),
                },
            ));
        }
    }

    /// 端末が消えた (偽の herdr-app が動いていれば、ペインを外し、空の space を消す)。
    pub fn removed(&mut self, terminal: &str) {
        if self.app {
            self.pending.push((
                self.lag,
                AppWrite::Drop {
                    terminal: terminal.to_owned(),
                },
            ));
        }
    }

    /// id の space (無ければ None)。
    pub fn space(&self, id: &str) -> Option<&Value> {
        self.value["spaces"]
            .as_array()?
            .iter()
            .find(|sp| sp["id"] == id)
    }

    /// space の id を doc の並びで。
    pub fn space_ids(&self) -> Vec<String> {
        self.value["spaces"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|sp| sp["id"].as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// 書き待ちのうち、もう書く番のものを書き、ほかは 1 つ近づける (doc.get に答える前)。
    fn tick(&mut self) {
        let mut later = Vec::new();
        for (n, w) in std::mem::take(&mut self.pending) {
            if n == 0 {
                self.write(&w);
            } else {
                later.push((n - 1, w));
            }
        }
        self.pending = later;
    }

    /// 書き待ちを全部すぐに書く (ほかの書き手が先に書いた)。何も書かなければ false。
    fn flush(&mut self) -> bool {
        let all = std::mem::take(&mut self.pending);
        let wrote = !all.is_empty();
        for (_, w) in all {
            self.write(&w);
        }
        wrote
    }

    fn write(&mut self, w: &AppWrite) {
        if self.value.is_null() {
            self.value = json!({"spaces": []});
        }
        let Some(spaces) = self.value["spaces"].as_array_mut() else {
            return;
        };
        match w {
            AppWrite::Place {
                space,
                tab,
                terminal,
                folder,
            } => {
                // もうどこかの space にその端末のペインがあれば、置かない (doc に置いた端末を herdr-app は拾う。E7)
                let placed = spaces.iter().any(|sp| {
                    sp["tabs"].as_array().is_some_and(|tabs| {
                        tabs.iter().any(|tb| {
                            tb["root"]["children"].as_array().is_some_and(|c| {
                                c.iter().any(|b| b["content"]["terminal"] == *terminal)
                            })
                        })
                    })
                });
                if placed {
                    return;
                }
                self.panes += 1;
                let block = json!({"content": {"terminal": terminal}, "id": format!("pane{}", self.panes), "type": "block"});
                let new_tab = || json!({"id": tab, "name": "", "root": {"children": [], "id": tab, "type": "row"}});
                let sp = match spaces.iter_mut().position(|sp| sp["id"] == *space) {
                    Some(i) => &mut spaces[i],
                    None => {
                        spaces.push(json!({"folder": folder, "id": space, "name": "", "tabs": []}));
                        let last = spaces.len() - 1;
                        &mut spaces[last]
                    }
                };
                let tabs = sp["tabs"].as_array_mut().expect("tabs の配列");
                let tb = match tabs.iter_mut().position(|t| t["id"] == *tab) {
                    Some(i) => &mut tabs[i],
                    None => {
                        tabs.push(new_tab());
                        let last = tabs.len() - 1;
                        &mut tabs[last]
                    }
                };
                tb["root"]["children"]
                    .as_array_mut()
                    .expect("children の配列")
                    .push(block);
            }
            AppWrite::Drop { terminal } => {
                for sp in spaces.iter_mut() {
                    if let Some(tabs) = sp["tabs"].as_array_mut() {
                        for tb in tabs.iter_mut() {
                            if let Some(children) = tb["root"]["children"].as_array_mut() {
                                children.retain(|b| b["content"]["terminal"] != *terminal);
                            }
                        }
                        tabs.retain(|tb| {
                            tb["root"]["children"]
                                .as_array()
                                .is_some_and(|c| !c.is_empty())
                        });
                    }
                }
                spaces.retain(|sp| sp["tabs"].as_array().is_some_and(|t| !t.is_empty()));
            }
        }
        self.version += 1;
    }

    /// `hc connect` の stdin の 1 行に答える。
    pub fn answer(&mut self, input: &str) -> Output {
        let req: Value = serde_json::from_str(input).expect("要求の 1 行が JSON でない");
        let reply = |mut body: Value| {
            body["id"] = req["id"].clone();
            body["jsonrpc"] = json!("2.0");
            ok(&format!("{body}\n"))
        };
        let error = |kind: &str, message: String| {
            reply(
                json!({"error": {"code": -32000, "data": {"kind": kind, "hint": "see `hc schema`"}, "message": message}}),
            )
        };
        let params = &req["params"];
        assert_eq!(params["name"], "herdr-app", "doc の名前: {params}");
        assert_eq!(
            params.get("on").and_then(Value::as_str),
            self.on.as_deref(),
            "doc の on: {params}"
        );
        match req["method"].as_str().unwrap_or_default() {
            "doc.get" => {
                if self.get_fails > 0 {
                    self.get_fails -= 1;
                    return error("unavailable", "the core is busy".to_owned());
                }
                self.tick();
                match self.get_error {
                    Some(kind) => error(kind, format!("doc.get: {kind}")),
                    None => {
                        reply(json!({"result": {"value": self.value, "version": self.version}}))
                    }
                }
            }
            "doc.set" => {
                if let Some(kind) = self.set_error {
                    return error(kind, format!("doc.set: {kind}"));
                }
                if self.conflicts > 0 {
                    self.conflicts -= 1;
                    if !self.flush() {
                        self.version += 1;
                    }
                }
                if params["version"].as_u64() != Some(self.version) {
                    return error(
                        "conflict",
                        format!(
                            "document \"herdr-app\" is at version {}, not {}",
                            self.version, params["version"]
                        ),
                    );
                }
                self.value = params["value"].clone();
                self.version += 1;
                reply(json!({"result": {"version": self.version}}))
            }
            m => reply(
                json!({"error": {"code": -32601, "data": {"kind": "unknown_method"}, "message": format!("unknown method {m:?}")}}),
            ),
        }
    }
}

/// `hc connect` に書いた要求 (偽の Runner は stdin の中身を argv の最後に足す)。
pub fn rpc_calls(f: &Fake) -> Vec<Value> {
    f.calls()
        .into_iter()
        .filter(|c| c.len() == 3 && c[0] == "hc" && c[1] == "connect")
        .map(|c| serde_json::from_str(&c[2]).expect("要求の 1 行が JSON でない"))
        .collect()
}

/// `hc connect` に書いた要求の method の並び。
pub fn rpc_methods(f: &Fake) -> Vec<String> {
    rpc_calls(f)
        .iter()
        .map(|r| r["method"].as_str().unwrap_or_default().to_owned())
        .collect()
}
