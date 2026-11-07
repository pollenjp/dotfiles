#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の hook。WSL の op (dotfiles の pkgs/pjp-op。理由 (--reason) が必須の 1Password CLI の wrapper) を守る。
#
# WSL から直に op.exe を起こすと、1Password の承認がどの pane にも共通の wsl.exe に付き、1 回の許可が後の呼び出しとほかの
# pane に効く。op は呼び出しごとの powershell で承認を閉じ、承認の画面と一緒に呼び手と理由の窓を出して記録する。
# 設計は dotfiles-private の docs/superpowers/specs/2026-11-07-op-wrapper-reason-design.md。
#
# ## 打つ前 (PreToolUse・matcher Bash)
#
# コマンドの中に op.exe を直に起こす単純コマンドがあれば止め (permissionDecision の deny)、op --reason "<理由>" … で打ち直す
# よう返す。承認の要らない whoami・signout・--version・-v・--help・-h・help と引数なしは止めない。
#
# 読み方は ssh-agent-notice.sh と同じ。lexer (awk)・pick_awk・split_commands・skip_opts はそのまま写し、match_simple の
# 「頭の VAR=値と予約語」と「包むコマンドを外す」(env・sudo・exec・command・nohup・nice・timeout・xargs・watch・flock・
# bash -c・eval・su・nix-shell・nix develop -c など) を、ssh の判定を除いて op_simple に写した (直すときは両方を直す)。
# 引用符・heredoc の本文・コメントの中の op.exe では止めない (commit のメッセージや grep の引数)。頭の語の basename を
# 小文字にして op.exe と比べる。script の中・関数・変数に入れた op.exe は見えない (窓の無い承認の画面は拒否する決まりと、
# op の共有の承認の見張りで守る)。
#
# ## 拒否・時間切れのあと (PostToolUse・PostToolUseFailure・matcher Bash)
#
# op の記録 (${XDG_STATE_HOME:-~/.local/state}/pjp-op/log.jsonl と log.1.jsonl) に、この会話 (入力の session_id。op は
# CLAUDE_CODE_SESSION_ID を書く) の end で result が denied か timeout のものが、まだ見ていないものとしてあれば、Claude に
# 「同じ op を打ち直さず、選択肢の問いを出す」指示を足し (additionalContext)、会話の画面に 1 行出す (systemMessage)。
# 続けて承認の画面が出ると慣れで許可しやすくなり、「窓の無い承認は拒否」の決まりが弱まるため。op は op の stderr を変えない
# ので、文言ではなく記録で見る。見た印は同じ dir の hook-seen/<session> (見た end の epoch の最大)。記録が印より古ければ
# 読まない。herdr の指揮役の子と subagent の決まりは ssh-agent-notice.sh と同じ (子の印は workspace の token と名前)。
#
# ## 黙る場面
#
#   - ~/.local/state/dotfiles/claude-op-reason.json の enable が true でないマシン (op の wrapper が無い。home/modules/op-reason.nix)
#   - Bash 以外の tool・op.exe の文字の無いコマンド (Pre)・この会話の新しい拒否・時間切れが記録に無い (Post)
#   - 想定外の入力・jq が無いとき。tool の流れを止めないよう、何があっても exit 0 で終える
#
# ## 登録
#
# scripts/bootstrap-claude-hook.sh が settings.json の hooks の PreToolUse・PostToolUse・PostToolUseFailure に 1 件ずつ
# (matcher Bash) 足す。

set -u -o pipefail

# 黙って抜ける場合も、先に stdin を読み切る (書き手の Claude Code を待たせない)
input=$(cat) || exit 0

command -v jq &>/dev/null || exit 0

# 入力の 1 項目を取り出す。無い・壊れている → 空文字
field() {
  jq -r "$1 // empty" <<<"${input}" 2>/dev/null || true
}

[[ $(field '.tool_name') == Bash ]] || exit 0
[[ $(jq -r '.enable // false' "${HOME}/.local/state/dotfiles/claude-op-reason.json" 2>/dev/null) == true ]] || exit 0

event=$(field '.hook_event_name')
cmd=$(field '.tool_input.command')

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

# find_op <段> <コマンドの文字列>: op.exe を直に起こす単純コマンドがあれば、包むコマンドを外した語を hit_head に入れて 0
find_op() {
  local depth=$1 line
  local -a w
  ((depth <= 3)) || return 1
  pick_awk
  ((${#2} <= lex_limit)) || return 1
  while IFS= read -r line; do
    IFS=$'\037' read -r -a w <<<"${line}"
    ((${#w[@]} > 0)) || continue
    if op_simple "${depth}" "${w[@]}"; then
      return 0
    fi
  done < <(split_commands "$2")
  return 1
}

# rematch <段> <文字列>: 文字列を読み直す (bash -c など)
rematch() {
  find_op "$(($1 + 1))" "$2"
}

# op_simple <段> <語>…: 単純コマンドを 1 つ見る (find_op の説明)
op_simple() {
  local depth=$1 base i guard=0
  shift
  local -a w=("$@")

  # 頭の VAR=値と予約語
  while ((${#w[@]} > 0)); do
    case ${w[0]} in
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
      cd | pushd) return 1 ;;
      env)
        w=("${w[@]:1}")
        while ((${#w[@]} > 0)); do
          case ${w[0]} in
            -u | --unset | -C | --chdir | -S | --split-string) w=("${w[@]:2}") ;;
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
      watch)
        w=("${w[@]:1}")
        skip_opts '-n|--interval|-q|--equexit'
        rematch "${depth}" "${w[*]}"
        return
        ;;
      flock)
        # -c は lock のファイルの後ろにも置ける (flock FILE -c CMD)
        for ((i = 1; i < ${#w[@]}; i++)); do
          if [[ ${w[i]} == -c || ${w[i]} == --command ]]; then
            rematch "${depth}" "${w[i + 1]-}"
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
                rematch "${depth}" "${w[i + 1]-}"
                return
              fi
              ;;
            *) return 1 ;;
          esac
        done
        return 1
        ;;
      eval)
        rematch "${depth}" "${w[*]:1}"
        return
        ;;
      su | runuser | script)
        for ((i = 1; i < ${#w[@]}; i++)); do
          case ${w[i]} in
            -c | --command)
              rematch "${depth}" "${w[i + 1]-}"
              return
              ;;
            --command=*)
              rematch "${depth}" "${w[i]#*=}"
              return
              ;;
          esac
        done
        return 1
        ;;
      nix-shell)
        for ((i = 1; i < ${#w[@]}; i++)); do
          if [[ ${w[i]} == --run || ${w[i]} == --command ]]; then
            rematch "${depth}" "${w[i + 1]-}"
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
  [[ ${base,,} == op.exe ]] || return 1
  # 承認の要らないもの (承認が無ければ whoami も画面を出さない)
  case ${w[1]-} in
    '' | whoami | signout | --version | -v | --help | -h | help) return 1 ;;
  esac
  hit_head=${w[*]}
  return 0
}

before() {
  local reason
  [[ -n ${cmd} && ${cmd,,} == *op.exe* ]] || return 0
  hit_head=""
  find_op 0 "${cmd}" || return 0
  reason='[op] op.exe を直接打たない。WSL では op --reason "<なぜ op を呼ぶか>" <op の引数…> で呼ぶ (dotfiles の wrapper。'
  reason+='承認を呼び出しごとの powershell に閉じ、承認の画面と一緒に呼び手と理由を窓に出して記録する)。'
  reason+='理由はユーザーが承認の画面の横で読むので、何のために何を読む・書くかを 1 文で書く。'
  reason+='承認は呼び出しごとに出るので、呼ぶ回数を減らす (例: vault get を 11 回打たず vault list --format json を 1 回にする。'
  reason+='複数の項目は item list --format json や op inject でまとめて読む)。op.exe の whoami・signout・--version・--help は打ってよい。'
  reason+=" (止めたもの: ${hit_head:0:200})"
  jq -cn --arg r "${reason}" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' || true
  return 0
}

# child_mark: この pane の workspace に herdr の指揮役の子の印があれば 0 (ssh-agent-notice.sh の child_mark と同じ印。ADR 036)
child_mark() {
  local got
  [[ ${HERDR_ENV:-} == 1 && -n ${HERDR_WORKSPACE_ID:-} ]] || return 1
  command -v herdr &>/dev/null || return 1
  got=$(timeout 2 herdr workspace get "${HERDR_WORKSPACE_ID}" </dev/null 2>/dev/null) || return 1
  jq -e '.result.workspace
    | ((.tokens.parent // "") != "")
      or ((.tokens.kin // "") | startswith("🌱"))
      or ((.label // "") | startswith("🌱"))' <<<"${got}" &>/dev/null
}

after() {
  local session dir log seen_file seen=0 got hit result when reason command where ctx title desc first rule
  local -a files=()
  session=$(field '.session_id')
  [[ -n ${session} ]] || return 0
  dir=${XDG_STATE_HOME:-${HOME}/.local/state}/pjp-op
  log=${dir}/log.jsonl
  [[ -f ${log} ]] || return 0
  seen_file=${dir}/hook-seen/${session//[^A-Za-z0-9_-]/_}
  if [[ -f ${seen_file} ]]; then
    [[ ${log} -nt ${seen_file} ]] || return 0
    seen=$(<"${seen_file}")
    [[ ${seen} =~ ^[0-9]+$ ]] || seen=0
  fi
  [[ ! -f ${dir}/log.1.jsonl ]] || files+=("${dir}/log.1.jsonl")
  files+=("${log}")
  got=$(jq -cnR --arg s "${session}" --argjson seen "${seen}" '
    [inputs | fromjson? | objects] as $recs
    | ($recs | map(select(.event == "start" and (.id | type) == "string")) | map({key: .id, value: .}) | from_entries) as $starts
    | [$recs[] | select(.event == "end" and .session == $s and ((.epoch // 0) > $seen))] as $ends
    | {max: ([$ends[].epoch] + [$seen] | max),
       hit: ([$ends[] | select(.result == "denied" or .result == "timeout")] | last
         | if . == null then null else . + {start: ($starts[.id] // {})} end)}' "${files[@]}" 2>/dev/null) || return 0
  mkdir -p "${seen_file%/*}" 2>/dev/null && jq -r '.max' <<<"${got}" >"${seen_file}" 2>/dev/null
  hit=$(jq -c '.hit // empty' <<<"${got}")
  [[ -n ${hit} ]] || return 0

  result=$(jq -r '.result' <<<"${hit}")
  when=$(jq -r '(.time // "")[11:19]' <<<"${hit}")
  reason=$(jq -r '.start.reason // ""' <<<"${hit}")
  command=$(jq -r '"op " + ((.start.args // []) | join(" "))' <<<"${hit}")
  where=$(jq -r '.start.caller.herdr // null
    | if . == null then "herdr の外の会話"
      else "workspace「" + ((.label // "") | if . == "" then "?" else . end) + "」・pane " + (.pane // "?") end' <<<"${hit}")

  if [[ ${result} == denied ]]; then
    title="🔑 op の承認が拒否された"
    desc="1Password の承認が拒否された"
    first="承認の画面と窓を見て許可するので、1 回だけ打ち直す"
  else
    title="⏱ op の承認が時間切れになった"
    desc="1Password の承認の画面に応えないまま時間切れになった"
    first="承認の画面が出たら許可するので、1 回だけ打ち直す"
  fi
  ctx="[op] 直前の Bash の op は、${desc} (${when}・理由「${reason}」・${command})。"
  ctx+="同じ op を打ち直さない (打ち直すと承認の画面がまた出て、慣れで許可しやすくなる)。"$'\n'
  if [[ -n $(field '.agent_id') ]]; then
    ctx+="subagent の中なので、ユーザーには聞かない。ここまでの結果と、${desc}こと (何を: ${command}。なぜ: ${reason}。"
    ctx+="どこから: ${where}) を報告に書いて作業を終える。問いは呼び出した会話が出す。"
  else
    if child_mark; then
      rule='この pane は herdr の指揮役の子 (workspace に子の印 🌱 か、親を示す ↑ がある) なので、AskUserQuestion を使わず、問いと選択肢を書いてターンを終える (指揮役がユーザーに聞く)。'
    else
      rule='herdr の指揮役から依頼を受けて動いている子は、AskUserQuestion を使わず、問いと選択肢を書いてターンを終える (指揮役がユーザーに聞く)。それ以外は AskUserQuestion で聞く。'
    fi
    ctx+="1. 何を (${command}) と、なぜ (理由「${reason}」) と、どこから (${where}) を書く。"$'\n'
    ctx+="2. 選択肢の問いを出す: ① ${first} (推奨) ② この手順を飛ばして進める ③ ここで止める。① が選ばれたら、同じ op を 1 回だけ打ち直す。"$'\n'
    ctx+=${rule}
  fi
  jq -cn --arg m "${title}: ${command} (理由「${reason}」)" --arg ev "${event}" --arg c "${ctx}" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: $ev, additionalContext: $c}}' || true
  return 0
}

case ${event} in
  PreToolUse) before ;;
  PostToolUse | PostToolUseFailure) after ;;
esac
exit 0
