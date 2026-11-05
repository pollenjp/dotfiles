#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/setup.sh の system の unit の手順 (wsl-mtu-guard・exe-exec-trace) が、home-manager の生成した unit を
# /etc/systemd/system へ入れる・入れ替える・止めて消すところを、使い捨ての checkout・HOME と偽の sudo・systemctl で
# 確かめる。
#
#   bash nix/tests/setup-system-units.test.sh [<nix/scripts のパス>]
#
# flake の checks (setup-system-units-test) が Nix のサンドボックスで流す。本物の sudo と systemd は使わない。
# /etc・/nix/var・/run の代わりに、setup.sh の DOTFILES_SYSTEM_ROOT が指す使い捨ての場所を使う。
#
# ## 確かめること
#
#   - 生成された unit (~/.local/share/dotfiles/systemd/<unit>) が無く、入ってもいなければ、sudo も systemctl も
#     呼ばずに何もしない (option が無効なマシン)
#   - systemd が動いていなければ (/run/systemd/system が無い)、sudo を呼ばずに飛ばす
#   - 入っていなければ、生成された unit を store の実体まで辿って /etc/systemd/system へ入れ、GC root
#     (/nix/var/nix/gcroots/<unit から .service を除いた名前>) をその実体へ張り、daemon-reload・enable・restart の順に打つ。
#     wsl-mtu-guard なら「eth0 の MTU を見張り始めた」と記録の読み方を出す
#   - 揃って動いていれば sudo を呼ばない (「既存マシン更新」で毎回走るため)。止まっていれば、入れ直さずに起こす
#   - 生成された unit の中身が変われば (上限を変えた)、入れ替えて起こし直す
#   - 生成された unit が無くなれば (option を false に戻した)、止めて消し、GC root も消す
#   - sudo がパスワードを訊けず端末も無ければ、入れずに 0 で終わり、最後の「残りの手作業」にずれと
#     --steps wsl-mtu-guard を出す (exe-exec-trace の案内より前に)。exe-exec-trace のずれの案内は今の文のまま
#   - 起こせなければ (restart が失敗)、手順が失敗し、journal の読み方を出す
#   - exe-exec-trace も同じ処理で、出す文は今のまま (記録の読み方・最新で動いている)
#   - 手順の並びで wsl-mtu-guard は chsh の後、exe-exec-trace の直前に来る。「既存マシン更新」(--update) にも
#     同じ並びで入る (setup は失敗した手順で止まるので、トレーサが起動に失敗しても見張りの入れ替えは止まらない)
#
# ## 作り
#
# setup-post-notes.test.sh と同じく、使い捨ての checkout (<ケース>/repo/nix/scripts/) に setup.sh を写し、要るコマンドだけを
# 並べた PATH で --steps を流す。生成された unit は <HOME>/.local/share/dotfiles/systemd/<unit> から <ケース>/store/ の
# ファイルへの symlink で置く (home-manager の置き方と同じ)。偽の sudo は呼び出しを <ケース>/state/calls に書き留めて
# 残りを exec し (-n true は FAKE_SUDO_ASKS があれば 1)、偽の systemctl も書き留めて、<ケース>/state/ の enabled.<unit>・
# active.<unit> を付け外しする (restart は FAKE_RESTART_FAIL があれば 1)。shebang は $BASH から作る (サンドボックスに
# /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
scripts=${1:-${here}/../scripts}
setup=${scripts}/setup.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/setup-system-units-test.XXXXXX")
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

guard=dotfiles-wsl-mtu-guard.service
trace=dotfiles-exe-exec-trace.service

# 要るコマンドだけを並べた PATH (git・gh・nix・home-manager・本物の sudo と systemctl は入れない)。true は偽の
# sudo が exec するので外のコマンドが要る (command -v は builtin の名前を返すので、type -P で外のものを引く)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq awk sed grep sort head tr cat dirname basename readlink uname id mktemp mkdir rm chmod cksum cmp install ln true; do
  if ! p=$(type -P "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

fake_bin="${work}/fake-bin"
mkdir -p "${fake_bin}"
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
printf 'systemctl %s\n' "$*" >>"${FAKE_STATE}/calls"
s=${FAKE_STATE}
unit=${!#}
case $1 in
  is-enabled) [[ -e ${s}/enabled.${unit} ]] ;;
  is-active) [[ -e ${s}/active.${unit} ]] ;;
  enable) : >"${s}/enabled.${unit}" ;;
  restart)
    if [[ -n ${FAKE_RESTART_FAIL-} ]]; then
      echo "Job for ${unit} failed because the control process exited with error code." >&2
      exit 1
    fi
    : >"${s}/active.${unit}"
    ;;
  disable) rm -f "${s}/enabled.${unit}" "${s}/active.${unit}" ;;
  daemon-reload) ;;
  *)
    echo "偽の systemctl が知らない引数: $*" >&2
    exit 99
    ;;
esac
EOF
} >"${fake_bin}/systemctl"
chmod +x "${fake_bin}/sudo" "${fake_bin}/systemctl"

# 1 ケースぶんの checkout・HOME・system の置き場所を作り、その場所を出す。
#   <ケース>/repo/nix/scripts/setup.sh   写した setup.sh
#   <ケース>/home                         HOME
#   <ケース>/root                         DOTFILES_SYSTEM_ROOT (etc/systemd/system・nix/var/nix/gcroots・run/systemd/system)
#   <ケース>/store                        生成された unit の実体
#   <ケース>/state                        偽の sudo・systemctl の書き留めと状態
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/repo/nix/scripts" "${c}/repo/nix/hosts" "${c}/home" "${c}/tmp" "${c}/store" "${c}/state" \
    "${c}/root/etc/systemd/system" "${c}/root/nix/var/nix/gcroots" "${c}/root/run/systemd/system"
  cp "${setup}" "${c}/repo/nix/scripts/setup.sh"
  printf '{ mkHome }:\n{\n  testhost = mkHome {\n    username = "test";\n  };\n}\n' >"${c}/repo/nix/hosts/default.nix"
  : >"${c}/state/calls"
  echo "${c}"
}

# 生成された unit を置く (symlink を張り替える)。$1: ケース、$2: unit、$3: 実体の名前、$4: 中身
generate() {
  local d="$1/home/.local/share/dotfiles/systemd"
  mkdir -p "${d}"
  printf '%s\n' "$4" >"$1/store/$3"
  ln -sfn "$1/store/$3" "${d}/$2"
}

# $1: ケース、残り: setup.sh の引数。stdout・stderr・終了コードを <ケース>/{out,err,rc} に残す
run() {
  local c=$1
  shift
  : >"${c}/state/calls"
  env -i HOME="${c}/home" USER=test TMPDIR="${c}/tmp" NO_COLOR=1 \
    PATH="${fake_bin}:${sys_bin}" \
    DOTFILES_LOCAL_DIR="${c}/local" DOTFILES_SYSTEM_ROOT="${c}/root" FAKE_STATE="${c}/state" \
    ${FAKE_SUDO_ASKS+"FAKE_SUDO_ASKS=${FAKE_SUDO_ASKS}"} ${FAKE_RESTART_FAIL+"FAKE_RESTART_FAIL=${FAKE_RESTART_FAIL}"} \
    "${BASH}" "${c}/repo/nix/scripts/setup.sh" "$@" >"${c}/out" 2>"${c}/err" </dev/null
  echo $? >"${c}/rc"
}

rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
calls() { cat "$1/state/calls"; }
# 偽の systemctl に届いた呼び出し (sudo を通したものも)。is-enabled・is-active は除く
systemctl_ops() { sed -n 's/^systemctl //p' "$1/state/calls" | grep -v '^is-' || true; }
sudo_calls() { grep -c '^sudo ' "$1/state/calls"; }
show() { printf 'rc=%s\nout=%s\nerr=%s\ncalls=%s' "$(rc "$1")" "$(out "$1")" "$(cat "$1/err")" "$(calls "$1")"; }
dst() { printf '%s' "$1/root/etc/systemd/system/$2"; }
gcroot() { printf '%s' "$1/root/nix/var/nix/gcroots/${2%.service}"; }
# 「残りの手作業」より後の stdout
after_post_notes() { sed -n '/^==> 残りの手作業/,$p' "$1/out"; }

echo "== setup.sh: system の unit の手順 (${setup})"

# 1. option が無効なマシン
c=$(new_case none)
run "${c}" --steps wsl-mtu-guard,exe-exec-trace
if [[ $(rc "${c}") == 0 && ! -s ${c}/state/calls ]] && grep -q '入ってもいないので何もしない' "${c}/out"; then
  ok "生成された unit が無く入ってもいなければ、sudo も systemctl も呼ばない"
else
  ng "option が無効" "$(show "${c}")"
fi

# 2. systemd が動いていない
c=$(new_case no-systemd)
rmdir "${c}/root/run/systemd/system"
generate "${c}" "${guard}" a-guard.service 'ExecStart=/nix/store/a/bin/pjp-wsl-mtu-guard eth0 1350'
run "${c}" --steps wsl-mtu-guard
if [[ $(rc "${c}") == 0 && $(sudo_calls "${c}") == 0 && ! -e $(dst "${c}" "${guard}") ]] \
  && grep -q 'systemd が動いていないので飛ばします' "${c}/out"; then
  ok "systemd が動いていなければ、sudo を呼ばずに飛ばす"
else
  ng "systemd が動いていない" "$(show "${c}")"
fi

# 3〜7. 入れる → 揃っていれば何もしない → 止まっていれば起こす → 中身が変われば入れ替える → 無くなれば消す
c=$(new_case guard)
generate "${c}" "${guard}" a-guard.service 'ExecStart=/nix/store/a/bin/pjp-wsl-mtu-guard eth0 1350'
run "${c}" --steps wsl-mtu-guard
if [[ $(rc "${c}") == 0 ]] && cmp -s "${c}/store/a-guard.service" "$(dst "${c}" "${guard}")" \
  && [[ $(readlink "$(gcroot "${c}" "${guard}")") == "${c}/store/a-guard.service" ]] \
  && [[ $(systemctl_ops "${c}") == "daemon-reload"$'\n'"enable ${guard}"$'\n'"restart ${guard}" ]] \
  && grep -q "${guard} が eth0 の MTU を見張り始めた" "${c}/out" && grep -q 'journalctl -u dotfiles-wsl-mtu-guard' "${c}/out"; then
  ok "入っていなければ、store の実体を入れて GC root を張り、daemon-reload・enable・restart の順に打つ"
else
  ng "入れる" "$(show "${c}")"
fi

run "${c}" --steps wsl-mtu-guard
if [[ $(rc "${c}") == 0 && $(sudo_calls "${c}") == 0 && -z $(systemctl_ops "${c}") ]] \
  && grep -q "${guard} は最新で、動いています" "${c}/out"; then
  ok "揃って動いていれば sudo を呼ばない"
else
  ng "揃っている" "$(show "${c}")"
fi

rm -f "${c}/state/active.${guard}"
run "${c}" --steps wsl-mtu-guard
if [[ $(rc "${c}") == 0 && $(systemctl_ops "${c}") == "enable ${guard}"$'\n'"restart ${guard}" ]] \
  && ! grep -q '^sudo install' "${c}/state/calls" && grep -q '止まっているので起こします' "${c}/out"; then
  ok "止まっていれば、入れ直さずに起こす"
else
  ng "止まっている" "$(show "${c}")"
fi

generate "${c}" "${guard}" b-guard.service 'ExecStart=/nix/store/a/bin/pjp-wsl-mtu-guard eth0 1300'
run "${c}" --steps wsl-mtu-guard
if [[ $(rc "${c}") == 0 && $(systemctl_ops "${c}") == "daemon-reload"$'\n'"enable ${guard}"$'\n'"restart ${guard}" ]] \
  && cmp -s "${c}/store/b-guard.service" "$(dst "${c}" "${guard}")" \
  && [[ $(readlink "$(gcroot "${c}" "${guard}")") == "${c}/store/b-guard.service" ]]; then
  ok "生成された unit の中身が変われば、入れ替えて起こし直す"
else
  ng "入れ替える" "$(show "${c}")"
fi

rm -f "${c}/home/.local/share/dotfiles/systemd/${guard}"
run "${c}" --steps wsl-mtu-guard
if [[ $(rc "${c}") == 0 && $(systemctl_ops "${c}") == "disable --now ${guard}"$'\n'"daemon-reload" ]] \
  && [[ ! -e $(dst "${c}" "${guard}") && ! -L $(gcroot "${c}" "${guard}") ]] && grep -q 'を止めて消します' "${c}/out"; then
  ok "生成された unit が無くなれば、止めて消し、GC root も消す"
else
  ng "消す" "$(show "${c}")"
fi

# 8. sudo を訊けない
c=$(new_case asks)
generate "${c}" "${guard}" a-guard.service 'ExecStart=/nix/store/a/bin/pjp-wsl-mtu-guard eth0 1350'
generate "${c}" "${trace}" a-trace.service 'ExecStart=/nix/store/t/bin/pjp-exe-exec-trace --json'
FAKE_SUDO_ASKS=1 run "${c}" --steps wsl-mtu-guard,exe-exec-trace
notes=$(after_post_notes "${c}")
guard_line=$(grep -n 'eth0 の MTU を見張る system の unit: unit がまだ入っていない。' <<<"${notes}" | cut -d: -f1)
trace_line=$(grep -n '.exe の起動を記録する system の unit: unit がまだ入っていない。' <<<"${notes}" | cut -d: -f1)
if [[ $(rc "${c}") == 0 && ! -e $(dst "${c}" "${guard}") && ! -e $(dst "${c}" "${trace}") && -n ${guard_line} && -n ${trace_line} ]] \
  && ((guard_line < trace_line)) && grep -q 'sudo がパスワードを訊けない' "${c}/out" \
  && grep -q -- '--steps wsl-mtu-guard で揃える (中で sudo を呼ぶ)。' <<<"${notes}" \
  && grep -q -- '--steps exe-exec-trace で揃える (中で sudo を呼ぶ。ADR 012)。' <<<"${notes}"; then
  ok "sudo を訊けなければ入れずに 0 で終わり、残りの手作業にずれと --steps を出す (wsl-mtu-guard が先)"
else
  ng "sudo を訊けない" "$(show "${c}")"
fi

# 9. 起こせない
c=$(new_case restart-fails)
generate "${c}" "${guard}" a-guard.service 'ExecStart=/nix/store/a/bin/pjp-wsl-mtu-guard eth0 1350'
FAKE_RESTART_FAIL=1 run "${c}" --steps wsl-mtu-guard
if [[ $(rc "${c}") != 0 ]] && grep -q "${guard} を起動できませんでした: sudo journalctl -u ${guard} -n 30" "${c}/out" "${c}/err"; then
  ok "起こせなければ手順が失敗し、journal の読み方を出す"
else
  ng "起こせない" "$(show "${c}")"
fi

# 10. exe-exec-trace も同じ処理で、出す文は今のまま
c=$(new_case trace)
generate "${c}" "${trace}" a-trace.service 'ExecStart=/nix/store/t/bin/pjp-exe-exec-trace --json'
run "${c}" --steps exe-exec-trace
first_ok=0
if [[ $(rc "${c}") == 0 && $(readlink "$(gcroot "${c}" "${trace}")") == "${c}/store/a-trace.service" ]] \
  && grep -qx "  ${trace} が記録を始めた。読むとき:" "${c}/out" \
  && grep -qx '    journalctl -u dotfiles-exe-exec-trace -o cat | pjp-exe-exec-trace --pretty' "${c}/out"; then
  first_ok=1
fi
run "${c}" --steps exe-exec-trace
if [[ ${first_ok} == 1 && $(rc "${c}") == 0 && $(sudo_calls "${c}") == 0 ]] && grep -qx "  ${trace} は最新で、動いています。" "${c}/out"; then
  ok "exe-exec-trace も同じ処理で入れ、出す文は今のまま (記録の読み方・最新で動いている)"
else
  ng "exe-exec-trace" "$(show "${c}")"
fi

# 11. 手順の並び
c=$(new_case order)
listed=$(env -i HOME="${c}/home" TMPDIR="${c}/tmp" NO_COLOR=1 PATH="${sys_bin}" \
  "${BASH}" "${c}/repo/nix/scripts/setup.sh" --list 2>&1 </dev/null)
ids=$(awk '$1 == "chsh" || $1 == "wsl-mtu-guard" || $1 == "exe-exec-trace" { print $1 }' <<<"${listed}")
last=$(awk 'NF { id = $1 } END { print id }' <<<"${listed}")
if [[ ${ids} == $'chsh\nwsl-mtu-guard\nexe-exec-trace' && ${last} == exe-exec-trace ]]; then
  ok "手順の並びで wsl-mtu-guard は chsh の後、exe-exec-trace の直前"
else
  ng "手順の並び" "${listed}"
fi

run "${c}" --update --dry-run --host testhost
planned=$(sed -n '/^==> 実行する手順/,/^$/p' "${c}/out")
guard_n=$(grep -n 'WSL の eth0 の MTU を上限まで下げ続ける system の unit' <<<"${planned}" | cut -d: -f1)
trace_n=$(grep -n 'WSL の .exe の起動を常時記録する system の unit' <<<"${planned}" | cut -d: -f1)
if [[ -n ${guard_n} && -n ${trace_n} ]] && ((guard_n + 1 == trace_n)); then
  ok "既存マシン更新 (--update) にも、exe-exec-trace の直前に入る"
else
  ng "--update の並び" "$(show "${c}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
