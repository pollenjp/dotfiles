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
#   - <private>/nix/shared/ に module (.nix で終わり . で始まらないファイル) があれば、compare は新しい形を shared/ を外しても
#     評価する。外した形が旧い形と同じなら 0 (同じ。shared/ の値だけ違う)、違えば 1 で、ホストのファイルの違い (旧い →
#     shared/ を外した新しい形) と shared/ が足す値 (shared/ を外した新しい形 → 新しい形。登録でこの PC に増える値) を分けて
#     出す。shared/ がこのホストの値を変えなければそう出す。shared/ を足した形が落ちれば 4、外した形だけが落ちれば原因を出して
#     shared/ を含めた形で比べる (1)。shared/ が無ければ shared/ の行は出さない
#   - 元のホストが型なら、ローカル flake の読む clone に shared/ があっても外さない (型には shared/ が当たらない)
#   - 元のホストが、ローカル flake の読む dotfiles-private に登録したホストなら、compare は旧い形から、draft は元のホストから
#     その shared/ を外して評価する (shared/ の値をホストのファイルの違いに出さない・下書きに描かない)。clone と作業ツリーの
#     shared/ が同じなら、ホストのファイルも同じとき 0 で「世代の中身は変わらない」、違うとき 1 で shared/ は同じと 1 行。
#     shared/ が違えば、そう出して作業ツリーの shared/ の値を並べる。shared/ を外して評価できなければ 3 で、外したことを出す。
#     clone には書かない。inspect は clone の shared/ の module を出す
#   - compare の --out が作業ツリーの nix/ やローカル flake の読む dotfiles-private の nix/ の中なら、作る前に 2

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
#                                      無ければ「DRAFT base=<PJP_BASE> name=<PJP_NAME>」と PJP_NOTES の中身を出す。flake.nix に
#                                      「# FAKE_」の行が無く、dotfiles-private の入力に hosts/<PJP_BASE>.nix があれば (元のホストが
#                                      登録したホスト)、そのファイルと入力の shared/*.nix の FAKE_DOTFILES を「VALUE <パス> <値>」
#                                      で出す (draft が描く値。shared/ が当たっていれば、その値も描かれる)。shared/ が当たらないのに
#                                      そのファイルに「# FAKE_NEEDS_SHARED: <文>」があれば落ちる
#   nix eval --raw path:<d>#homeConfigurations --apply <式>
#     <d>/flake.nix を F とする。F が dotfiles-private の入力を持ち「# FAKE_」の行を持たなければ (compare の新しい形・
#     登録したホストの旧い形)、式の getAttr "<h>" の <h> の、その入力の hosts/<h>.nix を F にし、入力の shared/*.nix
#     (shared/ の module) を当てる: shared/ の「# FAKE_EVAL_ERROR: <文>」で落ち、drvPath と outPath の後ろに +shared を
#     付け、FAKE_DOTFILES の後ろに shared/ の FAKE_DOTFILES を足す (同じパスなら後ろの shared/ が勝つ)。「# FAKE_SHARED_NOOP」
#     の行を持つ shared/ のファイルは、何も変えない module として数えない。shared/ が当たらないのに F に
#     「# FAKE_NEEDS_SHARED: <文>」があれば落ちる。F に「# FAKE_EVAL_ERROR: <文>」があれば落ちる。
#       tryEval (inspect)        F の「# FAKE_OUT: <h> <outPath>」ごとに「out<TAB><h><TAB><outPath>」(options.dotfiles を含む式は下)
#       options.dotfiles         F (と shared/) の「# FAKE_DOTFILES: <パス> <値>」ごとに「<パス><TAB><値>」
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
      p=$(sed -n 's|.*inputs\.dotfiles-private\.url = "path:\([^"]*\)".*|\1|p' "${PJP_FLAKE}/flake.nix")
      values=()
      if [[ -n ${p} && -f ${p}/hosts/${PJP_BASE}.nix ]] && ! grep -q '^# FAKE_' "${PJP_FLAKE}/flake.nix"; then
        values=("${p}/hosts/${PJP_BASE}.nix")
        for s in "${p}"/shared/*.nix; do
          [[ ! -f ${s} ]] || grep -q '^# FAKE_SHARED_NOOP' "${s}" || values+=("${s}")
        done
        if ((${#values[@]} == 1)); then
          e=$(sed -n 's/^# FAKE_NEEDS_SHARED: //p' "${values[0]}")
          [[ -z ${e} ]] || fail_with "${e}" >&2
        fi
      fi
      printf 'DRAFT base=%s name=%s\n' "${PJP_BASE}" "${PJP_NAME}"
      printf 'MAIN=%s\n' "$(sed -n 's|^ *inputs\.dotfiles\.url = "path:\([^"]*\)";|\1|p' "${PJP_FLAKE}/flake.nix")"
      for s in ${values[@]+"${values[@]}"}; do
        sed -n 's/^# FAKE_DOTFILES: \([^ ]*\) \(.*\)$/VALUE \1 \2/p' "${s}"
      done
      cat "${PJP_NOTES}"
      exit 0
    fi
    d=${3#path:}
    d=${d%%#*}
    f="${d}/flake.nix"
    expr=$5
    h=$(sed -n 's/.*getAttr "\([^"]*\)".*/\1/p' <<<"${expr}")
    p=$(sed -n 's|.*inputs\.dotfiles-private\.url = "path:\([^"]*\)".*|\1|p' "${f}")
    shared=()
    if [[ -n ${p} && -n ${h} ]] && ! grep -q '^# FAKE_' "${f}"; then
      f="${p}/hosts/${h}.nix"
      for s in "${p}"/shared/*.nix; do
        [[ ! -f ${s} ]] || grep -q '^# FAKE_SHARED_NOOP' "${s}" || shared+=("${s}")
      done
    fi
    e=$(sed -n 's/^# FAKE_EVAL_ERROR: //p' "${f}" ${shared[@]+"${shared[@]}"})
    [[ -z ${e} ]] || fail_with "${e}" >&2
    if ((${#shared[@]} == 0)); then
      e=$(sed -n 's/^# FAKE_NEEDS_SHARED: //p' "${f}")
      [[ -z ${e} ]] || fail_with "${e}" >&2
    fi
    plus=""
    ((${#shared[@]} == 0)) || plus=+shared
    case ${expr} in
      *options.dotfiles*)
        sed -n 's/^# FAKE_DOTFILES: \([^ ]*\) \(.*\)$/\1\t\2/p' "${f}" ${shared[@]+"${shared[@]}"}
        ;;
      *tryEval*)
        sed -n 's/^# FAKE_OUT: \([^ ]*\) \(.*\)$/out\t\1\t\2/p' "${f}"
        ;;
      *drvPath*)
        drv=$(sed -n -e "s/^# FAKE_DRV: ${h} //p" -e 's/^# FAKE_DRV: \([^ ]*\)$/\1/p' "${f}")
        o=$(sed -n -e "s/^# FAKE_OUT: ${h} //p" -e 's/^# FAKE_OUT: \([^ ]*\)$/\1/p' "${f}")
        printf '%s\n%s' "${drv}${plus}" "${o}${plus}"
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
  && ! grep -qF 'shared/' "${c}/out" \
  && grep -qxF "  inputs.dotfiles.url = \"path:${c}/repo/nix\";" "${c}/cw/new/flake.nix" \
  && grep -qxF "  inputs.dotfiles-private.url = \"path:${c}/pw/nix\";" "${c}/cw/new/flake.nix" \
  && grep -qxF "  inputs.dotfiles.url = \"path:${c}/repo/nix\";" "${c}/cw/old/flake.nix"; then
  ok "compare: 旧い形と新しい形が同じ本体を指し、drvPath が同じなら 0 (shared/ が無ければ shared/ の行は出さない)"
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

# shared/ のある登録の場面を 1 つ作り、その場所を出す (register_case に足す)。元のホストは型 (alice@x86_64-linux) で、
# ローカル flake は clone の nix/ を読む (clone の shared/ は型には当たらない)。
#   <ケース>/local/flake.nix         旧い形の答えに mise.releaseAgeOverrides [] を足し、dotfiles-private の入力を clone の nix/ へ
#   <ケース>/private/nix/shared/     clone の shared/ (release-age.nix)
#   <ケース>/pw/nix/hosts/alice@box.nix   旧い形と同じ drvPath・値の登録 (mise.releaseAgeOverrides は [])
#   <ケース>/pw/nix/shared/          release-age.nix (mise.releaseAgeOverrides に「全ホスト」の項目を足す module) と、module に
#                                    数えない README.md・.#lock.nix
shared_case() {
  local c
  c=$(register_case "$1")
  {
    echo '# FAKE_DOTFILES: mise.releaseAgeOverrides []'
    sed "s|path:${c}/repo/nix/private-stub|path:${c}/private/nix|" "${c}/local/flake.nix"
  } >"${c}/local/flake.nix.new"
  mv "${c}/local/flake.nix.new" "${c}/local/flake.nix"
  mkdir -p "${c}/private/nix/shared" "${c}/pw/nix/hosts" "${c}/pw/nix/shared"
  printf '# FAKE_DRV: /nix/store/same.drv\n# FAKE_OUT: %s/store/gen-1\n# FAKE_DOTFILES: ccPages.port 7801\n# FAKE_DOTFILES: mise.releaseAgeOverrides []\n{ mkHome, ... }: mkHome { }\n' \
    "${c}" >"${c}/pw/nix/hosts/alice@box.nix"
  printf '# FAKE_DOTFILES: mise.releaseAgeOverrides [{"reason":"全ホスト"}]\n{ }\n' >"${c}/pw/nix/shared/release-age.nix"
  cp "${c}/pw/nix/shared/release-age.nix" "${c}/private/nix/shared/"
  printf 'shared/ の説明\n' >"${c}/pw/nix/shared/README.md"
  printf '{ }\n' >"${c}/pw/nix/shared/.#lock.nix"
  echo "${c}"
}

# 15. compare: shared/ に module があれば、新しい形を shared/ を外しても評価する。外した形が旧い形と同じなら 0 (同じ。shared/ の値
#     だけ違う) とし、登録で増える値として shared/ が足す値を別に出す。README.md と . で始まるファイルは module に数えない。
#     元のホストが型なら、ローカル flake の読む clone に shared/ があっても、compare の旧い形と draft は shared/ を外さない
c=$(shared_case r15)
run_nix "${c}" compare --base alice@x86_64-linux --private "${c}/pw" --flake "${c}/local"
r_only=$(rc "${c}")
o_only=$(out "${c}")
run_nix "${c}" draft --base alice@x86_64-linux --flake "${c}/local"
d_type=$(err "${c}")
if [[ ${r_only} == 0 && ${o_only} == *"同じ (shared/ の値だけ違う)"* && ${o_only} == *"shared/ の module: release-age.nix ("* &&
  ${o_only} == *'mise.releaseAgeOverrides: [] → [{"reason":"全ホスト"}]'* && ${o_only} == *"登録でこの PC に増える"* &&
  ${o_only} != *ccPages.port* && ${o_only} != *"を外して評価する"* && ${d_type} != *"を外して描いた"* ]]; then
  ok "compare: shared/ を外した新しい形が旧い形と同じなら 0 (同じ。shared/ の値だけ違う) とし、shared/ が足す値を別に出す"
else
  ng "compare (shared/ の値だけ違う)" "rc=${r_only} ${o_only} $(err "${c}") draft: ${d_type}"
fi

# 16. compare: shared/ を外しても旧い形と違えば 1。違いは、ホストのファイルの分 (旧い → shared/ を外した新しい形) と shared/ が
#     足す値 (shared/ を外した新しい形 → 新しい形) に分けて出す
sed -i -e 's|^# FAKE_DRV: .*|# FAKE_DRV: /nix/store/other.drv|' -e 's|ccPages.port 7801|ccPages.port 7802|' \
  "${c}/pw/nix/hosts/alice@box.nix"
run_nix "${c}" compare --base alice@x86_64-linux --private "${c}/pw" --flake "${c}/local"
r_split=$(rc "${c}")
host_part=$(sed -n '/^→/,/shared\/ が足す値/p' "${c}/out")
shared_part=$(sed -n '/shared\/ が足す値/,$p' "${c}/out")
if [[ ${r_split} == 1 && ${host_part} == *"ccPages.port: 7801 → 7802"* && ${host_part} != *releaseAgeOverrides* &&
  ${shared_part} == *'mise.releaseAgeOverrides: [] → [{"reason":"全ホスト"}]'* && ${shared_part} != *ccPages.port* ]]; then
  ok "compare: shared/ を外しても違えば 1。ホストのファイルの違いと、shared/ が足す値を分けて出す"
else
  ng "compare (shared/ を外しても違う)" "rc=${r_split} $(out "${c}") $(err "${c}")"
fi

# 16b. compare: shared/ の module がこのホストの値を変えない (shared/ を足した形と外した形の drvPath が同じ) なら、shared/ が足す値の
#      段にそう出す (dotfiles の option の外を変えている、とは出さない)
printf '# FAKE_SHARED_NOOP\n{ }\n' >"${c}/pw/nix/shared/release-age.nix"
run_nix "${c}" compare --base alice@x86_64-linux --private "${c}/pw" --flake "${c}/local"
r_noop=$(rc "${c}")
shared_part=$(sed -n '/shared\/ が足す値/,$p' "${c}/out")
if [[ ${r_noop} == 1 && ${shared_part} == *"shared/ はこのホストの値を変えない"* && ${shared_part} != *"option の外"* ]]; then
  ok "compare: shared/ がこのホストの値を変えないなら、shared/ が足す値の段にそう出す"
else
  ng "compare (shared/ がこのホストを変えない)" "rc=${r_noop} $(out "${c}") $(err "${c}")"
fi

# 17. compare: shared/ を足した新しい形が落ちれば 4 (list でない option を shared/ とホストのファイルの両方に書いた、など)。shared/ を
#     外した形だけが落ちれば (ホストのファイルが shared/ に頼っている)、原因の行を出し、shared/ を含めた形で比べる
c=$(shared_case r17)
printf '# FAKE_EVAL_ERROR: shared/ とホストのファイルの定義がぶつかる\n' >>"${c}/pw/nix/shared/release-age.nix"
run_nix "${c}" compare --base alice@x86_64-linux --private "${c}/pw" --flake "${c}/local"
r_conflict=$(rc "${c}")
e_conflict=$(err "${c}")
sed -i '/FAKE_EVAL_ERROR/d' "${c}/pw/nix/shared/release-age.nix"
printf '# FAKE_NEEDS_SHARED: shared/ の option が無い\n' >>"${c}/pw/nix/hosts/alice@box.nix"
run_nix "${c}" compare --base alice@x86_64-linux --private "${c}/pw" --flake "${c}/local"
r_needs=$(rc "${c}")
o_needs=$(out "${c}")
if [[ ${r_conflict} == 4 && ${e_conflict} == *"定義がぶつかる"* && ${r_needs} == 1 &&
  ${o_needs} == *"shared/ を外した新しい形を評価できない"* && ${o_needs} == *"shared/ の option が無い"* &&
  ${o_needs} == *'mise.releaseAgeOverrides: [] → [{"reason":"全ホスト"}]'* ]]; then
  ok "compare: shared/ を足した形が落ちれば 4。shared/ を外した形だけが落ちれば、原因を出して shared/ を含めた形で比べる"
else
  ng "compare (shared/ の形が落ちる)" "衝突=${r_conflict} (${e_conflict}) 外すと落ちる=${r_needs} (${o_needs} $(err "${c}"))"
fi

# 18. 元のホストが dotfiles-private に登録したホスト (登録した値を直すとき。ローカル flake が clone の nix/ を読み、clone の shared/ が
#     元のホストに当たっている): compare は旧い形からも shared/ を外し、ホストのファイルどうしの違いだけを出す。clone と作業ツリーの
#     shared/ が同じなら、そう 1 行で出す (shared/ の値は登録で増える値ではないので並べない)。draft は shared/ を外して描く (shared/ の
#     値をホストのファイルに書かない)。どちらも clone には書かない。inspect は clone の shared/ の module を出す
c=$(register_case r18)
mkdir -p "${c}/private/nix/shared" "${c}/pw/nix/hosts" "${c}/pw/nix/shared"
printf '# FAKE_DRV: /nix/store/box.drv\n# FAKE_OUT: %s/store/gen-1\n# FAKE_DOTFILES: ccPages.port 7801\n# FAKE_DOTFILES: mise.releaseAgeOverrides []\n{ mkHome, ... }: mkHome { }\n' \
  "${c}" >"${c}/private/nix/hosts/alice@box.nix"
printf '# FAKE_DOTFILES: mise.releaseAgeOverrides [{"reason":"全ホスト"}]\n{ }\n' >"${c}/private/nix/shared/release-age.nix"
printf 'shared/ の説明\n' >"${c}/private/nix/shared/README.md"
cat >"${c}/local/flake.nix" <<EOF
{
  inputs.dotfiles.url = "path:${c}/repo/nix";
  inputs.dotfiles-private.url = "path:${c}/private/nix";
  inputs.dotfiles-private.flake = false;
  outputs =
    { dotfiles, dotfiles-private, ... }:
    {
      homeConfigurations = dotfiles.homeConfigurations // dotfiles.lib.privateHosts dotfiles-private;
    };
}
EOF
# 作業ツリー: ccPages.port だけを直した alice@box と、clone と同じ shared/
sed -e 's|box\.drv|box2.drv|' -e 's|ccPages.port 7801|ccPages.port 7802|' "${c}/private/nix/hosts/alice@box.nix" \
  >"${c}/pw/nix/hosts/alice@box.nix"
cp -R "${c}/private/nix/shared/." "${c}/pw/nix/shared/"
cp -R "${c}/private/nix" "${c}/clone.before"
run_nix "${c}" compare --base alice@box --private "${c}/pw" --flake "${c}/local"
r_reg=$(rc "${c}")
o_reg=$(out "${c}")
if [[ ${r_reg} == 1 && ${o_reg} == *"shared/ (release-age.nix) を外して評価する"* && ${o_reg} == *"ccPages.port: 7801 → 7802"* &&
  ${o_reg} == *"shared/ は clone と作業ツリーで同じ"* && ${o_reg} != *releaseAgeOverrides* && ${o_reg} != *"登録でこの PC に増える"* ]]; then
  ok "compare: 元のホストが登録したホストなら、旧い形からも clone の shared/ を外してホストのファイルどうしで比べ、shared/ が同じならそう出す"
else
  ng "compare (元のホストが登録したホスト)" "rc=${r_reg} ${o_reg} $(err "${c}")"
fi
# 18b. 同じ場面で、ホストのファイルも shared/ も clone と同じ (merge のあとに clone で比べ直すときもこの形) なら、0 で「世代の中身は
#      変わらない」(shared/ の値だけ違う、とは出さない)
cp "${c}/private/nix/hosts/alice@box.nix" "${c}/pw/nix/hosts/alice@box.nix"
run_nix "${c}" compare --base alice@box --private "${c}/pw" --flake "${c}/local"
r_same=$(rc "${c}")
o_same=$(out "${c}")
run_nix "${c}" compare --base alice@box --private "${c}/private" --flake "${c}/local"
r_clone=$(rc "${c}")
o_clone=$(out "${c}")
if [[ ${r_same} == 0 && ${o_same} == *"世代の中身は変わらない"* && ${o_same} != *"shared/ の値だけ違う"* &&
  ${o_same} != *releaseAgeOverrides* && ${r_clone} == 0 && ${o_clone} == *"世代の中身は変わらない"* ]]; then
  ok "compare: 登録したホストを元に、ホストのファイルも shared/ も同じなら 0 で「世代の中身は変わらない」(clone との比べ直しも)"
else
  ng "compare (登録したホスト・同じ)" "作業ツリー: rc=${r_same} ${o_same} / clone: rc=${r_clone} ${o_clone} $(err "${c}")"
fi
# 18c. 同じ場面で、ホストのファイルは同じで作業ツリーの shared/ だけが clone と違うなら、0 で「同じ (shared/ の値だけ違う)」とし、
#      shared/ が違うことと作業ツリーの shared/ が足す値を出す
printf '# FAKE_DOTFILES: mise.releaseAgeOverrides [{"reason":"全ホスト"},{"reason":"新しい項目"}]\n{ }\n' \
  >"${c}/pw/nix/shared/release-age.nix"
run_nix "${c}" compare --base alice@box --private "${c}/pw" --flake "${c}/local"
r_moved=$(rc "${c}")
o_moved=$(out "${c}")
if [[ ${r_moved} == 0 && ${o_moved} == *"同じ (shared/ の値だけ違う)"* && ${o_moved} == *"clone と作業ツリーの shared/ が違う"* &&
  ${o_moved} == *'mise.releaseAgeOverrides: [] → [{"reason":"全ホスト"},{"reason":"新しい項目"}]'* ]]; then
  ok "compare: 登録したホストを元に、作業ツリーの shared/ だけが clone と違えば 0 (shared/ の値だけ違う) とし、作業ツリーの shared/ の値を出す"
else
  ng "compare (登録したホスト・shared/ だけ違う)" "rc=${r_moved} ${o_moved} $(err "${c}")"
fi
cp "${c}/private/nix/shared/release-age.nix" "${c}/pw/nix/shared/release-age.nix"
# 18d. 登録したホストのファイルが shared/ に頼っている (shared/ を外すと評価できない) なら、draft と compare は 3 で止まり、shared/ を
#      外して評価したことを出す
cp "${c}/private/nix/hosts/alice@box.nix" "${c}/needs.before"
printf '# FAKE_NEEDS_SHARED: shared/ の option が無い\n' >>"${c}/private/nix/hosts/alice@box.nix"
run_nix "${c}" draft --base alice@box --flake "${c}/local"
r_dneeds=$(rc "${c}")
e_dneeds=$(err "${c}")
run_nix "${c}" compare --base alice@box --private "${c}/pw" --flake "${c}/local"
r_cneeds=$(rc "${c}")
e_cneeds=$(err "${c}")
mv "${c}/needs.before" "${c}/private/nix/hosts/alice@box.nix"
if [[ ${r_dneeds} == 3 && ${e_dneeds} == *"shared/ (release-age.nix) を外して評価した"* && ${e_dneeds} == *"shared/ の option が無い"* &&
  ${r_cneeds} == 3 && ${e_cneeds} == *"shared/ (release-age.nix) を外して評価した"* ]]; then
  ok "draft・compare: 登録したホストが shared/ に頼っていれば、3 で止まり shared/ を外して評価したことを出す"
else
  ng "draft・compare (shared/ に頼るホスト)" "draft: rc=${r_dneeds} ${e_dneeds} / compare: rc=${r_cneeds} ${e_cneeds}"
fi
# 18e. --out が作業ツリーの nix/ の中・ローカル flake の読む dotfiles-private の nix/ の中なら、写す前に 2 で止める
run_nix "${c}" compare --base alice@box --private "${c}/pw" --flake "${c}/local" --out "${c}/pw/nix/cw"
r_out_pw=$(rc "${c}")
e_out_pw=$(err "${c}")
run_nix "${c}" compare --base alice@box --private "${c}/pw" --flake "${c}/local" --out "${c}/private/nix/cw"
r_out_clone=$(rc "${c}")
e_out_clone=$(err "${c}")
if [[ ${r_out_pw} == 2 && ${e_out_pw} == *"作業ツリーの nix/ の中"* && ${r_out_clone} == 2 &&
  ${e_out_clone} == *"dotfiles-private の nix/ の中"* && ! -e ${c}/pw/nix/cw && ! -e ${c}/private/nix/cw ]]; then
  ok "compare: --out が作業ツリーの nix/ やローカル flake の読む dotfiles-private の nix/ の中なら、作る前に 2"
else
  ng "compare (--out の置き場所)" "作業ツリー: rc=${r_out_pw} ${e_out_pw} / clone: rc=${r_out_clone} ${e_out_clone}"
fi
run_nix "${c}" draft --base alice@box --flake "${c}/local"
d_rc=$(rc "${c}")
d_out=$(out "${c}")
if [[ ${d_rc} == 0 && ${d_out} == *"VALUE ccPages.port 7801"* && ${d_out} == *"VALUE mise.releaseAgeOverrides []"* &&
  ${d_out} != *'"全ホスト"'* ]] && grep -qF 'shared/ (release-age.nix) を外して描いた' "${c}/err"; then
  ok "draft: 元のホストが登録したホストなら、clone の shared/ を外して描く (shared/ の値をホストのファイルに書かない)"
else
  ng "draft (元のホストが登録したホスト)" "rc=${d_rc} ${d_out} $(err "${c}")"
fi
run_nix "${c}" inspect --flake "${c}/local"
if [[ $(rc "${c}") == 0 ]] && grep -qxF '  shared/ (登録した全ホストに足す module): release-age.nix' "${c}/out"; then
  ok "inspect: clone の shared/ の module (README.md は数えない) を出す"
else
  ng "inspect (shared/)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi
if diff -r "${c}/clone.before" "${c}/private/nix" >/dev/null; then
  ok "compare・draft・inspect: shared/ を外すのは写しで、clone (dotfiles-private) には書かない"
else
  ng "clone が変わった" "$(diff -r "${c}/clone.before" "${c}/private/nix")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
