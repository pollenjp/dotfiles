#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の hook。Bash で SSH agent (1Password) を使うコマンドを打つ前に知らせ、断られたら打ち直さずに
# 選択肢の問いを出させる (ADR 029)。
#
# herdr の中の SSH_AUTH_SOCK は手元の PC から SSH の接続で転送された agent を指し (ADR 025)、1Password の承認の
# 画面は手元の PC に出るが、どの pane のどの Claude が頼んだかは出ない。ユーザーは出どころの分からない依頼を
# 断るので、打つ前に「どこから・何を・承認の画面はどの接続の端末に出るか」を知らせる。判断は script がするので
# token を使わない (Claude に文を足すのは、断られたときだけ)。
#
# ## 打つ前 (PreToolUse・matcher Bash)
#
# コマンドの文字を単純コマンドに分け (split_commands)、次に当たれば、会話の画面に 1 行出す (systemMessage。
# Claude には渡らない)。コマンドは止めない (permissionDecision は出さない)。
#
#   ssh の接続   ssh・scp・sftp・ssh-copy-id・sshfs・mosh・autossh (ssh の -G・-V・-O・-Q は繋がないので外す)・
#                rsync の <host>:<path>・nixos-rebuild の --target-host / --build-host・nix-copy-closure・
#                nix の ssh:// / ssh-ng://・git の clone / fetch / pull / push / ls-remote で相手の URL が ssh
#   署名         git の commit など (commit・merge・rebase・cherry-pick・revert・am・pull・commit-tree) と tag と
#                push --signed で、署名するとき・ssh-keygen -Y sign・ssh-add -T
#   設定の一覧   中で ssh を打つ道具 (infra-v2 の nix run .#vm など)。host option
#                dotfiles.claude.sshAgentNotice.extraCommands の項目で、home-manager が
#                ~/.local/state/dotfiles/claude-ssh-agent-notice.json に置く。項目は語を空白で区切った glob で、
#                1 語目を頭の語に、残りを引数の中に順に当てる
#
# git が署名するかは、hook の中で git に実効の設定を聞いて決める。dotfiles は Claude の会話にだけ
# commit.gpgsign=false を env で入れているので (claude.nix の gitConfigBase)、素の git commit は当たらない。hook の
# env は Claude の会話と同じなので、会話の Bash と同じ答えになる。コマンドの git -c と -C も渡す。
#
# 読み方: 引用符と \ を外して語にし、heredoc の本文とコメントは捨てる (commit のメッセージや heredoc の本文に ssh と
# 書いても当たらない)。$( )・` `・<( ) の中は別の単純コマンドとして見る。頭の VAR=値・包むコマンド (env・sudo・
# timeout・xargs・nix develop -c など)・予約語は外し、bash -c・eval・nix-shell --run などに文字列で渡したものは
# 読み直す (3 段まで)。cd と git -C は、その後ろの git を見る場所に効かせる。script の中・関数・alias・変数に
# 入れたコマンドは見えない (断られたら、失敗のあとの指示で受ける)。読むのは 64 KB (gawk・mawk の無いマシンでは
# 16 KB) までで、それより長いコマンドは読まずに抜ける (macOS の awk は長いコマンドで十数秒かかる)。
#
# herdr の pane (HERDR_ENV=1) では、herdr の通知 (--sound request) でも知らせる。body は「どこから」(workspace の
# 名前・pane の ID・agent の名前)・コマンドの頭・承認の画面の接続の 3 行。同じ pane からは 600 秒に 1 回まで
# (commit のたびに鳴らさない。印は ${XDG_STATE_HOME:-~/.local/state}/pjp-ssh-agent-notice/ の時刻で、出せた通知
# だけを数える)。会話の画面の 1 行は毎回出す。herdr は 2 秒で切って呼び (timeout の無いマシンでは裏で流して見張る)、
# 落ちた・返事をしないときは、その回の残りと続く 60 秒は呼ばない (印は同じ dir の herdr-down)。
#
# 承認の画面の接続 (conn_desc) は、SSH_AUTH_SOCK (コマンドの頭の SSH_AUTH_SOCK= が勝つ。~ と $HOME は置き換える) の
# symlink の先を見る。sshd が転送した agent (s.*.sshd.*) なら、pjp-agent-link の記録 (~/.local/state/pjp-agent-link/
# conn/) の時刻と PJP_SSH_CLIENT の値 (無ければファイルの時刻) と、同じ dir のより新しい接続を出す。socket かどうかは
# 見ず、ファイルがあるかで見る (sshd は接続を閉じると socket を消す)。空なら、WSL では Windows の 1Password が出すと
# 言い (WSL の ssh は Windows の ssh.exe へのラッパーで、要求元は「Windows Terminal」としか出ない)、ほかでは分から
# ないと言う (ssh の設定の IdentityAgent で agent を使うことがある)。
#
# ## 断られたあと (PostToolUse・PostToolUseFailure・matcher Bash)
#
# 0 以外で終わった Bash には PostToolUse が来ず、PostToolUseFailure が来る (入力の error に出力が入る。Claude Code
# 2.1.306 で確かめた)。出力に次の文言があれば、Claude に指示を足し (additionalContext)、会話の画面に 1 行と、herdr の
# 通知 (理由ごとの title。間引かない) を出す。文言は偽の agent と使い捨ての sshd で ssh・scp・git から集めた。
#
#   断られた       agent refused operation (ssh の sign_and_send_pubkey: … と、git の署名の Couldn't sign message …)
#   通信が切れた   communication with agent failed (同じ形)
#   届かない       git の署名の Couldn't get agent socket・Couldn't load public key …/.git_signing_key_tmp…、
#                  鍵の認証の失敗 (Permission denied (publickey)) で agent の口があってその先が無いとき
#
# OpenSSH は自分のエラー行を \r\n で終え、Claude Code は tool の出力の \r を残すので、\r を外してから見る (git は
# ssh-keygen の出力の \r を ? に変えて出す。見本の行の終わりの ? はこれ)。どちらも行の終わりが文言のときだけ当てる
# (ssh・git の行は文言で終わり、diff・コード・文書の行はそうでない)。成功した Bash (2>&1 | tail で終了コードが
# 隠れたもの) は、行の頭も ssh・git の出す形 (sign_and_send_pubkey: など) に固定する。成功した grep・cat の結果に
# 出た文言で当てないため。
#
# 指示は「同じコマンドを打ち直さない。何を (コマンドの頭) とどこから (workspace・pane・agent) を書いてから、
# ① 直し方 (推奨) ② 飛ばして進める ③ 止める の問いを出す」。① は、断られたら「1Password を開いて承認する」、通信が
# 切れた・届かないなら agent の口の種類ごと (転送された接続なら「このマシンへ接続し直す」、手元の口なら「1Password を
# 起動してロックを解除する」、WSL で空なら Windows の 1Password、空なら SSH_AUTH_SOCK を設定する)。herdr の指揮役の
# 子は AskUserQuestion を使わず、問いを書いてターンを終える (workspace の名前が 🌱 で始まれば言い切る)。subagent の
# 中 (入力に agent_id がある) では問いを出させず、報告に書いて終えさせる。
#
# ## 黙る場面
#
#   - Bash 以外の tool・一覧に当たらないコマンド。コマンドの文字に ssh・scp・sftp・mosh・rsync・nixos-rebuild・
#     nix-copy-closure・git と、設定の一覧の項目の 1 語目のどれも無ければ、読まずに抜ける (この hook は Bash の
#     たびに走る)
#   - 断りの無い出力。口が生きている・空のときの鍵の認証の失敗 (鍵が相手に無いだけ・agent を使っていない)
#   - 想定外の入力・jq が無いとき。tool の流れを止めないよう、何があっても exit 0 で終える
#
# ## 登録
#
# scripts/bootstrap-claude-hook.sh が settings.json の hooks の PreToolUse・PostToolUse・PostToolUseFailure に
# 1 件ずつ (matcher Bash) 足す。

set -u -o pipefail

# 黙って抜ける場合も、先に stdin を読み切る (書き手の Claude Code を待たせない)
input=$(cat) || exit 0

command -v jq &>/dev/null || exit 0

# 入力の 1 項目を取り出す。無い・壊れている → 空文字
field() {
  jq -r "$1 // empty" <<<"${input}" 2>/dev/null || true
}

[[ $(field '.tool_name') == Bash ]] || exit 0

event=$(field '.hook_event_name')
cmd=$(field '.tool_input.command')
cwd=$(field '.cwd')
[[ -n ${cwd} && -d ${cwd} ]] || cwd=${PWD}
extra_cmds=()

# コマンドの文字を単純コマンドに分ける awk。1 行に 1 つ、語を US (\037) で区切って出す (語の中の改行・タブは空白)。
#
#   - '…'・"…"・$'…'・\ を外して語にする。${…}・$((…)) は語のまま
#   - ; & | 改行 ( ) で分ける。[[ … ]] の中の ( ) | < > は分けない
#   - $( )・` `・<( )・>( ) の中は別の単純コマンドとして出し、外の語は「$(…)」に置き換えて続ける。"…" の中の
#     $( )・` ` は、外を読み終えてから読む (閉じ括弧は引用符を見ずに数える)
#   - リダイレクトの先 (> f・2>&1 の 1 など) と here-string の語は捨てる。heredoc は終わりの印までの本文を捨てる
#   - 語の頭の # から行末まではコメント
read -r -d '' lexer <<'AWK' || true
BEGIN { US = "\037" }
{ src = (NR == 1) ? $0 : src "\n" $0 }
END {
  lex(src)
  flush_cmd()
  # "…" の中の $( )・` ` は、外を読み終えてから別のコマンドとして読む (読む間に増えた分も)
  for (qi = 1; qi <= nq; qi++) {
    depth = 0
    nh = 0
    lex(queue[qi])
    flush_cmd()
  }
}

# "…" の中の $( ) か ` ` を後で読む列に足し、語には印を置く。閉じる位置 (s の中の添字) を返す
function defer(s, i, n, kind,   j, q, e) {
  if (kind == "bt") {
    for (j = i + 1; j <= n; j++) {
      e = substr(s, j, 1)
      if (e == "\\") { j++; continue }
      if (e == "`") break
    }
    queue[++nq] = substr(s, i + 1, j - i - 1)
    word = word "`…`"
    return j
  }
  q = 0
  for (j = i + 1; j <= n; j++) {
    e = substr(s, j, 1)
    if (e == "(") q++
    else if (e == ")") { q--; if (q == 0) break }
  }
  queue[++nq] = substr(s, i + 2, j - i - 2)
  word = word "$(…)"
  return j
}

function add_char(ch) { word = word ch; inword = 1 }

function flush_word() {
  if (inword) {
    if (skip) {
      skip = 0
    } else {
      if (word == "[[") inbr = 1
      if (word == "]]") inbr = 0
      gsub(/[\n\t]/, " ", word)
      words[++nw] = word
    }
  }
  word = ""
  inword = 0
}

function flush_cmd(   k, line) {
  flush_word()
  if (nw > 0) {
    line = words[1]
    for (k = 2; k <= nw; k++) line = line US words[k]
    print line
  }
  nw = 0
  skip = 0
  inbr = 0
}

# $( )・` `・<( ) の中に入る。外の語を退避し、中を別の単純コマンドとして読む
function push(kind,   k) {
  depth++
  stype[depth] = kind
  sn[depth] = nw
  for (k = 1; k <= nw; k++) sw[depth, k] = words[k]
  sword[depth] = word
  sinbr[depth] = inbr
  inbr = 0
  nw = 0
  word = ""
  inword = 0
  skip = 0
}

function pop(   k, mark) {
  flush_cmd()
  mark = (stype[depth] == "proc") ? "<(…)" : (stype[depth] == "bt") ? "`…`" : "$(…)"
  nw = sn[depth]
  for (k = 1; k <= nw; k++) words[k] = sw[depth, k]
  word = sword[depth] mark
  inword = 1
  inbr = sinbr[depth]
  depth--
}

# heredoc の本文を飛ばした先 (終わりの印の行の次) を返す。<<- でなければ印の行を 1 回の index で探す (1 行ずつ
# substr で切り出すと、長い heredoc で二乗になる)
function heredoc_end(s, pos, n, delim, strip,   k, rest, eol, line) {
  if (!strip) {
    k = index("\n" substr(s, pos) "\n", "\n" delim "\n")
    return (k > 0) ? pos + k + length(delim) : n + 1
  }
  while (pos <= n) {
    rest = substr(s, pos)
    eol = index(rest, "\n")
    if (eol > 0) { line = substr(rest, 1, eol - 1); pos += eol } else { line = rest; pos = n + 1 }
    sub(/^\t+/, "", line)
    if (line == delim) break
  }
  return pos
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
        if (d == "$" && substr(s, i + 1, 1) == "(" && substr(s, i + 2, 1) != "(") { i = defer(s, i, n, "sub"); continue }
        if (d == "`") { i = defer(s, i, n, "bt"); continue }
        word = word d
      }
      continue
    }
    if (c == "$") {
      c2 = substr(s, i + 1, 1)
      if (c2 == "'") {
        inword = 1
        for (i += 2; i <= n; i++) {
          d = substr(s, i, 1)
          if (d == "\\") { word = word substr(s, i + 1, 1); i++; continue }
          if (d == "'") break
          word = word d
        }
        continue
      }
      if (c2 == "(" && substr(s, i + 2, 1) != "(") { push("sub"); i++; continue }
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
    if (c == "`") {
      if (depth > 0 && stype[depth] == "bt") pop(); else push("bt")
      continue
    }
    if (c == "(") { flush_cmd(); push("paren"); continue }
    if (c == ")") {
      if (depth > 0 && stype[depth] != "paren" && stype[depth] != "bt") pop()
      else { flush_cmd(); if (depth > 0 && stype[depth] == "paren") depth-- }
      continue
    }
    if (c == ";" || c == "|") { flush_cmd(); continue }
    if (c == "&") {
      if (substr(s, i + 1, 1) == ">") {
        flush_word()
        i++
        if (substr(s, i + 1, 1) == ">") i++
        skip = 1
      } else {
        flush_cmd()
      }
      continue
    }
    if (c == "<" || c == ">") {
      # 2> の 2 は fd なので語にしない
      if (inword && word ~ /^[0-9]+$/) { word = ""; inword = 0 } else flush_word()
      c2 = substr(s, i + 1, 1)
      if (c2 == "(") { push("proc"); i++; continue }
      if (c == "<" && c2 == "<") {
        if (substr(s, i + 2, 1) == "<") { i += 2; skip = 1; continue }
        # heredoc: 終わりの印を覚え、次の改行の後ろで本文を捨てる
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
        continue
      }
      while (substr(s, i + 1, 1) ~ /[>&|]/) i++
      skip = 1
      continue
    }
    if (c == "\n") {
      flush_cmd()
      if (nh > 0) {
        pos = i + 1
        for (k = 1; k <= nh; k++) pos = heredoc_end(s, pos, n, hd[k], hs[k])
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

# lexer に使う awk と、読むコマンドの長さの上限。gawk・mawk は長い文字列の substr が速いので先に使う。ほかの awk
# (macOS の onetrue-awk) は 1 文字ずつ読むと長さの二乗で遅くなる (80 KB で十数秒) ので、上限を小さくする。上限を
# 超えるコマンドは読まない (この hook は Bash のたびに走るので、待たせない方を採る。断られれば後で受ける)
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

# match_command <dir> <段> <コマンドの文字列>
#   単純コマンドを順に見て、最初に当たったもので hit_kind (種類)・hit_head (包むコマンドを外した語)・
#   hit_sock (頭の SSH_AUTH_SOCK= の値) を埋めて 0 を返す。当たらなければ 1。cd は後ろの単純コマンドの dir に効かせる
match_command() {
  local dir=$1 depth=$2 line
  local -a w
  ((depth <= 3)) || return 1
  pick_awk
  ((${#3} <= lex_limit)) || return 1
  while IFS= read -r line; do
    IFS=$'\037' read -r -a w <<<"${line}"
    ((${#w[@]} > 0)) || continue
    next_dir=""
    if match_simple "${dir}" "${depth}" "${w[@]}"; then
      return 0
    fi
    [[ -z ${next_dir} ]] || dir=${next_dir}
  done < <(split_commands "$3")
  return 1
}

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

# rematch <dir> <段> <sock> <文字列>: 文字列を読み直す (bash -c など)。当たって sock が無ければ外の sock を使う
rematch() {
  match_command "$1" "$(($2 + 1))" "$4" || return 1
  [[ -n ${hit_sock} ]] || hit_sock=$3
  return 0
}

# match_simple <dir> <段> <語>…: 単純コマンドを 1 つ見る (match_command の説明)
match_simple() {
  local dir=$1 depth=$2
  shift 2
  local -a w=("$@")
  local sock="" base kind="" a i guard=0

  # 頭の VAR=値 (SSH_AUTH_SOCK は接続として覚える) と予約語
  while ((${#w[@]} > 0)); do
    case ${w[0]} in
      SSH_AUTH_SOCK=*) sock=$(expand_home "${w[0]#*=}") ;;
      '!' | '{' | '}' | if | then | else | elif | do | while | until) ;;
      for | case | select | function | 'fi' | 'done' | 'esac' | '[[' | '[') return 1 ;;
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
        return 1
        ;;
      env)
        w=("${w[@]:1}")
        while ((${#w[@]} > 0)); do
          case ${w[0]} in
            -u | --unset | -C | --chdir | -S | --split-string) w=("${w[@]:2}") ;;
            SSH_AUTH_SOCK=*)
              sock=$(expand_home "${w[0]#*=}")
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
        [[ ${w[1]-} == -v || ${w[1]-} == -V ]] && return 1
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
      sshpass)
        w=("${w[@]:1}")
        skip_opts '-p|-f|-d|-P'
        ;;
      watch)
        w=("${w[@]:1}")
        skip_opts '-n|--interval|-q|--equexit'
        rematch "${dir}" "${depth}" "${sock}" "${w[*]}"
        return
        ;;
      flock)
        # -c は lock のファイルの後ろにも置ける (flock FILE -c CMD)
        for ((i = 1; i < ${#w[@]}; i++)); do
          if [[ ${w[i]} == -c || ${w[i]} == --command ]]; then
            rematch "${dir}" "${depth}" "${sock}" "${w[i + 1]-}"
            return
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
                rematch "${dir}" "${depth}" "${sock}" "${w[i + 1]-}"
                return
              fi
              ;;
            *) return 1 ;;
          esac
        done
        return 1
        ;;
      eval)
        rematch "${dir}" "${depth}" "${sock}" "${w[*]:1}"
        return
        ;;
      su | runuser | script)
        for ((i = 1; i < ${#w[@]}; i++)); do
          case ${w[i]} in
            -c | --command)
              rematch "${dir}" "${depth}" "${sock}" "${w[i + 1]-}"
              return
              ;;
            --command=*)
              rematch "${dir}" "${depth}" "${sock}" "${w[i]#*=}"
              return
              ;;
          esac
        done
        return 1
        ;;
      nix-shell)
        for ((i = 1; i < ${#w[@]}; i++)); do
          if [[ ${w[i]} == --run || ${w[i]} == --command ]]; then
            rematch "${dir}" "${depth}" "${sock}" "${w[i + 1]-}"
            return
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
  ((${#w[@]} > 0)) || return 1

  base=${w[0]##*/}
  case ${base} in
    ssh)
      for ((i = 1; i < ${#w[@]}; i++)); do
        a=${w[i]}
        [[ ${a} == -* ]] || break
        # -G・-V (束ねた形も)・-O・-Q は繋がない
        [[ ${a} =~ ^-[46AaCfGgKkMNnqsTtVvXxYy]*[GV] || ${a} == -O* || ${a} == -Q* ]] && return 1
        # 値を次の語に取るオプション
        [[ ${a} =~ ^-[46AaCfGgKkMNnqsTtVvXxYy]*[BbcDEeFIiJLlmopRSWw]$ ]] && i=$((i + 1))
      done
      kind="ssh の接続"
      ;;
    scp | sftp | ssh-copy-id | sshfs | mosh | autossh) kind="ssh の接続" ;;
    rsync)
      for a in "${w[@]:1}"; do
        [[ ${a} == -* || ${a} == *::* || ${a} == rsync://* ]] && continue
        if [[ ${a} =~ ^[^/:]+: ]]; then
          kind="ssh の接続"
          break
        fi
      done
      ;;
    ssh-add)
      for a in "${w[@]:1}"; do
        [[ ${a} == -T ]] && kind="署名"
      done
      ;;
    ssh-keygen)
      for ((i = 1; i < ${#w[@]}; i++)); do
        [[ ${w[i]} == -Ysign || (${w[i]} == -Y && ${w[i + 1]-} == sign) ]] && kind="署名"
      done
      ;;
    nixos-rebuild | nixos-rebuild-ng)
      for a in "${w[@]:1}"; do
        case ${a} in
          --target-host | --target-host=* | --build-host | --build-host=*) kind="ssh の接続" ;;
        esac
      done
      ;;
    nix-copy-closure) kind="ssh の接続" ;;
    nix | nix-*)
      for a in "${w[@]:1}"; do
        [[ ${a} == *ssh://* || ${a} == *ssh-ng://* ]] && kind="ssh の接続"
      done
      ;;
    git) kind=$(git_kind "${dir}" "${w[@]:1}") ;;
  esac
  if [[ -z ${kind} ]] && extra_match "${w[@]}"; then
    kind="設定の一覧"
  fi
  [[ -n ${kind} ]] || return 1

  hit_kind=${kind}
  hit_head=${w[*]}
  hit_sock=${sock}
  return 0
}

# load_extras: 一覧に足した道具 (dotfiles.claude.sshAgentNotice.extraCommands。home-manager が置く JSON) を
# extra_cmds に読む。無い・壊れている → 空 (組み込みの一覧だけ)
load_extras() {
  local f="${HOME}/.local/state/dotfiles/claude-ssh-agent-notice.json" line
  extra_cmds=()
  [[ -f ${f} ]] || return 0
  while IFS= read -r line; do
    [[ -z ${line} ]] || extra_cmds+=("${line}")
  done < <(jq -r '.extraCommands[]? | strings' "${f}" 2>/dev/null)
}

# extra_match <語>…: 一覧の項目に当たるか。項目は語を空白で区切った glob で、1 語目を頭の語 (そのままか basename) に、
# 残りを引数の中に順に当てる (間に別の語があってよい。"nix run .#vm" は nix run -L .#vm -- ip にも当たる)
extra_match() {
  local entry x k
  local -a pat
  for entry in "${extra_cmds[@]}"; do
    read -r -a pat <<<"${entry}"
    ((${#pat[@]} > 0)) || continue
    # shellcheck disable=SC2053 # 項目の語は glob として比べる
    [[ $1 == ${pat[0]} || ${1##*/} == ${pat[0]} ]] || continue
    k=1
    for x in "${@:2}"; do
      ((k < ${#pat[@]})) || break
      # shellcheck disable=SC2053 # 項目の語は glob として比べる
      [[ ${x} == ${pat[k]} ]] && k=$((k + 1))
    done
    ((k == ${#pat[@]})) && return 0
  done
  return 1
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

# git_in <git の引数>…: git_kind が決めた dir と git の前のオプションで git を流す (エラーは捨てる)
git_in() {
  git -C "${gdir}" "${gopts[@]}" "$@" 2>/dev/null </dev/null
}

# git_kind <dir> <git の後ろの語>…: 署名するなら「署名」、相手が ssh の remote なら「ssh の接続」を出す
git_kind() {
  local gdir=$1 sub=""
  shift
  local -a gopts=() a=("$@")
  [[ -d ${gdir} ]] || gdir=${cwd}
  while ((${#a[@]} > 0)); do
    case ${a[0]} in
      -C | -c | --git-dir | --work-tree | --namespace)
        gopts+=("${a[0]}" "${a[1]-}")
        a=("${a[@]:2}")
        ;;
      --git-dir=* | --work-tree=* | --namespace=*)
        gopts+=("${a[0]}")
        a=("${a[@]:1}")
        ;;
      --version | -v | --help | -h | --exec-path | --html-path | --man-path | --info-path | --list-cmds=*) return 0 ;;
      -*) a=("${a[@]:1}") ;;
      *)
        sub=${a[0]}
        a=("${a[@]:1}")
        break
        ;;
    esac
  done
  case ${sub} in
    commit | merge | rebase | cherry-pick | revert | am | pull | commit-tree)
      if commit_signs "${a[@]}"; then
        echo "署名"
      elif [[ ${sub} == pull ]] && remote_is_ssh pull "${a[@]}"; then
        echo "ssh の接続"
      fi
      ;;
    tag) tag_signs "${a[@]}" && echo "署名" ;;
    push)
      if push_signs "${a[@]}"; then
        echo "署名"
      elif remote_is_ssh push "${a[@]}"; then
        echo "ssh の接続"
      fi
      ;;
    fetch | ls-remote | clone) remote_is_ssh "${sub}" "${a[@]}" && echo "ssh の接続" ;;
    remote) [[ ${a[0]-} == update ]] && all_remotes_ssh && echo "ssh の接続" ;;
  esac
  return 0
}

# commit_signs <語>…: commit などが署名するか。-S・--gpg-sign が先、無ければ実効の commit.gpgsign
commit_signs() {
  local a sign=""
  for a in "$@"; do
    case ${a} in
      --abort | --quit | --dry-run | --show-current-patch | --edit-todo | -h | --help) return 1 ;;
      -S* | --gpg-sign | --gpg-sign=*) sign=1 ;;
      --no-gpg-sign) sign=0 ;;
    esac
  done
  if [[ -z ${sign} ]]; then
    sign=0
    [[ $(git_in config --type=bool --get commit.gpgsign) == true ]] && sign=1
  fi
  [[ ${sign} == 1 ]]
}

# tag_signs <語>…: tag を作り、署名するか。一覧・削除・検証は作らない
tag_signs() {
  local a sign="" annotate=0 create=0
  for a in "$@"; do
    case ${a} in
      -l | --list | -d | --delete | -v | --verify | --contains | --no-contains | --merged | --no-merged | --points-at | -n* | --column* | --sort* | --format* | -h | --help) return 1 ;;
      -s | --sign | -u | -u?* | --local-user | --local-user=*) sign=1 ;;
      --no-sign) sign=0 ;;
      -a | --annotate | -m | -m?* | --message | --message=* | -F | -F?* | --file | --file=*) annotate=1 ;;
      -*) ;;
      *) create=1 ;;
    esac
  done
  ((create)) || return 1
  if [[ -z ${sign} ]]; then
    sign=0
    if [[ $(git_in config --type=bool --get tag.gpgsign) == true ]]; then
      sign=1
    elif ((annotate)) && [[ $(git_in config --type=bool --get tag.forcesignannotated) == true ]]; then
      sign=1
    fi
  fi
  [[ ${sign} == 1 ]]
}

# push_signs <語>…: push の証明書 (--signed・push.gpgsign) に署名するか
push_signs() {
  local a sign="" v
  for a in "$@"; do
    case ${a} in
      --signed | --signed=true | --signed=yes | --signed=if-asked) sign=1 ;;
      --no-signed | --signed=false | --signed=no) sign=0 ;;
    esac
  done
  if [[ -z ${sign} ]]; then
    v=$(git_in config --get push.gpgsign)
    case ${v,,} in
      true | yes | on | 1 | if-asked) sign=1 ;;
      *) sign=0 ;;
    esac
  fi
  [[ ${sign} == 1 ]]
}

# remote_is_ssh <サブコマンド> <語>…: 相手の URL (insteadOf を解いたもの) が ssh か。--all は全部の remote を見る
remote_is_ssh() {
  local sub=$1 takes repo="" all=0 i url
  shift
  local -a a=("$@")
  case ${sub} in
    clone) takes='|-o|-b|-c|-j|-u|--origin|--branch|--config|--jobs|--upload-pack|--depth|--shallow-since|--shallow-exclude|--reference|--reference-if-able|--separate-git-dir|--template|--filter|--bundle-uri|--server-option|' ;;
    push) takes='|-o|--push-option|--receive-pack|--exec|' ;;
    ls-remote) takes='|-o|--server-option|--upload-pack|--sort|' ;;
    *) takes='|-o|-j|-s|-X|--server-option|--jobs|--depth|--deepen|--shallow-since|--shallow-exclude|--refmap|--negotiation-tip|--filter|--upload-pack|--strategy|--strategy-option|--recurse-submodules-default|' ;;
  esac
  for ((i = 0; i < ${#a[@]}; i++)); do
    case ${a[i]} in
      --all | --multiple) [[ ${sub} == push ]] || all=1 ;;
      --repo=*) repo=${a[i]#*=} ;;
      --repo)
        repo=${a[i + 1]-}
        i=$((i + 1))
        ;;
      -*) [[ ${takes} == *"|${a[i]}|"* ]] && i=$((i + 1)) ;;
      *) [[ -n ${repo} ]] || repo=${a[i]} ;;
    esac
  done
  if ((all)); then
    all_remotes_ssh
    return
  fi
  if [[ -n ${repo} ]]; then
    url=$(git_in ls-remote --get-url "${repo}")
    [[ -n ${url} ]] || url=${repo}
  else
    [[ ${sub} != clone ]] || return 1
    url=$(git_in ls-remote --get-url)
  fi
  is_ssh_url "${url}"
}

all_remotes_ssh() {
  local r
  while IFS= read -r r; do
    [[ -n ${r} ]] || continue
    is_ssh_url "$(git_in ls-remote --get-url "${r}")" && return 0
  done < <(git_in remote)
  return 1
}

# is_ssh_url <URL>: ssh:// か、scp の形 (<host>:<path>) か
is_ssh_url() {
  case $1 in
    ssh://* | git+ssh://* | ssh+git://*) return 0 ;;
    *://* | /* | ./* | ../* | '~'* | '') return 1 ;;
  esac
  [[ $1 =~ ^[^/:]+: ]]
}

# --- 承認の画面の接続

# record_field <file> <key>: pjp-agent-link の記録 (key=value の行) から 1 つ読む
record_field() {
  local k v
  [[ -f $1 ]] || return 1
  while IFS='=' read -r k v; do
    if [[ ${k} == "$2" ]]; then
      printf '%s' "${v}"
      return 0
    fi
  done <"$1"
  return 1
}

agent_record() {
  printf '%s' "${HOME}/.local/state/pjp-agent-link/conn/${1##*/}"
}

mtime() {
  stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null || echo 0
}

fmt_time() {
  date -d "@$1" '+%m/%d %H:%M' 2>/dev/null || date -r "$1" '+%m/%d %H:%M' 2>/dev/null
}

tilde() {
  printf '%s' "${1/#"${HOME}"/\~}"
}

# conn_epoch <socket>: 接続が入った時刻 (UNIX 秒)。記録の opened (ns)、無ければファイルの時刻
conn_epoch() {
  local opened
  opened=$(record_field "$(agent_record "$1")" opened) || opened=""
  if [[ ${opened} =~ ^[0-9]{10,}$ ]]; then
    printf '%s' "${opened:0:${#opened}-9}"
  else
    mtime "$1"
  fi
}

# conn_client <socket>: 記録の PJP_SSH_CLIENT の値 (無い・% が残る値は出さない)
conn_client() {
  local c
  c=$(record_field "$(agent_record "$1")" client) || return 0
  [[ -n ${c} && ${c} != *%* ]] && printf '%s' "${c}"
  return 0
}

# conn_desc <SSH_AUTH_SOCK の値>: 「承認の画面は…」の文 (日本語と英数字の間にだけ空白を置くので、文ごと返す)
conn_desc() {
  local sock=$1 target t tgt_t best_t=0 newer="" f client
  if [[ -z ${sock} ]]; then
    # WSL の ssh は Windows の ssh.exe へのラッパーで、SSH_AUTH_SOCK を使わない (nix/README「WSL の .exe の起動を
    # 常時記録する」)。ほかのマシンでも ssh の設定の IdentityAgent で agent を使うことがあるので、出ないとは言わない
    if [[ -n ${WSL_DISTRO_NAME:-} ]]; then
      printf '承認の画面は Windows の 1Password が出す (要求元は「Windows Terminal」としか出ない)'
    else
      printf '承認の画面がどこに出るかは分からない (SSH_AUTH_SOCK が空)'
    fi
    return
  fi
  target=$(readlink -f -- "${sock}" 2>/dev/null) || target=""
  [[ -n ${target} ]] || target=${sock}
  if [[ ! -e ${target} ]]; then
    printf '承認の画面は出ない (agent の口 %s の先が無い)' "$(tilde "${sock}")"
    return
  fi
  case ${target##*/} in
    s.*.sshd.*) ;;
    *)
      printf '承認の画面はこのマシンの agent (%s) が出す' "$(tilde "${target}")"
      return
      ;;
  esac
  tgt_t=$(conn_epoch "${target}")
  client=$(conn_client "${target}")
  printf '承認の画面は %s に%s入った接続の端末に出る' "$(fmt_time "${tgt_t}")" "${client:+ ${client} から}"
  for f in "${target%/*}"/s.*.sshd.*; do
    [[ -e ${f} && ${f} != "${target}" ]] || continue
    t=$(conn_epoch "${f}")
    ((t > tgt_t && t > best_t)) || continue
    best_t=${t}
    newer=${f}
  done
  if [[ -n ${newer} ]]; then
    client=$(conn_client "${newer}")
    printf ' (より新しい接続: %s%s)' "$(fmt_time "${best_t}")" "${client:+ ${client}}"
  fi
}

# clip <文字列>: 80 文字で切る (jq で切るので、文字の途中で切らない)
clip() {
  jq -rn --arg s "$1" '$s | if length > 80 then .[0:79] + "…" else . end'
}

# --- herdr の通知と、どこから

herdr_down_path() {
  printf '%s/pjp-ssh-agent-notice/herdr-down' "${XDG_STATE_HOME:-${HOME}/.local/state}"
}

# herdr_ready: herdr の pane で herdr があり、この回と直近 60 秒に呼べなかったことが無い
herdr_ready() {
  local f
  ((herdr_failed == 0)) || return 1
  [[ ${HERDR_ENV:-} == 1 ]] || return 1
  command -v herdr &>/dev/null || return 1
  f=$(herdr_down_path)
  [[ ! -e ${f} ]] || (($(date +%s) - $(mtime "${f}") >= 60))
}
herdr_failed=0

# herdr_down: 落ちた・返事をしない herdr を、この回の残りと続く 60 秒は呼ばない (Bash を毎回待たせない)
herdr_down() {
  local f
  herdr_failed=1
  f=$(herdr_down_path)
  mkdir -p "${f%/*}" 2>/dev/null && touch "${f}" 2>/dev/null
  return 0
}

# herdr_call <引数>…: 2 秒で切って呼ぶ。timeout の無いマシン (macOS) では裏で流して見張る
herdr_call() {
  local f pid i rc
  if command -v timeout &>/dev/null; then
    timeout 2 herdr "$@" </dev/null 2>/dev/null
    return
  fi
  f=$(mktemp "${TMPDIR:-/tmp}/ssh-agent-notice.XXXXXX") || return 1
  herdr "$@" </dev/null >"${f}" 2>/dev/null &
  pid=$!
  for ((i = 0; i < 20; i++)); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null
    rm -f "${f}"
    return 124
  fi
  wait "${pid}"
  rc=$?
  cat "${f}"
  rm -f "${f}"
  return "${rc}"
}

# herdr_notify <title> <body>: 音つきで知らせる。出せたら 0
herdr_notify() {
  herdr_ready || return 1
  herdr_call notification show "$1" --body "$2" --sound request >/dev/null && return 0
  herdr_down
  return 1
}

# where_desc: 「どこから」(workspace の名前・pane の ID・agent の名前・subagent) を where に、workspace の名前を
# ws_label に入れる (呼び出し元で使うので $( ) で呼ばない)
where_desc() {
  local agent_name="" agent_type part got
  local -a parts=()
  where=""
  ws_label=""
  if [[ ${HERDR_ENV:-} == 1 ]]; then
    if [[ -n ${HERDR_WORKSPACE_ID:-} ]] && herdr_ready; then
      if got=$(herdr_call workspace get "${HERDR_WORKSPACE_ID}"); then
        ws_label=$(jq -r '.result.workspace.label // empty' <<<"${got}" 2>/dev/null)
      else
        herdr_down
      fi
    fi
    if [[ -n ${HERDR_PANE_ID:-} ]] && herdr_ready; then
      if got=$(herdr_call agent get "${HERDR_PANE_ID}"); then
        agent_name=$(jq -r '.result.agent.name // empty' <<<"${got}" 2>/dev/null)
      else
        herdr_down
      fi
    fi
    [[ -z ${ws_label} ]] || parts+=("workspace「${ws_label}」")
    [[ -z ${HERDR_PANE_ID:-} ]] || parts+=("pane ${HERDR_PANE_ID}")
    [[ -z ${agent_name} ]] || parts+=("agent ${agent_name}")
  fi
  agent_type=$(field '.agent_type')
  [[ -z $(field '.agent_id') ]] || parts+=("subagent ${agent_type:-?}")
  for part in "${parts[@]}"; do
    where+=${where:+・}${part}
  done
  [[ -n ${where} ]] || where="herdr の外の会話"
}

# 同じ pane からの herdr の通知は 600 秒に 1 回。印は出せた通知の時刻
stamp_path() {
  local key="${HERDR_SESSION:-default}-${HERDR_PANE_ID:-}"
  printf '%s/pjp-ssh-agent-notice/notified-%s' "${XDG_STATE_HOME:-${HOME}/.local/state}" "${key//[^A-Za-z0-9_-]/_}"
}

notify_due() {
  local f
  f=$(stamp_path)
  [[ -e ${f} ]] || return 0
  (($(date +%s) - $(mtime "${f}") >= 600))
}

touch_stamp() {
  local f
  f=$(stamp_path)
  mkdir -p "${f%/*}" 2>/dev/null && touch "${f}" 2>/dev/null
  return 0
}

# --- 打つ前

before() {
  local prefilter='ssh|scp|sftp|mosh|rsync|nixos-rebuild|nix-copy-closure|git' conn head entry need=0
  local -a first
  [[ -n ${cmd} ]] || return 0
  # 安く抜ける前段。一覧の項目の 1 語目もコマンドの文字にあれば読む (glob の文字を含む 1 語目は、いつも読む)
  load_extras
  for entry in "${extra_cmds[@]}"; do
    read -r -a first <<<"${entry}"
    case ${first[0]-} in
      '') ;;
      *[*?[]*) need=1 ;;
      *) [[ ${cmd} != *"${first[0]}"* ]] || need=1 ;;
    esac
  done
  ((need)) || [[ ${cmd} =~ ${prefilter} ]] || return 0
  hit_kind=""
  hit_head=""
  hit_sock=""
  match_command "${cwd}" 0 "${cmd}" || return 0
  conn=$(conn_desc "${hit_sock:-${SSH_AUTH_SOCK:-}}")
  head=$(clip "${hit_head}")
  jq -cn --arg m "🔑 1Password の承認が出るかも (${hit_kind}): ${head} — ${conn}" '{systemMessage: $m}' || true
  if herdr_ready && notify_due; then
    where_desc
    herdr_notify "🔑 1Password の承認が出るかも" "${where}"$'\n'"${head}"$'\n'"${conn}" && touch_stamp
  fi
  return 0
}

# --- 断られたあと

# agent_kind <sock>: agent の口の種類。forwarded (sshd が転送した s.*.sshd.*。先が無くても)・local (ほかの口)・
# windows (WSL で SSH_AUTH_SOCK が空。ssh は Windows の ssh.exe)・none (空)
agent_kind() {
  local target
  if [[ -z $1 ]]; then
    if [[ -n ${WSL_DISTRO_NAME:-} ]]; then
      echo windows
    else
      echo none
    fi
    return
  fi
  target=$(readlink -f -- "$1" 2>/dev/null) || target=""
  case ${target:-$1} in
    */s.*.sshd.*) echo forwarded ;;
    *) echo local ;;
  esac
}

# refusal_reason <event> <出力 (\r を外したもの)>: 断りの理由を出す (refused・broken・unreachable と、鍵の認証の
# 失敗の publickey)。無ければ 1。どちらも行の終わりが文言のときだけ当てる (ssh・git の行は文言で終わり、diff・
# コード・文書の行はそうでない)。終わりの決まらない git の鍵の読み込みの失敗は、git がいつも付ける行の頭の
# error: で固定する。成功した Bash は、ssh・git の出す行の頭も固定する (成功した grep・cat の結果に出た文言で
# 当てない。2>&1 | tail で終了コードが隠れても、ssh・git の行はそのまま出る)
refusal_reason() {
  local i lead="^(sign_and_send_pubkey: |Couldn't sign |Signing |error: ).*"
  local -a pat reasons=(refused broken unreachable publickey)
  if [[ $1 == PostToolUseFailure ]]; then
    pat=(
      'agent refused operation\??$'
      'communication with agent failed\??$'
      "Couldn't get agent socket\\??\$|^error: Couldn't load public key [^ ]*\\.git_signing_key_tmp[^ ]*: "
      'Permission denied \([^)]*publickey[^)]*\)\.?$'
    )
  else
    pat=(
      "${lead}agent refused operation\\??\$"
      "${lead}communication with agent failed\\??\$"
      "^error: Couldn't (get agent socket\\??\$|load public key [^ ]*\\.git_signing_key_tmp)"
      '^([^ ]+: )?Permission denied \([^)]*publickey[^)]*\)\.?$'
    )
  fi
  for i in 0 1 2 3; do
    if grep -Eq "${pat[i]}" <<<"$2"; then
      echo "${reasons[i]}"
      return 0
    fi
  done
  return 1
}

after() {
  local text reason head conn title desc first rule sock
  text=$(jq -r '[.error, .tool_response.stdout, .tool_response.stderr] | map(strings) | join("\n")' <<<"${input}" 2>/dev/null) || return 0
  case ${text} in
    *agent* | *publickey* | *git_signing_key*) ;;
    *) return 0 ;;
  esac
  # OpenSSH は自分のエラー行を \r\n で終え、Claude Code は tool の出力の \r を残す
  text=${text//$'\r'/}
  reason=$(refusal_reason "${event}" "${text}") || return 0

  hit_kind=""
  hit_head=""
  hit_sock=""
  if [[ -n ${cmd} ]] && match_command "${cwd}" 0 "${cmd}"; then
    head=${hit_head}
  else
    head=${cmd%%$'\n'*}
  fi
  sock=${hit_sock:-${SSH_AUTH_SOCK:-}}
  # 鍵の認証の失敗は、agent の口があって、その先が無いときだけ agent に届かないとみなす。口が生きていれば鍵が相手に
  # 無いだけで、空なら agent を使っていない (WSL の ssh.exe など)
  if [[ ${reason} == publickey ]]; then
    [[ -n ${sock} && ! -e ${sock} ]] || return 0
    reason=unreachable
  fi
  head=$(clip "${head}")
  conn=$(conn_desc "${sock}")

  case ${reason} in
    refused)
      title="🔑 1Password に断られた"
      desc='1Password に断られた (承認の画面で断られたか、応えないまま時間切れになったか、1Password がロック中だった)'
      ;;
    broken)
      title="🔑 SSH agent との通信が切れた"
      desc='agent との通信が切れた (agent への接続が途中で閉じた)'
      ;;
    *)
      title="🔑 SSH agent に届かない"
      desc='agent に届かない (SSH_AUTH_SOCK の先に agent がいない)'
      ;;
  esac
  # 1 つ目の選択肢: 断られたら承認する。通信が切れた・届かないなら、agent の口の種類ごとの直し方
  if [[ ${reason} == refused ]]; then
    first='1Password を開いて承認するので、打ち直す'
  else
    case $(agent_kind "${sock}") in
      forwarded) first='手元の PC からこのマシンへ接続し直す (agent の口を張り替える) ので、打ち直す' ;;
      local) first='1Password を起動してロックを解除するので、打ち直す' ;;
      windows) first='Windows の 1Password を起動してロックを解除するので、打ち直す' ;;
      *) first='agent を使えるようにする (SSH_AUTH_SOCK を設定する) ので、打ち直す' ;;
    esac
  fi

  where_desc
  local ctx="[ssh-agent] 直前の Bash は SSH agent (1Password) を使えずに失敗した: ${desc}。"$'\n'
  ctx+="同じコマンドを打ち直さない (承認されないまま同じ失敗を繰り返す)。"$'\n'
  if [[ -n $(field '.agent_id') ]]; then
    ctx+="subagent の中なので、ユーザーには聞かない。ここまでの結果と、失敗したこと (何を: ${head} の接続先や署名する対象。"
    ctx+="どこから: ${where}。${conn}) を報告に書いて作業を終える。問いは呼び出した会話が出す。"
  else
    if [[ ${ws_label} == 🌱* ]]; then
      rule='この pane は herdr の指揮役の子 (workspace の名前が 🌱 で始まる) なので、AskUserQuestion を使わず、問いと選択肢を書いてターンを終える (指揮役がユーザーに聞く)。'
    else
      rule='herdr の指揮役から依頼を受けて動いている子は、AskUserQuestion を使わず、問いと選択肢を書いてターンを終える (指揮役がユーザーに聞く)。それ以外は AskUserQuestion で聞く。'
    fi
    ctx+="1. 何を (${head} の接続先や署名する対象) と、どこから (${where}) を書く。${conn}。"$'\n'
    ctx+="2. 選択肢の問いを出す: ① ${first} (推奨) ② この手順を飛ばして進める ③ ここで止める。① が選ばれたら、同じコマンドを 1 回だけ打ち直す。"$'\n'
    ctx+=${rule}
  fi

  jq -cn --arg m "${title}: ${head} — ${conn}" --arg ev "${event}" --arg c "${ctx}" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: $ev, additionalContext: $c}}' || true
  herdr_notify "${title}" "${where}"$'\n'"${head}"$'\n'"${conn}" || true
  return 0
}

case ${event} in
  PreToolUse) before ;;
  PostToolUse | PostToolUseFailure) after ;;
esac
exit 0
