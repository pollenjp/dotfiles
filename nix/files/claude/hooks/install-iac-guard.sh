#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の hook。venv・project の外 (system・user の環境) へ入れる install と、terraform・tofu・terragrunt で実物
# (資源か state) を変える操作を、打つ前に止める。
#
# 設計は claude-skills の docs/superpowers/specs/2026-11-13-lang-prefs-pack-design.md (§3.5・§8 の 1 と 2)、dotfiles の分で
# 決めたこと (venv の印の決め方・止める操作を足したもの・通す口など) は dotfiles-private の
# docs/superpowers/plans/2026-11-13-lang-prefs-pack-dotfiles.md。
#
# install は CLAUDE.md の「同梱 script の依存ツール」の 4 つ (pip install・npm install -g・apt install・brew install) の意味、
# つまり venv や project の外へ入れることを止める。pip という命令の名前では止めない (pip と venv で組む repo の手順を
# 毎回止めないため)。IaC は「実環境への apply は merge の後に人が流す (Claude は検査か plan まで)」の線で、apply・destroy と
# 同じく資源か state を変える操作をまとめて止める。止めたら (permissionDecision の deny) 代わりの手を Claude に返す。
#
# ## 止めるもの (PreToolUse・matcher Bash)
#
#   pip・pip3・python -m pip・python3 -m pip の install (python3.12 などの版付きも)
#       sudo 付き・--user・--break-system-packages はいつも止める。それ以外は、下の venv の印が無ければ止める
#   uv pip install の --system・--break-system-packages 付き
#   npm install -g (npm i -g・--global・--location=global、npm -g install も)・pnpm add -g・yarn global add・bun add -g
#   apt install・apt-get install・brew install (sudo 付きも)
#   terraform・tofu の apply・destroy・import・taint・untaint・force-unlock・refresh、state rm・mv・push・replace-provider、
#       workspace delete、-migrate-state・-force-copy 付きの init
#   terragrunt の同じ操作 (run --all apply・run -- apply・stack run apply・run-all destroy のように別の語の後ろに来る形も)
#       と apply-all・destroy-all・backend bootstrap・delete・migrate
#   読む長さ (下の「読み方」) を超えたコマンド
#       中を読まずに、行の中に上の形 (venv のパスで呼ぶ pip などは除く) があれば止め、コマンドを短くするよう返す
#
# ## 止めないもの
#
#   - venv の印のある pip:
#       - パスで呼ぶ interpreter (<root>/bin/pip・<root>/bin/python -m pip) で、root に pyvenv.cfg がある・root の名前が venv を
#         含むか env の語 (env・.env・build-env など) か、root の親が envs (conda の env)・同じコマンドの前の方で作った venv
#         (python -m venv <dir>・virtualenv <dir>・uv venv [<dir>]) か、root に変数を含む (解けないので印とみなす)。
#         /usr/bin/pip・~/.local/bin/pip・mise の python の pip は印にならない
#       - 同じコマンドの前の方の activate (source・. の <root>/bin/activate、conda・mamba・micromamba activate <base 以外>)
#       - uv run・poetry run・pdm run・hatch run・pipenv run・rye run・conda run の後ろ
#       - hook の env の VIRTUAL_ENV (Claude Code を venv の中で起こした)
#     -t・--target (dir を指して入れる) と -h・--help も通す
#   - --system の無い uv pip install、npm install (-g なし)・pnpm add (-g なし)、pipx install・cargo install・uv tool install・
#     go install (止めるかをユーザーがまだ決めていない)
#   - IaC の読むだけの操作 (plan・validate・fmt・flag の無い init・output・show・state list・show・pull・graph・providers・
#     test (mock を使う repo の検査)・workspace select など) と -help
#   - 包み (make apply・mise run apply・repo の script の apply)。git apply・kubectl apply を誤って止めないよう拾わない
#   - コマンドに書いただけのもの (commit の message・echo・heredoc の本文・引用符の中)
#
# ## 通す口
#
# 単純コマンドの頭の PJP_ALLOW_INSTALL=1 (install)・PJP_ALLOW_IAC=1 (IaC)。env の引数でもよく、bash -c などの中にも効く。
# 片方を付けても、もう片方は通さない。使うのは、ユーザーがこの会話で明示したときだけ (止めたときに返す文にもそう書く)。
#
# ## IaC の guard を外す
#
# ~/.local/state/dotfiles/claude-iac-guard.json の enable が false なら、IaC を止めない (install は止める)。値は host の
# option dotfiles.claude.iacGuard.enable (既定 true) を home/modules/claude.nix が書く (cloud では
# scripts/claude-cloud/bootstrap-claude-cloud.sh の --no-iac-guard)。agent が sandbox で自分でプロジェクトを作って消す
# マシンのためのもの。ファイルが無い・読めない・壊れているときは止める (jq を使わずに読む)。
#
# ## 読み方
#
# コマンドの文字を awk で単純コマンドに分ける (xref-guard.sh の lexer をそのまま写した。直すときは両方を見る)。頭の
# VAR=値・包むコマンド (env・sudo・timeout・nohup・xargs・nix develop -c・mise exec -- など)・予約語は外し、bash -c・eval・
# su -c・nix-shell --run などに文字列で渡したもの、bash <<EOF の本文は読み直す (3 段まで。読み直す中へは通す口・venv の印・
# sudo を引き継ぐ)。cd は後ろの単純コマンドの dir に効かせる (pyvenv.cfg と venv のパスを引く dir)。script の中・関数・
# alias・変数に入れたコマンドは見えない。読むのは 64 KB (gawk・mawk の無いマシンでは 16 KB) まで (xref-guard.sh と同じ)。
#
# ## 黙る場面
#
#   - Bash 以外・止める形の語を含まないコマンド・jq が無い・入力が壊れている。tool の流れを止めないよう、何があっても
#     exit 0 で終える
#
# ## 登録
#
# scripts/bootstrap-claude-hook.sh が settings.json の hooks の PreToolUse に 1 件 (matcher Bash) 足す。

set -u -o pipefail

# 黙って抜ける場合も、先に stdin を読み切る (書き手の Claude Code を待たせない)
input=$(cat) || exit 0

# IaC の guard を外したマシンか (上の「IaC の guard を外す」)
iac_on=1
iac_state="${HOME}/.local/state/dotfiles/claude-iac-guard.json"
if [[ -r ${iac_state} ]]; then
  iac_json=$(<"${iac_state}") || iac_json=""
  if [[ ${iac_json} =~ \"enable\"[[:space:]]*:[[:space:]]*false ]]; then
    iac_on=0
  fi
fi

# 止める形の語を含むか (この hook は Bash のたびに走るので、まず文字で絞る)
has_words() {
  local k
  for k in install npm yarn bun; do
    [[ $1 == *"${k}"* ]] && return 0
  done
  if ((iac_on)); then
    for k in terraform tofu terragrunt; do
      [[ $1 == *"${k}"* ]] && return 0
    done
  fi
  return 1
}
has_words "${input}" || exit 0
command -v jq &>/dev/null || exit 0

# tool の名前・コマンド・cwd を 1 回の jq で取り出す (NUL で区切る)。無い・壊れている → 空文字
tool="" cmd="" cwd=""
{
  IFS= read -r -d '' tool
  IFS= read -r -d '' cmd
  IFS= read -r -d '' cwd
} < <(jq -j '[.tool_name, .tool_input.command, .cwd] | map((strings // "") + "\u0000") | add' <<<"${input}" 2>/dev/null)
[[ ${tool} == Bash ]] || exit 0
[[ -n ${cwd} && -d ${cwd} ]] || cwd=${PWD}
has_words "${cmd}" || exit 0

# コマンドの文字を単純コマンドに分ける awk (上の「読み方」)。
#
#   - '…'・"…"・$'…'・\ を外して語にする。${…}・$((…)) は語のまま
#   - ; & | 改行 ( ) で分ける。[[ … ]] の中の ( ) | < > は分けない
#   - リダイレクトの先は、< f を stdin の F、> f・>> f・>| f・&> f (stdout) を書き先にし、ほか (2> f・2>&1 の 1 など) は
#     捨てる。here-string は stdin の H にする。heredoc は
#     終わりの印までの本文を stdin の H にする
#   - 語の頭の # から行末まではコメント
# 本文は xref-guard.sh の lexer そのまま。代入だけ read -r -d '' から $(cat <<'AWK' …) に替えた (read は pipe の heredoc を
# 1 バイトずつ読み、bash 5.3 で 20 ms ほど遅い。この hook は install・IaC の語を含む Bash のたびに走る)
lexer=$(
  cat <<'AWK'
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
    printf "%s%s%s%s%s", cpipe[k], US, cstdin[k], US, coutf[k]
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
  if (nw > 0 || cur_stdin != "" || own_hd) {
    line = ""
    for (k = 1; k <= nw; k++) line = line (k > 1 ? US : "") words[k]
    ncmd++
    cwords[ncmd] = line
    cnw[ncmd] = nw
    cpipe[ncmd] = pipein ? "P" : "-"
    cstdin[ncmd] = cur_stdin
    coutf[ncmd] = cur_outf
    stored = 1
  }
  nw = 0
  skip = 0
  inbr = 0
  cur_stdin = ""
  cur_outf = ""
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
)

# lexer に使う awk と、読むコマンドの長さの上限 (xref-guard.sh と同じ)。gawk・mawk は長い文字列の substr が速いので先に
# 使う。ほかの awk (macOS の onetrue-awk) は長さの二乗で遅くなるので、上限を小さくする
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

# join_dir <今の dir> <cd の引数>: cd の行き先。分からない (cd -・$( )・変数) なら今の dir
join_dir() {
  local d
  d=$(expand_home "$2")
  case ${d} in
    '') printf '%s' "${HOME}" ;;
    - | *'$'* | *'`'* | *$'\002'*) printf '%s' "$1" ;;
    /*) printf '%s' "${d}" ;;
    *) printf '%s' "$1/${d}" ;;
  esac
}

# abs_path <dir> <path>: dir から見た path (/./ と // は詰め、末尾の / と /. は外す)
abs_path() {
  local p
  p=$(expand_home "$2")
  [[ ${p} == /* ]] || p="$1/${p}"
  while [[ ${p} == *'/./'* || ${p} == *'//'* ]]; do
    p=${p//\/.\//\/}
    p=${p//\/\//\/}
  done
  p=${p%/.}
  [[ ${p} == / ]] || p=${p%/}
  printf '%s' "${p}"
}

# --- 止めたもの

found_install=()
found_iac=()
hint_pip=0
hint_node=0
hint_os=0
long_kb=0

# add_install <止めたもの> <pip|node|os>: install の止めたものを 1 行足す (同じものは 1 回だけ)
add_install() {
  local f
  case $2 in
    pip) hint_pip=1 ;;
    node) hint_node=1 ;;
    os) hint_os=1 ;;
  esac
  for f in "${found_install[@]}"; do
    [[ ${f} == "$1" ]] && return 0
  done
  found_install+=("$1")
}

# add_iac <止めたもの>: IaC の止めたものを 1 行足す (同じものは 1 回だけ)
add_iac() {
  local f
  for f in "${found_iac[@]}"; do
    [[ ${f} == "$1" ]] && return 0
  done
  found_iac+=("$1")
}

# --- venv

# 同じコマンドの前の方で作った venv (python -m venv・virtualenv・uv venv) の絶対パス
declare -A venv_made=()
# 同じコマンドの前の方で activate したか (bash -c などの中へは引き継ぎ、中の activate は外へ出さない)
venv_active=0

# venv_new <dir> <venv|uv> <引数>…: 作る venv の dir を venv_made に控える (uv venv は省けば .venv)
venv_new() {
  local dir=$1 kind=$2 i x got=0
  shift 2
  local -a a=("$@")
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      -p | --python | --prompt | --index-url | --extra-index-url | --find-links | -f | --index | --default-index | --cache-dir | \
        --seeder | --activators | --creator | --app-data | --link-mode | --upgrade-deps) i=$((i + 1)) ;;
      -*) ;;
      *)
        venv_made[$(abs_path "${dir}" "${x}")]=1
        got=1
        ;;
    esac
  done
  if ((! got)) && [[ ${kind} == uv ]]; then
    venv_made[$(abs_path "${dir}" .venv)]=1
  fi
  return 0
}

# venv_mark <dir> <pip を呼ぶ語 (pip・.venv/bin/pip・python3 など)>: venv の中へ入れる印があるか (上の「止めないもの」)。
# 呼び出し元の simple の runner を使う
venv_mark() {
  local dir=$1 interp=$2 bindir root abs base parent
  ((venv_active || runner)) && return 0
  [[ -n ${VIRTUAL_ENV-} ]] && return 0
  [[ ${interp} == */* ]] || return 1
  [[ ${interp} != *'$'* ]] || return 0
  bindir=${interp%/*}
  case ${bindir##*/} in
    bin | Scripts) ;;
    *) return 1 ;;
  esac
  if [[ ${bindir} == */* ]]; then
    root=${bindir%/*}
  else
    root=.
  fi
  [[ -n ${root} ]] || root=/
  abs=$(abs_path "${dir}" "${root}")
  [[ -f ${abs}/pyvenv.cfg ]] && return 0
  [[ -n ${venv_made[${abs}]+x} ]] && return 0
  base=${abs##*/}
  base=${base,,}
  [[ ${base} == *venv* ]] && return 0
  [[ ${base} =~ (^|[._-])env([._0-9-]|$) ]] && return 0
  parent=${abs%/*}
  [[ ${parent##*/} == envs ]] && return 0
  return 1
}

# --- install

# pip_cmd <dir> <pip を呼ぶ語> <止めたものの名前の頭 (pip3・python3 -m pip など)> <pip の後ろの語>…: pip の install を見る
# (呼び出し元の simple の allow_install・sudo・runner を使う)
pip_cmd() {
  local dir=$1 interp=$2 label=$3 i x sub="" py_opt="" user=0 bsp=0 target=0
  shift 3
  local -a a=("$@")
  ((allow_install)) && return 0
  # subcommand の前の global のオプション (値を取るものは値も飛ばす)。--python は入れる先の interpreter
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      --python=*) py_opt=${x#*=} ;;
      --python)
        py_opt=${a[i + 1]-}
        i=$((i + 1))
        ;;
      --log | --proxy | --retries | --timeout | --exists-action | --trusted-host | --cert | --client-cert | --cache-dir | \
        --use-feature | --use-deprecated | --keyring-provider | --resume-retries) i=$((i + 1)) ;;
      -*) ;;
      *)
        sub=${x}
        break
        ;;
    esac
  done
  [[ ${sub} == install ]] || return 0
  for x in "${a[@]:i+1}"; do
    case ${x} in
      -h | --help) return 0 ;;
      --user) user=1 ;;
      --break-system-packages) bsp=1 ;;
      -t | --target | --target=*) target=1 ;;
    esac
  done
  if ((sudo)); then
    add_install "sudo 付きの ${label} install" pip
  elif ((user)); then
    add_install "${label} install --user" pip
  elif ((bsp)); then
    add_install "${label} install --break-system-packages" pip
  elif ((target)); then
    return 0
  elif ! venv_mark "${dir}" "${py_opt:-${interp}}"; then
    add_install "${label} install (venv の印が無い)" pip
  fi
  return 0
}

# python_cmd <dir> <python を呼ぶ語> <python の後ろの語>…: -m pip・-m venv を見る
python_cmd() {
  local dir=$1 interp=$2 i x mod
  shift 2
  local -a a=("$@")
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      -m?*)
        mod=${x#-m}
        i=$((i + 1))
        ;;
      -m)
        mod=${a[i + 1]-}
        i=$((i + 2))
        ;;
      -c) return 0 ;;
      -W | -X) i=$((i + 1)) ;;
      -*) continue ;;
      *) return 0 ;;
    esac
    case ${mod} in
      pip) pip_cmd "${dir}" "${interp}" "${interp} -m pip" "${a[@]:i}" ;;
      venv) venv_new "${dir}" venv "${a[@]:i}" ;;
    esac
    return 0
  done
  return 0
}

# uv_cmd <dir> <uv の後ろの語>…: uv pip install --system と uv venv を見る (uv run は simple が包みとして外す)
uv_cmd() {
  local dir=$1 i x
  shift
  local -a a=("$@")
  for ((i = 0; i < ${#a[@]}; i++)); do
    [[ ${a[i]} == -* ]] || break
  done
  case ${a[i]-} in
    pip)
      [[ ${a[i + 1]-} == install ]] || return 0
      ((allow_install)) && return 0
      for x in "${a[@]:i+2}"; do
        case ${x} in
          --system | --break-system-packages)
            add_install "uv pip install ${x}" pip
            return 0
            ;;
        esac
      done
      ;;
    venv) venv_new "${dir}" uv "${a[@]:i+1}" ;;
  esac
  return 0
}

# node_cmd <npm|pnpm|yarn|bun> <後ろの語>…: global に入れる install を見る
node_cmd() {
  local tool=$1 i x sub="" sub2="" global=0
  shift
  local -a a=("$@")
  ((allow_install)) && return 0
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      -g | --global | --global=true | --location=global) global=1 ;;
      --location)
        [[ ${a[i + 1]-} == global ]] && global=1
        i=$((i + 1))
        ;;
      -*) ;;
      *)
        if [[ -z ${sub} ]]; then
          sub=${x}
        elif [[ -z ${sub2} ]]; then
          sub2=${x}
        fi
        ;;
    esac
  done
  case ${tool}:${sub} in
    npm:install | npm:i | npm:add | npm:in | npm:ins | npm:inst | npm:insta | npm:instal | npm:isnt | npm:isnta | npm:isntal | \
      npm:isntall | pnpm:add | pnpm:install | pnpm:i | bun:add | bun:a | bun:install | bun:i)
      ((global)) && add_install "${tool} ${sub} -g" node
      ;;
    yarn:global)
      [[ ${sub2} == add ]] && add_install "yarn global add" node
      ;;
  esac
  return 0
}

# os_cmd <apt|apt-get|brew> <後ろの語>…: OS の package の install を見る
os_cmd() {
  local tool=$1 i x sub="" lead=""
  shift
  local -a a=("$@")
  ((allow_install)) && return 0
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      -o | -c | -t | --option | --config-file | --target-release) [[ ${tool} == brew ]] || i=$((i + 1)) ;;
      -*) ;;
      *)
        sub=${x}
        break
        ;;
    esac
  done
  ((sudo)) && lead="sudo "
  [[ ${sub} == install ]] && add_install "${lead}${tool} install" os
  return 0
}

# --- IaC

# tf_sub <terraform|tofu|terragrunt> <subcommand> <後ろの語>…: 実物を変える subcommand なら found_iac に足す
tf_sub() {
  local tool=$1 sub=$2 x s2=""
  shift 2
  for x in "$@"; do
    case ${x} in
      -help | -h | --help) return 0 ;;
    esac
  done
  case ${sub} in
    apply | destroy | import | taint | untaint | force-unlock | refresh) add_iac "${tool} ${sub}" ;;
    state | workspace)
      for x in "$@"; do
        if [[ ${x} != -* ]]; then
          s2=${x}
          break
        fi
      done
      case ${sub}:${s2} in
        state:rm | state:mv | state:push | state:replace-provider | workspace:delete) add_iac "${tool} ${sub} ${s2}" ;;
      esac
      ;;
    init)
      for x in "$@"; do
        case ${x} in
          -migrate-state | --migrate-state | -migrate-state=true | -force-copy | --force-copy | -force-copy=true)
            add_iac "${tool} init ${x%%=*}"
            return 0
            ;;
        esac
      done
      ;;
  esac
  return 0
}

# tf_cmd <terraform|tofu> <後ろの語>…: 最初の flag でない語を subcommand とみなす (global の flag は -chdir=… の形)
tf_cmd() {
  local tool=$1 i x
  shift
  local -a a=("$@")
  ((iac_on && ! allow_iac)) || return 0
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      -help | -h | --help | -version | -v | --version) return 0 ;;
      -*) ;;
      *)
        tf_sub "${tool}" "${x}" "${a[@]:i+1}"
        return 0
        ;;
    esac
  done
  return 0
}

# tg_cmd <terragrunt の後ろの語>…: 語を順に見て、flag・知らない語 (flag の値など)・run・run-all・stack・exec は飛ばし、
# 最初に当たった terraform の subcommand か terragrunt の操作で決める
tg_cmd() {
  local i x next=""
  local -a a=("$@")
  ((iac_on && ! allow_iac)) || return 0
  for ((i = 0; i < ${#a[@]}; i++)); do
    x=${a[i]}
    case ${x} in
      -help | -h | --help | -version | --version) return 0 ;;
      -* | run | run-all | stack | exec) ;;
      apply-all | destroy-all)
        add_iac "terragrunt ${x}"
        return 0
        ;;
      backend)
        for ((i++; i < ${#a[@]}; i++)); do
          if [[ ${a[i]} != -* ]]; then
            next=${a[i]}
            break
          fi
        done
        case ${next} in
          bootstrap | delete | migrate) add_iac "terragrunt backend ${next}" ;;
        esac
        return 0
        ;;
      apply | destroy | import | taint | untaint | force-unlock | refresh | state | workspace | init | plan | validate | output | \
        show | fmt | graph | providers | test | console | get | version | login | logout | metadata | modules | query | render | \
        hcl | find | list | info | catalog | scaffold | dag)
        tf_sub terragrunt "${x}" "${a[@]:i+1}"
        return 0
        ;;
    esac
  done
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

# rescan <dir> <段> <文字列>: bash -c などに文字列で渡したものを読み直す。通す口・venv の印・sudo は中にも効かせ、中の
# activate は外へ出さない (呼び出し元の simple の allow_install・allow_iac・runner・sudo)
inh_allow_install=0
inh_allow_iac=0
inh_runner=0
inh_sudo=0
rescan() {
  local s_install=${inh_allow_install} s_iac=${inh_allow_iac} s_runner=${inh_runner} s_sudo=${inh_sudo} s_venv=${venv_active}
  inh_allow_install=${allow_install}
  inh_allow_iac=${allow_iac}
  inh_runner=${runner}
  inh_sudo=${sudo}
  scan_command "$1" "$(($2 + 1))" "$3"
  inh_allow_install=${s_install}
  inh_allow_iac=${s_iac}
  inh_runner=${s_runner}
  inh_sudo=${s_sudo}
  venv_active=${s_venv}
}

# simple <dir> <段> <stdin> <語>…: 単純コマンドを 1 つ見る。cd なら next_dir に行き先を入れる
simple() {
  local dir=$1 depth=$2 stdin=$3 i guard=0 name
  shift 3
  local -a w=("$@")
  local allow_install=${inh_allow_install} allow_iac=${inh_allow_iac} runner=${inh_runner} sudo=${inh_sudo}

  # 頭の VAR=値 と予約語
  while ((${#w[@]} > 0)); do
    case ${w[0]} in
      PJP_ALLOW_INSTALL=*) [[ ${w[0]#*=} == 1 ]] && allow_install=1 ;;
      PJP_ALLOW_IAC=*) [[ ${w[0]#*=} == 1 ]] && allow_iac=1 ;;
      '!' | '{' | '}' | if | then | else | elif | do | while | until) ;;
      for | case | select | function | 'fi' | 'done' | 'esac' | '[[' | '[') return 0 ;;
      *=*) [[ ${w[0]%%=*} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || break ;;
      *) break ;;
    esac
    w=("${w[@]:1}")
  done

  # 包むコマンドを外す。中に文字列で渡すものは読み直す
  while ((${#w[@]} > 0 && guard++ < 16)); do
    case ${w[0]##*/} in
      cd | pushd)
        next_dir=$(join_dir "${dir}" "${w[${#w[@]} - 1]}")
        ((${#w[@]} > 1)) || next_dir=${HOME}
        return 0
        ;;
      source | .)
        case ${w[1]-} in
          */bin/activate* | bin/activate*) venv_active=1 ;;
        esac
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
            PJP_ALLOW_INSTALL=1)
              allow_install=1
              w=("${w[@]:1}")
              ;;
            PJP_ALLOW_IAC=1)
              allow_iac=1
              w=("${w[@]:1}")
              ;;
            -* | *=*) w=("${w[@]:1}") ;;
            *) break ;;
          esac
        done
        ;;
      sudo | doas)
        sudo=1
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
            *) return 0 ;;
          esac
        done
        # -c も script のファイルも無い shell (bash <<EOF・bash -s) は heredoc の本文を読む
        [[ ${stdin} == H* ]] && rescan "${dir}" "${depth}" "${stdin:1}"
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
      uv)
        # uv run … <コマンド>: 後ろは uv が用意する venv の中
        [[ ${w[1]-} == run ]] || break
        runner=1
        w=("${w[@]:2}")
        skip_opts '--with|-w|--with-editable|--with-requirements|--python|-p|--project|--directory|--package|--extra|--group|--only-group|--no-group|--env-file|--index|--default-index|--index-url|-i|--extra-index-url|--find-links|-f|--config-file|--cache-dir|--color'
        ;;
      poetry | pdm | hatch | pipenv | rye)
        [[ ${w[1]-} == run ]] || break
        runner=1
        w=("${w[@]:2}")
        skip_opts ''
        ;;
      conda | mamba | micromamba)
        case ${w[1]-} in
          run)
            runner=1
            w=("${w[@]:2}")
            skip_opts '-n|--name|-p|--prefix|--cwd'
            ;;
          activate)
            for ((i = 2; i < ${#w[@]}; i++)); do
              if [[ ${w[i]} != -* ]]; then
                [[ ${w[i]} == base ]] || venv_active=1
                break
              fi
            done
            return 0
            ;;
          *) break ;;
        esac
        ;;
      *) break ;;
    esac
  done
  ((${#w[@]} > 0)) || return 0

  name=${w[0]##*/}
  case ${name} in
    pip | pip[0-9] | pip[0-9].*) pip_cmd "${dir}" "${w[0]}" "${w[0]}" "${w[@]:1}" ;;
    python | python[0-9] | python[0-9].*) python_cmd "${dir}" "${w[0]}" "${w[@]:1}" ;;
    virtualenv) venv_new "${dir}" venv "${w[@]:1}" ;;
    uv) uv_cmd "${dir}" "${w[@]:1}" ;;
    npm | pnpm | yarn | bun) node_cmd "${name}" "${w[@]:1}" ;;
    apt | apt-get | brew) os_cmd "${name}" "${w[@]:1}" ;;
    terraform | tofu) tf_cmd "${name}" "${w[@]:1}" ;;
    terragrunt) tg_cmd "${w[@]:1}" ;;
  esac
  return 0
}

# scan_command <dir> <段> <コマンドの文字列>: 単純コマンドを順に見る。cd は後ろの単純コマンドの dir に効かせる
scan_command() {
  local dir=$1 depth=$2
  local -a rec
  ((depth <= 3)) || return 0
  pick_awk
  (($(byte_len "$3") <= lex_limit)) || return 0
  while IFS=$'\037' read -r -d $'\036' -a rec; do
    next_dir=""
    if ((${#rec[@]} > 3)); then
      simple "${dir}" "${depth}" "${rec[1]}" "${rec[@]:3}"
    fi
    [[ -z ${next_dir} ]] || dir=${next_dir}
  done < <(split_commands "$3")
}

# --- 長いコマンド

# long_command <KB>: 読む長さを超えたコマンドは中を読まず、行を ; & | ( ) で分けた頭に止める形があれば止める (venv の印は
# 見ない。パスで呼ぶ pip は頭の形に当たらない)。ファイルの中身を Write の tool で書けば、コマンドが短くなり中を読める
long_command() {
  local line seg rest allow_i allow_a
  local tf='(terraform|tofu|terragrunt)[[:space:]]'
  long_kb=$1
  while IFS= read -r line; do
    line=${line//&&/;}
    line=${line//||/;}
    line=${line//[|&()]/;}
    while [[ -n ${line} ]]; do
      seg=${line%%;*}
      if [[ ${line} == *';'* ]]; then
        line=${line#*;}
      else
        line=""
      fi
      allow_i=0
      allow_a=0
      [[ ${seg} == *PJP_ALLOW_INSTALL=1* ]] && allow_i=1
      [[ ${seg} == *PJP_ALLOW_IAC=1* ]] && allow_a=1
      # 頭の空白・代入・包むコマンドを外す
      rest=${seg}
      while :; do
        rest=${rest#"${rest%%[![:space:]]*}"}
        if [[ ${rest} =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; then
          rest=${BASH_REMATCH[1]}
        elif [[ ${rest} =~ ^(sudo|env|time|nohup|exec|command|nice)[[:space:]]+(.*)$ ]]; then
          rest=${BASH_REMATCH[2]}
        elif [[ ${rest} =~ ^timeout[[:space:]]+[^[:space:]]+[[:space:]]+(.*)$ ]]; then
          rest=${BASH_REMATCH[1]}
        else
          break
        fi
      done
      rest+=" "
      if ((! allow_i)); then
        if [[ ${rest} =~ ^(pip[0-9.]*|python[0-9.]*[[:space:]]+-m[[:space:]]+pip)[[:space:]]+install[[:space:]] ]] \
          && [[ ${rest} != *' --target'* && ${rest} != *' -t '* ]]; then
          add_install "pip install (長いコマンドの中)" pip
        elif [[ ${rest} =~ ^uv[[:space:]]+pip[[:space:]]+install[[:space:]].*--(system|break-system-packages)[[:space:]] ]]; then
          add_install "uv pip install --${BASH_REMATCH[1]} (長いコマンドの中)" pip
        elif [[ ${rest} =~ ^(npm|pnpm|bun)[[:space:]].*[[:space:]](-g|--global)[[:space:]] ]]; then
          add_install "${BASH_REMATCH[1]} の -g (長いコマンドの中)" node
        elif [[ ${rest} =~ ^yarn[[:space:]]+global[[:space:]]+add[[:space:]] ]]; then
          add_install "yarn global add (長いコマンドの中)" node
        elif [[ ${rest} =~ ^(apt|apt-get)[[:space:]]+([^[:space:]]+[[:space:]]+)*install[[:space:]] ]]; then
          add_install "${BASH_REMATCH[1]} install (長いコマンドの中)" os
        elif [[ ${rest} =~ ^brew[[:space:]]+install[[:space:]] ]]; then
          add_install "brew install (長いコマンドの中)" os
        fi
      fi
      if ((iac_on && ! allow_a)) && [[ ${rest} =~ ^${tf} && ${rest} != *' -help '* ]]; then
        if [[ ${rest} =~ [[:space:]](apply|destroy|import|taint|untaint|force-unlock|refresh|apply-all|destroy-all)[[:space:]] ]] \
          || [[ ${rest} =~ [[:space:]]state[[:space:]]+(rm|mv|push|replace-provider)[[:space:]] ]] \
          || [[ ${rest} =~ [[:space:]]workspace[[:space:]]+delete[[:space:]] ]] \
          || [[ ${rest} =~ [[:space:]]backend[[:space:]]+(bootstrap|delete|migrate)[[:space:]] ]] \
          || [[ ${rest} =~ [[:space:]]-{1,2}(migrate-state|force-copy)[[:space:]=] ]]; then
          add_iac "${rest%% *} の実物を変える操作 (長いコマンドの中)"
        fi
      fi
    done
  done <<<"${cmd}"
}

# --- 止める

emit() {
  local msg f
  if ((long_kb)); then
    msg="[install-iac-guard] コマンドが長すぎて (${long_kb} KB。中を読むのは $((lex_limit / 1024)) KB まで) 中を読めず、"
    msg+="行の頭に次の形があるので止めた:"
  else
    msg="[install-iac-guard] 打つ前に止めた:"
  fi
  for f in "${found_install[@]}" "${found_iac[@]}"; do
    msg+=$'\n'"- ${f}"
  done
  if ((${#found_install[@]} > 0)); then
    msg+=$'\n\n'"install は venv・project の外 (system・user の環境) へ入れるので止めた (CLAUDE.md の「同梱 script の依存ツール」)。"
    if ((hint_pip)); then
      msg+=$'\n'"- Python は venv の中で入れる: uv の project なら uv add <pkg>。repo の手順が pip なら uv venv か python3 -m venv .venv の"
      msg+="後に .venv/bin/pip install … (uv pip install …・uv run pip install …・source .venv/bin/activate の後の pip install … も通す)"
    fi
    if ((hint_node)); then
      msg+=$'\n'"- Node の道具は project に入れる (pnpm add -D <pkg>) か、pnpm dlx・npx で一度だけ流す"
    fi
    if ((hint_os)); then
      msg+=$'\n'"- OS の package (apt・brew) は入れない"
    fi
    msg+=$'\n'"- system に要る道具は、nix flake の devShell → mise → (その 2 つが無理なわけを述べ、確認を取ってから) system の順で用意する"
    msg+=$'\n'"- ユーザーがこの会話で system・user の環境へ入れると明示したときだけ、コマンドの頭に PJP_ALLOW_INSTALL=1 を付けて打ち直す"
    msg+="(自分の判断では付けない)"
  fi
  if ((${#found_iac[@]} > 0)); then
    msg+=$'\n\n'"IaC の操作は実物 (資源か state) を変えるので止めた。実環境への apply は、merge の後に人が流す (Claude は検査か plan まで)。"
    msg+=$'\n'"- plan・validate・test で確かめ、流すコマンドと plan の要点をユーザーに伝える"
    msg+=$'\n'"- ユーザーがこの会話で流すと明示したときだけ、コマンドの頭に PJP_ALLOW_IAC=1 を付けて打ち直す (自分の判断では付けない)"
    msg+=$'\n'"- agent が自分で apply してよい sandbox のマシンなら、host の option dotfiles.claude.iacGuard.enable = false で外せる"
    msg+=" (外すかはユーザーが決める)"
  fi
  if ((long_kb)); then
    msg+=$'\n\n'"ファイルの中身は Write の tool で書いてコマンドを短くすれば、中を読んで確かめる。"
  fi
  jq -cn --arg r "${msg}" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' || true
}

pick_awk
cmd_bytes=$(byte_len "${cmd}")
if ((cmd_bytes > lex_limit)); then
  long_command "$(((cmd_bytes + 1023) / 1024))"
else
  scan_command "${cwd}" 0 "${cmd}"
fi
((${#found_install[@]} + ${#found_iac[@]} == 0)) || emit
exit 0
