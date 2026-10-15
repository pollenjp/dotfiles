#!/usr/bin/env bash
# shellcheck shell=bash
#
# PR 全体の差分から変更ファイルを fzf で選び、選んだファイルだけの git diff を出す (TKT-41)。
#
#   pjp-pr-diff                選んで出す。Tab で複数選べ、選んでいる間は行の差分をプレビューに出す
#   pjp-pr-diff --base <ref>   比べる相手を <ref> にする (gh で PR を引かない)
#   pjp-pr-diff --list         選ばずに変更ファイルを並べる (gh pr diff --name-only と比べられる)
#
# ## 比べる範囲
#
# merge-base(<base>, HEAD) から HEAD まで (= <base>...HEAD)。GitHub の PR の Files changed と同じ
# 三点の比較で、<base> 側が後から進めた変更は混ざらない。作業ツリーの未コミットの変更は含めない。
# <base> は上から順に決める:
#
#   1. --base <ref>
#   2. gh pr view が返す、この branch の PR の baseRefName (origin/<名前>)。main 以外へ向けた PR
#      (積み重ねた PR) でも、その PR の差分になる
#   3. origin/HEAD (PR が無い・gh が無い・ログインしていないとき)
#
# PR の base が手元に無い (fetch していない) ときは 3 へ落とさずに止まる。別の base と比べると、
# PR に無いファイルまで並ぶため。2 の remote はいつも origin と読む。fork から upstream へ出した
# PR では、--base upstream/<名前> で指定する。2 で GitHub にある PR の head が HEAD と違えば
# (push していない・pull していない commit がある)、比べるのは手元の HEAD のまま、そのことを
# fzf のヘッダ (--list では stderr) に出す。
#
# ## fzf に渡す行
#
# 1 行は「番号 TAB 状態 TAB パス」(rename と copy は「元 -> 先」) で、番号は隠す。プレビューと
# 選んだ後は、パスではなく番号から git diff --name-status -z の結果を引き直す。パスを fzf の欄で
# 渡すと、タブや改行を含む名前で壊れるため。git にはパスを --literal-pathspecs で渡す
# ([ab].txt が a.txt に当たらない)。rename は元と先の両方を渡すと、git が rename として出す。
#
# プレビューは fzf から script 自身を __preview <merge-base> <HEAD> <番号> で呼ぶ。fzf は既定で
# $SHELL (fish のことがある) でコマンドを走らせるので、--with-shell で bash に固定する。
#
# nix/pkgs/pjp-pr-diff/default.nix が writeShellApplication で PATH に置く。単体でも
# bash pjp-pr-diff.sh で動く (nix/tests/pjp-pr-diff.test.sh がそうして流す)。

set -euo pipefail

prog=pjp-pr-diff

usage() {
  cat <<'EOS'
PR 全体の差分から変更ファイルを選び、選んだファイルだけの git diff を出す。

使い方:
  pjp-pr-diff [--base <ref>]          fzf で選ぶ (Tab で複数選ぶ / Enter で出す / Esc でやめる)
  pjp-pr-diff [--base <ref>] --list   選ばずに変更ファイルを並べる

  -b, --base <ref>   比べる相手。省くと、この branch の PR の base (gh pr view)、無ければ origin/HEAD
  -l, --list         変更ファイルを並べるだけにする (gh pr diff --name-only と比べられる)
  -h, --help         この使い方を出す

比べる範囲は merge-base(<base>, HEAD) から HEAD まで (GitHub の PR の Files changed と同じ)。
作業ツリーの未コミットの変更は含めない。
EOS
}

die() {
  printf '%s: %s\n' "${prog}" "$*" >&2
  exit 1
}

# プレビューから呼ばれたときも、パスは repo の root から数える (git diff の出すパスと揃える)
cd_top() {
  local top
  top=$(git rev-parse --show-toplevel)
  cd "${top}"
}

# collect <merge-base> <HEAD> : 変更ファイルを配列 st (状態の 1 文字)・src (パス。rename と copy は元)・
# dst (rename と copy の先。それ以外は空) に読む
collect() {
  local -a f=()
  local i=0
  st=() src=() dst=()
  mapfile -d '' -t f < <(git diff --name-status -z -M "$1" "$2")
  wait "$!" || die "git diff --name-status が失敗しました。"
  while ((i < ${#f[@]})); do
    st+=("${f[i]:0:1}")
    src+=("${f[i + 1]}")
    case ${f[i]} in
      R* | C*)
        dst+=("${f[i + 2]}")
        i=$((i + 3))
        ;;
      *)
        dst+=('')
        i=$((i + 2))
        ;;
    esac
  done
}

# pathspecs <番号...> : その変更を git diff に渡すパスを配列 paths に並べる
pathspecs() {
  local n
  paths=()
  for n in "$@"; do
    if [[ ! ${n} =~ ^[0-9]+$ ]] || ((10#${n} >= ${#st[@]})); then
      die "変更ファイルの番号が範囲の外です: ${n}"
    fi
    n=$((10#${n}))
    paths+=("${src[n]}")
    if [[ -n ${dst[n]} ]]; then
      paths+=("${dst[n]}")
    fi
  done
}

if [[ ${1:-} == __preview ]]; then
  (($# == 4)) || die "__preview には <merge-base> <HEAD> <番号> を渡します。"
  cd_top
  collect "$2" "$3"
  pathspecs "$4"
  exec git --no-pager --literal-pathspecs diff --color=always -M "$2" "$3" -- "${paths[@]}"
fi

base='' list=0
while (($#)); do
  case $1 in
    -b | --base)
      if [[ $# -lt 2 || -z $2 ]]; then
        printf '%s: %s には比べる相手の ref が要ります。\n' "${prog}" "$1" >&2
        usage >&2
        exit 2
      fi
      base=$2
      shift 2
      ;;
    --base=?*)
      base=${1#--base=}
      shift
      ;;
    -l | --list)
      list=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf '%s: 不明な引数です: %s\n' "${prog}" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# プレビューで script 自身を呼ぶので、root へ移る前に絶対パスにしておく
case $0 in
  /*) self=$0 ;;
  *) self=${PWD}/$0 ;;
esac
cd_top

head=$(git rev-parse --verify --quiet 'HEAD^{commit}') || die "HEAD がまだ commit を指していません。"

# 比べる相手 (base_ref) と、それに決めた理由 (base_why)。PR の head (GitHub にある commit) が HEAD と
# 違えば、比べるのは手元の HEAD のまま知らせる (push していない・pull していない commit があると、
# GitHub の Files changed とずれる)
if [[ -n ${base} ]]; then
  base_ref=${base} base_why='--base で指定'
elif pr=$(gh pr view --json number,baseRefName,headRefOid --jq '"\(.number)\t\(.baseRefName)\t\(.headRefOid)"' 2>/dev/null) && [[ -n ${pr} ]]; then
  IFS=$'\t' read -r number name pr_head <<<"${pr}"
  if ! git rev-parse --verify --quiet "refs/remotes/origin/${name}" >/dev/null; then
    die "PR #${number} の base (${name}) が origin にありません。git fetch origin ${name} を打つか、--base で指定してください。"
  fi
  base_ref=origin/${name} base_why="PR #${number} の base"
  if [[ ${pr_head} != "${head}" ]]; then
    base_why+="。HEAD は PR の head (${pr_head:0:7}) と違う"
  fi
elif base_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD); then
  base_why='origin/HEAD。gh でこの branch の PR を引けなかった'
else
  die "比べる相手が決まりません。--base <ref> で指定するか、git remote set-head origin --auto を打ってください。"
fi

base_commit=$(git rev-parse --verify --quiet "${base_ref}^{commit}") || die "${base_ref} が見つかりません。"
mb=$(git merge-base "${base_commit}" "${head}") || die "${base_ref} と HEAD に共通の祖先がありません。"
collect "${mb}" "${head}"
range="${base_ref}...HEAD (${base_why})  merge-base $(git rev-parse --short "${mb}")  ${#st[@]} ファイル"

if ((list)); then
  printf '%s\n' "${range}" >&2
  exec git diff --name-only -M "${mb}" "${head}"
fi

if ((${#st[@]} == 0)); then
  die "変更されたファイルがありません: ${range}"
fi

items() {
  local i
  for i in "${!st[@]}"; do
    if [[ -n ${dst[i]} ]]; then
      printf '%s\t%s\t%s -> %s\0' "${i}" "${st[i]}" "${src[i]}" "${dst[i]}"
    else
      printf '%s\t%s\t%s\0' "${i}" "${st[i]}" "${src[i]}"
    fi
  done
}

# 選んだ行の番号 (1 列目) だけを受け取る (--accept-nth 1)。Esc や当たる行が無いときは fzf の
# 終了コードのまま終える (選んでいないのに PR 全体の差分を出さない)。
#
# 一覧は上から並べる (--layout=reverse)。既定の下から上の並びでは、カーソルが最初にいる一番下の
# 行で Tab (選んで下へ) を押しても動けず、同じ行を選んで外すだけになる。fzf.fish の一覧と同じく
# --cycle も付け、端で反対の端へ回る
chosen=$(
  fzf --multi --layout=reverse --cycle --read0 --accept-nth 1 \
    --delimiter '\t' --with-nth '2..' --nth '2..' \
    --with-shell "${BASH} -c" \
    --preview "$(printf '%q ' "${BASH}" "${self}" __preview "${mb}" "${head}"){1}" \
    --preview-window 'right,60%,<100(down,60%)' \
    --prompt 'files> ' \
    --header "${range}"$'\n''Tab: 選ぶ / Enter: 差分を出す / Esc: やめる' \
    < <(items)
) || exit
mapfile -t picked <<<"${chosen}"
pathspecs "${picked[@]}"
exec git --literal-pathspecs diff -M "${mb}" "${head}" -- "${paths[@]}"
