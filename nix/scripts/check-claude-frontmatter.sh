#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の skill・agent・command の frontmatter を確かめる。
#
#   check-claude-frontmatter.sh [<nix のパス>]
#
# frontmatter が YAML として読めないと、Claude Code はエラーを出さずに frontmatter を空として扱う (skill は読み込まれるが、
# description の代わりに本文の最初の行が一覧に出て、いつ使うものかが Claude に伝わらない)。読めても、値の途中の --- で
# frontmatter が閉じる・素の値の「 #」から先がコメントとして消える・重複した key の前の値が捨てられる、といった形では
# 値が黙って変わる。どれも Claude Code は何も言わないので、ここで落とす (TKT-289)。
#
# 見るのは <nix>/files/claude/ の下で、nix/home/modules/claude.nix が ~/.claude/ へ配置するもの:
#
#   skills/<名前>/SKILL.md   frontmatter・name がディレクトリ名と同じ・description
#   agents/<名前>.md         frontmatter・name がファイル名と同じ・description
#   commands/**/<名前>.md    frontmatter・description (呼び出し名はパスから決まるので、name は見ない)
#
# skills・agents・commands の直下の README.md は配置されないので見ない (commands のサブディレクトリの README.md は配置
# されて command になるので見る)。名前 (skill はディレクトリ名、agent はファイル名、command はパスの先頭の要素。
# commands/ns/foo.md の呼び出し名は /ns:foo) は pjp- で始める (nix/README.md の「命名」)。
#
# frontmatter (1 行目の --- から、次の --- の行まで) は yq (mikefarah/yq) で YAML として読む。frontmatter が無い・中に
# --- がある・YAML として読めない・key: value の並びでない・key が重複する・name と description が文字列でない・
# description が無い (空白だけも)・素の値の description の「 #」から先がコメントとして消える・name がディレクトリ名
# (ファイル名) と違う・小文字ケバブケースでない・名前が pjp- で始まらない、のどれでも落とす。description が 1024 文字を
# 超えるものは、注意を出すが落とさない。観点は claude-skills (private) の scripts/lint.sh の frontmatter の検査に
# 揃えてある。片方の観点を変えたら、もう片方も見る。
#
# 落とすものがあれば「<ファイル>: <理由>」を全部出して exit 1。見るものが 1 つも無くても exit 1。<nix>/files/claude が
# 無い・知らない引数・yq が無いときは exit 2。CI の lint ジョブが流す。<nix のパス> を省けば、この script の隣の nix/ を
# 見る。yq (mikefarah/yq) が PATH に無ければ、nix/ の devShell に入り直す (入り直しの nix develop 自体が落ちたときは、
# nix の終了コード (多くは 1) のまま終わる。CI は devShell の中から直に呼ぶ)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Claude Code の skill・agent・command の frontmatter を確かめる。

使い方:
  check-claude-frontmatter.sh [<nix のパス>]   確かめる (省けば、この script の隣の nix/)
  check-claude-frontmatter.sh -h, --help       これ
EOS
}

nix_dir=
for arg in "$@"; do
  case ${arg} in
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n ${nix_dir} ]]; then
        echo "<nix のパス> は 1 つだけです: ${arg}" >&2
        usage >&2
        exit 2
      fi
      nix_dir=${arg}
      ;;
  esac
done

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
flake_dir=$(dirname "${script_dir}")

have() { command -v "$1" &>/dev/null; }

# 同じ yq という名前の python の yq (kislyuk/yq。jq の wrapper) は書き方が違うので、版の出力で見分ける
have_yq_go() {
  local version
  have yq || return 1
  version=$(yq --version 2>&1) || return 1
  [[ ${version} == *mikefarah/yq* ]]
}

if ! have_yq_go; then
  if [[ -z ${CHECK_CLAUDE_FRONTMATTER_REEXEC:-} ]] && have nix; then
    export CHECK_CLAUDE_FRONTMATTER_REEXEC=1
    exec nix develop "${flake_dir}" --command "$0" "$@"
  fi
  echo "!! yq (mikefarah/yq) が要ります。nix があれば nix/ の devShell へ自動で入り直します。" >&2
  exit 2
fi

nix_dir=${nix_dir:-${flake_dir}}
claude_dir=${nix_dir}/files/claude
if [[ ! -d ${claude_dir} ]]; then
  echo "!! 見つかりません: ${claude_dir}" >&2
  exit 2
fi
base=$(basename "${nix_dir}")

problems=()
notes=()

# $1: ファイルかディレクトリ。nix/ から書いた名前を出す (CI の出力を短くする)
label_of() {
  printf '%s\n' "${base}/${1#"${nix_dir}/"}"
}

# $1 の 1 行目の --- から次の --- の行までの中身を出す。frontmatter が無ければ (1 行目が --- でない・閉じていない) 1 を返す
frontmatter() {
  awk '
    NR == 1 { if ($0 != "---") { exit 1 }; next }
    /^---[[:space:]]*$/ { found = 1; exit 0 }
    { print }
    END { if (!found) { exit 1 } }
  ' "$1"
}

# frontmatter ($2) に yq の式 ($1) を当てる。
#
# 先頭に --- の 1 行を足し、--header-preprocess を切って渡す。yq は既定で先頭の --- とコメントを読み飛ばすので、そのまま
# ではエラーの行番号がファイルの行とずれる。これで scanner のエラー (mapping values are not allowed など) はファイルの
# 行を指す。parser のエラー (did not find expected key など) は yq が行を 0 から数えるので 1 行前を指す (yq-go 4.53.3)。
# 見分ける目印が無いので、そのまま出す。alias は explode で解いてから式を当てる (Claude Code は alias を値に解くが、yq は
# 解かないと alias の type を空で返す)。
fm_yq() {
  yq --header-preprocess=false "explode(.) | $1" - <<<$'---\n'"$2"
}

# $1: 名前、$2: その名前を持つファイルかディレクトリ
check_prefix() {
  if [[ $1 != pjp-* ]]; then
    problems+=("$(label_of "$2"): 名前 '$1' は 'pjp-' で始めてください (自作のものと配信物を見分けるため。nix/README.md の「命名」)")
  fi
}

# $1: ファイル、$2: name に期待する値 (空なら name を見ない)、$3: その値の呼び名 (ディレクトリ名・ファイル名)
check_md() {
  local file=$1 want_name=$2 want_what=$3
  local label fm dash_line yaml_err root_type dup_keys desc_type desc dropped desc_chars name_type fm_name
  label=$(label_of "${file}")

  if ! fm=$(frontmatter "${file}"); then
    problems+=("${label}: YAML frontmatter がありません (1 行目を --- にし、次の --- の行で閉じる)")
    return 0
  fi

  # Claude Code は frontmatter を /^---\s*\n([\s\S]*?)---\s*\n?/ で取り出す (2.1.304 の本体で確かめた)。値の途中の ---
  # でもそこで閉じ、その先を本文として読む
  dash_line=$(awk 'index($0, "---") { print NR + 1; exit }' <<<"${fm}")
  if [[ -n ${dash_line} ]]; then
    problems+=("${label}: frontmatter の中に --- があります (${dash_line} 行目)。Claude Code はそこで frontmatter が終わったと読みます")
    return 0
  fi

  if ! yaml_err=$(fm_yq '.' "${fm}" 2>&1 >/dev/null); then
    yaml_err=${yaml_err#"Error: bad file '-': "}
    problems+=("${label}: frontmatter を YAML として読めません (${yaml_err//$'\n'/ })。値に「: 」や「 #」を含むなら、>- の block scalar にするか引用符で囲んでください")
    return 0
  fi

  root_type=$(fm_yq 'type' "${fm}")
  case ${root_type} in
    '!!map')
      # yq も Claude Code も、重複した key は黙って後の値を使う
      dup_keys=$(fm_yq 'keys | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "${fm}")
      if [[ -n ${dup_keys} ]]; then
        problems+=("${label}: frontmatter の key が重複しています (${dup_keys})。後の値だけが使われます")
      fi
      ;;
    '!!null') ;; # 空かコメントだけ。下の description の検査で落ちる
    *)
      problems+=("${label}: frontmatter が key: value の並びになっていません (${root_type})")
      return 0
      ;;
  esac

  desc_type=$(fm_yq '.description | type' "${fm}")
  if [[ ${desc_type} != '!!str' && ${desc_type} != '!!null' ]]; then
    problems+=("${label}: description が文字列ではありません (${desc_type})")
  else
    desc=$(fm_yq '.description // ""' "${fm}")
    # 空白だけも無いのと同じ (Claude Code も trim して読む)
    if [[ -z ${desc//[[:space:]]/} ]]; then
      problems+=("${label}: description がありません。Claude はここを読んで、いつ使うかを決めます")
    else
      # 素の値 (引用符も block scalar も無い) の「 #」から先は YAML のコメントで、値から黙って消える。1 行の値と、複数行の
      # 最後の行で起きる (途中の行なら YAML として読めずに上で落ちる)
      dropped=$(fm_yq '.description | select(style == "") | line_comment' "${fm}")
      if [[ -n ${dropped} ]]; then
        problems+=("${label}: description の「 #」から先 (${dropped}) がコメントとして捨てられています。値に含めるなら >- の block scalar にするか引用符で囲んでください")
      fi
      # 文字で数える (yq の length はバイトを数え、bash の ${#…} も C ロケールではバイトを数える)
      desc_chars=$(fm_yq '.description | split("") | length' "${fm}")
      if ((desc_chars > 1024)); then
        notes+=("${label}: description が長すぎます (${desc_chars} 文字)。起動の判断のノイズになるので、1024 文字までに絞ってください")
      fi
    fi
  fi

  [[ -n ${want_name} ]] || return 0
  name_type=$(fm_yq '.name | type' "${fm}")
  if [[ ${name_type} != '!!str' && ${name_type} != '!!null' ]]; then
    problems+=("${label}: name が文字列ではありません (${name_type})")
    return 0
  fi
  fm_name=$(fm_yq '.name // ""' "${fm}")
  if [[ -z ${fm_name} ]]; then
    problems+=("${label}: name がありません")
  elif [[ ${fm_name} != "${want_name}" ]]; then
    problems+=("${label}: name が '${fm_name}' ですが、${want_what} '${want_name}' と同じにしてください")
  # 範囲 [a-z] はロケールで当たり方が変わりうるので、yq (Go の正規表現) で見る
  elif [[ $(fm_yq '.name | test("^[a-z0-9]+(-[a-z0-9]+)*$")' "${fm}") != true ]]; then
    problems+=("${label}: name '${fm_name}' は小文字ケバブケースにしてください")
  fi
}

found=0

# skills: <名前>/SKILL.md。直下には skill のディレクトリ (と README.md) だけを置く
for entry in "${claude_dir}"/skills/*; do
  [[ -e ${entry} ]] || continue
  entry_name=$(basename "${entry}")
  [[ ${entry_name} != README.md ]] || continue
  found=$((found + 1))
  if [[ ! -d ${entry} ]]; then
    problems+=("$(label_of "${entry}"): skills の直下にはディレクトリだけを置いてください")
    continue
  fi
  check_prefix "${entry_name}" "${entry}"
  if [[ ! -f ${entry}/SKILL.md ]]; then
    problems+=("$(label_of "${entry}"): SKILL.md がありません")
    continue
  fi
  check_md "${entry}/SKILL.md" "${entry_name}" "ディレクトリ名"
done

# agents: <名前>.md
for entry in "${claude_dir}"/agents/*.md; do
  [[ -e ${entry} ]] || continue
  entry_name=$(basename "${entry}" .md)
  [[ ${entry_name} != README ]] || continue
  found=$((found + 1))
  check_prefix "${entry_name}" "${entry}"
  check_md "${entry}" "${entry_name}" "ファイル名"
done

# commands: **/<名前>.md。name は見ず、呼び出し名の頭になるパスの先頭の要素を見る
command_files=()
if [[ -d ${claude_dir}/commands ]]; then
  mapfile -t command_files < <(find "${claude_dir}/commands" -type f -name '*.md' ! -path "${claude_dir}/commands/README.md" | sort)
fi
for entry in "${command_files[@]}"; do
  found=$((found + 1))
  cmd_head=${entry#"${claude_dir}/commands/"}
  cmd_head=${cmd_head%%/*}
  check_prefix "${cmd_head%.md}" "${entry}"
  check_md "${entry}" "" ""
done

if ((found == 0)); then
  echo "!! skill・agent・command が 1 つも見つかりません (${claude_dir} の skills・agents・commands)。" >&2
  exit 1
fi
if ((${#notes[@]} > 0)); then
  echo "!! 落としませんが、見直してください:" >&2
  printf '   %s\n' "${notes[@]}" >&2
fi
if ((${#problems[@]} > 0)); then
  echo "!! frontmatter に直すところがあります:" >&2
  printf '   %s\n' "${problems[@]}" >&2
  echo "   書き方は nix/files/claude/ の skills・agents・commands の README.md にあります。複数行の description は >- の" >&2
  echo "   block scalar で書くと、値に「: 」や「 #」が入っても崩れません。" >&2
  exit 1
fi
echo "skill・agent・command の frontmatter: ${found} 個とも通る"
