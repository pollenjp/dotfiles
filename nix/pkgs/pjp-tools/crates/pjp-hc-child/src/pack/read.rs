//! SKILL.md の読み方 (pack.py の `split_frontmatter`・`read_packs`・`read_sections` と、その正規表現の写し)。
//!
//! 正規表現は crate を足さずに手で写す。どれも後戻りしても結果の変わらない形なので、前から 1 回なめれば同じに当たる。

use std::collections::BTreeSet;

use crate::pyfmt;

/// 入口の skill の名前の頭。
pub const ENTRY_PREFIX: &str = "pjp-pack-";

/// 読めない形を直す道しるべ (pack.py の `CANON_HINT`。読む道具の名前だけ `pjp pack` に)。
pub const CANON_HINT: &str = "metadata: の行の下に 2 字下げで pjp-pack: <pack> と書く。pack をいくつも書くなら、空白 1 つで区切って同じ行に並べる (dotfiles の bootstrap と pjp pack は行で読む)";

/// (frontmatter の行, 本文の行)。frontmatter が無ければ (None, 全部の行)。
///
/// Claude Code は値の途中の --- でも frontmatter を閉じるが、それは lint.sh が落とすので、--- で始まる行で閉じる。
pub fn split_frontmatter(text: &str) -> (Option<Vec<&str>>, Vec<&str>) {
    let lines = pyfmt::splitlines(text.trim_start_matches('\u{feff}'));
    if lines.first().is_none_or(|l| pyfmt::rstrip(l) != "---") {
        return (None, lines);
    }
    match lines.iter().skip(1).position(|l| l.starts_with("---")) {
        Some(k) => {
            let close = k + 1;
            (Some(lines[1..close].to_vec()), lines[close + 1..].to_vec())
        }
        None => (None, lines),
    }
}

/// 頭の半角空白の数 (pack.py の `indent_of`。タブは数えない)。
fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start_matches(' ').len()
}

/// `[a-z0-9]+(?:-[a-z0-9]+)*` の全体に当たるか。
pub fn is_pack_name(s: &str) -> bool {
    !s.is_empty()
        && s.split('-').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
}

/// `pjp-pack(?![-\w])` がどこかに当たるか (`pjp-pack-diagram` のような入口の名前は数えない)。
fn mentions_pack_key(s: &str) -> bool {
    s.match_indices("pjp-pack").any(|(i, m)| {
        s[i + m.len()..]
            .chars()
            .next()
            .is_none_or(|c| c != '-' && !pyfmt::is_word(c))
    })
}

/// `^[ \t]*["']?pjp-pack["']?[ \t]*:` に当たるか (pjp-pack を key にした行)。
fn is_key_line(line: &str) -> bool {
    let rest = line.trim_start_matches([' ', '\t']);
    let rest = rest.strip_prefix(['"', '\'']).unwrap_or(rest);
    let Some(rest) = rest.strip_prefix("pjp-pack") else {
        return false;
    };
    let rest = rest.strip_prefix(['"', '\'']).unwrap_or(rest);
    rest.trim_start_matches([' ', '\t']).starts_with(':')
}

/// `^  pjp-pack: ([a-z0-9]+(?:-[a-z0-9]+)*(?: [a-z0-9]+(?:-[a-z0-9]+)*)*)$` の pack の名前 (書いた順)。
///
/// 名前は空白 1 つで区切る (2 つ以上の空白・タブ・末尾の空白は当たらない)。
fn canon_packs(line: &str) -> Option<Vec<&str>> {
    let names: Vec<&str> = line.strip_prefix("  pjp-pack: ")?.split(' ').collect();
    names.iter().all(|n| is_pack_name(n)).then_some(names)
}

/// `^metadata[ \t]*:(.*)$` の `(.*)`。
fn metadata_rest(line: &str) -> Option<&str> {
    line.strip_prefix("metadata")?
        .trim_start_matches([' ', '\t'])
        .strip_prefix(':')
}

/// `:[ \t]*[|>][-+0-9]*[ \t]*(?:#.*)?$` がどこかに当たるか (block scalar を値にする key の行)。
fn is_block_scalar(line: &str) -> bool {
    line.match_indices(':').any(|(i, _)| {
        let rest = line[i + 1..].trim_start_matches([' ', '\t']);
        let Some(rest) = rest.strip_prefix(['|', '>']) else {
            return false;
        };
        let rest = rest.trim_start_matches(|c: char| c == '-' || c == '+' || c.is_ascii_digit());
        let rest = rest.trim_start_matches([' ', '\t']);
        rest.is_empty() || rest.starts_with('#')
    })
}

/// `s` の頭が `prefix` か (ASCII の大文字小文字を問わない)。当たれば残りを返す。
fn strip_prefix_ignore_case<'s>(s: &'s str, prefix: &str) -> Option<&'s str> {
    let head = s.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix)
        .then(|| &s[prefix.len()..])
}

/// `^disable-model-invocation[ \t]*:[ \t]*true[ \t]*(?:#.*)?$` (大文字小文字を問わない) に当たるか。
fn is_disabled_line(line: &str) -> bool {
    let Some(rest) = strip_prefix_ignore_case(line, "disable-model-invocation") else {
        return false;
    };
    let Some(rest) = rest.trim_start_matches([' ', '\t']).strip_prefix(':') else {
        return false;
    };
    let Some(rest) = strip_prefix_ignore_case(rest.trim_start_matches([' ', '\t']), "true") else {
        return false;
    };
    let rest = rest.trim_start_matches([' ', '\t']);
    rest.is_empty() || rest.starts_with('#')
}

/// `^## \`?(pjp-[a-z0-9]+(?:-[a-z0-9]+)*)\`?[ \t]*$` の skill の名前 (入口の目録の節の見出し)。
fn heading_name(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("## ")?;
    let rest = rest.strip_prefix('`').unwrap_or(rest);
    let len = rest
        .bytes()
        .take_while(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
        .count();
    let (name, tail) = rest.split_at(len);
    let tail = tail.strip_prefix('`').unwrap_or(tail);
    let valid = name.strip_prefix("pjp-").is_some_and(is_pack_name);
    (valid && tail.trim_start_matches([' ', '\t']).is_empty()).then_some(name)
}

/// `^#{1,2}(?:[ \t]|$)` に当たるか (目録の節を閉じる見出し。### は節の中の見出し)。
fn is_section_end(line: &str) -> bool {
    let hashes = line.bytes().take_while(|b| *b == b'#').count();
    (1..=2).contains(&hashes) && matches!(line.as_bytes().get(hashes), None | Some(b' ' | b'\t'))
}

/// `^[ ]{0,3}(\`{3,}|~{3,})(.*)$` の (柵, 残り)。
fn fence(line: &str) -> Option<(&str, &str)> {
    let spaces = line.bytes().take_while(|b| *b == b' ').count();
    if spaces > 3 {
        return None;
    }
    let rest = &line[spaces..];
    let mark = rest.bytes().next().filter(|b| *b == b'`' || *b == b'~')?;
    let run = rest.bytes().take_while(|b| *b == mark).count();
    (run >= 3).then(|| rest.split_at(run))
}

/// frontmatter の行から pjp-pack に書いた pack (書いた順。先頭が主の pack) と、読めない形の指摘を返す
/// (pack.py の `read_packs`)。
///
/// 読めない形が 1 つでもあれば pack は空にする (YAML で読む側と値が食い違いうるので、どの pack にも数えない)。
/// 同じ pack を 2 度書いた値も読めない形に数える。
/// 行で読むので、YAML の形をすべては追わない。claude-skills の lint.sh は yq の値とこの形を照らす。
pub fn read_packs(fm: &[&str]) -> (Vec<String>, Vec<String>) {
    let mut packs: Option<Vec<String>> = None; // pjp-pack の行を読んだら、その値
    let mut problems = Vec::new();
    let mut in_meta = false;
    let mut child_indent: Option<usize> = None;
    let mut scalar_indent: Option<usize> = None;
    for (i, line) in fm.iter().enumerate() {
        let lineno = i + 2; // ファイルの行 (1 行目は ---)
        let stripped = pyfmt::strip(line);
        if let Some(si) = scalar_indent {
            if stripped.is_empty() || indent_of(line) > si {
                continue;
            }
            scalar_indent = None;
        }
        if stripped.is_empty() || stripped.starts_with('#') {
            continue; // 空行とコメント (0 桁目のコメントも block を閉じない)
        }
        let ind = indent_of(line);
        if ind == 0 {
            in_meta = false; // 0 桁目の key の行で block が変わる
            if let Some(rest) = metadata_rest(line) {
                let rest = pyfmt::strip(rest);
                if !rest.is_empty() && !rest.starts_with('#') {
                    if mentions_pack_key(rest) {
                        problems.push(format!(
                            "{lineno} 行目の metadata を 1 行で書いています。{CANON_HINT}"
                        ));
                    }
                } else {
                    in_meta = true;
                    child_indent = None;
                }
            }
        } else if in_meta && child_indent.is_none() {
            child_indent = Some(ind);
        }
        if is_block_scalar(line) {
            scalar_indent = Some(ind);
        }
        if in_meta
            && ind > 0
            && (stripped.starts_with('{') || stripped.starts_with('['))
            && mentions_pack_key(line)
        {
            problems.push(format!(
                "{lineno} 行目の pjp-pack を 1 行の map で書いています。{CANON_HINT}"
            ));
            continue;
        }
        if !is_key_line(line) {
            continue;
        }
        match canon_packs(line) {
            Some(names) if in_meta && child_indent == Some(2) => {
                if packs.is_some() {
                    problems.push(format!(
                        "{lineno} 行目: pjp-pack の行が 2 つあります (pack をいくつも書くなら、1 行に空白で区切って並べる)"
                    ));
                } else {
                    // 2 度書いた名前を、はじめに書いた順に 1 回ずつ出す
                    let mut told = BTreeSet::new();
                    for p in &names {
                        if names.iter().filter(|q| *q == p).count() > 1 && told.insert(*p) {
                            problems.push(format!(
                                "{lineno} 行目: pjp-pack に {p} を 2 度書いています"
                            ));
                        }
                    }
                    packs = Some(names.into_iter().map(str::to_owned).collect());
                }
            }
            _ => problems.push(format!(
                "{lineno} 行目の pjp-pack を読めません。{CANON_HINT}"
            )),
        }
    }
    match packs {
        Some(p) if problems.is_empty() => (p, problems),
        _ => (Vec::new(), problems),
    }
}

/// 入口の本文から、目録の節 (## <skill の名前>) を書いた順に (名前, 節の本文) で返す (pack.py の `read_sections`)。
///
/// 節の本文は見出しの次の行から、次の # か ## の見出しの手前まで (### の見出しは節の中)。code block の中の見出しは
/// 見出しに数えない (行は節の本文に入る)。同じ名前の節は、どれも返す。
pub fn read_sections(body: &[&str]) -> Vec<(String, String)> {
    let mut sections: Vec<(String, Vec<&str>)> = Vec::new();
    let mut current: Option<usize> = None; // 今の目録の節 (sections の添字。目録の節の外なら None)
    let mut open: Option<&str> = None; // 開いている柵 (``` や ````)
    for line in body {
        let f = fence(line);
        match open {
            None if f.is_some() => open = f.map(|(run, _)| run),
            Some(cur) => {
                // 閉じる柵は同じ文字で、開いた柵より短くなく、後ろに何も無い
                if let Some((run, rest)) = f
                    && run.as_bytes()[0] == cur.as_bytes()[0]
                    && run.len() >= cur.len()
                    && pyfmt::strip(rest).is_empty()
                {
                    open = None;
                }
            }
            None if is_section_end(line) => {
                current = heading_name(line).map(|name| {
                    sections.push((name.to_owned(), Vec::new()));
                    sections.len() - 1
                });
                continue;
            }
            None => {}
        }
        if let Some(k) = current {
            sections[k].1.push(line);
        }
    }
    sections
        .into_iter()
        .map(|(name, lines)| (name, lines.join("\n")))
        .collect()
}

/// frontmatter の行のどれかが `disable-model-invocation: true` か。
pub fn is_disabled(fm: &[&str]) -> bool {
    fm.iter().any(|l| is_disabled_line(l))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fm(text: &str) -> Vec<&str> {
        pyfmt::splitlines(text)
    }

    fn packs_of(text: &str) -> (Vec<String>, Vec<String>) {
        read_packs(&fm(text))
    }

    fn owned(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| (*s).to_owned()).collect()
    }

    /// 目録の節の名前 (書いた順。pack.py の `read_catalog`)。
    fn read_catalog(body: &[&str]) -> Vec<String> {
        read_sections(body)
            .into_iter()
            .map(|(name, _)| name)
            .collect()
    }

    #[test]
    fn read_packs_canonical() {
        assert_eq!(
            packs_of("name: x\nmetadata:\n  pjp-pack: diagram\n"),
            (owned(&["diagram"]), vec![])
        );
    }

    #[test]
    fn read_packs_multi() {
        // 空白 1 つで区切って並べる。書いた順のまま (先頭が主の pack)
        assert_eq!(
            packs_of("metadata:\n  pjp-pack: notion docs\n"),
            (owned(&["notion", "docs"]), vec![])
        );
        assert_eq!(
            packs_of("metadata:\n  pjp-pack: repo diagram notion\n"),
            (owned(&["repo", "diagram", "notion"]), vec![])
        );
    }

    #[test]
    fn read_packs_absent_or_other_keys() {
        assert_eq!(packs_of("name: x\ndescription: y\n"), (vec![], vec![]));
        assert_eq!(packs_of("metadata:\n  owner: me\n"), (vec![], vec![]));
        assert_eq!(
            packs_of("metadata:\n  owner: me\n  pjp-pack: video\n"),
            (owned(&["video"]), vec![])
        );
        assert_eq!(
            packs_of("metadata:\n  owner: me\nname: x\n"),
            (vec![], vec![])
        );
    }

    #[test]
    fn read_packs_col0_comment_keeps_block() {
        assert_eq!(
            packs_of("metadata:\n# c\n  pjp-pack: video\n"),
            (owned(&["video"]), vec![])
        );
    }

    #[test]
    fn read_packs_unreadable_forms() {
        // 行番号はファイルの行 (frontmatter の 1 行目はファイルの 2 行目)
        let cases = [
            (
                "metadata: {pjp-pack: diagram}\n",
                "2 行目の metadata を 1 行で書いています",
            ),
            (
                "metadata:\n  pjp-pack: \"diagram\"\n",
                "3 行目の pjp-pack を読めません",
            ),
            (
                "metadata:\n  'pjp-pack': diagram\n",
                "3 行目の pjp-pack を読めません",
            ),
            (
                "metadata:\n    pjp-pack: diagram\n",
                "3 行目の pjp-pack を読めません",
            ),
            (
                "metadata:\n  pjp-pack: diagram # c\n",
                "3 行目の pjp-pack を読めません",
            ),
            (
                "metadata:\n  pjp-pack: Diagram\n",
                "3 行目の pjp-pack を読めません",
            ),
            ("pjp-pack: diagram\n", "2 行目の pjp-pack を読めません"),
            (
                "metadata:\n\tpjp-pack: diagram\n",
                "3 行目の pjp-pack を読めません",
            ),
            // pack をいくつも書くときに読めない形: 2 つの空白・タブ・末尾の空白・「,」・リスト・コロンの後ろの 2 つの空白
            (
                "metadata:\n  pjp-pack: notion  docs\n",
                "3 行目の pjp-pack を読めません",
            ),
            (
                "metadata:\n  pjp-pack: notion\tdocs\n",
                "3 行目の pjp-pack を読めません",
            ),
            (
                "metadata:\n  pjp-pack: notion docs \n",
                "3 行目の pjp-pack を読めません",
            ),
            (
                "metadata:\n  pjp-pack: notion,docs\n",
                "3 行目の pjp-pack を読めません",
            ),
            (
                "metadata:\n  pjp-pack: notion, docs\n",
                "3 行目の pjp-pack を読めません",
            ),
            (
                "metadata:\n  pjp-pack: [notion, docs]\n",
                "3 行目の pjp-pack を読めません",
            ),
            (
                "metadata:\n  pjp-pack:  notion\n",
                "3 行目の pjp-pack を読めません",
            ),
        ];
        for (text, want) in cases {
            let (packs, problems) = packs_of(text);
            assert_eq!(packs, Vec::<String>::new(), "{text:?}");
            assert_eq!(problems.len(), 1, "{text:?}: {problems:?}");
            assert!(problems[0].starts_with(want), "{text:?}: {problems:?}");
            assert!(problems[0].ends_with(CANON_HINT), "{text:?}: {problems:?}");
        }
    }

    #[test]
    fn read_packs_duplicate_line() {
        // YAML は後の値を採るので、どちらの値にもしない (どの pack にも数えない)
        let (packs, problems) = packs_of("metadata:\n  pjp-pack: a\n  pjp-pack: b\n");
        assert_eq!(packs, Vec::<String>::new());
        assert_eq!(
            problems,
            [
                "4 行目: pjp-pack の行が 2 つあります (pack をいくつも書くなら、1 行に空白で区切って並べる)"
            ]
        );
    }

    #[test]
    fn read_packs_duplicate_name() {
        let (packs, problems) = packs_of("metadata:\n  pjp-pack: notion docs notion\n");
        assert_eq!(packs, Vec::<String>::new());
        assert_eq!(problems, ["3 行目: pjp-pack に notion を 2 度書いています"]);
        // 2 度書いた名前が 2 つあれば、はじめに書いた順に 1 回ずつ
        let (_, problems) = packs_of("metadata:\n  pjp-pack: b a b a a\n");
        assert_eq!(
            problems,
            [
                "3 行目: pjp-pack に b を 2 度書いています",
                "3 行目: pjp-pack に a を 2 度書いています",
            ]
        );
    }

    #[test]
    fn read_packs_entry_name_and_text_are_not_keys() {
        assert_eq!(
            packs_of("metadata: {owner: pjp-pack-diagram}\n"),
            (vec![], vec![])
        );
        assert_eq!(
            packs_of(
                "description: pjp-pack: diagram のように書く\nmetadata:\n  # pjp-pack: old\n  pjp-pack: video\n"
            ),
            (owned(&["video"]), vec![])
        );
    }

    #[test]
    fn read_packs_block_scalars_are_skipped() {
        assert_eq!(
            packs_of(
                "description: >-\n  pjp-pack: demo のように\n  pjp-pack: x\nmetadata:\n  pjp-pack: video\n"
            ),
            (owned(&["video"]), vec![])
        );
        assert_eq!(
            packs_of("metadata:\n  note: |\n    pjp-pack: x\n  pjp-pack: video\n"),
            (owned(&["video"]), vec![])
        );
    }

    #[test]
    fn read_packs_child_of_a_child_is_not_read() {
        let (packs, problems) = packs_of("metadata:\n  sub:\n    pjp-pack: demo\n");
        assert_eq!(packs, Vec::<String>::new());
        assert_eq!(problems.len(), 1);
        assert!(
            problems[0].starts_with("4 行目の pjp-pack を読めません"),
            "{problems:?}"
        );
        let (packs, problems) = packs_of("metadata:\n pjp-pack: demo\n");
        assert_eq!(packs, Vec::<String>::new());
        assert!(
            problems[0].starts_with("3 行目の pjp-pack を読めません"),
            "{problems:?}"
        );
        // metadata の子が 1 字下げなら、2 字下げの行は孫 (YAML では metadata.sub.pjp-pack)
        for value in ["demo", "demo other"] {
            let (packs, problems) = packs_of(&format!("metadata:\n sub:\n  pjp-pack: {value}\n"));
            assert_eq!(packs, Vec::<String>::new(), "{value}");
            assert_eq!(problems.len(), 1, "{value}: {problems:?}");
        }
    }

    #[test]
    fn read_packs_flow_map_on_the_next_line() {
        let (packs, problems) = packs_of("metadata:\n  {pjp-pack: demo}\n");
        assert_eq!(packs, Vec::<String>::new());
        assert_eq!(
            problems,
            [format!(
                "3 行目の pjp-pack を 1 行の map で書いています。{CANON_HINT}"
            )]
        );
    }

    #[test]
    fn read_catalog_headings() {
        let body = fm(
            "# 入口\n\n## pjp-a\n## `pjp-b`\n### pjp-c\n## pjp-d x\n##  pjp-e\n## pjp-f-\n## pjp-g  \n```\n## pjp-h\n```\n## pjp-i\n",
        );
        assert_eq!(read_catalog(&body), ["pjp-a", "pjp-b", "pjp-g", "pjp-i"]);
    }

    #[test]
    fn read_catalog_nested_fences() {
        let body = fm(
            "````\n```\n## pjp-x\n```\n## pjp-y\n````\n## pjp-z\n~~~\n## pjp-w\n~~~ x\n~~~\n## pjp-v\n",
        );
        assert_eq!(read_catalog(&body), ["pjp-z", "pjp-v"]);
        // 4 字下げは柵でない
        assert_eq!(read_catalog(&fm("    ```\n## pjp-a\n")), ["pjp-a"]);
    }

    fn sections(v: &[(&str, &str)]) -> Vec<(String, String)> {
        v.iter()
            .map(|(n, t)| ((*n).to_owned(), (*t).to_owned()))
            .collect()
    }

    #[test]
    fn read_sections_bodies() {
        // 節は次の # か ## の見出しの手前まで。### と code block の中の見出しは節を閉じない
        let body = fm(
            "# 入口\n前置き\n## pjp-a\na の本文\n### 小見出し\na の続き\n```md\n## pjp-in-fence\n```\n## 選び方\n選び方の本文\n## pjp-b\nb の本文\n# 付録\n付録の本文\n",
        );
        assert_eq!(
            read_sections(&body),
            sections(&[
                (
                    "pjp-a",
                    "a の本文\n### 小見出し\na の続き\n```md\n## pjp-in-fence\n```"
                ),
                ("pjp-b", "b の本文"),
            ])
        );
    }

    #[test]
    fn read_sections_ends_and_duplicates() {
        // 「#」だけ・「##」だけの行も節を閉じる。「#x」「##x」「###」は閉じない。同じ名前の節は、どちらも返す
        let body = fm("## pjp-a\nx\n#x\n##x\n###\n#\ny\n## pjp-a\nz\n##\nw\n## `pjp-b`\n");
        assert_eq!(
            read_sections(&body),
            sections(&[("pjp-a", "x\n#x\n##x\n###"), ("pjp-a", "z"), ("pjp-b", "")])
        );
        assert!(is_section_end("#\tx"));
        assert!(!is_section_end(" ## pjp-a"));
    }

    #[test]
    fn frontmatter_split_and_bom() {
        let (f, body) = split_frontmatter("\u{feff}---\r\nname: a\r\n---\r\nbody\r\n");
        assert_eq!(f.unwrap(), ["name: a"]);
        assert_eq!(body, ["body"]);
        let (f, body) = split_frontmatter("name: a\n");
        assert!(f.is_none());
        assert_eq!(body, ["name: a"]);
        let (f, _) = split_frontmatter("---  \nname: a\n---x\n");
        assert_eq!(f.unwrap(), ["name: a"]);
        assert!(split_frontmatter("---\nname: a\n").0.is_none());
    }

    #[test]
    fn disabled_lines() {
        assert!(is_disabled(&["disable-model-invocation: true"]));
        assert!(is_disabled(&["Disable-Model-Invocation :TRUE # x"]));
        assert!(!is_disabled(&["  disable-model-invocation: true"]));
        assert!(!is_disabled(&["disable-model-invocation: false"]));
        assert!(!is_disabled(&["disable-model-invocation: truex"]));
    }

    #[test]
    fn small_matchers() {
        assert!(is_pack_name("a-b1"));
        assert!(!is_pack_name("a--b"));
        assert!(!is_pack_name("-a"));
        assert!(!is_pack_name(""));
        assert!(mentions_pack_key("{pjp-pack: x}"));
        assert!(mentions_pack_key("pjp-pack"));
        assert!(!mentions_pack_key("pjp-pack-diagram"));
        assert!(!mentions_pack_key("pjp-packの"));
        assert!(is_key_line(" \t\"pjp-pack\" :x"));
        assert!(!is_key_line("pjp-packx: y"));
        assert!(is_block_scalar("description: >-"));
        assert!(is_block_scalar("a: |2 # c"));
        assert!(!is_block_scalar("a: |x"));
        assert!(!is_block_scalar("a: b"));
        assert_eq!(fence("   ~~~~ js"), Some(("~~~~", " js")));
        assert_eq!(fence("``"), None);
        assert_eq!(canon_packs("  pjp-pack: a b-1"), Some(vec!["a", "b-1"]));
        assert_eq!(canon_packs("  pjp-pack: "), None);
        assert_eq!(canon_packs("  pjp-pack: a "), None);
    }
}
