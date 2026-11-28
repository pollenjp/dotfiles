//! 道具の引数の小さな読み手。clap を足さず手で読む (W0-1 の shim・doctor と同じ。依存を少なく保つ。spec §6.5)。
//!
//! - `--name value` と `--name=value`。値を取る option は、次の引数が `-` で始まっても値として取る
//! - `--` の後ろは全部が位置引数。`-` だけの引数も位置引数
//! - 知らない option・値の無い option・2 度渡した 1 つだけの option は設定の誤り (終了コード 2)
//! - `-h`・`--help` はいつでも受ける ([`Parsed::help`])

use std::collections::{HashMap, HashSet};

use pjp_core::{Error, Result};

/// 受ける option。名前は `--` から書く。
#[derive(Debug, Clone, Copy, Default)]
pub struct Spec<'a> {
    /// 値を取らない option (`--chrome` など)。
    pub flags: &'a [&'a str],
    /// 値を取る option (`--on <machine>` など)。繰り返してよいかは読む側が [`Parsed::value`]・[`Parsed::values`] で決める。
    pub values: &'a [&'a str],
}

/// 読んだ引数。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Parsed {
    flags: HashSet<String>,
    values: HashMap<String, Vec<String>>,
    pub positionals: Vec<String>,
    help: bool,
}

impl Parsed {
    /// `-h`・`--help` があったか。
    pub fn help(&self) -> bool {
        self.help
    }

    pub fn flag(&self, name: &str) -> bool {
        self.flags.contains(name)
    }

    /// 1 つだけ取る option の値。2 度渡されたら設定の誤り。
    pub fn value(&self, name: &str) -> Result<Option<&str>> {
        match self.values.get(name).map(Vec::as_slice) {
            None | Some([]) => Ok(None),
            Some([v]) => Ok(Some(v.as_str())),
            Some(_) => Err(Error::config(format!("{name} は 1 回だけ渡す"))),
        }
    }

    /// 繰り返してよい option の値 (渡した順)。
    pub fn values(&self, name: &str) -> &[String] {
        self.values.get(name).map_or(&[], Vec::as_slice)
    }
}

/// `args` (道具の名前とサブコマンドを除いたもの) を `spec` で読む。
pub fn parse(args: &[String], spec: &Spec<'_>) -> Result<Parsed> {
    let mut p = Parsed::default();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        if arg == "--" {
            p.positionals.extend(it.by_ref().cloned());
            break;
        }
        if arg == "-h" || arg == "--help" {
            p.help = true;
            continue;
        }
        // `-` で始まっても、`=` より前に空白があれば文 (`- 箇条書き` を pjp child send に渡すなど)。option の名前に空白は無い
        let name_part = arg.split('=').next().unwrap_or_default();
        if !arg.starts_with('-') || arg == "-" || name_part.contains(char::is_whitespace) {
            p.positionals.push(arg.clone());
            continue;
        }
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_owned())),
            _ => (arg.as_str(), None),
        };
        if spec.flags.contains(&name) {
            if inline.is_some() {
                return Err(Error::config(format!("{name} は値を取らない")));
            }
            p.flags.insert(name.to_owned());
        } else if spec.values.contains(&name) {
            let value = match inline {
                Some(v) => v,
                None => it
                    .next()
                    .cloned()
                    .ok_or_else(|| Error::config(format!("{name} に値が要る")))?,
            };
            p.values.entry(name.to_owned()).or_default().push(value);
        } else {
            return Err(Error::config(format!("知らない option です: {arg}")));
        }
    }
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pjp_core::exit::CONFIG;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| (*x).to_owned()).collect()
    }

    const SPEC: Spec<'static> = Spec {
        flags: &["--chrome", "--partial"],
        values: &["--on", "--pack", "--lines"],
    };

    #[test]
    fn reads_flags_values_and_positionals() {
        let p = parse(
            &s(&[
                "A",
                "--on",
                "wsl1",
                "--pack=lang",
                "--pack",
                "notion",
                "--chrome",
                "B",
            ]),
            &SPEC,
        )
        .unwrap();
        assert_eq!(p.positionals, s(&["A", "B"]));
        assert_eq!(p.value("--on").unwrap(), Some("wsl1"));
        assert_eq!(p.values("--pack"), s(&["lang", "notion"]));
        assert!(p.flag("--chrome"));
        assert!(!p.flag("--partial"));
        assert!(!p.help());
    }

    #[test]
    fn value_may_start_with_dash_and_double_dash_ends_options() {
        let p = parse(&s(&["--lines", "-1", "--", "--chrome", "-x"]), &SPEC).unwrap();
        assert_eq!(p.value("--lines").unwrap(), Some("-1"));
        assert_eq!(p.positionals, s(&["--chrome", "-x"]));
        assert!(!p.flag("--chrome"));
    }

    #[test]
    fn errors_are_config_errors() {
        for bad in [
            s(&["--nope"]),
            s(&["-x"]),
            s(&["--on"]),
            s(&["--chrome=yes"]),
        ] {
            let e = parse(&bad, &SPEC).unwrap_err();
            assert_eq!(e.code(), CONFIG, "{bad:?}: {e}");
        }
        let p = parse(&s(&["--on", "a", "--on", "b"]), &SPEC).unwrap();
        assert_eq!(p.value("--on").unwrap_err().code(), CONFIG);
    }

    #[test]
    fn text_starting_with_dash_and_space_is_positional() {
        let p = parse(&s(&["A", "- item one", "--on=a b"]), &SPEC).unwrap();
        assert_eq!(p.positionals, s(&["A", "- item one"]));
        assert_eq!(p.value("--on").unwrap(), Some("a b"));
        assert_eq!(
            parse(&s(&["-x y"]), &SPEC).unwrap().positionals,
            s(&["-x y"])
        );
    }

    #[test]
    fn help_and_lone_dash() {
        let p = parse(&s(&["-h", "-"]), &SPEC).unwrap();
        assert!(p.help());
        assert_eq!(p.positionals, s(&["-"]));
        assert!(parse(&s(&["--help"]), &SPEC).unwrap().help());
    }
}
