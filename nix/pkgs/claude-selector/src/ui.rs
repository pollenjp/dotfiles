//! 選ぶ画面の状態と、描く中身 (`Frame`)。端末には触らない (描くのは `term`。試験は tests/ui.rs がキーを並べて流す)。
//!
//! 画面は上から、見出しとキーの案内・コマンド行・選んでいる項目の名前と選択肢の一覧:
//!
//! ```text
//! claude-selector   ←→ / h l 項目   ↑↓ / j k 値   Enter 起こす   Esc やめる
//! $ claude --effort max --model claude-opus-5-5 --dangerously-skip-permissions [--remote-control]
//!
//!   アカウント
//! > claude           (既定)  ~/.claude
//!   claude-personal          ~/.claude-personal
//! ```
//!
//! 項目はコマンド行の区切りで、左から アカウント・effort・モデル・権限・Remote Control (アカウントの後ろは引数の並び
//! `choice::Part::ALL`)。打った直後はアカウントの項目を選んでいる。選んでいる項目は、コマンド行の中のその部分の見せ方を変える
//! (`Style::Selected`。色を付けないときは字の前後に `{` `}` を付ける)。項目の値は一覧のカーソルそのもので、動かせばすぐコマンド行に
//! 出る (決める操作は無い)。どの項目も既定に「(既定)」の印を付け、カーソルの初めの位置は既定なので、打ってすぐ Enter で既定のまま起こす。
//! 付けない値 (権限の「付けない」・Remote Control を付けない) は、コマンド行に灰色の括弧 (`[--permission-mode]`・`[--remote-control]`) で
//! 出し、claude には渡さない。cs の後ろの引数はコマンド行の最後にそのまま出す (項目にはしない)。コマンド行は端末の幅で折り返して全部出す。
//!
//! | キー | 一覧 | 字を打つ間 (モデルを手で打つ・Remote Control の名前) |
//! | --- | --- | --- |
//! | ←→・h l・Tab・Shift+Tab | 項目を移る (端で止まる) | ← は字が空なら一覧へ戻る。h・l は字 |
//! | ↑↓・k j・Ctrl+P・Ctrl+N・Home・End | 値を選ぶ (選べない行は飛ばす。Home・End は一覧の端) | - |
//! | Enter | 今のコマンド行のまま起こす。字を打つ行では打ち始める (打ち終えた直後は起こす) | 決めて一覧へ戻る |
//! | Backspace (Ctrl+H)・Ctrl+U | - | 1 字消す (字が空なら一覧へ戻る)・全部消す |
//! | Esc・Ctrl+C | やめる (起こさない) | やめる |
//!
//! 打つ値がまだ無い (コマンド行に名前の形 `<モデル名>`・`<名前>` を出している) まま Enter を押すと、起こさずにその項目へ移って打ち始める。
//! 選べないアカウントのまま Enter を押すと、知らせてアカウントの項目へ移る。

use crate::accounts::{Found, Mode};
use crate::choice::{self, EFFORTS, MODELS, Part, Permission, RemoteControl, Selection, Target};
use crate::launch::Plan;
use crate::quote;
use std::ffi::OsString;
use std::path::PathBuf;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

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
    /// 説明・キーの案内・項目の名前
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
    /// コマンド行のうち、選んでいる項目
    Selected,
    /// コマンド行のうち、付けない値の灰色の括弧 (claude には渡さない)
    Absent,
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

/// `spans` の後ろに字を足す (最後の塊と同じ見せ方なら、その塊につなぐ)
fn push(spans: &mut Vec<Span>, text: &str, style: Style) {
    match spans.last_mut() {
        Some(last) if last.style == style => last.text.push_str(text),
        _ => spans.push(span(text, style)),
    }
}

/// 既定の選択肢に付ける印
const DEFAULT_MARK: &str = "  (既定)";

/// キーの案内 (一覧・字を打つ行・字を打つ間)
const HELP: &str = "←→ / h l 項目   ↑↓ / j k 値   Enter 起こす   Esc やめる";
const HELP_ASKS: &str = "←→ / h l 項目   ↑↓ / j k 値   Enter 名前を打つ   Esc やめる";
const HELP_INPUT: &str = "Enter 決める   Backspace (空で) 一覧へ戻る   Esc やめる";

/// 端末の上の桁数 (日本語の字は 2 桁)
fn width(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

/// `s` の後ろに空白を足して `w` 桁にする
fn pad(s: &str, w: usize) -> String {
    format!("{s}{}", " ".repeat(w.saturating_sub(width(s))))
}

/// 項目の種類。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    /// 起こすもの (`claude`・`claude-<名前>`)
    Account,
    /// claude に渡す引数の組
    Part(Part),
}

/// アカウントの項目の位置 (一番左)
const ACCOUNT: usize = 0;

/// 引数の組 `part` の項目の位置 (アカウントの後ろに `Part::ALL` の並び)
fn index(part: Part) -> usize {
    1 + Part::ALL
        .iter()
        .position(|p| *p == part)
        .unwrap_or_default()
}

/// モデルの項目の「手で打つ」の位置 (選択肢の後ろ)
const MODEL_TYPED: usize = MODELS.len();
/// Remote Control の項目の選択肢の位置
const RC_OFF: usize = 0;
const RC_UNNAMED: usize = 1;

/// 選択肢 1 つ。
#[derive(Clone, Debug)]
struct Item {
    label: String,
    note: String,
    /// 選べるか (launcher の無いアカウントは選べない)
    enabled: bool,
    /// 字を打つ値か (モデルを手で打つ・Remote Control の名前を付ける)
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

/// 項目 1 つ。値は一覧のカーソル (`cursor`) そのもの。
#[derive(Clone, Debug)]
struct Field {
    kind: Kind,
    title: &'static str,
    items: Vec<Item>,
    default: usize,
    cursor: usize,
}

impl Field {
    /// カーソルの初めの位置は既定。選べなければ最初の選べる行 (どれも選べなければ既定)
    fn new(kind: Kind, title: &'static str, items: Vec<Item>, default: usize) -> Field {
        let cursor = if items.get(default).is_some_and(|i| i.enabled) {
            default
        } else {
            items.iter().position(|i| i.enabled).unwrap_or(default)
        };
        Field {
            kind,
            title,
            items,
            default,
            cursor,
        }
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

    /// カーソルが字を打つ行にあるか
    fn asks(&self) -> bool {
        self.items[self.cursor].asks
    }
}

/// 引数の組 `part` の項目
fn part_field(part: Part) -> Field {
    let index_of = |list: &[&str], want: &str| list.iter().position(|x| *x == want).unwrap_or(0);
    let kind = Kind::Part(part);
    match part {
        Part::Effort => Field::new(
            kind,
            "effort",
            EFFORTS.iter().map(|e| Item::new(*e, "")).collect(),
            index_of(&EFFORTS, choice::DEFAULT_EFFORT),
        ),
        Part::Model => {
            let mut models: Vec<Item> = MODELS.iter().map(|m| Item::new(*m, "")).collect();
            models.push(Item {
                asks: true,
                ..Item::new("手で打つ", "名前を入れる (別名の opus・fable なども)")
            });
            Field::new(
                kind,
                "モデル",
                models,
                index_of(&MODELS, choice::DEFAULT_MODEL),
            )
        }
        Part::Permission => Field::new(
            kind,
            "権限",
            Permission::ALL
                .iter()
                .map(|p| Item::new(p.label(), p.note()))
                .collect(),
            Permission::ALL
                .iter()
                .position(|p| *p == Permission::DEFAULT)
                .unwrap_or(0),
        ),
        Part::RemoteControl => Field::new(
            kind,
            "Remote Control",
            vec![
                Item::new("付けない", ""),
                Item::new("名前なしで付ける", "--remote-control="),
                Item {
                    asks: true,
                    ..Item::new("名前を付ける", "--remote-control=<名前>")
                },
            ],
            RC_OFF,
        ),
    }
}

/// 選ぶ画面。
pub struct Ui {
    /// 項目 (コマンド行の並び)
    fields: Vec<Field>,
    /// 選んでいる項目
    at: usize,
    /// 字を打っている間の字 (選んでいる項目の打つ値)
    input: Option<String>,
    /// 手で打って決めたモデルの名前
    model_text: Option<String>,
    /// 決めた Remote Control の名前
    rc_name: Option<String>,
    /// 打ち終えた直後か (次の Enter は打ち直さずに起こす。値を選ぶ・項目を移るキーで外れる)
    just_typed: bool,
    /// アカウントの項目の選択肢ごとの起こすものと、PATH で見つけた場所
    targets: Vec<(Target, Option<PathBuf>)>,
    /// cs の後ろに打った引数
    extra: Vec<OsString>,
    /// 一覧が読めなかったなどの知らせ (いつも上に出す)
    warnings: Vec<String>,
    /// 1 回だけの知らせ (選べないアカウントで Enter など。次のキーで消す)
    notice: Option<String>,
    /// 色を付けるか (付けないなら、コマンド行の選んでいる項目の前後に `{` `}` を付ける)
    color: bool,
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
        let mut fields = vec![Field::new(Kind::Account, "アカウント", items, 0)];
        fields.extend(Part::ALL.iter().map(|p| part_field(*p)));
        Ui {
            fields,
            at: ACCOUNT,
            input: None,
            model_text: None,
            rc_name: None,
            just_typed: false,
            targets,
            extra,
            warnings: found.warnings.clone(),
            notice: None,
            color: true,
        }
    }

    /// 色を付けるか (既定は付ける)。付けないなら、コマンド行の選んでいる項目の前後に `{` `}` を付ける (色と反転の替わり)
    pub fn with_color(mut self, color: bool) -> Ui {
        self.color = color;
        self
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
        let at = self.at;
        match key {
            Key::Up | Key::Char('k') => self.fields[at].step(false),
            Key::Down | Key::Char('j') => self.fields[at].step(true),
            Key::Home => self.fields[at].jump(false),
            Key::End => self.fields[at].jump(true),
            Key::Left | Key::Char('h') => self.at = at.saturating_sub(1),
            Key::Right | Key::Char('l') => self.at = (at + 1).min(self.fields.len() - 1),
            Key::Enter => return self.enter(),
            _ => return Outcome::Continue,
        }
        // 値を選んだ・項目を移った
        self.just_typed = false;
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

    /// 一覧で Enter: 字を打つ行なら打ち始める (打ち終えた直後は起こす)。ほかは今のコマンド行のまま起こす
    fn enter(&mut self) -> Outcome {
        let just_typed = std::mem::take(&mut self.just_typed);
        if self.fields[self.at].asks() && !just_typed {
            self.begin_input();
            return Outcome::Continue;
        }
        let account = &self.fields[ACCOUNT];
        let item = &account.items[account.cursor];
        if !item.enabled {
            self.notice = Some(format!("{} は選べません ({})", item.label, item.note));
            self.at = ACCOUNT;
            return Outcome::Continue;
        }
        // 打つ値がまだ無ければ (名前の形を見せている)、起こさずにその項目で打ち始める
        for (part, what) in [
            (Part::Model, "モデルの名前"),
            (Part::RemoteControl, "Remote Control の名前"),
        ] {
            if self.placeholder(part) {
                self.at = index(part);
                self.notice = Some(format!("{what}を入れてから起こします"));
                self.begin_input();
                return Outcome::Continue;
            }
        }
        Outcome::Launch(self.plan())
    }

    /// 選んでいる項目の字を打ち始める (決めた字があれば、そこから)
    fn begin_input(&mut self) {
        let start = match self.fields[self.at].kind {
            Kind::Part(part) => self.decided(part).cloned(),
            Kind::Account => None,
        };
        self.input = Some(start.unwrap_or_default());
    }

    /// 決めた打つ値 (モデルの名前・Remote Control の名前)
    fn decided(&self, part: Part) -> Option<&String> {
        match part {
            Part::Model => self.model_text.as_ref(),
            Part::RemoteControl => self.rc_name.as_ref(),
            Part::Effort | Part::Permission => None,
        }
    }

    /// 打った字で決めて一覧へ戻る
    fn commit_input(&mut self) {
        let Some(text) = self.input.as_deref() else {
            return;
        };
        let text = text.trim().to_string();
        match self.fields[self.at].kind {
            Kind::Part(Part::Model) => {
                if let Err(why) = choice::model_ok(&text) {
                    self.notice = Some(why.to_string());
                    return;
                }
                self.model_text = Some(text);
            }
            Kind::Part(Part::RemoteControl) => {
                // 空のまま決めたら名前なし
                if text.is_empty() {
                    self.fields[self.at].cursor = RC_UNNAMED;
                } else {
                    self.rc_name = Some(text);
                }
            }
            _ => {}
        }
        self.input = None;
        self.just_typed = true;
    }

    /// 組 `part` の字を今打っているか
    fn typing(&self, part: Part) -> bool {
        self.input.is_some() && self.at == index(part)
    }

    /// 組 `part` が、打つ値がまだ無くて名前の形 (`<モデル名>`・`<名前>`) を見せているか (この形では起こさない。Remote Control の
    /// 名前を打っている間に字が空なら、Enter で決まる名前なしを見せるので当たらない)
    fn placeholder(&self, part: Part) -> bool {
        match part {
            Part::Model => self.fields[index(part)].asks() && self.typed(part, "").is_empty(),
            Part::RemoteControl => {
                self.fields[index(part)].asks()
                    && self.typed(part, "").is_empty()
                    && !self.typing(part)
            }
            Part::Effort | Part::Permission => false,
        }
    }

    /// 組 `part` の打つ値 (打っている間はその字、ほかは決めた字。どちらも無ければ `placeholder`)
    fn typed(&self, part: Part, placeholder: &str) -> String {
        let current = if self.typing(part) {
            self.input.as_deref()
        } else {
            None
        };
        match current
            .or(self.decided(part).map(String::as_str))
            .map(str::trim)
        {
            Some(t) if !t.is_empty() => t.to_string(),
            _ => placeholder.to_string(),
        }
    }

    /// 今のコマンド行で選んでいるもの (打っている間は打っている字。打つ値がまだ無ければ名前の形)
    pub fn selection(&self) -> Selection {
        let cursor = |part: Part| self.fields[index(part)].cursor;
        let model = match cursor(Part::Model) {
            i if i < MODEL_TYPED => MODELS[i].to_string(),
            _ => self.typed(Part::Model, "<モデル名>"),
        };
        let remote_control = match cursor(Part::RemoteControl) {
            RC_OFF => RemoteControl::Off,
            RC_UNNAMED => RemoteControl::Unnamed,
            // 名前を打っている間に字が空なら、Enter で決まる名前なしを見せる (打つ前は名前の形を見せる)
            _ => match self.typed(Part::RemoteControl, "") {
                n if n.is_empty() && self.typing(Part::RemoteControl) => RemoteControl::Unnamed,
                n if n.is_empty() => RemoteControl::Named("<名前>".to_string()),
                n => RemoteControl::Named(n),
            },
        };
        Selection {
            target: self.targets[self.fields[ACCOUNT].cursor].0.clone(),
            permission: Permission::ALL[cursor(Part::Permission)],
            effort: EFFORTS[cursor(Part::Effort)],
            model,
            remote_control,
        }
    }

    /// 起こすもの (今のコマンド行から灰色の括弧を外したもの)
    fn plan(&self) -> Plan {
        let selection = self.selection();
        let (target, program) = &self.targets[self.fields[ACCOUNT].cursor];
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

    /// キーの案内
    fn help(&self) -> &'static str {
        if self.input.is_some() {
            HELP_INPUT
        } else if self.fields[self.at].asks() && !self.just_typed {
            HELP_ASKS
        } else {
            HELP
        }
    }

    /// コマンド行の塊 (項目ごと。cs の後ろの引数は 1 つの塊) と見せ方。引用と制御文字の見せ方は起こす行 (`Plan::shown`) と同じ
    fn segments(&self) -> Vec<(String, Style)> {
        let selection = self.selection();
        let style = |i: usize, absent: bool| {
            if i == self.at {
                Style::Selected
            } else if absent {
                Style::Absent
            } else {
                Style::Command
            }
        };
        let words = |args: &[String]| {
            args.iter()
                .map(|a| quote::word(a))
                .collect::<Vec<_>>()
                .join(" ")
        };
        let mut segments = vec![(
            quote::word(&selection.target.command()),
            style(ACCOUNT, false),
        )];
        for part in Part::ALL {
            let args = selection.part_args(part);
            segments.push(if args.is_empty() {
                (format!("[{}]", part.flag()), style(index(part), true))
            } else if self.placeholder(part) {
                // 名前の形は引用しない (起こさない。打つ所だと分かるように)
                (args.join(" "), style(index(part), false))
            } else {
                (words(&args), style(index(part), false))
            });
        }
        if !self.extra.is_empty() {
            let extra: Vec<String> = self
                .extra
                .iter()
                .map(|a| a.to_string_lossy().into_owned())
                .collect();
            segments.push((words(&extra), Style::Command));
        }
        segments
            .into_iter()
            .map(|(text, style)| {
                let text = quote::visible(&text);
                if style == Style::Selected && !self.color {
                    (format!("{{{text}}}"), style)
                } else {
                    (text, style)
                }
            })
            .collect()
    }

    /// 選択肢 `i` に添える説明 (打つ値を決めてあれば、その値)
    fn note(&self, field: &Field, i: usize) -> String {
        let item = &field.items[i];
        match (item.asks, field.kind) {
            (true, Kind::Part(Part::Model)) if self.model_text.is_some() => {
                self.typed(Part::Model, "")
            }
            (true, Kind::Part(Part::RemoteControl)) if self.rc_name.is_some() => {
                format!("--remote-control={}", self.typed(Part::RemoteControl, ""))
            }
            _ => item.note.clone(),
        }
    }

    /// 選択肢の一覧の行 (全部)
    fn item_lines(&self, field: &Field) -> Vec<Line> {
        let label_width = field
            .items
            .iter()
            .map(|i| width(&i.label))
            .max()
            .unwrap_or(0);
        let mut lines = Vec::new();
        for (i, item) in field.items.iter().enumerate() {
            let current = i == field.cursor;
            let label_style = match (item.enabled, current) {
                (false, _) => Style::Disabled,
                (true, true) => Style::Current,
                (true, false) => Style::Plain,
            };
            let marker_style = if current {
                Style::Current
            } else {
                Style::Plain
            };
            let mut spans = vec![
                span(if current { "> " } else { "  " }, marker_style),
                span(pad(&item.label, label_width), label_style),
            ];
            let note = self.note(field, i);
            // 既定の印は説明より前に置く (狭い端末で行の後ろが切れても見える)。説明のそろえのため、ほかの行は同じ幅の空白
            if i == field.default {
                spans.push(span(DEFAULT_MARK, Style::DefaultMark));
            } else if !note.is_empty() {
                spans.push(span(" ".repeat(width(DEFAULT_MARK)), Style::Plain));
            }
            if !note.is_empty() {
                let note_style = if item.enabled {
                    Style::Dim
                } else {
                    Style::Disabled
                };
                spans.push(span(format!("  {note}"), note_style));
            }
            lines.push(Line::of(spans));
        }
        lines
    }

    /// 字を打つ間の行 (打つ行と案内)。打つ行の桁 (端末のカーソルを置く所) も返す
    fn input_lines(&self, text: &str) -> (Vec<Line>, usize) {
        let (prompt, hint) = match self.fields[self.at].kind {
            Kind::Part(Part::Model) => (
                "  モデルの名前: ",
                "  claude --model に渡す名前 (claude-opus-5-5・別名の opus など)",
            ),
            _ => (
                "  Remote Control の名前: ",
                "  空のまま Enter で名前なし (--remote-control=)",
            ),
        };
        let shown = quote::visible(text);
        let col = width(prompt) + width(&shown);
        let lines = vec![
            Line::of(vec![
                span(prompt, Style::Plain),
                span(shown, Style::Current),
            ]),
            Line::of(vec![span(hint, Style::Dim)]),
        ];
        (lines, col)
    }

    /// 一番長い一覧の行の数 (項目を移っても枠の行の数を変えないように、一覧の下をこの数まで空行で埋める)
    fn tallest(&self) -> usize {
        self.fields
            .iter()
            .map(|f| f.items.len())
            .max()
            .unwrap_or(0)
            .max(2)
    }

    /// 描く中身。`cols` は 1 行に書ける桁 (コマンド行はこの幅で折り返す。ほかの行は term が切る)、`rows` は端末の行の数。
    /// 収まらなければ、一覧の下の空行・項目の名前と上の空行 (一覧が全部収まるときだけ出す)・一覧が読めない知らせを外し、一覧は
    /// カーソルの行が見える所だけにする (見出し・コマンド行・1 回だけの知らせ・カーソルの行 (字を打つ間は打つ行) は残す)
    pub fn frame(&self, cols: usize, rows: usize) -> Frame {
        let cols = cols.max(4);
        let rows = rows.max(1);
        let title = Line::of(vec![
            span("claude-selector", Style::Title),
            span("   ", Style::Plain),
            span(self.help(), Style::Dim),
        ]);
        let warnings: Vec<Line> = self
            .warnings
            .iter()
            .map(|w| {
                Line::of(vec![span(
                    format!("  ! {}", quote::visible(w)),
                    Style::Warn,
                )])
            })
            .collect();
        let command: Vec<Line> = wrap(&self.segments(), cols - 2)
            .into_iter()
            .enumerate()
            .map(|(i, spans)| {
                let mut line = vec![span(if i == 0 { "$ " } else { "  " }, Style::Dim)];
                line.extend(spans);
                Line::of(line)
            })
            .collect();
        let notice = self
            .notice
            .as_ref()
            .map(|n| Line::of(vec![span(format!("  {}", quote::visible(n)), Style::Warn)]));
        let field = &self.fields[self.at];
        // 一覧 (字を打つ間は打つ行と案内) と、見えていなければならない行
        let (body, focus, input_col) = match &self.input {
            Some(text) => {
                let (lines, col) = self.input_lines(text);
                (lines, 0, Some(col))
            }
            None => (self.item_lines(field), field.cursor, None),
        };
        let mut room = rows.saturating_sub(1 + command.len() + usize::from(notice.is_some()));
        // 収まらなければ、一覧が読めない知らせを外す (一覧の 1 行は残す)
        let show_warnings = room > warnings.len();
        if show_warnings {
            room -= warnings.len();
        }
        // 間の空行 (知らせがあれば知らせの行) と項目の名前は、一覧が全部収まるときだけ
        let deco_rows = usize::from(notice.is_none()) + 1;
        let deco = room >= deco_rows + body.len();
        if deco {
            room -= deco_rows;
        }
        // カーソルの行が見える所 (下へ動かしたらカーソルを一番下に)
        let shown = room.clamp(1, body.len().max(1));
        let start = (focus + 1)
            .saturating_sub(shown)
            .min(body.len().saturating_sub(shown));
        let body: Vec<Line> = body.into_iter().skip(start).take(shown).collect();
        let pad = if deco {
            self.tallest()
                .saturating_sub(body.len())
                .min(room.saturating_sub(body.len()))
        } else {
            0
        };
        let mut lines = vec![title];
        if show_warnings {
            lines.extend(warnings);
        }
        lines.extend(command);
        match notice {
            Some(n) => lines.push(n),
            None if deco => lines.push(Line::default()),
            None => {}
        }
        if deco {
            lines.push(Line::of(vec![span(
                format!("  {}", field.title),
                Style::Dim,
            )]));
        }
        let cursor = input_col.map(|col| (lines.len(), col.min(cols)));
        lines.extend(body);
        lines.extend(std::iter::repeat_n(Line::default(), pad));
        Frame { lines, cursor }
    }
}

/// 塊を `width` 桁ずつの行に分ける (空白で切れるなら空白で。1 語が幅を超えれば字の境で切る。日本語の字は 2 桁)。塊の見せ方は
/// 折り返した先でも保つ。塊の中の空白はその塊の見せ方、塊と塊の間の空白はコマンド行の見せ方にする (選んでいる項目の塊が途切れずに見える)
fn wrap(segments: &[(String, Style)], width: usize) -> Vec<Vec<Span>> {
    let width = width.max(1);
    let mut lines = Vec::new();
    let mut line: Vec<Span> = Vec::new();
    let mut used = 0;
    for (text, style) in segments {
        for (i, word) in text.split(' ').enumerate() {
            let gap = if i == 0 { Style::Command } else { *style };
            let need = UnicodeWidthStr::width(word);
            if used > 0 && used + 1 + need <= width {
                push(&mut line, " ", gap);
                push(&mut line, word, *style);
                used += 1 + need;
                continue;
            }
            if used > 0 {
                lines.push(std::mem::take(&mut line));
                used = 0;
            }
            // 1 語が幅を超えれば字の境で切る
            for c in word.chars() {
                let w = c.width().unwrap_or(0);
                if used + w > width && used > 0 {
                    lines.push(std::mem::take(&mut line));
                    used = 0;
                }
                let mut buf = [0; 4];
                push(&mut line, c.encode_utf8(&mut buf), *style);
                used += w;
            }
        }
    }
    if !line.is_empty() || lines.is_empty() {
        lines.push(line);
    }
    lines
}
