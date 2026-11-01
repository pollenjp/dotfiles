//! 選ぶ画面の model。repo を org (host/owner) ごとの木にまとめ、キーで on/off する。描くのは ui::draw_select。
//!
//! org の印は、下の repo が全部 on なら [x]、一部なら [-]、全部 off なら [ ] (絞り込みによらず org の全部で決める)。
//! 絞り込み (/) は repo の相対パスに大文字小文字を区別せずに含むもので、a / n と org の行の Space は絞り込んだ repo
//! だけに効く。

use std::collections::HashSet;
use std::path::PathBuf;

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::repo::Info;

/// PageUp / PageDown で動く行の数
const PAGE: usize = 10;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    pub path: PathBuf,
    pub rel: String,
    pub org: String,
    pub name: String,
    pub info: Info,
    pub selected: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Org {
    pub name: String,
    /// items の番号
    pub items: Vec<usize>,
    pub expanded: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Row {
    /// orgs の番号
    Org(usize),
    /// items の番号
    Repo(usize),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mark {
    All,
    Partial,
    None,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    None,
    Start,
    Quit,
}

#[derive(Clone, Debug)]
pub struct Selection {
    items: Vec<Item>,
    orgs: Vec<Org>,
    cursor: usize,
    filter: String,
    editing: bool,
    notice: Option<String>,
}

impl Selection {
    /// org の名前順・repo の名前順に並べる。org は開いた状態で始める
    pub fn new(mut items: Vec<Item>) -> Selection {
        items.sort_by(|a, b| a.org.cmp(&b.org).then_with(|| a.name.cmp(&b.name)));
        let mut orgs: Vec<Org> = Vec::new();
        for (i, item) in items.iter().enumerate() {
            match orgs.last_mut() {
                Some(org) if org.name == item.org => org.items.push(i),
                _ => orgs.push(Org {
                    name: item.org.clone(),
                    items: vec![i],
                    expanded: true,
                }),
            }
        }
        Selection {
            items,
            orgs,
            cursor: 0,
            filter: String::new(),
            editing: false,
            notice: None,
        }
    }

    /// 前回外していた repo (deselected) を off、ほかを on にして始める
    pub fn with_deselected(mut items: Vec<Item>, deselected: &HashSet<PathBuf>) -> Selection {
        for item in &mut items {
            item.selected = !deselected.contains(&item.path);
        }
        Selection::new(items)
    }

    pub fn items(&self) -> &[Item] {
        &self.items
    }

    pub fn orgs(&self) -> &[Org] {
        &self.orgs
    }

    pub fn cursor(&self) -> usize {
        self.cursor
    }

    pub fn filter(&self) -> &str {
        &self.filter
    }

    pub fn editing_filter(&self) -> bool {
        self.editing
    }

    pub fn notice(&self) -> Option<&str> {
        self.notice.as_deref()
    }

    fn matches(&self, item: usize) -> bool {
        self.filter.is_empty()
            || self.items[item]
                .rel
                .to_lowercase()
                .contains(&self.filter.to_lowercase())
    }

    /// 絞り込みに合う、org の下の repo
    fn targets(&self, org: usize) -> Vec<usize> {
        self.orgs[org]
            .items
            .iter()
            .copied()
            .filter(|&i| self.matches(i))
            .collect()
    }

    /// 画面に並ぶ行 (絞り込みに合う repo が無い org は出さない。畳んだ org の repo は出さない)
    pub fn rows(&self) -> Vec<Row> {
        let mut rows = Vec::new();
        for (o, org) in self.orgs.iter().enumerate() {
            let targets = self.targets(o);
            if targets.is_empty() {
                continue;
            }
            rows.push(Row::Org(o));
            if org.expanded {
                rows.extend(targets.into_iter().map(Row::Repo));
            }
        }
        rows
    }

    pub fn mark(&self, org: usize) -> Mark {
        let items = &self.orgs[org].items;
        let on = items.iter().filter(|&&i| self.items[i].selected).count();
        if on == items.len() {
            Mark::All
        } else if on == 0 {
            Mark::None
        } else {
            Mark::Partial
        }
    }

    pub fn selected(&self) -> Vec<PathBuf> {
        self.paths(true)
    }

    pub fn deselected(&self) -> Vec<PathBuf> {
        self.paths(false)
    }

    fn paths(&self, selected: bool) -> Vec<PathBuf> {
        self.items
            .iter()
            .filter(|i| i.selected == selected)
            .map(|i| i.path.clone())
            .collect()
    }

    pub fn on_key(&mut self, key: KeyEvent) -> Action {
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
            return Action::Quit;
        }
        self.notice = None;
        if self.editing {
            self.on_filter_key(key);
            return Action::None;
        }
        match key.code {
            KeyCode::Char(' ') => self.toggle(),
            KeyCode::Char('a') => self.set_filtered(true),
            KeyCode::Char('n') => self.set_filtered(false),
            KeyCode::Left | KeyCode::Char('h') => self.collapse(),
            KeyCode::Right | KeyCode::Char('l') => self.expand(),
            KeyCode::Up | KeyCode::Char('k') => self.move_by(-1),
            KeyCode::Down | KeyCode::Char('j') => self.move_by(1),
            KeyCode::PageUp => self.move_by(-(PAGE as isize)),
            KeyCode::PageDown => self.move_by(PAGE as isize),
            KeyCode::Home | KeyCode::Char('g') => self.cursor = 0,
            KeyCode::End | KeyCode::Char('G') => self.cursor = self.rows().len().saturating_sub(1),
            KeyCode::Char('/') => self.editing = true,
            KeyCode::Enter => {
                if self.items.iter().any(|i| i.selected) {
                    return Action::Start;
                }
                self.notice = Some("1 つも選んでいません (Space か a で選んでください)".into());
            }
            KeyCode::Char('q') | KeyCode::Esc => return Action::Quit,
            _ => {}
        }
        Action::None
    }

    fn on_filter_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Char(c) => self.filter.push(c),
            KeyCode::Backspace => {
                self.filter.pop();
            }
            KeyCode::Enter => self.editing = false,
            KeyCode::Esc => {
                self.filter.clear();
                self.editing = false;
            }
            _ => {}
        }
        self.clamp();
    }

    fn current(&self) -> Option<Row> {
        self.rows().get(self.cursor).copied()
    }

    fn toggle(&mut self) {
        match self.current() {
            Some(Row::Repo(i)) => self.items[i].selected = !self.items[i].selected,
            Some(Row::Org(o)) => {
                let targets = self.targets(o);
                let all_on = targets.iter().all(|&i| self.items[i].selected);
                for i in targets {
                    self.items[i].selected = !all_on;
                }
            }
            None => {}
        }
    }

    fn set_filtered(&mut self, on: bool) {
        for i in 0..self.items.len() {
            if self.matches(i) {
                self.items[i].selected = on;
            }
        }
    }

    fn org_of_cursor(&self) -> Option<usize> {
        match self.current()? {
            Row::Org(o) => Some(o),
            Row::Repo(i) => self.orgs.iter().position(|o| o.items.contains(&i)),
        }
    }

    fn collapse(&mut self) {
        if let Some(o) = self.org_of_cursor() {
            self.orgs[o].expanded = false;
            if let Some(pos) = self.rows().iter().position(|r| *r == Row::Org(o)) {
                self.cursor = pos;
            }
        }
    }

    fn expand(&mut self) {
        if let Some(Row::Org(o)) = self.current() {
            self.orgs[o].expanded = true;
        }
    }

    fn move_by(&mut self, delta: isize) {
        let last = self.rows().len().saturating_sub(1);
        self.cursor = self.cursor.saturating_add_signed(delta).min(last);
    }

    fn clamp(&mut self) {
        self.cursor = self.cursor.min(self.rows().len().saturating_sub(1));
    }
}
