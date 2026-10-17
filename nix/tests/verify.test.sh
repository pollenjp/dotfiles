#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/verify.sh が sandbox へ activate するとき、手元の user systemd に届かないように
# しているかを、使い捨ての checkout と偽の nix で確かめる。
#
#   bash nix/tests/verify.test.sh [<verify.sh のパス>]
#
# flake の checks (verify-test) が Nix のサンドボックスで流す。
#
# ## 確かめること
#
#   - activate は 2 回 (1 回目と冪等性の確認) とも、XDG_RUNTIME_DIR を sandbox の下
#     (<SANDBOX_HOME>/run) で受け取り、その場所は activate の時点で在る。手元の XDG_RUNTIME_DIR の
#     ままだと、activate が手元の user systemd に届き、sandbox と同じ名前の unit (cc-pages.service
#     など) を止めて起こし直す
#   - verify.sh は最後まで通る (「すべて通過しました。」)
#
# ## 作り
#
# verify.sh は自分の 1 つ上 (nix/) で git add と nix を流すので、使い捨ての checkout
# (<work>/repo/nix/scripts/) に写して流す。nix は偽物で、flake check は何もせず、build は -o の先に
# 偽の activate を持つ結果を置く。偽の activate は、受け取った XDG_RUNTIME_DIR と、その場所が
# 在るかを書き残す。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
verify=${1:-${here}/../scripts/verify.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/verify-test.XXXXXX")
# verify.sh の result_link (/tmp/hm-verify-*) は途中で落ちると残るので、偽の nix が書き残した先も消す
trap 'rm -f "$(cat "${work}/result-link" 2>/dev/null)"; rm -rf "${work}"' EXIT

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

tgit() {
  HOME="${work}/githome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git "$@"
}

# 使い捨ての checkout。verify.sh は git add -A をするので git の作業ツリーにする
repo="${work}/repo"
mkdir -p "${repo}/nix/scripts" "${repo}/nix/files" "${work}/githome"
cp "${verify}" "${repo}/nix/scripts/verify.sh"
tgit -C "${repo}" init -q

# 偽の nix。flake check は何もしない。build は -o の先 (verify.sh の result_link) に、結果への
# symlink を置く。結果の activate は、受け取った XDG_RUNTIME_DIR と、その場所が在るか (yes / no) を
# activate.log に 1 行ずつ足し、最後の `home-manager generations` 用の偽物を $HOME に置く
bin="${work}/bin"
mkdir -p "${bin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
# 偽の nix (verify.test.sh)
if [[ $1 == build ]]; then
  out=
  while (($#)); do
    if [[ $1 == -o ]]; then
      out=$2
      shift
    fi
    shift
  done
  printf '%s\n' "${out}" >"${FAKE_NIX_WORK}/result-link"
  res="${FAKE_NIX_WORK}/result"
  mkdir -p "${res}/home-files"
  {
    printf '#!%s\n' "${BASH}"
    cat <<'ACTIVATE'
# 偽の activate (verify.test.sh)
exists=no
if [[ -d ${XDG_RUNTIME_DIR:-} ]]; then
  exists=yes
fi
printf '%s\t%s\n' "${XDG_RUNTIME_DIR:-}" "${exists}" >>"${FAKE_NIX_WORK}/activate.log"
mkdir -p "${HOME}/.nix-profile/bin"
printf '#!%s\nexit 0\n' "${BASH}" >"${HOME}/.nix-profile/bin/home-manager"
chmod +x "${HOME}/.nix-profile/bin/home-manager"
ACTIVATE
  } >"${res}/activate"
  chmod +x "${res}/activate"
  ln -sfn "${res}" "${out}"
fi
exit 0
EOF
} >"${bin}/nix"
chmod +x "${bin}/nix"

# 手元の XDG_RUNTIME_DIR に見立てた場所を渡して流す
sandbox="${work}/hm-sandbox"
mkdir -p "${work}/user-run"
: >"${work}/activate.log"
env PATH="${bin}:${PATH}" FAKE_NIX_WORK="${work}" SANDBOX_HOME="${sandbox}" \
  XDG_RUNTIME_DIR="${work}/user-run" HOME="${work}/githome" \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  "${BASH}" "${repo}/nix/scripts/verify.sh" >"${work}/out" 2>&1
rc=$?

echo "== verify.sh"
if [[ ${rc} == 0 ]] && grep -qF 'すべて通過しました。' "${work}/out"; then
  ok "最後まで通る"
else
  ng "最後まで通らない (rc=${rc})" "$(tail -n 20 "${work}/out")"
fi

echo "== activate が受け取る XDG_RUNTIME_DIR"
n=0
while IFS=$'\t' read -r dir exists; do
  n=$((n + 1))
  if [[ ${dir} == "${sandbox}/run" && ${exists} == yes ]]; then
    ok "${n} 回目は sandbox の下 (在る)"
  else
    ng "${n} 回目が sandbox の下ではない" "受け取った値: ${dir:-(空)} (在る: ${exists})
期待する値: ${sandbox}/run (在る: yes)"
  fi
done <"${work}/activate.log"
if [[ ${n} == 2 ]]; then
  ok "activate を 2 回流す"
else
  ng "activate を流した回数が 2 ではない (${n} 回)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
