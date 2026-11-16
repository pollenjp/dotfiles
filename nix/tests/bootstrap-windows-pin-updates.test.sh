#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-pin-updates.sh の振る舞いを、使い捨ての HOME と、偽の check-winget-version.sh・
# check-herdr-app-version.sh・gh で確かめる。
#
#   bash nix/tests/bootstrap-windows-pin-updates.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-pin-updates-test) が Nix のサンドボックスで流す。ネットワークには出ない
# (新しい版の JSON は、偽の check-*.sh がケースごとの fixture から返す)。使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・windows-files.json が無いときは何も呼ばずに飛ばす。ntn・claudeCode が false の名前は確かめない
#     (欄が無い前の世代は確かめる)
#   - group.json (設定グループ) の tools.windowsHerdr が false なら herdr・herdr-app・herdr-core を確かめず、ほかの名前は確かめる。
#     true なら確かめる (group.json が無い前の世代も確かめる)
#   - --candidates と --list --json は group.json を見ず、tools.windowsHerdr が false のマシンでも herdr・herdr-app・herdr-core を出す
#   - bootstrap の 4 つ (git・gh・vs-buildtools・rustup。win/bootstrap/Install-Bootstrap.ps1) は、setup の手順では Windows の ghq に
#     dotfiles の clone がある (<windowsHome>/ghq/github.com/pollenjp/dotfiles/.git がある) マシンでだけ確かめる。--candidates と
#     --list --json はいつも出す
#   - gh が無い・ログインしていないときは、確かめられないと 1 行出して exit 0 (まとめにも残す)
#   - 見送っていない新しい版があれば、名前ごとに「<題>: <固定した版> → <新しい版>」(4 つ以上は頭と末尾と個数) を出し、
#     警告のまとめに頼み方 (Claude Code に「dotfiles の Windows に固定した版を上げて」と頼む) を書いた見出しと続きの行で残す。
#     出た日は引かない (--dates を付けない)。herdr-app と herdr-core は 1 回の呼び出しで読む
#   - 新しい版が無い・見送った版だけなら「無い」の 1 行で、まとめには残さない
#   - 確かめられない名前 (口が 2 で終わる・JSON でない) はわけを添えて 1 行出し、まとめにも残す。ほかの名前は知らせる。
#     どれも exit 0
#   - --candidates は windows-files.json によらず、出た日つき (--dates) で呼び、新しい版・猶予ごとの上げ先 (猶予以上たった、
#     見送っていない版のうち一番新しいもの。出た日の分からない版は選ばない)・上げ方を出す。新しい版の無い名前は最後に
#     1 行でまとめる。--grace で日数を変えられる。確かめられない名前があれば、ほかを出したうえで exit 2
#   - --list --json は gh が無くても動き、check の口を --json --offline で呼ぶ (ネットワークを使わない。--dates も付けない)。
#     名前ごとの name・title・files・pinned・winget_id・skip_file・error を {"version": 1, "items": […]} で出して exit 0
#     (windows-files.json は見ない)。名前を渡せば、その名前だけを出す
#   - --list --json で固定した版を読めない名前は、error にわけを書き (title は名前・files は []・pinned は ""・winget_id と
#     skip_file は null)、ほかの名前は出したうえで exit 2
#   - --candidates --json は、--dates で読んだ新しい版を candidates に古い順に入れ (age は age_days に。url の無い版は
#     winget-pkgs の manifest のディレクトリ)、猶予ごとの上げ先を targets (日数の文字列から版か null) に入れる。見送った版も
#     理由つきで入れて上げ先にはせず、出た日の分からない版は published・age_days を null にして上げ先にしない。--grace の
#     日数は数に読み直して key にする (07 は 7)。winget で入れないもの (herdr-app・herdr-core) は winget_id が null
#   - --candidates --json で確かめられない名前 (口が落ちる・出た日を確かめられない・gh が無い) は、error にわけを書いて
#     candidates を []・targets を全部 null にし、ほかの名前は出したうえで exit 2。gh が無ければ新しい版の口は呼ばない
#   - 知らない名前・--candidates か --list の無い名前・読めない --grace・知らない引数・--json の無い --list・--candidates か
#     --list の無い --json・--candidates と --list の両方は exit 2 (口は呼ばない)
#
# ## 本物の口と gh を見せない
#
# script は隣の check-winget-version.sh・check-herdr-app-version.sh を呼ぶので、script を使い捨てのディレクトリへ写し、
# その隣に偽物を置く。gh も偽物だけを並べた PATH で流す (本物の GitHub API を呼ばない)。偽物の shebang は $BASH から作る
# (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-pin-updates.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-pin-updates-test.XXXXXX")
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

# 要るコマンドだけを並べた PATH (gh は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed cat cp head tail mktemp rm dirname timeout tr sort mkdir; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 新しい版の JSON (check-winget-version.sh --json と同じ形)。$1: name、$2: title、$3: 固定した版、残り: 新しい版
# 「版|見送った理由|出た日|日数[|nourl]」(空の欄は null。5 つ目に nourl と書くと url を null にする)。packageId は名前ごとの
# 本物の ID (herdr-app・herdr-core は null)
pin_json() {
  local name=$1 title=$2 pinned=$3 e v reason day age nourl items='[]' id=''
  shift 3
  case ${name} in
    openssh) id=Microsoft.OpenSSH.Preview ;;
    herdr) id=Herdr.Herdr ;;
    google-japanese-input) id=Google.JapaneseIME ;;
    ntn) id=Notion.ntn ;;
    claude-code) id=Anthropic.ClaudeCode ;;
    git) id=Git.Git ;;
    gh) id=GitHub.cli ;;
    vs-buildtools) id=Microsoft.VisualStudio.2022.BuildTools ;;
    rustup) id=Rustlang.Rustup ;;
  esac
  for e in "$@"; do
    IFS='|' read -r v reason day age nourl <<<"${e}"
    items=$(jq -c --arg v "${v}" --arg reason "${reason}" --arg day "${day}" --arg age "${age}" --arg nourl "${nourl}" '. + [{
      version: $v,
      skipped: (if $reason == "" then null else $reason end),
      published: (if $day == "" then null else $day end),
      age: (if $age == "" then null else ($age | tonumber) end),
      url: (if $nourl == "nourl" then null else "https://example.invalid/" + $v end)
    }]' <<<"${items}")
  done
  jq -cn --arg name "${name}" --arg title "${title}" --arg pinned "${pinned}" --arg id "${id}" --argjson newer "${items}" '{
    name: $name, title: $title, packageId: (if $id == "" then null else $id end), pinned: $pinned,
    pinnedFile: ("win/" + $name + "/Install-X.ps1"),
    skippedFile: ("win/" + $name + "/skipped-versions.txt"), pinnedListed: true, readmeSection: ($title + " の新しい版が出たとき"),
    datesFrom: "github", datesChecked: true, datesProblem: null, newer: $newer
  }'
}

# 1 ケースぶんの場所を作る。$1: 名前、$2: windows-files.json の中身 (空なら作らない)。
# 写した script と偽の口は <case>/scripts、偽の gh は <case>/bin、fixture は <case>/json/<name>.json (無ければ新しい版なし)・
# <case>/rc/<name> (口の終了コード)・<case>/err/<name> (口の stderr)。--offline (固定した版だけ) の口は json/<name>.json から
# 引かないものを null にして返し、<case>/rc-local/<name>・<case>/err-local/<name> で落とせる
new_case() {
  local d="${work}/$1" n
  mkdir -p "${d}/home/.local/state/dotfiles" "${d}/scripts" "${d}/bin" "${d}/json" "${d}/rc" "${d}/err" "${d}/rc-local" "${d}/err-local"
  if [[ -n $2 ]]; then
    printf '%s\n' "$2" >"${d}/home/.local/state/dotfiles/windows-files.json"
  fi
  cp "${script}" "${d}/scripts/bootstrap-windows-pin-updates.sh"
  for n in openssh herdr google-japanese-input ntn claude-code git gh vs-buildtools rustup; do
    pin_json "${n}" "Windows の ${n}" 1.0.0 >"${d}/json/${n}.json"
  done
  pin_json herdr-app "Windows の herdr-app" 0.1.0 >"${d}/json/herdr-app.json"
  pin_json herdr-core herdr-core 0.1.0 >"${d}/json/herdr-core.json"
  # 偽の check-winget-version.sh。引数を記録し、名前 (最後の引数) の fixture を返す。--offline なら固定した版だけの形にする
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf 'winget %s\n' "$*" >>"${FAKE_DIR}/calls"
name=${*: -1}
if [[ " $* " == *' --offline '* ]]; then
  [[ ! -f ${FAKE_DIR}/err-local/${name} ]] || cat "${FAKE_DIR}/err-local/${name}" >&2
  rc=0
  [[ ! -f ${FAKE_DIR}/rc-local/${name} ]] || rc=$(<"${FAKE_DIR}/rc-local/${name}")
  if [[ ${rc} == 0 ]]; then
    jq -c '.newer = null | .pinnedListed = null | .datesChecked = false | .datesProblem = null' "${FAKE_DIR}/json/${name}.json"
  fi
  exit "${rc}"
fi
[[ ! -f ${FAKE_DIR}/err/${name} ]] || cat "${FAKE_DIR}/err/${name}" >&2
rc=0
[[ ! -f ${FAKE_DIR}/rc/${name} ]] || rc=$(<"${FAKE_DIR}/rc/${name}")
if [[ ${rc} == 0 ]]; then
  cat "${FAKE_DIR}/json/${name}.json"
fi
exit "${rc}"
EOF
  } >"${d}/scripts/check-winget-version.sh"
  # 偽の check-herdr-app-version.sh。引数を記録し、app と core の 2 行を返す。--offline なら固定した版だけの形にする
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf 'herdr-app %s\n' "$*" >>"${FAKE_DIR}/calls"
if [[ " $* " == *' --offline '* ]]; then
  [[ ! -f ${FAKE_DIR}/err-local/herdr-app ]] || cat "${FAKE_DIR}/err-local/herdr-app" >&2
  rc=0
  [[ ! -f ${FAKE_DIR}/rc-local/herdr-app ]] || rc=$(<"${FAKE_DIR}/rc-local/herdr-app")
  if [[ ${rc} == 0 ]]; then
    jq -c '.newer = null | .pinnedListed = null | .datesChecked = false | .datesProblem = null' \
      "${FAKE_DIR}/json/herdr-app.json" "${FAKE_DIR}/json/herdr-core.json"
  fi
  exit "${rc}"
fi
[[ ! -f ${FAKE_DIR}/err/herdr-app ]] || cat "${FAKE_DIR}/err/herdr-app" >&2
rc=0
[[ ! -f ${FAKE_DIR}/rc/herdr-app ]] || rc=$(<"${FAKE_DIR}/rc/herdr-app")
if [[ ${rc} == 0 ]]; then
  cat "${FAKE_DIR}/json/herdr-app.json" "${FAKE_DIR}/json/herdr-core.json"
fi
exit "${rc}"
EOF
  } >"${d}/scripts/check-herdr-app-version.sh"
  # 偽の gh。auth token だけを知る (FAKE_GH_NOLOGIN があればログインしていない)
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf 'gh %s\n' "$*" >>"${FAKE_DIR}/calls"
if [[ $1 == auth && $2 == token ]]; then
  [[ -z ${FAKE_GH_NOLOGIN-} ]] || { echo 'no oauth token found for github.com' >&2; exit 1; }
  echo gho_fake
  exit 0
fi
exit 99
EOF
  } >"${d}/bin/gh"
  chmod +x "${d}/scripts/"*.sh "${d}/bin/gh"
  echo "${d}"
}

# $1: case、$2: 1 なら偽の gh を PATH に置かない、残り: script の引数。まとめ用のファイルは <case>/warnings
run() {
  local d=$1 nogh=$2
  shift 2
  local path="${d}/bin:${sys_bin}"
  if [[ ${nogh} == 1 ]]; then
    path=${sys_bin}
  fi
  env HOME="${d}/home" PATH="${path}" FAKE_DIR="${d}" DOTFILES_SETUP_WARNINGS="${d}/warnings" \
    "${BASH}" "${d}/scripts/bootstrap-windows-pin-updates.sh" "$@" >"${d}/out" 2>"${d}/err-out"
  echo $? >"${d}/rc-out"
}

rc() { cat "$1/rc-out"; }
outerr() { cat "$1/out" "$1/err-out"; }
# 判定の grep -q はパイプで受けず、ファイルを直に読む (pjp-shell-traps の SIGPIPE と pipefail)
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err-out"
}
called() {
  local d=$1
  shift
  grep -qs "$@" "${d}/calls"
}
ncalls() { grep -c "^$2 " "$1/calls" 2>/dev/null || true; }

state_on='{"claudeCode":true,"enable":true,"ntn":true,"typeClipboard":false,"version":1,"windowsHome":"/mnt/c/Users/u"}'
state_off='{"claudeCode":false,"enable":false,"ntn":false,"typeClipboard":false,"version":1,"windowsHome":null}'
state_no_extra='{"claudeCode":false,"enable":true,"ntn":false,"typeClipboard":false,"version":1,"windowsHome":"/mnt/c/Users/u"}'
state_absent='{"enable":true,"typeClipboard":false,"version":1,"windowsHome":"/mnt/c/Users/u"}'
heading='Windows に固定した版より新しい版があります → Claude Code に「dotfiles の Windows に固定した版を上げて」と頼み、上げるか (どの版か) を決める'

echo "== bootstrap-windows-pin-updates.sh: ${script}"

# 1. windows-files.json が無い・配らないマシン: 何も呼ばずに飛ばす
d=$(new_case t1 "")
run "${d}" 0
d2=$(new_case t1b "${state_off}")
run "${d2}" 0
if [[ $(rc "${d}") == 0 && ! -s ${d}/calls && $(rc "${d2}") == 0 && ! -s ${d2}/calls ]] && seen "${d}" '飛ばします' && seen "${d2}" '配りません'; then
  ok "windows-files.json が無い・配らないマシンは、何も呼ばずに飛ばす"
else
  ng "飛ばすとき" "$(outerr "${d}") / $(outerr "${d2}")"
fi

# 2. gh が無い・ログインしていない: 確かめられないと 1 行出して exit 0 (まとめにも残す)。口は呼ばない
d=$(new_case t2 "${state_on}")
run "${d}" 1
d2=$(new_case t2b "${state_on}")
FAKE_GH_NOLOGIN=1 run "${d2}" 0
if [[ $(rc "${d}") == 0 && $(rc "${d2}") == 0 ]] && seen "${d}" -F 'gh が見つからない' && seen "${d2}" -F 'gh にログインしていない' \
  && [[ $(grep -c '' "${d}/warnings") == 1 && $(grep -c '' "${d2}/warnings") == 1 ]] \
  && ! called "${d}" '^winget' && ! called "${d2}" '^winget'; then
  ok "gh が無い・ログインしていないときは、確かめられないと 1 行出して exit 0 (まとめにも残す)"
else
  ng "gh が無い・ログインしていない" "$(outerr "${d}") / $(outerr "${d2}")"
fi

# 3. 新しい版がある: 名前ごとに 1 行 (4 つ以上は頭と末尾と個数)。まとめに見出しと続きの行。出た日は引かない
d=$(new_case t3 "${state_on}")
pin_json herdr 'Windows の herdr' 0.9.5 '0.9.6|||' >"${d}/json/herdr.json"
pin_json claude-code 'Windows の Claude Code' 2.1.318 '2.1.321|||' '2.1.322|||' '2.1.323|||' '2.1.325|||' '2.1.330|||' >"${d}/json/claude-code.json"
pin_json herdr-core herdr-core 0.1.18 '0.1.19|||' >"${d}/json/herdr-core.json"
run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && seen "${d}" -F "${heading}" \
  && seen "${d}" -xF '   Windows の herdr: 0.9.5 → 0.9.6' \
  && seen "${d}" -xF '   Windows の Claude Code: 2.1.318 → 2.1.321・…・2.1.330 (新しい版 5 個)' \
  && seen "${d}" -xF '   herdr-core: 0.1.18 → 0.1.19' \
  && [[ $(head -n 1 "${d}/warnings") == "${heading}" ]] \
  && grep -qxF '   Windows の herdr: 0.9.5 → 0.9.6' "${d}/warnings" \
  && ! called "${d}" -F -- '--dates' && [[ $(ncalls "${d}" herdr-app) == 1 && $(ncalls "${d}" winget) == 5 ]]; then
  ok "新しい版があれば名前ごとに 1 行出し、まとめに頼み方の見出しで残す (出た日は引かず、herdr-app と herdr-core は 1 回で読む)"
else
  ng "新しい版がある" "rc=$(rc "${d}") calls=$(cat "${d}/calls") warnings=$(cat "${d}/warnings" 2>/dev/null) $(outerr "${d}")"
fi

# 4. ntn・claudeCode が false の名前は確かめない。欄が無ければ (前の世代) 確かめる
d=$(new_case t4 "${state_no_extra}")
run "${d}" 0
d2=$(new_case t4b "${state_absent}")
run "${d2}" 0
if [[ $(rc "${d}") == 0 ]] && ! called "${d}" -E '^winget .*(ntn|claude-code)$' && called "${d}" -E '^winget .*herdr$' \
  && called "${d2}" -E '^winget .*ntn$' && called "${d2}" -E '^winget .*claude-code$'; then
  ok "ntn・claudeCode が false の名前は確かめず、欄が無ければ確かめる (jq の // で false を true に化けさせない)"
else
  ng "入れないマシンの名前" "calls=$(cat "${d}/calls") / $(cat "${d2}/calls")"
fi

# 4c. group.json の tools.windowsHerdr が false なら herdr・herdr-app・herdr-core を確かめない。true なら確かめる
d=$(new_case t4c "${state_on}")
printf '%s\n' '{"group":"client","tiers":{"aiTools":false,"personalAccounts":false},"tools":{"windowsHerdr":false},"version":1}' \
  >"${d}/home/.local/state/dotfiles/group.json"
run "${d}" 0
d2=$(new_case t4d "${state_on}")
printf '%s\n' '{"group":"personal","tiers":{"aiTools":true,"personalAccounts":true},"tools":{"windowsHerdr":true},"version":1}' \
  >"${d2}/home/.local/state/dotfiles/group.json"
run "${d2}" 0
if [[ $(rc "${d}") == 0 ]] && ! called "${d}" -E '^winget .*herdr$' && ! called "${d}" -E '^herdr-app ' \
  && called "${d}" -E '^winget .*ntn$' && called "${d}" -E '^winget .*openssh$' \
  && called "${d2}" -E '^winget .*herdr$' && called "${d2}" -E '^herdr-app '; then
  ok "group.json の tools.windowsHerdr が false なら herdr・herdr-app・herdr-core を確かめず、true なら確かめる"
else
  ng "windowsHerdr" "calls=$(cat "${d}/calls" 2>/dev/null) / $(cat "${d2}/calls" 2>/dev/null)"
fi

# 4d. --candidates と --list --json (依存の更新の skill が読む口) は group.json を見ない。tools.windowsHerdr が false の
#     マシンでも herdr・herdr-app・herdr-core を出す (repo が固定しているもの全部)
group_no_herdr='{"group":"client","tiers":{"aiTools":false,"personalAccounts":false},"tools":{"windowsHerdr":false},"version":1}'
d=$(new_case t4e "${state_on}")
printf '%s\n' "${group_no_herdr}" >"${d}/home/.local/state/dotfiles/group.json"
run "${d}" 1 --list --json
d2=$(new_case t4f "${state_on}")
printf '%s\n' "${group_no_herdr}" >"${d2}/home/.local/state/dotfiles/group.json"
run "${d2}" 0 --candidates
if [[ $(rc "${d}") == 0 ]] \
  && jq -e '[.items[].name] == ["openssh", "herdr", "google-japanese-input", "ntn", "claude-code", "git", "gh", "vs-buildtools", "rustup", "herdr-app", "herdr-core"]' \
    "${d}/out" >/dev/null \
  && [[ $(rc "${d2}") == 0 ]] && called "${d2}" -E '^winget .*herdr$' && called "${d2}" -E '^herdr-app '; then
  ok "--candidates と --list --json は group.json を見ず、tools.windowsHerdr が false でも herdr・herdr-app・herdr-core を出す"
else
  ng "group.json と --candidates・--list --json" \
    "rc=$(rc "${d}")/$(rc "${d2}") calls=$(cat "${d2}/calls" 2>/dev/null) $(outerr "${d}") / $(outerr "${d2}")"
fi

# 4g. bootstrap の 4 つ (git・gh・vs-buildtools・rustup) は、Windows で bootstrap を流したマシン (Windows の ghq に dotfiles の clone が
#     ある) でだけ確かめる。clone が無ければ確かめない (入れていない道具の版を知らせない)
d=$(new_case t4g "${state_on}")
jq -c --arg h "${d}/winhome" '.windowsHome = $h' <<<"${state_on}" >"${d}/home/.local/state/dotfiles/windows-files.json"
mkdir -p "${d}/winhome/ghq/github.com/pollenjp/dotfiles/.git"
pin_json git 'Windows の Git for Windows' 2.56.0.4 '2.56.1|||' >"${d}/json/git.json"
run "${d}" 0
d2=$(new_case t4h "${state_on}")
jq -c --arg h "${d2}/winhome" '.windowsHome = $h' <<<"${state_on}" >"${d2}/home/.local/state/dotfiles/windows-files.json"
mkdir -p "${d2}/winhome"
pin_json git 'Windows の Git for Windows' 2.56.0.4 '2.56.1|||' >"${d2}/json/git.json"
run "${d2}" 0
if [[ $(rc "${d}") == 0 ]] && [[ $(ncalls "${d}" winget) == 9 ]] && called "${d}" -E '^winget .*vs-buildtools$' \
  && seen "${d}" -xF '   Windows の Git for Windows: 2.56.0.4 → 2.56.1' \
  && [[ $(rc "${d2}") == 0 && $(ncalls "${d2}" winget) == 5 ]] && ! called "${d2}" -E '^winget .*(git|gh|vs-buildtools|rustup)$' \
  && ! seen "${d2}" -F 'Git for Windows'; then
  ok "bootstrap の 4 つは、Windows の ghq に dotfiles の clone があるマシンでだけ確かめ、無ければ確かめない"
else
  ng "bootstrap の 4 つ" "calls=$(cat "${d}/calls" 2>/dev/null) / $(cat "${d2}/calls" 2>/dev/null) $(outerr "${d}") / $(outerr "${d2}")"
fi

# 5. 新しい版が無い・見送った版だけ: 「無い」の 1 行で、まとめには残さない
d=$(new_case t5 "${state_on}")
pin_json herdr 'Windows の herdr' 0.9.5 '0.9.6|試したら設定が読めなかった||' >"${d}/json/herdr.json"
run "${d}" 0
if [[ $(rc "${d}") == 0 && ! -s ${d}/warnings ]] && seen "${d}" -F 'Windows に固定した版より新しい版は無い (見送った版を除く' \
  && ! seen "${d}" -F '0.9.6'; then
  ok "新しい版が無い・見送った版だけなら「無い」の 1 行で、まとめには残さない"
else
  ng "新しい版が無い" "rc=$(rc "${d}") warnings=$(cat "${d}/warnings" 2>/dev/null) $(outerr "${d}")"
fi

# 6. 確かめられない名前 (口が 2・JSON でない): わけを添えて 1 行出し、まとめにも残す。ほかの名前は知らせる。exit 0
d=$(new_case t6 "${state_on}")
echo 2 >"${d}/rc/openssh"
printf '!! winget-pkgs の manifests/m/Microsoft/OpenSSH/Preview を読めませんでした (gh api …):\n   HTTP 403: API rate limit exceeded\n' >"${d}/err/openssh"
printf 'not json\n' >"${d}/json/ntn.json"
pin_json herdr 'Windows の herdr' 0.9.5 '0.9.6|||' >"${d}/json/herdr.json"
run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && seen "${d}" -F '確かめられなかったもの: openssh・ntn (winget-pkgs の manifests/m/Microsoft/OpenSSH/Preview を読めませんでした (gh api …): / HTTP 403: API rate limit exceeded)' \
  && seen "${d}" -xF '   Windows の herdr: 0.9.5 → 0.9.6' && grep -qF '確かめられなかったもの: openssh・ntn' "${d}/warnings" \
  && grep -qxF "${heading}" "${d}/warnings"; then
  ok "確かめられない名前はわけを添えて 1 行出し (まとめにも)、ほかの名前の新しい版は知らせて exit 0"
else
  ng "確かめられない名前" "rc=$(rc "${d}") warnings=$(cat "${d}/warnings" 2>/dev/null) $(outerr "${d}")"
fi

# 7. --candidates: windows-files.json によらず --dates で呼び、猶予ごとの上げ先を出す。出た日の分からない版は選ばない。
#    見送った版は理由つきで並べ、上げ先にしない。新しい版の無い名前は最後に 1 行でまとめる
d=$(new_case t7 "")
pin_json claude-code 'Windows の Claude Code' 2.1.318 '2.1.321||2026-11-04|10' '2.1.322|速すぎた|2026-11-08|6' \
  '2.1.323||2026-11-09|5' '2.1.325||2026-11-12|2' '2.1.330|||' >"${d}/json/claude-code.json"
run "${d}" 0 --candidates
if [[ $(rc "${d}") == 0 ]] && [[ $(ncalls "${d}" winget) == 9 && $(ncalls "${d}" herdr-app) == 1 ]] && ! called "${d}" -vF -- '--dates' \
  && seen "${d}" -xF '■ Windows の Claude Code (claude-code)' \
  && seen "${d}" -F '2.1.322 (見送った: 速すぎた)' && seen "${d}" -F '2.1.330 (出た日が分からない)' \
  && seen "${d}" -F '2.1.321 (2026-11-04 に出た、10 日前)  https://example.invalid/2.1.321' \
  && seen "${d}" -xF '  猶予 1 日 : 2.1.325' && seen "${d}" -xF '  猶予 3 日 : 2.1.323' && seen "${d}" -xF '  猶予 7 日 : 2.1.321' \
  && seen "${d}" -F '上げ方     : win/README.md の「Windows の Claude Code の新しい版が出たとき」' \
  && seen "${d}" -F '新しい版は無い (見送った版を除く): Windows の openssh (1.0.0)'; then
  ok "--candidates は --dates で呼び、猶予ごとの上げ先を出す (出た日の分からない版・見送った版は選ばない)"
else
  ng "--candidates" "rc=$(rc "${d}") calls=$(cat "${d}/calls" 2>/dev/null) $(outerr "${d}")"
fi

# 8. --candidates --grace と名前: 渡した名前だけを、渡した日数で出す。どの版も満たさなければ「無い」
d=$(new_case t8 "")
pin_json ntn 'Windows の ntn' 0.23.28 '0.23.29||2026-11-12|2' '0.23.30||2026-11-13|1' >"${d}/json/ntn.json"
run "${d}" 0 --candidates --grace 2,5 ntn
if [[ $(rc "${d}") == 0 && $(ncalls "${d}" winget) == 1 && $(ncalls "${d}" herdr-app) == 0 ]] \
  && seen "${d}" -xF '  猶予 2 日 : 0.23.29' && seen "${d}" -xF '  猶予 5 日 : 無い (5 日たった新しい版は無い)' && ! seen "${d}" -F '猶予 7 日'; then
  ok "--candidates --grace 2,5 ntn は、ntn だけを 2 日と 5 日で出し、満たす版が無ければ「無い」"
else
  ng "--grace と名前" "rc=$(rc "${d}") calls=$(cat "${d}/calls" 2>/dev/null) $(outerr "${d}")"
fi

# 9. --candidates で確かめられない名前: ほかを出したうえで exit 2
d=$(new_case t9 "")
echo 2 >"${d}/rc/herdr-app"
printf '!! 確かめられなかった: GitHub の herdrdev/herdr-app の tag を読めない\n' >"${d}/err/herdr-app"
pin_json herdr 'Windows の herdr' 0.9.5 '0.9.6||2026-11-01|13' >"${d}/json/herdr.json"
run "${d}" 0 --candidates
if [[ $(rc "${d}") == 2 ]] && seen "${d}" -xF '  猶予 7 日 : 0.9.6' \
  && seen "${d}" -F 'herdr-app は確かめられなかった: 確かめられなかった: GitHub の herdrdev/herdr-app の tag を読めない' \
  && seen "${d}" -F 'herdr-core は確かめられなかった'; then
  ok "--candidates で確かめられない名前があれば、ほかを出したうえで exit 2"
else
  ng "--candidates の失敗" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 10. 引数の誤り: 知らない名前・--candidates の無い名前・読めない --grace・知らない引数は exit 2 (口は呼ばない)
d=$(new_case t10 "${state_on}")
run "${d}" 0 --candidates vscode
d2=$(new_case t10b "${state_on}")
run "${d2}" 0 ntn
d3=$(new_case t10c "${state_on}")
run "${d3}" 0 --candidates --grace 1,x
d4=$(new_case t10d "${state_on}")
run "${d4}" 0 --bogus
if [[ $(rc "${d}") == 2 && $(rc "${d2}") == 2 && $(rc "${d3}") == 2 && $(rc "${d4}") == 2 ]] \
  && [[ ! -s ${d}/calls && ! -s ${d2}/calls && ! -s ${d3}/calls && ! -s ${d4}/calls ]] && seen "${d}" -F '知らない名前です: vscode'; then
  ok "知らない名前・--candidates の無い名前・読めない --grace・知らない引数は exit 2 (口は呼ばない)"
else
  ng "引数の誤り" "rc=$(rc "${d}")/$(rc "${d2}")/$(rc "${d3}")/$(rc "${d4}") $(outerr "${d}")"
fi

# 11. --list --json: gh が無くても、check の口を --json --offline で呼んで固定した版を出す (windows-files.json は見ない)。
#     名前を渡せば、その名前だけ
d=$(new_case t11 "")
run "${d}" 1 --list --json
d2=$(new_case t11b "${state_off}")
run "${d2}" 1 --list --json ntn herdr-core
if [[ $(rc "${d}") == 0 ]] && jq -e '.version == 1 and ([.items[].name] == ["openssh", "herdr", "google-japanese-input", "ntn", "claude-code", "git", "gh", "vs-buildtools", "rustup", "herdr-app", "herdr-core"])
    and (.items[] | select(.name == "ntn") | . == {name: "ntn", title: "Windows の ntn", files: ["win/ntn/Install-X.ps1"],
      pinned: "1.0.0", winget_id: "Notion.ntn", skip_file: "win/ntn/skipped-versions.txt", error: null})
    and (.items[] | select(.name == "herdr-app") | .winget_id == null and .files == ["win/herdr-app/Install-X.ps1"] and .pinned == "0.1.0")
    and ([.items[] | has("candidates") or has("targets")] | any | not)' "${d}/out" >/dev/null \
  && [[ $(ncalls "${d}" winget) == 9 && $(ncalls "${d}" herdr-app) == 1 ]] && ! called "${d}" -vF -- '--offline' \
  && ! called "${d}" -F -- '--dates' && ! called "${d}" '^gh ' \
  && [[ $(rc "${d2}") == 0 ]] && jq -e '[.items[].name] == ["ntn", "herdr-core"]' "${d2}/out" >/dev/null; then
  ok "--list --json は gh が無くても --offline の口で固定した版を出し (windows-files.json は見ない)、名前を渡せばその名前だけ"
else
  ng "--list --json" "rc=$(rc "${d}")/$(rc "${d2}") calls=$(cat "${d}/calls" 2>/dev/null) $(outerr "${d}") / $(outerr "${d2}")"
fi

# 12. --list --json で固定した版を読めない名前: error にわけを書き、ほかの名前は出して exit 2
d=$(new_case t12 "")
echo 2 >"${d}/rc-local/ntn"
printf "!! 固定した版が読めません: win/ntn/Install-Ntn.ps1 に [string]\$Version = '<版>' の行がありません。\n" >"${d}/err-local/ntn"
echo 2 >"${d}/rc-local/herdr-app"
run "${d}" 1 --list --json
if [[ $(rc "${d}") == 2 ]] && jq -e '
    (.items[] | select(.name == "ntn") | . == {name: "ntn", title: "ntn", files: [], pinned: "", winget_id: null, skip_file: null,
      error: "固定した版が読めません: win/ntn/Install-Ntn.ps1 に [string]$Version = '"'"'<版>'"'"' の行がありません。"})
    and (.items[] | select(.name == "herdr-core") | .error == "終了コード 2" and .pinned == "")
    and (.items[] | select(.name == "herdr") | .error == null and .pinned == "1.0.0")' "${d}/out" >/dev/null; then
  ok "--list --json で固定した版を読めない名前は error にわけを書き (ほかの欄は空に)、ほかの名前は出して exit 2"
else
  ng "--list --json の読めない名前" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 13. --candidates --json: 新しい版を candidates に、猶予ごとの上げ先を targets に入れる。見送った版・出た日の分からない版は
#     上げ先にしない。url の無い版は winget-pkgs の manifest のディレクトリ。--grace の 07 は 7 の key になる
d=$(new_case t13 "")
pin_json claude-code 'Windows の Claude Code' 2.1.318 '2.1.321||2026-11-04|10' '2.1.322|速すぎた|2026-11-08|6' \
  '2.1.323||2026-11-09|5' '2.1.325||2026-11-12|2' '2.1.330||||nourl' >"${d}/json/claude-code.json"
pin_json herdr-core herdr-core 0.1.18 '0.1.19||2026-11-08|6' >"${d}/json/herdr-core.json"
run "${d}" 0 --candidates --json --grace 1,3,07
if [[ $(rc "${d}") == 0 ]] && jq -e '
    (.items[] | select(.name == "claude-code")
      | .winget_id == "Anthropic.ClaudeCode" and .pinned == "2.1.318" and .error == null
        and ([.candidates[].version] == ["2.1.321", "2.1.322", "2.1.323", "2.1.325", "2.1.330"])
        and .candidates[0] == {version: "2.1.321", published: "2026-11-04", age_days: 10, url: "https://example.invalid/2.1.321", skipped: null}
        and .candidates[1].skipped == "速すぎた"
        and .candidates[4] == {version: "2.1.330", published: null, age_days: null,
          url: "https://github.com/microsoft/winget-pkgs/tree/master/manifests/a/Anthropic/ClaudeCode/2.1.330", skipped: null}
        and .targets == {"1": "2.1.325", "3": "2.1.323", "7": "2.1.321"})
    and (.items[] | select(.name == "herdr-core") | .winget_id == null and .targets == {"1": "0.1.19", "3": "0.1.19", "7": null})
    and (.items[] | select(.name == "ntn") | .candidates == [] and .targets == {"1": null, "3": null, "7": null})' "${d}/out" >/dev/null \
  && [[ $(grep -c -- '--dates' "${d}/calls") == 10 ]]; then
  ok "--candidates --json は candidates (age_days・url の埋め) と targets を出し、見送った版・出た日の分からない版を上げ先にしない"
else
  ng "--candidates --json" "rc=$(rc "${d}") calls=$(cat "${d}/calls" 2>/dev/null) $(outerr "${d}")"
fi

# 14. --candidates --json で確かめられない名前: 口が落ちる・出た日を確かめられない・gh が無い。error にわけを書き、candidates を
#     []・targets を全部 null にして、ほかの名前は出したうえで exit 2
d=$(new_case t14 "")
echo 2 >"${d}/rc/openssh"
printf '!! winget-pkgs の manifests/m/Microsoft/OpenSSH/Preview を読めませんでした (gh api …):\n   HTTP 403: API rate limit exceeded\n' >"${d}/err/openssh"
pin_json ntn 'Windows の ntn' 0.23.28 '0.23.29|||' | jq -c '.datesChecked = false | .datesProblem = "winget-pkgs の commit の一覧が取れない (HTTP 502)"' >"${d}/json/ntn.json"
pin_json herdr 'Windows の herdr' 0.9.5 '0.9.6||2026-11-01|13' >"${d}/json/herdr.json"
run "${d}" 0 --candidates --json
d2=$(new_case t14b "")
run "${d2}" 1 --candidates --json herdr herdr-app
if [[ $(rc "${d}") == 2 ]] && jq -e '
    (.items[] | select(.name == "openssh") | .error == "winget-pkgs の manifests/m/Microsoft/OpenSSH/Preview を読めませんでした (gh api …): / HTTP 403: API rate limit exceeded"
      and .candidates == [] and .targets == {"1": null, "3": null, "7": null} and .pinned == "1.0.0" and .winget_id == "Microsoft.OpenSSH.Preview")
    and (.items[] | select(.name == "ntn") | .error == "出た日を確かめられなかった: winget-pkgs の commit の一覧が取れない (HTTP 502)" and .candidates == [])
    and (.items[] | select(.name == "herdr") | .error == null and .targets["7"] == "0.9.6")' "${d}/out" >/dev/null \
  && [[ $(rc "${d2}") == 2 ]] && jq -e '[.items[] | .error | startswith("gh が見つからない")] == [true, true]
    and ([.items[].name] == ["herdr", "herdr-app"]) and (.items[0].pinned == "1.0.0")' "${d2}/out" >/dev/null \
  && ! called "${d2}" -- '--dates'; then
  ok "--candidates --json で確かめられない名前は error にわけを書き (candidates は []・targets は null)、ほかを出して exit 2"
else
  ng "--candidates --json の失敗" "rc=$(rc "${d}")/$(rc "${d2}") $(outerr "${d}") / $(outerr "${d2}") calls=$(cat "${d2}/calls" 2>/dev/null)"
fi

# 15. JSON の口の引数の誤り: --json の無い --list・--candidates か --list の無い --json・--candidates と --list の両方は exit 2
d=$(new_case t15 "")
run "${d}" 0 --list
d2=$(new_case t15b "")
run "${d2}" 0 --json
d3=$(new_case t15c "")
run "${d3}" 0 --candidates --list --json
if [[ $(rc "${d}") == 2 && $(rc "${d2}") == 2 && $(rc "${d3}") == 2 ]] \
  && [[ ! -s ${d}/calls && ! -s ${d2}/calls && ! -s ${d3}/calls ]] && seen "${d}" -F -- '--list は --json と一緒に'; then
  ok "--json の無い --list・--candidates か --list の無い --json・--candidates と --list の両方は exit 2 (口は呼ばない)"
else
  ng "JSON の口の引数の誤り" "rc=$(rc "${d}")/$(rc "${d2}")/$(rc "${d3}") $(outerr "${d}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
