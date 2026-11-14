#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows に固定した版で入れているものに、固定した版より新しい版が出ていないかを確かめて、短く知らせる。
# 冪等。`setup.sh --update` でも毎回走る。dotfiles.wsl.windowsFiles.enable = true のマシンが対象。新しい版があれば
# 名前ごとに 1 行と、上げるかを決める Claude Code の skill (pjp-dotfiles-win-pin-update) の名前を、setup の最後の
# 「警告のまとめ」に残す。確かめられなければ (gh が無い・ログインしていない・API の失敗) 1 行出して先へ進む。
#
# order: 97
#
# ^ setup.sh が読む実行順。Windows のアプリを揃える bootstrap と同じ 97 (どれも相手を使わない。この手順は Windows に
#   触らず、repo の固定した版と GitHub だけを見る)。衝突で exit 1 しうる bootstrap-windows-google-ime.sh (98) より前に
#   置き、それに止められないようにする。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows のアプリは版を固定して入れている (win/README.md の「固定した版より新しい版の知らせ」)。新しい版が出ても、今までは
# 各手順の ※ の行と、週 1 回の CI (猶予 30 日・7 日) でしか見えなかった。setup のたびに「新しい版がある」とだけ短く出し、
# Claude Code がそれを拾って、猶予ごとの上げ先の候補を出し、上げるか (どの版か・上げないか) をユーザーに聞けるようにする。
#
# ## 対象
#
#   名前                    固定した版                                   新しい版を出す口
#   openssh                 win/openssh/Install-OpenSSH.ps1              check-winget-version.sh --json
#   herdr                   win/herdr/Install-Herdr.ps1                  check-winget-version.sh --json
#   google-japanese-input   win/google-japanese-input/Install-*.ps1      check-winget-version.sh --json
#   ntn                     win/ntn/Install-Ntn.ps1                      check-winget-version.sh --json (windows-files.json の ntn)
#   claude-code             win/claude-code/Install-ClaudeCode.ps1       check-winget-version.sh --json (windows-files.json の claudeCode)
#   herdr-app・herdr-core   nix/pkgs/herdr-core/releases.json            check-herdr-app-version.sh --json (1 回で 2 つ)
#
# type-clipboard (自作のアプリ。公開からの猶予を置かず、Release を出す流れで上げる) と PowerToys (版を固定しない) は外す。
# 見送りの一覧 (各 skipped-versions.txt) にある版は知らせない。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json を読み、配らないマシンは飛ばす。ntn・claudeCode が false の名前は確かめない
#    (欄が無い前の世代は true と読む)
# 2. gh が無い・ログインしていないなら、確かめられないと 1 行出して exit 0
# 3. 名前ごとに上の口を出た日なしで呼び (60 秒で打ち切る)、見送っていない新しい版があれば「<題>: <固定した版> → <新しい版>」を
#    出す。警告のまとめには、skill の名前を書いた見出しと、その続きの行として残す。新しい版が無ければ 1 行だけ (まとめには
#    残さない)。確かめられなかった名前は、わけを添えて 1 行出し、まとめにも残す。どれも exit 0 (setup を止めない)
#
# ## --candidates (skill が打つ)
#
#   bootstrap-windows-pin-updates.sh --candidates [--grace 1,3,7] [<名前>…]
#
# windows-files.json によらず、名前 (省けば全部) ごとに出た日つきで呼び、新しい版 (出た日・何日前・URL、見送った版は理由)、
# 猶予ごとの上げ先 (猶予の日数以上たった、見送っていない新しい版のうち、いちばん新しいもの。出た日の分からない版は選ばない)、
# 上げ方の README の節と見送りの一覧の場所を出す。確かめられない名前があれば、出せるものを出したうえで exit 2。

set -eu -o pipefail

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null || exit
  pwd -P
)
state_file="${HOME}/.local/state/dotfiles/windows-files.json"
all_names=(openssh herdr google-japanese-input ntn claude-code herdr-app herdr-core)
skill=pjp-dotfiles-win-pin-update

usage() {
  cat <<'EOS'
Windows に固定した版で入れているものに、固定した版より新しい版が出ていないかを確かめて、短く知らせる。

使い方:
  bootstrap-windows-pin-updates.sh                                        確かめて知らせる (setup の手順)
  bootstrap-windows-pin-updates.sh --candidates [--grace 1,3,7] [<名前>…]  猶予ごとの上げ先の候補を出す

  名前: openssh・herdr・google-japanese-input・ntn・claude-code・herdr-app・herdr-core (省けば全部)
EOS
}

candidates=0
graces=1,3,7
names=()
while (($#)); do
  case $1 in
    --candidates) candidates=1 ;;
    --grace)
      if (($# < 2)); then
        echo "--grace には日数を , で区切って渡します (例: --grace 1,3,7)。" >&2
        exit 2
      fi
      graces=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "不明な引数です: $1" >&2
      usage >&2
      exit 2
      ;;
    *) names+=("$1") ;;
  esac
  shift
done
if ((! candidates && (${#names[@]} > 0))); then
  echo "名前は --candidates と一緒に渡します。" >&2
  usage >&2
  exit 2
fi
if [[ ! ${graces} =~ ^[0-9]+(,[0-9]+)*$ ]]; then
  echo "--grace の日数が読めません: ${graces} (例: 1,3,7)" >&2
  exit 2
fi
for n in "${names[@]}"; do
  if [[ " ${all_names[*]} " != *" ${n} "* ]]; then
    echo "知らない名前です: ${n} (${all_names[*]} のどれか)" >&2
    exit 2
  fi
done

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

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-pin-updates.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

# 名前 $1 の新しい版の JSON を ${tmp}/<名前>.json に、エラーの出力を ${tmp}/<名前>.err に書く。$2: 打ち切る秒数、
# $3: 1 なら出た日も引く。確かめられなければ 1 を返す。herdr-app と herdr-core は 1 回の呼び出しで 2 つを書く
fetch() {
  local name=$1 limit=$2 dates=$3 rc=0 flag=()
  if ((dates)); then
    flag=(--dates)
  fi
  case ${name} in
    herdr-app | herdr-core)
      if [[ ! -e ${tmp}/herdr-app.done ]]; then
        : >"${tmp}/herdr-app.done"
        timeout "${limit}" "${BASH}" "${script_dir}/check-herdr-app-version.sh" --json "${flag[@]}" \
          >"${tmp}/herdr-app.lines" 2>"${tmp}/herdr-app.err" </dev/null || rc=$?
        if ((rc == 0)); then
          jq -c 'select(.name == "herdr-app")' "${tmp}/herdr-app.lines" >"${tmp}/herdr-app.json" 2>/dev/null || true
          jq -c 'select(.name == "herdr-core")' "${tmp}/herdr-app.lines" >"${tmp}/herdr-core.json" 2>/dev/null || true
        fi
        cp "${tmp}/herdr-app.err" "${tmp}/herdr-core.err"
      fi
      ;;
    *)
      timeout "${limit}" "${BASH}" "${script_dir}/check-winget-version.sh" --json "${flag[@]}" "${name}" \
        >"${tmp}/${name}.json" 2>"${tmp}/${name}.err" </dev/null || rc=$?
      ;;
  esac
  # 出力が JSON の 1 つでなければ (打ち切られた・壊れた)、確かめられなかったことにする
  if [[ ! -s ${tmp}/${name}.json ]] || ! jq -e 'type == "object" and has("newer")' "${tmp}/${name}.json" &>/dev/null; then
    if [[ ! -s ${tmp}/${name}.err ]]; then
      if ((rc == 124)); then
        echo "${limit} 秒で返らなかった" >"${tmp}/${name}.err"
      else
        echo "終了コード ${rc}" >"${tmp}/${name}.err"
      fi
    fi
    return 1
  fi
  return 0
}

# 確かめられなかったわけを 1 行にする ($1: 名前)。!! と字下げを落とし、空でない最初の 2 行を「 / 」でつなぐ
reason_of() {
  local line out='' n=0
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line#'!! '}
    line=${line#"${line%%[![:space:]]*}"}
    [[ -n ${line} ]] || continue
    out+="${out:+ / }${line}"
    n=$((n + 1))
    if ((n == 2)); then
      break
    fi
  done <"${tmp}/$1.err"
  printf '%s' "${out}"
}

# ---------------------------------------------------------------------------
# --candidates: 猶予ごとの上げ先の候補
# ---------------------------------------------------------------------------
if ((candidates)); then
  if ((${#names[@]} == 0)); then
    names=("${all_names[@]}")
  fi
  if ! command -v gh &>/dev/null; then
    echo "gh が見つかりません (新しい版と出た日は GitHub API で読む)。home-manager switch を実行してください。" >&2
    exit 2
  fi
  failed=()
  quiet=()
  for name in "${names[@]}"; do
    if ! fetch "${name}" 180 1; then
      failed+=("${name}")
      continue
    fi
    # 見送っていない新しい版が無い名前は、最後に 1 行でまとめる
    if jq -e '[.newer[] | select(.skipped == null)] | length == 0' "${tmp}/${name}.json" >/dev/null; then
      quiet+=("$(jq -r '"\(.title) (\(.pinned))"' "${tmp}/${name}.json")")
      continue
    fi
    jq -r --arg name "${name}" --arg graces "${graces}" '
      def when: if .published == null then "出た日が分からない" else "\(.published) に出た、\(.age) 日前" end;
      . as $p
      | [.newer[] | select(.skipped == null)] as $u
      | "■ \(.title) (\($name))",
        "  固定した版 : \(.pinned) (\(.pinnedFile))",
        ( .newer | to_entries[]
          | (if .key == 0 then "  新しい版   : " else "               " end)
            + .value.version + " ("
            + (if .value.skipped != null then "見送った: " + .value.skipped else (.value | when) end) + ")"
            + (if .value.url != null and .value.skipped == null then "  " + .value.url else "" end) ),
        ( $graces | split(",") | map(tonumber)[] as $g
          | ([$u[] | select(.age != null and .age >= $g)] | last) as $c
          | "  猶予 \($g) 日 : "
            + (if $c == null then "無い (\($g) 日たった新しい版は無い)" else $c.version end) ),
        ( if $p.datesProblem != null then "  ※ 出た日を確かめられなかった: \($p.datesProblem)" else empty end ),
        ( if $p.pinnedListed == false then "  ※ 固定した版が一覧に無い (CI の知らせを見る)" else empty end ),
        "  上げ方     : win/README.md の「\(.readmeSection)」。見送るなら \(.skippedFile) に足す (書き方はそのファイルの頭)",
        ""' "${tmp}/${name}.json"
  done
  if ((${#quiet[@]})); then
    printf '新しい版は無い (見送った版を除く): %s\n' "$(printf '%s・' "${quiet[@]}" | sed 's/・$//')"
  fi
  if ((${#failed[@]})); then
    for name in "${failed[@]}"; do
      echo "!! ${name} は確かめられなかった: $(reason_of "${name}")" >&2
    done
    exit 2
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# setup の手順: 新しい版があれば短く知らせる
# ---------------------------------------------------------------------------
if [[ ! -r ${state_file} ]]; then
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
# ntn・Claude Code は、入れないマシンでは確かめない (欄が無い前の世代は入れる。jq の // は false も置き換えるので使わない)
names=()
for n in "${all_names[@]}"; do
  case ${n} in
    ntn) key=ntn ;;
    claude-code) key=claudeCode ;;
    *) key='' ;;
  esac
  if [[ -n ${key} && $(jq -r --arg k "${key}" 'if has($k) then .[$k] else true end' "${state_file}") != true ]]; then
    continue
  fi
  names+=("${n}")
done

if ! command -v gh &>/dev/null; then
  warn "Windows に固定した版より新しい版があるかを確かめられませんでした (gh が見つからない。home-manager switch の後に流し直す)。"
  exit 0
fi
if ! gh auth token &>/dev/null; then
  warn "Windows に固定した版より新しい版があるかを確かめられませんでした (gh にログインしていない。gh auth login の後に流し直す)。"
  exit 0
fi

newer_lines=()
failed=()
for name in "${names[@]}"; do
  if ! fetch "${name}" 60 0; then
    failed+=("${name}")
    continue
  fi
  line=$(jq -r '
    [.newer[] | select(.skipped == null) | .version] as $n
    | if ($n | length) == 0 then empty
      elif ($n | length) <= 3 then "\(.title): \(.pinned) → \($n | join("・"))"
      else "\(.title): \(.pinned) → \($n[0])・…・\($n[-1]) (新しい版 \($n | length) 個)"
      end' "${tmp}/${name}.json")
  if [[ -n ${line} ]]; then
    newer_lines+=("${line}")
  fi
done

if ((${#newer_lines[@]})); then
  warn "Windows に固定した版より新しい版があります → Claude Code の ${skill} skill で、上げるか (どの版か) を決める" \
    "${newer_lines[@]}"
elif ((${#failed[@]} == 0)); then
  echo "Windows に固定した版より新しい版は無い (見送った版を除く。確かめたもの: $(printf '%s・' "${names[@]}" | sed 's/・$//'))。"
fi
if ((${#failed[@]})); then
  warn "Windows に固定した版より新しい版があるかを確かめられなかったもの: $(printf '%s・' "${failed[@]}" | sed 's/・$//') ($(reason_of "${failed[0]}"))。setup は続けます。"
fi
exit 0
