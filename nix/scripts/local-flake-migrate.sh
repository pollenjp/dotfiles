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
# ${nix_dir}・${template_id} の置き換えと、\$ \` \\ を 1 文字にすることだけで、ほかの展開があれば描かずに止まる。
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
  local-flake-migrate.sh id [<setup-local-flake.sh のパス> | -]
      雛形の版の印 (8 桁の 16 進) を出す。省けばこの repo の setup-local-flake.sh、- なら stdin
  local-flake-migrate.sh render (--rev <rev> | --file <パス>) --nix-dir <パス>
      雛形の 1 版を描いて stdout に出す (--rev はこの repo の git の commit)
  local-flake-migrate.sh -h, --help
      これ
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

tmp=$(mktemp -d "${TMPDIR:-/tmp}/local-flake-migrate.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

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

# 雛形の 1 版を描く。$1: setup-local-flake.sh のパス、$2: ${nix_dir} に入れるパス。
# 引用しない heredoc の展開を真似る。描けない展開があれば、何も出さずに理由を stderr に出して 1
template_render() {
  local id
  id=$(template_id "$1") || return 1
  template_raw "$1" | NIX_DIR=$2 TEMPLATE_ID=${id} awk '
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
    cat >"${tmp}/stdin.sh"
    printf '%s\n' "${tmp}/stdin.sh"
  else
    [[ -f $1 ]] || die "ファイルがありません: $1"
    printf '%s\n' "$1"
  fi
}

# この repo の、ある commit の setup-local-flake.sh をファイルに写して、そのパスを出す
rev_file() {
  local f="${tmp}/rev-$1.sh"
  git -C "${repo_dir}" show "$1:${template_rel}" >"${f}" 2>/dev/null \
    || die "この repo (${repo_dir}) の $1 に ${template_rel} がありません。"
  printf '%s\n' "${f}"
}

cmd_id() {
  local file
  [[ $# -le 1 ]] || die "id に渡せるのはパス 1 つだけです (--help)"
  file=$(script_file "${1:-${repo_dir}/${template_rel}}")
  template_id "${file}" || {
    printf '!! 雛形の heredoc が見つかりません (開きの行が 1 つでないか、閉じの EOS が無い): %s\n' "${1:-${repo_dir}/${template_rel}}" >&2
    return 1
  }
}

cmd_render() {
  local rev="" file="" nix_dir=""
  while [[ $# -gt 0 ]]; do
    case $1 in
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
  if [[ -n ${rev} ]]; then
    file=$(rev_file "${rev}")
  else
    file=$(script_file "${file}")
  fi
  if ! template_raw "${file}" >/dev/null; then
    printf '!! 雛形の heredoc が見つかりません (開きの行が 1 つでないか、閉じの EOS が無い): %s\n' "${rev:-${file}}" >&2
    return 1
  fi
  template_render "${file}" "${nix_dir}"
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi
cmd=$1
shift
case ${cmd} in
  id) cmd_id "$@" ;;
  render) cmd_render "$@" ;;
  -h | --help) usage ;;
  *) die "知らないコマンドです: ${cmd} (--help)" ;;
esac
