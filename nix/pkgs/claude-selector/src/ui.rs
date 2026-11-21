//! 選ぶ画面の状態機械と、描く中身 (`Frame`)。端末には触らない (描くのは `term`。試験は tests/ui.rs がキーを並べて流す)。
//!
//! 段: アカウント → 権限 → effort → モデル → Remote Control → 確かめる (組み立てたコマンド行を見せ、Enter で起こす)。どの段も既定に
//! 「(既定)」の印を付け、カーソルの初めの位置は既定 (戻ってきたときは決めた選択肢) なので、Enter だけで既定のまま進める。どの段でも
//! 一番下に、今のカーソルのまま Enter で進んだときのコマンド行を出す。
//!
//! | キー | 一覧 | 字を打つ間 (モデルを手で打つ・Remote Control の名前) | 確かめる |
//! | --- | --- | --- | --- |
//! | ↑↓ (k・j・Ctrl+P・Ctrl+N・Tab・Shift+Tab)・Home・End | 選ぶ (選べない行は飛ばす) | - | - |
//! | Enter (→・l) | 決めて次の段へ | 決める | 起こす |
//! | ← (Backspace・h) | 前の段へ | 字が空なら一覧へ戻る (Backspace は 1 字消す。Ctrl+U は全部消す) | 前の段へ |
//! | Esc・Ctrl+C | やめる (起こさない) | やめる | やめる |

use crate::accounts::{Found, Mode};
use crate::choice::{self, EFFORTS, MODELS, Permission, RemoteControl, Selection, Target};
use crate::launch::Plan;
use crate::quote;
use std::ffi::OsString;
use std::path::PathBuf;
use unicode_width::UnicodeWidthStr;

/// 画面が受けるキー (term が端末のキーから写す)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    Enter,
    Esc,
    Backspace,
    /// Ctrl+C (raw mode では signal でなくキーで届く)
    Interrupt,
    /// Ctrl+U (打った字を全部消す)
    ClearLine,
    Char(char),
}

/// キーを受けた後。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// まだ選んでいる (描き直す)
    Continue,
    /// やめた (起こさない)
    Cancel,
    /// これを起こす
    Launch(Plan),
}

/// 字の見せ方 (色は term が決める。NO_COLOR なら色を付けない)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    Plain,
    /// 見出し
    Title,
    /// 説明・キーの案内
    Dim,
    /// カーソルの行
    Current,
    /// 「(既定)」の印
    DefaultMark,
    /// 選べない行
    Disabled,
    /// 知らせ
    Warn,
    /// コマンド行
    Command,
}

/// 字のひとかたまり。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Span {
    pub text: String,
    pub style: Style,
}

/// 1 行。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Line {
    pub spans: Vec<Span>,
}

impl Line {
    fn of(spans: Vec<Span>) -> Line {
        Line { spans }
    }

    /// 字だけ (見せ方を除く)
    pub fn text(&self) -> String {
        self.spans.iter().map(|s| s.text.as_str()).collect()
    }
}

/// 描く中身。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Frame {
    pub lines: Vec<Line>,
    /// 字を打つ間のカーソルの位置 (行, 桁)。None ならカーソルを隠す
    pub cursor: Option<(usize, usize)>,
}

impl Frame {
    /// 字だけを行ごとに改行でつないだもの (試験が読む)
    pub fn text(&self) -> String {
        self.lines
            .iter()
            .map(Line::text)
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn span(text: impl Into<String>, style: Style) -> Span {
    Span {
        text: text.into(),
        style,
    }
}

/// 既定の選択肢に付ける印
const DEFAULT_MARK: &str = "  (既定)";

/// 端末の上の桁数 (日本語の字は 2 桁)
fn width(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

/// `s` の後ろに空白を足して `w` 桁にする
fn pad(s: &str, w: usize) -> String {
    format!("{s}{}", " ".repeat(w.saturating_sub(width(s))))
}

/// 段の種類 (並びも)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Account,
    Permission,
    Effort,
    Model,
    RemoteControl,
}

const ACCOUNT: usize = 0;
const PERMISSION: usize = 1;
const EFFORT: usize = 2;
const MODEL: usize = 3;
const REMOTE_CONTROL: usize = 4;

/// モデルの段の「手で打つ」の位置 (選択肢の後ろ)
const MODEL_TYPED: usize = MODELS.len();
/// Remote Control の段の選択肢の位置
const RC_OFF: usize = 0;
const RC_UNNAMED: usize = 1;
const RC_NAMED: usize = 2;

/// 選択肢 1 つ。
#[derive(Clone, Debug)]
struct Item {
    label: String,
    note: String,
    /// 選べるか (launcher の無いアカウントは選べない)
    enabled: bool,
    /// 選ぶと字を打つ (モデルを手で打つ・Remote Control の名前を付ける)
    asks: bool,
}

impl Item {
    fn new(label: impl Into<String>, note: impl Into<String>) -> Item {
        Item {
            label: label.into(),
            note: note.into(),
            enabled: true,
            asks: false,
        }
    }
}

/// 段 1 つ。
#[derive(Clone, Debug)]
struct Stage {
    kind: Kind,
    title: &'static str,
    items: Vec<Item>,
    default: usize,
    cursor: usize,
    /// 決めた選択肢 (戻ってきたときにカーソルを置く)
    chosen: Option<usize>,
}

impl Stage {
    fn new(kind: Kind, title: &'static str, items: Vec<Item>, default: usize) -> Stage {
        let mut s = Stage {
            kind,
            title,
            items,
            default,
            cursor: default,
            chosen: None,
        };
        s.cursor = s.start();
        s
    }

    /// カーソルの初めの位置: 決めた選択肢、まだなら既定。選べなければ最初の選べる行 (どれも選べなければ既定)
    fn start(&self) -> usize {
        let want = self.chosen.unwrap_or(self.default);
        if self.items.get(want).is_some_and(|i| i.enabled) {
            return want;
        }
        self.items.iter().position(|i| i.enabled).unwrap_or(want)
    }

    /// カーソルを選べる行へ `forward` の向きに 1 つ動かす (端で止まる)
    fn step(&mut self, forward: bool) {
        let enabled = |i: &usize| self.items[*i].enabled;
        let next = if forward {
            (self.cursor + 1..self.items.len()).find(enabled)
        } else {
            (0..self.cursor).rev().find(enabled)
        };
        if let Some(n) = next {
            self.cursor = n;
        }
    }

    /// カーソルを端の選べる行へ
    fn jump(&mut self, last: bool) {
        let mut all = 0..self.items.len();
        let found = if last {
            all.rfind(|i| self.items[*i].enabled)
        } else {
            all.find(|i| self.items[*i].enabled)
        };
        if let Some(n) = found {
            self.cursor = n;
        }
    }
}

/// 選ぶ画面。
pub struct Ui {
    stages: Vec<Stage>,
    /// 今の段 (`stages.len()` なら確かめる画面)
    at: usize,
    /// 字を打っている間の字
    input: Option<String>,
    /// 手で打って決めたモデルの名前
    model_text: Option<String>,
    /// 決めた Remote Control の名前
    rc_name: Option<String>,
    /// アカウントの段の選択肢ごとの起こすものと、PATH で見つけた場所
    targets: Vec<(Target, Option<PathBuf>)>,
    /// cs の後ろに打った引数
    extra: Vec<OsString>,
    /// 一覧が読めなかったなどの知らせ (いつも上に出す)
    warnings: Vec<String>,
    /// 1 回だけの知らせ (選べない行で Enter など。次のキーで消す)
    notice: Option<String>,
}

impl Ui {
    /// `found` (アカウントと PATH の claude)・`claude_note` (素の claude に添える説明。~/.claude か CLAUDE_CONFIG_DIR)・`extra`
    /// (cs の後ろの引数) で作る
    pub fn new(found: &Found, claude_note: &str, extra: Vec<OsString>) -> Ui {
        let mut items = vec![Item {
            enabled: found.claude.is_some(),
            ..Item::new(
                "claude",
                if found.claude.is_some() {
                    claude_note.to_string()
                } else {
                    "PATH に claude が無い".to_string()
                },
            )
        }];
        let mut targets = vec![(Target::Plain, found.claude.clone())];
        for a in &found.accounts {
            let note = match (&a.launcher, a.mode) {
                (None, _) => "launcher が PATH に無い".to_string(),
                (Some(_), Mode::Token) => format!("~/.claude-{} (token)", a.name),
                (Some(_), Mode::Subscription) => format!("~/.claude-{}", a.name),
            };
            items.push(Item {
                enabled: a.launcher.is_some(),
                ..Item::new(format!("claude-{}", a.name), note)
            });
            targets.push((Target::Account(a.name.clone()), a.launcher.clone()));
        }
        let permissions = Permission::ALL
            .iter()
            .map(|p| Item::new(p.label(), p.note()))
            .collect();
        let efforts = EFFORTS.iter().map(|e| Item::new(*e, "")).collect();
        let mut models: Vec<Item> = MODELS.iter().map(|m| Item::new(*m, "")).collect();
        models.push(Item {
            asks: true,
            ..Item::new("手で打つ", "名前を入れる (別名の opus・fable なども)")
        });
        let rc = vec![
            Item::new("付けない", ""),
            Item::new("名前なしで付ける", "--remote-control="),
            Item {
                asks: true,
                ..Item::new("名前を付ける", "--remote-control=<名前>")
            },
        ];
        let index_of =
            |list: &[&str], want: &str| list.iter().position(|x| *x == want).unwrap_or(0);
        let permission_default = Permission::ALL
            .iter()
            .position(|p| *p == Permission::DEFAULT)
            .unwrap_or(0);
        Ui {
            stages: vec![
                Stage::new(Kind::Account, "アカウント", items, 0),
                Stage::new(Kind::Permission, "権限", permissions, permission_default),
                Stage::new(
                    Kind::Effort,
                    "effort",
                    efforts,
                    index_of(&EFFORTS, choice::DEFAULT_EFFORT),
                ),
                Stage::new(
                    Kind::Model,
                    "モデル",
                    models,
                    index_of(&MODELS, choice::DEFAULT_MODEL),
                ),
                Stage::new(Kind::RemoteControl, "Remote Control", rc, RC_OFF),
            ],
            at: 0,
            input: None,
            model_text: None,
            rc_name: None,
            targets,
            extra,
            warnings: found.warnings.clone(),
            notice: None,
        }
    }

    /// キーを 1 つ受ける
    pub fn handle(&mut self, key: Key) -> Outcome {
        self.notice = None;
        if matches!(key, Key::Esc | Key::Interrupt) {
            return Outcome::Cancel;
        }
        if self.input.is_some() {
            self.handle_input(key);
            return Outcome::Continue;
        }
        if self.at == self.stages.len() {
            return match key {
                Key::Enter | Key::Right | Key::Char('l') => Outcome::Launch(self.plan()),
                Key::Left | Key::Backspace | Key::Char('h') => {
                    self.back();
                    Outcome::Continue
                }
                _ => Outcome::Continue,
            };
        }
        let at = self.at;
        match key {
            Key::Up | Key::Char('k') => self.stages[at].step(false),
            Key::Down | Key::Char('j') => self.stages[at].step(true),
            Key::Home => self.stages[at].jump(false),
            Key::End => self.stages[at].jump(true),
            Key::Left | Key::Backspace | Key::Char('h') => self.back(),
            Key::Enter | Key::Right | Key::Char('l') => self.choose(),
            _ => {}
        }
        Outcome::Continue
    }

    /// 字を打つ間のキー
    fn handle_input(&mut self, key: Key) {
        let Some(text) = self.input.as_mut() else {
            return;
        };
        match key {
            Key::Char(c) if !c.is_control() => text.push(c),
            Key::Backspace | Key::Left if text.is_empty() => self.input = None,
            Key::Backspace => {
                text.pop();
            }
            Key::ClearLine => text.clear(),
            Key::Enter => self.commit_input(),
            _ => {}
        }
    }

    /// カーソルの選択肢を決める (字を打つ選択肢なら打ち始める)
    fn choose(&mut self) {
        let stage = &self.stages[self.at];
        let item = &stage.items[stage.cursor];
        if !item.enabled {
            self.notice = Some(format!("{} は選べません ({})", item.label, item.note));
            return;
        }
        if item.asks {
            let start = match stage.kind {
                Kind::Model => self.model_text.clone(),
                Kind::RemoteControl => self.rc_name.clone(),
                _ => None,
            };
            self.input = Some(start.unwrap_or_default());
            return;
        }
        let index = stage.cursor;
        self.decide(index);
    }

    /// 打った字で決める
    fn commit_input(&mut self) {
        let Some(text) = self.input.clone() else {
            return;
        };
        let text = text.trim().to_string();
        match self.stages[self.at].kind {
            Kind::Model => {
                if let Err(why) = choice::model_ok(&text) {
                    self.notice = Some(why.to_string());
                    return;
                }
                self.input = None;
                self.model_text = Some(text);
                self.decide(MODEL_TYPED);
            }
            Kind::RemoteControl => {
                self.input = None;
                // 空のまま決めたら名前なし
                if text.is_empty() {
                    self.decide(RC_UNNAMED);
                } else {
                    self.rc_name = Some(text);
                    self.decide(RC_NAMED);
                }
            }
            _ => self.input = None,
        }
    }

    /// 今の段を `index` に決めて次の段へ
    fn decide(&mut self, index: usize) {
        let stage = &mut self.stages[self.at];
        stage.chosen = Some(index);
        stage.cursor = index;
        self.at += 1;
        if let Some(next) = self.stages.get_mut(self.at) {
            next.cursor = next.start();
        }
    }

    /// 前の段へ (決めたものは残す)
    fn back(&mut self) {
        if self.at == 0 {
            return;
        }
        self.at -= 1;
        let stage = &mut self.stages[self.at];
        stage.cursor = stage.start();
    }

    /// 段 `i` で今効いている選択肢 (今の段はカーソル、ほかは決めたもの、まだなら既定)
    fn index(&self, i: usize) -> usize {
        let stage = &self.stages[i];
        if i == self.at {
            stage.cursor
        } else {
            stage.chosen.unwrap_or(stage.default)
        }
    }

    /// 段 `i` の打つ字 (打っている間はその字、ほかは決めた字。どちらも無ければ `placeholder`)
    fn typed(&self, i: usize, decided: &Option<String>, placeholder: &str) -> String {
        let current = if self.at == i {
            self.input.as_deref()
        } else {
            None
        };
        match current.or(decided.as_deref()).map(str::trim) {
            Some(t) if !t.is_empty() => t.to_string(),
            _ => placeholder.to_string(),
        }
    }

    /// 今のカーソルのまま Enter で進んだときに選ぶもの (確かめる画面では決めたもの)
    pub fn selection(&self) -> Selection {
        let model = match self.index(MODEL) {
            i if i < MODELS.len() => MODELS[i].to_string(),
            _ => self.typed(MODEL, &self.model_text, "<モデル名>"),
        };
        let remote_control = match self.index(REMOTE_CONTROL) {
            RC_OFF => RemoteControl::Off,
            RC_UNNAMED => RemoteControl::Unnamed,
            _ => match self.typed(REMOTE_CONTROL, &self.rc_name, "") {
                n if n.is_empty() => RemoteControl::Named("<名前>".to_string()),
                n => RemoteControl::Named(n),
            },
        };
        Selection {
            target: self.targets[self.index(ACCOUNT)].0.clone(),
            permission: Permission::ALL[self.index(PERMISSION)],
            effort: EFFORTS[self.index(EFFORT)],
            model,
            remote_control,
        }
    }

    /// 起こすもの (確かめる画面で Enter)
    fn plan(&self) -> Plan {
        let selection = self.selection();
        let (target, program) = &self.targets[self.index(ACCOUNT)];
        let args = selection.args(&self.extra);
        Plan {
            // 選べるのは見つけたものだけ。念のため、無ければ名前で起こす (unix は PATH で探す)
            program: program
                .clone()
                .unwrap_or_else(|| PathBuf::from(target.command())),
            shown: quote::command_line(&target.command(), &args),
            args,
        }
    }

    /// 確かめる画面に出す、段 `i` で決めたもの
    fn chosen_label(&self, i: usize, selection: &Selection) -> String {
        match i {
            ACCOUNT => selection.target.command(),
            PERMISSION => selection.permission.label(),
            EFFORT => selection.effort.to_string(),
            MODEL => selection.model.clone(),
            _ => match &selection.remote_control {
                RemoteControl::Off => "付けない".to_string(),
                RemoteControl::Unnamed => "名前なしで付ける".to_string(),
                RemoteControl::Named(n) => format!("名前を付ける ({n})"),
            },
        }
    }

    /// キーの案内
    fn help(&self) -> &'static str {
        if self.input.is_some() {
            "Enter 決める  Backspace (空で) 一覧へ戻る  Esc やめる"
        } else if self.at == self.stages.len() {
            "Enter 起こす  ← 戻る  Esc やめる"
        } else if self.at == 0 {
            "↑↓ 選ぶ  Enter 決める  Esc やめる"
        } else {
            "↑↓ 選ぶ  Enter 決める  ← 戻る  Esc やめる"
        }
    }

    /// 描く中身
    pub fn frame(&self) -> Frame {
        let total = self.stages.len();
        let mut lines = Vec::new();
        let mut cursor = None;
        let title = match self.stages.get(self.at) {
            Some(stage) => format!("[{}/{total}] {}", self.at + 1, stage.title),
            None => "これで起こす".to_string(),
        };
        lines.push(Line::of(vec![
            span("claude-selector", Style::Title),
            span("  ", Style::Plain),
            span(title, Style::Title),
        ]));
        for w in &self.warnings {
            lines.push(Line::of(vec![span(format!("  ! {w}"), Style::Warn)]));
        }
        match (self.stages.get(self.at), &self.input) {
            (Some(stage), Some(text)) => {
                let prompt = match stage.kind {
                    Kind::Model => "  モデルの名前: ",
                    _ => "  Remote Control の名前: ",
                };
                cursor = Some((lines.len(), width(prompt) + width(text)));
                lines.push(Line::of(vec![
                    span(prompt, Style::Plain),
                    span(text.clone(), Style::Current),
                ]));
                let hint = match stage.kind {
                    Kind::Model => {
                        "  claude --model に渡す名前 (claude-opus-5-5・別名の opus など)"
                    }
                    _ => "  空のまま Enter で名前なし (--remote-control=)",
                };
                lines.push(Line::of(vec![span(hint, Style::Dim)]));
            }
            (Some(stage), None) => {
                let label_width = stage
                    .items
                    .iter()
                    .map(|i| width(&i.label))
                    .max()
                    .unwrap_or(0);
                for (i, item) in stage.items.iter().enumerate() {
                    let current = i == stage.cursor;
                    let label_style = match (item.enabled, current) {
                        (false, _) => Style::Disabled,
                        (true, true) => Style::Current,
                        (true, false) => Style::Plain,
                    };
                    let mut spans = vec![
                        span(
                            if current { "> " } else { "  " },
                            if current {
                                Style::Current
                            } else {
                                Style::Plain
                            },
                        ),
                        span(pad(&item.label, label_width), label_style),
                    ];
                    // 既定の印は説明より前に置く (狭い端末で行の後ろが切れても見える)。説明のそろえのため、ほかの行は同じ幅の空白
                    if i == stage.default {
                        spans.push(span(DEFAULT_MARK, Style::DefaultMark));
                    } else if !item.note.is_empty() {
                        spans.push(span(" ".repeat(width(DEFAULT_MARK)), Style::Plain));
                    }
                    if !item.note.is_empty() {
                        let note_style = if item.enabled {
                            Style::Dim
                        } else {
                            Style::Disabled
                        };
                        spans.push(span(format!("  {}", item.note), note_style));
                    }
                    lines.push(Line::of(spans));
                }
            }
            (None, _) => {
                let selection = self.selection();
                let title_width = self
                    .stages
                    .iter()
                    .map(|s| width(s.title))
                    .max()
                    .unwrap_or(0);
                for (i, stage) in self.stages.iter().enumerate() {
                    lines.push(Line::of(vec![
                        span(format!("  {}", pad(stage.title, title_width)), Style::Dim),
                        span("  ", Style::Plain),
                        span(self.chosen_label(i, &selection), Style::Plain),
                    ]));
                }
            }
        }
        if let Some(n) = &self.notice {
            lines.push(Line::of(vec![span(format!("  {n}"), Style::Warn)]));
        }
        let selection = self.selection();
        let command =
            quote::command_line(&selection.target.command(), &selection.args(&self.extra));
        lines.push(Line::of(vec![
            span("$ ", Style::Dim),
            span(command, Style::Command),
        ]));
        lines.push(Line::of(vec![span(self.help(), Style::Dim)]));
        Frame { lines, cursor }
    }
}
