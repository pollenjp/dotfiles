//! 単体の試験で使う道具: 一時ディレクトリ (crate を足さない。drop で消す) と、外のコマンドの偽の口 (`FakeSys`)。

use crate::process::{CommandSpec, RunResult, Sys};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

type Responder = Box<dyn Fn(&CommandSpec) -> RunResult>;

/// 外のコマンドの偽の口。打たれたコマンドを控え、`responder` が返す結果を返す (出力の行は `on_line` にも流す)。
pub struct FakeSys {
    responder: Responder,
    programs: BTreeMap<String, PathBuf>,
    env: BTreeMap<String, String>,
    pub calls: RefCell<Vec<CommandSpec>>,
}

impl FakeSys {
    pub fn new(responder: impl Fn(&CommandSpec) -> RunResult + 'static) -> Self {
        FakeSys {
            responder: Box::new(responder),
            programs: BTreeMap::new(),
            env: BTreeMap::new(),
            calls: RefCell::new(Vec::new()),
        }
    }

    /// `which(name)` が返すパス
    pub fn with_program(mut self, name: &str, path: &str) -> Self {
        self.programs.insert(name.to_string(), PathBuf::from(path));
        self
    }

    pub fn with_env(mut self, name: &str, value: &str) -> Self {
        self.env.insert(name.to_string(), value.to_string());
        self
    }

    /// 打たれたコマンドの引数 (1 つの文字列に並べたもの)
    pub fn call_args(&self) -> Vec<String> {
        self.calls
            .borrow()
            .iter()
            .map(|c| c.args_lossy().join(" "))
            .collect()
    }
}

impl Sys for FakeSys {
    fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult {
        self.calls.borrow_mut().push(spec.clone());
        let r = (self.responder)(spec);
        for l in &r.output {
            on_line(l);
        }
        r
    }

    fn which(&self, name: &str) -> Option<PathBuf> {
        self.programs.get(name).cloned()
    }

    fn env(&self, name: &str) -> Option<String> {
        self.env.get(name).cloned()
    }
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(tag: &str) -> Self {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "dotfiles-win-{tag}-{}-{n}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).expect("一時ディレクトリを作れない");
        TempDir(dir)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }

    /// `rel` (`/` 区切り) にファイルを書く。親のディレクトリも作る。
    pub fn write(&self, rel: &str, content: &str) -> PathBuf {
        let mut p = self.0.clone();
        for seg in rel.split('/') {
            p.push(seg);
        }
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, content).unwrap();
        p
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
