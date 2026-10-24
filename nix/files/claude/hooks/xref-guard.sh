#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の hook。public な repo に、ほかの repo の issue・PR・commit への参照を書く git push と gh pr create
# などを、打つ前に止める (ADR 033)。
#
# public な repo の PR の本文・コメントや commit の message に、ほかの repo への参照 (owner/repo#番号・PR や issue の
# URL など) をそのまま書くと、GitHub は参照先の timeline に「mentioned this」「referenced」の跡を残す。付いた跡は、本文を
# 直しても、force push で commit を外しても消えない (dotfiles の PR #159)。commit の跡は push の時点で付くので、PR を
# 出したあとに気づいても間に合わない。打つ前に止め (permissionDecision の deny)、どこか・どう直すかを Claude に返す。
#
# ## 止めるもの (PreToolUse・matcher Bash)
#
#   gh pr create・edit・comment・review・merge、gh issue create・edit・comment
#       タイトル (-t・--title) と merge の commit の件名・本文 (gh pr merge の --subject・--body) は backquote の中も
#       数え、本文・コメント (-b・--body・-F・--body-file) は code block (``` か ~~~ の囲み) と inline code の外だけを数える
#
# 拾う形は claude-skills の ticket.sh pr (pjp-dev-tracker の ticket.py の XREF_RES と strip_code) と同じ: owner/repo#番号・
# owner/repo@sha (7〜40 桁)・github.com の issues・pull・discussions・commit の URL。同じ repo (-R・引数の PR の URL・
# GH_REPO の repo。どれも無ければ dir の remote の repo を全部) と #番号 は数えない。
#
# 参照が見つかったときだけ、gh repo view で公開範囲を引く (10 秒で切る。控えは持たない: private から public に変えた
# 直後に古い値で通さない)。PRIVATE・INTERNAL は通し、PUBLIC と、引けないもの (gh が無い・未ログイン・時間切れ・
# github.com でない host) は止める。
#
# 通す口: 単純コマンドの頭の PJP_ALLOW_XREF=1 (env の引数も。bash -c などの中にも効く)。使うのは、ユーザーがその参照を
# 書くと明示したときだけ (止めたときに返す文にもそう書く)。
#
# ## 読み方
#
# コマンドの文字を awk で単純コマンドに分ける (split_commands)。元は ssh-agent-notice.sh の lexer で、次を変えた。
#
#   - heredoc の本文・here-string・< file を、その単純コマンドの stdin として残す。パイプでつながっているかも残す
#     (gh … -F - の本文に、そのコマンドの heredoc か、パイプの前の cat <<EOF・echo を使う)
#   - 語の中の改行を残す (本文の code block の判定に要る)。1 つの単純コマンドは「<P|-> US <stdin> US <語> US …」の
#     1 レコード (US は \037、レコードの終わりは \036。stdin は H<本文>・F<path>・空)
#   - $( )・<( ) の閉じ括弧は、引用符・heredoc の本文・コメントを見て探す (本文の「1)」で閉じない)
#   - $( ) を値に置き換える: $(cat <<EOF … EOF) は heredoc の本文、$(cat <file>)・$(< <file>) はファイルの中身
#     (印 \002<path>\003 を bash の側で読む)、ほかは中の文字のまま。中は別の単純コマンドとしても読む
#   - (( … )) を飛ばす (<< を heredoc と読まない)
#
# 頭の VAR=値・包むコマンド (env・sudo・timeout・nohup・nix develop -c など)・予約語は外し、bash -c・eval などに文字列で
# 渡したものは読み直す (3 段まで)。cd は後ろの単純コマンドの dir に効かせる。代入だけの単純コマンド (BODY=…・export
# BODY=…) は覚えておき、値がちょうど "$BODY" の語に入れる。script の中・関数・alias に入れたコマンドは見えない。
# 読むのは 64 KB (gawk・mawk の無いマシンでは 16 KB) まで (macOS の awk は長いコマンドで遅い。ssh-agent-notice.sh と同じ)。
#
# ## 黙る場面
#
#   - Bash 以外・push と gh を含まないコマンド・jq が無い・入力が壊れている。tool の流れを止めないよう、何があっても
#     exit 0 で終える
#
# ## 登録
#
# scripts/bootstrap-claude-hook.sh が settings.json の hooks の PreToolUse に 1 件 (matcher Bash) 足す。

set -u -o pipefail

# 黙って抜ける場合も、先に stdin を読み切る (書き手の Claude Code を待たせない)
input=$(cat) || exit 0

# 安い前段: push も gh も無い入力は読まない (この hook は Bash のたびに走る)
[[ ${input} == *push* || ${input} == *gh* ]] || exit 0
command -v jq &>/dev/null || exit 0

# 入力の 1 項目を取り出す。無い・壊れている → 空文字
field() {
  jq -r "$1 // empty" <<<"${input}" 2>/dev/null || true
}

[[ $(field '.tool_name') == Bash ]] || exit 0
cmd=$(field '.tool_input.command')
cwd=$(field '.cwd')
[[ -n ${cwd} && -d ${cwd} ]] || cwd=${PWD}
[[ ${cmd} == *push* ]] || [[ ${cmd} == *gh* && (${cmd} == *pr* || ${cmd} == *issue*) ]] || exit 0

# コマンドの文字を単純コマンドに分ける awk (上の「読み方」)。
#
#   - '…'・"…"・$'…'・\ を外して語にする。${…}・$((…)) は語のまま
#   - ; & | 改行 ( ) で分ける。[[ … ]] の中の ( ) | < > は分けない
#   - リダイレクトの先 (> f・2>&1 の 1 など) は捨て、< f は stdin の F、here-string は stdin の H にする。heredoc は
#     終わりの印までの本文を stdin の H にする
#   - 語の頭の # から行末まではコメント
read -r -d '' lexer <<'AWK' || true
BEGIN { US = "\037"; RSEP = "\036" }
{ src = (NR == 1) ? $0 : src "\n" $0 }
END {
  lex(src)
  flush_cmd(0)
  # $( )・` `・<( ) の中は、外を読み終えてから別の単純コマンドとして読む (読む間に増えた分も)
  for (qi = 1; qi <= nq; qi++) {
    nh = 0
    pipein = 0
    lex(queue[qi])
    flush_cmd(0)
  }
  for (k = 1; k <= ncmd; k++) {
    printf "%s%s%s", cpipe[k], US, cstdin[k]
    if (cnw[k] > 0) printf "%s%s", US, cwords[k]
    printf "%s", RSEP
  }
}

function add_char(ch) { word = word ch; inword = 1 }

function flush_word() {
  if (inword) {
    if (skip == 1) {
      skip = 0
    } else if (skip == 2) {
      cur_stdin = "F" word
      skip = 0
    } else if (skip == 3) {
      cur_stdin = "H" word "\n"
      skip = 0
    } else {
      if (word == "[[") inbr = 1
      if (word == "]]") inbr = 0
      words[++nw] = word
    }
  }
  word = ""
  inword = 0
}

# 単純コマンドを 1 つ閉じる。pipe が 1 なら、次の単純コマンドの stdin はこのコマンドの出力
function flush_cmd(pipe,   k, line, stored) {
  flush_word()
  stored = 0
  if (nw > 0 || cur_stdin != "" || own_hd) {
    line = ""
    for (k = 1; k <= nw; k++) line = line (k > 1 ? US : "") words[k]
    ncmd++
    cwords[ncmd] = line
    cnw[ncmd] = nw
    cpipe[ncmd] = pipein ? "P" : "-"
    cstdin[ncmd] = cur_stdin
    stored = 1
  }
  nw = 0
  skip = 0
  inbr = 0
  cur_stdin = ""
  own_hd = 0
  # a |<改行> b のように、空のコマンドではパイプを切らない
  if (stored || pipe) pipein = pipe
}

# heredoc の本文を hbody に入れ、本文を飛ばした先 (終わりの印の行の次) を返す。<<- でなければ印の行を 1 回の index で
# 探す (1 行ずつ substr で切り出すと、長い heredoc で二乗になる)
function heredoc_read(s, pos, n, delim, strip,   k, rest, eol, line) {
  if (!strip) {
    k = index("\n" substr(s, pos) "\n", "\n" delim "\n")
    if (k > 0) {
      hbody = substr(s, pos, k - 1)
      return pos + k + length(delim)
    }
    hbody = substr(s, pos)
    return n + 1
  }
  hbody = ""
  while (pos <= n) {
    rest = substr(s, pos)
    eol = index(rest, "\n")
    if (eol > 0) { line = substr(rest, 1, eol - 1); pos += eol } else { line = rest; pos = n + 1 }
    sub(/^\t+/, "", line)
    if (line == delim) break
    hbody = hbody line "\n"
  }
  return pos
}

# s の j 文字目の " に対応する " の位置
function dq_end(s, j,   n, d) {
  n = length(s)
  for (j++; j <= n; j++) {
    d = substr(s, j, 1)
    if (d == "\\") { j++; continue }
    if (d == "\"") return j
    if (d == "$" && substr(s, j + 1, 1) == "(") { j = paren_end(s, j + 1); continue }
    if (d == "`") { j = bt_end(s, j); continue }
  }
  return n + 1
}

# s の j 文字目の ` に対応する ` の位置
function bt_end(s, j,   n, d) {
  n = length(s)
  for (j++; j <= n; j++) {
    d = substr(s, j, 1)
    if (d == "\\") { j++; continue }
    if (d == "`") return j
  }
  return n + 1
}

# s の p 文字目の ( に対応する ) の位置。引用符・\・` `・heredoc の本文・コメントの中の括弧は数えない
function paren_end(s, p,   n, j, c, depth, nhd, hdl, hst, k, pos, delim, strip, prev) {
  n = length(s)
  depth = 0
  nhd = 0
  for (j = p; j <= n; j++) {
    c = substr(s, j, 1)
    if (c == "\\") { j++; continue }
    if (c == "'") {
      for (j++; j <= n && substr(s, j, 1) != "'"; j++) ;
      continue
    }
    if (c == "\"") { j = dq_end(s, j); continue }
    if (c == "`") { j = bt_end(s, j); continue }
    if (c == "(") { depth++; continue }
    if (c == ")") {
      depth--
      if (depth == 0) return j
      continue
    }
    if (c == "#") {
      prev = (j > 1) ? substr(s, j - 1, 1) : " "
      if (prev ~ /[ \t\n;&|(]/) {
        k = index(substr(s, j), "\n")
        if (k == 0) return n + 1
        j += k - 2
      }
      continue
    }
    if (c == "<" && substr(s, j + 1, 1) == "<") {
      if (substr(s, j + 2, 1) == "<") { j += 2; continue }
      j += 2
      strip = 0
      if (substr(s, j, 1) == "-") { strip = 1; j++ }
      while (substr(s, j, 1) == " " || substr(s, j, 1) == "\t") j++
      delim = ""
      for (; j <= n; j++) {
        c = substr(s, j, 1)
        if (c ~ /[ \t\n;&|<>()]/) break
        if (c == "'" || c == "\"" || c == "\\") continue
        delim = delim c
      }
      j--
      if (delim != "") { nhd++; hdl[nhd] = delim; hst[nhd] = strip }
      continue
    }
    if (c == "\n" && nhd > 0) {
      pos = j + 1
      for (k = 1; k <= nhd; k++) pos = heredoc_read(s, pos, n, hdl[k], hst[k])
      nhd = 0
      j = pos - 1
    }
  }
  return n + 1
}

# s の i 文字目からの (( … )) の終わり (算術の << を heredoc と読まない)
function arith_end(s, i,   n, j, q, d) {
  n = length(s)
  q = 0
  for (j = i; j <= n; j++) {
    d = substr(s, j, 1)
    if (d == "(") q++
    else if (d == ")") { q--; if (q == 0) return j }
  }
  return n
}

# $( ) の中の文字 → 語に入れる値。cat <<EOF … EOF だけなら本文 (末尾の改行は $( ) と同じく外す)、cat <file>・< <file>
# だけならファイルの印、ほかは中の文字のまま
function subst_value(inner,   t, n, i, c, strip, delim, e, p) {
  t = inner
  sub(/^[ \t\n]+/, "", t)
  if (t ~ /^cat[ \t]+(-[ \t]+)?<<[^<]/) {
    i = index(t, "<<") + 2
    n = length(t)
    strip = 0
    if (substr(t, i, 1) == "-") { strip = 1; i++ }
    while (substr(t, i, 1) == " " || substr(t, i, 1) == "\t") i++
    delim = ""
    for (; i <= n; i++) {
      c = substr(t, i, 1)
      if (c ~ /[ \t\n;&|<>()]/) break
      if (c == "'" || c == "\"" || c == "\\") continue
      delim = delim c
    }
    while (substr(t, i, 1) == " " || substr(t, i, 1) == "\t") i++
    if (delim != "" && substr(t, i, 1) == "\n") {
      e = heredoc_read(t, i + 1, n, delim, strip)
      if (substr(t, e) !~ /[^ \t\n]/) {
        sub(/\n+$/, "", hbody)
        return hbody
      }
    }
  }
  if (t ~ /^(cat[ \t]+|<[ \t]*)/) {
    p = t
    sub(/^(cat[ \t]+|<[ \t]*)/, "", p)
    sub(/[ \t\n]+$/, "", p)
    if (p ~ /^'[^']*'$/ || p ~ /^"[^"$`\\]*"$/) p = substr(p, 2, length(p) - 2)
    else if (p !~ /^[^ \t\n'"\\$`;&|<>()*?]+$/) p = ""
    if (p != "") return "\002" p "\003"
  }
  return "$(" inner ")"
}

# s の p 文字目の ( で始まる $( )・<( )・>( ) (kind は $ < >) を読み、語に値を足す。閉じる位置を返す
function subst(s, p, kind,   e, inner) {
  e = paren_end(s, p)
  inner = substr(s, p + 1, e - p - 1)
  queue[++nq] = inner
  if (kind == "$") add_char(subst_value(inner))
  else add_char(kind "(" inner ")")
  return e
}

# s の i 文字目の ` で始まる ` ` を読み、語に値を足す。閉じる位置を返す
function subst_bt(s, i,   e, inner) {
  e = bt_end(s, i)
  inner = substr(s, i + 1, e - i - 1)
  gsub(/\\`/, "`", inner)
  queue[++nq] = inner
  add_char(subst_value(inner))
  return e
}

# s の p 文字目の ' で始まる $'…' を読む (\n・\t を文字に戻す)。閉じる位置を返す
function ansi_c(s, p,   n, j, d, e) {
  n = length(s)
  inword = 1
  for (j = p + 1; j <= n; j++) {
    d = substr(s, j, 1)
    if (d == "\\") {
      e = substr(s, j + 1, 1)
      j++
      if (e == "n") word = word "\n"
      else if (e == "t") word = word "\t"
      else word = word e
      continue
    }
    if (d == "'") break
    word = word d
  }
  return j
}

function lex(s,   n, i, c, c2, d, j, k, q, pos, delim, strip) {
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") {
      c2 = substr(s, i + 1, 1)
      if (c2 != "\n") add_char(c2)
      i++
      continue
    }
    if (c == "'") {
      # 残りを substr で切り出すと、引用符の多い長いコマンドで二乗になる
      for (j = i + 1; j <= n && substr(s, j, 1) != "'"; j++) ;
      add_char(substr(s, i + 1, j - i - 1))
      i = j
      continue
    }
    if (c == "\"") {
      inword = 1
      for (i++; i <= n; i++) {
        d = substr(s, i, 1)
        if (d == "\\") {
          c2 = substr(s, i + 1, 1)
          if (c2 == "\"" || c2 == "\\" || c2 == "$" || c2 == "`") { word = word c2; i++; continue }
          if (c2 == "\n") { i++; continue }
          word = word d
          continue
        }
        if (d == "\"") break
        if (d == "$" && substr(s, i + 1, 1) == "(" && substr(s, i + 2, 1) != "(") { i = subst(s, i + 1, "$"); continue }
        if (d == "`") { i = subst_bt(s, i); continue }
        word = word d
      }
      continue
    }
    if (c == "$") {
      c2 = substr(s, i + 1, 1)
      if (c2 == "'") { i = ansi_c(s, i + 1); continue }
      if (c2 == "(" && substr(s, i + 2, 1) != "(") { i = subst(s, i + 1, "$"); continue }
      if (c2 == "(" || c2 == "{") {
        # $((…)) と ${…} は、対になる閉じ括弧までを語のまま足す
        q = 0
        for (j = i + 1; j <= n; j++) {
          d = substr(s, j, 1)
          if (d == c2) q++
          else if ((c2 == "(" && d == ")") || (c2 == "{" && d == "}")) { q--; if (q == 0) break }
        }
        add_char(substr(s, i, j - i + 1))
        i = j
        continue
      }
      add_char(c)
      continue
    }
    if (inbr && (c == "(" || c == ")" || c == "|" || c == "<" || c == ">" || c == "&")) { add_char(c); continue }
    if (c == "`") { i = subst_bt(s, i); continue }
    if (c == "(") {
      if (!inword && nw == 0 && substr(s, i + 1, 1) == "(") { i = arith_end(s, i); continue }
      flush_cmd(0)
      continue
    }
    if (c == ")" || c == ";") { flush_cmd(0); continue }
    if (c == "|") {
      if (substr(s, i + 1, 1) == "|") { i++; flush_cmd(0); continue }
      if (substr(s, i + 1, 1) == "&") i++
      flush_cmd(1)
      continue
    }
    if (c == "&") {
      if (substr(s, i + 1, 1) == ">") {
        flush_word()
        i++
        if (substr(s, i + 1, 1) == ">") i++
        skip = 1
        continue
      }
      if (substr(s, i + 1, 1) == "&") i++
      flush_cmd(0)
      continue
    }
    if (c == "<" || c == ">") {
      # 2> の 2 は fd なので語にしない
      if (inword && word ~ /^[0-9]+$/) { word = ""; inword = 0 } else flush_word()
      c2 = substr(s, i + 1, 1)
      if (c2 == "(") { i = subst(s, i + 1, c); continue }
      if (c == "<" && c2 == "<") {
        if (substr(s, i + 2, 1) == "<") { i += 2; skip = 3; continue }
        # heredoc: 終わりの印を覚え、次の改行の後ろで本文を読む
        i += 2
        strip = 0
        if (substr(s, i, 1) == "-") { strip = 1; i++ }
        while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
        delim = ""
        for (; i <= n; i++) {
          d = substr(s, i, 1)
          if (d ~ /[ \t\n;&|<>()]/) break
          if (d == "'" || d == "\"" || d == "\\") continue
          delim = delim d
        }
        i--
        nh++
        hd[nh] = delim
        hs[nh] = strip
        ho[nh] = ncmd + 1
        own_hd = 1
        continue
      }
      # < f は stdin のファイル。<& <> と > の先は捨てる
      skip = (c == "<" && c2 != "&" && c2 != ">") ? 2 : 1
      while (substr(s, i + 1, 1) ~ /[>&|]/) i++
      continue
    }
    if (c == "\n") {
      flush_cmd(0)
      if (nh > 0) {
        pos = i + 1
        for (k = 1; k <= nh; k++) {
          pos = heredoc_read(s, pos, n, hd[k], hs[k])
          cstdin[ho[k]] = "H" hbody
        }
        nh = 0
        i = pos - 1
      }
      continue
    }
    if (c == " " || c == "\t") { flush_word(); continue }
    if (c == "#" && !inword) {
      k = index(substr(s, i), "\n")
      if (k == 0) i = n; else i += k - 2
      continue
    }
    add_char(c)
  }
}
AWK

# 参照を探す jq (ticket.py の XREF_RES と strip_code)。Oniguruma の \w・\b は日本語も語の文字に数えるので、ASCII の
# 文字の組で書く (日本語の直後の owner/repo#1 も拾う)。
#
#   入力: 文の配列。1 つは {head, suffix, numbered, mode (md|plain), fix (commit|title|body), text}
#   出力: 見つけた参照があれば、1 行目に「#fix <直し方の種類>…」、続けて 1 件 1 行 (20 件まで)
read -r -d '' refs_lib <<'JQ' || true
def r1: "(?<![A-Za-z0-9_./-])(?<o>[A-Za-z0-9][A-Za-z0-9-]*)/(?<r>[A-Za-z0-9_.-]+)(?:#[0-9]+|@[0-9a-fA-F]{7,40})(?![A-Za-z0-9_])";
def r2: "https?://(?:www\\.)?github\\.com/(?<o>[A-Za-z0-9_.-]+)/(?<r>[A-Za-z0-9_.-]+)/(?:(?:issues|pull|discussions)/[0-9]+|commit/[0-9a-fA-F]{7,40})(?![A-Za-z0-9_])";
# code block (``` か ~~~ の囲み) の行を空にする。backquote の囲みの情報文字列に ` は来ない
def strip_fences:
  reduce (split("\n")[]) as $line ({fence: null, out: []};
    ([$line | match("^ {0,3}(?<f>`{3,}|~{3,})")] | first) as $m
    | if .fence != null then
        (if $m != null
            and ($m.captures[0].string[0:1] == .fence[0:1])
            and (($m.captures[0].string | length) >= (.fence | length))
            and ($line[$m.length:] | test("^\\s*$"))
          then .fence = null else . end)
        | .out += [""]
      elif $m != null and (($m.captures[0].string[0:1] == "`" and ($line[$m.length:] | contains("`"))) | not) then
        .fence = $m.captures[0].string | .out += [""]
      else .out += [$line] end)
  | .out | join("\n");
# inline code を外す (閉じない backquote は空行を越えない)。行の番号を保つよう、中の改行は残す
def strip_spans:
  gsub("(?<!`)(?<t>`+)(?!`)(?<c>(?:(?!\\n[ \\t]*\\n)[\\s\\S])+?)(?<!`)\\k<t>(?!`)"; " " + (.c | gsub("[^\\n]"; "")));
def clip($n): if length > $n then .[0:$n - 1] + "…" else . end;
# 行のうち、参照のまわりだけを見せる
def around($ref):
  index($ref) as $i
  | if length <= 60 then .
    elif $i == null then clip(60)
    else ([$i - 25, 0] | max) as $s | ($i + ($ref | length) + 25) as $e
      | (if $s > 0 then "…" else "" end) + .[$s:$e] + (if $e < length then "…" else "" end)
    end;
# 1 つの文の参照: [{line, ref, ctx}]。同じ参照は最初の行だけ
def refs_of($own):
  . as $t
  | ($t.text | split("\n")) as $orig
  | ((if $t.mode == "md" then ($t.text | strip_fences | strip_spans) else $t.text end) | split("\n")) as $scan
  | [range(0; $scan | length) as $i
      | ([$scan[$i] | match(r1; "g"), match(r2; "gi")] | sort_by(.offset))[]
      | .string as $ref
      | (.captures | map({key: .name, value: .string}) | from_entries) as $c
      | select((($c.o + "/" + $c.r) | ascii_downcase) as $s | ($own | any(. == $s)) | not)
      | {line: ($i + 1), ref: $ref, ctx: (($orig[$i] // $scan[$i]) | around($ref))}]
  | reduce .[] as $f ([]; if any(.[]; .ref == $f.ref) then . else . + [$f] end);
def line_of($t; $f):
  if $t.numbered then "- \($t.head) \($f.line) 行目\($t.suffix): \($f.ref) —「\($f.ctx)」"
  else "- \($t.head)\($t.suffix): \($f.ref)" end;
def report($own):
  [.[] | . as $t | refs_of($own)[] | {t: $t, f: .}] as $hits
  | if ($hits | length) == 0 then empty
    else
      ("#fix " + ([$hits[].t.fix] | unique | join(" "))),
      ($hits[0:20][] | line_of(.t; .f)),
      (if ($hits | length) > 20 then "- ほか \(($hits | length) - 20) 件" else empty end)
    end;
JQ

# lexer に使う awk と、読むコマンドの長さの上限 (ssh-agent-notice.sh と同じ)。gawk・mawk は長い文字列の substr が速い
# ので先に使う。ほかの awk (macOS の onetrue-awk) は長さの二乗で遅くなるので、上限を小さくする
pick_awk() {
  [[ -z ${awk_bin} ]] || return 0
  if awk_bin=$(command -v gawk) || awk_bin=$(command -v mawk); then
    lex_limit=65536
  else
    awk_bin="awk"
    lex_limit=16384
  fi
}
awk_bin=""
lex_limit=0

split_commands() {
  printf '%s' "$1" | LC_ALL=C "${awk_bin}" "${lexer}"
}

# expand_home <path>: 頭の ~・$HOME・${HOME} を置き換える (コマンドの語は展開していないので)
expand_home() {
  local d=$1
  # shellcheck disable=SC2016 # $HOME を文字のまま探す
  case ${d} in
    '${HOME}'*) d=${HOME}${d#'${HOME}'} ;;
    '$HOME'*) d=${HOME}${d#'$HOME'} ;;
  esac
  # shellcheck disable=SC2088 # ~ を文字のまま探す
  case ${d} in
    '~') d=${HOME} ;;
    '~/'*) d=${HOME}/${d#'~/'} ;;
  esac
  printf '%s' "${d}"
}

# join_dir <今の dir> <cd の引数>: cd の行き先。分からない (cd -) なら今の dir
join_dir() {
  local d
  d=$(expand_home "$2")
  case ${d} in
    '') printf '%s' "${HOME}" ;;
    -) printf '%s' "$1" ;;
    /*) printf '%s' "${d}" ;;
    *) printf '%s' "$1/${d}" ;;
  esac
}

# read_file <dir> <path>: ふつうのファイルなら頭の 1 MB を file_text に入れて 0 を返す (/dev/zero などで待たない)
read_file() {
  local p
  p=$(expand_home "$2")
  [[ ${p} == /* ]] || p="$1/${p}"
  file_text=""
  [[ -f ${p} && -r ${p} ]] || return 1
  file_text=$(head -c 1048576 -- "${p}" 2>/dev/null) || return 1
}

# url_parse <URL>: git の remote の URL を url_host (小文字) と url_slug (owner/repo) に分ける。手元の path・file:// は 1
url_parse() {
  local u=$1 rest
  url_host=""
  url_slug=""
  case ${u} in
    file://* | /* | ./* | ../* | '~'* | '') return 1 ;;
    *://*)
      rest=${u#*://}
      url_host=${rest%%/*}
      url_host=${url_host##*@}
      url_host=${url_host%%:*}
      rest=${rest#*/}
      ;;
    *)
      [[ ${u} =~ ^([^@/:]+@)?([^/:]+):(.*)$ ]] || return 1
      url_host=${BASH_REMATCH[2]}
      rest=${BASH_REMATCH[3]}
      ;;
  esac
  rest=${rest%/}
  rest=${rest%.git}
  [[ ${rest} =~ ([^/]+)/([^/]+)$ ]] || return 1
  url_host=${url_host,,}
  url_slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  [[ -n ${url_host} ]]
}

# remote_slugs <dir>: dir の repo の remote の owner/repo を 1 行ずつ
remote_slugs() {
  local r u
  while IFS= read -r r; do
    [[ -n ${r} ]] || continue
    u=$(git -C "$1" remote get-url "${r}" 2>/dev/null </dev/null) || continue
    url_parse "${u}" && printf '%s\n' "${url_slug}"
  done < <(git -C "$1" remote 2>/dev/null </dev/null)
}

# run_in <dir> <コマンド>…: dir で流す。10 秒で切る (timeout の無いマシンでは切らない)
run_in() {
  local dir=$1
  shift
  [[ -d ${dir} ]] || dir=${cwd}
  if command -v timeout &>/dev/null; then
    (cd -- "${dir}" && timeout 10 "$@" </dev/null)
  else
    (cd -- "${dir}" && "$@" </dev/null)
  fi
}

# visibility <dir> <[host/]owner/repo か空 (dir の repo)>: 公開範囲を vis (PUBLIC・PRIVATE・INTERNAL か空)・vis_name
# (owner/repo)・vis_why (引けなかったわけ) に入れる。同じ repo は 1 回の実行で 1 回だけ引く
declare -A vis_seen=()
visibility() {
  local dir=$1 target=$2 key out rc errf first="" l
  local -a args=(repo view)
  key=${target:-dir:${dir}}
  if [[ -n ${vis_seen[${key}]+x} ]]; then
    IFS=$'\037' read -r vis vis_name vis_why <<<"${vis_seen[${key}]}"
    return 0
  fi
  vis=""
  vis_name=""
  vis_why=""
  if ! command -v gh &>/dev/null; then
    vis_why="gh が見つからない"
  else
    [[ -z ${target} ]] || args+=("${target}")
    args+=(--json nameWithOwner,visibility)
    errf=$(mktemp "${TMPDIR:-/tmp}/xref-guard.XXXXXX") || errf=/dev/null
    out=$(run_in "${dir}" gh "${args[@]}" 2>"${errf}")
    rc=$?
    if ((rc == 124)); then
      vis_why="gh が 10 秒で返らなかった"
    elif ((rc != 0)); then
      while IFS= read -r l; do
        if [[ -n ${l//[[:space:]]/} ]]; then
          first=${l}
          break
        fi
      done <"${errf}"
      vis_why="gh: ${first:-終了コード ${rc}}"
    else
      vis=$(jq -r '.visibility // empty | ascii_upcase' <<<"${out}" 2>/dev/null)
      vis_name=$(jq -r '.nameWithOwner // empty' <<<"${out}" 2>/dev/null)
      [[ -n ${vis} ]] || vis_why="gh の出力を読めない"
    fi
    [[ ${errf} == /dev/null ]] || rm -f -- "${errf}"
  fi
  vis_seen[${key}]="${vis}"$'\037'"${vis_name}"$'\037'"${vis_why}"
}

# --- 調べる文と、止める理由

sections=()
fixes=()
job_texts=()
job_own=()

# add_text <見出し> <後ろに添える文> <行の番号を書くか (true|false)> <md|plain> <直し方 (commit|title|body)> <文>:
# 調べる文を job_texts に 1 つ足す (文は jq の stdin で渡す。引数の長さの上限に当たらない)
add_text() {
  job_texts+=("$(printf '%s' "$6" | jq -R -s -c --arg head "$1" --arg suffix "$2" --argjson numbered "$3" \
    --arg mode "$4" --arg fix "$5" '{head: $head, suffix: $suffix, numbered: $numbered, mode: $mode, fix: $fix, text: .}')")
}

# check_texts <見出し> <dir> <公開範囲を引く repo (空なら dir の repo)> <repo の名前の目安>: job_texts を、job_own を
# 同じ repo として調べる。参照があって、public か公開範囲を確かめられない repo なら、止める理由の節を sections に足す
check_texts() {
  local label=$1 dir=$2 target=$3 hint=$4 own_json out head lines name desc f
  ((${#job_texts[@]} > 0)) || return 0
  own_json=$(jq -cn '$ARGS.positional | map(ascii_downcase)' --args "${job_own[@]}")
  out=$(printf '%s\n' "${job_texts[@]}" | jq -s -r --argjson own "${own_json}" "${refs_lib}"' report($own)' 2>/dev/null) || return 0
  [[ -n ${out} ]] || return 0
  head=${out%%$'\n'*}
  lines=${out#*$'\n'}
  visibility "${dir}" "${target}"
  case ${vis} in
    PRIVATE | INTERNAL) return 0 ;;
  esac
  name=${vis_name:-${target#*/}}
  [[ -n ${name} ]] || name=${hint:-この dir の repo}
  if [[ ${vis} == PUBLIC ]]; then
    desc="public な repo"
  else
    desc="公開範囲を確かめられない: ${vis_why}"
  fi
  sections+=("${label} → ${name} (${desc}):"$'\n'"${lines}")
  for f in ${head#\#fix }; do
    [[ " ${fixes[*]} " == *" ${f} "* ]] || fixes+=("${f}")
  done
}

# expand_value <dir> <語>: 語の値を expanded に入れる。ちょうど $NAME・${NAME} で前に代入を見たなら、その値。
# $(cat <file>) の印はファイルの中身 (末尾の改行は外す。読めなければ $(cat <file>) の文字のまま)
declare -A vars=()
expand_value() {
  local v=$2 out="" rest path
  if [[ ${v} =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ && -n ${vars[${BASH_REMATCH[1]}]+x} ]]; then
    v=${vars[${BASH_REMATCH[1]}]}
  fi
  while [[ ${v} == *$'\002'*$'\003'* ]]; do
    out+=${v%%$'\002'*}
    rest=${v#*$'\002'}
    path=${rest%%$'\003'*}
    if read_file "$1" "${path}"; then
      out+=${file_text}
    else
      out+="\$(cat ${path})"
    fi
    v=${rest#*$'\003'}
  done
  expanded=${out}${v}
}

# remember <NAME=値>…: 代入を覚える (後ろの "$NAME" に入れる)
remember() {
  local a
  for a in "$@"; do
    [[ ${a} == *=* && ${a%%=*} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && vars[${a%%=*}]=${a#*=}
  done
  return 0
}

# --- gh

# gh_target <[host/]owner/repo>: gh の -R・GH_REPO の値から、同じ repo (job_own) と公開範囲を引く repo (target) を決める
gh_target() {
  local v=${1%/} host
  if [[ ${v} == */*/* ]]; then
    host=${v%%/*}
    v=${v#*/}
  else
    host=${env_host:-github.com}
  fi
  job_own=("${v}")
  target="${host,,}/${v}"
}

# gh_cmd <dir> <gh の後ろの語>…: gh pr|issue … のタイトルと本文を調べる (呼び出し元の simple の in_text・in_known・
# env_repo・env_host を使う)
gh_cmd() {
  local dir=$1 kind="${2-} ${3-}" vshort vlong x v c i k
  local title="" title_set=0 body="" body_set=0 body_file="" bf_set=0 repo_flag="" url_repo="" url_host=""
  local target="" hint="" head_t="タイトル" head_b="本文の" suffix_b=" (backquote の外)" mode_b=md fix_t=title fix_b=body
  case ${kind} in
    "pr create")
      vshort=tbFRBHalmprT
      vlong='|title|body|body-file|repo|base|head|assignee|label|milestone|project|reviewer|template|recover|'
      ;;
    "pr edit")
      vshort=tbFRBm
      vlong='|title|body|body-file|repo|base|milestone|add-assignee|remove-assignee|add-label|remove-label|add-project|remove-project|add-reviewer|remove-reviewer|'
      ;;
    "pr comment" | "issue comment")
      vshort=bFR
      vlong='|body|body-file|repo|'
      head_b="コメントの"
      ;;
    "pr review")
      vshort=bFR
      vlong='|body|body-file|repo|'
      head_b="review の本文の"
      ;;
    "pr merge")
      vshort=tbFRA
      vlong='|subject|body|body-file|repo|match-head-commit|author-email|'
      head_t="merge の commit の件名"
      head_b="merge の commit の本文の"
      suffix_b=""
      mode_b=plain
      fix_b=title
      ;;
    "issue create")
      vshort=tbFRalmpT
      vlong='|title|body|body-file|repo|assignee|label|milestone|project|template|recover|'
      ;;
    "issue edit")
      vshort=tbFRm
      vlong='|title|body|body-file|repo|milestone|add-assignee|remove-assignee|add-label|remove-label|add-project|remove-project|'
      ;;
    *) return 0 ;;
  esac
  shift 3
  local -a a=("$@")

  # gh_flag <短い名前か長い名前> <値>
  gh_flag() {
    case $1 in
      t | title | subject)
        title=$2
        title_set=1
        ;;
      b | body)
        body=$2
        body_set=1
        ;;
      F | body-file)
        body_file=$2
        bf_set=1
        ;;
      R | repo) repo_flag=$2 ;;
    esac
  }
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      --) break ;;
      --*=*)
        v=${x%%=*}
        gh_flag "${v#--}" "${x#*=}"
        ;;
      --*)
        if [[ ${vlong} == *"|${x#--}|"* ]]; then
          gh_flag "${x#--}" "${a[i + 1]-}"
          i=$((i + 1))
        fi
        ;;
      -[!-]*)
        # 束ねた短いオプション (-db x)。値を取るものが来たら、残りの文字 (頭の = は外す) か次の語が値
        for ((k = 1; k < ${#x}; k++)); do
          c=${x:k:1}
          [[ ${vshort} == *"${c}"* ]] || continue
          v=${x:k+1}
          if [[ -z ${v} ]]; then
            v=${a[i + 1]-}
            i=$((i + 1))
          fi
          gh_flag "${c}" "${v#=}"
          break
        done
        ;;
      *)
        if [[ ${x} =~ ^https?://([^/]+)/([^/]+)/([^/]+)/(pull|issues)/[0-9]+ ]]; then
          url_host=${BASH_REMATCH[1],,}
          url_repo="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
        fi
        ;;
    esac
  done

  # 同じ repo と、公開範囲を引く repo。どれも無ければ dir の remote の repo を全部同じ repo とみなし、gh に dir で引かせる
  job_texts=()
  job_own=()
  if [[ -n ${url_repo} ]]; then
    job_own=("${url_repo}")
    target="${url_host}/${url_repo}"
  elif [[ -n ${repo_flag} ]]; then
    gh_target "${repo_flag}"
  elif [[ -n ${env_repo} ]]; then
    gh_target "${env_repo}"
  else
    mapfile -t job_own < <(remote_slugs "${dir}")
    hint=${job_own[0]-}
  fi

  if ((title_set)); then
    expand_value "${dir}" "${title}"
    add_text "${head_t}" "" false plain "${fix_t}" "${expanded}"
  fi
  if ((body_set)); then
    expand_value "${dir}" "${body}"
    add_text "${head_b}" "${suffix_b}" true "${mode_b}" "${fix_b}" "${expanded}"
  fi
  if ((bf_set)); then
    if [[ ${body_file} == - || ${body_file} == /dev/stdin ]]; then
      ((in_known)) && add_text "${head_b}" "${suffix_b}" true "${mode_b}" "${fix_b}" "${in_text}"
    elif read_file "${dir}" "${body_file}"; then
      add_text "${head_b}" "${suffix_b}" true "${mode_b}" "${fix_b}" "${file_text}"
    else
      # 読めないファイル (<( ) など) は、語の文字のまま数える
      add_text "${head_b}" "${suffix_b}" true "${mode_b}" "${fix_b}" "${body_file}"
    fi
  fi
  check_texts "gh ${kind}" "${dir}" "${target}" "${hint}"
}

# --- git

git_cmd() {
  return 0
}

# --- 単純コマンドを見る

# skip_opts <値を取るオプション (| で区切る)>: 呼び出し元の w の頭のオプションを外す (値を取るものは値も)
skip_opts() {
  local takes="|$1|"
  while ((${#w[@]} > 0)); do
    case ${w[0]} in
      --)
        w=("${w[@]:1}")
        return
        ;;
      -?*)
        if [[ ${takes} == *"|${w[0]}|"* ]]; then
          w=("${w[@]:2}")
        else
          w=("${w[@]:1}")
        fi
        ;;
      *) return ;;
    esac
  done
}

# rescan <dir> <段> <文字列>: bash -c などに文字列で渡したものを読み直す。頭の VAR=値 (通す口・GH_REPO・GH_HOST) は
# 中にも効かせる (呼び出し元の simple の allow・env_repo・env_host)
inh_allow=0
inh_repo=${GH_REPO:-}
inh_host=${GH_HOST:-}
rescan() {
  local s_allow=${inh_allow} s_repo=${inh_repo} s_host=${inh_host}
  inh_allow=${allow}
  inh_repo=${env_repo}
  inh_host=${env_host}
  scan_command "$1" "$(($2 + 1))" "$3"
  inh_allow=${s_allow}
  inh_repo=${s_repo}
  inh_host=${s_host}
}

# simple <dir> <段> <P|-> <stdin> <語>…: 単純コマンドを 1 つ見る。cd なら next_dir に行き先を入れ、出力 (パイプの先の
# stdin) が分かれば out_text・out_known に入れる
simple() {
  local dir=$1 depth=$2 pipe=$3 stdin=$4
  shift 4
  local -a w=("$@") assigns=()
  local allow=${inh_allow} env_repo=${inh_repo} env_host=${inh_host} in_text="" in_known=0 i guard=0
  case ${stdin} in
    H*)
      in_text=${stdin:1}
      in_known=1
      ;;
    F*)
      if read_file "${dir}" "${stdin:1}"; then
        in_text=${file_text}
        in_known=1
      fi
      ;;
    *)
      if [[ ${pipe} == P ]]; then
        in_text=${last_out}
        in_known=${last_known}
      fi
      ;;
  esac

  # 頭の VAR=値 と予約語
  while ((${#w[@]} > 0)); do
    case ${w[0]} in
      PJP_ALLOW_XREF=*) [[ ${w[0]#*=} == 1 ]] && allow=1 ;;
      GH_REPO=*) env_repo=${w[0]#*=} ;;
      GH_HOST=*) env_host=${w[0]#*=} ;;
      '!' | '{' | '}' | if | then | else | elif | do | while | until) ;;
      for | case | select | function | 'fi' | 'done' | 'esac' | '[[' | '[') return 0 ;;
      *=*)
        [[ ${w[0]%%=*} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || break
        assigns+=("${w[0]}")
        ;;
      *) break ;;
    esac
    w=("${w[@]:1}")
  done
  if ((${#w[@]} == 0)); then
    # 代入だけの単純コマンドは、後ろの "$NAME" のために覚える
    remember "${assigns[@]}"
    return 0
  fi

  # 包むコマンドを外す。中に文字列で渡すものは読み直す
  while ((${#w[@]} > 0 && guard++ < 16)); do
    case ${w[0]##*/} in
      cd | pushd)
        next_dir=$(join_dir "${dir}" "${w[${#w[@]} - 1]}")
        ((${#w[@]} > 1)) || next_dir=${HOME}
        return 0
        ;;
      export)
        remember "${w[@]:1}"
        return 0
        ;;
      env)
        w=("${w[@]:1}")
        while ((${#w[@]} > 0)); do
          case ${w[0]} in
            -u | --unset | -C | --chdir | -S | --split-string) w=("${w[@]:2}") ;;
            PJP_ALLOW_XREF=* | GH_REPO=* | GH_HOST=*)
              case ${w[0]} in
                PJP_ALLOW_XREF=1) allow=1 ;;
                GH_REPO=*) env_repo=${w[0]#*=} ;;
                GH_HOST=*) env_host=${w[0]#*=} ;;
              esac
              w=("${w[@]:1}")
              ;;
            -* | *=*) w=("${w[@]:1}") ;;
            *) break ;;
          esac
        done
        ;;
      sudo | doas)
        w=("${w[@]:1}")
        skip_opts '-u|-g|-h|-p|-C|-D|-r|-t|-U|-T|-R'
        ;;
      exec)
        w=("${w[@]:1}")
        skip_opts '-a'
        ;;
      command | builtin)
        [[ ${w[1]-} == -v || ${w[1]-} == -V ]] && return 0
        w=("${w[@]:1}")
        skip_opts ''
        ;;
      nohup | setsid | unbuffer | chronic | time)
        w=("${w[@]:1}")
        skip_opts ''
        ;;
      nice)
        w=("${w[@]:1}")
        skip_opts '-n|--adjustment'
        ;;
      ionice)
        w=("${w[@]:1}")
        skip_opts '-c|-n|--class|--classdata'
        ;;
      stdbuf)
        w=("${w[@]:1}")
        skip_opts '-i|-o|-e|--input|--output|--error'
        ;;
      timeout)
        w=("${w[@]:1}")
        skip_opts '-s|-k|--signal|--kill-after'
        w=("${w[@]:1}")
        ;;
      xargs)
        w=("${w[@]:1}")
        skip_opts '-I|-n|-P|-L|-d|-E|-s|-a|--max-args|--max-procs|--max-lines|--delimiter|--eof|--max-chars|--arg-file'
        ;;
      watch)
        w=("${w[@]:1}")
        skip_opts '-n|--interval|-q|--equexit'
        rescan "${dir}" "${depth}" "${w[*]}"
        return 0
        ;;
      flock)
        # -c は lock のファイルの後ろにも置ける (flock FILE -c CMD)
        for ((i = 1; i < ${#w[@]}; i++)); do
          if [[ ${w[i]} == -c || ${w[i]} == --command ]]; then
            rescan "${dir}" "${depth}" "${w[i + 1]-}"
            return 0
          fi
        done
        w=("${w[@]:1}")
        skip_opts '-w|-E|--timeout|--conflict-exit-code'
        w=("${w[@]:1}")
        ;;
      bash | sh | zsh | dash | ksh | fish)
        for ((i = 1; i < ${#w[@]}; i++)); do
          case ${w[i]} in
            -o | +o | -O | +O) i=$((i + 1)) ;;
            -*)
              if [[ ${w[i]} =~ ^-[A-Za-z]*c[A-Za-z]*$ ]]; then
                rescan "${dir}" "${depth}" "${w[i + 1]-}"
                return 0
              fi
              ;;
            *) return 0 ;;
          esac
        done
        return 0
        ;;
      eval)
        rescan "${dir}" "${depth}" "${w[*]:1}"
        return 0
        ;;
      su | runuser | script)
        for ((i = 1; i < ${#w[@]}; i++)); do
          case ${w[i]} in
            -c | --command)
              rescan "${dir}" "${depth}" "${w[i + 1]-}"
              return 0
              ;;
            --command=*)
              rescan "${dir}" "${depth}" "${w[i]#*=}"
              return 0
              ;;
          esac
        done
        return 0
        ;;
      nix-shell)
        for ((i = 1; i < ${#w[@]}; i++)); do
          if [[ ${w[i]} == --run || ${w[i]} == --command ]]; then
            rescan "${dir}" "${depth}" "${w[i + 1]-}"
            return 0
          fi
        done
        break
        ;;
      nix)
        if [[ ${w[1]-} == develop || ${w[1]-} == shell ]]; then
          for ((i = 2; i < ${#w[@]}; i++)); do
            if [[ ${w[i]} == -c || ${w[i]} == --command ]]; then
              w=("${w[@]:i+1}")
              continue 2
            fi
          done
        fi
        break
        ;;
      *) break ;;
    esac
  done
  ((${#w[@]} > 0)) || return 0

  case ${w[0]##*/} in
    git) git_cmd "${dir}" "${w[@]:1}" ;;
    gh) ((allow)) || gh_cmd "${dir}" "${w[@]:1}" ;;
    cat)
      if ((${#w[@]} == 1)) || [[ ${w[1]} == - ]]; then
        out_text=${in_text}
        out_known=${in_known}
      elif read_file "${dir}" "${w[1]}"; then
        out_text=${file_text}
        out_known=1
      fi
      ;;
    echo | printf)
      out_text=${w[*]:1}
      out_known=1
      ;;
  esac
  return 0
}

# scan_command <dir> <段> <コマンドの文字列>: 単純コマンドを順に見る。cd は後ろの単純コマンドの dir に効かせる
scan_command() {
  local dir=$1 depth=$2
  local -a rec
  ((depth <= 3)) || return 0
  pick_awk
  ((${#3} <= lex_limit)) || return 0
  last_out=""
  last_known=0
  while IFS=$'\037' read -r -d $'\036' -a rec; do
    next_dir=""
    out_text=""
    out_known=0
    if ((${#rec[@]} > 2)); then
      simple "${dir}" "${depth}" "${rec[0]}" "${rec[1]}" "${rec[@]:2}"
    fi
    [[ -z ${next_dir} ]] || dir=${next_dir}
    last_out=${out_text}
    last_known=${out_known}
  done < <(split_commands "$3")
}

# --- 止める

emit() {
  local msg s
  msg="[xref-guard] ほかの repo の issue・PR・commit への参照を書こうとしているので止めた。GitHub は参照先の timeline に跡を残し、"
  msg+="付いた跡は本文を直しても force push で commit を外しても消えない。"
  for s in "${sections[@]}"; do
    msg+=$'\n\n'"${s}"
  done
  msg+=$'\n\n'"直し方:"
  if [[ " ${fixes[*]} " == *" commit "* ]]; then
    msg+=$'\n'"- commit の message からは参照を消し、「nixpkgs の PR 577218」のように # も URL も使わずに書く (commit の message は"
    msg+="Markdown ではないので、backquote で囲んでも跡が付く)。参照は PR の本文に backquote で囲んで書く"
    msg+=$'\n'"- 直前の commit なら git commit --amend、前の commit なら git rebase で message を書き換えてから push し直す"
    msg+="(同じコマンドで作る commit なら、-m の文を直す)"
  fi
  if [[ " ${fixes[*]} " == *" title "* ]]; then
    msg+=$'\n'"- タイトルからは消す (merge の commit の件名・本文も。backquote で囲んでも、merge の commit の message に写って"
    msg+="跡が付く)。「nixpkgs の PR 577218」のように言葉で書き、参照は本文に backquote で囲んで書く"
  fi
  if [[ " ${fixes[*]} " == *" body "* ]]; then
    msg+=$'\n'"- 本文・コメントの参照は backquote で囲む (\`owner/repo#123\` の形の inline code にする)。[文](URL) のリンクにもしない"
  fi
  msg+=$'\n'"- ユーザーがこの参照を書くと明示したときだけ、コマンドの頭に PJP_ALLOW_XREF=1 を付けて打ち直す (自分の判断では付けない)"
  jq -cn --arg r "${msg}" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' || true
}

scan_command "${cwd}" 0 "${cmd}"
((${#sections[@]} == 0)) || emit
exit 0
