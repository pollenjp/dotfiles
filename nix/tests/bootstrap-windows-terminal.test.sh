#!/usr/bin/env bash
# shellcheck shell=bash
# jq の式 ($w など) を文字のまま書く所が多いので、ファイル全体で SC2016 を止める
# shellcheck disable=SC2016
#
# nix/scripts/bootstrap-windows-terminal.sh の振る舞いを、使い捨ての HOME と偽の checkout で確かめる。
#
#   bash nix/tests/bootstrap-windows-terminal.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-terminal-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・git・coreutils・findutils・diffutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・windows-files.json が無いときは、何も書かずに飛ばす
#   - settings.json が無い・JSON として読めないときは、warn で知らせて書かずに exit 0
#   - 値が無ければ書き足し、ほかのキーは変えない。同じ値なら settings.json に触らず、記録だけする
#   - managed.json を変えたら (settings.json が前回書いた値のまま) 書き換える
#   - Windows 側で変わった・消えた・書く前から違う値があったときは衝突として触らず、両方の値と
#     解き方を出して exit 1。衝突しないキーは書く。--force なら settings.json を退避してから書く
#   - --import は衝突したキーの値を managed.json へ取り込み (値が無ければキーを消し、空になった object も
#     消す)、settings.json は変えない。managed.json に commit していない変更があるとき・git の checkout で
#     ないときは止まる
#   - --dry-run は何も書かない (settings.json・記録・退避)
#   - 名前に . を含むキー・配列・null を、それぞれ 1 つの値として扱う
#   - managed.json から消したキーは、settings.json からは消さず、記録からだけ消す
#   - profiles.list を持とうとする managed.json は、--check でも本番でも止まる。--check は形
#     (jq --indent 4 の出力と同じか) も見る
#   - settings.json の途中が object でなくて書けないキーは、⚠ で出して exit 1
#   - 退避は新しい方から 10 回分だけ残す。壊れた記録では止まる。引数の組み合わせの誤りは exit 2
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、exit 0 で続ける警告を続きの行ごと
#     setup の最後のまとめ用のファイルにも残す
#
# ## 偽の checkout
#
# script は自分のいる checkout の win/windows-terminal/managed.json を読むので、ケースごとに
# <ケース>/repo/nix/scripts/ へ写して流す。Windows のホームに見立てるのは <ケース>/win。
# script は .exe を呼ばないが、要るコマンドだけを symlink で並べた PATH で流す (足りないコマンドに
# 気づけるように)。出力は <ケース>/out と <ケース>/err に残し、grep には直にファイルを渡す
# (パイプの grep -q は、pipefail の下で SIGPIPE を拾って落ちることがある。TKT-155)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-terminal.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-terminal-test.XXXXXX")
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

# 要るコマンドだけを並べた PATH
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in jq git cat mkdir mktemp mv cp rm date find sort sed cmp dirname; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

settings_rel="AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
sound='C:\Windows\Media\Windows Information Bar.wav'
other='C:\Windows\Media\ding.wav'

# Windows Terminal が書く形の settings.json (bellSound は無い)
base_settings() {
  cat <<'EOF'
{
    "$help": "https://aka.ms/terminal-documentation",
    "$schema": "https://aka.ms/terminal-profiles-schema",
    "actions":
    [
        {
            "command": "paste",
            "id": "User.paste"
        }
    ],
    "copyOnSelect": false,
    "keybindings":
    [
        {
            "id": null,
            "keys": "ctrl+v"
        }
    ],
    "profiles":
    {
        "defaults": {},
        "list":
        [
            {
                "guid": "{574e775e-4f2a-5b96-ac1e-a2962a402336}",
                "hidden": false,
                "name": "PowerShell",
                "source": "Windows.Terminal.PowershellCore"
            }
        ]
    },
    "schemes": []
}
EOF
}

# managed.json (jq --indent 4 の形)。$1: bellSound の値
managed_bell() {
  jq -n --indent 4 --arg v "$1" '{profiles: {defaults: {bellSound: $v}}}'
}

# 1 ケースぶんを作る。$1: 名前。managed.json は bellSound=${sound}、settings.json は base_settings
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/home/.local/state/dotfiles" "${c}/repo/nix/scripts" "${c}/repo/win/windows-terminal" \
    "${c}/win/$(dirname "${settings_rel}")"
  cp "${script}" "${c}/repo/nix/scripts/bootstrap-windows-terminal.sh"
  jq -n --arg home "${c}/win" '{enable: true, version: 1, windowsHome: $home}' \
    >"${c}/home/.local/state/dotfiles/windows-files.json"
  managed_bell "${sound}" >"${c}/repo/win/windows-terminal/managed.json"
  base_settings >"${c}/win/${settings_rel}"
  echo "${c}"
}

settings() { printf '%s' "$1/win/${settings_rel}"; }
managed() { printf '%s' "$1/repo/win/windows-terminal/managed.json"; }
record() { printf '%s' "$1/home/.local/state/dotfiles/windows-terminal.applied.json"; }
backup_root() { printf '%s' "$1/home/.local/state/dotfiles/windows-terminal/backup"; }
backups() {
  local d
  d=$(backup_root "$1")
  if [[ -d ${d} ]]; then
    find "${d}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
  else
    echo 0
  fi
}

# settings.json の値を JSON で出す。$1: ケース、$2: jq のパス
val() { jq -c "$2" "$(settings "$1")"; }
bell() { val "$1" '.profiles.defaults.bellSound'; }
# settings.json を写しておき、後で同じバイト列かを比べる
snap() { cp "$(settings "$1")" "$1/before"; }
untouched() { cmp -s "$1/before" "$(settings "$1")"; }

# $1: ケース、残り: script の引数。環境変数は呼び出し側で付ける
run() {
  local c=$1
  shift
  env HOME="${c}/home" PATH="${sys_bin}" "${BASH}" "${c}/repo/nix/scripts/bootstrap-windows-terminal.sh" "$@" \
    >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}
rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
# 出力 (stdout か stderr) に $2 があるか
has() { grep -qF -- "$2" "$1/out" "$1/err"; }

# managed.json を commit した git の checkout にする
git_init() {
  git -C "$1/repo" init -q
  git -C "$1/repo" add win
  git -C "$1/repo" -c user.name=test -c user.email=test@example.com commit -qm init
}

echo "== bootstrap-windows-terminal.sh: ${script}"

# 1. windows-files.json が無い: 飛ばす
c=$(new_case t1)
rm -f "${c}/home/.local/state/dotfiles/windows-files.json"
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '飛ばします' && untouched "${c}" && [[ ! -e $(record "${c}") ]]; then
  ok "windows-files.json が無ければ何も書かずに飛ばす"
else
  ng "windows-files.json が無いとき" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 2. 配らないマシン
c=$(new_case t2)
jq -n '{enable: false, version: 1, windowsHome: null}' >"${c}/home/.local/state/dotfiles/windows-files.json"
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '配りません' && untouched "${c}"; then
  ok "enable = false のマシンでは何もしない"
else
  ng "配らないマシン" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 3. settings.json が無い: warn で知らせて exit 0。作らない
c=$(new_case t3)
rm -f "$(settings "${c}")"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '!! Windows Terminal の settings.json がありません' \
  && has "${c}" '一度起動すると作られます' && [[ ! -e $(settings "${c}") ]]; then
  ok "settings.json が無ければ warn で知らせて作らない"
else
  ng "settings.json が無いとき" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 4. settings.json にコメントがある: 読めないので書かない
c=$(new_case t4)
{
  echo '// 手で書いたコメント'
  base_settings
} >"$(settings "${c}")"
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" 'JSON として読めないので、書き足しません' && untouched "${c}"; then
  ok "JSON として読めない settings.json には書かない (exit 0)"
else
  ng "読めない settings.json" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 5. 値が無い: 書き足す。ほかのキーは変えず、記録と退避を残す
c=$(new_case t5)
snap "${c}"
run "${c}"
want=$(jq -cn --arg v "${sound}" '$v')
rest_before=$(jq -S 'del(.profiles.defaults.bellSound)' "${c}/before")
rest_after=$(jq -S 'del(.profiles.defaults.bellSound)' "$(settings "${c}")")
recorded=$(jq -c '.keys["[\"profiles\",\"defaults\",\"bellSound\"]"]' "$(record "${c}")" 2>/dev/null)
if [[ $(rc "${c}") == 0 && $(bell "${c}") == "${want}" && ${rest_before} == "${rest_after}" && ${recorded} == "${want}" ]] \
  && [[ $(backups "${c}") == 1 ]] && has "${c}" 'profiles.defaults.bellSound: 書き足す' \
  && cmp -s "${c}/before" "$(find "$(backup_root "${c}")" -name settings.json)"; then
  ok "値が無ければ書き足し、ほかのキーは変えず、記録と退避 (書く前の中身) を残す"
else
  ng "書き足し" "rc=$(rc "${c}") bell=$(bell "${c}") recorded=${recorded} backups=$(backups "${c}") $(outerr "${c}")"
fi
if compgen -G "$(dirname "$(settings "${c}")")/*.dotfiles-tmp.*" >/dev/null; then
  ng "一時ファイルが残った"
else
  ok "書いたあとに一時ファイルを残さない"
fi

# 6. もう同じ値: settings.json に触らず、記録だけする
c=$(new_case t6)
jq --indent 4 --arg v "${sound}" '.profiles.defaults.bellSound = $v' <<<"$(base_settings)" >"$(settings "${c}")"
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '揃っています (持つキー 1 件)' && untouched "${c}" \
  && [[ -s $(record "${c}") && $(backups "${c}") == 0 ]]; then
  ok "同じ値なら settings.json に触らず、記録だけする"
else
  ng "同じ値" "rc=$(rc "${c}") backups=$(backups "${c}") $(outerr "${c}")"
fi

# 7. managed.json を変えた (settings.json は前回書いた値のまま): 書き換える
c=$(new_case t7)
run "${c}"
managed_bell "${other}" >"$(managed "${c}")"
run "${c}"
if [[ $(rc "${c}") == 0 && $(bell "${c}") == "$(jq -cn --arg v "${other}" '$v')" ]] \
  && has "${c}" 'profiles.defaults.bellSound: 書き換える (managed.json が更新された)'; then
  ok "managed.json を変えたら、前回書いた値のままの settings.json を書き換える"
else
  ng "managed.json の更新" "rc=$(rc "${c}") bell=$(bell "${c}") $(outerr "${c}")"
fi

# 8. Windows 側で変わった: 衝突。触らずに両方の値と解き方を出して exit 1
c=$(new_case t8)
run "${c}"
jq --indent 4 --arg v "${other}" '.profiles.defaults.bellSound = $v' "$(settings "${c}")" >"${c}/tmp" && mv "${c}/tmp" "$(settings "${c}")"
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 1 ]] && untouched "${c}" \
  && grep -qF '!! 衝突: profiles.defaults.bellSound は Windows 側で変わっています' "${c}/err" \
  && grep -qF "Windows 側:   $(jq -cn --arg v "${other}" '$v')" "${c}/err" \
  && grep -qF "managed.json: $(jq -cn --arg v "${sound}" '$v')" "${c}/err" \
  && grep -qF 'bootstrap-windows-terminal.sh --import' "${c}/err" \
  && grep -qF 'bootstrap-windows-terminal.sh --force' "${c}/err" && grep -qF '⚠️' "${c}/err"; then
  ok "Windows 側で変わっていたら触らず、両方の値と解き方を ⚠ で出して exit 1"
else
  ng "Windows 側の変更" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 9. 書く前から違う値がある (記録が無い): 衝突
c=$(new_case t9)
jq --indent 4 --arg v "${other}" '.profiles.defaults.bellSound = $v' <<<"$(base_settings)" >"$(settings "${c}")"
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 1 ]] && untouched "${c}" && grep -qF '書いた記録が無く、managed.json と値が違います' "${c}/err"; then
  ok "書く前から違う値があれば、記録が無い衝突として触らない"
else
  ng "記録が無い衝突" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 10. Windows 側で消えた (記録はある): 衝突
c=$(new_case t10)
run "${c}"
jq --indent 4 'del(.profiles.defaults.bellSound)' "$(settings "${c}")" >"${c}/tmp" && mv "${c}/tmp" "$(settings "${c}")"
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 1 ]] && untouched "${c}" && grep -qF 'Windows 側で消えています' "${c}/err" \
  && grep -qF 'Windows 側:   (無い)' "${c}/err"; then
  ok "書いた値が Windows 側で消えていたら、衝突として書き直さない"
else
  ng "消えた値" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 11. --force: 衝突でも退避してから書く
c=$(new_case t11)
jq --indent 4 --arg v "${other}" '.profiles.defaults.bellSound = $v' <<<"$(base_settings)" >"$(settings "${c}")"
snap "${c}"
run "${c}" --force
recorded=$(jq -c '.keys["[\"profiles\",\"defaults\",\"bellSound\"]"]' "$(record "${c}")" 2>/dev/null)
if [[ $(rc "${c}") == 0 && $(bell "${c}") == "${want}" && ${recorded} == "${want}" && $(backups "${c}") == 1 ]] \
  && has "${c}" '書き換える (--force)' && cmp -s "${c}/before" "$(find "$(backup_root "${c}")" -name settings.json)"; then
  ok "--force は衝突でも、元の settings.json を退避してから書く"
else
  ng "--force" "rc=$(rc "${c}") bell=$(bell "${c}") backups=$(backups "${c}") $(outerr "${c}")"
fi

# 12. --dry-run: 何も書かない
c=$(new_case t12)
snap "${c}"
run "${c}" --dry-run
if [[ $(rc "${c}") == 0 ]] && untouched "${c}" && [[ ! -e $(record "${c}") && $(backups "${c}") == 0 ]] \
  && has "${c}" '[dry-run] profiles.defaults.bellSound: 書き足す'; then
  ok "--dry-run は判定だけ出して、settings.json・記録・退避のどれも書かない"
else
  ng "--dry-run" "rc=$(rc "${c}") backups=$(backups "${c}") $(outerr "${c}")"
fi

# 13. --import: 衝突したキーの値を managed.json へ取り込み、settings.json は変えない
c=$(new_case t13)
run "${c}"
git_init "${c}"
jq --indent 4 --arg v "${other}" '.profiles.defaults.bellSound = $v' "$(settings "${c}")" >"${c}/tmp" && mv "${c}/tmp" "$(settings "${c}")"
snap "${c}"
run "${c}" --import
imported=$(jq -c '.profiles.defaults.bellSound' "$(managed "${c}")")
if [[ $(rc "${c}") == 0 && ${imported} == "$(jq -cn --arg v "${other}" '$v')" ]] && untouched "${c}" \
  && has "${c}" 'managed.json へ取り込みました' \
  && jq --indent 4 . "$(managed "${c}")" | cmp -s - "$(managed "${c}")"; then
  ok "--import は衝突した値を managed.json へ (jq --indent 4 の形で) 取り込み、settings.json は変えない"
else
  ng "--import" "rc=$(rc "${c}") imported=${imported} $(outerr "${c}")"
fi
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '揃っています' && untouched "${c}"; then
  ok "取り込んだ後は揃っている (記録も取り込んだ値になる)"
else
  ng "取り込んだ後" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 14. --import: Windows 側で消えていたら、managed.json からキーと空になった object を消す
c=$(new_case t14)
run "${c}"
git_init "${c}"
jq --indent 4 'del(.profiles.defaults.bellSound)' "$(settings "${c}")" >"${c}/tmp" && mv "${c}/tmp" "$(settings "${c}")"
run "${c}" --import
if [[ $(rc "${c}") == 0 && $(jq -c . "$(managed "${c}")") == '{}' ]] \
  && [[ $(jq -c '.keys' "$(record "${c}")") == '{}' ]]; then
  ok "--import は Windows 側で消えたキーを managed.json から消し、空になった object も消す"
else
  ng "--import で消す" "rc=$(rc "${c}") managed=$(jq -c . "$(managed "${c}")") $(outerr "${c}")"
fi

# 15. --import: managed.json に commit していない変更があれば止まる
c=$(new_case t15)
run "${c}"
git_init "${c}"
jq --indent 4 --arg v "${other}" '.profiles.defaults.bellSound = $v' "$(settings "${c}")" >"${c}/tmp" && mv "${c}/tmp" "$(settings "${c}")"
jq --indent 4 '.copyOnSelect = true' "$(managed "${c}")" >"${c}/tmp" && mv "${c}/tmp" "$(managed "${c}")"
cp "$(managed "${c}")" "${c}/managed-before"
run "${c}" --import
if [[ $(rc "${c}") == 1 ]] && grep -qF 'commit していない変更があります' "${c}/err" \
  && cmp -s "${c}/managed-before" "$(managed "${c}")"; then
  ok "--import は managed.json に commit していない変更があると、何も書かずに止まる"
else
  ng "--import と commit していない変更" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 16. --import: git の checkout でなければ止まる
c=$(new_case t16)
run "${c}" --import
if [[ $(rc "${c}") == 1 ]] && grep -qF '確かめられません' "${c}/err"; then
  ok "--import は git の checkout でなければ止まる"
else
  ng "--import と git の外" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 17. 名前に . を含むキー・配列・null を 1 つの値として扱う
c=$(new_case t17)
jq -n --indent 4 '{
  "compatibility.allowHeadless": true,
  newTabMenu: [{type: "remainingProfiles"}, {type: "separator"}],
  profiles: {defaults: {"experimental.retroTerminalEffect": false, bellSound: null}}
}' >"$(managed "${c}")"
run "${c}"
if [[ $(rc "${c}") == 0 ]] \
  && [[ $(val "${c}" '."compatibility.allowHeadless"') == true ]] \
  && [[ $(val "${c}" 'has("compatibility")') == false ]] \
  && [[ $(val "${c}" '.newTabMenu | length') == 2 ]] \
  && [[ $(val "${c}" '.profiles.defaults."experimental.retroTerminalEffect"') == false ]] \
  && [[ $(val "${c}" '.profiles.defaults | has("bellSound")') == true && $(bell "${c}") == null ]] \
  && has "${c}" '"compatibility.allowHeadless": 書き足す' \
  && has "${c}" 'profiles.defaults."experimental.retroTerminalEffect": 書き足す'; then
  ok "名前に . を含むキー・配列・null を 1 つの値として書く"
else
  ng "名前に . を含むキー・配列・null" "rc=$(rc "${c}") $(outerr "${c}") $(jq -c . "$(settings "${c}")")"
fi
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '揃っています (持つキー 4 件)' && untouched "${c}"; then
  ok "書いた後は、null の値も含めて揃っている"
else
  ng "書いた後の null" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 18. managed.json から消したキー: settings.json からは消さず、記録からだけ消す
c=$(new_case t18)
run "${c}"
echo '{}' >"$(managed "${c}")"
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '揃っています (持つキー 0 件)' && untouched "${c}" \
  && [[ $(jq -c '.keys' "$(record "${c}")") == '{}' ]]; then
  ok "managed.json から消したキーは、settings.json からは消さず記録からだけ消す"
else
  ng "消したキー" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 19. 衝突しないキーは書き、衝突したキーには触らない
c=$(new_case t19)
jq --indent 4 --arg v "${other}" '.profiles.defaults.bellSound = $v' <<<"$(base_settings)" >"$(settings "${c}")"
jq -n --indent 4 --arg v "${sound}" '{copyFormatting: "none", profiles: {defaults: {bellSound: $v}}}' >"$(managed "${c}")"
run "${c}"
if [[ $(rc "${c}") == 1 && $(val "${c}" '.copyFormatting') == '"none"' && $(bell "${c}") == "$(jq -cn --arg v "${other}" '$v')" ]]; then
  ok "衝突しないキーは書き、衝突したキーには触らずに exit 1"
else
  ng "衝突と書き足しが混ざるとき" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 20. profiles.list を持とうとする managed.json: --check も本番も止まる
c=$(new_case t20)
jq -n --indent 4 '{profiles: {list: []}}' >"$(managed "${c}")"
snap "${c}"
run "${c}" --check
check_rc=$(rc "${c}")
check_has=0
if grep -qF 'profiles.list があります' "${c}/err"; then
  check_has=1
fi
run "${c}"
if [[ ${check_rc} == 1 && ${check_has} == 1 && $(rc "${c}") == 1 ]] && untouched "${c}"; then
  ok "profiles.list を持とうとする managed.json は、--check でも本番でも止まる"
else
  ng "profiles.list" "check_rc=${check_rc} rc=$(rc "${c}") $(outerr "${c}")"
fi

# 21. --check は形も見る (jq --indent 4 の出力と違えば落ちる)
c=$(new_case t21)
run "${c}" --check
first_rc=$(rc "${c}")
first_ok=0
if grep -qF 'managed.json: OK (持つキー 1 件)' "${c}/out"; then
  first_ok=1
fi
jq . "$(managed "${c}")" >"${c}/tmp" && mv "${c}/tmp" "$(managed "${c}")"
run "${c}" --check
if [[ ${first_rc} == 0 && ${first_ok} == 1 && $(rc "${c}") == 1 ]] && grep -qF 'jq --indent 4' "${c}/err"; then
  ok "--check は中身と形 (jq --indent 4 の出力と同じか) を見る"
else
  ng "--check" "first_rc=${first_rc} rc=$(rc "${c}") $(outerr "${c}")"
fi

# 22. settings.json の途中が object でない (profiles が配列の古い形): 書けないので ⚠ で exit 1
c=$(new_case t22)
jq --indent 4 '.profiles = .profiles.list' <<<"$(base_settings)" >"$(settings "${c}")"
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 1 ]] && untouched "${c}" && grep -qF '途中の profiles が object ではない' "${c}/err" \
  && grep -qF '⚠️' "${c}/err"; then
  ok "settings.json の途中が object でなくて書けないキーは、⚠ で出して exit 1"
else
  ng "書けないキー" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 23. 退避は新しい方から 10 回分だけ残す
c=$(new_case t23)
for i in $(seq -w 1 12); do
  mkdir -p "$(backup_root "${c}")/20200101T0000${i}Z-1"
done
run "${c}"
if [[ $(rc "${c}") == 0 && $(backups "${c}") == 10 ]] \
  && [[ ! -d "$(backup_root "${c}")/20200101T000001Z-1" && ! -d "$(backup_root "${c}")/20200101T000003Z-1" ]] \
  && [[ -d "$(backup_root "${c}")/20200101T000004Z-1" ]]; then
  ok "退避は新しい方から 10 回分だけ残す"
else
  ng "退避の数" "rc=$(rc "${c}") backups=$(backups "${c}")"
fi

# 24. 壊れた記録では止まる
c=$(new_case t24)
echo '[]' >"$(record "${c}")"
snap "${c}"
run "${c}"
if [[ $(rc "${c}") == 1 ]] && grep -qF '壊れています' "${c}/err" && untouched "${c}"; then
  ok "壊れた記録では何も書かずに止まる"
else
  ng "壊れた記録" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 25. 引数の組み合わせの誤り
c=$(new_case t25)
bad=()
for args in "--import --force" "--import --dry-run" "--check --dry-run" "--nope"; do
  # shellcheck disable=SC2086
  run "${c}" ${args}
  if [[ $(rc "${c}") != 2 ]]; then
    bad+=("${args}: rc=$(rc "${c}")")
  fi
done
if ((${#bad[@]} == 0)); then
  ok "引数の組み合わせの誤りは exit 2"
else
  ng "引数の組み合わせ" "${bad[*]}"
fi

# 26. setup から走るとき: exit 0 で続ける警告を、続きの行ごとまとめ用のファイルにも残す
c=$(new_case t26)
rm -f "$(settings "${c}")"
DOTFILES_SETUP_WARNINGS="${c}/warnings" run "${c}"
if [[ $(rc "${c}") == 0 && $(head -n 1 "${c}/warnings" 2>/dev/null) == "Windows Terminal の settings.json がありません: "* ]] \
  && grep -qE '^[[:space:]]+Windows Terminal \(Store 版\) を一度起動すると作られます' "${c}/warnings"; then
  ok "setup から走るときは、警告を続きの行ごとまとめ用のファイルにも残す"
else
  ng "まとめ用の警告" "rc=$(rc "${c}") warnings=$(cat "${c}/warnings" 2>/dev/null)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
