#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-t3-code.sh が、T3 Code の settings.json の決めたキーを状態ファイル (~/.local/state/dotfiles/t3-code.json) の値に
# 合わせ、状態を出すことを、使い捨ての HOME と偽の t3・systemctl・loginctl・claude-account で確かめる。
#
#   bash nix/tests/bootstrap-t3-code.test.sh <bootstrap-t3-code.sh のパス> <nix/files/t3-code/managed-settings.json のパス>
#
# flake の checks (bootstrap-t3-code-test) が Nix のサンドボックスで流す。使うのは bash・jq・coreutils・grep だけ。
#
# ## 確かめること
#
#   - settings.json が無ければ、合わせるキーだけで作る (dir も。ENTRYPOINT が on なら environment に 1 つ)
#   - ほかのキー (idleCompaction など) と順を残し、claudeAgent の config のほかのキー (launchArgs) と environment のほかの要素を残す。
#     ENTRYPOINT が on なら同じ名前の要素を最初の位置で置き換え (重なりは 1 つにまとめ)、無ければ末尾に足す。off なら外し、
#     environment が無ければ作らない
#   - そろっていれば書かない (inode が変わらない)。書くときは元の mode を保つ
#   - lavie の手で書いた settings.json (2026-11-22) に on で当てると、足すのは defaultModelSelection・defaultThreadEnvMode だけ
#   - 壊れた JSON・合わせるキーの型が違う (environment が object)・symlink なら、書き換えずに警告して exit 0
#   - 状態ファイルが無い・形が違うなら、警告して exit 0 (settings.json を作らない)
#   - 状態: runtime の .install-complete が無ければ警告して止まる。t3 --version が落ちれば nix-ld の案内。linger が no・service が
#     動いていない・t3 が current と読まない・claude-t3 にログインしていない・T3 Connect が NOT reachable なら、それぞれ警告 (exit 0)。
#     どれもそろっていれば警告を出さず、版・service・claude-t3・T3 Connect の行を出す
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、警告をまとめ用のファイルにも残す

set -u -o pipefail

script=${1:?bootstrap-t3-code.sh のパスを渡す}
managed=${2:?nix/files/t3-code/managed-settings.json のパスを渡す}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-t3-code-test.XXXXXX")
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

# 偽のコマンド。ふるまいは HOME の下の印のファイルで変える (shebang は $BASH から作る。Nix のサンドボックスには /usr/bin/env が無い)
fake_bin="${work}/bin"
mkdir -p "${fake_bin}"
write_fake() { # $1: 名前、$2: 本文
  printf '#!%s\n%s\n' "${BASH}" "$2" >"${fake_bin}/$1"
  chmod +x "${fake_bin}/$1"
}
# 偽物の本文は偽物の中で展開する
# shellcheck disable=SC2016
write_fake loginctl 'cat "${HOME}/fake/linger" 2>/dev/null || echo yes'
# shellcheck disable=SC2016
write_fake systemctl 'case "$2" in
  is-enabled) cat "${HOME}/fake/enabled" 2>/dev/null || echo enabled ;;
  is-active) cat "${HOME}/fake/active" 2>/dev/null || echo active ;;
esac'
# shellcheck disable=SC2016
write_fake claude-account '[[ -e ${HOME}/fake/no-login ]] && exit 1
echo "t3: subscription (ログイン済み)"'

# 1 ケースぶんの HOME を作る。$1: 名前、$2: clearClaudeEntrypoint (true・false。空なら状態ファイルを作らない)
new_home() {
  local h="${work}/$1" rt
  rt="${h}/.t3/runtime/versions/0.1.11"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/fake" "${rt}"
  printf '0.1.11\n' >"${rt}/.install-complete"
  # shellcheck disable=SC2016 # 偽の t3 の本文は偽物の中で展開する
  printf '#!%s\n%s\n' "${BASH}" 'case "$1" in
  --version) [[ -e ${HOME}/fake/t3-broken ]] && { echo "cannot execute: required file not found" >&2; exit 127; }; echo "t3 v0.1.11" ;;
  service) cat "${HOME}/fake/service-status" 2>/dev/null || printf "T3 Code service\n  Status: installed · t3@0.1.11\n" ;;
  connect) cat "${HOME}/fake/connect-status" 2>/dev/null || printf "T3 Connect\n  Environment link: ready\n" ;;
esac' >"${rt}/t3"
  chmod +x "${rt}/t3"
  if [[ -n $2 ]]; then
    jq -n --arg rt "${rt}" --argjson clear "$2" --slurpfile m "${managed}" \
      '{version: "0.1.11", runtime: $rt, clearClaudeEntrypoint: $clear, managed: $m[0]}' >"${h}/.local/state/dotfiles/t3-code.json"
  fi
  echo "${h}"
}

run() {
  local h=$1
  rm -f "${h}/warnings"
  env -u T3CODE_HOME HOME="${h}" PATH="${fake_bin}:${PATH}" DOTFILES_SETUP_WARNINGS="${h}/warnings" \
    "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}
rc() { cat "$1/rc"; }
log() { echo "rc=$(rc "$1") out=$(cat "$1/out") err=$(cat "$1/err") warnings=$(cat "$1/warnings" 2>/dev/null)"; }
quiet() { [[ ! -s $1/err && ! -s $1/warnings ]]; }
warned() { [[ -s $1/err && -s $1/warnings ]]; }
settings_of() { echo "$1/.t3/userdata/settings.json"; }
put_settings() { # $1: HOME、$2: 中身
  mkdir -p "$1/.t3/userdata"
  printf '%s\n' "$2" >"$(settings_of "$1")"
}
# 書いたファイルのキーの並び (上の段)
keys_of() { jq -c 'keys_unsorted' "$(settings_of "$1")"; }
env_of() { jq -c '.providerInstances.claudeAgent.environment' "$(settings_of "$1")"; }

dms=$(jq -c '.defaultModelSelection' "${managed}")
entry=$(jq -c '.entrypointEnvironment' "${managed}")

# 1. 無ければ合わせるキーだけで作る
h=$(new_home create true)
run "${h}"
s=$(settings_of "${h}")
if [[ $(rc "${h}") == 0 && -f ${s} ]] && quiet "${h}" \
  && [[ $(jq -c '.providerInstances.claudeAgent' "${s}") == "{\"driver\":\"claudeAgent\",\"config\":{\"homePath\":\"~/.claude-t3\"},\"environment\":[${entry}]}" ]] \
  && [[ $(jq -c '.defaultModelSelection' "${s}") == "${dms}" && $(jq -r '.defaultThreadEnvMode' "${s}") == worktree ]]; then
  ok "settings.json が無ければ合わせるキーだけで作る (ENTRYPOINT が on なら environment に 1 つ)"
else
  ng "作る" "$(log "${h}") settings=$(cat "${s}" 2>/dev/null)"
fi

# 2. ほかのキーと順・config と environment のほかの要素を残し、ENTRYPOINT を最初の位置で置き換える
h=$(new_home keep true)
put_settings "${h}" '{"idleCompaction":"onReturn","providerInstances":{"codex":{"driver":"codex"},"claudeAgent":{"driver":"old","config":{"launchArgs":"--x","homePath":"~/.claude"},"environment":[{"name":"A","value":"1","sensitive":false},{"name":"CLAUDE_CODE_ENTRYPOINT","value":"","sensitive":true,"secret":{"provider":"p","reference":"r"}},{"name":"B","value":"2","sensitive":false},{"name":"CLAUDE_CODE_ENTRYPOINT","value":"x","sensitive":false}]}},"defaultThreadEnvMode":"local","linkedEnvironmentsEnabled":true}'
chmod 640 "$(settings_of "${h}")"
run "${h}"
s=$(settings_of "${h}")
if [[ $(rc "${h}") == 0 ]] && quiet "${h}" \
  && [[ $(keys_of "${h}") == '["idleCompaction","providerInstances","defaultThreadEnvMode","linkedEnvironmentsEnabled","defaultModelSelection"]' ]] \
  && [[ $(jq -c '.providerInstances | keys_unsorted' "${s}") == '["codex","claudeAgent"]' ]] \
  && [[ $(jq -c '.providerInstances.claudeAgent.config' "${s}") == '{"launchArgs":"--x","homePath":"~/.claude-t3"}' ]] \
  && [[ $(jq -r '.providerInstances.claudeAgent.driver' "${s}") == claudeAgent ]] \
  && [[ $(env_of "${h}") == "[{\"name\":\"A\",\"value\":\"1\",\"sensitive\":false},${entry},{\"name\":\"B\",\"value\":\"2\",\"sensitive\":false}]" ]] \
  && [[ $(jq -r '.defaultThreadEnvMode' "${s}") == worktree ]] && [[ -n $(find "${s}" -prune -perm 640) ]]; then
  ok "ほかのキーと順・config と environment のほかの要素を残し、ENTRYPOINT を最初の位置で 1 つに置き換え、mode を保つ"
else
  ng "残して合わせる" "$(log "${h}") settings=$(cat "${s}")"
fi

# 3. そろっていれば書かない
before=$(stat -c '%i' "${s}")
run "${h}"
if [[ $(rc "${h}") == 0 ]] && quiet "${h}" && [[ $(stat -c '%i' "${s}") == "${before}" ]] && grep -Fq 'そろっています' "${h}/out"; then
  ok "そろっていれば書かない (inode が変わらない)"
else
  ng "そろっている" "$(log "${h}")"
fi

# 4. ENTRYPOINT が off なら外し、environment が無ければ作らない
h=$(new_home off false)
put_settings "${h}" "{\"providerInstances\":{\"claudeAgent\":{\"driver\":\"claudeAgent\",\"environment\":[${entry},{\"name\":\"B\",\"value\":\"2\",\"sensitive\":false}]}}}"
run "${h}"
h2=$(new_home off-none false)
put_settings "${h2}" '{"providerInstances":{"claudeAgent":{"driver":"claudeAgent"}}}'
run "${h2}"
if [[ $(rc "${h}") == 0 && $(env_of "${h}") == '[{"name":"B","value":"2","sensitive":false}]' ]] \
  && [[ $(rc "${h2}") == 0 && $(env_of "${h2}") == null ]] && quiet "${h}" && quiet "${h2}"; then
  ok "ENTRYPOINT が off なら同じ名前の要素を外し、environment が無ければ作らない"
else
  ng "ENTRYPOINT が off" "$(log "${h}") / $(log "${h2}")"
fi

# 5. lavie の手で書いた settings.json に on で当てると、足すのは defaultModelSelection・defaultThreadEnvMode だけ
h=$(new_home lavie true)
lavie='{"idleCompaction":"onReturn","linkedEnvironmentsEnabled":true,"providerInstances":{"claudeAgent":{"driver":"claudeAgent","config":{"homePath":"~/.claude-t3"},"environment":[{"name":"CLAUDE_CODE_ENTRYPOINT","value":""}]}}}'
put_settings "${h}" "${lavie}"
run "${h}"
s=$(settings_of "${h}")
want=$(jq -c --argjson d "${dms}" --argjson e "${entry}" '.providerInstances.claudeAgent.environment = [$e] | .defaultModelSelection = $d | .defaultThreadEnvMode = "worktree"' <<<"${lavie}")
if [[ $(rc "${h}") == 0 && $(jq -c . "${s}") == "${want}" ]] && quiet "${h}"; then
  ok "lavie の settings.json には defaultModelSelection・defaultThreadEnvMode を足し、ENTRYPOINT の要素に sensitive を足すだけ"
else
  ng "lavie の settings.json" "$(log "${h}") settings=$(cat "${s}")"
fi

# 6. 壊れた JSON・型が違う・symlink は書き換えずに警告して exit 0
bad=0
for c in broken type link; do
  h=$(new_home "bad-${c}" true)
  case ${c} in
    broken) put_settings "${h}" '{"providerInstances":' ;;
    type) put_settings "${h}" '{"providerInstances":{"claudeAgent":{"environment":{"name":"x"}}}}' ;;
    link)
      mkdir -p "${h}/.t3/userdata"
      printf '{}\n' >"${h}/elsewhere.json"
      ln -s "${h}/elsewhere.json" "$(settings_of "${h}")"
      ;;
  esac
  before=$(cat "$(settings_of "${h}")")
  run "${h}"
  if [[ $(rc "${h}") != 0 ]] || ! warned "${h}" || [[ $(cat "$(settings_of "${h}")") != "${before}" ]] \
    || [[ ${c} == link && ! -L $(settings_of "${h}") ]]; then
    bad=1
    ng "${c} は書き換えずに警告" "$(log "${h}")"
  fi
done
((bad == 0)) && ok "壊れた JSON・合わせるキーの型が違う・symlink なら、書き換えずに警告して exit 0"

# 7. 状態ファイルが無い・形が違うなら警告して exit 0 (settings.json を作らない)
h=$(new_home nostate "")
run "${h}"
h2=$(new_home badstate true)
printf '{"version":1}\n' >"${h2}/.local/state/dotfiles/t3-code.json"
run "${h2}"
if [[ $(rc "${h}") == 0 && $(rc "${h2}") == 0 ]] && warned "${h}" && warned "${h2}" \
  && [[ ! -e $(settings_of "${h}") && ! -e $(settings_of "${h2}") ]]; then
  ok "状態ファイルが無い・形が違うなら、警告して exit 0 (settings.json を作らない)"
else
  ng "状態ファイル" "$(log "${h}") / $(log "${h2}")"
fi

# 8. 状態: そろっていれば警告を出さず、版・service・claude-t3・T3 Connect の行を出す
h=$(new_home status-ok true)
run "${h}"
if [[ $(rc "${h}") == 0 ]] && quiet "${h}" && grep -Fq 'T3 Code: t3 v0.1.11' "${h}/out" \
  && grep -Fq 'Status: installed · t3@0.1.11' "${h}/out" && grep -Fq 'claude-t3): t3: subscription' "${h}/out" \
  && grep -Fq 'T3 Connect: Environment link: ready' "${h}/out"; then
  ok "状態がそろっていれば警告を出さず、版・service・claude-t3・T3 Connect の行を出す"
else
  ng "状態がそろっている" "$(log "${h}")"
fi

# 9. 状態の警告 (それぞれ exit 0)
check_warn() { # $1: 名前、$2: 印のファイル、$3: 中身、$4: 警告に出る文字
  local h
  h=$(new_home "warn-$1" true)
  printf '%s\n' "$3" >"${h}/fake/$2"
  run "${h}"
  if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -Fq -- "$4" "${h}/err" && grep -Fq -- "$4" "${h}/warnings"; then
    ok "状態の警告: $1"
  else
    ng "状態の警告: $1" "$(log "${h}")"
  fi
}
check_warn "t3 が起きなければ nix-ld の案内" t3-broken x 'programs.nix-ld.enable'
check_warn "linger が no" linger no 'loginctl enable-linger'
check_warn "service が動いていない" active inactive 'systemctl --user daemon-reload && systemctl --user start t3code'
check_warn "t3 が current と読まない" service-status $'T3 Code service\n  Status: needs an update or repair' 't3 service install'
check_warn "claude-t3 にログインしていない" no-login x 'claude-t3 を起こして /login'
check_warn "T3 Connect が NOT reachable" connect-status $'T3 Connect\n  Environment link: pending server startup\n✕ T3 Connect is NOT reachable from other devices' 'Environment link: pending server startup'

# 10. runtime が無ければ警告して止まる (t3 を打たない)
h=$(new_home noruntime true)
rm -f "${h}/.t3/runtime/versions/0.1.11/.install-complete"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -Fq 'runtime がありません' "${h}/err" && ! grep -Fq 'T3 Code: t3' "${h}/out"; then
  ok "runtime の .install-complete が無ければ警告して止まる"
else
  ng "runtime が無い" "$(log "${h}")"
fi

echo
echo "pass=${pass} fail=${fail}"
((fail == 0))
