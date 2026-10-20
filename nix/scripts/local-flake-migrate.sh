#!/usr/bin/env bash
# shellcheck shell=bash
#
# 旧いローカル flake (~/dotfiles/flake.nix) を、値を引き継いで今の雛形 (setup-local-flake.sh が書く形) へ移す。
#
# ## なぜ要るのか
#
# ~/dotfiles/flake.nix は setup-local-flake.sh が heredoc の雛形から 1 度だけ作る、git 管理外のファイル。
# 雛形が新しくなっても既にあるファイルは古い形のまま残り、--force で作り直すと local に書いた値と手で足した
# ホストが消える。この script は、旧いファイルを作った元の雛形・今の雛形・旧いファイルの 3 つで 3-way merge し、
# 旧い flake と移した flake を評価して値を引き継げたことを確かめてから書く。
#
# ## 雛形の版の描き出し
#
# 雛形の各版は、git の履歴の setup-local-flake.sh から heredoc の原文 (開きの行
# `  cat >"${flake_file}" <<EOS` の次の行から EOS の前の行まで) を抜き、bash の heredoc の展開を真似て描く。
# 古い版の script は実行しない (古い版は DOTFILES_LOCAL_DIR を知らず、~/dotfiles に書きうる)。真似るのは
# ${nix_dir}・${private_nix_dir}・${template_id} の置き換えと、\$ \` \\ を 1 文字にすることだけで、ほかの展開があれば
# 描かずに止まる。
#
# ## dotfiles-private の入力
#
# 今の雛形は、dotfiles-private の clone の nix/ (無ければ本体の空の stub) を path: の入力に取る (${private_nix_dir}。
# ADR 025)。どこを指すかは private-host.sh input-dir が決める。印が同じでも、入力がそこと違えば (stub のまま clone に
# nix/ ができた、など) status は 1 にし、prepare はその行を指し直す。元の雛形は旧いファイルの入力の値で、今の雛形は
# input-dir で描くので、3-way merge がその行だけを今の値にする。
#
# ## 雛形の版の印
#
# 雛形の先頭のコメントに「# 雛形の版: <8 桁の 16 進>」を置く。値は heredoc の原文 (展開する前) の POSIX cksum の
# CRC で、マシンに依らず、印の行は原文では ${template_id} のままなので自分自身を含んでも循環しない。heredoc の外を
# 直しても変わらない。setup-local-flake.sh は書くときに id で計算して入れ、setup-local-flake.sh と setup.sh は
# check で照合する。id と check は bash・awk・cksum だけで動く (setup は Nix を入れた直後、jq も git も無い段階でも
# 走る)。
#
# 詳しくは nix/README.md「雛形が新しくなったら」と ADR 024。手順を Claude Code に任せるなら
# pjp-dotfiles-local-flake-migrate skill。

set -eu -o pipefail

usage() {
  cat <<'EOS'
旧いローカル flake (~/dotfiles/flake.nix) を、値を引き継いで今の雛形へ移す。

使い方:
  local-flake-migrate.sh status [--flake <dir>]
      ローカル flake の雛形の版の印が、今の雛形と同じかを出す (同じなら 0、違う・印が無いなら 1)。印が同じでも
      dotfiles-private の入力が private-host.sh input-dir と違えば 1
  local-flake-migrate.sh check [--flake <dir>]
      status の静かな版 (setup が使う)。同じなら何も出さず 0、違えば「旧い印 → 今の印」を出して 1。
      調べられなければ 2。git も nix も使わない
  local-flake-migrate.sh prepare [--flake <dir>] [--out <dir>] [--base <rev>] [--always]
      作業場所 (--out。在るなら空であること。省けば mktemp -d) に、旧い flake の写し・元の雛形・
      今の雛形と、3-way merge で移した new/flake.nix を作る。元の雛形は印の版か、無ければ履歴で
      旧いファイルとの差分が最も小さい版。--base でこの repo の commit を選び直せる。移すものが無ければ
      作業場所を作らないが、--always なら作る (new/flake.nix は旧いファイルと同じ。local を直して
      compare・apply するため。dotfiles-private に登録したあとの仕上げなど)
  local-flake-migrate.sh compare <作業場所> [--baseline <dir>]
      旧い flake (--baseline を渡せばそのディレクトリの flake.nix) と new/flake.nix を同じ本体・同じ lock で
      評価し、全ホストの drvPath と、setup が拾うホストの並びを比べる。0 = 同じ、1 = 違う、
      3 = 基準が今の本体で評価できない、4 = new/flake.nix が評価できない
  local-flake-migrate.sh apply <作業場所> [--accept-changes]
      compare を今の中身で流したことを確かめ、flake.nix.bak-<日時> (と flake.lock.bak-<日時>) に
      退避してから new/flake.nix を書く。compare が同じでない・--baseline で比べたなら --accept-changes が要る
  local-flake-migrate.sh id [<setup-local-flake.sh のパス> | -]
      雛形の版の印 (8 桁の 16 進) を出す。省けばこの repo の setup-local-flake.sh、- なら stdin
  local-flake-migrate.sh render (--rev <rev> | --file <パス>) --nix-dir <パス> [--private-dir <パス>]
      雛形の 1 版を描いて stdout に出す (--rev はこの repo の git の commit)。dotfiles-private の入力
      (${private_nix_dir}) は --private-dir で描き、省けば private-host.sh input-dir --nix-dir <パス>
  local-flake-migrate.sh -h, --help
      これ

  --flake の既定は ${DOTFILES_LOCAL_DIR:-~/dotfiles}。雛形の履歴と今の雛形は、この script が置かれた
  repo の nix/scripts/setup-local-flake.sh から取る (今の雛形は作業ツリーのファイル)。
EOS
}

die() {
  printf '!! %s\n' "$*" >&2
  exit 2
}

# $0 が symlink 経由でも実体の場所を返す (setup-local-flake.sh と同じ。macOS の readlink には -f が無い)。
resolve_dir() {
  local src=$1 dir
  while [[ -L ${src} ]]; do
    dir=$(
      cd -P -- "$(dirname -- "${src}")" &>/dev/null
      pwd
    )
    src=$(readlink -- "${src}")
    case ${src} in
      /*) ;;
      *) src="${dir}/${src}" ;;
    esac
  done
  cd -P -- "$(dirname -- "${src}")" &>/dev/null
  pwd
}

script_dir=$(resolve_dir "$0")
repo_dir=$(dirname "$(dirname "${script_dir}")")
template_rel=nix/scripts/setup-local-flake.sh
self="${script_dir}/local-flake-migrate.sh"
default_flake_dir=${DOTFILES_LOCAL_DIR:-${HOME}/dotfiles}

# 一時ファイルの置き場は使うときに作る (check は mktemp も要らない)。$(...) の中から初めて呼ぶと、作った場所が
# 親に伝わらず消えずに残るので、使うコマンドの頭で (親のシェルで) 呼ぶ
tmp=""
trap '[[ -z ${tmp} ]] || rm -rf "${tmp}"' EXIT
need_tmp() {
  [[ -n ${tmp} ]] || tmp=$(mktemp -d "${TMPDIR:-/tmp}/local-flake-migrate.XXXXXX")
}

# heredoc の原文を出す。$1: setup-local-flake.sh のパス。開きの行がちょうど 1 つで、閉じの EOS もあるときだけ 0
template_raw() {
  awk '
    $0 == "  cat >\"${flake_file}\" <<EOS" { n++; if (n == 1) f = 1; next }
    f && $0 == "EOS" { f = 0; closed = 1; next }
    f { print }
    END { if (n != 1 || !closed) exit 1 }
  ' "$1"
}

# 雛形の版の印を出す。$1: setup-local-flake.sh のパス
template_id() {
  local sum
  sum=$(template_raw "$1" | cksum) || return 1
  printf '%08x\n' "${sum%% *}"
}

# 雛形の 1 版を描く。$1: setup-local-flake.sh のパス、$2: ${nix_dir} に入れるパス、$3: ${private_nix_dir} に入れる
# パス (dotfiles-private の入力。その展開の無い版では使わない)。
# 引用しない heredoc の展開を真似る。描けない展開があれば、何も出さずに理由を stderr に出して 1
template_render() {
  local id
  id=$(template_id "$1") || return 1
  template_raw "$1" | NIX_DIR=$2 PRIVATE_NIX_DIR=${3:-} TEMPLATE_ID=${id} awk '
    function bad(why) {
      printf "!! 雛形に描けない展開があります (原文の %d 行目の %s): %s\n", NR, why, $0 > "/dev/stderr"
      failed = 1
      exit 1
    }
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\\") {
          if (i == n) bad("行末の \\")
          nx = substr(line, i + 1, 1)
          if (nx == "$" || nx == "`" || nx == "\\") { out = out nx; i += 2; continue }
          out = out c; i++; continue
        }
        if (c == "`") bad("`")
        if (c == "$") {
          if (substr(line, i, 10) == "${nix_dir}") { out = out ENVIRON["NIX_DIR"]; i += 10; continue }
          if (substr(line, i, 18) == "${private_nix_dir}") {
            if (ENVIRON["PRIVATE_NIX_DIR"] == "") bad("${private_nix_dir} に入れるパスが無い")
            out = out ENVIRON["PRIVATE_NIX_DIR"]; i += 18; continue
          }
          if (substr(line, i, 14) == "${template_id}") { out = out ENVIRON["TEMPLATE_ID"]; i += 14; continue }
          nx = substr(line, i + 1, 1)
          if (nx ~ /[[A-Za-z0-9_{(@*#?$!-]/) bad("$" nx)
        }
        out = out c; i++
      }
      lines[NR] = out
    }
    END {
      if (failed) exit 1
      for (k = 1; k <= NR; k++) print lines[k]
    }
  '
}

# render / id に渡す script を 1 つのファイルにする。$1: パスか -。出すのはファイルのパス
script_file() {
  if [[ $1 == - ]]; then
    need_tmp
    cat >"${tmp}/stdin.sh"
    printf '%s\n' "${tmp}/stdin.sh"
  else
    [[ -f $1 ]] || die "ファイルがありません: $1"
    printf '%s\n' "$1"
  fi
}

# この repo の、ある commit の setup-local-flake.sh をファイルに写して、そのパスを出す
rev_file() {
  local f
  need_tmp
  f="${tmp}/rev-${1//\//_}.sh"
  git -C "${repo_dir}" show "$1:${template_rel}" >"${f}" 2>/dev/null \
    || die "この repo (${repo_dir}) の $1 に ${template_rel} がありません。"
  printf '%s\n' "${f}"
}

# flake.nix の「雛形の版」の印 (8 桁の 16 進) を出す。無ければ何も出さない
local_marker() {
  awk '
    /^# 雛形の版: [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]([^0-9a-f]|$)/ {
      sub(/^# 雛形の版: /, "")
      print substr($0, 1, 8)
      exit
    }
  ' "$1"
}

# flake.nix の inputs.dotfiles.url の path: のパスを出す (setup-local-flake.sh が書き、setup.sh の
# sync_local_flake_lock が読む形)。無ければ何も出さない
local_nix_dir() {
  awk '
    match($0, /^[[:space:]]*inputs\.dotfiles\.url[[:space:]]*=[[:space:]]*"path:[^"]*"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^[^"]*"path:/, "", s)
      sub(/"$/, "", s)
      print s
      exit
    }
  ' "$1"
}

# flake.nix の dotfiles-private の入力 (inputs.dotfiles-private.url の path:) のパスを出す。無ければ何も出さない
local_private_dir() {
  awk '
    match($0, /^[[:space:]]*inputs\.dotfiles-private\.url[[:space:]]*=[[:space:]]*"path:[^"]*"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^[^"]*"path:/, "", s)
      sub(/"$/, "", s)
      print s
      exit
    }
  ' "$1"
}

# 今の雛形が dotfiles-private の入力に書く場所 (private-host.sh input-dir。clone の nix/ が無ければ本体の stub)。
# $1: 本体の nix (雛形の ${nix_dir})。private-host.sh が無ければ <本体の nix>/private-stub
want_private_dir() {
  local p=""
  if [[ -f ${script_dir}/private-host.sh ]]; then
    p=$("${BASH}" "${script_dir}/private-host.sh" input-dir --nix-dir "$1" 2>/dev/null) || p=""
  fi
  printf '%s\n' "${p:-$1/private-stub}"
}

# 雛形 ($1: setup-local-flake.sh のパス) が dotfiles-private の入力 (${private_nix_dir}) を持つか
template_has_private() {
  local raw
  raw=$(template_raw "$1") || return 1
  # shellcheck disable=SC2016 # 展開ではなく、原文の ${private_nix_dir} の文字を探す
  [[ ${raw} == *'${private_nix_dir}'* ]]
}

# --flake を読む。flake_dir と flake (その flake.nix) を決め、ローカル flake でなければ 2 で止まる
# (quiet なら何も出さない)。$1: quiet か loud、残り: 引数
parse_flake_args() {
  local mode=$1
  shift
  flake_dir=${default_flake_dir}
  while [[ $# -gt 0 ]]; do
    case $1 in
      --flake)
        [[ $# -ge 2 ]] || die "--flake にディレクトリを渡してください"
        flake_dir=$2
        shift
        ;;
      --out)
        [[ $# -ge 2 ]] || die "--out にディレクトリを渡してください"
        out_dir=$2
        shift
        ;;
      --base)
        [[ $# -ge 2 ]] || die "--base に commit を渡してください"
        base_given=$2
        shift
        ;;
      --always) always=1 ;;
      *) die "知らない引数です: $1 (--help)" ;;
    esac
    shift
  done
  flake="${flake_dir}/flake.nix"
  if [[ ! -f ${flake} ]]; then
    [[ ${mode} == quiet ]] || printf '!! ローカル flake がありません: %s\n' "${flake}" >&2
    exit 2
  fi
  # 絶対パスにする (prepare.env に書き、apply はどこから流しても同じ所に書く)
  flake_dir=$(cd -P -- "${flake_dir}" && pwd)
  flake="${flake_dir}/flake.nix"
  local_nix=$(local_nix_dir "${flake}")
  if [[ -z ${local_nix} ]]; then
    [[ ${mode} == quiet ]] \
      || printf '!! %s に inputs.dotfiles.url = "path:…" がありません (setup-local-flake.sh が作ったローカル flake ではない)。\n' "${flake}" >&2
    exit 2
  fi
}

# この repo が git の作業ツリーで、雛形の履歴を引けることを確かめる
need_history() {
  git -C "${repo_dir}" rev-parse --git-dir &>/dev/null \
    || die "この repo (${repo_dir}) は git の作業ツリーではないので、雛形の履歴を引けません。"
}

# 2 つのファイルの diff の行数 (< と > の行) を出す
diff_lines() {
  local rc=0
  diff "$1" "$2" >"${tmp}/diff" || rc=$?
  [[ ${rc} -le 1 ]] || die "diff に失敗しました: $1 $2"
  grep -c '^[<>]' "${tmp}/diff" || true
}

# 元の雛形を決める。$1: 旧い flake.nix、$2: ${nix_dir} に入れるパス、$3: 旧いファイルの印 (無ければ空)、
# $4: ${private_nix_dir} に入れるパス (旧いファイルの dotfiles-private の入力。無ければ今の雛形が書く場所)。
#
# 履歴の各版 (作業ツリーに commit していない変更があればそれ → 新しい commit から古い commit の順) を描いて
# ${tmp}/cand/<n>.nix に置き、一覧を ${tmp}/candidates.tsv (版・日付・印・差分の行数・題) に書く。決めた版を
#   base_rev    版 (commit の短い名前か「作業ツリー」)
#   base_label  版・日付・題
#   base_file   描いた雛形
#   base_id     その版の印
#   base_how    marker (印と同じ版) か nearest (旧いファイルとの差分が最小の版。同数なら新しい方)
#   base_lines  旧いファイルとの差分の行数
# に入れる。印があるのに同じ版が無ければ marker_missing=1。描ける版が 1 つも無ければ 1
find_base() {
  local old=$1 nix_dir=$2 marker=$3 private=$4 n=0 rev date subject f id lines label why
  local best_n="" best_lines="" best_rev="" best_label="" best_id="" mark_n="" mark_rev="" mark_label="" mark_id="" mark_lines=""
  need_tmp
  mkdir -p "${tmp}/cand"
  : >"${tmp}/candidates.tsv"
  marker_missing=0
  while IFS=$'\t' read -r rev date subject; do
    n=$((n + 1))
    f="${tmp}/cand/${n}.sh"
    if [[ ${rev} == 作業ツリー ]]; then
      cp "${repo_dir}/${template_rel}" "${f}"
    else
      git -C "${repo_dir}" show "${rev}:${template_rel}" >"${f}" 2>/dev/null || continue
    fi
    label="${rev} ${date} ${subject}"
    : >"${tmp}/render.err"
    if ! id=$(template_id "${f}" 2>/dev/null) || ! template_render "${f}" "${nix_dir}" "${private}" >"${tmp}/cand/${n}.nix" 2>"${tmp}/render.err"; then
      why=$(awk 'NR == 1 { sub(/^!! /, ""); print }' "${tmp}/render.err")
      printf '%s\t%s\t%s\t%s\t%s\n' "${rev}" "${date}" "-" "描けない" "${subject} (${why:-雛形の heredoc が見つからない})" >>"${tmp}/candidates.tsv"
      continue
    fi
    # find_base は呼び出し側の || の中で動くので set -e が効かない。比べられなかった版は飛ばす
    if ! lines=$(diff_lines "${old}" "${tmp}/cand/${n}.nix") || [[ ! ${lines} =~ ^[0-9]+$ ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "${rev}" "${date}" "${id}" "比べられない" "${subject}" >>"${tmp}/candidates.tsv"
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${rev}" "${date}" "${id}" "${lines}" "${subject}" >>"${tmp}/candidates.tsv"
    if [[ -n ${marker} && -z ${mark_n} && ${id} == "${marker}" ]]; then
      mark_n=${n} mark_rev=${rev} mark_label=${label} mark_id=${id} mark_lines=${lines}
    fi
    if [[ -z ${best_n} ]] || ((lines < best_lines)); then
      best_n=${n} best_lines=${lines} best_rev=${rev} best_label=${label} best_id=${id}
    fi
  done < <(
    if ! git -C "${repo_dir}" diff --quiet HEAD -- "${template_rel}" 2>/dev/null; then
      printf '作業ツリー\t-\t(commit していない変更)\n'
    fi
    git -C "${repo_dir}" log --format='%h%x09%cs%x09%s' -- "${template_rel}"
  )
  if [[ -n ${mark_n} ]]; then
    base_rev=${mark_rev} base_label=${mark_label} base_id=${mark_id} base_how=marker base_lines=${mark_lines}
    base_file="${tmp}/cand/${mark_n}.nix"
    return 0
  fi
  [[ -n ${best_n} ]] || return 1
  [[ -z ${marker} ]] || marker_missing=1
  base_rev=${best_rev} base_label=${best_label} base_id=${best_id} base_how=nearest base_lines=${best_lines}
  base_file="${tmp}/cand/${best_n}.nix"
}

# 差分の行数が小さい順に、候補を 3 つまで「版 (n 行・印 <印>)」で並べる (印が同じ版は雛形の中身が同じ)
nearest_candidates() {
  awk -F'\t' '$4 ~ /^[0-9]+$/ { print $4 "\t" NR "\t" $1 "\t" $3 }' "${tmp}/candidates.tsv" \
    | sort -t$'\t' -k1,1n -k2,2n \
    | awk -F'\t' 'NR <= 3 { printf "%s%s (%s 行・印 %s)", (NR > 1 ? " / " : ""), $3, $1, $4 } END { print "" }'
}

# git merge-file --diff3 の出力のうち、片側が元の行の前後に足しただけの衝突を解く。$1: merge の出力、
# $2: 数を書くファイル (resolved=・remaining=・resolved_lines=・remaining_lines=。行番号は出力の行)。
# 解いた結果を stdout に出す。解く形 (B は元の行、空でない):
#   今 = B + X、手元は B で始まらず B で終わらない     → 手元 + X
#   今 = X + B、手元は同じ                           → X + 手元
#   手元 = B + Y・Y + B、今は B で始まらず B で終わらない → 今 + Y・Y + 今
# 両側が B に足した・B の前後のどちらにも当たる・B が空、などは決めずに印のまま残す
resolve_conflicts() {
  STATS=$2 awk '
    function emit(s) { print s; outn++ }
    function has_prefix(a, na,   i) {
      if (nb == 0 || na <= nb) return 0
      for (i = 1; i <= nb; i++) if (a[i] != b[i]) return 0
      return 1
    }
    function has_suffix(a, na,   i) {
      if (nb == 0 || na <= nb) return 0
      for (i = 1; i <= nb; i++) if (a[na - nb + i] != b[i]) return 0
      return 1
    }
    function touches(a, na,   i) {
      # a が B で始まるか B で終わるか (B と同じ長さでも)
      if (nb == 0 || na < nb) return 0
      for (i = 1; i <= nb; i++) if (a[i] != b[i]) break
      if (i > nb) return 1
      for (i = 1; i <= nb; i++) if (a[na - nb + i] != b[i]) return 0
      return 1
    }
    function finish(   i, start, how, tp, ts, op, os) {
      tp = has_prefix(t, nt); ts = has_suffix(t, nt); op = has_prefix(o, no); os = has_suffix(o, no)
      how = ""
      if (tp != ts && !touches(o, no)) how = tp ? "t_after" : "t_before"
      else if (op != os && !touches(t, nt)) how = op ? "o_after" : "o_before"
      start = outn + 1
      if (how == "t_after") { for (i = 1; i <= no; i++) emit(o[i]); for (i = nb + 1; i <= nt; i++) emit(t[i]) }
      else if (how == "t_before") { for (i = 1; i <= nt - nb; i++) emit(t[i]); for (i = 1; i <= no; i++) emit(o[i]) }
      else if (how == "o_after") { for (i = 1; i <= nt; i++) emit(t[i]); for (i = nb + 1; i <= no; i++) emit(o[i]) }
      else if (how == "o_before") { for (i = 1; i <= no - nb; i++) emit(o[i]); for (i = 1; i <= nt; i++) emit(t[i]) }
      else {
        emit(m_open)
        for (i = 1; i <= no; i++) emit(o[i])
        emit(m_base)
        for (i = 1; i <= nb; i++) emit(b[i])
        emit(m_sep)
        for (i = 1; i <= nt; i++) emit(t[i])
        emit(m_close)
        remaining++
        remaining_lines = remaining_lines (remaining_lines == "" ? "" : " ") start
        return
      }
      resolved++
      resolved_lines = resolved_lines (resolved_lines == "" ? "" : " ") (outn >= start ? start "-" outn : start)
    }
    st == 0 && /^<<<<<<< / { st = 1; m_open = $0; no = 0; nb = 0; nt = 0; next }
    st == 1 && /^\|\|\|\|\|\|\| / { st = 2; m_base = $0; next }
    st == 2 && /^=======$/ { st = 3; m_sep = $0; next }
    st == 3 && /^>>>>>>> / { m_close = $0; finish(); st = 0; next }
    st == 1 { o[++no] = $0; next }
    st == 2 { b[++nb] = $0; next }
    st == 3 { t[++nt] = $0; next }
    { emit($0) }
    END {
      printf "resolved=%d\nremaining=%d\nresolved_lines=%s\nremaining_lines=%s\n", resolved, remaining, resolved_lines, remaining_lines > ENVIRON["STATS"]
    }
  ' "$1"
}

# key=value の行のファイルから値を読む (eval しない。値は最初の = より後ろ全部)。$1: ファイル、$2: 名前
env_get() {
  local line
  while IFS= read -r line; do
    if [[ ${line%%=*} == "$2" ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <"$1"
  return 1
}

# ファイルの diff3 の衝突の印の行番号を、空白で区切って出す (無ければ何も出さない)
conflict_lines() {
  awk '/^(<<<<<<< |\|\|\|\|\|\|\| |>>>>>>> )/ || /^=======$/ { printf "%s%d", (n++ ? " " : ""), NR } END { if (n) print "" }' "$1"
}

# setup.sh がローカル flake の文字列から拾うホストを、上から順に空白で区切って出す。setup.sh の parse_hosts と
# local_flake_hosts と同じ形 (行頭が # の行は拾わない・sandbox を除く・重複は最初だけ)。一番上が setup の既定の
# 対象ホストになる
setup_hosts() {
  sed -n \
    -e 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*=[[:space:]]*[A-Za-z0-9_.]*mkHome.*/\1/p' \
    -e 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_-]*\)[[:space:]]*=[[:space:]]*[A-Za-z0-9_.]*mkHome.*/\1/p' \
    "$1" | awk '$0 != "sandbox" && !seen[$0]++ { printf "%s%s", (n++ ? " " : ""), $0 } END { print "" }'
}

# 全ホストの drvPath と警告を 1 行ずつ「drv<TAB>ホスト<TAB>drvPath」「warn<TAB>ホスト<TAB>警告」で出す式
# (警告の改行は \n、タブは空白にする)。ホストごとに tryEval で包み、評価が落ちるホストは「fail<TAB>ホスト」に
# する (module の評価の誤りは throw なので拾える。1 ホストが落ちても、ほかのホストは比べられる)。
# 検証専用の sandbox は比べない (setup も対象にしない。登録簿が持つ値と local がぶつかって落ちることがある)
# shellcheck disable=SC2016 # Nix の式をそのまま書く
summary_expr='hs: builtins.concatStringsSep "" (builtins.concatLists (map (n:
  let
    h = builtins.getAttr n hs;
    d = builtins.tryEval h.activationPackage.drvPath;
    w = builtins.tryEval (builtins.deepSeq h.config.warnings h.config.warnings);
  in
  if d.success then
    [ ("drv\t" + n + "\t" + d.value + "\n") ]
    ++ (if w.success then map (x: "warn\t" + n + "\t" + builtins.replaceStrings [ "\n" "\t" ] [ "\\n" " " ] x + "\n") w.value else [ ])
  else [ ("fail\t" + n + "\n") ]
) (builtins.filter (n: n != "sandbox") (builtins.attrNames hs))))'

# 1 ホストの drvPath を出す式 (tryEval で包まない。評価が落ちるホストの、原因のエラーを見るため)。$1: ホスト
host_drv_expr() {
  local h=$1
  h=${h//\\/\\\\}
  h=${h//\"/\\\"}
  h=${h//\$\{/\\\$\{}
  printf '%s' 'hs: (builtins.getAttr "'"${h}"'" hs).activationPackage.drvPath'
}

# 1 ホストの config.dotfiles を平らにして「パス<TAB>値の JSON」で 1 行ずつ出す式。$1: ホスト。
# drv (outPath を持つもの) はたどらずに JSON (store のパス) にし、関数は "<function>" にする
dotfiles_expr() {
  local h=$1
  h=${h//\\/\\\\}
  h=${h//\"/\\\"}
  h=${h//\$\{/\\\$\{}
  printf '%s' 'hs: let
    flat = p: v:
      if builtins.isAttrs v && !(v ? outPath) then
        builtins.concatLists (map (k: flat (if p == "" then k else p + "." + k) (builtins.getAttr k v)) (builtins.attrNames v))
      else [ (p + "\t" + (if builtins.isFunction v then "\"<function>\"" else builtins.toJSON v) + "\n") ];
  in builtins.concatStringsSep "" (flat "" (builtins.getAttr "'"${h}"'" hs).config.dotfiles)'
}

# flake.nix の path: の入力を「名前 パス」で 1 行ずつ出す (inputs.<名前>.url = "path:<パス>"; の形。本体と
# dotfiles-private)
path_inputs() {
  sed -n 's|^[[:space:]]*inputs\.\([A-Za-z0-9_-]*\)\.url[[:space:]]*=[[:space:]]*"path:\([^"]*\)".*|\1 \2|p' "$1"
}

# 評価用の写しの lock を、写しの flake.nix の path: の入力ぜんぶに合わせる (setup.sh の sync_local_flake_lock と
# 同じ考え)。$1: 写しのディレクトリ。lock が無ければ nix flake lock で作り、あれば実物の narHash が lock に無い入力を
# まとめて nix flake update <名前>… で張り直す (合っている入力は触らない)。指す先の無い入力は nix のエラーに任せる
lock_sync() {
  local d=$1 name path cur stale=()
  : >"${d}.lock.log"
  if [[ ! -f ${d}/flake.lock ]]; then
    nix flake lock "path:${d}" >>"${d}.lock.log" 2>&1
    return
  fi
  while read -r name path; do
    [[ -n ${name} && -d ${path} ]] || continue
    cur=$(nix hash path --sri --type sha256 "${path}" 2>>"${d}.lock.log") || return 1
    grep -qF -- "${cur}" "${d}/flake.lock" || stale+=("${name}")
  done < <(path_inputs "${d}/flake.nix")
  if ((${#stale[@]} > 0)); then
    nix flake update "${stale[@]}" --flake "path:${d}" >>"${d}.lock.log" 2>&1
  fi
}

# flake.nix ($1) の dotfiles-private の入力が読むホスト (指す先の hosts/*.nix のファイル名から .nix を除いたもの)
private_hosts_of() {
  local p f
  p=$(local_private_dir "$1")
  [[ -n ${p} && -d ${p}/hosts ]] || return 0
  for f in "${p}"/hosts/*.nix; do
    [[ -f ${f} ]] || continue
    f=${f##*/}
    printf '%s\n' "${f%.nix}"
  done
}

# nix のエラーの出力から、原因の行を字下げして出す。nix は trace のあとの最後の error: の行に原因を書くので、
# そこから 15 行まで (error: の行が無ければ末尾の 15 行) を出し、全文の場所を添える
eval_error_excerpt() {
  local at
  at=$(awk '/^[[:space:]]*error:/ { n = NR } END { print n + 0 }' "$1")
  if ((at > 0)); then
    awk -v at="${at}" 'NR >= at && NR < at + 15 { print "    " $0 }' "$1"
  else
    tail -n 15 "$1" | sed 's/^/    /'
  fi
  printf '    (全文: %s)\n' "$1"
}

cmd_compare() {
  local work="" baseline="" base_src nix_dir lines base_label new_sum base_sum base_is_old n_hosts=0 n_same=0 differ=0
  local h f flake_dir hosts_base hosts_new base_fail="" new_fail="" both_fail=""
  local private_new private_base this_name="" this_added=0 other_diff=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --baseline)
        [[ $# -ge 2 ]] || die "--baseline にディレクトリを渡してください"
        baseline=$2
        shift
        ;;
      -*) die "compare の知らない引数です: $1 (--help)" ;;
      *)
        [[ -z ${work} ]] || die "compare に渡せる作業場所は 1 つだけです"
        work=$1
        ;;
    esac
    shift
  done
  [[ -n ${work} ]] || die "compare に prepare の作業場所を渡してください (--help)"
  [[ -f ${work}/prepare.env && -f ${work}/new/flake.nix && -f ${work}/old/flake.nix ]] \
    || die "prepare の作業場所ではありません: ${work}"
  work=$(cd -P -- "${work}" && pwd)
  rm -f "${work}/compare.result"
  lines=$(conflict_lines "${work}/new/flake.nix")
  [[ -z ${lines} ]] || die "new/flake.nix に衝突の印が残っています (${lines// /・} 行目)。解いてから compare してください。"
  if [[ -n ${baseline} ]]; then
    [[ -f ${baseline}/flake.nix ]] || die "--baseline のディレクトリに flake.nix がありません: ${baseline}"
    base_src=$(cd -P -- "${baseline}" && pwd)
    base_label="--baseline ${base_src}"
  else
    base_src="${work}/old"
    base_label="旧い flake (old/)"
  fi
  [[ ${base_src} == "${work}/old" ]] && base_is_old=1 || base_is_old=0
  command -v nix &>/dev/null || die "nix がありません。"
  nix_dir=$(env_get "${work}/prepare.env" nix_dir) || die "prepare.env に nix_dir がありません: ${work}"
  need_tmp

  # 評価は写しで行う (old/ と new/ は触らない)。lock は基準の lock (無ければ old/ の lock) を両方に写す
  rm -rf "${work}/.eval"
  mkdir -p "${work}/.eval/base" "${work}/.eval/new"
  cp "${base_src}/flake.nix" "${work}/.eval/base/flake.nix"
  cp "${work}/new/flake.nix" "${work}/.eval/new/flake.nix"
  if [[ -f ${base_src}/flake.lock ]]; then
    cp "${base_src}/flake.lock" "${work}/.eval/base/flake.lock"
  elif [[ -f ${work}/old/flake.lock ]]; then
    cp "${work}/old/flake.lock" "${work}/.eval/base/flake.lock"
  fi
  [[ ! -f ${work}/.eval/base/flake.lock ]] || cp "${work}/.eval/base/flake.lock" "${work}/.eval/new/flake.lock"
  # ローカル flake の隣のファイル (flake.nix が import するものなど) も、両方の写しに置く。退避・一時ファイル・
  # setup (setup.sh への symlink) は写さない
  flake_dir=$(env_get "${work}/prepare.env" flake_dir) || die "prepare.env に flake_dir がありません: ${work}"
  for f in "${flake_dir}"/* "${flake_dir}"/.[!.]*; do
    [[ -e ${f} || -L ${f} ]] || continue
    case ${f##*/} in
      flake.nix | flake.lock | setup | flake.nix.bak-* | flake.lock.bak-* | .flake.nix.*) continue ;;
    esac
    # 作業場所そのもの (ローカル flake の中に作った場合) は写さない
    [[ $(cd -P -- "${f}" 2>/dev/null && pwd) != "${work}" ]] || continue
    if ! { cp -R -p "${f}" "${work}/.eval/base/" && cp -R -p "${f}" "${work}/.eval/new/"; }; then
      die "ローカル flake の隣のファイルを評価用の写しに置けません: ${f}"
    fi
  done
  new_sum=$(cksum <"${work}/new/flake.nix")
  base_sum=$(cksum <"${base_src}/flake.nix")

  printf '==> 比べる: %s と、移した flake (new/flake.nix)\n' "${base_label}"
  printf '  本体: %s\n' "${nix_dir}"
  for side in base new; do
    if ! lock_sync "${work}/.eval/${side}"; then
      printf '!! 評価用の写し (%s) の lock を、path: の入力 (本体・dotfiles-private) に合わせられません:\n' "${side}" >&2
      eval_error_excerpt "${work}/.eval/${side}.lock.log" >&2
      exit 2
    fi
  done

  echo "  評価しています (1 回 20〜60 秒)…"
  if ! nix eval --raw "path:${work}/.eval/base#homeConfigurations" --apply "${summary_expr}" \
    >"${work}/.eval/base.tsv" 2>"${work}/.eval/base.err"; then
    {
      printf '!! 旧い flake (基準) は今の本体 (%s) で評価できません (どのホストも評価する前に落ちた)。\n' "${nix_dir}"
      echo "   下の nix のエラーを読む (構文の誤り・import するファイルが無い・取得の失敗、または本体の変更に"
      echo "   旧い local が合っていない、など)。"
      echo "   nix のエラー:"
      eval_error_excerpt "${work}/.eval/base.err"
      echo "   読み解き方と比べ直し方は pjp-dotfiles-local-flake-migrate skill の「旧い flake が評価できないとき」"
      echo "   (旧い flake に評価が通るだけの直しを当てた基準を作り、--baseline で比べ直す)。"
    } >&2
    exit 3
  fi
  if ! nix eval --raw "path:${work}/.eval/new#homeConfigurations" --apply "${summary_expr}" \
    >"${work}/.eval/new.tsv" 2>"${work}/.eval/new.err"; then
    {
      echo "!! 移した flake は評価できません (new/flake.nix を直してから compare し直す)。"
      echo "   nix のエラー:"
      eval_error_excerpt "${work}/.eval/new.err"
    } >&2
    exit 4
  fi

  # ホストごとの drvPath を比べる (sandbox は式で外しているが、出力の側でも外す)
  awk -F'\t' '
    FNR == NR { if ($1 == "drv") a[$2] = $3; else if ($1 == "fail") a[$2] = "\001"; next }
    $1 == "drv" { b[$2] = $3 }
    $1 == "fail" { b[$2] = "\001" }
    END {
      for (h in a) {
        if (h == "sandbox") continue
        if (!(h in b)) s = "旧い flake だけ"
        else if (a[h] == "\001" && b[h] == "\001") s = "両方で評価が落ちる"
        else if (a[h] == "\001") s = "旧い flake で評価が落ちる"
        else if (b[h] == "\001") s = "移した flake で評価が落ちる"
        else s = (a[h] == b[h] ? "同じ" : "違う")
        print h "\t" s
      }
      for (h in b) if (h != "sandbox" && !(h in a)) print h "\t移した flake だけ"
    }
  ' "${work}/.eval/base.tsv" "${work}/.eval/new.tsv" | sort >"${tmp}/hosts.tsv"
  # 移した flake だけにあるホストのうち、移した flake の dotfiles-private の入力が読むもの (hosts/<名前>.nix) は、
  # 入力が足したホスト (指し直した・入力を足した) なので違いに数えない。ただし、この PC の名前のホストは setup が
  # --host なしで選ぶようになる (対象のホストが変わる) ので、違いに数える
  private_new=$'\n'$(private_hosts_of "${work}/.eval/new/flake.nix")$'\n'
  private_base=$'\n'$(private_hosts_of "${work}/.eval/base/flake.nix")$'\n'
  if [[ -f ${script_dir}/private-host.sh ]]; then
    this_name=$("${BASH}" "${script_dir}/private-host.sh" name 2>/dev/null) || this_name=""
  fi
  echo "  ホストごとの drvPath:"
  while IFS=$'\t' read -r h state; do
    if [[ ${state} == "移した flake だけ" && ${private_new} == *$'\n'"${h}"$'\n'* ]]; then
      if [[ ${h} == "${this_name}" && ${private_base} != *$'\n'"${h}"$'\n'* ]]; then
        state="dotfiles-private のホスト (移した flake だけ。この PC のホスト)"
        this_added=1
        differ=1
      else
        state="dotfiles-private のホスト (移した flake だけ。比べない)"
      fi
      printf '  %-30s %s\n' "${h}" "${state}"
      continue
    fi
    printf '  %-30s %s\n' "${h}" "${state}"
    case ${state} in
      "両方で評価が落ちる") both_fail+="${both_fail:+ }${h}" ;;
      "旧い flake で評価が落ちる") base_fail+="${base_fail:+ }${h}" ;;
      "移した flake で評価が落ちる") new_fail+="${new_fail:+ }${h}" ;;
      "同じ")
        n_hosts=$((n_hosts + 1))
        n_same=$((n_same + 1))
        ;;
      *)
        n_hosts=$((n_hosts + 1))
        differ=1
        other_diff=1
        ;;
    esac
  done <"${tmp}/hosts.tsv"

  # 片側でだけ評価が落ちるホストがあれば、そのうち 1 つを tryEval なしで評価し直して、原因のエラーを出す
  if [[ -n ${base_fail} || (-z ${new_fail} && -n ${both_fail} && ${n_hosts} -eq 0) ]]; then
    h=${base_fail:-${both_fail}}
    h=${h%% *}
    nix eval --raw "path:${work}/.eval/base#homeConfigurations" --apply "$(host_drv_expr "${h}")" \
      >/dev/null 2>"${work}/.eval/base-host.err" || true
    {
      printf '!! 旧い flake (基準) は、今の本体 (%s) では次のホストを評価できません: %s\n' "${nix_dir}" "${base_fail:-${both_fail}}"
      echo "   本体で option が削除・改名された・型が変わった、登録簿のホストが持つ値と local がぶつかる、などです。"
      printf '   nix のエラー (%s):\n' "${h}"
      eval_error_excerpt "${work}/.eval/base-host.err"
      [[ -z ${new_fail} ]] || printf '   移した flake で評価が落ちるホストもあります: %s\n' "${new_fail}"
      echo "   読み解き方と比べ直し方は pjp-dotfiles-local-flake-migrate skill の「旧い flake が評価できないとき」"
      echo "   (旧い flake に評価が通るだけの直しを当てた基準を作り、--baseline で比べ直す)。"
    } >&2
    exit 3
  fi
  if [[ -n ${new_fail} ]]; then
    h=${new_fail%% *}
    nix eval --raw "path:${work}/.eval/new#homeConfigurations" --apply "$(host_drv_expr "${h}")" \
      >/dev/null 2>"${work}/.eval/new-host.err" || true
    {
      printf '!! 移した flake は次のホストを評価できません (new/flake.nix を直してから compare し直す): %s\n' "${new_fail}"
      printf '   nix のエラー (%s):\n' "${h}"
      eval_error_excerpt "${work}/.eval/new-host.err"
    } >&2
    exit 4
  fi
  if ((n_same == n_hosts)); then
    printf '  → drvPath: 全 %d ホストで同じ\n' "${n_hosts}"
  else
    printf '  → drvPath: %d ホストのうち %d ホストが違う\n' "${n_hosts}" "$((n_hosts - n_same))"
  fi
  if [[ -n ${both_fail} ]]; then
    printf '  %s は、旧い flake でも移した flake でも評価が落ちるので比べていない\n' "${both_fail}"
    echo "    (setup の対象のホストでなければ気にしなくてよい。対象なら、旧い local がそのホストで落ちている)"
  fi
  if ((this_added)); then
    printf '  この PC のホスト %s が dotfiles-private (%s/hosts/%s.nix) から足される。\n' \
      "${this_name}" "$(local_private_dir "${work}/.eval/new/flake.nix")" "${this_name}"
    printf '    移したあと、setup は --host なしで %s を選ぶ (値は local ではなく、そのファイルから来る)。\n' "${this_name}"
  fi

  # 違うホストは、config.dotfiles の違いを出す。同じ違いのホストはまとめる (bash 3 でも動くよう、連想配列は使わない)
  local -a group_text=() group_hosts=()
  local text i found
  while IFS=$'\t' read -r h state; do
    [[ ${state} == 違う ]] || continue
    if nix eval --raw "path:${work}/.eval/base#homeConfigurations" --apply "$(dotfiles_expr "${h}")" \
      >"${tmp}/d-base.tsv" 2>/dev/null \
      && nix eval --raw "path:${work}/.eval/new#homeConfigurations" --apply "$(dotfiles_expr "${h}")" \
        >"${tmp}/d-new.tsv" 2>/dev/null; then
      text=$(
        awk -F'\t' '
          FNR == NR { a[$1] = $2; next }
          { b[$1] = $2 }
          END {
            for (k in a) if (!(k in b)) print "    " k ": " a[k] " → (無い)"
            for (k in b) if (!(k in a)) print "    " k ": (無い) → " b[k]; else if (a[k] != b[k]) print "    " k ": " a[k] " → " b[k]
          }
        ' "${tmp}/d-base.tsv" "${tmp}/d-new.tsv" | sort
      )
      [[ -n ${text} ]] || text="    (config.dotfiles は同じ。dotfiles の option の外 (足したホストの modules など) が違う)"
    else
      text="    (config.dotfiles を読めませんでした。評価に失敗した)"
    fi
    found=""
    for i in "${!group_text[@]}"; do
      if [[ ${group_text[i]} == "${text}" ]]; then
        group_hosts[i]="${group_hosts[i]}, ${h}"
        found=1
        break
      fi
    done
    if [[ -z ${found} ]]; then
      group_text+=("${text}")
      group_hosts+=("${h}")
    fi
  done <"${tmp}/hosts.tsv"
  for i in "${!group_text[@]}"; do
    printf '  config.dotfiles の違い (基準 → 移した。%s):\n' "${group_hosts[i]}"
    printf '%s\n' "${group_text[i]}"
  done

  # setup が文字列から拾うホストの並び (一番上が既定の対象)
  hosts_base=$(setup_hosts "${base_src}/flake.nix")
  hosts_new=$(setup_hosts "${work}/new/flake.nix")
  if [[ ${hosts_base} != "${hosts_new}" ]]; then
    differ=1
    printf '  setup が拾うホストの並び (一番上が既定の対象ホスト) が違う: 基準 [%s] → 移した [%s]\n' "${hosts_base}" "${hosts_new}"
  fi

  # 警告 (config.warnings) を、文ごとにホストの数で出す (文の末尾の改行は落とす)
  awk -F'\t' '
    function trim(s) { sub(/(\\n)+$/, "", s); return s }
    FNR == NR { if ($1 == "warn") { a[$3]++ }; next }
    $1 == "warn" { b[$3]++ }
    END {
      for (w in a) {
        if (!(w in b)) print "移して消えた: " trim(w) " (" a[w] " ホスト)"
        else if (b[w] < a[w]) print "一部のホストで消えた: " trim(w) " (" a[w] " → " b[w] " ホスト)"
      }
      for (w in b) {
        note = ""
        if (!(w in a)) note = " (基準には無い)"
        else if (b[w] > a[w]) note = " (基準では " a[w] " ホスト)"
        print "移した flake にある: " trim(w) " (" b[w] " ホスト)" note
      }
    }
  ' "${work}/.eval/base.tsv" "${work}/.eval/new.tsv" | sort >"${tmp}/warn.txt"
  if [[ -s ${tmp}/warn.txt ]]; then
    echo "  警告 (config.warnings):"
    # 警告の中の改行 (式で \n にしたもの) は、改行して字下げする
    awk '{ gsub(/\\n/, "\n      "); print "    " $0 }' "${tmp}/warn.txt"
  fi

  {
    printf 'new_sum=%s\n' "${new_sum}"
    printf 'baseline_dir=%s\n' "${base_src}"
    printf 'baseline_sum=%s\n' "${base_sum}"
    printf 'baseline_is_old=%s\n' "${base_is_old}"
    printf 'result=%s\n' "$( ((differ)) && echo differ || echo same)"
    printf 'unverified=%s\n' "${both_fail}"
  } >"${work}/compare.result"

  if ((differ)); then
    if ((this_added && ! other_diff)) && [[ ${hosts_base} == "${hosts_new}" ]]; then
      echo "→ 違いがあります (setup が --host なしで選ぶホストが ${this_name} になる)。意図した違いか確かめる。受け入れるなら apply に --accept-changes を付ける。"
    else
      echo "→ 違いがあります (値が変わる)。意図した違いか確かめる。受け入れるなら apply に --accept-changes を付ける。"
    fi
    return 1
  fi
  if ((base_is_old)); then
    if [[ -n ${both_fail} ]]; then
      echo "→ 比べられたホストでは、値は全部引き継げています (世代の中身は変わらない。switch は要らない)。"
    else
      echo "→ 値は全部引き継げています (home-manager の世代の中身は変わらない。switch は要らない)。"
    fi
  else
    echo "→ 基準と同じです。基準は旧い flake に直しを当てたものなので、apply には --accept-changes が要る。"
  fi
}

cmd_apply() {
  local work="" accept=0 flake_dir target lock lines new_sum result base_is_old unverified ts bak_nix bak_lock="" tmpf
  while [[ $# -gt 0 ]]; do
    case $1 in
      --accept-changes) accept=1 ;;
      -*) die "apply の知らない引数です: $1 (--help)" ;;
      *)
        [[ -z ${work} ]] || die "apply に渡せる作業場所は 1 つだけです"
        work=$1
        ;;
    esac
    shift
  done
  [[ -n ${work} ]] || die "apply に prepare の作業場所を渡してください (--help)"
  [[ -f ${work}/prepare.env && -f ${work}/new/flake.nix && -f ${work}/old/flake.nix ]] \
    || die "prepare の作業場所ではありません: ${work}"
  work=$(cd -P -- "${work}" && pwd)
  flake_dir=$(env_get "${work}/prepare.env" flake_dir) || die "prepare.env に flake_dir がありません: ${work}"
  target="${flake_dir}/flake.nix"
  lock="${flake_dir}/flake.lock"
  [[ -f ${target} ]] || die "ローカル flake がありません: ${target}"
  [[ -w ${target} && -w ${flake_dir} ]] || die "書き込めません: ${target} (ファイルかディレクトリに書き込みの権限が無い)"
  if ! cmp -s "${target}" "${work}/old/flake.nix" || [[ $(cksum <"${target}") != "$(env_get "${work}/prepare.env" old_sum)" ]]; then
    die "prepare のあとに ${target} が書き換わっています。prepare からやり直してください。"
  fi
  lines=$(conflict_lines "${work}/new/flake.nix")
  [[ -z ${lines} ]] || die "new/flake.nix に衝突の印が残っています (${lines// /・} 行目)。解いて compare してから apply してください。"
  [[ -f ${work}/compare.result ]] || die "compare を流していません。先に ${self} compare ${work} で確かめてください。"
  new_sum=$(cksum <"${work}/new/flake.nix")
  [[ ${new_sum} == "$(env_get "${work}/compare.result" new_sum)" ]] \
    || die "compare のあとに new/flake.nix が変わっています。${self} compare ${work} で確かめ直してください。"
  result=$(env_get "${work}/compare.result" result)
  base_is_old=$(env_get "${work}/compare.result" baseline_is_old)
  unverified=$(env_get "${work}/compare.result" unverified || true)
  if [[ ${result} != same || ${base_is_old} != 1 ]] && ((accept == 0)); then
    die "compare が旧い flake と同じでない (違いがある、または --baseline で比べた) ので、値が変わります。ユーザーが受け入れたなら --accept-changes を付けてください。"
  fi

  ts=$(date +%Y%m%dT%H%M%S)
  bak_nix="${target}.bak-${ts}"
  [[ ! -e ${bak_nix} ]] || die "退避の名前が既にあります: ${bak_nix} (1 秒おいてやり直す)"
  cp -p "${target}" "${bak_nix}"
  if [[ -f ${lock} ]]; then
    bak_lock="${lock}.bak-${ts}"
    cp -p "${lock}" "${bak_lock}"
  fi
  # 同じディレクトリの一時ファイルに書いてから置き換える (元の mode を引き継ぐ)。しくじったら一時ファイルを消す
  tmpf=$(mktemp "${flake_dir}/.flake.nix.XXXXXX")
  if ! { cp -p "${target}" "${tmpf}" && cat "${work}/new/flake.nix" >"${tmpf}" && mv -f "${tmpf}" "${target}"; }; then
    rm -f "${tmpf}"
    die "書き換えに失敗しました。${target} は元のままです (退避: ${bak_nix})。"
  fi

  printf '==> 書き換えました: %s\n' "${target}"
  printf '  退避: %s\n' "${bak_nix}"
  [[ -z ${bak_lock} ]] || printf '        %s\n' "${bak_lock}"
  echo "  戻すなら:"
  printf '    cp -p %s %s\n' "${bak_nix}" "${target}"
  [[ -z ${bak_lock} ]] || printf '    cp -p %s %s\n' "${bak_lock}" "${lock}"
  if [[ -n ${unverified} ]]; then
    printf '  比べていないホスト: %s (旧い flake でも移した flake でも評価が落ちた。setup の対象なら、移しても落ちる)\n' "${unverified}"
  fi
  if [[ ${result} == same && ${base_is_old} == 1 ]]; then
    echo "  home-manager の世代の中身は変わらないので、switch は要りません (次の ~/dotfiles/setup --update でそのまま使われる)。"
  else
    echo "  値が変わるので、反映は ~/dotfiles/setup --update。"
  fi
  echo "  退避は、動いているのを確かめたら消してよい。"
}

cmd_check() {
  local current marker
  parse_flake_args quiet "$@"
  current=$(template_id "${repo_dir}/${template_rel}" 2>/dev/null) || exit 2
  marker=$(local_marker "${flake}")
  [[ ${marker} != "${current}" ]] || return 0
  printf '%s → %s\n' "${marker:-印なし}" "${current}"
  return 1
}

cmd_status() {
  local current marker have want repoint=0
  parse_flake_args loud "$@"
  current=$(template_id "${repo_dir}/${template_rel}") || die "今の雛形の heredoc が見つかりません: ${repo_dir}/${template_rel}"
  marker=$(local_marker "${flake}")
  have=$(local_private_dir "${flake}")
  want=$(want_private_dir "${local_nix}")
  if template_has_private "${repo_dir}/${template_rel}" && [[ ${have} != "${want}" ]]; then
    repoint=1
  fi
  printf '==> ローカル flake: %s\n' "${flake}"
  printf '  雛形の版の印: %s\n' "${marker:-なし}"
  printf '  今の雛形の版: %s  (%s)\n' "${current}" "${repo_dir}/${template_rel}"
  if ((repoint)); then
    printf '  dotfiles-private の入力: %s → %s (移すときに指し直す)\n' "${have:-無い}" "${want}"
  fi
  if [[ ${marker} == "${current}" ]]; then
    if ((repoint == 0)); then
      echo "  → 今の雛形と同じ版です。移すものはありません。"
      return 0
    fi
    echo "  → 今の雛形と同じ版ですが、dotfiles-private の入力を指し直します。"
    printf '  指し直すには: %s prepare --flake %s\n' "${self}" "${flake_dir}"
    return 1
  fi
  need_history
  find_base "${flake}" "${local_nix}" "${marker}" "${have:-${want}}" || die "描ける雛形の版が履歴にありません。"
  if [[ ${base_how} == marker ]]; then
    printf '  → 前の雛形から作られています。印の版: %s\n' "${base_label}"
  elif [[ -n ${marker} ]]; then
    printf '  → 印 %s の版は履歴にありません。最も近い版: %s (差分 %s 行)\n' "${marker}" "${base_label}" "${base_lines}"
  else
    printf '  → 印がありません (印を入れる前の雛形から作られています)。最も近い版: %s (差分 %s 行)\n' "${base_label}" "${base_lines}"
  fi
  printf '  移すには: %s prepare --flake %s\n' "${self}" "${flake_dir}"
  return 1
}

cmd_prepare() {
  local current_file current marker conflicts=0 rc=0 resolved remaining resolved_lines remaining_lines f out_created=0
  local have want repoint=0
  out_dir=""
  base_given=""
  always=0
  parse_flake_args loud "$@"
  need_history
  need_tmp
  current_file="${repo_dir}/${template_rel}"
  current=$(template_id "${current_file}") || die "今の雛形の heredoc が見つかりません: ${current_file}"
  marker=$(local_marker "${flake}")
  # dotfiles-private の入力: 元の雛形は旧いファイルの値 (無ければ今の値) で、今の雛形は今の値 (input-dir) で描く。
  # 3-way merge がその行だけを今の値にする
  have=$(local_private_dir "${flake}")
  want=$(want_private_dir "${local_nix}")
  if template_has_private "${current_file}" && [[ ${have} != "${want}" ]]; then
    repoint=1
  fi
  find_base "${flake}" "${local_nix}" "${marker}" "${have:-${want}}" || die "描ける雛形の版が履歴にありません。"
  if [[ -n ${base_given} ]]; then
    # 元の雛形を選び直す (近い版が僅差で中身が違うときなど、Claude やユーザーが決めた版)
    f=$(rev_file "${base_given}")
    template_render "${f}" "${local_nix}" "${have:-${want}}" >"${tmp}/given.nix" 2>/dev/null \
      || die "--base ${base_given} の雛形を描けません。"
    base_rev=$(git -C "${repo_dir}" log -1 --format=%h "${base_given}")
    base_label="$(git -C "${repo_dir}" log -1 --format='%h %cs %s' "${base_given}")"
    base_id=$(template_id "${f}")
    base_how=given
    base_lines=$(diff_lines "${flake}" "${tmp}/given.nix")
    base_file="${tmp}/given.nix"
  fi

  printf '==> ローカル flake: %s\n' "${flake}"
  printf '  本体 (inputs.dotfiles.url): %s\n' "${local_nix}"
  if [[ ${local_nix} != "${repo_dir}/nix" ]]; then
    printf '  雛形はこの script の repo (%s) のものを使います (ローカル flake が指す本体とは別の checkout)。\n' "${repo_dir}"
  fi
  if [[ $(git -C "${repo_dir}" rev-parse --is-shallow-repository 2>/dev/null) == true ]]; then
    echo "  この repo は浅い clone なので、古い雛形の版が履歴に無いかもしれません。"
  fi
  if [[ ${base_how} == marker ]]; then
    printf '  元の雛形: %s  (印 %s と同じ版)\n' "${base_label}" "${marker}"
  elif [[ ${base_how} == given ]]; then
    printf '  元の雛形: %s  (--base で選んだ版。旧いファイルとの差分 %s 行)\n' "${base_label}" "${base_lines}"
    printf '    近い版: %s\n' "$(nearest_candidates)"
  else
    if [[ ${marker_missing} == 1 ]]; then
      printf '  印 %s の版は履歴にありません。差分の最も小さい版を元にします。\n' "${marker}"
    fi
    printf '  元の雛形: %s  (履歴で旧いファイルとの差分が最も小さい版。差分 %s 行)\n' "${base_label}" "${base_lines}"
    printf '    近い版: %s\n' "$(nearest_candidates)"
  fi
  printf '  今の雛形: 版 %s  (%s)\n' "${current}" "${current_file}"
  if ((repoint)); then
    printf '  dotfiles-private の入力: %s → %s (指し直す)\n' "${have:-無い}" "${want}"
  fi
  if [[ ${base_id} == "${current}" ]] && ((repoint == 0)); then
    echo "  → 元の雛形が今の雛形と同じ版です。移すものはありません。"
    if ((always == 0)); then
      return 0
    fi
    echo "    --always なので作業場所を作ります (new/flake.nix は旧いファイルと同じ。local を直して compare・apply する)。"
  fi

  if [[ -n ${out_dir} ]]; then
    if [[ -e ${out_dir} ]] && [[ ! -d ${out_dir} || -n $(ls -A "${out_dir}") ]]; then
      die "--out が空でないか、ディレクトリではありません: ${out_dir}"
    fi
    # 既にあるディレクトリは、自分のもので、ほかの利用者が書けないこと (共有の /tmp に先に作られた場所で、
    # new/flake.nix や compare.result を差し替えられないように)
    if [[ -d ${out_dir} ]] && { [[ ! -O ${out_dir} ]] || [[ -n $(find "${out_dir}" -maxdepth 0 \( -perm -0020 -o -perm -0002 \)) ]]; }; then
      die "--out がほかの利用者のものか、ほかの利用者が書けるディレクトリです: ${out_dir} (mktemp -d で作るか、--out を省く)"
    fi
    [[ -e ${out_dir} ]] || out_created=1
    mkdir -p "${out_dir}"
  else
    out_dir=$(mktemp -d "${TMPDIR:-/tmp}/local-flake-migrate-work.XXXXXX")
  fi
  out_dir=$(cd -P -- "${out_dir}" && pwd)
  # ローカル flake の中の作業場所は断る (compare が隣のファイルとして作業場所ごと写してしまう)
  case "${out_dir}/" in
    "${flake_dir}/"*)
      [[ ${out_created} != 1 ]] || rmdir "${out_dir}" 2>/dev/null || true
      die "--out がローカル flake の中です: ${out_dir} (ローカル flake の外、Claude の scratchpad などに作る)"
      ;;
  esac
  mkdir -p "${out_dir}/old" "${out_dir}/new"
  cp -p "${flake}" "${out_dir}/old/flake.nix"
  if [[ -f ${flake_dir}/flake.lock ]]; then
    cp -p "${flake_dir}/flake.lock" "${out_dir}/old/flake.lock"
  fi
  cp "${base_file}" "${out_dir}/base.nix"
  template_render "${current_file}" "${local_nix}" "${want}" >"${out_dir}/template.nix"
  {
    printf '版\t日付\t印\t旧いファイルとの差分の行数\t題\n'
    cat "${tmp}/candidates.tsv"
  } >"${out_dir}/candidates.tsv"

  git merge-file -p --diff3 -L 手元 -L 元の雛形 -L 今の雛形 \
    "${out_dir}/old/flake.nix" "${out_dir}/base.nix" "${out_dir}/template.nix" >"${tmp}/merged" || rc=$?
  [[ ${rc} -lt 128 ]] || die "git merge-file に失敗しました (終了コード ${rc})。"
  conflicts=${rc}
  resolve_conflicts "${tmp}/merged" "${tmp}/stats" >"${out_dir}/new/flake.nix"
  resolved=$(env_get "${tmp}/stats" resolved)
  remaining=$(env_get "${tmp}/stats" remaining)
  resolved_lines=$(env_get "${tmp}/stats" resolved_lines)
  remaining_lines=$(env_get "${tmp}/stats" remaining_lines)

  {
    printf 'flake_dir=%s\n' "${flake_dir}"
    printf 'old_sum=%s\n' "$(cksum <"${flake}")"
    printf 'nix_dir=%s\n' "${local_nix}"
    printf 'private_dir=%s\n' "${want}"
    printf 'base_rev=%s\n' "${base_rev}"
    printf 'base_id=%s\n' "${base_id}"
    printf 'base_how=%s\n' "${base_how}"
    printf 'base_lines=%s\n' "${base_lines}"
    printf 'template_id=%s\n' "${current}"
    printf 'conflicts=%s\n' "${conflicts}"
    printf 'resolved=%s\n' "${resolved}"
    printf 'remaining=%s\n' "${remaining}"
  } >"${out_dir}/prepare.env"

  printf '  衝突: %s 件 (自動で解いた %s 件・残り %s 件)\n' "${conflicts}" "${resolved}" "${remaining}"
  if [[ ${resolved} -gt 0 ]]; then
    printf '    自動で解いた: new/flake.nix の %s 行目 (片側が元の行の前後に足しただけの衝突)\n' "${resolved_lines// /・}"
  fi
  if [[ ${remaining} -gt 0 ]]; then
    printf '    残り: new/flake.nix の %s 行目から (<<<<<<< 手元 / ||||||| 元の雛形 / ======= / >>>>>>> 今の雛形)\n' "${remaining_lines// /・}"
  fi
  printf '==> 作業場所: %s\n' "${out_dir}"
  echo "  old/flake.nix    旧いローカル flake の写し (このあと触らない)"
  echo "  new/flake.nix    移した flake (残った衝突は diff3 の印のまま)"
  echo "  base.nix         元の雛形"
  echo "  template.nix     今の雛形"
  echo "  candidates.tsv   履歴の各版と、旧いファイルとの差分の行数"
  echo "次に打つもの:"
  if [[ ${remaining} -gt 0 ]]; then
    printf '  0. 残った衝突を %s/new/flake.nix で解く\n' "${out_dir}"
  fi
  printf '  1. %s compare %s\n' "${self}" "${out_dir}"
  printf '  2. diff -u %s %s/new/flake.nix を見て、書き換えてよいかを決める\n' "${flake}" "${out_dir}"
  printf '  3. %s apply %s\n' "${self}" "${out_dir}"
}

cmd_id() {
  local file
  [[ $# -le 1 ]] || die "id に渡せるのはパス 1 つだけです (--help)"
  # 一時ファイルの置き場は親で作る ($(...) の中で作ると、親の trap が消せない)
  [[ ${1:-} != - ]] || need_tmp
  file=$(script_file "${1:-${repo_dir}/${template_rel}}")
  template_id "${file}" || {
    printf '!! 雛形の heredoc が見つかりません (開きの行が 1 つでないか、閉じの EOS が無い): %s\n' "${1:-${repo_dir}/${template_rel}}" >&2
    return 1
  }
}

cmd_render() {
  local rev="" file="" nix_dir="" private=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --private-dir)
        [[ $# -ge 2 ]] || die "--private-dir にパスを渡してください"
        private=$2
        shift
        ;;
      --rev)
        [[ $# -ge 2 ]] || die "--rev に commit を渡してください"
        rev=$2
        shift
        ;;
      --file)
        [[ $# -ge 2 ]] || die "--file にパスを渡してください"
        file=$2
        shift
        ;;
      --nix-dir)
        [[ $# -ge 2 ]] || die "--nix-dir にパスを渡してください"
        nix_dir=$2
        shift
        ;;
      *) die "render の知らない引数です: $1 (--help)" ;;
    esac
    shift
  done
  [[ -n ${rev} || -n ${file} ]] || die "render には --rev か --file が要ります (--help)"
  [[ -z ${rev} || -z ${file} ]] || die "render の --rev と --file はどちらか 1 つです"
  [[ -n ${nix_dir} ]] || die "render には --nix-dir が要ります (--help)"
  # 一時ファイルの置き場は親で作る ($(...) の中で作ると、親の trap が消せない)
  need_tmp
  if [[ -n ${rev} ]]; then
    file=$(rev_file "${rev}")
  else
    file=$(script_file "${file}")
  fi
  if ! template_raw "${file}" >/dev/null; then
    printf '!! 雛形の heredoc が見つかりません (開きの行が 1 つでないか、閉じの EOS が無い): %s\n' "${rev:-${file}}" >&2
    return 1
  fi
  [[ -n ${private} ]] || private=$(want_private_dir "${nix_dir}")
  template_render "${file}" "${nix_dir}" "${private}"
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi
cmd=$1
shift
case ${cmd} in
  status) cmd_status "$@" ;;
  check) cmd_check "$@" ;;
  prepare) cmd_prepare "$@" ;;
  compare) cmd_compare "$@" ;;
  apply) cmd_apply "$@" ;;
  id) cmd_id "$@" ;;
  render) cmd_render "$@" ;;
  -h | --help) usage ;;
  *) die "知らないコマンドです: ${cmd} (--help)" ;;
esac
