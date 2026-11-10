#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の herdr-app を入れる win/herdr-app/Install-HerdrApp.ps1 が写している、公式の install.ps1 (app と core) が、
# 写したときから変わっていないかを確かめる。
#
#   check-herdr-app-installers.sh [<記録のファイル>]
#
# 記録 (既定は repo の win/herdr-app/upstream-installers.txt) の 1 行は「<sha256>  <落とす URL>  <中身の履歴>」。
# # で始まる行と空行は読まない。URL ごとに curl で落とし、sha256 を記録と比べる。
#
# Install-HerdrApp.ps1 は公式の install.ps1 を流さずに、同じ置き場所・手順を自分で踏む。公式が置くもの・置き場所・
# 手順を変えると、入れるもの・外すもの (-Uninstall) が黙ってずれるので、中身が変わったら知らせ、差分を読んで合わせる
# (win/README.md の「公式の install.ps1 が変わったとき」)。
#
# GitHub Actions の herdr-app-installers (.github/workflows/herdr-app-installers.yml) が週 1 回と PR で流し、落ちる
# ことで知らせる。win/ は flake からは見えない (ADR 010) ので、flake check ではなく checkout の上で走らせる。手元でも打てる。
#
# 終了コード: 0 = 変わっていない、1 = 変わった (今の sha256 と、差分を読む所を出す)、2 = 確かめられなかった
# (記録が読めない・書き損じ・install.ps1 の行が無い・落とせない)。1 と 2 が両方あれば 1。GitHub Actions の中では、
# 落ちる理由を ::error の行にも出す (実行の画面の先頭に出る)。
#
# ## 依存
#
# bash・curl・sha256sum (coreutils)・mktemp。GitHub の ubuntu のランナーにはどれも最初から入っている。

set -eu -o pipefail

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")

usage() {
  cat <<'EOS'
herdr-app の公式の install.ps1 (app と core) が、Install-HerdrApp.ps1 に写したときから変わっていないかを確かめる。

使い方:
  check-herdr-app-installers.sh [<記録のファイル>]

  記録の既定は repo の win/herdr-app/upstream-installers.txt (1 行に「<sha256>  <URL>  <中身の履歴>」)。

終了コード: 0 = 変わっていない、1 = 変わった、2 = 確かめられなかった
EOS
}

args=()
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
    *) args+=("${arg}") ;;
  esac
done
if ((${#args[@]} > 1)); then
  usage >&2
  exit 2
fi
record=${args[0]:-${repo_dir}/win/herdr-app/upstream-installers.txt}

# GitHub Actions の中なら、落ちる理由を ::error の行にも出す (% と改行は workflow command の決まりでエスケープする)
annotate() {
  [[ ${GITHUB_ACTIONS-} == true ]] || return 0
  local msg=$1
  msg=${msg//'%'/'%25'}
  msg=${msg//$'\r'/'%0D'}
  msg=${msg//$'\n'/'%0A'}
  printf '::error title=herdr-app の公式の install.ps1::%s\n' "${msg}"
}

if [[ ! -r ${record} ]]; then
  echo "!! 記録が読めません: ${record}" >&2
  annotate "記録が読めません: ${record}"
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/check-herdr-app-installers.XXXXXX")
trap 'rm -rf "${work}"' EXIT

changed=0
broken=0
entries=0
lineno=0
while IFS= read -r line || [[ -n ${line} ]]; do
  lineno=$((lineno + 1))
  line=${line%$'\r'}
  if [[ -z ${line//[[:space:]]/} || ${line} == '#'* ]]; then
    continue
  fi
  read -r want url history extra <<<"${line}"
  if [[ ! ${want} =~ ^[0-9a-f]{64}$ || ! ${url} =~ ^https:// || ! ${history} =~ ^https:// || -n ${extra} ]]; then
    echo "!! 記録の ${lineno} 行目が「<sha256 (64 桁の小文字の hex)>  <https の URL>  <https の中身の履歴>」の形ではありません: ${line}" >&2
    annotate "記録の ${lineno} 行目の形が違います: ${line}"
    broken=1
    continue
  fi
  entries=$((entries + 1))
  file="${work}/${entries}"
  rc=0
  # while read が記録を読んでいるので、curl に stdin を渡さない
  curl -fsSL --max-time 60 -o "${file}" "${url}" </dev/null || rc=$?
  if ((rc != 0)); then
    echo "!! 落とせませんでした (curl の終了コード ${rc}): ${url}" >&2
    annotate "落とせませんでした (curl の終了コード ${rc}): ${url}"
    broken=1
    continue
  fi
  got=$(sha256sum "${file}")
  got=${got%% *}
  if [[ ${got} == "${want}" ]]; then
    echo "同じ: ${url} (${want:0:12}…)"
  else
    echo "!! 変わった: ${url}"
    echo "   記録の sha256: ${want}"
    echo "   今の sha256:   ${got}"
    echo "   差分を読む所:  ${history}"
    annotate "変わった: ${url} (今の sha256 は ${got})。差分は ${history} で読む"
    changed=1
  fi
done <"${record}"

if ((entries == 0 && broken == 0)); then
  echo "!! 記録に install.ps1 の行がありません: ${record}" >&2
  annotate "記録に install.ps1 の行がありません: ${record}"
  exit 2
fi
if ((changed)); then
  echo
  echo "公式の install.ps1 が変わりました。差分を読んで win/herdr-app/Install-HerdrApp.ps1 を合わせ (置くもの・外すもの・"
  echo "置き場所・手順)、記録の sha256 を今の値に書き換えます (合わせることが無くても書き換える)。"
  echo "手順は win/README.md の「公式の install.ps1 が変わったとき」。"
  exit 1
fi
if ((broken)); then
  exit 2
fi
echo "公式の install.ps1 は、記録したときから変わっていません (${entries} 本)。"
