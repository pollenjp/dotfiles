#!/usr/bin/env bash
# shellcheck shell=bash
#
# マシンローカルの環境変数ファイル (~/.config/pjp/env) を用意し、頭の「dotfiles が書く欄」を書き直す。
# 冪等。`setup.sh --update` でも毎回走る。
#
# ## これは何か
#
# そのマシンでしか使わない API キーのように、tracked にできない環境変数の置き場。
# bash.nix / fish.nix のローダが「在れば読む / 無ければ何もしない」で参照する。
# 形式の詳細は nix/README.md の「マシンローカルの環境変数」を参照。
#
# ファイルの頭には、dotfiles と skill が受け取る環境変数の一覧を、印で囲んだ欄として置く
# (ADR 021)。一覧の文言は、変数を読むコードの隣に置いた断片から集める:
#
#   dotfiles の script が読む変数   この script のいる checkout の nix/files/pjp-env/dotfiles.txt
#   skill が読む変数                 ~/.claude/skills/<名前>/pjp-env.txt (名前の順)
#
# 断片は素のテキストで、各行の頭に「# 」を付けて欄に並べる。欄の中はすべて # で始まるので、
# ローダは欄を読まない (断片に FOO=bar と書いても、欄では # FOO=bar になる)。
#
# ## なぜ Nix で配置しないのか
#
# 中身は秘密情報なので、リポジトリにも /nix/store にも置けない。home.file で
# 配置すると store 経由になり、誰でも読める場所に値が残る。
# home.sessionVariables も同じ理由で使えない。
#
# ## なぜ home.activation でやらないのか
#
# 秘密の値が入ったファイルを switch が書き換えることになり、「Nix の管理下か否か」の線が
# 曖昧になる。store に置けないファイルは setup の手順で扱う。
#
# ## 欄だけを書き直す。欄の外は 1 バイトも変えない
#
# 実際の API キーが入っているファイルなので、書き換えるのは印 (# >>> dotfiles の行から
# # <<< dotfiles の行まで) の間だけ。印の外 (ユーザーが書いた値・メモ・コメントアウトした値) は、
# 改行の形も含めてそのまま残す。迷う場面 (印が壊れている・symlink・書けない) では書かずに
# warn で知らせ、exit 0 で終える (setup の後ろの手順を巻き込まない)。

set -eu -o pipefail

# glob の並び (skill の節の順) を C ロケールの順に揃える
export LC_ALL=C

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")
dotfiles_fragment="${repo_dir}/nix/files/pjp-env/dotfiles.txt"
skills_dir="${HOME}/.claude/skills"

env_file="${XDG_CONFIG_HOME:-${HOME}/.config}/pjp/env"
env_dir=$(dirname "${env_file}")

# 印として見るのは行の頭だけ。後ろの文言は変えてよい (ADR 021 の A)
begin_prefix='# >>> dotfiles'
end_prefix='# <<< dotfiles'
begin_line="${begin_prefix} が書く欄 (setup --update のたびに書き直す。ここには書かない) >>>"
end_line="${end_prefix} が書く欄ここまで。この行より下に生の KEY=VALUE を書く (setup はここから下を書き換えない) <<<"

# 手順を止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup.sh から走るときは、最後の「警告のまとめ」にも同じ行を残す (summary_warn)。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
  summary_warn "$@"
}

# setup.sh の最後の「警告のまとめ」にだけ警告を残す (その場には出さない。引数は warn と同じ)。
# setup.sh が手順ごとに DOTFILES_SETUP_WARNINGS でファイルを渡す。単体で流したときは何もしない。
summary_warn() {
  [[ -n ${DOTFILES_SETUP_WARNINGS-} ]] || return 0
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  { printf '%s\n' "${text//${nl}/${nl}   }" >>"${DOTFILES_SETUP_WARNINGS}"; } 2>/dev/null || true
}

# stat のオプションは GNU (Linux) と BSD (macOS) で違う。
file_mode() {
  local mode
  if mode=$(stat -c '%a' "$1" 2>/dev/null); then
    printf '%s' "${mode}"
  else
    stat -f '%Lp' "$1"
  fi
}

# 一時ファイルは env と同じディレクトリに作り (mv を同じファイルシステムの中で済ませる)、
# 抜けるときに残っていれば消す
block_tmp=""
new_tmp=""
bak_tmp=""
cleanup() {
  local f
  for f in "${block_tmp}" "${new_tmp}" "${bak_tmp}"; do
    [[ -z ${f} ]] || rm -f -- "${f}"
  done
}
trap cleanup EXIT

# 欄の 1 節を stdout へ出す。$1: 見出し、$2: 断片のファイル。
# 行末の CR を外し、先頭と末尾の空行を落とし、空行は「#」、それ以外は「# 」+ 行にする。
# 空 (空行だけ) なら何も出さない。読めない断片と、「# 」を付けると印として読まれてしまう行
# (>>> dotfiles / <<< dotfiles で始まる行) を持つ断片は、warn して何も出さず 1 を返す。
render_fragment() {
  local heading=$1 file=$2 body rc=0
  body=$(
    awk '
      { sub(/\r$/, ""); lines[++n] = $0 }
      END {
        first = 0
        for (i = 1; i <= n; i++) if (lines[i] !~ /^[ \t]*$/) { if (!first) first = i; last = i }
        if (!first) exit 0
        for (i = first; i <= last; i++) if (lines[i] ~ /^(>>>|<<<) dotfiles/) exit 3
        for (i = first; i <= last; i++) print (lines[i] ~ /^[ \t]*$/ ? "#" : "# " lines[i])
      }
    ' "${file}" 2>/dev/null
  ) || rc=$?
  case ${rc} in
    0) ;;
    3)
      warn "${file} は ~/.config/pjp/env の欄に入れません。" \
        "印と同じ頭 (>>> dotfiles / <<< dotfiles) で始まる行があり、欄が壊れるため。その行の頭を変えてください。"
      return 1
      ;;
    *)
      warn "${file} を読めないので、~/.config/pjp/env の欄に入れません。"
      return 1
      ;;
  esac
  [[ -n ${body} ]] || return 0
  printf '# ---- %s ----\n#\n%s\n#\n' "${heading}" "${body}"
}

# 欄の全体 (始まりの印から終わりの印まで) を stdout へ出す
render_block() {
  local d
  printf '%s\n' "${begin_line}"
  cat <<'PREAMBLE'
#
# マシンローカルの環境変数。git にも /nix/store にも入らない。
# bash / fish の両方が起動時に読む (dotfiles の nix/README.md「マシンローカルの環境変数」)。
#
#   - 行頭から KEY=VALUE、1 行 1 個、改行は LF
#   - クォートしない。= の後ろは行末までそのまま値 (FOO='x' は 'x' になる)
#   - 展開もコマンド置換もしない ($X は文字列 "$X" のまま)
#   - 識別子で始まらない行は黙って無視される
#   - 同じ名前を 2 回書くと、後の行が勝つ
#
# 下に並ぶのは、dotfiles と skill が受け取る環境変数。使うものは、この欄より下へ
# 「#」を外して書き写し、値を入れる。
#
PREAMBLE
  if [[ -f ${dotfiles_fragment} ]]; then
    render_fragment dotfiles "${dotfiles_fragment}" || true
  fi
  # */ は切れた symlink に当たらない (指す先がディレクトリでないため)
  for d in "${skills_dir}"/*/; do
    [[ -f "${d}pjp-env.txt" ]] || continue
    d=${d%/}
    render_fragment "skill: ${d##*/}" "${d}/pjp-env.txt" || true
  done
  printf '%s\n' '#####################################################' "${end_line}"
}

# 書けないときも setup を止めない (warn して exit 0)
give_up() {
  warn "$@"
  exit 0
}

if [[ -e ${env_file} || -L ${env_file} ]]; then
  echo "既に在るので中身には触りません: ${env_file}"
else
  mkdir -p "${env_dir}" 2>/dev/null \
    || give_up "${env_dir} を作れないので、${env_file} を置きません。"
  block_tmp=$(mktemp "${env_dir}/.env.XXXXXX" 2>/dev/null) \
    || give_up "${env_dir} に一時ファイルを作れないので、${env_file} を置きません。"
  if ! { render_block >"${block_tmp}" && chmod 600 "${block_tmp}" && mv -f "${block_tmp}" "${env_file}"; }; then
    give_up "${env_file} を書けませんでした。"
  fi
  block_tmp=""
  echo "作りました: ${env_file}"
fi

# 秘密情報を置く前提のファイルなので、緩ければ締める。
mode=$(file_mode "${env_file}")
if [[ ${mode} != 600 ]]; then
  chmod 600 "${env_file}"
  echo "パーミッションを ${mode} -> 600 にしました。"
fi

echo
echo "値を足すには (新しいシェルから有効になる):"
echo "  \$EDITOR ${env_file}"
