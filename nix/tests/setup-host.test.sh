#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/setup.sh の対象ホストの決め方 (dotfiles-private に登録したこの PC のホスト) と、switch の前の
# dotfiles-private の取得・ローカル flake の lock の張り直しを、使い捨ての checkout と偽の uname・nix・手順で確かめる。
#
#   bash nix/tests/setup-host.test.sh [<nix/scripts のパス>]
#
# flake の checks (setup-host-test) が Nix のサンドボックスで流す。
#
# ## 確かめること
#
#   - 対象ホストは --host → DOTFILES_HOST → ローカル flake (~/dotfiles/flake.nix) のホスト → dotfiles-private に登録した
#     この PC のホスト (<user>@<短い hostname>) → $USER と uname からの推測、の順で決まり、--which-host が
#     「<ホスト><TAB><決め方>」(--host・DOTFILES_HOST・local・private・guess) を出す。決まらなければ 1
#   - dotfiles-private のホストを選ぶのは、clone に nix/hosts/<この PC>.nix があり、ローカル flake の
#     inputs.dotfiles-private.url がその clone の nix/ を指すときだけ (入力が無い・本体の stub を指す・ローカル flake が
#     無いなら推測)
#   - ローカル flake が clone の nix/ を読んでいないのに clone にこの PC のファイルがあれば、残りの手作業で、推測に
#     落ちたことと直し方 (local-flake-migrate.sh prepare・pjp-dotfiles-register-host) を出す。読んでいれば出さない
#   - --host・DOTFILES_HOST で、この PC の登録した名前と違うホストを選んだら、警告する (警告のまとめの
#     [対象ホスト] にも)。同じ名前・登録していない PC では出さない
#   - --host <dotfiles-private のホスト> は、ローカル flake が読んでいれば登録済みとして通り、switch がそのホストを当てる。
#     読んでいなければ 1 で止まり、dotfiles-private の案内を出す
#   - --update では手順 private-fetch (dotfiles-private の取得) が switch より前に並び、clone があれば
#     bootstrap-dotfiles-private.sh を switch の前に流し、後ろの手順 bootstrap-dotfiles-private は「switch の前に取得
#     した」と出して飛ばす (取れないときの警告もまとめに 1 回だけ)。clone が無ければ private-fetch は何もせず、後ろの
#     bootstrap-dotfiles-private がいつもどおり流れる
#   - switch の前の lock の張り直しは path: の入力ぜんぶを見て、実物の hash が lock に無い入力だけをまとめて
#     nix flake update <名前>… で張り直す (合っていれば張り直さない)。dotfiles-private の入力の指す先が無ければ警告する
#
# ## 作り
#
# setup.sh と private-host.sh を使い捨ての checkout (<ケース>/repo/nix/scripts/) に写し、登録簿 (alice@x86_64-linux・
# alice@wsl) と偽の bootstrap-*.sh を置く。ローカル flake (<ケース>/local/flake.nix) はテストが書く (setup.sh は文字列
# から読むだけ)。dotfiles-private の clone は <ケース>/private (DOTFILES_PRIVATE_DIR)。偽の uname は -n で box を返すので、
# この PC の名前は alice@box。shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
dir=${1:-${here}/../scripts}
work=$(mktemp -d "${TMPDIR:-/tmp}/setup-host-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

for f in setup.sh private-host.sh; do
  if [[ ! -f ${dir}/${f} ]]; then
    echo "見つからない: ${dir}/${f}" >&2
    exit 1
  fi
done

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

# 要るコマンドだけを並べた PATH (git・gh・nix・home-manager・ghq は入れない。uname は偽物)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env awk sed grep sort head tail tr cat dirname basename readlink id mktemp mkdir rm chmod cksum cmp ln; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
case ${1-} in
  -n) echo box ;;
  -m) echo x86_64 ;;
  *) echo Linux ;;
esac
EOF
} >"${sys_bin}/uname"
chmod +x "${sys_bin}/uname"

# 偽の home-manager と nix を置いた bin を作り、その場所を出す。home-manager は何もせず 0 を返す。
# nix は引数を <HOME>/nix-calls に書き、`hash path <dir>` なら sha256-<dir/.fakehash の中身> (無ければ sha256-FAKE) を
# 出す。ほかは何も出さずに 0 (eval の warnings は空)
fake_hm_bin() {
  local b="$1/fake-bin"
  mkdir -p "${b}"
  printf '#!%s\nexit 0\n' "${BASH}" >"${b}/home-manager"
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/nix-calls"
if [[ $1 == hash ]]; then
  last=""
  for a in "$@"; do last=$a; done
  if [[ -f ${last}/.fakehash ]]; then echo "sha256-$(cat "${last}/.fakehash")"; else echo sha256-FAKE; fi
fi
exit 0
EOF
  } >"${b}/nix"
  chmod +x "${b}/home-manager" "${b}/nix"
  echo "${b}"
}

# 1 ケースぶんの checkout と HOME と dotfiles-private の clone を作り、その場所を出す。
#   <ケース>/repo/nix/scripts/        写した setup.sh・private-host.sh と、偽の bootstrap-a.sh
#   <ケース>/repo/nix/hosts/default.nix  alice@x86_64-linux・alice@wsl の登録簿
#   <ケース>/repo/nix/private-stub/   本体の stub
#   <ケース>/private/                 dotfiles-private の clone (.git と nix/hosts/alice@box.nix)
#   <ケース>/home・<ケース>/tmp        HOME・TMPDIR
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/repo/nix/scripts" "${c}/repo/nix/hosts" "${c}/repo/nix/private-stub" "${c}/home" "${c}/tmp" \
    "${c}/private/.git" "${c}/private/nix/hosts"
  cp "${dir}/setup.sh" "${dir}/private-host.sh" "${c}/repo/nix/scripts/"
  {
    printf '{ mkHome }:\n{\n'
    printf '  "alice@x86_64-linux" = mkHome {\n    username = "alice";\n  };\n'
    printf '  "alice@wsl" = mkHome {\n    username = "alice";\n  };\n'
    printf '}\n'
  } >"${c}/repo/nix/hosts/default.nix"
  printf '{ mkHome, ... }:\nmkHome { username = "alice"; system = "x86_64-linux"; }\n' >"${c}/private/nix/hosts/alice@box.nix"
  fake_step "${c}" bootstrap-a.sh 'echo "a を流した"'
  echo "${c}"
}

# 偽の手順を置く。$1: ケース、$2: ファイル名 (bootstrap-a.sh など)、$3: 本体 (bash)
fake_step() {
  {
    printf '#!%s\n' "${BASH}"
    printf '# 偽の手順 (%s)\n' "$2"
    printf '%s\n' "$3"
  } >"$1/repo/nix/scripts/$2"
  chmod +x "$1/repo/nix/scripts/$2"
}

# ローカル flake を書く。$1: ケース、$2: dotfiles-private の入力の指す先 (none なら入力の行を書かない)、
# $3: 手で足したホストの行 (省略可)
local_flake() {
  local c=$1 private=$2
  mkdir -p "${c}/local"
  {
    printf '{\n  inputs.dotfiles.url = "path:%s/repo/nix";\n' "${c}"
    if [[ ${private} != none ]]; then
      printf '  inputs.dotfiles-private.url = "path:%s";\n  inputs.dotfiles-private.flake = false;\n' "${private}"
    fi
    printf '  outputs = { dotfiles, ... }: {\n'
    printf '    # dotfiles.claude.notion.profile は local に書く\n'
    printf '    homeConfigurations = dotfiles.lib.hostsWith [ ] // {\n'
    [[ -z ${3:-} ]] || printf '%s\n' "$3"
    printf '    };\n  };\n}\n'
  } >"${c}/local/flake.nix"
}

# $1: ケース、残り: setup.sh の引数。stdout・stderr・終了コードを <ケース>/{out,err,rc} に残す。
# 環境変数 (PATH_EXTRA・DOTFILES_HOST・DOTFILES_PRIVATE_DIR) は呼び出し側で付ける
run() {
  local c=$1
  shift
  env -i HOME="${c}/home" USER=alice TMPDIR="${c}/tmp" NO_COLOR=1 \
    PATH="${PATH_EXTRA:+${PATH_EXTRA}:}${sys_bin}" \
    DOTFILES_LOCAL_DIR="${c}/local" DOTFILES_PRIVATE_DIR="${DOTFILES_PRIVATE_DIR:-${c}/private}" \
    ${DOTFILES_HOST+"DOTFILES_HOST=${DOTFILES_HOST}"} \
    "${BASH}" "${c}/repo/nix/scripts/setup.sh" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}
rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }
# 「結果」より後の stdout と、「残りの手作業」より後の stdout
after_result() { sed -n '/^==> 結果/,$p' "$1/out"; }
after_post_notes() { sed -n '/^==> 残りの手作業/,$p' "$1/out"; }
# 判定の grep -q はパイプで受けず、<<< で渡す (check-test-grep-q.sh)
seen_after_result() {
  local c=$1
  shift
  grep -q "$@" <<<"$(after_result "${c}")"
}
seen_after_post_notes() {
  local c=$1
  shift
  grep -q "$@" <<<"$(after_post_notes "${c}")"
}
# stdout で、$2 を含む最初の行の行番号 (無ければ 0)
line_of() { awk -v s="$2" 'index($0, s) { print NR; found = 1; exit } END { if (!found) print 0 }' "$1/out"; }

echo "== setup.sh: 対象ホストの決め方と dotfiles-private (${dir}/setup.sh)"

# 1. --which-host: 決め方の順
c=$(new_case t1)
local_flake "${c}" "${c}/private/nix"
run "${c}" --which-host
r_private="$(rc "${c}") $(out "${c}")"
local_flake "${c}" "${c}/private/nix" '      tmp = dotfiles.lib.mkHome {'
run "${c}" --which-host
r_local="$(rc "${c}") $(out "${c}")"
local_flake "${c}" "${c}/private/nix"
DOTFILES_HOST=alice@x86_64-linux run "${c}" --which-host
r_env="$(rc "${c}") $(out "${c}")"
DOTFILES_HOST=alice@x86_64-linux run "${c}" --which-host --host alice@wsl
r_opt="$(rc "${c}") $(out "${c}")"
if [[ ${r_private} == "0 alice@box"$'\t'"private" && ${r_local} == "0 tmp"$'\t'"local" &&
  ${r_env} == "0 alice@x86_64-linux"$'\t'"DOTFILES_HOST" && ${r_opt} == "0 alice@wsl"$'\t'"--host" ]]; then
  ok "--which-host: --host → DOTFILES_HOST → ローカル flake のホスト → dotfiles-private のこの PC のホスト の順"
else
  ng "--which-host (順)" "private=${r_private} / local=${r_local} / env=${r_env} / --host=${r_opt}"
fi

# 2. --which-host: dotfiles-private を読んでいない・登録していないなら推測
local_flake "${c}" "${c}/repo/nix/private-stub"
run "${c}" --which-host
r_stub="$(rc "${c}") $(out "${c}")"
local_flake "${c}" none
run "${c}" --which-host
r_none="$(rc "${c}") $(out "${c}")"
local_flake "${c}" "${c}/private/nix"
DOTFILES_PRIVATE_DIR="${c}/other-private" run "${c}" --which-host
r_other="$(rc "${c}") $(out "${c}")"
mv "${c}/private/nix/hosts/alice@box.nix" "${c}/alice@box.nix"
run "${c}" --which-host
r_unreg="$(rc "${c}") $(out "${c}")"
mv "${c}/alice@box.nix" "${c}/private/nix/hosts/alice@box.nix"
rm -rf "${c}/local"
run "${c}" --which-host
r_nolocal="$(rc "${c}") $(out "${c}")"
want_guess="0 alice@x86_64-linux"$'\t'"guess"
if [[ ${r_stub} == "${want_guess}" && ${r_none} == "${want_guess}" && ${r_other} == "${want_guess}" &&
  ${r_unreg} == "${want_guess}" && ${r_nolocal} == "${want_guess}" ]]; then
  ok "--which-host: 入力が stub・入力が無い・別の clone を指す・この PC が未登録・ローカル flake が無いなら推測"
else
  ng "--which-host (推測)" "stub=${r_stub} / 入力なし=${r_none} / 別の clone=${r_other} / 未登録=${r_unreg} / local なし=${r_nolocal}"
fi

# 3. --which-host: 決まらなければ 1
c=$(new_case t3)
printf '{ mkHome }:\n{\n  bob = mkHome {\n    username = "bob";\n  };\n}\n' >"${c}/repo/nix/hosts/default.nix"
local_flake "${c}" none
run "${c}" --which-host
if [[ $(rc "${c}") == 1 && -z $(out "${c}") ]] && grep -qF '対象ホストが決まりません' "${c}/err"; then
  ok "--which-host: 対象ホストが決まらなければ 1 で、stdout には何も出さない"
else
  ng "--which-host (決まらない)" "rc=$(rc "${c}") out=$(out "${c}") err=$(err "${c}")"
fi

# 4. 残りの手作業: clone にこの PC のファイルがあるのに、ローカル flake が読んでいない
c=$(new_case t4)
local_flake "${c}" "${c}/repo/nix/private-stub"
run "${c}" --steps bootstrap-a
if [[ $(rc "${c}") == 0 ]] && seen_after_post_notes "${c}" -F 'alice@box' \
  && seen_after_post_notes "${c}" -F 'local-flake-migrate.sh prepare' \
  && seen_after_post_notes "${c}" -F 'pjp-dotfiles-register-host' \
  && seen_after_post_notes "${c}" -F '推測'; then
  ok "残りの手作業: ローカル flake が dotfiles-private を読んでいなければ、推測に落ちたことと直し方を出す"
else
  ng "残りの手作業 (読んでいない)" "rc=$(rc "${c}") $(after_post_notes "${c}")"
fi
local_flake "${c}" "${c}/private/nix"
run "${c}" --steps bootstrap-a
if [[ $(rc "${c}") == 0 ]] && ! seen_after_post_notes "${c}" -F 'pjp-dotfiles-register-host'; then
  ok "残りの手作業: ローカル flake が dotfiles-private を読んでいれば、その案内は出さない"
else
  ng "残りの手作業 (読んでいる)" "rc=$(rc "${c}") $(after_post_notes "${c}")"
fi

# 5. 登録した名前と違うホストを --host・DOTFILES_HOST で選んだら警告する
c=$(new_case t5)
local_flake "${c}" "${c}/private/nix"
run "${c}" --steps bootstrap-a --host alice@x86_64-linux
r_opt=$(rc "${c}")
e_opt=$(err "${c}")
s_opt=$(after_result "${c}")
DOTFILES_HOST=alice@x86_64-linux run "${c}" --steps bootstrap-a
e_env=$(err "${c}")
if [[ ${r_opt} == 0 && ${e_opt} == *"alice@box"* && ${s_opt} == *"[対象ホスト]"*"alice@box"* && ${e_env} == *"alice@box"* ]]; then
  ok "--host・DOTFILES_HOST で登録した名前と違うホストを選んだら警告する (まとめの [対象ホスト] にも)"
else
  ng "登録と違うホストの警告" "rc=${r_opt} err=${e_opt} まとめ=${s_opt} env=${e_env}"
fi
run "${c}" --steps bootstrap-a --host alice@box
e_same=$(err "${c}")
mv "${c}/private/nix/hosts/alice@box.nix" "${c}/alice@box.nix"
run "${c}" --steps bootstrap-a --host alice@x86_64-linux
e_unreg=$(err "${c}")
if [[ ${e_same} != *"登録"* && ${e_unreg} != *"登録"* ]]; then
  ok "登録した名前と同じホスト・登録していない PC では警告しない"
else
  ng "登録と違うホストの警告 (出さない場合)" "同じ=${e_same} / 未登録=${e_unreg}"
fi

# 6. --host <dotfiles-private のホスト>: 読んでいれば通り、読んでいなければ止まる
c=$(new_case t6)
local_flake "${c}" "${c}/private/nix"
run "${c}" --steps switch --dry-run --host alice@box
r_read=$(rc "${c}")
o_read=$(out "${c}")
local_flake "${c}" "${c}/repo/nix/private-stub"
run "${c}" --steps switch --dry-run --host alice@box
if [[ ${r_read} == 0 && ${o_read} == *"switch --flake ${c}/local#alice@box"* && ${o_read} == *"dotfiles-private"*"で定義"* ]] \
  && [[ $(rc "${c}") == 1 ]] && grep -qF 'dotfiles-private' "${c}/err" && grep -qF 'local-flake-migrate.sh prepare' "${c}/err"; then
  ok "--host <dotfiles-private のホスト>: 読んでいれば登録済みとして switch し、読んでいなければ 1 で案内を出す"
else
  ng "--host <dotfiles-private のホスト>" "読む: rc=${r_read} ${o_read} / 読まない: rc=$(rc "${c}") $(err "${c}")"
fi

# 7. --update --dry-run: private-fetch が switch より前。clone があれば switch の前に取り、後ろは飛ばす
c=$(new_case t7)
fake_step "${c}" bootstrap-dotfiles-private.sh 'echo "dotfiles-private を取った"'
local_flake "${c}" "${c}/private/nix"
run "${c}" --update --dry-run
l_label=$(line_of "${c}" 'dotfiles-private を取得 (switch の前)')
l_switch_label=$(line_of "${c}" 'home-manager switch')
l_cmd=$(line_of "${c}" "+ ${c}/repo/nix/scripts/bootstrap-dotfiles-private.sh")
l_switch_cmd=$(line_of "${c}" "switch --flake ${c}/local#alice@box")
if [[ $(rc "${c}") == 0 && ${l_label} -gt 0 && ${l_label} -lt ${l_switch_label} && ${l_cmd} -gt 0 && ${l_cmd} -lt ${l_switch_cmd} ]] \
  && grep -qF 'switch の前に取得した' "${c}/out" \
  && [[ $(grep -cF "+ ${c}/repo/nix/scripts/bootstrap-dotfiles-private.sh" "${c}/out") == 1 ]]; then
  ok "--update: private-fetch が switch より前に並び、clone があれば switch の前に取って、後ろの bootstrap-dotfiles-private は飛ばす"
else
  ng "--update --dry-run (clone あり)" "rc=$(rc "${c}") 行: 手順=${l_label} switch=${l_switch_label} 取得=${l_cmd} switch のコマンド=${l_switch_cmd} $(out "${c}")"
fi
rm -rf "${c}/private/.git"
run "${c}" --update --dry-run
l_note=$(line_of "${c}" 'clone がまだ無い')
l_cmd=$(line_of "${c}" "+ ${c}/repo/nix/scripts/bootstrap-dotfiles-private.sh")
l_switch_cmd=$(line_of "${c}" "switch --flake ${c}/local#alice@box")
if [[ $(rc "${c}") == 0 && ${l_note} -gt 0 && ${l_cmd} -gt ${l_switch_cmd} ]] && ! grep -qF 'switch の前に取得した' "${c}/out"; then
  ok "--update: clone が無ければ private-fetch は何もせず、後ろの bootstrap-dotfiles-private が流れる"
else
  ng "--update --dry-run (clone なし)" "rc=$(rc "${c}") 行: 案内=${l_note} 取得=${l_cmd} switch のコマンド=${l_switch_cmd} $(out "${c}")"
fi

# 8. --update (dry-run でない): 取れないときの警告はまとめに 1 回だけで、setup は止まらない
c=$(new_case t8)
# shellcheck disable=SC2016 # 偽の手順の本文 (展開は偽の手順が走るときにする)
fake_step "${c}" bootstrap-dotfiles-private.sh '
echo x >>"${HOME}/private-fetches"
echo "!! 取得 (fetch) に失敗しました。手元の clone のまま続けます" >&2
[[ -z ${DOTFILES_SETUP_WARNINGS-} ]] || echo "取得 (fetch) に失敗しました。手元の clone のまま続けます" >>"${DOTFILES_SETUP_WARNINGS}"
exit 0'
local_flake "${c}" "${c}/private/nix"
b=$(fake_hm_bin "${c}")
PATH_EXTRA=${b} run "${c}" --update
if [[ $(rc "${c}") == 0 && $(grep -c . "${c}/home/private-fetches" 2>/dev/null) == 1 ]] \
  && [[ $(grep -c '取得 (fetch) に失敗しました' <<<"$(after_result "${c}")") == 1 ]] \
  && seen_after_result "${c}" -F '[private-fetch]'; then
  ok "--update: 取れなくても止まらず、取得は 1 回だけ、警告はまとめに 1 回だけ ([private-fetch])"
else
  ng "--update (取れない)" "rc=$(rc "${c}") 取得=$(cat "${c}/home/private-fetches" 2>/dev/null) $(after_result "${c}") $(err "${c}")"
fi

# 9. lock: path: の入力ぜんぶを見て、lock に無い入力だけをまとめて張り直す
c=$(new_case t9)
local_flake "${c}" "${c}/private/nix"
b=$(fake_hm_bin "${c}")
printf 'PRIV1\n' >"${c}/private/nix/.fakehash"
printf '{ "a": "sha256-FAKE" }\n' >"${c}/local/flake.lock"
: >"${c}/home/nix-calls"
PATH_EXTRA=${b} run "${c}" --steps switch --host alice@box
calls_private=$(cat "${c}/home/nix-calls")
printf '{ "nodes": {} }\n' >"${c}/local/flake.lock"
: >"${c}/home/nix-calls"
PATH_EXTRA=${b} run "${c}" --steps switch --host alice@box
calls_both=$(cat "${c}/home/nix-calls")
printf '{ "a": "sha256-FAKE", "b": "sha256-PRIV1" }\n' >"${c}/local/flake.lock"
: >"${c}/home/nix-calls"
PATH_EXTRA=${b} run "${c}" --steps switch --host alice@box
calls_none=$(cat "${c}/home/nix-calls")
if grep -qxF "flake update dotfiles-private --flake ${c}/local" <<<"${calls_private}" \
  && grep -qxF "flake update dotfiles dotfiles-private --flake ${c}/local" <<<"${calls_both}" \
  && ! grep -q '^flake update' <<<"${calls_none}"; then
  ok "lock: hash が lock に無い path: の入力だけを、まとめて nix flake update で張り直す (合っていれば触らない)"
else
  ng "lock の張り直し" "private だけ: ${calls_private} / 両方: ${calls_both} / 合っている: ${calls_none}"
fi
local_flake "${c}" "${c}/nothing/nix"
PATH_EXTRA=${b} run "${c}" --steps switch --host alice@x86_64-linux
if grep -qF "dotfiles-private の入力が指す先がありません" "${c}/err"; then
  ok "lock: dotfiles-private の入力の指す先が無ければ警告する"
else
  ng "lock (指す先が無い)" "rc=$(rc "${c}") $(err "${c}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
