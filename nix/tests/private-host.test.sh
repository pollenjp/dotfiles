#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/private-host.sh (この PC を dotfiles-private に登録するときの名前・clone の場所・登録の下書きと比べ方) を、
# 偽の uname・scutil・ghq・nix と使い捨ての HOME で確かめる。
#
#   bash nix/tests/private-host.test.sh [<nix/scripts のパス>]
#
# flake の checks (private-host-test) が Nix のサンドボックスで流す。
#
# ## 確かめること
#
#   - name は <user>@<短い hostname>。user は $USER (無ければ id -un)、hostname は uname -n の最初の . まで。macOS
#     (uname -s が Darwin) は scutil --get LocalHostName を先に見て、scutil が無い・落ちる・空なら uname -n に戻る。
#     英数字・. _ - の外の文字を含む名前は、理由を stderr に出して 1。nix も jq も無い PATH で動く
#   - dir は $DOTFILES_PRIVATE_DIR (末尾の / を落とす) → $(ghq root)/github.com/pollenjp/dotfiles-private →
#     ~/ghq/github.com/pollenjp/dotfiles-private
#   - input-dir は clone の nix/ が directory ならそれ、無ければ本体の stub (<script の repo>/nix/private-stub か、
#     --nix-dir <dir> の <dir>/private-stub)
#   - private_dir() の本文が、clone を読む bootstrap-*.sh (dotfiles-private・ssh-config・windows-ssh-config・
#     windows-google-ime) の private_dir() と 1 字も違わない (clone の場所の決め方を 1 つにする)
#   - 引数が無い・知らないサブコマンドは usage を出して 2、-h は 0
#   - inspect (偽の nix) は、この PC の名前・clone と登録の有無・登録してあるホスト・ローカル flake の dotfiles-private の
#     入力の状態 (stub)・手で足したホスト・local のコメントでない行 (dotfiles の外の行も)・setup が --host なしで選ぶ
#     ホスト (setup.sh --which-host)・今の世代 (~/.local/state/nix/profiles/home-manager) と outPath が一致するホストを
#     出し、一致しなければそう出す。ユーザーの flake.nix と flake.lock は変えない (評価は写しで行う)
#   - 今の雛形の形 (local も手で足したホストも無い) の flake では、inspect は local が無いことと、setup が --host なしで
#     選ぶホストが決まらない (setup は止まる) ことを出し、draft は notes なしで描く
#   - draft (偽の nix) は、元にするホスト・この PC の名前・local の dotfiles の外の行 (notes) を渡して描いたものを、
#     --out のファイルか stdout に出す。--out が在れば --force なしで 2 (変えない)、評価が落ちれば原因の行を出して 3
#   - compare (偽の nix) は、旧い形 (ローカル flake の写しの <base>。inputs.dotfiles.url を --nix-dir に書き換える) と
#     新しい形 (dotfiles.lib.privateHosts だけの flake の <名前>。同じ本体と <private>/nix を指す) の drvPath が同じなら 0、
#     違えば 1 と config.dotfiles の違い、旧い形が落ちれば 3、新しい形が落ちれば 4、<private>/nix/hosts/<名前>.nix が
#     無ければ 2。今の世代との一致は参考に出す。ユーザーの flake.nix と flake.lock は変えない

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
dir=${1:-${here}/../scripts}
src=${dir}/private-host.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/private-host-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

if [[ ! -f ${src} ]]; then
  echo "見つからない: ${src}" >&2
  exit 1
fi

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

# 要るコマンドだけを並べた PATH (nix・jq・ghq・scutil・hostname は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env awk sed grep sort head tail tr cat dirname basename readlink mktemp mkdir rm cp mv ls chmod cmp diff cksum ln date; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 偽のコマンドを置いた bin。shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)
#   uname   -n は FAKE_UNAME_N (既定 box)、-s は FAKE_UNAME_S (既定 Linux)、-m は x86_64
#   id      -un は FAKE_ID_UN (既定 nobody)
fake_bin="${work}/fake-bin"
mkdir -p "${fake_bin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
case ${1-} in
  -n) printf '%s\n' "${FAKE_UNAME_N-box}" ;;
  -m) printf '%s\n' x86_64 ;;
  *) printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
esac
EOF
} >"${fake_bin}/uname"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
[[ ${1-} == -un ]] && printf '%s\n' "${FAKE_ID_UN:-nobody}"
EOF
} >"${fake_bin}/id"
chmod +x "${fake_bin}/uname" "${fake_bin}/id"

# scutil と ghq は、置くケースだけの bin に置く
#   scutil  --get LocalHostName なら FAKE_SCUTIL を出して FAKE_SCUTIL_RC (既定 0) で終わる
#   ghq     root なら FAKE_GHQ_ROOT を出す (空なら 1)
extra_bin="${work}/extra-bin"
mkdir -p "${extra_bin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
[[ $* == "--get LocalHostName" ]] && printf '%s\n' "${FAKE_SCUTIL-}"
exit "${FAKE_SCUTIL_RC:-0}"
EOF
} >"${extra_bin}/scutil"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
[[ ${1-} == root && -n ${FAKE_GHQ_ROOT-} ]] || exit 1
printf '%s\n' "${FAKE_GHQ_ROOT}"
EOF
} >"${extra_bin}/ghq"
chmod +x "${extra_bin}/scutil" "${extra_bin}/ghq"

# 1 ケースぶんの checkout と HOME を作り、その場所を出す。
#   <ケース>/repo/nix/scripts/private-host.sh   写した script (script の 2 つ上が repo)
#   <ケース>/home                               HOME
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/repo/nix/scripts" "${c}/home"
  cp "${src}" "${c}/repo/nix/scripts/private-host.sh"
  echo "${c}"
}

# $1: ケース、残り: script の引数。stdout・stderr・終了コードを <ケース>/{out,err,rc} に残す。
# 環境変数 (USER・FAKE_*・DOTFILES_PRIVATE_DIR・PATH_EXTRA) は呼び出し側で付ける
run() {
  local c=$1
  shift
  env -i HOME="${c}/home" ${USER+"USER=${USER}"} TMPDIR="${work}" \
    PATH="${PATH_EXTRA:+${PATH_EXTRA}:}${fake_bin}:${sys_bin}" \
    ${FAKE_UNAME_N+"FAKE_UNAME_N=${FAKE_UNAME_N}"} ${FAKE_UNAME_S+"FAKE_UNAME_S=${FAKE_UNAME_S}"} \
    ${FAKE_ID_UN+"FAKE_ID_UN=${FAKE_ID_UN}"} ${FAKE_SCUTIL+"FAKE_SCUTIL=${FAKE_SCUTIL}"} \
    ${FAKE_SCUTIL_RC+"FAKE_SCUTIL_RC=${FAKE_SCUTIL_RC}"} ${FAKE_GHQ_ROOT+"FAKE_GHQ_ROOT=${FAKE_GHQ_ROOT}"} \
    ${DOTFILES_PRIVATE_DIR+"DOTFILES_PRIVATE_DIR=${DOTFILES_PRIVATE_DIR}"} \
    ${FAKE_NIX_LOG+"FAKE_NIX_LOG=${FAKE_NIX_LOG}"} \
    "${BASH}" "${c}/repo/nix/scripts/private-host.sh" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}
rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }

echo "== private-host.sh (${src})"

# 1. name: uname -n の最初の . まで
c=$(new_case n1)
USER=alice FAKE_UNAME_N=box.example.test run "${c}" name
if [[ $(rc "${c}") == 0 && $(out "${c}") == alice@box ]]; then
  ok "name は <user>@<uname -n の最初の . まで> (nix も jq も無い PATH)"
else
  ng "name (Linux)" "rc=$(rc "${c}") out=$(out "${c}") err=$(err "${c}")"
fi

# 2. name: macOS は scutil の LocalHostName を先に見る
c=$(new_case n2)
USER=alice FAKE_UNAME_S=Darwin FAKE_UNAME_N=mac.local FAKE_SCUTIL=Alices-Mac PATH_EXTRA=${extra_bin} run "${c}" name
if [[ $(rc "${c}") == 0 && $(out "${c}") == alice@Alices-Mac ]]; then
  ok "macOS は scutil --get LocalHostName を使う"
else
  ng "name (Darwin・scutil)" "rc=$(rc "${c}") out=$(out "${c}") err=$(err "${c}")"
fi

# 3. name: macOS で scutil が無い・落ちる・空なら uname -n に戻る
c=$(new_case n3)
USER=alice FAKE_UNAME_S=Darwin FAKE_UNAME_N=mac.local run "${c}" name
r1="$(rc "${c}") $(out "${c}")"
USER=alice FAKE_UNAME_S=Darwin FAKE_UNAME_N=mac.local FAKE_SCUTIL=x FAKE_SCUTIL_RC=1 PATH_EXTRA=${extra_bin} run "${c}" name
r2="$(rc "${c}") $(out "${c}")"
USER=alice FAKE_UNAME_S=Darwin FAKE_UNAME_N=mac.local FAKE_SCUTIL='' PATH_EXTRA=${extra_bin} run "${c}" name
r3="$(rc "${c}") $(out "${c}")"
if [[ ${r1} == "0 alice@mac" && ${r2} == "0 alice@mac" && ${r3} == "0 alice@mac" ]]; then
  ok "macOS で scutil が無い・落ちる・空なら uname -n の最初の . まで"
else
  ng "name (Darwin・scutil なし)" "無い: ${r1} / 落ちる: ${r2} / 空: ${r3}"
fi

# 4. name: $USER が無ければ id -un
c=$(new_case n4)
(
  unset USER
  FAKE_ID_UN=bob run "${c}" name
)
if [[ $(rc "${c}") == 0 && $(out "${c}") == bob@box ]]; then
  ok "\$USER が無ければ id -un を使う"
else
  ng "name (id -un)" "rc=$(rc "${c}") out=$(out "${c}") err=$(err "${c}")"
fi

# 5. name: 使えない文字を含む hostname は 1
c=$(new_case n5)
USER=alice FAKE_UNAME_N='my box' run "${c}" name
r1="$(rc "${c}") $(out "${c}")"
e1=$(err "${c}")
USER=alice FAKE_UNAME_N='' run "${c}" name
r2="$(rc "${c}") $(out "${c}")"
if [[ ${r1} == "1 " && ${e1} == *"my box"* && ${r2} == "1 " ]]; then
  ok "英数字・. _ - の外の文字を含む名前・空の hostname は、理由を出して 1"
else
  ng "name (使えない文字)" "空白: ${r1} (${e1}) / 空: ${r2}"
fi

# 6. dir: DOTFILES_PRIVATE_DIR → ghq root → ~/ghq
c=$(new_case d1)
DOTFILES_PRIVATE_DIR=/x/y/ FAKE_GHQ_ROOT=/g PATH_EXTRA=${extra_bin} run "${c}" dir
r1=$(out "${c}")
FAKE_GHQ_ROOT=/g PATH_EXTRA=${extra_bin} run "${c}" dir
r2=$(out "${c}")
FAKE_GHQ_ROOT='' PATH_EXTRA=${extra_bin} run "${c}" dir
r3=$(out "${c}")
if [[ ${r1} == /x/y && ${r2} == /g/github.com/pollenjp/dotfiles-private &&
  ${r3} == "${c}/home/ghq/github.com/pollenjp/dotfiles-private" ]]; then
  ok "dir は \$DOTFILES_PRIVATE_DIR → \$(ghq root)/github.com/pollenjp/dotfiles-private → ~/ghq/… の順"
else
  ng "dir" "env: ${r1} / ghq: ${r2} / 既定: ${r3}"
fi

# 7. input-dir: clone の nix/ があればそれ、無ければ本体の stub
c=$(new_case i1)
mkdir -p "${c}/private/nix"
DOTFILES_PRIVATE_DIR="${c}/private" run "${c}" input-dir
r1=$(out "${c}")
DOTFILES_PRIVATE_DIR="${c}/nothing" run "${c}" input-dir
r2=$(out "${c}")
DOTFILES_PRIVATE_DIR="${c}/nothing" run "${c}" input-dir --nix-dir /n
r3=$(out "${c}")
if [[ ${r1} == "${c}/private/nix" && ${r2} == "${c}/repo/nix/private-stub" && ${r3} == /n/private-stub ]]; then
  ok "input-dir は clone の nix/ が無ければ本体の stub (<repo>/nix/private-stub か --nix-dir の下)"
else
  ng "input-dir" "clone: ${r1} / stub: ${r2} / --nix-dir: ${r3}"
fi

# 8. private_dir() の本文が clone を読む bootstrap-*.sh と同じ
body_of() {
  awk '
    /^private_dir\(\) \{/ { f = 1 }
    f { print; if ($0 ~ /^\}$/) f = 0 }
  ' "$1"
}
want=$(body_of "${src}")
differ=""
for f in bootstrap-dotfiles-private.sh bootstrap-ssh-config.sh bootstrap-windows-ssh-config.sh bootstrap-windows-google-ime.sh; do
  if [[ ! -f ${dir}/${f} || $(body_of "${dir}/${f}") != "${want}" ]]; then
    differ+=" ${f}"
  fi
done
if [[ -n ${want} && -z ${differ} ]]; then
  ok "private_dir() の本文が、clone を読む bootstrap-*.sh の private_dir() と 1 字も違わない"
else
  ng "private_dir() の本文" "違う・無い:${differ} (private-host.sh の本文: ${want:-無い})"
fi

# 9. 使い方
c=$(new_case u1)
run "${c}"
r1=$(rc "${c}")
run "${c}" nosuch
r2=$(rc "${c}")
run "${c}" -h
r3=$(rc "${c}")
if [[ ${r1} == 2 && ${r2} == 2 && ${r3} == 0 ]] && grep -q 'name' "${c}/out"; then
  ok "引数が無い・知らないサブコマンドは 2、-h は usage を出して 0"
else
  ng "使い方" "なし=${r1} 知らない=${r2} -h=${r3} $(out "${c}")"
fi

# ---- inspect・draft・compare (偽の nix) ----
# 偽の nix は呼ばれた引数を FAKE_NIX_LOG に 1 行で書く。
#   nix hash path … <dir>              sha256-FAKE を出す
#   nix flake lock / update … path:<d> <d>/flake.lock に sha256-FAKE を書く
#   nix eval --raw --impure --expr …   (draft) PJP_FLAKE の flake.nix に「# FAKE_EVAL_ERROR: <文>」があれば落ちる。
#                                      無ければ「DRAFT base=<PJP_BASE> name=<PJP_NAME>」と PJP_NOTES の中身を出す
#   nix eval --raw path:<d>#homeConfigurations --apply <式>
#     <d>/flake.nix を F とする。F が dotfiles-private の入力を持ち「# FAKE_」の行を持たなければ (compare の新しい形)、
#     式の getAttr "<h>" の <h> の、その入力の hosts/<h>.nix を F にする。F に「# FAKE_EVAL_ERROR: <文>」があれば落ちる。
#       tryEval (inspect)        F の「# FAKE_OUT: <h> <outPath>」ごとに「out<TAB><h><TAB><outPath>」(options.dotfiles を含む式は下)
#       options.dotfiles         F の「# FAKE_DOTFILES: <パス> <値>」ごとに「<パス><TAB><値>」
#       drvPath (compare)        F の「# FAKE_DRV: [<h>] <drvPath>」と「# FAKE_OUT: [<h>] <outPath>」を 2 行で
fake_nix_bin="${work}/fake-nix-bin"
mkdir -p "${fake_nix_bin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$*" >>"${FAKE_NIX_LOG:-/dev/null}"
last=""
for a in "$@"; do last=$a; done
fail_with() {
  echo 'error:'
  echo '       … while evaluating something'
  printf '       error: %s\n' "$1"
  exit 1
}
case $1 in
  hash) echo sha256-FAKE ;;
  flake)
    d=${last#path:}
    printf '{ "fake": "sha256-FAKE" }\n' >"${d}/flake.lock"
    ;;
  eval)
    if [[ $* == *--expr* ]]; then
      e=$(sed -n 's/^# FAKE_EVAL_ERROR: //p' "${PJP_FLAKE}/flake.nix")
      [[ -z ${e} ]] || fail_with "${e}" >&2
      printf 'DRAFT base=%s name=%s\n' "${PJP_BASE}" "${PJP_NAME}"
      printf 'MAIN=%s\n' "$(sed -n 's|^ *inputs\.dotfiles\.url = "path:\([^"]*\)";|\1|p' "${PJP_FLAKE}/flake.nix")"
      cat "${PJP_NOTES}"
      exit 0
    fi
    d=${3#path:}
    d=${d%%#*}
    f="${d}/flake.nix"
    expr=$5
    h=$(sed -n 's/.*getAttr "\([^"]*\)".*/\1/p' <<<"${expr}")
    p=$(sed -n 's|.*inputs\.dotfiles-private\.url = "path:\([^"]*\)".*|\1|p' "${f}")
    if [[ -n ${p} && -n ${h} ]] && ! grep -q '^# FAKE_' "${f}"; then
      f="${p}/hosts/${h}.nix"
    fi
    e=$(sed -n 's/^# FAKE_EVAL_ERROR: //p' "${f}")
    [[ -z ${e} ]] || fail_with "${e}" >&2
    case ${expr} in
      *options.dotfiles*)
        sed -n 's/^# FAKE_DOTFILES: \([^ ]*\) \(.*\)$/\1\t\2/p' "${f}"
        ;;
      *tryEval*)
        sed -n 's/^# FAKE_OUT: \([^ ]*\) \(.*\)$/out\t\1\t\2/p' "${f}"
        ;;
      *drvPath*)
        drv=$(sed -n -e "s/^# FAKE_DRV: ${h} //p" -e 's/^# FAKE_DRV: \([^ ]*\)$/\1/p' "${f}")
        o=$(sed -n -e "s/^# FAKE_OUT: ${h} //p" -e 's/^# FAKE_OUT: \([^ ]*\)$/\1/p' "${f}")
        printf '%s\n%s' "${drv}" "${o}"
        ;;
    esac
    ;;
esac
exit 0
EOF
} >"${fake_nix_bin}/nix"
chmod +x "${fake_nix_bin}/nix"

# 登録の場面を 1 つ作り、その場所を出す。
#   <ケース>/repo/nix/scripts/   private-host.sh と setup.sh (setup.sh --which-host を呼ぶ)
#   <ケース>/repo/nix/hosts/default.nix   alice@x86_64-linux・alice@wsl
#   <ケース>/local/flake.nix     ローカル flake (local に dotfiles の行と dotfiles の外の行、手で足したホスト tmp)。
#                                 偽の nix の答え (FAKE_OUT・FAKE_DRV) も書く
#   <ケース>/private             dotfiles-private の clone (bob@other だけ登録済み)
#   <ケース>/store/gen-1         今の世代 (~/.local/state/nix/profiles/home-manager の指す先)
register_case() {
  local c
  c=$(new_case "$1")
  c=$(cd -P "${c}" && pwd)
  cp "${dir}/setup.sh" "${c}/repo/nix/scripts/"
  mkdir -p "${c}/repo/nix/hosts" "${c}/repo/nix/private-stub" "${c}/local" "${c}/private/.git" "${c}/private/nix/hosts" \
    "${c}/store/gen-1" "${c}/store/gen-2" "${c}/home/.local/state/nix/profiles"
  printf '{ mkHome }:\n{\n  "alice@x86_64-linux" = mkHome { username = "alice"; };\n  "alice@wsl" = mkHome { username = "alice"; };\n}\n' \
    >"${c}/repo/nix/hosts/default.nix"
  printf '{ mkHome, ... }: mkHome { username = "bob"; system = "x86_64-linux"; }\n' >"${c}/private/nix/hosts/bob@other.nix"
  cat >"${c}/local/flake.nix" <<EOF
# FAKE_OUT: alice@x86_64-linux ${c}/store/gen-1
# FAKE_OUT: alice@wsl ${c}/store/gen-2
# FAKE_DRV: alice@x86_64-linux /nix/store/same.drv
# FAKE_DOTFILES: ccPages.port 7801
{
  inputs.dotfiles.url = "path:${c}/repo/nix";
  inputs.dotfiles-private.url = "path:${c}/repo/nix/private-stub";
  inputs.dotfiles-private.flake = false;
  outputs =
    { dotfiles, dotfiles-private, ... }:
    let
      local = {
        # Dev Tracker を使うか。
        dotfiles.claude.devTracker.enable = true;

        programs.git.settings.user.email = "alice@example.test";
      };
    in
    {
      homeConfigurations = dotfiles.lib.hostsWith [ local ] // {
        tmp = dotfiles.lib.mkHome { };
      };
    };
}
EOF
  printf '{ "nodes": {} }\n' >"${c}/local/flake.lock"
  ln -s "${c}/store/gen-1" "${c}/home/.local/state/nix/profiles/home-manager"
  echo "${c}"
}

# $1: ケース、残り: script の引数。偽の nix を PATH に置き、USER=alice・hostname box・clone <ケース>/private で流す
run_nix() {
  local c=$1
  shift
  : >"${c}/nix-calls"
  USER=alice DOTFILES_PRIVATE_DIR="${c}/private" PATH_EXTRA="${fake_nix_bin}" FAKE_NIX_LOG="${c}/nix-calls" run "${c}" "$@"
}

# 10. inspect
c=$(register_case r10)
cp -p "${c}/local/flake.nix" "${c}/flake.before"
cp -p "${c}/local/flake.lock" "${c}/lock.before"
run_nix "${c}" inspect --flake "${c}/local"
inspect_ok=1
for want in 'ホストの名前: alice@box' \
  "clone: ${c}/private" \
  "この PC のホスト: ${c}/private/nix/hosts/alice@box.nix (無い)" \
  '登録してあるホスト: bob@other' \
  "dotfiles-private の入力: ${c}/repo/nix/private-stub (本体の空の stub" \
  '手で足したホスト: tmp' \
  'dotfiles.claude.devTracker.enable = true;' \
  'programs.git.settings.user.email = "alice@example.test";' \
  "setup が --host なしで選ぶホスト: tmp" \
  '一致するホスト: alice@x86_64-linux'; do
  grep -qF -- "${want}" "${c}/out" || {
    inspect_ok=0
    echo "       見つからない: ${want}"
  }
done
if [[ $(rc "${c}") == 0 && ${inspect_ok} == 1 ]] && ! grep -qF '# Dev Tracker を使うか。' "${c}/out"; then
  ok "inspect: この PC・clone と登録・ローカル flake (入力・手で足したホスト・local の行)・setup の選ぶホスト・今の世代と一致するホストを出す"
else
  ng "inspect" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi
if cmp -s "${c}/flake.before" "${c}/local/flake.nix" && cmp -s "${c}/lock.before" "${c}/local/flake.lock" \
  && ! grep -qF -- "path:${c}/local " "${c}/nix-calls" && ! grep -q "path:${c}/local\$" "${c}/nix-calls"; then
  ok "inspect: ユーザーの flake.nix と flake.lock は変えず、評価は写しで行う"
else
  ng "inspect (ユーザーの flake)" "$(cat "${c}/nix-calls")"
fi

if grep -qF 'draft --base <ホスト>' "${c}/out" && ! grep -qF '登録済み' <<<"$(sed -n '/^次:/,$p' "${c}/out")"; then
  ok "inspect: 登録していない PC には、次に下書きを描くコマンドを出す"
else
  ng "inspect (次: 登録していない)" "$(sed -n '/^次:/,$p' "${c}/out")"
fi

# 11. inspect: 今の世代と一致するホストが無い
ln -sfn "${c}/store/gen-9" "${c}/home/.local/state/nix/profiles/home-manager"
mkdir -p "${c}/store/gen-9"
run_nix "${c}" inspect --flake "${c}/local"
if [[ $(rc "${c}") == 0 ]] && grep -qF '一致するホストはありません' "${c}/out"; then
  ok "inspect: 今の世代と一致するホストが無ければ、そう出す"
else
  ng "inspect (一致なし)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi

# 11b. inspect: 登録済みの PC には、次に打つものとして値の直し方と、ローカル flake が読んでいなければ移し方を出す
printf '{ mkHome, ... }: mkHome { username = "alice"; }\n' >"${c}/private/nix/hosts/alice@box.nix"
run_nix "${c}" inspect --flake "${c}/local"
next=$(sed -n '/^次:/,$p' "${c}/out")
if [[ $(rc "${c}") == 0 && ${next} == *"登録済み"* ]] \
  && [[ ${next} == *"draft --base alice@box"* && ${next} == *"local-flake-migrate.sh prepare"* ]]; then
  ok "inspect: 登録済みの PC には、値の直し方 (draft --base <名前>) と、読んでいないローカル flake の移し方を出す"
else
  ng "inspect (次: 登録済み)" "rc=$(rc "${c}") ${next}"
fi

# 12. draft: --out に書く・在れば --force なしで 2・stdout・評価が落ちれば 3
c=$(register_case r12)
mkdir -p "${c}/draft"
run_nix "${c}" draft --base alice@x86_64-linux --flake "${c}/local" --out "${c}/draft/alice@box.nix"
d1_rc=$(rc "${c}")
d1=$(cat "${c}/draft/alice@box.nix" 2>/dev/null)
printf 'keep\n' >"${c}/draft/keep.nix"
run_nix "${c}" draft --base alice@x86_64-linux --flake "${c}/local" --out "${c}/draft/keep.nix"
d2_rc=$(rc "${c}")
d2=$(cat "${c}/draft/keep.nix")
run_nix "${c}" draft --base alice@x86_64-linux --flake "${c}/local" --out "${c}/draft/keep.nix" --force
d3_rc=$(rc "${c}")
d3=$(cat "${c}/draft/keep.nix")
if [[ ${d1_rc} == 0 && ${d1} == *"DRAFT base=alice@x86_64-linux name=alice@box"* &&
  ${d1} == *'programs.git.settings.user.email = "alice@example.test";'* &&
  ${d2_rc} == 2 && ${d2} == keep && ${d3_rc} == 0 && ${d3} == *DRAFT* ]]; then
  ok "draft: 元のホスト・この PC の名前・local の dotfiles の外の行を渡して --out に書き、在れば --force なしで 2"
else
  ng "draft (--out)" "rc=${d1_rc}/${d2_rc}/${d3_rc} d1=${d1} d2=${d2} $(err "${c}")"
fi
run_nix "${c}" draft --base alice@x86_64-linux --flake "${c}/local" --name carol@pc
if [[ $(rc "${c}") == 0 ]] && grep -qF 'DRAFT base=alice@x86_64-linux name=carol@pc' "${c}/out"; then
  ok "draft: --out が無ければ stdout に出し、--name で名前を変えられる"
else
  ng "draft (stdout)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi
# draft は compare と同じ本体で評価する: ローカル flake の写しの inputs.dotfiles.url を、既定で script の repo の nix/ に、
# --nix-dir があればそこに書き換える (ローカル flake は別の本体を指していても)
sed -i "s|path:${c}/repo/nix\";|path:${c}/elsewhere/nix\";|" "${c}/local/flake.nix"
mkdir -p "${c}/elsewhere/nix" "${c}/other-main/nix"
run_nix "${c}" draft --base alice@x86_64-linux --flake "${c}/local"
m_default=$(sed -n 's/^MAIN=//p' "${c}/out")
run_nix "${c}" draft --base alice@x86_64-linux --flake "${c}/local" --nix-dir "${c}/other-main/nix"
m_given=$(sed -n 's/^MAIN=//p' "${c}/out")
if [[ ${m_default} == "${c}/repo/nix" && ${m_given} == "${c}/other-main/nix" ]]; then
  ok "draft: compare と同じ本体で評価する (既定は script の repo の nix/、--nix-dir で変えられる)"
else
  ng "draft (本体)" "既定=${m_default} --nix-dir=${m_given} $(err "${c}")"
fi
printf '# FAKE_EVAL_ERROR: attribute '"'"'nosuch'"'"' missing\n' >>"${c}/local/flake.nix"
run_nix "${c}" draft --base nosuch --flake "${c}/local"
if [[ $(rc "${c}") == 3 ]] && grep -qF "attribute 'nosuch' missing" "${c}/err"; then
  ok "draft: 評価が落ちれば、原因の行を出して 3"
else
  ng "draft (評価が落ちる)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi

# 12b. 今の雛形の形 (local も手で足したホストも無い) の flake: inspect は local が無いことと、setup の選ぶホストが決まらない
#      (setup は止まる) ことを出す。draft は notes なしで描く
c=$(register_case r12b)
cat >"${c}/local/flake.nix" <<EOF
# FAKE_OUT: alice@x86_64-linux ${c}/store/gen-1
{
  inputs.dotfiles.url = "path:${c}/repo/nix";
  inputs.dotfiles-private.url = "path:${c}/repo/nix/private-stub";
  inputs.dotfiles-private.flake = false;
  outputs =
    { dotfiles, dotfiles-private, ... }:
    let
      privateHosts = dotfiles.lib.privateHosts dotfiles-private;
    in
    {
      homeConfigurations = dotfiles.homeConfigurations // privateHosts // {
        # tmp = dotfiles.lib.mkHome {
        #   username = "alice";
        # };
      };
    };
}
EOF
run_nix "${c}" inspect --flake "${c}/local"
inspect_new_rc=$(rc "${c}")
inspect_new=$(out "${c}")
run_nix "${c}" draft --base alice@x86_64-linux --flake "${c}/local"
if [[ ${inspect_new_rc} == 0 && ${inspect_new} == *"local: 無い (今の雛形"* && ${inspect_new} == *"手で足したホスト: なし"* &&
  ${inspect_new} == *"setup が --host なしで選ぶホスト: 決まらない (setup は止まる"* &&
  ${inspect_new} == *"一致するホスト: alice@x86_64-linux"* && ${inspect_new} != *"local のコメントでない行"* ]] \
  && [[ $(rc "${c}") == 0 ]] && grep -qF 'DRAFT base=alice@x86_64-linux name=alice@box' "${c}/out" \
  && ! grep -qF 'option の外の行' "${c}/out"; then
  ok "今の雛形の形の flake: inspect は local が無いことと setup の選ぶホストが決まらないことを出し、draft は notes なしで描く"
else
  ng "今の雛形の形の flake" "inspect: rc=${inspect_new_rc} ${inspect_new} / draft: rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi

# 13. compare: 同じ → 0。新しい形は同じ本体と <private>/nix を指し、旧い形の写しの url は --nix-dir
c=$(register_case r13)
sed -i "s|inputs.dotfiles.url = \"path:${c}/repo/nix\";|inputs.dotfiles.url = \"path:${c}/elsewhere/nix\";|" "${c}/local/flake.nix"
mkdir -p "${c}/elsewhere/nix" "${c}/pw/nix/hosts"
printf '# FAKE_DRV: /nix/store/same.drv\n# FAKE_OUT: %s/store/gen-1\n# FAKE_DOTFILES: ccPages.port 7801\n{ mkHome, ... }: mkHome { }\n' "${c}" \
  >"${c}/pw/nix/hosts/alice@box.nix"
cp -p "${c}/local/flake.nix" "${c}/flake.before"
cp -p "${c}/local/flake.lock" "${c}/lock.before"
run_nix "${c}" compare --base alice@x86_64-linux --private "${c}/pw" --flake "${c}/local" --nix-dir "${c}/repo/nix" --out "${c}/cw"
if [[ $(rc "${c}") == 0 ]] && grep -qF 'drvPath が同じ' "${c}/out" && grep -qF '今の世代' "${c}/out" \
  && grep -qxF "  inputs.dotfiles.url = \"path:${c}/repo/nix\";" "${c}/cw/new/flake.nix" \
  && grep -qxF "  inputs.dotfiles-private.url = \"path:${c}/pw/nix\";" "${c}/cw/new/flake.nix" \
  && grep -qxF "  inputs.dotfiles.url = \"path:${c}/repo/nix\";" "${c}/cw/old/flake.nix"; then
  ok "compare: 旧い形と新しい形が同じ本体を指し、drvPath が同じなら 0"
else
  ng "compare (同じ)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}") new=$(cat "${c}/cw/new/flake.nix" 2>/dev/null)"
fi
if cmp -s "${c}/flake.before" "${c}/local/flake.nix" && cmp -s "${c}/lock.before" "${c}/local/flake.lock"; then
  ok "compare: ユーザーの flake.nix と flake.lock は変えない"
else
  ng "compare がユーザーの flake を変えた"
fi

# 14. compare: 違う → 1 と config.dotfiles の違い。旧い形・新しい形が落ちる → 3・4。登録のファイルが無い → 2
sed -i -e 's|^# FAKE_DRV: .*|# FAKE_DRV: /nix/store/other.drv|' -e 's|^# FAKE_DOTFILES: ccPages.port 7801|# FAKE_DOTFILES: ccPages.port 7802|' \
  "${c}/pw/nix/hosts/alice@box.nix"
run_nix "${c}" compare --base alice@x86_64-linux --private "${c}/pw" --flake "${c}/local" --nix-dir "${c}/repo/nix"
r_differ=$(rc "${c}")
o_differ=$(out "${c}")
printf '# FAKE_EVAL_ERROR: 新しい形の誤り\n' >>"${c}/pw/nix/hosts/alice@box.nix"
run_nix "${c}" compare --base alice@x86_64-linux --private "${c}/pw" --flake "${c}/local" --nix-dir "${c}/repo/nix"
r_new=$(rc "${c}")
e_new=$(err "${c}")
printf '# FAKE_EVAL_ERROR: 旧い形の誤り\n' >>"${c}/local/flake.nix"
run_nix "${c}" compare --base alice@x86_64-linux --private "${c}/pw" --flake "${c}/local" --nix-dir "${c}/repo/nix"
r_old=$(rc "${c}")
e_old=$(err "${c}")
run_nix "${c}" compare --base alice@x86_64-linux --private "${c}/pw" --flake "${c}/local" --name nobody@box
r_missing=$(rc "${c}")
if [[ ${r_differ} == 1 && ${o_differ} == *"ccPages.port: 7801 → 7802"* && ${r_new} == 4 && ${e_new} == *"新しい形の誤り"* &&
  ${r_old} == 3 && ${e_old} == *"旧い形の誤り"* && ${r_missing} == 2 ]]; then
  ok "compare: 違えば 1 と config.dotfiles の違い、新しい形が落ちれば 4、旧い形が落ちれば 3、登録のファイルが無ければ 2"
else
  ng "compare (違う・落ちる)" "違う=${r_differ} (${o_differ}) 新=${r_new} (${e_new}) 旧=${r_old} (${e_old}) 無い=${r_missing}"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
