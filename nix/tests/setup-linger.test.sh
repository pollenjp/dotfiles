#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/setup.sh の手順 linger (dotfiles.linger.enable。systemd の linger を有効にする) が、~/.local/state/dotfiles/group.json の
# tools.linger と loginctl の Linger を見て、要るときだけ sudo loginctl enable-linger を打つところを、使い捨ての checkout・HOME と
# 偽の sudo・loginctl で確かめる。
#
#   bash nix/tests/setup-linger.test.sh [<nix/scripts のパス>]
#
# flake の checks (setup-linger-test) が Nix のサンドボックスで流す。本物の sudo と loginctl は使わない。/etc・/run の代わりに、
# setup.sh の DOTFILES_SYSTEM_ROOT が指す使い捨ての場所を使う。
#
# ## 確かめること
#
#   - tools.linger が true で Linger が no なら、sudo loginctl enable-linger <id -un の名前> を打ち、有効にしたと出す
#   - Linger が yes なら sudo を呼ばない (「既存マシン更新」で毎回走るため)。残りの手作業にも linger の行を出さない
#   - Linger を読めない (logind がそのユーザーを知らず、loginctl show-user が落ちる) なら、yes でないとみなして有効にする
#   - tools.linger が false なら、loginctl も sudo も呼ばずに「dotfiles.linger.enable が off なので飛ばします」と出し、結果に
#     「↷ … (このホストでは off)」を出す (手で有効にした linger を外さない)。残りの手作業にも出さない
#   - group.json が無い・tools.linger が無い (この手順を持つ世代へまだ switch していない) なら、loginctl も sudo も呼ばない。
#     前の世代の group.json のまま --update --dry-run を流しても同じ
#   - systemd が動いていない (/run/systemd/system が無い) なら呼び出しなしで、loginctl が PATH に無いなら sudo を呼ばずに飛ばす
#   - NixOS (/etc/NIXOS がある) では loginctl enable-linger を打たず、残りの手作業に nixos-config の
#     users.users.<名前>.linger = true; と nixos-rebuild switch と、止め方 (dotfiles.linger.enable = false) を出す
#   - sudo がパスワードを訊けず端末も無ければ、打たずに 0 で終わり、残りの手作業に「linger が有効でない (Linger=no)」と
#     --steps linger と止め方を出す
#   - sudo loginctl enable-linger が落ちても手順は ✔ で終わり (後ろの手順を止めない)、警告のまとめに [linger] で出し
#     (sudo を使えないホストは dotfiles.linger.enable = false にする、とも出す)、残りの手作業にも出す
#   - --dry-run では打つコマンド (+ sudo loginctl enable-linger …) を見せるだけで、sudo を呼ばない
#   - 手順の並びで linger は switch の直後 (bootstrap の手順より前)。「既存マシン更新」(--update) にも同じ並びで入る
#
# ## 作り
#
# setup-system-units.test.sh と同じく、使い捨ての checkout (<ケース>/repo/nix/scripts/) に setup.sh を写し、要るコマンドだけを
# 並べた PATH で --steps linger を流す。group.json は <HOME>/.local/state/dotfiles/group.json に tools だけを書く。偽の sudo は
# 呼び出しを <ケース>/state/calls に書き留めて残りを exec し (-n true は FAKE_SUDO_ASKS があれば 1)、偽の loginctl も書き留めて、
# show-user は <ケース>/state/linger の中身 (無ければ no。--value が無ければ Linger=<値> の形) を出し (FAKE_SHOW_FAIL があれば 1)、
# enable-linger は state/linger に yes を書く (FAKE_ENABLE_FAIL があれば 1)。shebang は $BASH から作る (サンドボックスに
# /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
scripts=${1:-${here}/../scripts}
setup=${scripts}/setup.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/setup-linger-test.XXXXXX")
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

# setup.sh が loginctl に渡すユーザーの名前 (id -un)
user=$(id -un)
label='systemd の linger を有効にする (ログアウトしても user の service を止めない)'

# 要るコマンドだけを並べた PATH (git・gh・nix・home-manager・本物の sudo と loginctl は入れない)。true は偽の sudo が exec するので
# 外のコマンドが要る (command -v は builtin の名前を返すので、type -P で外のものを引く)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env awk sed grep sort head tr cat dirname basename readlink uname id mktemp mkdir rm chmod cksum cmp install ln true; do
  if ! p=$(type -P "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 偽の sudo と loginctl。loginctl の無いホストを作るときは、sudo だけの dir (fake-bin-nolc) を PATH に置く
fake_bin="${work}/fake-bin"
fake_bin_nolc="${work}/fake-bin-nolc"
mkdir -p "${fake_bin}" "${fake_bin_nolc}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf 'sudo %s\n' "$*" >>"${FAKE_STATE}/calls"
if [[ $1 == -n ]]; then
  [[ -z ${FAKE_SUDO_ASKS-} ]] || exit 1
  shift
fi
exec "$@"
EOF
} >"${fake_bin}/sudo"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf 'loginctl %s\n' "$*" >>"${FAKE_STATE}/calls"
case $1 in
  show-user)
    if [[ -n ${FAKE_SHOW_FAIL-} ]]; then
      echo "Failed to get user: User ID 1000 is not logged in or lingering" >&2
      exit 1
    fi
    v=$(cat "${FAKE_STATE}/linger" 2>/dev/null || echo no)
    case " $* " in
      *' --value '*) printf '%s\n' "${v}" ;;
      *) printf 'Linger=%s\n' "${v}" ;;
    esac
    ;;
  enable-linger)
    if [[ -n ${FAKE_ENABLE_FAIL-} ]]; then
      echo "Could not enable linger: Access denied" >&2
      exit 1
    fi
    echo yes >"${FAKE_STATE}/linger"
    ;;
  *)
    echo "偽の loginctl が知らない引数: $*" >&2
    exit 99
    ;;
esac
EOF
} >"${fake_bin}/loginctl"
cp "${fake_bin}/sudo" "${fake_bin_nolc}/sudo"
chmod +x "${fake_bin}/sudo" "${fake_bin}/loginctl" "${fake_bin_nolc}/sudo"

# 1 ケースぶんの checkout・HOME・system の置き場所を作り、その場所を出す。
#   <ケース>/repo/nix/scripts/setup.sh   写した setup.sh
#   <ケース>/home                         HOME
#   <ケース>/root                         DOTFILES_SYSTEM_ROOT (etc・run/systemd/system)
#   <ケース>/state                        偽の sudo・loginctl の書き留めと Linger
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/repo/nix/scripts" "${c}/repo/nix/hosts" "${c}/home" "${c}/tmp" "${c}/state" \
    "${c}/root/etc" "${c}/root/run/systemd/system"
  cp "${setup}" "${c}/repo/nix/scripts/setup.sh"
  printf '{ mkHome }:\n{\n  testhost = mkHome {\n    username = "test";\n  };\n}\n' >"${c}/repo/nix/hosts/default.nix"
  : >"${c}/state/calls"
  echo "${c}"
}

# group.json を置く。$1: ケース、$2: tools の object の中身 (home-manager の group.json と同じく空白を入れない)
group_json() {
  local d="$1/home/.local/state/dotfiles"
  mkdir -p "${d}"
  printf '{"group":"all","tools":{%s},"version":2}\n' "$2" >"${d}/group.json"
}
on='"herdrCore":true,"linger":true'

# $1: ケース、残り: setup.sh の引数。stdout・stderr・終了コードを <ケース>/{out,err,rc} に残す。PATH の偽の dir は fake_path
fake_path=${fake_bin}
run() {
  local c=$1
  shift
  : >"${c}/state/calls"
  env -i HOME="${c}/home" USER=test TMPDIR="${c}/tmp" NO_COLOR=1 \
    PATH="${fake_path}:${sys_bin}" \
    DOTFILES_LOCAL_DIR="${c}/local" DOTFILES_SYSTEM_ROOT="${c}/root" FAKE_STATE="${c}/state" \
    ${FAKE_SUDO_ASKS+"FAKE_SUDO_ASKS=${FAKE_SUDO_ASKS}"} ${FAKE_SHOW_FAIL+"FAKE_SHOW_FAIL=${FAKE_SHOW_FAIL}"} \
    ${FAKE_ENABLE_FAIL+"FAKE_ENABLE_FAIL=${FAKE_ENABLE_FAIL}"} \
    "${BASH}" "${c}/repo/nix/scripts/setup.sh" "$@" >"${c}/out" 2>"${c}/err" </dev/null
  echo $? >"${c}/rc"
}

rc() { cat "$1/rc"; }
show() { printf 'rc=%s\nout=%s\nerr=%s\ncalls=%s' "$(rc "$1")" "$(cat "$1/out")" "$(cat "$1/err")" "$(cat "$1/state/calls")"; }
sudo_calls() { grep -c '^sudo ' "$1/state/calls"; }
# 「残りの手作業」より後の stdout
after_post_notes() { sed -n '/^==> 残りの手作業/,$p' "$1/out"; }

echo "== setup.sh: 手順 linger (${setup})"

# 1. 有効でなければ有効にする
c=$(new_case enable)
group_json "${c}" "${on}"
run "${c}" --steps linger
if [[ $(rc "${c}") == 0 ]] && grep -qx "sudo loginctl enable-linger ${user}" "${c}/state/calls" \
  && grep -q "${user} の linger を有効にした" "${c}/out"; then
  ok "Linger が no なら sudo loginctl enable-linger <名前> を打ち、有効にしたと出す"
else
  ng "有効にする" "$(show "${c}")"
fi

# 2. 有効なら sudo を呼ばない
c=$(new_case already)
group_json "${c}" "${on}"
echo yes >"${c}/state/linger"
run "${c}" --steps linger
if [[ $(rc "${c}") == 0 && $(sudo_calls "${c}") == 0 ]] && grep -q "${user} の linger は有効です (Linger=yes)" "${c}/out" \
  && ! grep -q 'linger が有効でない' <<<"$(after_post_notes "${c}")"; then
  ok "Linger が yes なら sudo を呼ばず、残りの手作業にも出さない"
else
  ng "有効" "$(show "${c}")"
fi

# 3. 読めなければ有効にする
c=$(new_case unknown)
group_json "${c}" "${on}"
FAKE_SHOW_FAIL=1 run "${c}" --steps linger
if [[ $(rc "${c}") == 0 ]] && grep -qx "sudo loginctl enable-linger ${user}" "${c}/state/calls"; then
  ok "Linger を読めなければ (loginctl show-user が落ちる)、yes でないとみなして有効にする"
else
  ng "読めない" "$(show "${c}")"
fi

# 4. option が off
c=$(new_case off)
group_json "${c}" '"herdrCore":true,"linger":false'
run "${c}" --steps linger
if [[ $(rc "${c}") == 0 && ! -s ${c}/state/calls ]] \
  && grep -q 'このホストでは dotfiles.linger.enable が off なので飛ばします' "${c}/out" \
  && grep -qF "↷ ${label} (このホストでは off)" "${c}/out" \
  && ! grep -q 'linger が有効でない' <<<"$(after_post_notes "${c}")"; then
  ok "tools.linger が false なら、loginctl も sudo も呼ばずに飛ばし (↷)、残りの手作業にも出さない"
else
  ng "off" "$(show "${c}")"
fi

# 5. まだ switch していない (キーが無い・group.json が無い)
c=$(new_case no-key)
group_json "${c}" '"herdrCore":true'
run "${c}" --steps linger
c2=$(new_case no-file)
run "${c2}" --steps linger
if [[ $(rc "${c}") == 0 && ! -s ${c}/state/calls && $(rc "${c2}") == 0 && ! -s ${c2}/state/calls ]] \
  && grep -q 'まだ switch していない' "${c}/out" && grep -q 'まだ switch していない' "${c2}/out"; then
  ok "group.json が無い・tools.linger が無いなら、loginctl も sudo も呼ばない"
else
  ng "まだ switch していない" "$(show "${c}")"$'\n'"$(show "${c2}")"
fi

# 6. systemd が動いていない
c=$(new_case no-systemd)
rmdir "${c}/root/run/systemd/system"
group_json "${c}" "${on}"
run "${c}" --steps linger
if [[ $(rc "${c}") == 0 && ! -s ${c}/state/calls ]] && grep -q 'systemd が動いていないので飛ばします' "${c}/out"; then
  ok "systemd が動いていなければ、loginctl も sudo も呼ばずに飛ばす"
else
  ng "systemd が動いていない" "$(show "${c}")"
fi

# 7. loginctl が無い
c=$(new_case no-loginctl)
group_json "${c}" "${on}"
fake_path=${fake_bin_nolc} run "${c}" --steps linger
if [[ $(rc "${c}") == 0 && $(sudo_calls "${c}") == 0 ]] && grep -q 'loginctl が見つからないので飛ばします' "${c}/out"; then
  ok "loginctl が PATH に無ければ、sudo を呼ばずに飛ばす"
else
  ng "loginctl が無い" "$(show "${c}")"
fi

# 8. NixOS
c=$(new_case nixos)
group_json "${c}" "${on}"
: >"${c}/root/etc/NIXOS"
run "${c}" --steps linger
notes=$(after_post_notes "${c}")
if [[ $(rc "${c}") == 0 ]] && ! grep -q 'enable-linger' "${c}/state/calls" \
  && grep -qF "users.users.${user}.linger = true;" <<<"${notes}" && grep -q 'nixos-rebuild switch' <<<"${notes}" \
  && grep -qF 'dotfiles.linger.enable = false' <<<"${notes}"; then
  ok "NixOS では enable-linger を打たず、残りの手作業に nixos-config の users.users.<名前>.linger = true; と止め方を出す"
else
  ng "NixOS" "$(show "${c}")"
fi

# 9. sudo を訊けない
c=$(new_case asks)
group_json "${c}" "${on}"
FAKE_SUDO_ASKS=1 run "${c}" --steps linger
notes=$(after_post_notes "${c}")
if [[ $(rc "${c}") == 0 ]] && ! grep -q 'enable-linger' "${c}/state/calls" && grep -q 'sudo がパスワードを訊けない' "${c}/out" \
  && grep -qF 'linger が有効でない (Linger=no)' <<<"${notes}" && grep -qF -- '--steps linger で有効にする' <<<"${notes}" \
  && grep -qF 'dotfiles.linger.enable = false' <<<"${notes}"; then
  ok "sudo を訊けなければ打たずに 0 で終わり、残りの手作業にずれと --steps linger と止め方を出す"
else
  ng "sudo を訊けない" "$(show "${c}")"
fi

# 10. 打てない
c=$(new_case enable-fails)
group_json "${c}" "${on}"
FAKE_ENABLE_FAIL=1 run "${c}" --steps linger
notes=$(after_post_notes "${c}")
if [[ $(rc "${c}") == 0 ]] && grep -qF "✔ ${label}" "${c}/out" \
  && grep -qF "[linger] ${user} の linger を有効にできませんでした" "${c}/out" \
  && grep -qF 'sudo を使えないホストでは、そのホストの modules で dotfiles.linger.enable = false' "${c}/err" \
  && grep -qF 'linger が有効でない (Linger=no)' <<<"${notes}"; then
  ok "enable-linger が落ちても手順は ✔ で、警告のまとめに [linger] で出し (sudo を使えないホストの止め方も)、残りの手作業にも出す"
else
  ng "打てない" "$(show "${c}")"
fi

# 11. --dry-run
c=$(new_case dry-run)
group_json "${c}" "${on}"
run "${c}" --steps linger --dry-run
if [[ $(rc "${c}") == 0 && $(sudo_calls "${c}") == 0 ]] && grep -qF "+ sudo loginctl enable-linger ${user}" "${c}/out"; then
  ok "--dry-run では打つコマンドを見せるだけで、sudo を呼ばない"
else
  ng "--dry-run" "$(show "${c}")"
fi

# 12. 手順の並び (bootstrap の手順の前に来るかを見るため、偽の bootstrap を 1 つ置く。中身は流さない)
c=$(new_case order)
printf '#!/bin/sh\n# 並びを見るための偽の bootstrap\n' >"${c}/repo/nix/scripts/bootstrap-example.sh"
listed=$(env -i HOME="${c}/home" TMPDIR="${c}/tmp" NO_COLOR=1 PATH="${sys_bin}" \
  "${BASH}" "${c}/repo/nix/scripts/setup.sh" --list 2>&1 </dev/null)
after_switch=$(awk '$1 == "switch" { getline; print $1; exit }' <<<"${listed}")
after_linger=$(awk '$1 == "linger" { getline; print $1; exit }' <<<"${listed}")
if [[ ${after_switch} == linger && ${after_linger} == bootstrap-example ]]; then
  ok "手順の並びで linger は switch の直後 (bootstrap の手順より前)"
else
  ng "手順の並び" "${listed}"
fi

# 前の世代の group.json (tools.linger が無い) のまま --update --dry-run を流す
group_json "${c}" '"herdrCore":true'
run "${c}" --update --dry-run --host testhost
planned=$(sed -n '/^==> 実行する手順/,/^$/p' "${c}/out")
switch_n=$(grep -n '\. home-manager switch$' <<<"${planned}" | cut -d: -f1)
linger_n=$(grep -nF ". ${label}" <<<"${planned}" | cut -d: -f1)
if [[ -n ${switch_n} && -n ${linger_n} ]] && ((switch_n + 1 == linger_n)); then
  ok "既存マシン更新 (--update) にも、switch の直後に入る"
else
  ng "--update の並び" "$(show "${c}")"
fi
if [[ ! -s ${c}/state/calls ]] && grep -q 'まだ switch していない' "${c}/out"; then
  ok "前の世代の group.json のまま --update --dry-run を流しても、loginctl も sudo も呼ばない"
else
  ng "--update --dry-run (前の世代)" "$(show "${c}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
