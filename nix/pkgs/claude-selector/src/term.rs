//! 端末 (crossterm): raw mode にしてキーを読み、`Frame` を今の行から下に描く。
//!
//! 全画面 (alternate screen) には切り替えず、cs を打った行から下に描いて、描き直すたびに前に描いた所へ戻って消す (選ぶ画面は 10 行ほど)。
//! 行は端末の幅で切り、折り返さない (折り返すと戻る行の数がずれる。コマンド行は `ui` が幅で折り返して何行かにする)。枠の行の数は
//! 端末の行の数までに `ui` が減らす。終わったら描いた所を消し、起こすときはコマンド行を 1 行残す。制御文字は見える形 (`\n` など) にして
//! 書く。raw mode では Ctrl+C が signal でなくキー (`Key::Interrupt`) で届く (Linux も Windows も)。
//!
//! 端末を戻すのは、終わるとき (`finish`)・drop (途中で落ちた・エラー)・panic (`install_panic_hook`) のどれでも。

use crate::quote;
use crate::ui::{Frame, Key, Line, Span, Style};
use crossterm::cursor;
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::queue;
use crossterm::style::{self, Attribute, Color};
use crossterm::terminal::{self, ClearType};
use std::io::{self, Write};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// raw mode の端末。drop で元に戻す (途中で落ちても端末を raw mode のままにしない)。
pub struct Term {
    out: io::Stdout,
    /// 前に描いた枠の中で、カーソルのいる行 (枠の頭から数えて)。描いていなければ None
    cursor_row: Option<u16>,
    /// 色を付けるか (NO_COLOR なら付けない)
    color: bool,
}

/// panic したときに、panic の文を出す前に端末を戻す (raw mode のままだと文が階段状になり、端末も戻らない)
pub fn install_panic_hook() {
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = terminal::disable_raw_mode();
        let mut out = io::stdout();
        let _ = queue!(out, cursor::Show, style::Print("\r\n"));
        let _ = out.flush();
        default(info);
    }));
}

impl Term {
    /// raw mode にしてカーソルを隠す
    pub fn start(color: bool) -> io::Result<Term> {
        terminal::enable_raw_mode()?;
        let mut term = Term {
            out: io::stdout(),
            cursor_row: None,
            color,
        };
        queue!(term.out, cursor::Hide)?;
        term.out.flush()?;
        Ok(term)
    }

    /// 枠に使える (桁, 行)。最後の桁に書くと折り返す端末があるので、桁は 1 つあける
    pub fn size(&self) -> (usize, usize) {
        let (cols, rows) = terminal::size().unwrap_or((80, 24));
        (usize::from(cols.max(2)) - 1, usize::from(rows.max(1)))
    }

    /// キーを 1 つ待つ。画面の大きさが変わった・使わないキーなら None (描き直す)
    pub fn read_key(&mut self) -> io::Result<Option<Key>> {
        Ok(match event::read()? {
            // Windows は離したときも届く
            Event::Key(k) if k.kind != KeyEventKind::Release => map_key(k),
            _ => None,
        })
    }

    /// 描く (前に描いた枠を消してから)
    pub fn draw(&mut self, frame: &Frame) -> io::Result<()> {
        let (width, _) = self.size();
        self.clear()?;
        let last = frame.lines.len().saturating_sub(1);
        for (i, line) in frame.lines.iter().enumerate() {
            self.print_line(line, width)?;
            if i < last {
                queue!(self.out, style::Print("\r\n"))?;
            }
        }
        match frame.cursor {
            Some((row, col)) => {
                let up = last.saturating_sub(row);
                if up > 0 {
                    queue!(self.out, cursor::MoveUp(to_u16(up)))?;
                }
                queue!(
                    self.out,
                    cursor::MoveToColumn(to_u16(col.min(width))),
                    cursor::Show
                )?;
                self.cursor_row = Some(to_u16(row.min(last)));
            }
            None => {
                queue!(self.out, cursor::Hide)?;
                self.cursor_row = Some(to_u16(last));
            }
        }
        self.out.flush()
    }

    /// 描いた枠を消して端末を戻す。`last` があれば、消した所に 1 行残す (起こすコマンド行。制御文字は見える形にする)。
    /// 落ちたときも、これで消してからわけを出す
    pub fn finish(mut self, last: Option<&str>) -> io::Result<()> {
        self.clear()?;
        self.cursor_row = None;
        if let Some(line) = last {
            queue!(
                self.out,
                style::Print(quote::visible(line)),
                style::Print("\r\n")
            )?;
        }
        queue!(self.out, cursor::Show)?;
        self.out.flush()?;
        terminal::disable_raw_mode()
    }

    /// 前に描いた枠の頭へ戻り、そこから下を消す
    fn clear(&mut self) -> io::Result<()> {
        if let Some(row) = self.cursor_row {
            // MoveUp(0) は 1 行上がる端末がある
            if row > 0 {
                queue!(self.out, cursor::MoveUp(row))?;
            }
            queue!(
                self.out,
                cursor::MoveToColumn(0),
                terminal::Clear(ClearType::FromCursorDown)
            )?;
        }
        Ok(())
    }

    /// 1 行を `width` 桁で切って書く
    fn print_line(&mut self, line: &Line, width: usize) -> io::Result<()> {
        for span in clip(line, width).spans {
            self.set_style(span.style)?;
            queue!(
                self.out,
                style::Print(span.text),
                style::SetAttribute(Attribute::Reset),
                style::ResetColor
            )?;
        }
        Ok(())
    }

    fn set_style(&mut self, s: Style) -> io::Result<()> {
        let bold = matches!(s, Style::Title | Style::Current | Style::Command);
        if bold {
            queue!(self.out, style::SetAttribute(Attribute::Bold))?;
        }
        if !self.color {
            return Ok(());
        }
        let fg = match s {
            Style::Plain | Style::Title => None,
            Style::Dim | Style::Disabled => Some(Color::DarkGrey),
            Style::Current => Some(Color::Cyan),
            Style::DefaultMark | Style::Warn => Some(Color::Yellow),
            Style::Command => Some(Color::Green),
        };
        if let Some(c) = fg {
            queue!(self.out, style::SetForegroundColor(c))?;
        }
        Ok(())
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        let _ = queue!(self.out, cursor::Show);
        let _ = self.out.flush();
        let _ = terminal::disable_raw_mode();
    }
}

/// 行を `width` 桁に収める。制御文字は見える形 (`\n`・`\u{1b}` など) にしてから数え、はみ出すなら、収まる所まで残して最後に「…」を
/// 付ける (日本語の字は 2 桁。空になった塊は除く)
pub fn clip(line: &Line, width: usize) -> Line {
    let spans: Vec<Span> = line
        .spans
        .iter()
        .map(|s| Span {
            text: quote::visible(&s.text),
            style: s.style,
        })
        .collect();
    let total: usize = spans
        .iter()
        .map(|s| UnicodeWidthStr::width(s.text.as_str()))
        .sum();
    if total <= width {
        return Line { spans };
    }
    // 「…」の 1 桁をあける
    let limit = width.saturating_sub(1);
    let mut used = 0;
    let mut out = Vec::new();
    for span in spans {
        let mut text = String::new();
        let mut cut = false;
        for c in span.text.chars() {
            let w = c.width().unwrap_or(0);
            if used + w > limit {
                cut = true;
                break;
            }
            used += w;
            text.push(c);
        }
        if cut {
            text.push('…');
        }
        if !text.is_empty() {
            out.push(Span {
                text,
                style: span.style,
            });
        }
        if cut {
            break;
        }
    }
    Line { spans: out }
}

fn to_u16(n: usize) -> u16 {
    u16::try_from(n).unwrap_or(u16::MAX)
}

/// 端末のキーを画面のキーに写す (使わないキーは None)。Ctrl+Alt+字は AltGr で打った字として受ける (Windows は AltGr を Ctrl+Alt で
/// 届ける)。Ctrl+H は Backspace (Backspace に Ctrl+H を送る端末がある)
pub fn map_key(k: KeyEvent) -> Option<Key> {
    let ctrl =
        k.modifiers.contains(KeyModifiers::CONTROL) && !k.modifiers.contains(KeyModifiers::ALT);
    Some(match k.code {
        KeyCode::Char('c') if ctrl => Key::Interrupt,
        KeyCode::Char('u') if ctrl => Key::ClearLine,
        KeyCode::Char('p') if ctrl => Key::Up,
        KeyCode::Char('n') if ctrl => Key::Down,
        KeyCode::Char('h') if ctrl => Key::Backspace,
        KeyCode::Char(_) if ctrl => return None,
        KeyCode::Char(c) => Key::Char(c),
        KeyCode::Up | KeyCode::BackTab => Key::Up,
        KeyCode::Down | KeyCode::Tab => Key::Down,
        KeyCode::Left => Key::Left,
        KeyCode::Right => Key::Right,
        KeyCode::Home => Key::Home,
        KeyCode::End => Key::End,
        KeyCode::Enter => Key::Enter,
        KeyCode::Esc => Key::Esc,
        KeyCode::Backspace => Key::Backspace,
        _ => return None,
    })
}
