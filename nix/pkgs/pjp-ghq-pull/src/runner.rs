//! 作業の列。workers 本の thread が列から作業を取り、進み具合と結果を channel で画面へ送る。
//! 1 つの repo の作業は、前の作業の結果 (問い) に答えたときにしか積まれないので、1 つの repo に git が 2 本同時に
//! 流れることは無い。drain は、まだ始めていない作業だけを列から外す (動いている作業は止めない)。

use std::collections::VecDeque;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};

use crate::flow::{Choice, Outcome, Phase, Question};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Job {
    /// repo の番号。判定から始める
    Start(usize),
    /// repo の番号と、問いと答え
    Answer(usize, Question, Choice),
}

impl Job {
    pub fn id(&self) -> usize {
        match self {
            Job::Start(id) | Job::Answer(id, ..) => *id,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Msg {
    Phase(usize, Phase),
    Done(usize, Outcome),
}

/// 1 つの作業を流す関数 (ふだんは flow::start / flow::answer。テストは偽物)
pub type Work = Arc<dyn Fn(&Job, &dyn Fn(Phase)) -> Outcome + Send + Sync>;

#[derive(Default)]
struct Queue {
    jobs: VecDeque<Job>,
    closed: bool,
}

pub struct Runner {
    shared: Arc<(Mutex<Queue>, Condvar)>,
    workers: Vec<JoinHandle<()>>,
}

impl Runner {
    pub fn spawn(workers: usize, work: Work, tx: Sender<Msg>) -> Runner {
        let shared = Arc::new((Mutex::new(Queue::default()), Condvar::new()));
        let workers = (0..workers.max(1))
            .map(|_| {
                let shared = Arc::clone(&shared);
                let work = Arc::clone(&work);
                let tx = tx.clone();
                thread::spawn(move || {
                    while let Some(job) = next(&shared) {
                        let id = job.id();
                        let phase_tx = tx.clone();
                        let phase = move |p: Phase| {
                            let _ = phase_tx.send(Msg::Phase(id, p));
                        };
                        let outcome = catch_unwind(AssertUnwindSafe(|| work(&job, &phase)))
                            .unwrap_or_else(|payload| Outcome::Failed {
                                what: "pjp-ghq-pull の内部のエラーで止まった".into(),
                                stderr: panic_text(payload.as_ref()),
                                conflict: false,
                            });
                        let _ = tx.send(Msg::Done(id, outcome));
                    }
                })
            })
            .collect();
        Runner { shared, workers }
    }

    pub fn push(&self, job: Job) {
        let (lock, cv) = &*self.shared;
        if let Ok(mut q) = lock.lock() {
            q.jobs.push_back(job);
            cv.notify_one();
        }
    }

    /// まだ始めていない作業を列から外し、その repo の番号を返す
    pub fn drain(&self) -> Vec<usize> {
        let (lock, _) = &*self.shared;
        lock.lock()
            .map(|mut q| q.jobs.drain(..).map(|j| j.id()).collect())
            .unwrap_or_default()
    }

    /// 列を閉じ、動いている作業が終わるのを待つ
    pub fn shutdown(self) {
        {
            let (lock, cv) = &*self.shared;
            if let Ok(mut q) = lock.lock() {
                q.closed = true;
            }
            cv.notify_all();
        }
        for w in self.workers {
            let _ = w.join();
        }
    }
}

/// panic の文 (panic!("…") の文字列)
fn panic_text(payload: &(dyn std::any::Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|s| s.to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_default()
}

/// 次の作業を取る。列が空で閉じていれば None
fn next(shared: &(Mutex<Queue>, Condvar)) -> Option<Job> {
    let (lock, cv) = shared;
    let mut q = lock.lock().ok()?;
    loop {
        if let Some(job) = q.jobs.pop_front() {
            return Some(job);
        }
        if q.closed {
            return None;
        }
        q = cv.wait(q).ok()?;
    }
}
