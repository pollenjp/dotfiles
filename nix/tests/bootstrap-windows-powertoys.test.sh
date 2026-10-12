#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-powertoys.sh の振る舞いを、使い捨ての HOME と偽の powershell.exe で確かめる。
#
#   bash nix/tests/bootstrap-windows-powertoys.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-powertoys-test) が Nix のサンドボックスで流す。
# 使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・default.json が無いときは powershell.exe を呼ばずに飛ばす
#   - 送れたら記録し、同じ default.json では呼ばない。変われば呼ぶ。--force なら変わらなくても呼ぶ
#   - PowerToys が動いていない (absent) ときも記録する。interop が使えない・出力がおかしいときは
#     手で読み直す方法を出し、記録しない。どれも exit 0
#
# 本物の powershell.exe を見せないよう、要るコマンドだけを symlink で並べた PATH で流す。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-powertoys.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-powertoys-test.XXXXXX")
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

sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head cut mkdir dirname sha256sum timeout; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# $1: 名前、$2: windows-files.json の中身 (空なら作らない)、$3: 1 なら default.json を置く
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager"
    printf '{"remapKeys":{"inProcess":[{"originalKeys":"20","newRemapKeys":"124"}]}}' \
      >"${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
  fi
  # 偽の powershell.exe。引数を記録し、FAKE_PS_OUT (既定 set) を CRLF で出して FAKE_PS_RC で終わる
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/ps-calls"
printf '%s\r\n' "${FAKE_PS_OUT-set}"
exit "${FAKE_PS_RC:-0}"
EOF
  } >"${h}/bin/powershell.exe"
  chmod +x "${h}/bin/powershell.exe"
  echo "${h}"
}

# $1: HOME、$2: 1 なら powershell.exe を PATH に置かない、残り: script の引数
run() {
  local h=$1 nops=$2
  shift 2
  local path="${h}/bin:${sys_bin}"
  if [[ ${nops} == 1 ]]; then
    path="${sys_bin}"
  fi
  env HOME="${h}" PATH="${path}" "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
ncalls() { grep -c '' "$1/ps-calls" 2>/dev/null || echo 0; }
record() { echo "$1/.local/state/dotfiles/powertoys-keyboard-manager.reloaded"; }

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

echo "== bootstrap-windows-powertoys.sh: ${script}"

# 1. 状態ファイルが無い / enable = false / default.json が無い: 呼ばずに飛ばす
for t in "nostate::1" "off:${state_off}:1" "nojson:${state_on}:0"; do
  name=${t%%:*}
  rest=${t#*:}
  state=${rest%:*}
  json=${rest##*:}
  h=$(new_home "t1-${name}" "${state}" "${json}")
  run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 0 && ! -e $(record "${h}") ]]; then
    ok "飛ばす (${name}): powershell.exe を呼ばない"
  else
    ng "飛ばす (${name})" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
  fi
done

# 2. 送れた: 記録する。名前付きイベントの名前を渡す
h=$(new_home t2 "${state_on}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] && outerr "${h}" | grep -q '読み直させました' \
  && grep -qF 'PowerToys_KeyboardManager_Event_Settings' "${h}/ps-calls" && grep -qF -- '-NoProfile' "${h}/ps-calls"; then
  ok "送れたら記録し、イベントの名前を渡す (CRLF の出力も読める)"
else
  ng "送れた" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 3. 同じ default.json: 呼ばない
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '読み直し済み'; then
  ok "同じ default.json なら呼ばない"
else
  ng "同じ default.json" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 4. --force: 同じでも呼ぶ
run "${h}" 0 --force
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 2 ]]; then
  ok "--force なら同じでも呼ぶ"
else
  ng "--force" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 5. default.json が変わった: 呼んで記録を更新する
printf '{"remapKeys":{"inProcess":[]}}' >"${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
before=$(cat "$(record "${h}")")
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 3 && $(cat "$(record "${h}")") != "${before}" ]]; then
  ok "default.json が変わったら呼んで記録を更新する"
else
  ng "変わった" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 6. PowerToys が動いていない (absent): 記録する
h=$(new_home t6 "${state_on}" 1)
FAKE_PS_OUT=absent run "${h}" 0
if [[ $(rc "${h}") == 0 && -s $(record "${h}") ]] && outerr "${h}" | grep -q '動いていません'; then
  ok "PowerToys が動いていなければ記録する (起動したときに読む)"
else
  ng "absent" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. powershell.exe が無い: 手で読み直す方法を出し、記録しない
h=$(new_home t7 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 && ! -e $(record "${h}") ]] && outerr "${h}" | grep -q 'オフにしてオンに戻す'; then
  ok "powershell.exe が無ければ手で読み直す方法を出し、記録しない"
else
  ng "powershell.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 8. powershell.exe が失敗する / 知らない出力: 手で読み直す方法を出し、記録しない
for t in "126:" "0:Exec format error"; do
  h=$(new_home "t8-${t%%:*}" "${state_on}" 1)
  FAKE_PS_RC=${t%%:*} FAKE_PS_OUT=${t#*:} run "${h}" 0
  if [[ $(rc "${h}") == 0 && ! -e $(record "${h}") ]] && outerr "${h}" | grep -q 'オフにしてオンに戻す'; then
    ok "powershell.exe が失敗・知らない出力 (rc=${t%%:*}) なら記録しない"
  else
    ng "失敗 (rc=${t%%:*})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 9. 知らない引数: exit 2
h=$(new_home t9 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 && $(ncalls "${h}") == 0 ]]; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
