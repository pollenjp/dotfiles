#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/closure-scan.sh が sbomnix (vulnxscan 同梱) を用意する順 (対象の pin → dotfiles の pin → 対象の flake.lock の
# git の履歴にある前の pin) と、退いたことの出し方を、nix の包み (eval は本物の nix に --store dummy:// を付けて渡し、
# build は偽の sbomnix と閉包を作る) と本物の git の repo で確かめる。
#
#   bash nix/tests/closure-scan.test.sh [<closure-scan.sh のパス>]
#
# flake の checks (closure-scan-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・git・jq・nix (flake.lock を
# 読む nix eval) だけ。
#
# ## 確かめること
#
#   - PATH に sbomnix と vulnxscan があれば組まずにそれで照らし、scanner.txt の出どころを「PATH」にする
#   - 対象の pin で組めればそれで照らし、警告を出さない (scanner.txt の出どころは「対象の pin」)。組んだ sbomnix には
#     成果物のディレクトリから out-link (GC root) を張る
#   - 対象の pin で組めなければ dotfiles の pin (store の app に渡す flake.lock) へ退き、その sbomnix で照らす。
#     退いたことを警告 (stderr と setup の警告のまとめ) と GitHub Actions の annotation と scanner.txt に出す。
#     scanner.txt には組めなかった pin と、そのわけ (最初に組めなかった derivation の名前) も残す
#   - dotfiles 自身のスキャン (script の隣の flake が対象) では、dotfiles の pin を対象と同じ pin として二度組まず、
#     git の履歴の前の pin へ退く。前の pin は first-parent でたどる (merge した branch の途中の pin は試さない)
#   - lock を書き換えたまま (update の直後・commit の前) なら、HEAD の pin へ退く
#   - 前の pin は新しい順に 3 つまで試す (同じ pin は数えない)
#   - どれでも組めなければ、試した pin とわけを並べて止まる (終了コード 1)。git の repo の外なら前の pin を
#     さかのぼっていないことを、履歴の浅い clone なら fetch-depth: 0 を添える。dotfiles の pin が対象と同じなら
#     二度組まない
#   - findings の照合: vulns.csv の whitelist の列が False の組だけを new-findings.txt に出して門で落ち、列が無ければ
#     止まる。baseline は whitelist に無い組だけを 1 行ずつ足す (同じ組を二重に足さない)
#
# 偽の nix build は、組めてよい pin の rev を FAKE_SBOMNIX_OK のファイルから 1 行ずつ読み、試した pin を FAKE_NIX_LOG へ
# 「sbomnix <rev>」の行で残す。偽の sbomnix と vulnxscan は、呼ばれた自分のパスを FAKE_RUN_LOG へ残す。偽の vulnxscan は
# FAKE_VULNS の csv を findings として書く (無ければ findings なし)。偽のコマンドの shebang は $BASH から作る (Nix の
# サンドボックスには /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/closure-scan.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/closure-scan-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT
# store の app と同じく、隣 (../flake.nix) に flake の無い場所へ写して流す (チェックアウトから流しても、隣の
# dotfiles の flake を退き先に拾わないため)。dotfiles 自身のスキャンのケースは、repo の中へ写して流す
app="${work}/app/bin/closure-scan.sh"
mkdir -p "${work}/app/bin"
cp "${script}" "${app}"

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

if ! real_nix=$(command -v nix); then
  echo "nix が見つからない" >&2
  exit 1
fi
if command -v sbomnix &>/dev/null || command -v vulnxscan &>/dev/null; then
  echo "PATH に sbomnix か vulnxscan があると、組む順を確かめられない" >&2
  exit 1
fi
export HOME="${work}/home"
mkdir -p "${HOME}"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# 外から効く値は、ケースごとに渡すものだけにする
unset GITHUB_ACTIONS DOTFILES_SETUP_WARNINGS CLOSURE_SCAN_DOTFILES_FLAKE_LOCK FAKE_VULNS

# 偽の sbomnix と vulnxscan。偽の nix build が store のパスへ写す
tools="${work}/tools"
mkdir -p "${tools}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$0" >>"${FAKE_RUN_LOG:?}"
while [[ $# -gt 0 ]]; do
  case $1 in
    --csv | --cdx | --spdx)
      : >"$2"
      shift 2
      ;;
    --version)
      echo 9.9
      exit 0
      ;;
    *) shift ;;
  esac
done
EOF
} >"${tools}/sbomnix"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$0" >>"${FAKE_RUN_LOG:?}"
echo "(偽の vulnxscan)"
# FAKE_VULNS があれば、その csv を -o の先へ写す (無ければ findings なしで csv を書かない)
while [[ $# -gt 0 ]]; do
  case $1 in
    -o)
      if [[ -n ${FAKE_VULNS-} ]]; then cp "${FAKE_VULNS}" "$2"; fi
      shift 2
      ;;
    *) shift ;;
  esac
done
EOF
} >"${tools}/vulnxscan"
chmod +x "${tools}/sbomnix" "${tools}/vulnxscan"

bin="${work}/bin"
mkdir -p "${bin}"
{
  printf '#!%s\n' "${BASH}"
  printf 'real=%q\n' "${real_nix}"
  printf 'store=%q\n' "${work}/store"
  printf 'tools=%q\n' "${tools}"
  cat <<'EOF'
case $1 in
  eval) exec "${real}" --store dummy:// --extra-experimental-features 'nix-command flakes' "$@" ;;
  build) shift ;;
  *)
    echo "偽の nix: 知らない呼び出し: $*" >&2
    exit 1
    ;;
esac
link=""
from=""
installable=""
print=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -o | --out-link)
      link=$2
      shift 2
      ;;
    --inputs-from)
      from=$2
      shift 2
      ;;
    --print-out-paths)
      print=1
      shift
      ;;
    -*) shift ;;
    *)
      installable=$1
      shift
      ;;
  esac
done
if [[ ${installable} == *'#sbomnix' ]]; then
  # どの pin か: --inputs-from ならその flake の flake.lock の nixpkgs、ref ならその rev
  if [[ -n ${from} ]]; then
    rev=$(jq -r '.nodes[.nodes[.root].inputs.nixpkgs].locked.rev' "${from}/flake.lock")
  else
    rev=${installable#github:NixOS/nixpkgs/}
    rev=${rev%%[?#]*}
  fi
  printf 'sbomnix %s\n' "${rev}" >>"${FAKE_NIX_LOG:?}"
  if ! grep -qx "${rev}" "${FAKE_SBOMNIX_OK:?}"; then
    echo "error: Cannot build '/nix/store/00000000000000000000000000000000-python3.14-sqliteschema-2.0.1.drv'." >&2
    echo "       Reason: builder failed with exit code 1." >&2
    exit 1
  fi
  p="${store}/${rev}-sbomnix-9.9"
  mkdir -p "${p}/bin"
  cp "${tools}/sbomnix" "${tools}/vulnxscan" "${p}/bin/"
else
  p="${store}/closure"
  mkdir -p "${p}"
fi
if [[ -n ${link} ]]; then
  ln -sfn "${p}" "${link}"
fi
if [[ ${print} == 1 ]]; then
  printf '%s\n' "${p}"
fi
EOF
} >"${bin}/nix"
chmod +x "${bin}/nix"
PATH="${bin}:${PATH}"

# pin k の rev (40 桁) と narHash (SRI の形。nix が長さを確かめる)
rev() { printf 'c0ffee%034d' "$1"; }
nar() {
  local c
  c=$(printf '%s' BCDEFGHIJKLMNOPQRSTUVWXYZ | cut -c"$1")
  printf 'sha256-%s%sA=' "$(printf "%0.s${c}" {1..21})" "$(printf "%0.s${c}" {1..21})"
}
# nixpkgs の pin が k ($1) の flake.lock。$2 を渡すと home-manager の node も足す (nixpkgs の pin は同じまま、
# lock の中身だけが変わる commit を作るため)
lock() {
  local hm="" hm_root=""
  if [[ -n ${2:-} ]]; then
    hm=$(printf ', "home-manager": {"locked": {"lastModified": 1, "narHash": "%s", "owner": "nix-community", "repo": "home-manager", "rev": "%s", "type": "github"}, "original": {"owner": "nix-community", "repo": "home-manager", "type": "github"}}' \
      "$(nar "$2")" "$(rev "$2")")
    hm_root=', "home-manager": "home-manager"'
  fi
  printf '{"nodes": {"nixpkgs": {"locked": {"lastModified": %s, "narHash": "%s", "owner": "NixOS", "repo": "nixpkgs", "rev": "%s", "type": "github"}, "original": {"owner": "NixOS", "ref": "nixpkgs-unstable", "repo": "nixpkgs", "type": "github"}}%s, "root": {"inputs": {"nixpkgs": "nixpkgs"%s}}}, "root": "root", "version": 7}\n' \
    "$((1790000000 + $1))" "$(nar "$1")" "$(rev "$1")" "${hm}" "${hm_root}"
}

# flake のディレクトリ ($1) を、nixpkgs の pin が k ($2) の flake.lock で作る
new_flake() {
  mkdir -p "$1"
  cat >"$1/flake.nix" <<'EOF'
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = _: { };
}
EOF
  lock "$2" >"$1/flake.lock"
  printf '"vuln_id","package","comment"\n' >"$1/vulnxscan-whitelist.csv"
}

# dotfiles の形の git の repo ($1) を作る: nix/ に flake と、確かめる script を置き、pin が k ($2) の lock で commit する
new_repo() {
  git init -q -b main "$1"
  new_flake "$1/nix" "$2"
  mkdir -p "$1/nix/scripts"
  cp "${script}" "$1/nix/scripts/closure-scan.sh"
  git -C "$1" add -A
  git -C "$1" commit -qm "pin $2"
}

# repo ($1) の nix/flake.lock を pin k ($2。$3 は lock の home-manager) にして commit する
commit_lock() {
  lock "$2" "${3:-}" >"$1/nix/flake.lock"
  git -C "$1" commit -qam "pin $2"
}

# ケースのディレクトリ ($1 の名前) を作り、組めてよい pin (k を 2 つ目からの引数に) を書く
new_case() {
  local d="${work}/cases/$1" k
  shift
  mkdir -p "${d}"
  : >"${d}/ok.txt"
  for k in "$@"; do
    printf '%s\n' "$(rev "${k}")" >>"${d}/ok.txt"
  done
  : >"${d}/nix.log"
  : >"${d}/run.log"
  printf '%s\n' "${d}"
}

# closure-scan.sh の動作 $1 (scan・baseline) を流す。$2: ケースのディレクトリ、$3: 流す script、残り: script の引数の
# 後ろに足すもの (flake の場所)。出力は <ケース>/stdout・stderr・rc、成果物は <ケース>/out
run_cmd() {
  local sub=$1 d=$2 s=$3
  shift 3
  FAKE_NIX_LOG="${d}/nix.log" FAKE_RUN_LOG="${d}/run.log" FAKE_SBOMNIX_OK="${d}/ok.txt" \
    bash "${s}" "${sub}" --attr packages.x86_64-linux.fake --out-dir "${d}/out" "$@" \
    >"${d}/stdout" 2>"${d}/stderr" </dev/null
  echo "$?" >"${d}/rc"
}
scan() { run_cmd scan "$@"; }

# 試した pin の rev を、試した順に 1 行ずつ出す
tried() { sed -n 's/^sbomnix //p' "$1/nix.log"; }
# 期待する試した順 (k を並べる)
expect_tried() {
  local k
  for k in "$@"; do printf '%s\n' "$(rev "${k}")"; done
}

# 1 つめのケースの結果を比べる: $1 名前、$2 ケース、$3 期待の rc、$4 期待の試した順 (改行区切り)
check_rc_tried() {
  local d=$2 got_rc got_tried
  got_rc=$(cat "${d}/rc")
  got_tried=$(tried "${d}")
  if [[ ${got_rc} == "$3" && ${got_tried} == "$4" ]]; then
    ok "$1"
  else
    ng "$1" "rc=${got_rc} (期待 $3)
試した pin:
${got_tried}
期待:
$4
stderr:
$(cat "${d}/stderr")"
  fi
}

echo "PATH の sbomnix"
d=$(new_case path)
new_flake "${d}/flake" 1
mkdir -p "${d}/pathbin"
cp "${tools}/sbomnix" "${tools}/vulnxscan" "${d}/pathbin/"
PATH="${d}/pathbin:${PATH}" scan "${d}" "${app}" "${d}/flake"
check_rc_tried "PATH にあれば組まない" "${d}" 0 ""
if grep -qx '出どころ: PATH' "${d}/out/scanner.txt" && grep -qxF "${d}/pathbin/vulnxscan" "${d}/run.log"; then
  ok "PATH の sbomnix で照らし、scanner.txt の出どころを PATH にする"
else
  ng "PATH の sbomnix で照らし、scanner.txt の出どころを PATH にする" "$(cat "${d}/out/scanner.txt" "${d}/run.log" 2>&1)"
fi

echo "対象の pin"
d=$(new_case target 1)
new_flake "${d}/flake" 1
scan "${d}" "${app}" "${d}/flake"
check_rc_tried "対象の pin で組めればそれだけを組む" "${d}" 0 "$(expect_tried 1)"
if grep -q '^出どころ: 対象の pin ' "${d}/out/scanner.txt" \
  && grep -qxF "${work}/store/$(rev 1)-sbomnix-9.9/bin/vulnxscan" "${d}/run.log"; then
  ok "対象の pin の sbomnix で照らし、scanner.txt の出どころを対象の pin にする"
else
  ng "対象の pin の sbomnix で照らし、scanner.txt の出どころを対象の pin にする" "$(cat "${d}/out/scanner.txt" "${d}/run.log" 2>&1)"
fi
if grep -q '^!! ' "${d}/stderr"; then
  ng "対象の pin で組めれば警告を出さない" "$(cat "${d}/stderr")"
else
  ok "対象の pin で組めれば警告を出さない"
fi
if [[ $(readlink "${d}/out/sbomnix") == "${work}/store/$(rev 1)-sbomnix-9.9" ]]; then
  ok "組んだ sbomnix に、成果物のディレクトリから out-link を張る"
else
  ng "組んだ sbomnix に、成果物のディレクトリから out-link を張る" "$(ls -l "${d}/out" 2>&1)"
fi

echo "dotfiles の pin へ退く (store の app に渡す flake.lock)"
d=$(new_case dotfiles 1)
new_flake "${d}/flake" 2
lock 1 >"${d}/dotfiles-flake.lock"
CLOSURE_SCAN_DOTFILES_FLAKE_LOCK="${d}/dotfiles-flake.lock" GITHUB_ACTIONS=true DOTFILES_SETUP_WARNINGS="${d}/warnings" \
  scan "${d}" "${app}" "${d}/flake"
check_rc_tried "対象の pin の次に dotfiles の pin を組む" "${d}" 0 "$(expect_tried 2 1)"
if grep -q '^出どころ: dotfiles の pin ' "${d}/out/scanner.txt" \
  && grep -qxF "${work}/store/$(rev 1)-sbomnix-9.9/bin/vulnxscan" "${d}/run.log"; then
  ok "dotfiles の pin の sbomnix で照らし、scanner.txt の出どころを dotfiles の pin にする"
else
  ng "dotfiles の pin の sbomnix で照らし、scanner.txt の出どころを dotfiles の pin にする" "$(cat "${d}/out/scanner.txt" "${d}/run.log" 2>&1)"
fi
if grep -q "^組めなかった pin: 対象の pin .*$(rev 2).*python3.14-sqliteschema-2.0.1" "${d}/out/scanner.txt"; then
  ok "scanner.txt に、組めなかった対象の pin と、最初に組めなかった derivation を残す"
else
  ng "scanner.txt に、組めなかった対象の pin と、最初に組めなかった derivation を残す" "$(cat "${d}/out/scanner.txt" 2>&1)"
fi
if grep -q '^!! sbomnix を対象の pin で組めなかったので、dotfiles の pin ' "${d}/stderr" \
  && grep -q '^sbomnix を対象の pin で組めなかったので、dotfiles の pin ' "${d}/warnings"; then
  ok "退いたことを警告し、setup の警告のまとめにも残す"
else
  ng "退いたことを警告し、setup の警告のまとめにも残す" "$(cat "${d}/stderr" "${d}/warnings" 2>&1)"
fi
if grep -q '^::warning title=closure-scan::sbomnix を対象の pin で組めなかったので、dotfiles の pin .*%0A' "${d}/stdout"; then
  ok "GitHub Actions の中なら annotation を出す (改行は %0A)"
else
  ng "GitHub Actions の中なら annotation を出す (改行は %0A)" "$(cat "${d}/stdout")"
fi

echo "dotfiles 自身のスキャン: git の履歴の前の pin へ退く"
d=$(new_case self 1)
repo="${d}/repo"
new_repo "${repo}" 1
c1=$(git -C "${repo}" rev-parse --short HEAD)
git -C "${repo}" switch -q -c feat
commit_lock "${repo}" 3
commit_lock "${repo}" 2
git -C "${repo}" switch -q main
git -C "${repo}" merge -q --no-ff -m "merge feat" feat
scan "${d}" "${repo}/nix/scripts/closure-scan.sh"
check_rc_tried "対象 (= dotfiles) の pin を二度組まず、first-parent の前の pin を組む (branch の途中の pin 3 は試さない)" \
  "${d}" 0 "$(expect_tried 2 1)"
if grep -q "^出どころ: 対象の前の pin (commit ${c1} の flake.lock) .*$(rev 1)" "${d}/out/scanner.txt"; then
  ok "scanner.txt の出どころを、前の pin の commit で出す"
else
  ng "scanner.txt の出どころを、前の pin の commit で出す" "$(cat "${d}/out/scanner.txt" 2>&1)"
fi

echo "lock を書き換えたまま (commit の前)"
d=$(new_case dirty 1)
repo="${d}/repo"
new_repo "${repo}" 1
c1=$(git -C "${repo}" rev-parse --short HEAD)
lock 2 >"${repo}/nix/flake.lock"
scan "${d}" "${repo}/nix/scripts/closure-scan.sh"
check_rc_tried "HEAD の pin へ退く" "${d}" 0 "$(expect_tried 2 1)"
if grep -q "^出どころ: 対象の前の pin (commit ${c1} の flake.lock) " "${d}/out/scanner.txt"; then
  ok "scanner.txt の出どころを HEAD の commit で出す"
else
  ng "scanner.txt の出どころを HEAD の commit で出す" "$(cat "${d}/out/scanner.txt" 2>&1)"
fi

echo "前の pin は 3 つまで"
d=$(new_case max)
repo="${d}/repo"
# 新しい順に 8 (今の pin) → 7 → 6 (home-manager だけ上げた commit) → 6 → 5 → 4。6 は 1 つと数え、4 は試さない
new_repo "${repo}" 4
commit_lock "${repo}" 5
commit_lock "${repo}" 6
commit_lock "${repo}" 6 1
commit_lock "${repo}" 7
commit_lock "${repo}" 8
scan "${d}" "${repo}/nix/scripts/closure-scan.sh"
check_rc_tried "対象の pin のあと、前の pin を新しい順に 3 つまで組む (同じ pin は数えない)" "${d}" 1 "$(expect_tried 8 7 6 5)"

echo "どれでも組めない"
d=$(new_case none)
new_flake "${d}/flake" 2
lock 3 >"${d}/dotfiles-flake.lock"
CLOSURE_SCAN_DOTFILES_FLAKE_LOCK="${d}/dotfiles-flake.lock" scan "${d}" "${app}" "${d}/flake"
check_rc_tried "対象の pin と dotfiles の pin を組んで止まる" "${d}" 1 "$(expect_tried 2 3)"
if grep -q "^  対象の pin .*$(rev 2).*python3.14-sqliteschema-2.0.1" "${d}/stderr" \
  && grep -q "^  dotfiles の pin .*$(rev 3)" "${d}/stderr" \
  && grep -q 'git の repo の中に無いので、前の pin はさかのぼっていません' "${d}/stderr"; then
  ok "試した pin とわけを並べ、git の repo の外ならさかのぼっていないことを添える"
else
  ng "試した pin とわけを並べ、git の repo の外ならさかのぼっていないことを添える" "$(cat "${d}/stderr")"
fi
if grep -q "^組めなかった pin: dotfiles の pin " "${d}/out/scanner.txt"; then
  ok "止まるときも scanner.txt に組めなかった pin を残す"
else
  ng "止まるときも scanner.txt に組めなかった pin を残す" "$(cat "${d}/out/scanner.txt" 2>&1)"
fi

d=$(new_case same)
new_flake "${d}/flake" 2
lock 2 >"${d}/dotfiles-flake.lock"
CLOSURE_SCAN_DOTFILES_FLAKE_LOCK="${d}/dotfiles-flake.lock" scan "${d}" "${app}" "${d}/flake"
check_rc_tried "dotfiles の pin が対象と同じなら二度組まない" "${d}" 1 "$(expect_tried 2)"

d=$(new_case shallow 1)
repo="${d}/repo"
new_repo "${repo}" 1
commit_lock "${repo}" 2
git clone -q --depth 1 "file://${repo}" "${d}/clone"
scan "${d}" "${d}/clone/nix/scripts/closure-scan.sh"
check_rc_tried "履歴の浅い clone では前の pin をたどれない" "${d}" 1 "$(expect_tried 2)"
if grep -q 'fetch-depth: 0' "${d}/stderr"; then
  ok "履歴の浅い clone なら fetch-depth: 0 を添える"
else
  ng "履歴の浅い clone なら fetch-depth: 0 を添える" "$(cat "${d}/stderr")"
fi

echo "findings の照合 (whitelist の列・baseline)"
vulns_header='"vuln_id","url","package","version","whitelist","whitelist_comment"'
d=$(new_case gate 1)
new_flake "${d}/flake" 1
printf '%s\n' "${vulns_header}" '"CVE-0001","u","pkga","1","False",""' '"CVE-0002","u","pkgb","1","True","ok"' \
  >"${d}/vulns.csv"
FAKE_VULNS="${d}/vulns.csv" scan "${d}" "${app}" "${d}/flake"
if [[ $(cat "${d}/rc") == 1 && $(cat "${d}/out/new-findings.txt") == $'CVE-0001\tpkga' ]]; then
  ok "whitelist の列が False の findings だけを new-findings.txt に出し、門で落ちる"
else
  ng "whitelist の列が False の findings だけを new-findings.txt に出し、門で落ちる" \
    "rc=$(cat "${d}/rc") new-findings=$(cat "${d}/out/new-findings.txt" 2>&1)"
fi

d=$(new_case nocol 1)
new_flake "${d}/flake" 1
printf '%s\n' '"vuln_id","url","package","version"' '"CVE-0001","u","pkga","1"' >"${d}/vulns.csv"
FAKE_VULNS="${d}/vulns.csv" scan "${d}" "${app}" "${d}/flake"
if [[ $(cat "${d}/rc") == 1 ]] && grep -q 'vulns.csv に whitelist 列がありません' "${d}/stderr"; then
  ok "vulns.csv に whitelist の列が無ければ止まる"
else
  ng "vulns.csv に whitelist の列が無ければ止まる" "rc=$(cat "${d}/rc") $(cat "${d}/stderr")"
fi

d=$(new_case baseline 1)
new_flake "${d}/flake" 1
printf '"CVE-0001","pkga","前から受け入れていた"\n' >>"${d}/flake/vulnxscan-whitelist.csv"
printf '%s\n' "${vulns_header}" '"CVE-0001","u","pkga","1","False",""' '"CVE-0003","u","pkgc","1","False",""' \
  '"CVE-0003","u","pkgc","2","False",""' >"${d}/vulns.csv"
FAKE_VULNS="${d}/vulns.csv" run_cmd baseline "${d}" "${app}" "${d}/flake"
wl="${d}/flake/vulnxscan-whitelist.csv"
if [[ $(cat "${d}/rc") == 0 && $(grep -c '^"CVE-0001","pkga",' "${wl}") == 1 && $(grep -c '^"CVE-0003","pkgc",' "${wl}") == 1 ]]; then
  ok "baseline は whitelist に無い組だけを 1 行ずつ足す (同じ組を二重に足さない)"
else
  ng "baseline は whitelist に無い組だけを 1 行ずつ足す (同じ組を二重に足さない)" "rc=$(cat "${d}/rc")
$(cat "${wl}")"
fi

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} -eq 0 ]]
