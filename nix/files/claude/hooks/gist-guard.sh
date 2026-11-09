#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の hook。gist やペースト共有のサービス (0x0.st・transfer.sh・termbin など) へ上げるコマンドと、gist を作る・
# 書き換える MCP の tool を、打つ前にいつも止める (ADR 047)。
#
# 確かめずに外へ上げると、private な中身 (コード・設定・会話の中身) も、URL を知る誰もが読める所に出る。secret gist も
# URL を知る人には見え、ペースト共有のサービスの多くは消す手段が無い。上げてよい場面かを Claude が決めないよう、いつも
# 止め (permissionDecision の deny)、わけと、どうするかを Claude に返す。通す口 (xref-guard.sh の PJP_ALLOW_XREF=1 の
# ような印) は作らない (Claude が自分で付けられてしまう)。上げたいときは、ユーザーが自分で `! <コマンド>` と打つ (! で
# 打つコマンドは Claude の tool を通らないので、この hook は走らない)。
#
# ## 止めるもの (PreToolUse・matcher Bash)
#
#   gh gist create・new・edit・rename と知らない subcommand (hub gist も。list・ls・view・clone・delete は通す)
#   gh api・hub api の gists への書き込み
#       -f・-F・--input があって -X の無い POST と、-X・--method の POST・PATCH・PUT。endpoint は gists・/gists/…・
#       https://api.github.com/gists・GHES の …/api/v3/gists
#   curl・wget・HTTPie (http・https・xh) での gist の API への書き込み (GET・HEAD・DELETE・OPTIONS でない method)
#   gist への git push
#       push の先 (引数の remote か URL・--repo、無ければ branch.<今>.pushRemote → remote.pushDefault →
#       branch.<今>.remote → origin) の push の URL (pushurl と insteadOf を解いたもの。同じコマンドの git remote add・
#       set-url も) の host が gist.github.com・gist.<host> か、path が /gist/… (GHES)
#   ペースト共有のサービス (下の一覧) への送信
#       curl の -d・--data…・--json・-F・--form…・-T・--upload-file、wget の --post-data・--post-file・--body-…、HTTPie の
#       本文と、書き込みの method。nc・ncat・netcat・socat・telnet の宛先、> /dev/tcp/<host>/<port> などへの書き込み
#   専用のコマンド: pastebinit・wgetpaste・fpaste・gist (gem)・gist-paste・haste・nopaste (--help・-h・--version は通す)
#   glab snippet create・new (GitLab の snippet は gist にあたる)
#   python・node・deno・bun・ruby・perl・php の引数 (-c・-e の中)・stdin・同じコマンドで書いた script に、gist の API・
#       gist・ペースト共有のサービスの URL か、gist を作る呼び出し (create_gist・gists.create など) があるもの
#   読む長さ (下の「読み方」) を超えたコマンド
#       中を読まずに、上げる形の文字 (gist かペースト共有のサービスの URL・gh gist create・gh api … gists・nc の宛先・
#       専用のコマンド・push の先が gist の git push など) があれば止め、コマンドを分けるよう返す
#
# ## 止めるもの (PreToolUse・matcher mcp__.*[Gg]ist.*)
#
#   MCP の tool のうち、名前 (mcp__<server>__<tool> を _・-・.・大文字の頭で語に分ける) に gist・gists と書き込みの語
#   (create・update・edit・fork など) を両方含むもの (GitHub の MCP の create_gist・update_gist)。get・list・delete は通す
#
# ## 止めないもの
#
#   読むだけのもの (gh gist list・view・clone、gh api・curl・wget の GET、ペースト共有のサービスからのダウンロード)、
#   gh gist delete と DELETE (上げてしまったものの片付けに要る)、gist でない repo への push、--help。コマンドに書いた
#   だけのもの (commit の message・grep の引数・echo・heredoc の本文)
#
# ## ペースト共有のサービス
#
# host が一覧 (下の paste_hosts) の domain か、その sub-domain なら止める。path やただの文字では止めない
# (https://example.com/0x0.st は通す)。増やすときは paste_hosts に足す。
#
# ## 拾えないもの
#
# script のファイルの中 (同じコマンドで書いたものは読む)・関数・alias、組み立てた URL (変数をつなぐ・base64 など)・
# 短縮 URL・一覧に無いサービス・自前のサーバ、curl の -K の設定のファイル。hook は手癖を止めるためのもので、回り込みを
# 全部は塞げない。回り込まないことは、止めたときに返す文で Claude に伝える。
#
# ## 読み方
#
# コマンドの文字を awk で単純コマンドに分ける (xref-guard.sh の lexer。> /dev/tcp/… などの書き先を、送り先として
# 残すよう足した)。頭の VAR=値・包むコマンド (env・sudo・timeout・nohup・xargs・nix develop -c・mise exec -- など)・
# 予約語は外し、bash -c・eval・ssh <host> <コマンド> などに文字列で渡したもの、find -exec の中、同じコマンドで書いた
# script を bash・source で流すものは読み直す (3 段まで)。cd と git -C は後ろの単純コマンドの dir に効かせる。代入だけの
# 単純コマンド (URL=…) は覚えておき、値がちょうど "$URL" の語に入れる。
# 読むのは 64 KB (gawk・mawk の無いマシンでは 16 KB) まで (xref-guard.sh と同じ)。
#
# ## 黙る場面
#
#   - Bash と MCP の tool 以外・上げる形の語を含まない入力・jq が無い・入力が壊れている。tool の流れを止めないよう、
#     何があっても exit 0 で終える
#
# ## 登録
#
# scripts/bootstrap-claude-hook.sh が settings.json の hooks の PreToolUse に 2 件 (matcher Bash と mcp__.*[Gg]ist.*) 足す。

set -u -o pipefail

# 黙って抜ける場合も、先に stdin を読み切る (書き手の Claude Code を待たせない)
input=$(cat) || exit 0

# ペースト共有のサービス: host がこの domain か、その sub-domain なら止める
paste_hosts=(
  # テキスト
  pastebin.com paste.rs dpaste.com dpaste.org sprunge.us termbin.com ix.io bpa.st paste.debian.net paste.ubuntu.com
  rentry.co rentry.org hastebin.com paste.ee clbin.com
  # ファイル
  0x0.st transfer.sh temp.sh catbox.moe file.io tmpfiles.org bashupload.com oshi.at x0.at uguu.se envs.sh
)
# ペースト共有のサービスか gist へ上げる専用のコマンド
paste_clis=(pastebinit wgetpaste fpaste gist gist-paste haste nopaste)

# 安い前段: 上げる形の語が無い入力は読まない (この hook は Bash のたびに走る)
lc=${input,,}
hit=0
for k in gist push snippet /dev/tcp/ /dev/udp/ "${paste_hosts[@]}" "${paste_clis[@]}"; do
  if [[ ${lc} == *"${k}"* ]]; then
    hit=1
    break
  fi
done
((hit)) || exit 0
command -v jq &>/dev/null || exit 0

# 入力の 1 項目を取り出す。無い・壊れている → 空文字
field() {
  jq -r "$1 // empty" <<<"${input}" 2>/dev/null || true
}

event=$(field '.hook_event_name')
[[ -z ${event} || ${event} == PreToolUse ]] || exit 0
tool=$(field '.tool_name')

found=()
long_kb=0
lex_limit=0

# add_found <止めたもの>: 止める理由に 1 行足す (同じものは 1 回だけ)
add_found() {
  local f
  for f in "${found[@]}"; do
    [[ ${f} == "$1" ]] && return 0
  done
  found+=("$1")
}

# --- 止める

emit() {
  local msg f
  if ((long_kb)); then
    msg="[gist-guard] コマンドが長すぎて (${long_kb} KB。中を読むのは $((lex_limit / 1024)) KB まで) 中を読めず、gist か"
    msg+="ペースト共有のサービスへ上げる形の文字があるので止めた:"
  else
    msg="[gist-guard] gist かペースト共有のサービスへ上げようとしているので、打つ前に止めた:"
  fi
  for f in "${found[@]}"; do
    msg+=$'\n'"- ${f}"
  done
  msg+=$'\n\n'"確かめずに外へ上げると、private な中身 (コード・設定・会話の中身) も公開される。secret gist も URL を知る人は"
  msg+="誰でも読め、ペースト共有のサービスの多くは消せない。上げてよいかを Claude が決めないよう、この hook はいつも止める。"
  msg+=$'\n\n'"次のようにする:"
  if ((long_kb)); then
    msg+=$'\n'"- 上げるつもりが無いなら、コマンドを分けて打ち直す (短いコマンドなら中を読んで確かめる)。長い本文は heredoc に"
    msg+="せず、Write の tool でファイルに書く"
  fi
  msg+=$'\n'"- 回り込まない: 別のコマンド・別のサービス・gh api や curl で同じ API を叩く・script のファイルに書いて流す、"
  msg+="をしない"
  msg+=$'\n'"- ユーザーがこの会話で上げると明示しているなら、自分では打たず、ユーザーに \`! gh gist create <file>\` のように"
  msg+=" ! を付けて自分で打ってもらう (止めたコマンドをそのまま渡してよい)"
  msg+=$'\n'"- 明示されていないなら上げずに、何を・どこへ・なぜ上げたいかをユーザーに聞く"
  msg+=$'\n'"- Notion に載せたい HTML なら、外へ置かずに Notion の HTML ブロック (.html を File Upload で上げ、"
  msg+="embed.file_upload に付ける) で直接載せる"
  jq -cn --arg r "${msg}" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' || true
}

# --- MCP の tool

# mcp_tool <tool の名前>: mcp__<server>__<tool> を _・-・.・大文字の頭で語に分け、gist・gists と書き込みの語を両方
# 含めば止める (logistics の gist は語でないので数えない)
mcp_tool() {
  local name=$1 s="" c p="" i w gist=0 write=0
  local -a parts=()
  for ((i = 0; i < ${#name}; i++)); do
    c=${name:i:1}
    [[ ${c} == [[:upper:]] && ${p} == [[:lower:][:digit:]] ]] && s+=_
    s+=${c}
    p=${c}
  done
  s=${s,,}
  s=${s//[-.]/_}
  IFS=_ read -r -a parts <<<"${s}"
  for w in "${parts[@]}"; do
    case ${w} in
      gist | gists) gist=1 ;;
      create | update | edit | new | fork | upload | write | put | post | patch | add | rename | comment | publish | \
        share | save | set | append | upsert | paste | star | modify | replace) write=1 ;;
    esac
  done
  if ((gist && write)); then
    add_found "MCP の tool ${name} (gist を作る・書き換える)"
  fi
}

case ${tool} in
  mcp__*)
    mcp_tool "${tool}"
    ((${#found[@]} == 0)) || emit
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

cmd=$(field '.tool_input.command')
cwd=$(field '.cwd')
[[ -n ${cwd} && -d ${cwd} ]] || cwd=${PWD}
[[ -n ${cmd} ]] || exit 0

# コマンドの文字を単純コマンドに分ける awk。xref-guard.sh の lexer に、/dev/tcp・/dev/udp への書き込み (> f・>> f・<> f・
# 2> f などの先) を送り先として残すよう足した (1 つの単純コマンドは「<P|-> US <stdin> US <書き先> US <送り先> US <語> US …」
# の 1 レコード。送り先は \034 で区切る)。
#
#   - '…'・"…"・$'…'・\ を外して語にする。${…}・$((…)) は語のまま
#   - ; & | 改行 ( ) で分ける。[[ … ]] の中の ( ) | < > は分けない
#   - リダイレクトの先は、< f を stdin の F、> f・>> f・>| f・&> f (stdout) を書き先にし、ほか (2> f・2>&1 の 1 など) は
#     捨てる。here-string は stdin の H にする。heredoc は終わりの印までの本文を stdin の H にする
#   - $( )・` `・<( ) の中は、別の単純コマンドとしても読む。$(cat <<EOF … EOF) は heredoc の本文、$(cat <file>) は
#     ファイルの印 (\002<path>\003) を語に入れる
#   - 語の頭の # から行末まではコメント
read -r -d '' lexer <<'AWK' || true
BEGIN { US = "\037"; RSEP = "\036"; NSEP = "\034" }
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
    printf "%s%s%s%s%s%s%s", cpipe[k], US, cstdin[k], US, coutf[k], US, cnet[k]
    if (cnw[k] > 0) printf "%s%s", US, cwords[k]
    printf "%s", RSEP
  }
}

function add_char(ch) { word = word ch; inword = 1 }

function flush_word() {
  if (inword) {
    # /dev/tcp・/dev/udp への書き込み (> f・>> f・<> f・2> f など。< f は読むだけ) は、送り先として残す
    if ((skip == 1 || skip == 4) && word ~ /^\/dev\/(tcp|udp)\//) cur_net = cur_net (cur_net == "" ? "" : NSEP) word
    if (skip == 1) {
      skip = 0
    } else if (skip == 2) {
      cur_stdin = "F" word
      skip = 0
    } else if (skip == 3) {
      cur_stdin = "H" word "\n"
      skip = 0
    } else if (skip == 4) {
      cur_outf = word
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
  # 語の無い ( … ) > /dev/tcp/… なども、送り先があれば残す
  if (nw > 0 || cur_stdin != "" || own_hd || cur_net != "") {
    line = ""
    for (k = 1; k <= nw; k++) line = line (k > 1 ? US : "") words[k]
    ncmd++
    cwords[ncmd] = line
    cnw[ncmd] = nw
    cpipe[ncmd] = pipein ? "P" : "-"
    cstdin[ncmd] = cur_stdin
    coutf[ncmd] = cur_outf
    cnet[ncmd] = cur_net
    stored = 1
  }
  nw = 0
  skip = 0
  inbr = 0
  cur_stdin = ""
  cur_outf = ""
  cur_net = ""
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

function lex(s,   n, i, c, c2, d, j, k, q, pos, delim, strip, fd) {
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
        # &> f・&>> f は stdout の書き先
        flush_word()
        i++
        if (substr(s, i + 1, 1) == ">") i++
        skip = 4
        continue
      }
      if (substr(s, i + 1, 1) == "&") i++
      flush_cmd(0)
      continue
    }
    if (c == "<" || c == ">") {
      # 2> の 2 は fd なので語にしない
      fd = ""
      if (inword && word ~ /^[0-9]+$/) { fd = word; word = ""; inword = 0 } else flush_word()
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
      # < f は stdin のファイル、> f・>> f・>| f は stdout の書き先 (書いた中身を後ろの --body-file・-F で読む)。
      # <& <> >& と 2> などの先は捨てる
      if (c == "<") skip = (c2 != "&" && c2 != ">") ? 2 : 1
      else skip = (c2 != "&" && (fd == "" || fd == "1")) ? 4 : 1
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

# lexer に使う awk と、読むコマンドの長さの上限 (xref-guard.sh と同じ)。gawk・mawk は長い文字列の substr が速いので
# 先に使う。ほかの awk (macOS の onetrue-awk) は長さの二乗で遅くなるので、上限を小さくする
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

split_commands() {
  printf '%s' "$1" | LC_ALL=C "${awk_bin}" "${lexer}"
}

# byte_len <文字列>: バイト数 (awk は LC_ALL=C でバイトを読むので、読む長さもバイトで比べる)
byte_len() {
  LC_ALL=C
  printf '%s' "${#1}"
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

# join_dir <今の dir> <cd の引数>: cd の行き先。分からない (cd -・$( )・変数) なら今の dir (前の代入は入れる)
join_dir() {
  local d
  expand_value "$1" "$2"
  d=$(expand_home "${expanded}")
  case ${d} in
    '') printf '%s' "${HOME}" ;;
    - | *'$'* | *'`'* | *$'\002'*) printf '%s' "$1" ;;
    /*) printf '%s' "${d}" ;;
    *) printf '%s' "$1/${d}" ;;
  esac
}

# abs_path <dir> <path>: dir から見た path (/./ と // は詰める)
abs_path() {
  local p
  p=$(expand_home "$2")
  [[ ${p} == /* ]] || p="$1/${p}"
  while [[ ${p} == *'/./'* || ${p} == *'//'* ]]; do
    p=${p//\/.\//\/}
    p=${p//\/\//\/}
  done
  printf '%s' "${p}"
}

# remember_write <dir> <path> <中身が分かるか (1|0)> <中身>: 同じコマンドの前の方で書いたファイルを覚える (hook が走る
# 時点では、まだ書かれていないか、古い中身のまま)
declare -A written=()
remember_write() {
  local p
  p=$(abs_path "$1" "$2")
  if (($3)); then
    written[${p}]="K$4"
  else
    written[${p}]="U"
  fi
}

# read_written <dir> <path>: 同じコマンドの前の方で書いたファイルなら、書いた中身を file_text に入れて 0 を返す。流す
# script (bash <file>・source <file>・python <file>・bash < <file>) は、これで読む (手元にあるだけのファイルは読まない)
read_written() {
  local p
  p=$(abs_path "$1" "$2")
  file_text=""
  [[ -n ${written[${p}]+x} && ${written[${p}]} == K* ]] || return 1
  file_text=${written[${p}]:1}
}

# read_file <dir> <path>: ふつうのファイルなら頭の 1 MB を file_text に入れて 0 を返す (/dev/zero などで待たない)。同じ
# コマンドの前の方で書いたファイルは、書いた中身 (分からなければ 1)。$(cat <file>) の値 (cd の行き先など) に使う
read_file() {
  local p
  p=$(abs_path "$1" "$2")
  file_text=""
  if [[ -n ${written[${p}]+x} ]]; then
    [[ ${written[${p}]} == K* ]] || return 1
    file_text=${written[${p}]:1}
    return 0
  fi
  [[ -f ${p} && -r ${p} ]] || return 1
  file_text=$(head -c 1048576 -- "${p}" 2>/dev/null) || return 1
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

# --- 宛先

# classify_url <URL か host>: gist の API・gist・ペースト共有のサービスなら、url_kind (gist-api・gist-git・paste)・
# url_host・url_svc (一覧の domain) を入れて 0 を返す。scheme の無いもの (curl の 0x0.st・api.github.com/gists) と、
# git の scp の形 (git@gist.github.com:<id>.git) も読む。gist.githubusercontent.com (raw を読むだけ) は数えない
classify_url() {
  local rest hostport host path d
  url_kind=""
  url_host=""
  url_svc=""
  case $1 in
    *://*) rest=${1#*://} ;;
    //*) rest=${1#//} ;;
    *) rest=$1 ;;
  esac
  hostport=${rest%%[/?#]*}
  path=${rest:${#hostport}}
  hostport=${hostport##*@}
  host=${hostport%%:*}
  # :443 は port、:<id>.git・:gist は scp の形の path
  if [[ ${hostport} == *:* && ! ${hostport#*:} =~ ^[0-9]*$ ]]; then
    path="/${hostport#*:}${path}"
  fi
  host=${host%.}
  host=${host,,}
  [[ ${host} == *.* && ${host} =~ ^[a-z0-9.-]+$ ]] || return 1
  path=${path%%[?#]*}
  path=${path,,}
  url_host=${host}
  if [[ ${path} == /api/v3/gists || ${path} == /api/v3/gists/* ]] \
    || [[ ${host} == api.github.com && (${path} == /gists || ${path} == /gists/*) ]]; then
    url_kind="gist-api"
    return 0
  fi
  [[ ${host} != gist.githubusercontent.com ]] || return 1
  if [[ ${host} == gist.* || ${path} == /gist/* ]]; then
    url_kind="gist-git"
    return 0
  fi
  for d in "${paste_hosts[@]}"; do
    if [[ ${host} == "${d}" || ${host} == *".${d}" ]]; then
      url_kind="paste"
      url_svc=${d}
      return 0
    fi
  done
  return 1
}

# paste_label: classify_url が決めたペースト共有のサービスを「host (ペースト共有のサービス[ 一覧の domain])」で出す
paste_label() {
  if [[ ${url_host} == "${url_svc}" ]]; then
    printf '%s (ペースト共有のサービス)' "${url_host}"
  else
    printf '%s (ペースト共有のサービス %s)' "${url_host}" "${url_svc}"
  fi
}

# gists_endpoint <gh api の endpoint>: gists の endpoint (gists・/gists/…・full URL・GHES の api/v3/gists) なら 0
gists_endpoint() {
  local e=$1
  if [[ ${e} == *://* ]]; then
    classify_url "${e}" && [[ ${url_kind} == gist-api ]]
    return
  fi
  e=${e#/}
  e=${e%%[?#]*}
  e=${e,,}
  e=${e#api/v3/}
  [[ ${e} == gists || ${e} == gists/* ]]
}

# send_check <dir> <コマンドの名前> <method> <本文を送るか (1|0)> <URL>…: gist の API への書き込み (GET・HEAD・DELETE・
# OPTIONS でない method) と、ペースト共有のサービスへの送信 (本文があるか、書き込みの method) を found に足す
send_check() {
  local dir=$1 name=$2 method=$3 body=$4 u read_only=0
  shift 4
  case ${method} in
    GET | HEAD | DELETE | OPTIONS) read_only=1 ;;
  esac
  for u in "$@"; do
    expand_value "${dir}" "${u}"
    classify_url "${expanded}" || continue
    case ${url_kind} in
      gist-api)
        ((read_only)) || add_found "${name} ${method} ${expanded} (gist の API に書き込む)"
        ;;
      paste)
        ((read_only && ! body)) || add_found "${name} → $(paste_label)"
        ;;
    esac
  done
}

url_re='[A-Za-z][A-Za-z0-9+.-]*://[A-Za-z0-9._~:/?#@!$&*+=%-]+'
gist_call_re='(create|update|edit)_?gists?([^a-z_]|$)|gists\.(create|update)'

# code_urls <コマンドの名前> <文>: 文の中の gist の API・gist・ペースト共有のサービスの URL と、gist を作る呼び出し
# (create_gist・gists.create など) を found に足す
code_urls() {
  local name=$1 text=$2 u
  local -a urls=()
  mapfile -t urls < <(LC_ALL=C grep -Eo -- "${url_re}" <<<"${text}")
  for u in "${urls[@]}"; do
    classify_url "${u}" || continue
    case ${url_kind} in
      gist-api) add_found "${name} のコードの ${u} (gist の API)" ;;
      gist-git) add_found "${name} のコードの ${u} (gist)" ;;
      paste) add_found "${name} のコードの ${u} → $(paste_label)" ;;
    esac
  done
  if [[ ${text,,} =~ ${gist_call_re} ]]; then
    add_found "${name} のコードの ${BASH_REMATCH[0]} (gist を作る・書き換える呼び出し)"
  fi
}

# --- gh・hub・glab

# gh_cmd <gh か hub> <後ろの語>…: gh gist と gh api を見る
gh_cmd() {
  local prog=$1 x i
  shift
  local -a a=("$@")
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      -h | --help | --version) return 0 ;;
      -*) ;;
      *) break ;;
    esac
  done
  case ${a[i]-} in
    gist) gh_gist "${prog}" "${a[@]:i+1}" ;;
    api) gh_api "${prog}" "${a[@]:i+1}" ;;
  esac
}

# gh_gist <gh か hub> <gist の後ろの語>…: 作る・書き換える subcommand と、知らない subcommand を止める
gh_gist() {
  local prog=$1 x sub="" what
  shift
  for x in "$@"; do
    [[ ${x} == -h || ${x} == --help ]] && return 0
  done
  for x in "$@"; do
    if [[ ${x} != -* ]]; then
      sub=${x}
      break
    fi
  done
  case ${sub} in
    '' | list | ls | view | clone | delete) return 0 ;;
    show) [[ ${prog} == hub ]] && return 0 ;;
  esac
  case ${sub} in
    create | new) what="gist を作る" ;;
    edit | rename) what="gist を書き換える" ;;
    *) what="知らない subcommand。gist を作る・書き換えるものとみなす" ;;
  esac
  add_found "${prog} gist ${sub} (${what})"
}

# gh_api <gh か hub> <api の後ろの語>…: gists の endpoint への書き込みを止める。method は -X・--method、無ければ -f・
# -F・--input があれば POST、無ければ GET (gh の決まり)
gh_api() {
  local prog=$1 x c k v i method="" body=0 endpoint=""
  shift
  local -a a=("$@")
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      --)
        [[ -n ${endpoint} ]] || endpoint=${a[i + 1]-}
        break
        ;;
      -h | --help) return 0 ;;
      --method=*) method=${x#*=} ;;
      --method)
        method=${a[i + 1]-}
        i=$((i + 1))
        ;;
      --field=* | --raw-field=* | --input=*) body=1 ;;
      --field | --raw-field | --input)
        body=1
        i=$((i + 1))
        ;;
      --*=*) ;;
      --header | --jq | --template | --hostname | --cache | --preview) i=$((i + 1)) ;;
      --*) ;;
      -?*)
        # 束ねた短いオプション (-XPUT・-iX POST)。値を取るものが来たら、残りの文字 (頭の = は外す) か次の語が値
        for ((k = 1; k < ${#x}; k++)); do
          c=${x:k:1}
          [[ XfFHqtp == *"${c}"* ]] || continue
          v=${x:k+1}
          if [[ -z ${v} ]]; then
            v=${a[i + 1]-}
            i=$((i + 1))
          fi
          case ${c} in
            X) method=${v#=} ;;
            f | F) body=1 ;;
          esac
          break
        done
        ;;
      *) [[ -n ${endpoint} ]] || endpoint=${x} ;;
    esac
  done
  method=${method^^}
  if [[ -z ${method} ]]; then
    if ((body)); then method=POST; else method=GET; fi
  fi
  case ${method} in
    GET | HEAD | DELETE | OPTIONS) return 0 ;;
  esac
  gists_endpoint "${endpoint}" || return 0
  add_found "${prog} api ${method} ${endpoint} (gist の API に書き込む)"
}

# glab_cmd <glab の後ろの語>…: glab snippet create・new (GitLab の snippet は gist にあたる) を止める
glab_cmd() {
  local x i
  local -a a=("$@")
  for x in "${a[@]}"; do
    [[ ${x} == -h || ${x} == --help ]] && return 0
  done
  for ((i = 0; i < ${#a[@]}; i++)); do
    [[ ${a[i]} == -* ]] || break
  done
  [[ ${a[i]-} == snippet ]] || return 0
  for ((i++; i < ${#a[@]}; i++)); do
    [[ ${a[i]} == -* ]] || break
  done
  case ${a[i]-} in
    create | new) add_found "glab snippet ${a[i]} (GitLab の snippet を作る。gist にあたる)" ;;
  esac
}

# --- git

# git_in <git の引数>…: push_job の dir と git の前のオプション (gopts) で git を流す (エラーは捨てる)
git_in() {
  git -C "${dir}" "${gopts[@]}" "$@" 2>/dev/null </dev/null
}

# git_cmd <dir> <git の後ろの語>…: git push と、push より前に足す remote (git remote add・set-url) を見る
git_cmd() {
  local gdir=$1 sub=""
  shift
  local -a gopts=() a=("$@")
  while ((${#a[@]} > 0)); do
    case ${a[0]} in
      -C)
        gdir=$(join_dir "${gdir}" "${a[1]-}")
        a=("${a[@]:2}")
        ;;
      -c | --git-dir | --work-tree | --namespace | --config-env)
        gopts+=("${a[0]}" "${a[1]-}")
        a=("${a[@]:2}")
        ;;
      --git-dir=* | --work-tree=* | --namespace=* | --config-env=*)
        gopts+=("${a[0]}")
        a=("${a[@]:1}")
        ;;
      -*) a=("${a[@]:1}") ;;
      *)
        sub=${a[0]}
        a=("${a[@]:1}")
        break
        ;;
    esac
  done
  # git gh <コマンド> (GitHub へ gh の資格情報で通す dotfiles の git-gh) は、後ろの語を git の語として読む
  if [[ ${sub} == gh ]]; then
    sub=${a[0]-}
    a=("${a[@]:1}")
  fi
  case ${sub} in
    push) push_job "${gdir}" "${a[@]}" ;;
    remote) remote_job "${gdir}" "${a[@]}" ;;
  esac
}

# remote_job <dir> <git remote の後ろの語>…: 同じコマンドで足す・付け替える remote の URL を覚える (hook が走る時点では、
# まだ config に無い)
declare -A new_remotes=()
remote_job() {
  local dir=$1 i x
  shift
  local -a a=("$@") pos=()
  case ${a[0]-} in
    add | set-url) ;;
    *) return 0 ;;
  esac
  for ((i = 1; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      -t | -m) i=$((i + 1)) ;;
      -*) ;;
      *) pos+=("${x}") ;;
    esac
  done
  ((${#pos[@]} >= 2)) || return 0
  expand_value "${dir}" "${pos[1]}"
  new_remotes[${pos[0]}]=${expanded}
}

# push_job <dir> <git push の後ろの語>…: push の先の URL が gist なら止める (呼び出し元の git_cmd の gopts を使う)
push_job() {
  local dir=$1 x remote="" repo_opt="" i k c cur u
  shift
  local -a a=("$@") pos=() urls=()
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      --)
        pos+=("${a[@]:i+1}")
        break
        ;;
      # --dry-run は送らない
      -h | --help | -n | --dry-run) return 0 ;;
      --repo=*) repo_opt=${x#*=} ;;
      --repo | -o | --push-option | --receive-pack | --exec)
        [[ ${x} == --repo ]] && repo_opt=${a[i + 1]-}
        i=$((i + 1))
        ;;
      --*) ;;
      -*)
        # 束ねた短いオプション (-fu など)。-o は値を取る
        for ((k = 1; k < ${#x}; k++)); do
          c=${x:k:1}
          [[ ${c} == n ]] && return 0
          if [[ ${c} == o ]]; then
            ((k + 1 < ${#x})) || i=$((i + 1))
            break
          fi
        done
        ;;
      *) pos+=("${x}") ;;
    esac
  done

  # push の先: 引数・--repo、無ければ branch.<今>.pushRemote → remote.pushDefault → branch.<今>.remote → origin
  remote=${pos[0]:-${repo_opt}}
  if [[ -n ${remote} ]]; then
    expand_value "${dir}" "${remote}"
    remote=${expanded}
  fi
  cur=$(git_in symbolic-ref -q --short HEAD) || cur=""
  if [[ -z ${remote} ]]; then
    [[ -z ${cur} ]] || remote=$(git_in config --get "branch.${cur}.pushRemote")
    [[ -n ${remote} ]] || remote=$(git_in config --get remote.pushDefault)
    [[ -n ${remote} || -z ${cur} ]] || remote=$(git_in config --get "branch.${cur}.remote")
    [[ -n ${remote} ]] || remote=origin
  fi
  if [[ -n ${new_remotes[${remote}]+x} ]]; then
    urls=("${new_remotes[${remote}]}")
  elif [[ ${remote} != */* && -n $(git_in config --get "remote.${remote}.url") ]]; then
    # push の URL は pushurl と pushInsteadOf を解いたもの。pushurl が複数なら全部へ送る
    mapfile -t urls < <(git_in remote get-url --push --all "${remote}")
  else
    mapfile -t urls < <(git_in ls-remote --get-url "${remote}")
  fi
  ((${#urls[@]} > 0)) || urls=("${remote}")
  for u in "${urls[@]}"; do
    classify_url "${u}" || continue
    if [[ ${url_kind} == gist-git || ${url_kind} == gist-api ]]; then
      add_found "git push → ${u} (gist の repo)"
    fi
  done
}

# --- HTTP のクライアント

# curl の値を取るオプション
curl_short=AbcCdDeEFHKmoPQrtTuUwxXyYz
curl_long='|abstract-unix-socket|alt-svc|aws-sigv4|cacert|capath|cert|cert-type|ciphers|config|connect-timeout|connect-to|'
curl_long+='continue-at|cookie|cookie-jar|create-file-mode|curves|delegation|dns-interface|dns-ipv4-addr|dns-ipv6-addr|'
curl_long+='dns-servers|doh-url|dump-header|ech|egd-file|engine|etag-compare|etag-save|expect100-timeout|ftp-account|'
curl_long+='ftp-alternative-to-user|ftp-method|ftp-port|ftp-ssl-ccc-mode|happy-eyeballs-timeout-ms|haproxy-clientip|header|'
curl_long+='hostpubmd5|hostpubsha256|hsts|interface|ip-tos|ipfs-gateway|keepalive-cnt|keepalive-time|key|key-type|krb|'
curl_long+='libcurl|limit-rate|local-port|login-options|mail-auth|mail-from|mail-rcpt|max-filesize|max-redirs|max-time|'
curl_long+='netrc-file|noproxy|oauth2-bearer|output|output-dir|parallel-max|pass|pinnedpubkey|preproxy|proto|'
curl_long+='proto-default|proto-redir|proxy|proxy-cacert|proxy-capath|proxy-cert|proxy-cert-type|proxy-ciphers|'
curl_long+='proxy-crlfile|proxy-header|proxy-key|proxy-key-type|proxy-pass|proxy-pinnedpubkey|proxy-service-name|'
curl_long+='proxy-tls13-ciphers|proxy-tlsauthtype|proxy-tlspassword|proxy-tlsuser|proxy-user|quote|random-file|range|rate|'
curl_long+='referer|request-target|resolve|retry|retry-delay|retry-max-time|sasl-authzid|service-name|socks4|socks4a|'
curl_long+='socks5|socks5-gssapi-service|socks5-hostname|speed-limit|speed-time|stderr|telnet-option|tftp-blksize|'
curl_long+='time-cond|tls-max|tls13-ciphers|tlsauthtype|tlspassword|tlsuser|trace|trace-ascii|trace-config|unix-socket|'
curl_long+='url-query|user|user-agent|variable|write-out|'

# curl_cmd <dir> <curl の後ろの語>…: method は -X・--request、無ければ本文 (-d・-F・-T など) があれば POST (-G なら
# GET)、-I なら HEAD、ほかは GET
curl_cmd() {
  local dir=$1 x c k v i method="" body=0 get=0 head=0
  shift
  local -a a=("$@") urls=()
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      --)
        urls+=("${a[@]:i+1}")
        break
        ;;
      -h | --help | -M | --manual | -V | --version) return 0 ;;
      --request)
        method=${a[i + 1]-}
        i=$((i + 1))
        ;;
      --data | --data-ascii | --data-binary | --data-raw | --data-urlencode | --json | --form | --form-string | --upload-file)
        body=1
        i=$((i + 1))
        ;;
      --url)
        urls+=("${a[i + 1]-}")
        i=$((i + 1))
        ;;
      --get) get=1 ;;
      --head) head=1 ;;
      --*) [[ ${curl_long} == *"|${x#--}|"* ]] && i=$((i + 1)) ;;
      -?*)
        # 束ねた短いオプション (-sF x・-XPOST)。値を取るものが来たら、残りの文字か次の語が値
        for ((k = 1; k < ${#x}; k++)); do
          c=${x:k:1}
          case ${c} in
            G) get=1 ;;
            I) head=1 ;;
          esac
          [[ ${curl_short} == *"${c}"* ]] || continue
          v=${x:k+1}
          if [[ -z ${v} ]]; then
            v=${a[i + 1]-}
            i=$((i + 1))
          fi
          case ${c} in
            X) method=${v} ;;
            d | F | T) body=1 ;;
          esac
          break
        done
        ;;
      *) urls+=("${x}") ;;
    esac
  done
  method=${method^^}
  if [[ -z ${method} ]]; then
    if ((body && ! get)); then
      method=POST
    elif ((head)); then
      method=HEAD
    else
      method=GET
    fi
  fi
  send_check "${dir}" curl "${method}" "${body}" "${urls[@]}"
}

# wget の値を取るオプション
wget_short=aBDeIilOoPQRtTUwXY
wget_long='|output-document|output-file|append-output|input-file|base|config|tries|timeout|dns-timeout|connect-timeout|'
wget_long+='read-timeout|wait|waitretry|quota|limit-rate|bind-address|user|password|http-user|http-password|ftp-user|'
wget_long+='ftp-password|proxy-user|proxy-password|header|referer|user-agent|load-cookies|save-cookies|certificate|'
wget_long+='certificate-type|private-key|private-key-type|ca-certificate|ca-directory|crl-file|pinnedpubkey|secure-protocol|'
wget_long+='ciphers|directory-prefix|cut-dirs|level|accept|reject|accept-regex|reject-regex|domains|exclude-domains|'
wget_long+='include-directories|exclude-directories|execute|local-encoding|remote-encoding|restrict-file-names|default-page|'
wget_long+='max-redirect|compression|report-speed|use-askpass|regex-type|rejected-log|hsts-file|warc-file|warc-header|'
wget_long+='warc-max-size|warc-dedup|warc-tempdir|'

# wget_cmd <dir> <wget の後ろの語>…: method は --method、無ければ --post-data・--post-file があれば POST、ほかは GET
wget_cmd() {
  local dir=$1 x c k i method="" body=0
  shift
  local -a a=("$@") urls=()
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      --)
        urls+=("${a[@]:i+1}")
        break
        ;;
      -h | --help | -V | --version) return 0 ;;
      --post-data=* | --post-file=* | --body-data=* | --body-file=*) body=1 ;;
      --post-data | --post-file | --body-data | --body-file)
        body=1
        i=$((i + 1))
        ;;
      --method=*) method=${x#*=} ;;
      --method)
        method=${a[i + 1]-}
        i=$((i + 1))
        ;;
      --*=*) ;;
      --*) [[ ${wget_long} == *"|${x#--}|"* ]] && i=$((i + 1)) ;;
      -?*)
        for ((k = 1; k < ${#x}; k++)); do
          c=${x:k:1}
          [[ ${wget_short} == *"${c}"* ]] || continue
          [[ -n ${x:k+1} ]] || i=$((i + 1))
          break
        done
        ;;
      *) urls+=("${x}") ;;
    esac
  done
  method=${method^^}
  if [[ -z ${method} ]]; then
    if ((body)); then method=POST; else method=GET; fi
  fi
  send_check "${dir}" wget "${method}" "${body}" "${urls[@]}"
}

# httpie_cmd <dir> <名前> <後ろの語>…: HTTPie (http・https) と xh。[METHOD] URL [ITEM…] の ITEM (field=値・field:=JSON・
# field@file。name==値 は query) か stdin があれば本文で、method の既定は POST (呼び出し元の simple の in_given を使う)
httpie_cmd() {
  local dir=$1 name=$2 x i method="" body=0 no_stdin=0
  shift 2
  local -a a=("$@") urls=()
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      --help | --version) return 0 ;;
      -f | --form | --multipart | --raw=*) body=1 ;;
      --raw)
        body=1
        i=$((i + 1))
        ;;
      -I | --ignore-stdin) no_stdin=1 ;;
      --*=*) ;;
      --auth | --auth-type | --output | --session | --session-read-only | --verify | --cert | --cert-key | --proxy | \
        --timeout | --max-redirects | --print | --pretty | --style | --format-options | --response-charset | \
        --response-mime | --boundary | --ssl | --ciphers | --default-scheme | --max-headers | --history-print | --unix-socket)
        i=$((i + 1))
        ;;
      --*) ;;
      -?*) [[ ${x} =~ ^-[A-Za-z]*[aAopsP]$ ]] && i=$((i + 1)) ;;
      *)
        if ((${#urls[@]} == 0)); then
          if [[ -z ${method} && ${x^^} =~ ^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$ ]]; then
            method=${x^^}
          else
            urls+=("${x}")
          fi
        elif [[ ${x} != *==* && (${x} == *=* || ${x} == *@*) ]]; then
          body=1
        fi
        ;;
    esac
  done
  ((no_stdin || ! in_given)) || body=1
  if [[ -z ${method} ]]; then
    if ((body)); then method=POST; else method=GET; fi
  fi
  send_check "${dir}" "${name}" "${method}" "${body}" "${urls[@]}"
}

# net_cmd <dir> <名前> <後ろの語>…: nc・ncat・netcat・socat・telnet の宛先 (socat は TCP:<host>:<port> などの host) が
# ペースト共有のサービス (termbin.com など) なら止める
net_cmd() {
  local dir=$1 name=$2 x
  shift 2
  for x in "$@"; do
    [[ ${x} != -* ]] || continue
    expand_value "${dir}" "${x}"
    x=${expanded}
    [[ ${x} =~ ^[A-Za-z0-9-]+:([^:,]+): ]] && x=${BASH_REMATCH[1]}
    if classify_url "${x}" && [[ ${url_kind} == paste ]]; then
      add_found "${name} → $(paste_label)"
    fi
  done
}

# --- そのほかのコマンド

# interp_cmd <dir> <名前> <引数>…: python・node などの引数 (-c・-e の中)・stdin・同じコマンドで書いた script の中の URL を
# 見る (呼び出し元の simple の in_text・in_known を使う)
interp_cmd() {
  local dir=$1 name=$2 x text=""
  shift 2
  for x in "$@"; do
    text+=${x}$'\n'
    [[ ${x} != -* ]] || continue
    read_written "${dir}" "${x}" && text+=${file_text}$'\n'
  done
  ((in_known)) && text+=${in_text}
  code_urls "${name}" "${text}"
}

# paste_cli <名前> <引数>…: ペースト共有のサービスか gist へ上げる専用のコマンド。--help・-h・--version (pastebinit は
# -v・-l も) は通す
paste_cli() {
  local name=$1 x info='|-h|--help|--version|'
  shift
  [[ ${name} == pastebinit ]] && info+='-v|-l|'
  for x in "$@"; do
    [[ ${info} == *"|${x}|"* ]] && return 0
  done
  add_found "${name} (ペースト共有のサービスか gist へ上げるコマンド)"
}

# echo_out <echo の引数>…: echo の出力を out_text に入れる (-e なら \n などを戻す)
echo_out() {
  local esc=0
  while [[ ${1-} =~ ^-[neE]+$ ]]; do
    [[ $1 == *e* ]] && esc=1
    shift
  done
  out_text="$*"$'\n'
  ((esc)) && printf -v out_text '%b' "${out_text}"
  out_known=1
}

# printf_out <printf の引数>…: printf の出力を out_text に入れる。幅の大きい書式 (%99999s・%*s) は打たずに、書式と引数を
# 並べたものにする (長い文字を作らない)
wide_re='%[^a-zA-Z%]*([0-9]{4,}|\*)'
printf_out() {
  local fmt
  [[ ${1-} == -- ]] && shift
  # -v <変数> は出力しない
  [[ ${1-} == -v ]] && return 0
  fmt=${1-}
  shift
  if [[ ${fmt} =~ ${wide_re} ]]; then
    printf -v out_text '%b\n%s' "${fmt}" "$*"
  else
    # shellcheck disable=SC2059 # コマンドの書式をそのまま使う
    printf -v out_text -- "${fmt}" "$@" 2>/dev/null || printf -v out_text '%b\n%s' "${fmt}" "$*"
  fi
  out_known=1
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

# rescan <dir> <段> <文字列>: bash -c などに文字列で渡したものを読み直す
rescan() {
  scan_command "$1" "$(($2 + 1))" "$3"
}

# simple <dir> <段> <P|-> <stdin> <stdout の書き先> <送り先> <語>…: 単純コマンドを 1 つ見る。cd なら next_dir に行き先を
# 入れ、出力 (パイプの先の stdin・> f の中身) が分かれば out_text・out_known に入れる
simple() {
  local dir=$1 depth=$2 pipe=$3 stdin=$4 outf=$5 net=$6 a name
  shift 6
  local -a w=("$@") assigns=() nets=() sub=()
  local in_text="" in_known=0 in_given=0 i guard=0
  case ${stdin} in
    H*)
      in_text=${stdin:1}
      in_known=1
      in_given=1
      ;;
    F*)
      in_given=1
      if read_written "${dir}" "${stdin:1}"; then
        in_text=${file_text}
        in_known=1
      fi
      ;;
    *)
      if [[ ${pipe} == P ]]; then
        in_given=1
        in_text=${last_out}
        in_known=${last_known}
      fi
      ;;
  esac

  # > /dev/tcp/<host>/<port> などへの書き込み (bash が開くソケット)
  if [[ -n ${net} ]]; then
    IFS=$'\034' read -r -a nets <<<"${net}"
    for a in "${nets[@]}"; do
      name=${a#/dev/*/}
      if classify_url "${name%%/*}" && [[ ${url_kind} == paste ]]; then
        add_found "${a} への書き込み → $(paste_label)"
      fi
    done
  fi

  # 頭の VAR=値 と予約語
  while ((${#w[@]} > 0)); do
    case ${w[0]} in
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
            -S | --split-string)
              rescan "${dir}" "${depth}" "${w[*]:1}"
              return 0
              ;;
            -u | --unset | -C | --chdir) w=("${w[@]:2}") ;;
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
      bash | sh | zsh | dash | ksh | mksh | fish)
        for ((i = 1; i < ${#w[@]}; i++)); do
          case ${w[i]} in
            -o | +o | -O | +O | --rcfile | --init-file) i=$((i + 1)) ;;
            -*)
              if [[ ${w[i]} =~ ^-[A-Za-z]*c[A-Za-z]*$ ]]; then
                rescan "${dir}" "${depth}" "${w[i + 1]-}"
                return 0
              fi
              ;;
            *)
              # script のファイル。同じコマンドで書いたものだけ読む
              read_written "${dir}" "${w[i]}" && rescan "${dir}" "${depth}" "${file_text}"
              return 0
              ;;
          esac
        done
        # -c も script のファイルも無い shell (bash <<EOF・bash -s・cat … | bash) は stdin を読む
        ((in_known)) && rescan "${dir}" "${depth}" "${in_text}"
        return 0
        ;;
      source | .)
        ((${#w[@]} > 1)) && read_written "${dir}" "${w[1]}" && rescan "${dir}" "${depth}" "${file_text}"
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
      ssh)
        # ssh [オプション] <host> <コマンド>…: host の後ろをコマンドとして読み直す
        for ((i = 1; i < ${#w[@]}; i++)); do
          case ${w[i]} in
            -[BbcDEeFIiJLlmOoPpQRSWw]) i=$((i + 1)) ;;
            -*) ;;
            *)
              ((i + 1 < ${#w[@]})) && rescan "${dir}" "${depth}" "${w[*]:i+1}"
              return 0
              ;;
          esac
        done
        return 0
        ;;
      find)
        # -exec・-execdir・-ok・-okdir の後ろから ; か + までを、1 つの単純コマンドとして見る
        for ((i = 1; i < ${#w[@]}; i++)); do
          case ${w[i]} in
            -exec | -execdir | -ok | -okdir)
              sub=()
              for ((i++; i < ${#w[@]}; i++)); do
                [[ ${w[i]} == ';' || ${w[i]} == + ]] && break
                sub+=("${w[i]}")
              done
              if ((${#sub[@]} > 0 && depth < 3)); then
                simple "${dir}" "$((depth + 1))" - "" "" "" "${sub[@]}"
              fi
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
      mise)
        # mise exec … -- <コマンド>
        if [[ ${w[1]-} == exec || ${w[1]-} == x ]]; then
          for ((i = 2; i < ${#w[@]}; i++)); do
            if [[ ${w[i]} == -- ]]; then
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

  name=${w[0]##*/}
  name=${name%.exe}
  case ${name} in
    gh | hub) gh_cmd "${name}" "${w[@]:1}" ;;
    glab) glab_cmd "${w[@]:1}" ;;
    git) git_cmd "${dir}" "${w[@]:1}" ;;
    curl) curl_cmd "${dir}" "${w[@]:1}" ;;
    wget | wget2) wget_cmd "${dir}" "${w[@]:1}" ;;
    http | https | xh | xhs) httpie_cmd "${dir}" "${name}" "${w[@]:1}" ;;
    nc | ncat | netcat | nc.openbsd | nc.traditional | socat | telnet) net_cmd "${dir}" "${name}" "${w[@]:1}" ;;
    python | python[23] | python[23].* | pypy | pypy[23] | node | nodejs | deno | bun | ruby | perl | php)
      interp_cmd "${dir}" "${name}" "${w[@]:1}"
      ;;
    cat)
      if ((${#w[@]} == 1)) || [[ ${w[1]} == - ]]; then
        out_text=${in_text}
        out_known=${in_known}
      elif read_written "${dir}" "${w[1]}"; then
        out_text=${file_text}
        out_known=1
      fi
      ;;
    echo) echo_out "${w[@]:1}" ;;
    printf) printf_out "${w[@]:1}" ;;
    tee)
      out_text=${in_text}
      out_known=${in_known}
      for a in "${w[@]:1}"; do
        [[ ${a} == -* ]] || remember_write "${dir}" "${a}" "${in_known}" "${in_text}"
      done
      ;;
    *)
      for a in "${paste_clis[@]}"; do
        if [[ ${name} == "${a}" ]]; then
          paste_cli "${name}" "${w[@]:1}"
          break
        fi
      done
      ;;
  esac
  [[ -z ${outf} ]] || remember_write "${dir}" "${outf}" "${out_known}" "${out_text}"
  return 0
}

# scan_command <dir> <段> <コマンドの文字列>: 単純コマンドを順に見る。cd は後ろの単純コマンドの dir に効かせる
scan_command() {
  local dir=$1 depth=$2
  local -a rec
  ((depth <= 3)) || return 0
  (($(byte_len "$3") <= lex_limit)) || return 0
  last_out=""
  last_known=0
  while IFS=$'\037' read -r -d $'\036' -a rec; do
    next_dir=""
    out_text=""
    out_known=0
    if ((${#rec[@]} > 4)) || [[ -n ${rec[3]-} ]]; then
      simple "${dir}" "${depth}" "${rec[0]}" "${rec[1]-}" "${rec[2]-}" "${rec[3]-}" "${rec[@]:4}"
    fi
    [[ -z ${next_dir} ]] || dir=${next_dir}
    last_out=${out_text}
    last_known=${out_known}
  done < <(split_commands "$3")
}

# --- 長いコマンド

# long_command <KB>: 読む長さを超えたコマンドは中を読まず、上げる形の文字があれば止める (grep が 1 行ずつ探す)。長い
# 本文を Write の tool でファイルに書くか、コマンドを分ければ、中を読んで確かめられる
long_command() {
  local hosts m nl=$'\n' push_re n=0
  local -a hits=() gopts=()
  long_kb=$1
  hosts=$(
    IFS='|'
    printf '%s' "${paste_hosts[*]//./\\.}"
  )
  mapfile -t hits < <(LC_ALL=C grep -Eo \
    -e "${url_re}" \
    -e '(^|[^[:alnum:]_.-])(gh|hub)(\.exe)?[[:space:]]+gist[[:space:]]+(create|new|edit|rename)' \
    -e '(^|[^[:alnum:]_.-])(gh|hub)(\.exe)?[[:space:]]+api[[:space:]][^;&|]*gists' \
    -e '(^|[^[:alnum:]_.-])glab(\.exe)?[[:space:]]+snippet[[:space:]]+(create|new)' \
    -e '(^|[^[:alnum:]_./-])(pastebinit|wgetpaste|fpaste|gist-paste|nopaste)([^[:alnum:]_.-]|$)' \
    -e "/dev/(tcp|udp)/([A-Za-z0-9-]+\\.)*(${hosts})" \
    -e "(^|[^[:alnum:]_.-])(nc|ncat|netcat|socat|telnet)[[:space:]][^;&|]*(${hosts})" \
    <<<"${cmd}")
  for m in "${hits[@]}"; do
    if [[ ${m} =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
      classify_url "${m}" || continue
    fi
    m=${m#[^[:alnum:]/]}
    m=${m%[^[:alnum:]]}
    add_found "コマンドの文字「${m}」"
    ((++n < 5)) || break
  done
  # git … push は、今の dir の push の先が gist なら止める (1 行の中だけで探す)
  push_re="(^|[^[:alnum:]_.-])git[[:space:]]+([^;&|${nl}]*[[:space:]])?push([[:space:]]|\$)"
  [[ ${cmd} =~ ${push_re} ]] && push_job "${cwd}"
  return 0
}

pick_awk
cmd_bytes=$(byte_len "${cmd}")
if ((cmd_bytes > lex_limit)); then
  long_command "$(((cmd_bytes + 1023) / 1024))"
else
  scan_command "${cwd}" 0 "${cmd}"
fi
((${#found[@]} == 0)) || emit
exit 0
