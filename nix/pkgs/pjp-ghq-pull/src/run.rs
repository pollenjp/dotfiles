//! 実行中の画面の model。作業の列からの知らせ (Msg) とキーを受け、作業の列への指示 (Effect) を返す。描くのは
//! ui::draw_run。
//!
//! 問いは来た順に確認待ちに並ぶ。答えのキーは確認待ちの欄に focus があるときだけ、今の問いで選べるものだけ効く
//! (一覧を見ている間に打ったキーで merge などを流さないため)。答えると、その repo の続きを作業の列に積み、次の問いへ移る。
//! q・Ctrl-C は、確認待ちとまだ始めていない repo を「スキップ」にし、動いている git が終わるのを待ってから閉じる
//! (git を途中で止めると index.lock や途中の merge が残るため。通信は時間切れで必ず終わる)。

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::flow::{Choice, Outcome, Phase, Question};
use crate::runner::{Job, Msg};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    Queued,
    Working(Phase),
    Waiting(Question),
    Final(Outcome),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Focus {
    List,
    Questions,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    /// 作業の列に積む
    Enqueue(Job),
    /// まだ始めていない作業を列から外し、その番号を on_drained へ渡す
    Drain,
    /// 画面を閉じる
    Exit,
}

pub struct Run {
    labels: Vec<String>,
    statuses: Vec<Status>,
    /// 確認待ちの repo の番号 (来た順)
    waiting: Vec<usize>,
    q_cursor: usize,
    list_cursor: usize,
    focus: Focus,
    show_detail: bool,
    quitting: bool,
}

impl Run {
    pub fn new(labels: Vec<String>) -> Run {
        let statuses = vec![Status::Queued; labels.len()];
        Run {
            labels,
            statuses,
            waiting: Vec::new(),
            q_cursor: 0,
            list_cursor: 0,
            focus: Focus::Questions,
            show_detail: false,
            quitting: false,
        }
    }

    pub fn labels(&self) -> &[String] {
        &self.labels
    }

    pub fn status(&self, id: usize) -> &Status {
        &self.statuses[id]
    }

    pub fn focus(&self) -> Focus {
        self.focus
    }

    pub fn show_detail(&self) -> bool {
        self.show_detail
    }

    pub fn quitting(&self) -> bool {
        self.quitting
    }

    pub fn list_cursor(&self) -> usize {
        self.list_cursor
    }

    /// 確認待ちの repo の番号 (来た順) と、そのうち今の問いの位置
    pub fn waiting_ids(&self) -> (&[usize], usize) {
        (&self.waiting, self.q_cursor)
    }

    pub fn current_question(&self) -> Option<(usize, &Question)> {
        let id = *self.waiting.get(self.q_cursor)?;
        match &self.statuses[id] {
            Status::Waiting(q) => Some((id, q)),
            _ => None,
        }
    }

    pub fn done(&self) -> usize {
        self.statuses
            .iter()
            .filter(|s| matches!(s, Status::Final(_)))
            .count()
    }

    pub fn waiting(&self) -> usize {
        self.waiting.len()
    }

    pub fn finished(&self) -> bool {
        self.done() == self.statuses.len()
    }

    /// 各 repo の名前と結果 (終わっていない repo はスキップとして返す)
    pub fn outcomes(&self) -> Vec<(String, Outcome)> {
        self.labels
            .iter()
            .zip(&self.statuses)
            .map(|(label, status)| {
                let outcome = match status {
                    Status::Final(o) => o.clone(),
                    Status::Waiting(q) => Outcome::Skipped {
                        reason: q.reason.label(),
                    },
                    _ => Outcome::Skipped {
                        reason: "終わらなかった".into(),
                    },
                };
                (label.clone(), outcome)
            })
            .collect()
    }

    pub fn on_msg(&mut self, msg: Msg) -> Vec<Effect> {
        match msg {
            Msg::Phase(id, phase) => {
                if !matches!(self.statuses[id], Status::Final(_)) {
                    self.statuses[id] = Status::Working(phase);
                }
            }
            Msg::Done(id, Outcome::Ask(q)) if self.quitting => {
                self.statuses[id] = Status::Final(Outcome::Skipped {
                    reason: q.reason.label(),
                });
            }
            Msg::Done(id, Outcome::Ask(q)) => {
                self.statuses[id] = Status::Waiting(q);
                self.waiting.push(id);
            }
            Msg::Done(id, outcome) => self.statuses[id] = Status::Final(outcome),
        }
        self.exit_if_quit_and_done()
    }

    /// Effect::Drain で列から外した repo をスキップにする
    pub fn on_drained(&mut self, ids: &[usize]) -> Vec<Effect> {
        for &id in ids {
            self.statuses[id] = Status::Final(Outcome::Skipped {
                reason: "やめたので始めなかった".into(),
            });
        }
        self.exit_if_quit_and_done()
    }

    pub fn on_key(&mut self, key: KeyEvent) -> Vec<Effect> {
        let ctrl_c =
            key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c');
        if ctrl_c || key.code == KeyCode::Char('q') {
            return self.quit();
        }
        if self.finished() && matches!(key.code, KeyCode::Enter | KeyCode::Esc) {
            return vec![Effect::Exit];
        }
        match key.code {
            KeyCode::Tab | KeyCode::BackTab => {
                self.focus = match self.focus {
                    Focus::List => Focus::Questions,
                    Focus::Questions => Focus::List,
                };
            }
            KeyCode::Up | KeyCode::Char('k') => self.move_by(-1),
            KeyCode::Down | KeyCode::Char('j') => self.move_by(1),
            KeyCode::Char('d') if self.focus == Focus::Questions => {
                self.show_detail = !self.show_detail;
            }
            KeyCode::Char(c) if self.focus == Focus::Questions => return self.answer(c),
            _ => {}
        }
        Vec::new()
    }

    fn quit(&mut self) -> Vec<Effect> {
        if self.finished() {
            return vec![Effect::Exit];
        }
        if self.quitting {
            return Vec::new();
        }
        self.quitting = true;
        for id in std::mem::take(&mut self.waiting) {
            if let Status::Waiting(q) = &self.statuses[id] {
                self.statuses[id] = Status::Final(Outcome::Skipped {
                    reason: q.reason.label(),
                });
            }
        }
        self.q_cursor = 0;
        vec![Effect::Drain]
    }

    fn answer(&mut self, key: char) -> Vec<Effect> {
        let Some((id, q)) = self.current_question() else {
            return Vec::new();
        };
        let Some(choice) = q.choices.iter().copied().find(|c| c.key() == key) else {
            return Vec::new();
        };
        let q = q.clone();
        self.waiting.remove(self.q_cursor);
        self.q_cursor = self.q_cursor.min(self.waiting.len().saturating_sub(1));
        if choice == Choice::Skip {
            self.statuses[id] = Status::Final(Outcome::Skipped {
                reason: q.reason.label(),
            });
            return Vec::new();
        }
        self.statuses[id] = Status::Queued;
        vec![Effect::Enqueue(Job::Answer(id, q, choice))]
    }

    fn move_by(&mut self, delta: isize) {
        let (cursor, len) = match self.focus {
            Focus::List => (&mut self.list_cursor, self.statuses.len()),
            Focus::Questions => (&mut self.q_cursor, self.waiting.len()),
        };
        *cursor = cursor
            .saturating_add_signed(delta)
            .min(len.saturating_sub(1));
    }

    fn exit_if_quit_and_done(&self) -> Vec<Effect> {
        if self.quitting && self.finished() {
            vec![Effect::Exit]
        } else {
            Vec::new()
        }
    }
}
