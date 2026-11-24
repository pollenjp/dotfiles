#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/check-cargo-lock-vulns.sh の振る舞いを、偽の osv-scanner と使い捨ての git の repo で確かめる。
#
#   bash nix/tests/check-cargo-lock-vulns.test.sh [<script のパス>]
#
# flake の checks (check-cargo-lock-vulns-test) が Nix のサンドボックスで流す。ネットワークには出ない (osv-scanner は偽物で、
# 渡された引数・stdin・cwd・TZ を記録し、ケースごとに決めた表を --output-file の先へ写して、決めた終了コードで終わる)。
# 使うのは bash・git・coreutils・grep だけ。script はケースごとの repo の nix/scripts/ へ写して流す (script は自分の 2 つ上を
# repo の root とみなす)。今の時刻は CHECK_CARGO_LOCK_VULNS_NOW で 2026-11-24 12:00 (UTC) に決める (受け入れの期限は
# 2027-02-22 まで書ける)。
#
# ## 確かめること
#
#   - git の追う Cargo.lock を全部 (repo の root のものも、深い所のものも)、git ls-files の順に --lockfile で渡す。git が追って
#     いない Cargo.lock と、名前が Cargo.lock でないファイルは渡さない。osv-scanner は scan source --no-call-analysis=all
#     --format markdown --output-file で、repo の root を cwd・stdin を空・TZ を UTC にして呼ぶ
#   - osv-scanner が 0 なら exit 0、1 (advisory がある) なら exit 1 で、照らした Cargo.lock・受け入れ・osv-scanner の表を出し、
#     1 のときは直し方 (cargo update -p … --precise …・受け入れ) も出す。--out-dir (相対のパスは呼んだ所から読む。--out-dir=<dir>
#     も) には同じ中身を report.md に書く
#   - osv-scanner がほかの終了コード (127・128・130) で終わったら exit 2。git の追う Cargo.lock が無ければ、osv-scanner を呼ばずに
#     exit 2
#   - GitHub Actions の中 (GITHUB_ACTIONS=true) なら、落ちる理由を ::error の行に、期限を過ぎた受け入れを ::warning の行にも出す
#     (外では出さない)
#   - 受け入れ (Cargo.lock の隣の osv-scanner.toml) の [[IgnoredVulns]] の id・ignoreUntil・reason を読み、期限の前のものを
#     受け入れとして並べる (コメント・空行・字下げ・CRLF・reason の中の \" も読む)。ignoreUntil が今日 (UTC) 以前の項目は、止めずに
#     期限を過ぎたと知らせる。90 日先 (2027-02-22) は書け、91 日先は書けない。今日は TZ によらず UTC で数える
#   - 受け入れの書き損じは、osv-scanner を呼ばずに exit 2 で、ファイルと行を出す: id・ignoreUntil・reason の欠け、空白だけの
#     reason、引用符の無い・単引用符の・行末にコメントのある・複数行の文字列、引用符で囲んだ・暦に無い・時刻つきの日付、
#     91 日先の期限、知らない key、[[IgnoredVulns]] でない表、表の外の値、同じ id の 2 度目、1 つの項目の同じ key の 2 度目、
#     項目の無いファイル、隣に git の追う Cargo.lock の無いファイル、照らす Cargo.lock の隣にあって git が追っていないファイル、
#     git が追っているのに作業ツリーに無いファイル。--out-dir にはそのときも report.md を書く
#   - osv-scanner も nix も無ければ exit 2。知らない引数・値の無い --out-dir・UNIX 秒でない CHECK_CARGO_LOCK_VULNS_NOW は exit 2、
#     -h は使い方を出して exit 0
#
# ## 本物の osv-scanner と nix を見せない
#
# 手元の PATH には本物の osv-scanner や nix があり、見えると api.osv.dev へ照らしにいく・nix shell で入り直す。要るコマンドだけを
# symlink で並べた PATH で流す (check-herdr-app-installers.test.sh と同じ作り)。偽の osv-scanner の shebang は $BASH から作る
# (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/check-cargo-lock-vulns.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/check-cargo-lock-vulns-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

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

# 2026-11-24 12:00:00 UTC。今日は 2026-11-24、受け入れの期限は 2027-02-22 まで
now=1795521600

# 要るコマンドだけを並べた PATH (osv-scanner と nix は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env git cat cp mkdir mktemp rm dirname; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 1 ケースぶんの場所を作る。$1: 名前。<case>/repo が git の repo (script を nix/scripts/ に写す)、<case>/bin が偽の osv-scanner
new_case() {
  local d="${work}/$1"
  mkdir -p "${d}/bin" "${d}/repo/nix/scripts"
  git init -q "${d}/repo"
  cp "${script}" "${d}/repo/nix/scripts/check-cargo-lock-vulns.sh"
  # 偽の osv-scanner。引数・stdin・cwd・TZ を記録し、<case>/osv.md を --output-file の先へ写して、<case>/osv-rc (無ければ 0) で終わる
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$@" >"${FAKE_DIR}/osv-args"
cat >"${FAKE_DIR}/osv-stdin"
pwd >"${FAKE_DIR}/osv-cwd"
printf '%s\n' "${TZ-unset}" >"${FAKE_DIR}/osv-tz"
dest='' prev=''
for a in "$@"; do
  if [[ ${prev} == --output-file ]]; then
    dest=${a}
  fi
  prev=${a}
done
if [[ -n ${dest} && -f ${FAKE_DIR}/osv.md ]]; then
  cp "${FAKE_DIR}/osv.md" "${dest}"
fi
rc=0
if [[ -f ${FAKE_DIR}/osv-rc ]]; then
  rc=$(cat "${FAKE_DIR}/osv-rc")
fi
exit "${rc}"
EOF
  } >"${d}/bin/osv-scanner"
  chmod +x "${d}/bin/osv-scanner"
  printf '\nNo issues found\n' >"${d}/osv.md"
  echo "${d}"
}

# repo にファイルを置く。$1: case、$2: repo の中のパス、$3: 中身 (そのまま書く)。add は git に入れる、put は入れない
put() {
  mkdir -p "$(dirname "$1/repo/$2")"
  printf '%s' "$3" >"$1/repo/$2"
}
add() {
  put "$@"
  git -C "$1/repo" add -- "$2"
}

lock='version = 4
'

# $1: case、残り: script の引数。cwd は <case> (repo の外)。GITHUB_ACTIONS は外す (run_gha が立てる)。stdin には字を流す
# (script が osv-scanner に stdin を渡していないことを、サンドボックスの空の stdin でも見られるように)
run() {
  local d=$1
  shift
  (cd "${d}" && env -u GITHUB_ACTIONS PATH="${d}/bin:${sys_bin}" FAKE_DIR="${d}" CHECK_CARGO_LOCK_VULNS_NOW="${now}" \
    "${BASH}" "${d}/repo/nix/scripts/check-cargo-lock-vulns.sh" "$@" <<<"stdin-from-test" >"${d}/out" 2>"${d}/err")
  echo $? >"${d}/rc"
}
run_gha() {
  local d=$1
  shift
  (cd "${d}" && env GITHUB_ACTIONS=true PATH="${d}/bin:${sys_bin}" FAKE_DIR="${d}" CHECK_CARGO_LOCK_VULNS_NOW="${now}" \
    "${BASH}" "${d}/repo/nix/scripts/check-cargo-lock-vulns.sh" "$@" <<<"stdin-from-test" >"${d}/out" 2>"${d}/err")
  echo $? >"${d}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
# 判定の grep -q はパイプで受けず、ファイルを直に読む (pipefail の下で SIGPIPE を拾わない)
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}
# osv-scanner の引数を 1 行に並べる (--output-file の先は一時ファイルなので <out> にする)
osv_args() {
  local d=$1 a prev='' line=''
  [[ -f ${d}/osv-args ]] || return 1
  while IFS= read -r a; do
    if [[ ${prev} == --output-file ]]; then
      a='<out>'
    fi
    line+="${line:+ }${a}"
    prev=${a}
  done <"${d}/osv-args"
  printf '%s\n' "${line}"
}

finding_md='
Total 1 package affected by 1 known vulnerability (0 Critical, 0 High, 0 Medium, 0 Low, 1 Unknown) from 1 ecosystem.
1 vulnerability can be fixed.

| OSV URL | CVSS | Ecosystem | Package | Version | Fixed Version | Source |
| --- | --- | --- | --- | --- | --- | --- |
| https://osv.dev/RUSTSEC-2026-0486 |  | crates.io | rustix | 1.1.5 | 1.1.6 | a/Cargo.lock |
'

echo "== check-cargo-lock-vulns.sh: ${script}"

# 1. git の追う Cargo.lock を全部、git ls-files の順に渡す。無ければ exit 0
d=$(new_case c1)
add "${d}" Cargo.lock "${lock}"
add "${d}" a/Cargo.lock "${lock}"
add "${d}" b/c/Cargo.lock "${lock}"
put "${d}" d/Cargo.lock "${lock}"
add "${d}" e/Cargo.lock.orig "${lock}"
add "${d}" f/x-Cargo.lock "${lock}"
run "${d}"
want='scan source --no-call-analysis=all --format markdown --output-file <out> --lockfile Cargo.lock --lockfile a/Cargo.lock --lockfile b/c/Cargo.lock'
got=$(osv_args "${d}")
if [[ $(rc "${d}") == 0 && ${got} == "${want}" ]] && seen "${d}" -F '照らした Cargo.lock (git が追うもの。3 個)' \
  && seen "${d}" -F -e "- \`b/c/Cargo.lock\`" && seen "${d}" -F 'No issues found' && seen "${d}" -F '受け入れ (osv-scanner.toml): なし' \
  && ! seen "${d}" -F 'd/Cargo.lock' && ! seen "${d}" '^::'; then
  ok "git の追う Cargo.lock を全部 (root も深い所も) git ls-files の順に --lockfile で渡し、無ければ exit 0 (追っていない・名前の違うものは渡さない)"
else
  ng "Cargo.lock を渡す" "rc=$(rc "${d}") args=[${got}] $(outerr "${d}")"
fi
if [[ $(cat "${d}/osv-cwd") == "$(cd "${d}/repo" && pwd -P)" && -e ${d}/osv-stdin && ! -s ${d}/osv-stdin ]] \
  && [[ $(cat "${d}/osv-tz") == UTC ]]; then
  ok "osv-scanner は repo の root を cwd・stdin を空・TZ を UTC にして呼ぶ"
else
  ng "osv-scanner の呼び方" "cwd=$(cat "${d}/osv-cwd") tz=$(cat "${d}/osv-tz") stdin=$(cat "${d}/osv-stdin")"
fi

# 2. --out-dir (相対のパスは呼んだ所から)・--out-dir=<dir> に report.md を書く
d=$(new_case c2)
add "${d}" a/Cargo.lock "${lock}"
run "${d}" --out-dir rel/out
d2=$(new_case c2b)
add "${d2}" a/Cargo.lock "${lock}"
run "${d2}" --out-dir="${d2}/abs"
if [[ $(rc "${d}") == 0 && $(rc "${d2}") == 0 ]] && grep -q -F -e "- \`a/Cargo.lock\`" "${d}/rel/out/report.md" \
  && grep -q -F 'No issues found' "${d}/rel/out/report.md" && grep -q -F 'No issues found' "${d2}/abs/report.md"; then
  ok "--out-dir (相対のパスは呼んだ所から)・--out-dir=<dir> に、照らした Cargo.lock と表の report.md を書く"
else
  ng "--out-dir" "rc=$(rc "${d}") rc2=$(rc "${d2}") $(outerr "${d}") $(outerr "${d2}")"
fi

# 3. advisory がある (osv-scanner が 1): exit 1 で、表と直し方を出す。Actions の中では ::error の行も
d=$(new_case c3)
add "${d}" a/Cargo.lock "${lock}"
printf '%s' "${finding_md}" >"${d}/osv.md"
echo 1 >"${d}/osv-rc"
run "${d}" --out-dir rep
d2=$(new_case c3b)
add "${d2}" a/Cargo.lock "${lock}"
printf '%s' "${finding_md}" >"${d2}/osv.md"
echo 1 >"${d2}/osv-rc"
run_gha "${d2}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F '| https://osv.dev/RUSTSEC-2026-0486 |' \
  && seen "${d}" -F '受け入れていない advisory があります' && seen "${d}" -F 'cargo update -p <crate>@<今の版> --precise <直した版>' \
  && seen "${d}" -F 'osv-scanner.toml に理由と期限' && grep -q -F 'RUSTSEC-2026-0486' "${d}/rep/report.md" \
  && ! seen "${d}" '^::'; then
  ok "advisory があれば exit 1 で、表・直し方 (cargo update -p … --precise …・受け入れ) を出し、report.md にも書く"
else
  ng "advisory がある" "rc=$(rc "${d}") $(outerr "${d}")"
fi
if [[ $(rc "${d2}") == 1 ]] && grep -q '^::error title=Cargo.lock の既知の脆弱性::受け入れていない advisory があります' "${d2}/out"; then
  ok "GitHub Actions の中では、advisory があることを ::error の行にも出す"
else
  ng "::error の行" "rc=$(rc "${d2}") $(outerr "${d2}")"
fi

# 4. osv-scanner が 0・1 のほかで終わった: exit 2
bad=0
detail=''
for code in 127 128 130; do
  d=$(new_case "c4-${code}")
  add "${d}" a/Cargo.lock "${lock}"
  echo "${code}" >"${d}/osv-rc"
  run_gha "${d}"
  if [[ $(rc "${d}") != 2 ]] || ! seen "${d}" -F "osv-scanner が落ちました (終了コード ${code}" || ! seen "${d}" '^::error '; then
    bad=1
    detail+="[${code}] rc=$(rc "${d}") $(outerr "${d}")"$'\n'
  fi
done
if ((bad == 0)); then
  ok "osv-scanner が 0・1 のほか (127・128・130) で終われば exit 2 で、終了コードを出す (Actions の中では ::error も)"
else
  ng "osv-scanner が落ちた" "${detail}"
fi

# 5. git の追う Cargo.lock が無い: osv-scanner を呼ばずに exit 2
d=$(new_case c5)
put "${d}" a/Cargo.lock "${lock}"
add "${d}" README.md 'x'
run "${d}"
if [[ $(rc "${d}") == 2 && ! -e ${d}/osv-args ]] && seen "${d}" -F 'git の追う Cargo.lock がありません'; then
  ok "git の追う Cargo.lock が無ければ、osv-scanner を呼ばずに exit 2"
else
  ng "Cargo.lock が無い" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 6. 受け入れを読む (コメント・空行・字下げ・CRLF・\")。期限の前のものを並べる。90 日先まで書ける
d=$(new_case c6)
add "${d}" a/Cargo.lock "${lock}"
add "${d}" a/osv-scanner.toml "$(printf '%s\r\n' \
  '# 受け入れ' \
  '' \
  '[[IgnoredVulns]]' \
  '  id = "RUSTSEC-2026-0001"' \
  'ignoreUntil=2026-12-31' \
  'reason = "直した版が無い (\"引用\" も書ける)"' \
  '' \
  '[[IgnoredVulns]]' \
  'id = "GHSA-aaaa-bbbb-cccc"' \
  'ignoreUntil = 2027-02-22' \
  'reason = "上流の直しを待つ"')"
run "${d}"
if [[ $(rc "${d}") == 0 && -e ${d}/osv-args ]] && seen "${d}" -F '受け入れ (osv-scanner.toml。ignoreUntil の日から再び出る。2 件)' \
  && seen "${d}" -F -e '- a/osv-scanner.toml: RUSTSEC-2026-0001 (ignoreUntil 2026-12-31): 直した版が無い (\"引用\" も書ける)' \
  && seen "${d}" -F -e '- a/osv-scanner.toml: GHSA-aaaa-bbbb-cccc (ignoreUntil 2027-02-22): 上流の直しを待つ' \
  && ! seen "${d}" -F '書き損じ' && ! seen "${d}" -F '期限を過ぎた'; then
  ok "受け入れの id・ignoreUntil・reason を読み (コメント・空行・字下げ・CRLF・\\\" も)、期限の前のものを並べる (90 日先まで書ける)"
else
  ng "受け入れを読む" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 7. 受け入れの書き損じ: osv-scanner を呼ばずに exit 2 で、ファイルと行を出す
entry() {
  printf '[[IgnoredVulns]]\n'
  printf '%s\n' "$@"
}
id_line='id = "RUSTSEC-2026-0001"'
until_line='ignoreUntil = 2026-12-31'
reason_line='reason = "直した版が無い"'
bad_cases=(
  "reason の欠け|$(entry "${id_line}" "${until_line}")|a/osv-scanner.toml:1: [[IgnoredVulns]] に reason がありません"
  "ignoreUntil の欠け|$(entry "${id_line}" "${reason_line}")|a/osv-scanner.toml:1: [[IgnoredVulns]] に ignoreUntil がありません"
  "id と reason の欠け|$(entry "${until_line}")|a/osv-scanner.toml:1: [[IgnoredVulns]] に id reason がありません"
  "空白だけの reason|$(entry "${id_line}" "${until_line}" 'reason = "  "')|a/osv-scanner.toml:4: reason は引用符で囲んだ"
  "引用符の無い reason|$(entry "${id_line}" "${until_line}" 'reason = 直した版が無い')|a/osv-scanner.toml:4: reason は引用符で囲んだ"
  "単引用符の id|$(entry "id = 'RUSTSEC-2026-0001'" "${until_line}" "${reason_line}")|a/osv-scanner.toml:2: id は引用符で囲んだ"
  "行末のコメント|$(entry "${id_line}" "${until_line}" 'reason = "x" # c')|a/osv-scanner.toml:4: reason は引用符で囲んだ"
  "複数行の文字列|$(entry "${id_line}" "${until_line}" 'reason = """' 'x' '"""')|a/osv-scanner.toml:4: reason は引用符で囲んだ"
  "引用符で囲んだ日付|$(entry "${id_line}" 'ignoreUntil = "2026-12-31"' "${reason_line}")|a/osv-scanner.toml:3: ignoreUntil は引用符の無い暦の日付"
  "暦に無い日付|$(entry "${id_line}" 'ignoreUntil = 2026-02-30' "${reason_line}")|a/osv-scanner.toml:3: ignoreUntil は引用符の無い暦の日付"
  "時刻つきの日付|$(entry "${id_line}" 'ignoreUntil = 2026-12-31T00:00:00Z' "${reason_line}")|a/osv-scanner.toml:3: ignoreUntil は引用符の無い暦の日付"
  "91 日先の期限|$(entry "${id_line}" 'ignoreUntil = 2027-02-23' "${reason_line}")|a/osv-scanner.toml:1: RUSTSEC-2026-0001 の ignoreUntil (2027-02-23) が 90 日より先です (2027-02-22 までにする)"
  "知らない key|$(entry "${id_line}" "${until_line}" "${reason_line}" 'effectiveUntil = 2026-12-31')|a/osv-scanner.toml:5: 知らない key です"
  "ほかの表|$(entry "${id_line}" "${until_line}" "${reason_line}")
[[PackageOverrides]]
name = \"rustix\"|a/osv-scanner.toml:5: 書ける表は [[IgnoredVulns]] だけです"
  "表の外の値|${id_line}
$(entry "${id_line}" "${until_line}" "${reason_line}")|a/osv-scanner.toml:1: [[IgnoredVulns]] の外に値があります"
  "インラインの表|IgnoredVulns = [{ id = \"X\" }]|a/osv-scanner.toml:1: [[IgnoredVulns]] の外に値があります"
  "同じ id の 2 度目|$(entry "${id_line}" "${until_line}" "${reason_line}")
$(entry "${id_line}" "${until_line}" "${reason_line}")|a/osv-scanner.toml:5: RUSTSEC-2026-0001 は 2 度目です"
  "同じ key の 2 度目|$(entry "${id_line}" "${until_line}" "${reason_line}" 'reason = "もう 1 つ"')|a/osv-scanner.toml:5: 1 つの [[IgnoredVulns]] に reason が 2 つあります"
  "項目の無いファイル|# まだ無い|a/osv-scanner.toml: [[IgnoredVulns]] がありません"
)
bad=0
detail=''
i=0
for c in "${bad_cases[@]}"; do
  i=$((i + 1))
  label=${c%%|*}
  rest=${c#*|}
  body=${rest%|*}
  want=${rest##*|}
  d=$(new_case "c7-${i}")
  add "${d}" a/Cargo.lock "${lock}"
  add "${d}" a/osv-scanner.toml "${body}"$'\n'
  run "${d}" --out-dir rep
  if [[ $(rc "${d}") != 2 || -e ${d}/osv-args ]] || ! seen "${d}" -F -- "${want}" \
    || ! grep -q -F -- "${want}" "${d}/rep/report.md"; then
    bad=1
    detail+="[${label}] rc=$(rc "${d}") $(outerr "${d}")"$'\n'
  fi
done
if ((bad == 0)); then
  ok "受け入れの書き損じ (${#bad_cases[@]} 通り) は、osv-scanner を呼ばずに exit 2 で、ファイルと行を出す (report.md にも)"
else
  ng "受け入れの書き損じ" "${detail}"
fi

# 8. 置き場所の書き損じ: 隣に Cargo.lock が無い・git が追っていない・作業ツリーに無い
good_accept="$(entry "${id_line}" "${until_line}" "${reason_line}")"$'\n'
d=$(new_case c8a)
add "${d}" a/Cargo.lock "${lock}"
add "${d}" osv-scanner.toml "${good_accept}"
run "${d}"
d2=$(new_case c8b)
add "${d2}" a/Cargo.lock "${lock}"
put "${d2}" a/osv-scanner.toml "${good_accept}"
run "${d2}"
d3=$(new_case c8c)
add "${d3}" a/Cargo.lock "${lock}"
add "${d3}" a/osv-scanner.toml "${good_accept}"
rm "${d3}/repo/a/osv-scanner.toml"
run_gha "${d3}"
if [[ $(rc "${d}") == 2 && $(rc "${d2}") == 2 && $(rc "${d3}") == 2 ]] \
  && [[ ! -e ${d}/osv-args && ! -e ${d2}/osv-args && ! -e ${d3}/osv-args ]] \
  && seen "${d}" -F 'osv-scanner.toml: 隣に git の追う Cargo.lock がありません' \
  && seen "${d2}" -F 'a/osv-scanner.toml: git が追っていない受け入れです' \
  && seen "${d3}" -F 'a/osv-scanner.toml: git が追っているのに、作業ツリーにありません' \
  && grep -q '^::error title=Cargo.lock の既知の脆弱性::受け入れの書き損じ: a/osv-scanner.toml' "${d3}/out"; then
  ok "隣に git の追う Cargo.lock が無い・git が追っていない・作業ツリーに無い受け入れも、osv-scanner を呼ばずに exit 2 (Actions の中では ::error も)"
else
  ng "置き場所の書き損じ" "rc=$(rc "${d}")/$(rc "${d2}")/$(rc "${d3}") $(outerr "${d}") $(outerr "${d2}") $(outerr "${d3}")"
fi

# 9. 期限を過ぎた受け入れ (今日以前) は止めずに知らせる。明日の期限は受け入れのまま
d=$(new_case c9)
add "${d}" a/Cargo.lock "${lock}"
add "${d}" a/osv-scanner.toml "$(entry 'id = "RUSTSEC-2026-0001"' 'ignoreUntil = 2026-11-24' "${reason_line}")
$(entry 'id = "RUSTSEC-2026-0002"' 'ignoreUntil = 2026-11-01' "${reason_line}")
$(entry 'id = "RUSTSEC-2026-0003"' 'ignoreUntil = 2026-11-25' "${reason_line}")
"
run_gha "${d}"
if [[ $(rc "${d}") == 0 && -e ${d}/osv-args ]] && seen "${d}" -F '期限を過ぎた受け入れ (2 件。止めない)' \
  && seen "${d}" -F 'a/osv-scanner.toml:1: RUSTSEC-2026-0001 の ignoreUntil (2026-11-24) を過ぎました' \
  && seen "${d}" -F 'a/osv-scanner.toml:5: RUSTSEC-2026-0002 の ignoreUntil (2026-11-01) を過ぎました' \
  && seen "${d}" -F -e '- a/osv-scanner.toml: RUSTSEC-2026-0003 (ignoreUntil 2026-11-25)' \
  && seen "${d}" -F '受け入れ (osv-scanner.toml。ignoreUntil の日から再び出る。1 件)' \
  && grep -q '^::warning title=Cargo.lock の既知の脆弱性::期限を過ぎた受け入れ: a/osv-scanner.toml:1: ' "${d}/out" \
  && ! grep -q '^::error ' "${d}/out"; then
  ok "ignoreUntil が今日以前の受け入れは、止めずに期限を過ぎたと知らせる (Actions の中では ::warning)。明日の期限は受け入れのまま"
else
  ng "期限を過ぎた受け入れ" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 10. 今日は TZ によらず UTC で数える (2026-11-24 20:00 UTC は JST では 11-25)
d=$(new_case c10)
add "${d}" a/Cargo.lock "${lock}"
add "${d}" a/osv-scanner.toml "$(entry "${id_line}" 'ignoreUntil = 2026-11-25' "${reason_line}")"$'\n'
(cd "${d}" && env -u GITHUB_ACTIONS TZ=JST-9 PATH="${d}/bin:${sys_bin}" FAKE_DIR="${d}" CHECK_CARGO_LOCK_VULNS_NOW=$((now + 8 * 3600)) \
  "${BASH}" "${d}/repo/nix/scripts/check-cargo-lock-vulns.sh" >"${d}/out" 2>"${d}/err")
echo $? >"${d}/rc"
if [[ $(rc "${d}") == 0 && $(cat "${d}/osv-tz") == UTC ]] && seen "${d}" -F 'RUSTSEC-2026-0001 (ignoreUntil 2026-11-25)' \
  && ! seen "${d}" -F '期限を過ぎた'; then
  ok "今日は TZ によらず UTC で数え、osv-scanner にも TZ=UTC で渡す"
else
  ng "TZ" "rc=$(rc "${d}") tz=$(cat "${d}/osv-tz" 2>/dev/null) $(outerr "${d}")"
fi

# 11. osv-scanner も nix も無い: exit 2
d=$(new_case c11)
add "${d}" a/Cargo.lock "${lock}"
rm "${d}/bin/osv-scanner"
run "${d}"
if [[ $(rc "${d}") == 2 ]] && seen "${d}" -F 'osv-scanner が要ります'; then
  ok "osv-scanner も nix も無ければ exit 2"
else
  ng "osv-scanner が無い" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 12. 引数: 知らない引数・値の無い --out-dir・UNIX 秒でない今は exit 2、-h は exit 0
bad=0
detail=''
i=0
for args in '--bogus' '--out-dir' '--out-dir=' 'extra'; do
  i=$((i + 1))
  d=$(new_case "c12-${i}")
  add "${d}" a/Cargo.lock "${lock}"
  run "${d}" "${args}"
  if [[ $(rc "${d}") != 2 || -e ${d}/osv-args ]]; then
    bad=1
    detail+="[${args}] rc=$(rc "${d}") $(outerr "${d}")"$'\n'
  fi
done
d=$(new_case c12-now)
add "${d}" a/Cargo.lock "${lock}"
(cd "${d}" && env -u GITHUB_ACTIONS PATH="${d}/bin:${sys_bin}" FAKE_DIR="${d}" CHECK_CARGO_LOCK_VULNS_NOW=yesterday \
  "${BASH}" "${d}/repo/nix/scripts/check-cargo-lock-vulns.sh" >"${d}/out" 2>"${d}/err")
echo $? >"${d}/rc"
if [[ $(rc "${d}") != 2 ]] || ! seen "${d}" -F 'CHECK_CARGO_LOCK_VULNS_NOW'; then
  bad=1
  detail+="[NOW=yesterday] rc=$(rc "${d}") $(outerr "${d}")"$'\n'
fi
# --out-dir にファイルを渡した (ディレクトリを作れない)。advisory があるときの 1 と混ぜない
d=$(new_case c12-outfile)
add "${d}" a/Cargo.lock "${lock}"
printf 'x' >"${d}/afile"
run "${d}" --out-dir afile
if [[ $(rc "${d}") != 2 || -e ${d}/osv-args ]] || ! seen "${d}" -F -- '--out-dir のディレクトリを作れません'; then
  bad=1
  detail+="[--out-dir afile] rc=$(rc "${d}") $(outerr "${d}")"$'\n'
fi
d=$(new_case c12-help)
run "${d}" -h
if ((bad == 0)) && [[ $(rc "${d}") == 0 ]] && seen "${d}" '使い方'; then
  ok "知らない引数・値の無い --out-dir・作れない --out-dir・UNIX 秒でない CHECK_CARGO_LOCK_VULNS_NOW は exit 2、-h は使い方を出して exit 0"
else
  ng "引数" "${detail} help: rc=$(rc "${d}") $(outerr "${d}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
