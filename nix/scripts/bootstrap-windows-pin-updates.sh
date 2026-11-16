#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows に固定した版で入れているものに、固定した版より新しい版が出ていないかを確かめて、短く知らせる。
# 冪等。`setup.sh --update` でも毎回走る。dotfiles.wsl.windowsFiles.enable = true のマシンが対象。新しい版があれば
# 名前ごとに 1 行と、上げるかを決める頼み方 (Claude Code に「dotfiles の Windows に固定した版を上げて」と頼む) を、setup の
# 最後の「警告のまとめ」に残す。確かめられなければ (gh が無い・ログインしていない・API の失敗) 1 行出して先へ進む。
# 依存の更新の skill が読む JSON の口 (--list --json・--candidates --json) も持つ (下の「JSON の口」)。
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
# Claude Code に頼めば、猶予ごとの上げ先の候補を出して、上げるか (どの版か・上げないか) をユーザーに聞けるようにする。
# 候補は、repo の拡張 (.claude/skills/pjp-dotfiles-deps/。設定の deps.toml の [[pins]] の windows) が指す JSON の口から出る。
#
# ## 対象
#
#   名前                    固定した版                                   新しい版を出す口
#   openssh                 win/openssh/Install-OpenSSH.ps1              check-winget-version.sh --json
#   herdr                   win/herdr/Install-Herdr.ps1                  check-winget-version.sh --json
#   google-japanese-input   win/google-japanese-input/Install-*.ps1      check-winget-version.sh --json
#   ntn                     win/ntn/Install-Ntn.ps1                      check-winget-version.sh --json (windows-files.json の ntn)
#   claude-code             win/claude-code/Install-ClaudeCode.ps1       check-winget-version.sh --json (windows-files.json の claudeCode)
#   git・gh・vs-buildtools・rustup
#                           win/bootstrap/Install-Bootstrap.ps1          check-winget-version.sh --json (Windows の ghq に dotfiles の clone
#                                                                         があるマシンだけ。下の「何をするか」の 1)
#   herdr-app・herdr-core   nix/pkgs/herdr-core/releases.json            check-herdr-app-version.sh --json (1 回で 2 つ)
#
# type-clipboard と op-reason (どちらも自作のアプリ。公開からの猶予を置かず、Release を出す流れで上げる) と PowerToys (版を
# 固定しない) は外す。
# 見送りの一覧 (各 skipped-versions.txt) にある版は知らせない。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json を読み、配らないマシンは飛ばす。ntn・claudeCode が false の名前は確かめない
#    (欄が無い前の世代は true と読む)。herdr・herdr-app・herdr-core は、~/.local/state/dotfiles/group.json (設定グループ。
#    home/modules/group.nix) の tools.windowsHerdr (dotfiles.wsl.windowsFiles.herdr.enable) が false なら確かめない (ファイル・欄が
#    無い前の世代は true と読む。windows-files.json に欄を足すと、今までのホストのそのファイルまで変わるので group.json に置いた)。
#    bootstrap が入れる 4 つ (git・gh・vs-buildtools・rustup) は、Windows で bootstrap を流したマシン (windows-files.json の windowsHome の
#    下に ghq/github.com/pollenjp/dotfiles/.git がある) だけ確かめる (入れていない道具の版を知らせない。dotfiles-private の
#    docs/adr/058_win_runner_bootstrap_*)
# 2. gh が無い・ログインしていないなら、確かめられないと 1 行出して exit 0
# 3. 名前ごとに上の口を出た日なしで呼び (60 秒で打ち切る)、見送っていない新しい版があれば「<題>: <固定した版> → <新しい版>」を
#    出す。警告のまとめには、頼み方を書いた見出しと、その続きの行として残す。新しい版が無ければ 1 行だけ (まとめには
#    残さない)。確かめられなかった名前は、わけを添えて 1 行出し、まとめにも残す。どれも exit 0 (setup を止めない)
#
# ## --candidates (人が読む)
#
#   bootstrap-windows-pin-updates.sh --candidates [--grace 1,3,7] [<名前>…]
#
# windows-files.json・group.json によらず、名前 (省けば全部) ごとに出た日つきで呼び、新しい版 (出た日・何日前・URL、
# 見送った版は理由)、猶予ごとの上げ先 (猶予の日数以上たった、見送っていない新しい版のうち、いちばん新しいもの。出た日の
# 分からない版は選ばない)、上げ方の README の節と見送りの一覧の場所を出す。確かめられない名前があれば、出せるものを出した
# うえで exit 2。
#
# ## JSON の口 (--list --json・--candidates --json)
#
# repo の拡張の設定 (.claude/skills/pjp-dotfiles-deps/deps.toml の [[pins]] の windows) が指す口。依存の更新の skill が repo の
# root で打ち、stdout の JSON 1 つを読む。形は読む側との約束 (ADR 056) で、項目を足す・変えるときは読む側と揃える。
#
#   bootstrap-windows-pin-updates.sh --list --json [<名前>…]                         固定した版と ID だけ (ネットワークを使わない)
#   bootstrap-windows-pin-updates.sh --candidates --json [--grace 1,3,7] [<名前>…]   新しい版と、猶予ごとの上げ先も
#
#   {"version": 1, "items": [
#     {"name", "title", "files": [repo の root からのパス], "pinned", "winget_id": 文字列 | null, "skip_file": 文字列 | null,
#      "candidates": [{"version", "published": "YYYY-MM-DD" | null, "age_days": 日数 | null, "url", "skipped": 理由 | null}],
#      "targets": {"<猶予の日数>": 版 | null},
#      "error": 文字列 | null}]}
#
# - candidates と targets は --candidates のときだけ。candidates は固定した版より新しい版を古い順に並べる (見送った版も理由
#   つきで入れる)。published・age_days は、出た日の分からない版 (見送った版の多く・release と突き合わせられない版) で null。
#   url はいつも文字列 (release notes などが無い版は winget-pkgs の manifest のディレクトリ)。targets は --candidates の上げ先と
#   同じ選び方で、日数ごとに版か null
# - winget_id は winget で入れないもの (herdr-app・herdr-core) で null。files は版を書くファイル (ps1 か releases.json)
# - 確かめられなかった名前は error にわけを書き、ほかの名前は出したうえで exit 2 (stdout の JSON は読める)。ps1 が読めない
#   名前は title が名前・files が []・pinned が ""・winget_id と skip_file が null。出た日を確かめられなかった名前・gh が
#   無いときは candidates が []・targets が全部 null
# - windows-files.json・group.json は見ない (repo が固定しているもの全部。このマシンが設定グループで入れない名前も出す)。
#   --list は jq だけで動き、gh もネットワークも使わない (固定した版は check の口の --json --offline で読む)

set -eu -o pipefail

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null || exit
  pwd -P
)
state_file="${HOME}/.local/state/dotfiles/windows-files.json"
group_file="${HOME}/.local/state/dotfiles/group.json"
all_names=(openssh herdr google-japanese-input ntn claude-code git gh vs-buildtools rustup herdr-app herdr-core)

usage() {
  cat <<'EOS'
Windows に固定した版で入れているものに、固定した版より新しい版が出ていないかを確かめて、短く知らせる。

使い方:
  bootstrap-windows-pin-updates.sh                                               確かめて知らせる (setup の手順)
  bootstrap-windows-pin-updates.sh --candidates [--grace 1,3,7] [<名前>…]         猶予ごとの上げ先の候補を出す
  bootstrap-windows-pin-updates.sh --candidates --json [--grace 1,3,7] [<名前>…]  同じものを JSON で出す
  bootstrap-windows-pin-updates.sh --list --json [<名前>…]                        固定した版を JSON で出す (ネットワークを使わない)

  名前: openssh・herdr・google-japanese-input・ntn・claude-code・git・gh・vs-buildtools・rustup・herdr-app・herdr-core (省けば全部)
EOS
}

candidates=0
list=0
json=0
graces=1,3,7
names=()
while (($#)); do
  case $1 in
    --candidates) candidates=1 ;;
    --list) list=1 ;;
    --json) json=1 ;;
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
if ((candidates && list)); then
  echo "--candidates と --list は一緒に使えません。" >&2
  usage >&2
  exit 2
fi
if ((list && ! json)); then
  echo "--list は --json と一緒に使います。" >&2
  usage >&2
  exit 2
fi
if ((json && ! candidates && ! list)); then
  echo "--json は --candidates か --list と一緒に使います。" >&2
  usage >&2
  exit 2
fi
if ((! candidates && ! list && (${#names[@]} > 0))); then
  echo "名前は --candidates か --list と一緒に渡します。" >&2
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

# 名前 $1 の固定した版の JSON (check の口の --json --offline。ネットワークを使わない) を ${tmp}/<名前>.local.json に、エラーの
# 出力を ${tmp}/<名前>.local.err に書く。読めなければ 1 を返す。herdr-app と herdr-core は 1 回の呼び出しで 2 つを書く
fetch_local() {
  local name=$1 rc=0
  case ${name} in
    herdr-app | herdr-core)
      if [[ ! -e ${tmp}/herdr-app.local.done ]]; then
        : >"${tmp}/herdr-app.local.done"
        "${BASH}" "${script_dir}/check-herdr-app-version.sh" --json --offline \
          >"${tmp}/herdr-app.local.lines" 2>"${tmp}/herdr-app.local.err" </dev/null || rc=$?
        if ((rc == 0)); then
          jq -c 'select(.name == "herdr-app")' "${tmp}/herdr-app.local.lines" >"${tmp}/herdr-app.local.json" 2>/dev/null || true
          jq -c 'select(.name == "herdr-core")' "${tmp}/herdr-app.local.lines" >"${tmp}/herdr-core.local.json" 2>/dev/null || true
        elif [[ ! -s ${tmp}/herdr-app.local.err ]]; then
          echo "終了コード ${rc}" >"${tmp}/herdr-app.local.err"
        fi
        cp "${tmp}/herdr-app.local.err" "${tmp}/herdr-core.local.err"
      fi
      ;;
    *)
      "${BASH}" "${script_dir}/check-winget-version.sh" --json --offline "${name}" \
        >"${tmp}/${name}.local.json" 2>"${tmp}/${name}.local.err" </dev/null || rc=$?
      ;;
  esac
  if [[ ! -s ${tmp}/${name}.local.json ]] || ! jq -e 'type == "object" and has("pinned")' "${tmp}/${name}.local.json" &>/dev/null; then
    if [[ ! -s ${tmp}/${name}.local.err ]]; then
      echo "終了コード ${rc}" >"${tmp}/${name}.local.err"
    fi
    return 1
  fi
  return 0
}

# 確かめられなかったわけを 1 行にする ($1: ${tmp} の中のエラーの出力の名前。<名前> か <名前>.local)。!! と字下げを落とし、
# 空でない最初の 2 行を「 / 」でつなぐ
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
# JSON の口: --list --json と --candidates --json
# ---------------------------------------------------------------------------
if ((json)); then
  if ((${#names[@]} == 0)); then
    names=("${all_names[@]}")
  fi
  have_gh=1
  if ((candidates)) && ! command -v gh &>/dev/null; then
    have_gh=0
  fi
  failed=0
  : >"${tmp}/items.jsonl"
  for name in "${names[@]}"; do
    # 確かめられなかったときの項目の頭 (固定した版を読めれば、その値で埋める)
    base_ok=1
    if ! fetch_local "${name}"; then
      base_ok=0
    fi
    error=''
    if ((! base_ok)); then
      error=$(reason_of "${name}.local")
    elif ((candidates && ! have_gh)); then
      error='gh が見つからない (新しい版と出た日は GitHub API で読む。home-manager switch の後に流し直す)'
    elif ((candidates)); then
      if ! fetch "${name}" 180 1; then
        error=$(reason_of "${name}")
      elif problem=$(jq -er '.datesProblem // empty' "${tmp}/${name}.json"); then
        error="出た日を確かめられなかった: ${problem}"
      fi
    fi
    if [[ -n ${error} ]]; then
      failed=1
      if ((base_ok)); then
        base="${tmp}/${name}.local.json"
      else
        base="${tmp}/${name}.none.json"
        jq -cn --arg name "${name}" '{name: $name, title: $name, pinnedFile: null, pinned: "", packageId: null, skippedFile: null}' >"${base}"
      fi
      jq -c --arg name "${name}" --arg error "${error}" --arg graces "${graces}" --argjson candidates "${candidates}" '
        { name: $name, title, files: ([.pinnedFile] | map(select(. != null))), pinned, winget_id: .packageId,
          skip_file: .skippedFile }
        + (if $candidates == 1 then
             { candidates: [],
               targets: (reduce ($graces | split(",")[] | tonumber) as $g ({}; .[$g | tostring] = null)) }
           else {} end)
        + { error: $error }' "${base}" >>"${tmp}/items.jsonl"
      continue
    fi
    if ((list)); then
      jq -c --arg name "${name}" '{
        name: $name, title, files: [.pinnedFile], pinned, winget_id: .packageId, skip_file: .skippedFile, error: null
      }' "${tmp}/${name}.local.json" >>"${tmp}/items.jsonl"
      continue
    fi
    # --candidates --json: 新しい版と、猶予ごとの上げ先 (--candidates と同じ選び方)
    jq -c --arg name "${name}" --arg graces "${graces}" '
      def manifest_dir: "https://github.com/microsoft/winget-pkgs/tree/master/manifests/"
        + (.packageId[0:1] | ascii_downcase) + "/" + (.packageId | gsub("\\."; "/"));
      . as $p
      | [.newer[] | select(.skipped == null)] as $u
      | { name: $name, title, files: [.pinnedFile], pinned, winget_id: .packageId, skip_file: .skippedFile,
          candidates: [ .newer[]
            | { version, published, age_days: .age,
                url: (.url // (if $p.packageId != null then ($p | manifest_dir) + "/" + .version else "" end)),
                skipped } ],
          targets: (reduce ($graces | split(",")[] | tonumber) as $g ({};
            .[$g | tostring] = ([$u[] | select(.age != null and .age >= $g)] | last | .version? // null))),
          error: null }' "${tmp}/${name}.json" >>"${tmp}/items.jsonl"
  done
  jq -s '{version: 1, items: .}' "${tmp}/items.jsonl"
  if ((failed)); then
    exit 2
  fi
  exit 0
fi

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
# ntn・Claude Code は、入れないマシンでは確かめない (欄が無い前の世代は入れる。jq の // は false も置き換えるので使わない)。
# herdr・herdr-app・herdr-core は group.json の tools.windowsHerdr で決める (ファイル・欄が無い前の世代は入れる)
windows_herdr=true
if [[ -r ${group_file} ]]; then
  windows_herdr=$(jq -r 'if (.tools | type) == "object" and (.tools | has("windowsHerdr")) then .tools.windowsHerdr | tostring else "true" end' \
    "${group_file}" 2>/dev/null) || windows_herdr=true
fi
# bootstrap が入れる 4 つは、Windows で bootstrap を流した (Windows の ghq に dotfiles の clone がある) マシンでだけ確かめる
windows_home=$(jq -r '.windowsHome // empty' "${state_file}")
bootstrapped=0
if [[ -n ${windows_home} && -e ${windows_home}/ghq/github.com/pollenjp/dotfiles/.git ]]; then
  bootstrapped=1
fi
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
  case ${n} in
    herdr | herdr-app | herdr-core)
      [[ ${windows_herdr} != false ]] || continue
      ;;
    git | gh | vs-buildtools | rustup)
      ((bootstrapped)) || continue
      ;;
  esac
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
  warn "Windows に固定した版より新しい版があります → Claude Code に「dotfiles の Windows に固定した版を上げて」と頼み、上げるか (どの版か) を決める" \
    "${newer_lines[@]}"
elif ((${#failed[@]} == 0)); then
  echo "Windows に固定した版より新しい版は無い (見送った版を除く。確かめたもの: $(printf '%s・' "${names[@]}" | sed 's/・$//'))。"
fi
if ((${#failed[@]})); then
  warn "Windows に固定した版より新しい版があるかを確かめられなかったもの: $(printf '%s・' "${failed[@]}" | sed 's/・$//') ($(reason_of "${failed[0]}"))。setup は続けます。"
fi
exit 0
