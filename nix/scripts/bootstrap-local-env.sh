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
# 前の版を 1 世代だけ残す (欄の中に手で書いたコメントの逃げ場。秘密の写しを増やさないため 1 つだけ)
bak_file="${env_dir}/env.bak"

# 印として見るのは行の頭だけ。後ろの文言は変えてよい (ADR 021 の A)
begin_prefix='# >>> dotfiles'
end_prefix='# <<< dotfiles'
begin_line="${begin_prefix} が書く欄 (setup --update のたびに書き直す。ここには書かない) >>>"
end_line="${end_prefix} が書く欄ここまで。この行より下に生の KEY=VALUE を書く (setup はここから下を書き換えない) <<<"
# Windows のエディタが頭に付ける UTF-8 の BOM。印と古いテンプレートを見分けるときだけ外す
bom=$'\xef\xbb\xbf'

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

# 印の無い古いテンプレート (ADR 021 の前の、この script が初回に置いたもの)。
# 頭の 10 行がこれと同じなら、欄に替えてよい (ユーザーが書いたものではない)。
legacy_template() {
  cat <<'TEMPLATE'
# マシンローカルの環境変数。git にも /nix/store にも入らない。
# bash / fish の両方が起動時に読む (nix/README.md も参照)。
#
#   - 行頭から KEY=VALUE、1 行 1 個、改行は LF
#   - クォートしない。= の後ろは行末までそのまま値 (FOO='x' は 'x' になる)
#   - 展開もコマンド置換もしない ($X は文字列 "$X" のまま)
#   - 識別子で始まらない行は黙って無視される
#
# 例:
#   FOO_API_KEY=sk-xxxx
TEMPLATE
}

# 行末の CR と 1 行目の頭の BOM を外した行を line に入れる awk の断片
# (印と古いテンプレートの見分けにだけ使う。書くときは元のバイトのまま)。$0 は awk の変数
# shellcheck disable=SC2016
awk_plain_line='line = $0; sub(/\r$/, "", line); if (NR == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1)'

# 印の行を数える。出力 (1 行): <始まりの数> <終わりの数> <始まりの行番号> <終わりの行番号> <全行数>
# 行番号は「,」区切りで、無ければ「無し」
scan_markers() {
  awk -v b="${begin_prefix}" -v e="${end_prefix}" -v bom="${bom}" '
    { '"${awk_plain_line}"' }
    index(line, b) == 1 { nb++; bl = bl (bl == "" ? "" : ",") NR }
    index(line, e) == 1 { ne++; el = el (el == "" ? "" : ",") NR }
    END { printf "%d %d %s %s %d\n", nb, ne, (bl == "" ? "無し" : bl), (el == "" ? "無し" : el), NR }
  ' "$1"
}

# 頭の 10 行が古いテンプレートと 1 行ずつ同じか
is_legacy() {
  local head10
  head10=$(awk -v bom="${bom}" 'NR > 10 { exit } { '"${awk_plain_line}"'; print line }' "$1")
  [[ ${head10} == "$(legacy_template)" ]]
}

# 印の間 (行 $2 と行 $3 の間) の、空白だけでなく # で始まらない行 (ユーザーが書いたもの)。
# $4 が lines なら元のバイトのまま出す。names なら「<KEY=VALUE の形でない行の数><TAB><変数名のカンマ区切り>」
# (数を先に置く。TAB は read が空白として読み飛ばすので、空になりうる名前を先に置くとずれる)
rescue() {
  awk -v b="$2" -v e="$3" -v mode="$4" '
    NR <= b || NR >= e { next }
    { l = $0; gsub(/[ \t\r]/, "", l) }
    l == "" || substr($0, 1, 1) == "#" { next }
    mode == "lines" { print; next }
    match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) { names = names (names == "" ? "" : ", ") substr($0, 1, RLENGTH - 1); next }
    { other++ }
    END { if (mode == "names") printf "%d\t%s\n", other, names }
  ' "$1"
}

# 書けないときも setup を止めない (warn して exit 0)
give_up() {
  warn "$@"
  exit 0
}

# --- 書いてよいファイルか ----------------------------------------------------

if [[ -L ${env_file} ]]; then
  give_up "${env_file} は symlink なので書き換えません (指す先: $(readlink "${env_file}"))。" \
    "頭の欄を足すなら、symlink をやめて実体のファイルを置いてください。"
fi
if [[ -e ${env_file} && ! -f ${env_file} ]]; then
  give_up "${env_file} が普通のファイルではないので書き換えません。"
fi
if [[ -f ${env_file} && ! (-r ${env_file} && -w ${env_file}) ]]; then
  give_up "${env_file} を読み書きできないので書き換えません。"
fi

# --- 書き上がりを一時ファイルに組む ------------------------------------------

mkdir -p "${env_dir}" 2>/dev/null \
  || give_up "${env_dir} を作れないので、${env_file} を書けません。"
block_tmp=$(mktemp "${env_dir}/.env.XXXXXX" 2>/dev/null) \
  || give_up "${env_dir} に一時ファイルを作れないので、${env_file} を書き換えません。"
new_tmp=$(mktemp "${env_dir}/.env.XXXXXX" 2>/dev/null) \
  || give_up "${env_dir} に一時ファイルを作れないので、${env_file} を書き換えません。"
render_block >"${block_tmp}" || give_up "${env_file} の欄を組めませんでした。"

rescued_names=""
rescued_other=0
if [[ ! -e ${env_file} ]]; then
  kind=created
  cat "${block_tmp}" >"${new_tmp}" || give_up "${env_file} を書けませんでした。"
else
  markers=$(scan_markers "${env_file}") || give_up "${env_file} を読めないので書き換えません。"
  read -r nb ne blist elist total <<<"${markers}"
  if [[ ${nb} == 1 && ${ne} == 1 ]] && ((blist < elist)); then
    # 印の間だけを替える。印より上と下は head / tail でバイトのまま写す。
    # 印の間のユーザーの行は、終わりの印のすぐ下 (下の行より前) へ移し、後の行が勝つ順を変えない
    kind=replaced
    kept=$((blist - 1 + total - elist))
    {
      if ((blist > 1)); then
        head -n "$((blist - 1))" "${env_file}"
      fi
      cat "${block_tmp}"
      rescue "${env_file}" "${blist}" "${elist}" lines
      tail -n "+$((elist + 1))" "${env_file}"
    } >"${new_tmp}" || give_up "${env_file} を書けませんでした。"
    IFS=$'\t' read -r rescued_other rescued_names <<<"$(rescue "${env_file}" "${blist}" "${elist}" names)"
  elif [[ ${nb} == 0 && ${ne} == 0 ]]; then
    if is_legacy "${env_file}"; then
      kind=legacy
      kept=$((total > 10 ? total - 10 : 0))
      { cat "${block_tmp}" && tail -n +11 "${env_file}"; } >"${new_tmp}" \
        || give_up "${env_file} を書けませんでした。"
    else
      kind=prepended
      kept=${total}
      { cat "${block_tmp}" && cat "${env_file}"; } >"${new_tmp}" \
        || give_up "${env_file} を書けませんでした。"
    fi
  else
    give_up "${env_file} の印の行が 1 組になっていないので、書き換えません (${begin_prefix} の行: ${blist}、${end_prefix} の行: ${elist})。" \
      "直すには、印の行を 1 組だけ残すか、欄ごと消して印の無い形に戻し、~/dotfiles/setup --steps bootstrap-local-env で流し直してください。"
  fi
fi

# --- 書く (今と違うときだけ) -------------------------------------------------

if [[ ${kind} != created ]] && cmp -s "${new_tmp}" "${env_file}"; then
  echo "欄は最新です: ${env_file}"
else
  if [[ ${kind} != created ]]; then
    bak_tmp=$(mktemp "${env_dir}/.env.bak.XXXXXX" 2>/dev/null) \
      || give_up "${env_dir} に一時ファイルを作れないので、${env_file} を書き換えません。"
    if ! { cp "${env_file}" "${bak_tmp}" && chmod 600 "${bak_tmp}" && mv -f "${bak_tmp}" "${bak_file}"; }; then
      give_up "前の版を ${bak_file} へ写せないので、${env_file} を書き換えません。"
    fi
    bak_tmp=""
  fi
  if ! { chmod 600 "${new_tmp}" && mv -f "${new_tmp}" "${env_file}"; }; then
    give_up "${env_file} を書けませんでした (中身は元のまま)。"
  fi
  new_tmp=""
  case ${kind} in
    created) echo "作りました: ${env_file}" ;;
    replaced) echo "欄を書き直しました: ${env_file} (欄の外の ${kept} 行には触れていません。前の版は ${bak_file})" ;;
    legacy) echo "印の無い古い形だったので、頭のテンプレート 10 行を欄に替えました: ${env_file} (残りの ${kept} 行には触れていません。前の版は ${bak_file})" ;;
    prepended) echo "印が無かったので、欄を頭に足しました: ${env_file} (今あった ${kept} 行はすべて欄の下に残しています。前の版は ${bak_file})" ;;
  esac
fi

if [[ -n ${rescued_names} || ${rescued_other} != 0 ]]; then
  moved=${rescued_names:-(無し)}
  if [[ ${rescued_other} != 0 ]]; then
    moved+="。ほかに KEY=VALUE の形でない行 ${rescued_other} 行"
  fi
  warn "${env_file} の欄の中に書かれていた行を、欄のすぐ下へ移しました: ${moved} (値は出しません)。" \
    "欄 (# >>> dotfiles から # <<< dotfiles まで) は setup が書き直すので、値は欄より下に書いてください。"
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
