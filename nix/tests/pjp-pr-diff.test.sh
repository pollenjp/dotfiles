#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/pkgs/pjp-pr-diff/pjp-pr-diff.sh の振る舞いを、使い捨ての git repo で確かめる。
#
#   bash nix/tests/pjp-pr-diff.test.sh [<pjp-pr-diff.sh のパス>]
#
# flake の checks (pjp-pr-diff-test) が Nix のサンドボックスで流す。使うのは bash・git・fzf・jq・
# coreutils・grep だけ。GitHub には出ない (origin は手元の bare repo、gh は偽物)。
#
# fzf は端末が無いと選べないので、本物の fzf を FZF_DEFAULT_OPTS の --filter=<query> で非対話にして
# 流す (query に当たった行をすべて選んで Enter したのと同じになる)。PATH の先頭には、引数・入力・
# cwd を書き留めてから本物の fzf へ渡す薄い fzf を置く。プレビューは fzf と同じ形 (--with-shell の
# shell に、{1} を埋めたコマンドを渡す) で走らせて確かめる。SHELL は bash の構文を読めない偽物
# (fish の代わり) に向けておく。
#
# ## 確かめること
#
#   - 比べる範囲は merge-base(base, HEAD) から HEAD まで。base が後から進めた変更は混ざらない
#   - base は --base > gh pr view の baseRefName (origin/<名前>) > origin/HEAD の順に決まる。
#     PR の base が手元に無いときと、どれも決まらないときは、別の base へ黙って落ちずに止まる
#   - 1 つ選べばそのファイルだけ、複数選べばそれらだけの差分を出す。何も選ばなければ何も出さない
#     (エラーも出さない)。検索はパスだけに当たり、状態の文字 (A・D など) では選ばれない
#   - プレビューは、その行のファイルの差分を色付きで出す (SHELL が fish でも、script を相対パスで
#     呼んでも)
#   - 空白・日本語・改行・タブ・glob の文字を含むパス、rename、サブディレクトリからの実行
#   - 変更が無ければ fzf を開かずに終わる。知らない引数は exit 2

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=$(realpath -- "${1:-${here}/../pkgs/pjp-pr-diff/pjp-pr-diff.sh}")
invoke=${script}
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-pr-diff-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# 流す人の fzf の設定に左右されないようにする
unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE FZF_DEFAULT_COMMAND

if ! real_fzf=$(command -v fzf); then
  echo "見つからない: fzf" >&2
  exit 1
fi

# 偽物の shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)
bin="${work}/bin"
log="${work}/fzf-log"
mkdir -p "${bin}" "${log}"

# fzf: 引数 (NUL 区切り)・入力・cwd を書き留めてから本物へ渡す
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\0' "$@" >"${FAKE_FZF_LOG}/args"
pwd >"${FAKE_FZF_LOG}/cwd"
tee "${FAKE_FZF_LOG}/input" | "${FAKE_FZF_REAL}" "$@"
EOF
} >"${bin}/fzf"

# gh: `gh pr view --json <列> --jq <式>` だけを本物と同じ形で返す。FAKE_GH_PR (gh pr view --json が
# 返す JSON のファイル) が無ければ、PR の無い branch で本物が返すのと同じく exit 1 する
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
if [[ ${1:-} != pr || ${2:-} != view ]]; then
  echo "fake gh: 想定していない呼び出し: $*" >&2
  exit 2
fi
shift 2
fields='' expr=''
while (($#)); do
  case $1 in
    --json) fields=$2 && shift 2 ;;
    --jq | -q) expr=$2 && shift 2 ;;
    *) echo "fake gh: 想定していない引数: $1" >&2 && exit 2 ;;
  esac
done
if [[ -z ${FAKE_GH_PR:-} ]]; then
  echo "no pull requests found for branch \"$(git branch --show-current)\"" >&2
  exit 1
fi
json=$(jq -c --arg f "${fields}" '. as $pr | reduce ($f | split(","))[] as $k ({}; .[$k] = $pr[$k])' "${FAKE_GH_PR}")
if [[ -n ${expr} ]]; then
  jq -r "${expr}" <<<"${json}"
else
  printf '%s\n' "${json}"
fi
EOF
} >"${bin}/gh"

# fish の代わり。fzf が SHELL でプレビューを走らせると、bash の構文が通らずに落ちる
{
  printf '#!%s\n' "${BASH}"
  echo 'echo "fake fish: bash の構文は読めない" >&2; exit 127'
} >"${work}/fish"
chmod +x "${bin}/fzf" "${bin}/gh" "${work}/fish"
export SHELL="${work}/fish"

# gh pr view --json が返す JSON (PR #7)。$1: baseRefName
pr_json() {
  local f="${work}/pr-$1.json"
  jq -n --arg base "$1" '{number: 7, title: "t", state: "OPEN", isDraft: true, baseRefName: $base, headRefName: "stacked", url: "https://github.com/o/r/pull/7"}' >"${f}"
  printf '%s' "${f}"
}

# ------------------------------------------------------------------------------------------------
# 手元の「GitHub」(bare repo) と作業用の clone
#
#   c1 ─┬─ c2 (main: main-only.txt を足す。feat を切った後に進んだ)
#       ├─ f1 (feat)
#       └─ d1 (develop: dev-only.txt) ─ s1 (stacked: stacked.txt。develop へ向けた PR)
# ------------------------------------------------------------------------------------------------
origin="${work}/origin.git"
repo="${work}/repo"
git init --quiet --bare -b main "${origin}"
git init --quiet -b main "${repo}"
git -C "${repo}" remote add origin "${origin}"
# このマシンの設定 (programs.git) と同じく日本語のパスをそのまま出す
git -C "${repo}" config core.quotepath false

# put <path> <中身> : repo にファイルを書く
put() {
  mkdir -p "$(dirname "${repo}/$1")"
  printf '%s\n' "$2" >"${repo}/$1"
}
commit() {
  git -C "${repo}" add -A
  git -C "${repo}" commit --quiet -m "$1"
}

put keep.txt keep-0
put 'old name.txt' old-name
put del.txt delete-me
put a.txt plain-a-0
put sub/dir/base.txt base
commit c1
c1=$(git -C "${repo}" rev-parse HEAD)

git -C "${repo}" switch --quiet -c develop
put dev-only.txt dev-only
commit d1
git -C "${repo}" switch --quiet -c stacked
put stacked.txt stacked
commit s1

git -C "${repo}" switch --quiet -c feat "${c1}"
put keep.txt keep-1
put 'new file.txt' new-file
put 'テスト.md' tesuto
put '[ab].txt' glob
put a.txt plain-a-1
put $'line\nbreak.txt' linebreak
put $'tab\tname.txt' tabname
git -C "${repo}" rm --quiet del.txt
mkdir -p "${repo}/renamed"
git -C "${repo}" mv 'old name.txt' 'renamed/new name.txt'
commit f1

git -C "${repo}" switch --quiet main
put main-only.txt main-only
commit c2

git -C "${repo}" push --quiet origin main develop 2>/dev/null
git -C "${repo}" remote set-head origin main >/dev/null
git -C "${repo}" switch --quiet feat

# run <dir> [<変数>=<値>...] -- <引数...> : <dir> で script を流す。stdout・stderr・exit code を
# ${work}/{out,err,rc} に残す。fzf の書き留めは毎回消す
run() {
  local dir=$1
  shift
  local -a vars=()
  while [[ $1 != -- ]]; do
    vars+=("$1")
    shift
  done
  shift
  rm -f "${log}/args" "${log}/input" "${log}/cwd"
  (
    cd "${dir}" || exit
    env PATH="${bin}:${PATH}" FAKE_FZF_LOG="${log}" FAKE_FZF_REAL="${real_fzf}" "${vars[@]}" \
      "${BASH}" "${invoke}" "$@"
  ) >"${work}/out" 2>"${work}/err"
  echo $? >"${work}/rc"
}
out() { cat "${work}/out"; }
err() { cat "${work}/err"; }
rc() { cat "${work}/rc"; }
# 出した差分に含まれるファイルの数
diffs() { grep -c '^diff --git' "${work}/out"; }
detail() { printf 'rc=%s\nstdout:\n%s\nstderr:\n%s' "$(rc)" "$(out)" "$(err)"; }

# fzf の引数に <opt> (かその短い形 <short>) があるか
fzf_has() {
  local -a args=()
  local a
  [[ -f ${log}/args ]] || return 1
  mapfile -d '' -t args <"${log}/args"
  for a in "${args[@]}"; do
    if [[ ${a} == "$1" || ${a} == "$1"=* || (-n ${2:-} && ${a} == "$2") ]]; then
      return 0
    fi
  done
  return 1
}
# fzf の引数のうち <opt> の値 (--opt <値> と --opt=<値> のどちらでも)
fzf_opt() {
  local -a args=()
  local i
  [[ -f ${log}/args ]] || return 1
  mapfile -d '' -t args <"${log}/args"
  for ((i = 0; i < ${#args[@]}; i++)); do
    case ${args[i]} in
      "$1") printf '%s' "${args[i + 1]:-}" && return 0 ;;
      "$1"=*) printf '%s' "${args[i]#"$1"=}" && return 0 ;;
    esac
  done
  return 1
}
# fzf の入力で、表示が <表示> の行の 1 列目 (タブ区切り)
fzf_field1() {
  local line
  [[ -f ${log}/input ]] || return 1
  while IFS= read -r -d '' line; do
    if [[ ${line#*$'\t'*$'\t'} == "$1" ]]; then
      printf '%s' "${line%%$'\t'*}"
      return 0
    fi
  done <"${log}/input"
  return 1
}
# プレビューを fzf と同じ形で走らせる: --with-shell (無ければ $SHELL -c) の shell に、{1} を
# '<値>' に置き換えたコマンドを渡す。cwd は fzf が動いていた場所
preview() {
  local cmd shell cwd q="'$1'"
  local -a words
  cmd=$(fzf_opt --preview) || return 1
  shell=$(fzf_opt --with-shell) || shell="${SHELL} -c"
  cwd=$(cat "${log}/cwd") || return 1
  read -r -a words <<<"${shell}"
  (cd "${cwd}" && "${words[@]}" "${cmd//\{1\}/${q}}")
}

echo "== pjp-pr-diff.sh"

# 1. PR が無い (gh が exit 1) → origin/HEAD (origin/main) と比べる。main が後から足した main-only.txt は
#    混ざらない (二点の比較なら消したファイルとして出る)。rename は新しいパスで並ぶ
expected=$(
  cat <<'EOF'
[ab].txt
a.txt
del.txt
keep.txt
"line\nbreak.txt"
new file.txt
renamed/new name.txt
"tab\tname.txt"
テスト.md
EOF
)
run "${repo}" -- --list
if [[ $(rc) == 0 && $(out) == "${expected}" && $(err) == *origin/main* && $(err) == *"${c1:0:7}"* ]]; then
  ok "PR が無ければ origin/HEAD との merge-base から HEAD までを並べる"
else
  ng "PR が無ければ origin/HEAD との merge-base から HEAD までを並べる" "$(detail)"
fi

# 2. develop へ向けた PR → gh が返す base (origin/develop) と比べる
git -C "${repo}" switch --quiet stacked
run "${repo}" FAKE_GH_PR="$(pr_json develop)" -- --list
if [[ $(rc) == 0 && $(out) == stacked.txt && $(err) == *origin/develop* && $(err) == *'#7'* ]]; then
  ok "PR があれば gh pr view の baseRefName (origin/<名前>) と比べる"
else
  ng "PR があれば gh pr view の baseRefName (origin/<名前>) と比べる" "$(detail)"
fi

# 3. 同じ branch でも PR が無ければ origin/HEAD と比べ、develop の変更も並ぶ
run "${repo}" -- --list
if [[ $(rc) == 0 && $(out) == $'dev-only.txt\nstacked.txt' ]]; then
  ok "gh が PR を返さなければ origin/HEAD に戻る"
else
  ng "gh が PR を返さなければ origin/HEAD に戻る" "$(detail)"
fi

# 4. --base は gh より優先する (gh は main を返すが、--base の origin/develop と比べる)
run "${repo}" FAKE_GH_PR="$(pr_json main)" -- --base origin/develop --list
if [[ $(rc) == 0 && $(out) == stacked.txt && $(err) == *origin/develop* ]]; then
  ok "--base を gh pr view より優先する"
else
  ng "--base を gh pr view より優先する" "$(detail)"
fi

# 5. PR の base が手元に無い → origin/HEAD へ黙って落ちずに止まる
run "${repo}" FAKE_GH_PR="$(pr_json gone)" -- --list
if [[ $(rc) == 1 && -z $(out) && $(err) == *gone* ]]; then
  ok "PR の base が origin に無ければ止まる"
else
  ng "PR の base が origin に無ければ止まる" "$(detail)"
fi

# 6. --base が commit を指さない → 止まる
run "${repo}" -- --base no-such-ref --list
if [[ $(rc) == 1 && -z $(out) && $(err) == *no-such-ref* ]]; then
  ok "--base が見つからなければ止まる"
else
  ng "--base が見つからなければ止まる" "$(detail)"
fi
git -C "${repo}" switch --quiet feat

# 7. --base も PR も origin/HEAD も無い → 止まる
git -C "${repo}" remote set-head origin --delete
run "${repo}" -- --list
if [[ $(rc) == 1 && -z $(out) && -n $(err) ]]; then
  ok "比べる相手が決まらなければ止まる"
else
  ng "比べる相手が決まらなければ止まる" "$(detail)"
fi
git -C "${repo}" remote set-head origin main >/dev/null

# 8. 1 つ選ぶ (サブディレクトリから) → そのファイルだけの差分
run "${repo}/sub/dir" FZF_DEFAULT_OPTS='--exact --filter=keep' --
if [[ $(rc) == 0 && $(diffs) == 1 && $(out) == *-keep-0* && $(out) == *+keep-1* ]]; then
  ok "1 つ選ぶと、そのファイルだけの差分を出す (サブディレクトリからでも)"
else
  ng "1 つ選ぶと、そのファイルだけの差分を出す (サブディレクトリからでも)" "$(detail)"
fi

# 9. 複数選ぶ → それらだけの差分。rename は rename として出る
run "${repo}" FZF_DEFAULT_OPTS='--exact --filter=new' --
if [[ $(rc) == 0 && $(diffs) == 2 && $(out) == *+new-file* && $(out) == *'rename from old name.txt'* && $(out) == *'rename to renamed/new name.txt'* ]]; then
  ok "複数選ぶと、それらだけの差分を出す (rename は rename として)"
else
  ng "複数選ぶと、それらだけの差分を出す (rename は rename として)" "$(detail)"
fi

# 10. glob の文字を含むパスは文字どおりに渡る ([ab].txt は a.txt に当たらない)
run "${repo}" FZF_DEFAULT_OPTS='--exact --filter=[ab]' --
if [[ $(rc) == 0 && $(diffs) == 1 && $(out) == *+glob* && $(out) != *plain-a* ]]; then
  ok "glob の文字を含むパスを文字どおりに渡す"
else
  ng "glob の文字を含むパスを文字どおりに渡す" "$(detail)"
fi

# 11-13. 改行・タブ・日本語を含むパス
for q in break:linebreak tab:tabname テスト:tesuto; do
  run "${repo}" FZF_DEFAULT_OPTS="--exact --filter=${q%%:*}" --
  if [[ $(rc) == 0 && $(diffs) == 1 && $(out) == *"+${q#*:}"* ]]; then
    ok "パスに「${q%%:*}」を含むファイルを選べる"
  else
    ng "パスに「${q%%:*}」を含むファイルを選べる" "$(detail)"
  fi
done

# 14. 何も選ばない (当たる行が無い・Esc) → 何も出さず、エラーも出さずに終わる (PR 全体の差分を出さない)
run "${repo}" FZF_DEFAULT_OPTS='--exact --filter=zzz' --
if [[ -e ${log}/args && $(rc) != 0 && -z $(out) && -z $(err) ]]; then
  ok "何も選ばなければ何も出さずに終わる"
else
  ng "何も選ばなければ何も出さずに終わる" "$(detail)"
fi

# 15. 検索は表示のパスだけに当たる。状態の文字 (D = 消した) では選ばれない
run "${repo}" FZF_DEFAULT_OPTS='--exact --filter=D' --
if [[ -e ${log}/args && $(rc) != 0 && -z $(out) ]]; then
  ok "状態の文字では選ばれない"
else
  ng "状態の文字では選ばれない" "$(detail)"
fi

# 16. 複数選べる fzf を開き、プレビューはその行のファイルの差分を色付きで出す。script を
#     サブディレクトリから相対パスで呼んでも、プレビューが script を見つけられる
invoke=$(realpath --relative-to="${repo}/sub/dir" "${script}")
run "${repo}/sub/dir" FZF_DEFAULT_OPTS='--exact --filter=keep' --
invoke=${script}
if fzf_has --multi -m; then
  ok "fzf を --multi で開く"
else
  ng "fzf を --multi で開く" "args=$(tr '\0' ' ' <"${log}/args" 2>&1)"
fi
idx_keep=$(fzf_field1 keep.txt)
idx_rename=$(fzf_field1 'old name.txt -> renamed/new name.txt')
p_keep=$(preview "${idx_keep}" 2>&1)
if [[ -n ${idx_keep} && ${p_keep} == *keep-1* && ${p_keep} == *$'\e['* && ${p_keep} != *new-file* ]]; then
  ok "プレビューは、その行のファイルの差分を色付きで出す (script を相対パスで呼んでも)"
else
  ng "プレビューは、その行のファイルの差分を色付きで出す (script を相対パスで呼んでも)" "idx=${idx_keep} preview=${p_keep}"
fi
p_rename=$(preview "${idx_rename}" 2>&1)
if [[ -n ${idx_rename} && ${p_rename} == *'rename from old name.txt'* ]]; then
  ok "rename の行のプレビューは rename として出る"
else
  ng "rename の行のプレビューは rename として出る" "idx=${idx_rename} preview=${p_rename}"
fi

# 17. 変更が無い (main は origin/main と同じ) → fzf を開かずに止まる。--list は空で成功
git -C "${repo}" switch --quiet main
run "${repo}" FZF_DEFAULT_OPTS='--exact --filter=x' --
if [[ $(rc) == 1 && -z $(out) && ! -e ${log}/args && -n $(err) ]]; then
  ok "変更が無ければ fzf を開かずに止まる"
else
  ng "変更が無ければ fzf を開かずに止まる" "$(detail)"
fi
run "${repo}" -- --list
if [[ $(rc) == 0 && -z $(out) ]]; then
  ok "変更が無ければ --list は何も並べずに成功する"
else
  ng "変更が無ければ --list は何も並べずに成功する" "$(detail)"
fi
git -C "${repo}" switch --quiet feat

# 18. 知らない引数・値の無い --base → exit 2
run "${repo}" -- --bogus
rc_bogus=$(rc)
run "${repo}" -- --base
if [[ ${rc_bogus} == 2 && $(rc) == 2 ]]; then
  ok "知らない引数と値の無い --base は exit 2"
else
  ng "知らない引数と値の無い --base は exit 2" "--bogus: rc=${rc_bogus} / --base: $(detail)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
