#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-pjp.sh (claude-skills の shim の pjp を入れ、pjp --build を流す手順) を、使い捨ての HOME と偽の
# claude-skills の clone と、偽の cargo・nix・pjp で確かめる。
#
#   bash nix/tests/bootstrap-pjp.test.sh [<nix/scripts のパス>]
#
# flake の checks (bootstrap-pjp-test) が Nix のサンドボックスで流す。setup.sh の手順の並びも見るので、nix/scripts を丸ごと
# 渡す。使うのは bash と coreutils・awk・grep だけ。
#
# ## 確かめること
#
#   - clone が決まらない (claude-skills-dir も PJP_SKILLS_DIR も無い) か、clone に crates/pjp-shim が無い (claude-skills の W0-1
#     より前) なら、cargo も nix も打たずに「飛ばします」と出して 0 で終わる (警告しない)
#   - shim が無ければ、clone の中で、clone の rust-toolchain.toml の channel を RUSTUP_TOOLCHAIN にして
#     cargo install --locked --path <clone>/crates/pjp-shim を打ち、その後で PJP_SKILLS_DIR=<clone> の pjp --build を打つ
#     (警告しない)。cargo は $CARGO_HOME/bin の cargo を PATH の cargo より先に使う。clone は、claude-skills-dir より
#     PJP_SKILLS_DIR を、それより --dir を先に見る
#   - 入れてある shim の版 (pjp --version) が clone の crates/pjp-shim の版と同じなら入れ直さず「のまま」と出し、pjp --build は打つ。
#     版が違う・shim が起きない (終了コードが 0 でない) なら入れ直す
#   - cargo はあるが Linux でリンカの cc が無いとき、cargo が無いときは、nix develop --profile ~/.local/state/dotfiles/pjp-shim-devshell
#     path:<clone>/nix --command env RUSTUP_TOOLCHAIN=<channel> cargo install … を clone の中で打つ (devShell を GC root に残す)
#   - cargo も nix も無いとき、cargo install・nix・pjp --build が落ちたとき、rust-toolchain.toml の channel か crates/pjp-shim の
#     version を読めないときは、警告して (setup の最後のまとめにも残し) 0 で終わる。落ちた後の手順 (pjp --build) は打たない
#   - --dry-run では、cargo・nix・pjp を打たずに、打つコマンドを「+ 」の行で出す
#   - setup の手順の並び (setup.sh --list) で、bootstrap-mise・bootstrap-claude-skills の後、bootstrap-herdr-hub の前に来る
#
# 偽の cargo は「cwd|RUSTUP_TOOLCHAIN|引数」を、偽の nix は「nix|引数」を、偽の pjp は「pjp|PJP_SKILLS_DIR|引数」を $HOME/calls に
# 1 行ずつ残す。偽の cargo の install は ${CARGO_HOME:-~/.cargo}/bin/pjp に偽の pjp (FAKE_SHIM_VERSION の版。既定 0.1.0) を書き、
# FAKE_CARGO_FAIL=install なら落ちる。偽の nix は --profile の先に profile の link を作ってから、--command の後ろを打つ
# (FAKE_NIX_FAIL=1 なら落ちる)。偽の pjp の --build は FAKE_BUILD_RC で終わる。サンドボックスの stdenv の cc を拾わないよう、
# PATH は使うコマンドだけを並べた dir (farm) と偽物の dir で作る。偽物の shebang は $BASH から作る。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
scripts=${1:-${here}/../scripts}
script=${scripts}/bootstrap-pjp.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-pjp-test.XXXXXX")
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

# script と偽物が使うコマンドだけを並べた dir (cc は置かない)
farm="${work}/farm"
mkdir -p "${farm}"
for c in bash env awk head uname mkdir cat chmod ln touch rm sed grep; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${farm}/${c}"
done

# 偽物の dir: cargo・nix と、リンカの cc (cc だけ別の dir に置き、PATH に入れるかで有無を変える)
fakes="${work}/fakes"
ccdir="${work}/ccbin"
mkdir -p "${fakes}" "${ccdir}"

# 偽の pjp の中身を出す道具。$1: 版。偽の cargo の install と、テストが入れてある shim を置くときに使う
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '#!%s\n' "${BASH}"
cat <<INNER
case \${1-} in
  --version) echo "pjp $1" ;;
  --build)
    printf 'pjp|%s|%s\n' "\${PJP_SKILLS_DIR-}" "\$*" >>"\${HOME}/calls"
    exit "\${FAKE_BUILD_RC:-0}"
    ;;
esac
INNER
EOF
} >"${work}/shim-text"

{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s|%s|%s\n' "${PWD}" "${RUSTUP_TOOLCHAIN-}" "$*" >>"${HOME}/calls"
if [[ ${1-} == install ]]; then
  if [[ ${FAKE_CARGO_FAIL-} == install ]]; then
    echo "error: 偽の cargo の失敗" >&2
    exit 101
  fi
  bin="${CARGO_HOME:-${HOME}/.cargo}/bin"
  mkdir -p "${bin}"
  "${FAKE_SHIM_TEXT}" "${FAKE_SHIM_VERSION:-0.1.0}" >"${bin}/pjp"
  chmod +x "${bin}/pjp"
fi
exit 0
EOF
} >"${fakes}/cargo"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf 'nix|%s\n' "$*" >>"${HOME}/calls"
[[ -z ${FAKE_NIX_FAIL-} ]] || exit 1
profile=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)
      profile=$2
      shift 2
      ;;
    --command)
      shift
      break
      ;;
    *) shift ;;
  esac
done
if [[ -n ${profile} ]]; then
  touch "${profile}-1-link"
  ln -sfn "${profile}-1-link" "${profile}"
fi
# devShell と同じく、cargo (rustup) を PATH に足してから打つ
PATH="${FAKE_DEVSHELL_PATH}:${PATH}" exec "$@"
EOF
} >"${fakes}/nix"
printf '#!%s\nexit 0\n' "${BASH}" >"${ccdir}/cc"
chmod +x "${fakes}/cargo" "${fakes}/nix" "${ccdir}/cc" "${work}/shim-text"

# 1 ケースぶんの HOME と clone を作る。$1: 名前。clone は <HOME>/clone (crates/pjp-shim の版 0.1.0・channel 1.99.1・nix/flake.nix)。
# claude-skills-dir には clone の場所を書く
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/clone/crates/pjp-shim" "${h}/clone/nix" "${h}/cargo-home/bin" "${h}/pathbin"
  printf '[package]\nname = "pjp-shim"\n# shim の版\nversion = "0.1.0"\n\n[dependencies]\nserde_json.workspace = true\n' \
    >"${h}/clone/crates/pjp-shim/Cargo.toml"
  printf '# toolchain\n[toolchain]\nchannel = "1.99.1"\ncomponents = ["clippy", "rustfmt"]\n' >"${h}/clone/rust-toolchain.toml"
  : >"${h}/clone/nix/flake.nix"
  printf '%s\n' "${h}/clone" >"${h}/.local/state/dotfiles/claude-skills-dir"
  : >"${h}/calls"
  echo "${h}"
}

# script を流す。$1: HOME。残りは script の引数。呼ぶ側の CASE_PATH (PATH の頭に置く dir。既定は偽物と cc)・PJP_SKILLS_DIR・
# FAKE_* を渡す。CARGO_HOME は <HOME>/cargo-home
run() {
  local h=$1
  shift
  local -a envs=(
    HOME="${h}" PATH="${CASE_PATH-${fakes}:${ccdir}}:${farm}" CARGO_HOME="${h}/cargo-home"
    DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_SHIM_TEXT="${work}/shim-text" FAKE_DEVSHELL_PATH="${fakes}"
    FAKE_CARGO_FAIL="${FAKE_CARGO_FAIL-}" FAKE_NIX_FAIL="${FAKE_NIX_FAIL-}" FAKE_BUILD_RC="${FAKE_BUILD_RC-0}"
    FAKE_SHIM_VERSION="${FAKE_SHIM_VERSION-0.1.0}"
  )
  [[ -z ${PJP_SKILLS_DIR-} ]] || envs+=(PJP_SKILLS_DIR="${PJP_SKILLS_DIR}")
  env -i "${envs[@]}" "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

# 出力と呼び出しの記録
detail() {
  printf 'rc=%s\n--- calls\n%s\n--- out\n%s\n--- err\n%s\n--- warnings\n%s' "$(cat "$1/rc")" "$(cat "$1/calls")" \
    "$(cat "$1/out")" "$(cat "$1/err")" "$(cat "$1/warnings" 2>/dev/null)"
}
no_warning() { ! grep -Fq '!! ' "$1/err" && [[ ! -s $1/warnings ]]; }
warned() { grep -Fq '!! ' "$1/err" && grep -Fq -- "$2" "$1/warnings"; }
rc0() { [[ $(cat "$1/rc") == 0 ]]; }
# 偽の cargo を CARGO_HOME の bin に置く (PATH の cargo より先に見つかる場所)
place_cargo_in_home() { ln -s "${fakes}/cargo" "$1/cargo-home/bin/cargo"; }
# 入れてある shim を置く。$2: 版 (broken なら起きない shim)
place_shim() {
  if [[ $2 == broken ]]; then
    printf '#!%s\nexit 127\n' "${BASH}" >"$1/cargo-home/bin/pjp"
  else
    "${work}/shim-text" "$2" >"$1/cargo-home/bin/pjp"
  fi
  chmod +x "$1/cargo-home/bin/pjp"
}
install_line() { printf '%s|1.99.1|install --locked --path %s\n' "$1/clone" "$1/clone/crates/pjp-shim"; }
build_line() { printf 'pjp|%s|--build\n' "$1/clone"; }

echo "== bootstrap-pjp.sh: ${script}"

# 1. clone が決まらない・Rust の道具の無い clone
h=$(new_home no-clone)
rm -f "${h}/.local/state/dotfiles/claude-skills-dir"
run "${h}"
h2=$(new_home no-shim-crate)
rm -rf "${h2}/clone/crates"
run "${h2}"
if rc0 "${h}" && [[ ! -s ${h}/calls ]] && grep -Fq '飛ばします' "${h}/out" && no_warning "${h}" \
  && rc0 "${h2}" && [[ ! -s ${h2}/calls ]] && grep -Fq 'crates/pjp-shim' "${h2}/out" && no_warning "${h2}"; then
  ok "clone が決まらない・crates/pjp-shim の無い clone なら、何も打たずに飛ばす (警告しない)"
else
  ng "clone が決まらない・crates/pjp-shim が無い" "$(detail "${h}")"$'\n'"$(detail "${h2}")"
fi

# 2. shim が無い: CARGO_HOME の cargo で入れてから pjp --build
h=$(new_home fresh)
place_cargo_in_home "${h}"
ln -s "${fakes}/cargo" "${h}/pathbin/cargo"
CASE_PATH="${h}/pathbin:${ccdir}:${fakes}" run "${h}"
want="$(install_line "${h}")"$'\n'"$(build_line "${h}")"
if rc0 "${h}" && [[ $(cat "${h}/calls") == "${want}" ]] && [[ -x ${h}/cargo-home/bin/pjp ]] && no_warning "${h}" \
  && grep -Fq '完了しました' "${h}/out"; then
  ok "shim が無ければ、clone の中で channel を RUSTUP_TOOLCHAIN にして cargo install を打ち、PJP_SKILLS_DIR=<clone> の pjp --build を打つ"
else
  ng "shim が無い" "want=${want}"$'\n'"$(detail "${h}")"
fi
# CARGO_HOME の cargo を使ったか (PATH の cargo は ${h}/pathbin。ここでは同じ偽物を指すので、使った場所を out の + 行で見る)
if grep -Fq "+ env RUSTUP_TOOLCHAIN=1.99.1 ${h}/cargo-home/bin/cargo install --locked --path ${h}/clone/crates/pjp-shim" "${h}/out"; then
  ok "cargo は \$CARGO_HOME/bin の cargo を PATH の cargo より先に使う"
else
  ng "\$CARGO_HOME/bin の cargo を先に使う" "$(detail "${h}")"
fi

# clone は claude-skills-dir より PJP_SKILLS_DIR を、それより --dir を先に見る
h=$(new_home dir-order)
place_cargo_in_home "${h}"
cp -r "${h}/clone" "${h}/clone-env"
cp -r "${h}/clone" "${h}/clone-arg"
PJP_SKILLS_DIR="${h}/clone-env" run "${h}"
env_ok=$(grep -Fq "pjp|${h}/clone-env|--build" "${h}/calls" && echo yes)
rm -f "${h}/cargo-home/bin/pjp"
: >"${h}/calls"
PJP_SKILLS_DIR="${h}/clone-env" run "${h}" --dir "${h}/clone-arg"
if [[ ${env_ok} == yes ]] && rc0 "${h}" && grep -Fq "pjp|${h}/clone-arg|--build" "${h}/calls" \
  && grep -Fq "install --locked --path ${h}/clone-arg/crates/pjp-shim" "${h}/calls"; then
  ok "clone は claude-skills-dir より PJP_SKILLS_DIR を、それより --dir を先に見る"
else
  ng "clone の決まり方" "env_ok=${env_ok}"$'\n'"$(detail "${h}")"
fi

# 3. 同じ版の shim は入れ直さない。違う版・起きない shim は入れ直す
h=$(new_home same)
place_cargo_in_home "${h}"
place_shim "${h}" 0.1.0
run "${h}"
if rc0 "${h}" && [[ $(cat "${h}/calls") == "$(build_line "${h}")" ]] && grep -Fq '0.1.0 のまま' "${h}/out" && no_warning "${h}"; then
  ok "入れてある shim が clone と同じ版なら入れ直さず「のまま」と出し、pjp --build は打つ"
else
  ng "同じ版の shim" "$(detail "${h}")"
fi
for have in 0.0.9 broken; do
  h=$(new_home "reinstall-${have}")
  place_cargo_in_home "${h}"
  place_shim "${h}" "${have}"
  run "${h}"
  want="$(install_line "${h}")"$'\n'"$(build_line "${h}")"
  if rc0 "${h}" && [[ $(cat "${h}/calls") == "${want}" ]] && no_warning "${h}"; then
    ok "入れてある shim が ${have} なら入れ直す"
  else
    ng "shim が ${have}" "want=${want}"$'\n'"$(detail "${h}")"
  fi
done

# 4. cc が無い・cargo が無い: nix の devShell の中で入れ、devShell を GC root に残す
for kind in no-cc no-cargo; do
  h=$(new_home "devshell-${kind}")
  case ${kind} in
    no-cc)
      place_cargo_in_home "${h}"
      CASE_PATH="${fakes}" run "${h}"
      ;;
    no-cargo)
      ln -s "${fakes}/nix" "${h}/pathbin/nix"
      CASE_PATH="${h}/pathbin:${ccdir}" run "${h}"
      ;;
  esac
  profile="${h}/.local/state/dotfiles/pjp-shim-devshell"
  want="nix|develop --profile ${profile} path:${h}/clone/nix --command env RUSTUP_TOOLCHAIN=1.99.1 cargo install --locked --path ${h}/clone/crates/pjp-shim"
  if rc0 "${h}" && [[ $(sed -n 1p "${h}/calls") == "${want}" ]] && [[ -L ${profile} ]] \
    && [[ $(sed -n 3p "${h}/calls") == "$(build_line "${h}")" ]] && no_warning "${h}"; then
    ok "${kind}: nix develop --profile <state>/pjp-shim-devshell path:<clone>/nix の中で cargo install を打ち、pjp --build を打つ"
  else
    ng "${kind}: devShell" "want=${want}"$'\n'"$(detail "${h}")"
  fi
done
# no-cargo の 2 行目 (devShell の中の cargo) が clone の中で channel を付けて打たれたか
if [[ $(sed -n 2p "${h}/calls") == "${h}/clone|1.99.1|install --locked --path ${h}/clone/crates/pjp-shim" ]]; then
  ok "devShell の中の cargo install も、clone の中で channel を RUSTUP_TOOLCHAIN にして打つ"
else
  ng "devShell の中の cargo install" "$(detail "${h}")"
fi

# 5. 落ちたとき
h=$(new_home no-cargo-no-nix)
CASE_PATH="${ccdir}" run "${h}"
if rc0 "${h}" && [[ ! -s ${h}/calls ]] && warned "${h}" 'nix'; then
  ok "cargo も nix も無ければ、警告して 0 で終わる (何も打たない)"
else
  ng "cargo も nix も無い" "$(detail "${h}")"
fi
h=$(new_home cargo-fails)
place_cargo_in_home "${h}"
FAKE_CARGO_FAIL=install run "${h}"
if rc0 "${h}" && [[ $(cat "${h}/calls") == "$(install_line "${h}")" ]] && warned "${h}" '入れられませんでした'; then
  ok "cargo install が落ちたら、警告して 0 で終わる (pjp --build は打たない)"
else
  ng "cargo install が落ちる" "$(detail "${h}")"
fi
h=$(new_home nix-fails)
place_cargo_in_home "${h}"
FAKE_NIX_FAIL=1 CASE_PATH="${fakes}" run "${h}"
if rc0 "${h}" && [[ $(grep -c '' "${h}/calls") == 1 ]] && warned "${h}" 'devShell'; then
  ok "nix develop が落ちたら、警告して 0 で終わる (pjp --build は打たない)"
else
  ng "nix develop が落ちる" "$(detail "${h}")"
fi
h=$(new_home build-fails)
place_cargo_in_home "${h}"
place_shim "${h}" 0.1.0
FAKE_BUILD_RC=101 run "${h}"
if rc0 "${h}" && [[ $(cat "${h}/calls") == "$(build_line "${h}")" ]] && warned "${h}" '作れませんでした'; then
  ok "pjp --build が落ちたら、警告して 0 で終わる"
else
  ng "pjp --build が落ちる" "$(detail "${h}")"
fi
for broken in channel version; do
  h=$(new_home "unreadable-${broken}")
  place_cargo_in_home "${h}"
  case ${broken} in
    channel) printf '[toolchain]\ncomponents = ["clippy"]\n' >"${h}/clone/rust-toolchain.toml" ;;
    version) printf '[package]\nname = "pjp-shim"\nversion.workspace = true\n' >"${h}/clone/crates/pjp-shim/Cargo.toml" ;;
  esac
  run "${h}"
  if rc0 "${h}" && [[ ! -s ${h}/calls ]] && warned "${h}" '読めません'; then
    ok "${broken} を読めなければ、警告して 0 で終わる (何も打たない)"
  else
    ng "${broken} を読めない" "$(detail "${h}")"
  fi
done

# 6. --dry-run
h=$(new_home dry-run)
place_cargo_in_home "${h}"
run "${h}" --dry-run
if rc0 "${h}" && [[ ! -s ${h}/calls ]] && [[ ! -e ${h}/cargo-home/bin/pjp ]] \
  && grep -Fq "+ env RUSTUP_TOOLCHAIN=1.99.1 ${h}/cargo-home/bin/cargo install --locked --path ${h}/clone/crates/pjp-shim" "${h}/out" \
  && grep -Fq "+ env PJP_SKILLS_DIR=${h}/clone ${h}/cargo-home/bin/pjp --build" "${h}/out" && no_warning "${h}"; then
  ok "--dry-run では何も打たず、打つコマンドを「+ 」の行で出す"
else
  ng "--dry-run" "$(detail "${h}")"
fi

# 7. setup の手順の並び: bootstrap-mise・bootstrap-claude-skills の後、bootstrap-herdr-hub の前。使い捨ての checkout に setup.sh と
# bootstrap を写し、登録簿を置いて --list で並べる
o="${work}/order"
mkdir -p "${o}/repo/nix/scripts" "${o}/repo/nix/hosts" "${o}/home"
cp "${scripts}/setup.sh" "${scripts}/bootstrap-mise.sh" "${scripts}/bootstrap-claude-skills.sh" "${script}" \
  "${scripts}/bootstrap-herdr-hub.sh" "${o}/repo/nix/scripts/"
printf '{ mkHome }:\n{\n  testhost = mkHome {\n    username = "test";\n  };\n}\n' >"${o}/repo/nix/hosts/default.nix"
listed=$(env HOME="${o}/home" TMPDIR="${work}" "${BASH}" "${o}/repo/nix/scripts/setup.sh" --list 2>&1 </dev/null)
ids=$(awk '$1 ~ /^bootstrap-/ { print $1 }' <<<"${listed}")
if [[ ${ids} == $'bootstrap-mise\nbootstrap-claude-skills\nbootstrap-pjp\nbootstrap-herdr-hub' ]]; then
  ok "setup の手順の並びで、bootstrap-mise・bootstrap-claude-skills の後、bootstrap-herdr-hub の前に来る"
else
  ng "setup の手順の並び" "${listed}"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
