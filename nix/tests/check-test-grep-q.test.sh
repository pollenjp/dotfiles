#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/check-test-grep-q.sh の振る舞いを、使い捨てのテストのファイルで確かめる。
#
#   bash nix/tests/check-test-grep-q.test.sh [<script のパス>]
#
# flake の checks (check-test-grep-q-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・grep と、
# script が使う shfmt・jq。サンドボックスの外で流すときは shfmt と jq を PATH に用意する (nix/ の devShell にある)。
#
# ## 確かめること
#
#   - grep -q (-qF・-Fxq などのまとめ書き・--quiet・--silent・引用符で囲んだ "-q") をパイプ (| と |&) の先に
#     置いた行を、ファイルと grep の行番号付きで全部出して exit 1。! で打ち消した判定・if や && の中・$(…) の中・
#     3 段以上のパイプの最後・command grep・\grep・egrep / fgrep・パターンより後ろの -q (GNU grep は並べ替えて読む) も
#     数える。行をまたいだパイプ (\ で続けた行・| で終わる行) は、grep のある行を出す
#   - 数えないもの: ファイルを直に読む grep -q・<<< で渡す grep -q・-q の無い grep (-c・-e q・-eq・-m 1 など)・
#     -- と -e の後ろの "-q" (パターン)・展開を含む引数・コメント・文字列・ヒアドキュメントの中の「| grep -q」。
#     数えないものだけなら、見た本数を出して exit 0
#   - 引数のディレクトリは直下の *.sh だけを見る (中のディレクトリと *.sh でないファイルは見ない)。引数を省けば、
#     script の隣の nix/tests を見る。ファイルとディレクトリを並べれば、全部の見つけたものを出す
#   - shfmt が読めないファイルがあれば、名前を出して exit 2。無いパス・*.sh の無いディレクトリ・知らない引数も
#     exit 2。--help は使い方を出して exit 0
#   - shfmt か jq が PATH に無ければ、nix/ の devShell に入り直して (nix develop <nix> --command) 同じ引数で
#     流し直す。入り直しても無ければ (印の環境変数がある)、入り直さずに exit 2
#   - このテストのファイル自身 (文字列の中に「| grep -q」を多く持つ) は通る
#   - script に実行ビットがある (CI の lint ジョブが ./nix/scripts/check-test-grep-q.sh で直に呼ぶ)

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/check-test-grep-q.sh}
self="${here}/$(basename "$0")"
work=$(mktemp -d "${TMPDIR:-/tmp}/check-test-grep-q-test.XXXXXX")
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

# $1: ケースの名前。<work>/<ケース> を作って出す
new_case() {
  mkdir -p "${work}/$1"
  echo "${work}/$1"
}

# $1: ケースの dir、$2: 流す script、残り: script の引数。<ケース>/out・err・rc に残す
run_with() {
  local c=$1 s=$2
  shift 2
  "${BASH}" "${s}" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}
# $1: ケースの dir、残り: script の引数
run() {
  local c=$1
  shift
  run_with "${c}" "${script}" "$@"
}
rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }
# 判定の grep -q にはファイルを直に読ませる (このテストが確かめている形そのもの)
seen_out() {
  local c=$1
  shift
  grep -q "$@" "${c}/out"
}
seen_err() {
  local c=$1
  shift
  grep -q "$@" "${c}/err"
}

# $1: fixture のファイル。行末に「# 出す」と書いた行の番号を、1 行に 1 つずつ出す
want_lines() { grep -n '# 出す$' "$1" | cut -d: -f1; }
# $1: ケースの dir、$2: fixture のファイル。script が出した「<ファイル>:<行>:」の行番号を、1 行に 1 つずつ出す
got_lines() { sed -n "s|^ *$2:\([0-9][0-9]*\): .*|\1|p" "$1/err"; }

echo "== check-test-grep-q.sh: ${script}"

# 1. パイプの先の grep -q は、形を問わず全部数える。行をまたいだパイプは grep のある行を出す
c=$(new_case t1)
cat >"${c}/bad.test.sh" <<'EOF'
#!/usr/bin/env bash
set -u -o pipefail
d=$1
outerr() { cat "$1/out" "$1/err"; }
if outerr "${d}" | grep -q '飛ばします'; then :; fi # 出す
if [[ -n ${d} ]] && ! outerr "${d}" | grep -qF '⚠'; then :; fi # 出す
outerr "${d}" | grep -Fxq 'x' # 出す
outerr "${d}" |& grep --quiet x # 出す
outerr "${d}" | grep --silent x # 出す
outerr "${d}" | grep "-q" x # 出す
outerr "${d}" | grep x -q # 出す
outerr "${d}" | grep -qe x # 出す
outerr "${d}" | grep -e x -q # 出す
x=$(outerr "${d}" | grep -q x && echo y) # 出す
outerr "${d}" | tail -n 1 | grep -q x # 出す
outerr "${d}" | command grep -q x # 出す
outerr "${d}" | \grep -q x # 出す
outerr "${d}" | egrep -q 'x|y' # 出す
outerr "${d}" | fgrep -q x # 出す
outerr "${d}" \
  | grep -q x # 出す
outerr "${d}" |
  grep -q x # 出す
EOF
run "${c}" "${c}/bad.test.sh"
want=$(want_lines "${c}/bad.test.sh")
got=$(got_lines "${c}" "${c}/bad.test.sh")
if [[ $(rc "${c}") == 1 && -n ${want} && ${got} == "${want}" ]]; then
  ok "パイプの先の grep -q は形を問わず全部出して exit 1 (行をまたげば grep の行)"
else
  ng "パイプの先の grep -q" "rc=$(rc "${c}")"$'\n'"$(diff <(echo "${want}") <(echo "${got}"))"$'\n'"$(err "${c}")"
fi
cont=$(grep -n '^  | grep -q x # 出す$' "${c}/bad.test.sh" | cut -d: -f1)
if seen_err "${c}" -xF "   ${c}/bad.test.sh:5: if outerr \"\${d}\" | grep -q '飛ばします'; then :; fi # 出す" \
  && seen_err "${c}" -xF "   ${c}/bad.test.sh:${cont}: | grep -q x # 出す"; then
  ok "見つけた行は「<ファイル>:<行>: <その行>」で出す (行の頭の空白は外す)"
else
  ng "見つけた行の出し方" "$(err "${c}")"
fi

# 2. 数えないものだけなら exit 0 で、見た本数を出す
c=$(new_case t2)
cat >"${c}/good.test.sh" <<'EOF'
#!/usr/bin/env bash
set -u -o pipefail
d=$1
opt=-q
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}
if seen "${d}" -F 'x' && ! seen "${d}" '⚠'; then :; fi
grep -q x "${d}/out"
grep -q x <<<"$(cat "${d}/out" "${d}/err")"
n=$(cat "${d}/out" "${d}/err" | grep -c x)
cat "${d}/out" | grep x >/dev/null
cat "${d}/out" | grep -e q
cat "${d}/out" | grep -eq
cat "${d}/out" | grep -m 1 x
cat "${d}/out" | grep -- -q
cat "${d}/out" | grep -e -q
cat "${d}/out" | grep "${opt}" x
echo "outerr \"\${d}\" | grep -q x"
echo 'outerr "${d}" | grep -q x'
# outerr "${d}" | grep -q x
: # outerr "${d}" | grep -q x
cat <<'EOS'
outerr "${d}" | grep -q x
EOS
x='| grep -q'
echo "${n} ${x}"
EOF
run "${c}" "${c}/good.test.sh"
if [[ $(rc "${c}") == 0 && ! -s ${c}/err ]] && seen_out "${c}" '1 本'; then
  ok "ファイルを直に読む・<<< で渡す・-q の無い grep・パターンの -q・コメント・文字列・ヒアドキュメントは数えない"
else
  ng "数えないもの" "rc=$(rc "${c}") out=$(out "${c}") err=$(err "${c}")"
fi

# 3. ディレクトリは直下の *.sh だけを見る。ファイルとディレクトリを並べれば、全部の見つけたものを出す
c=$(new_case t3)
mkdir -p "${c}/tests/fixtures" "${c}/other"
cp "${work}/t2/good.test.sh" "${c}/tests/good.test.sh"
cp "${work}/t1/bad.test.sh" "${c}/tests/bad.test.sh"
cp "${work}/t1/bad.test.sh" "${c}/tests/fixtures/nested.sh"
cp "${work}/t1/bad.test.sh" "${c}/tests/notes.md"
cp "${work}/t1/bad.test.sh" "${c}/other/one.sh"
run "${c}" "${c}/tests" "${c}/other/one.sh"
if [[ $(rc "${c}") == 1 ]] && seen_err "${c}" -F "${c}/tests/bad.test.sh:5:" && seen_err "${c}" -F "${c}/other/one.sh:5:" \
  && ! seen_err "${c}" -F 'nested.sh' && ! seen_err "${c}" -F 'notes.md' && ! seen_err "${c}" -F 'good.test.sh'; then
  ok "ディレクトリは直下の *.sh だけを見て、並べたファイルとディレクトリの見つけたものを全部出す"
else
  ng "ディレクトリとファイル" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 4. 引数を省けば、script の隣の nix/tests を見る。nix/ の下のファイルは nix/ から書く
c=$(new_case t4)
mkdir -p "${c}/nix/scripts" "${c}/nix/tests"
cp "${script}" "${c}/nix/scripts/check-test-grep-q.sh"
cp "${work}/t2/good.test.sh" "${c}/nix/tests/good.test.sh"
run_with "${c}" "${c}/nix/scripts/check-test-grep-q.sh"
rc_good=$(rc "${c}")
cp "${work}/t1/bad.test.sh" "${c}/nix/tests/bad.test.sh"
run_with "${c}" "${c}/nix/scripts/check-test-grep-q.sh"
if [[ ${rc_good} == 0 && $(rc "${c}") == 1 ]] && seen_err "${c}" -F '   nix/tests/bad.test.sh:5: '; then
  ok "引数を省けば、script の隣の nix/tests を見る (nix/ の下のファイルは nix/ から書く)"
else
  ng "引数を省く" "good だけのとき rc=${rc_good} / rc=$(rc "${c}") err=$(err "${c}")"
fi

# 5. shfmt が読めないファイル・無いパス・*.sh の無いディレクトリ・知らない引数は exit 2。--help は exit 0
c=$(new_case t5)
mkdir -p "${c}/empty"
printf '%s\n' '#!/usr/bin/env bash' 'if true; then' '  echo "閉じていない"' >"${c}/broken.test.sh"
run "${c}" "${c}/broken.test.sh"
rc_broken=$(rc "${c}")
broken_named=0
if seen_err "${c}" -F "${c}/broken.test.sh"; then
  broken_named=1
fi
run "${c}" "${c}/no-such.test.sh"
rc_missing=$(rc "${c}")
run "${c}" "${c}/empty"
rc_empty=$(rc "${c}")
run "${c}" --no-such-option
rc_opt=$(rc "${c}")
run "${c}" --help
if [[ ${rc_broken} == 2 && ${broken_named} == 1 && ${rc_missing} == 2 && ${rc_empty} == 2 ]] \
  && [[ ${rc_opt} == 2 && $(rc "${c}") == 0 ]] && seen_out "${c}" '使い方'; then
  ok "読めないファイル・無いパス・*.sh の無いディレクトリ・知らない引数は exit 2、--help は使い方を出して exit 0"
else
  ng "exit 2 と --help" "読めない rc=${rc_broken} (名前を出したか ${broken_named}) / 無いパス rc=${rc_missing} / 空のディレクトリ rc=${rc_empty} / 知らない引数 rc=${rc_opt} / --help rc=$(rc "${c}") out=$(out "${c}")"
fi

# 6. shfmt か jq が無ければ、nix/ の devShell に入り直して同じ引数で流し直す。入り直しても無ければ exit 2
c=$(new_case t6)
mkdir -p "${c}/nix/scripts" "${c}/bin"
cp "${script}" "${c}/nix/scripts/check-test-grep-q.sh"
for cmd in dirname cat; do
  ln -s "$(command -v "${cmd}")" "${c}/bin/${cmd}"
done
# 偽の nix。引数を 1 行に 1 つずつ書き留めて終わる
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$@" >"${NIX_CALLS}"
EOF
} >"${c}/bin/nix"
chmod +x "${c}/bin/nix"
NIX_CALLS="${c}/nix-calls" PATH="${c}/bin" "${BASH}" "${c}/nix/scripts/check-test-grep-q.sh" a.test.sh b >"${c}/out" 2>"${c}/err"
echo $? >"${c}/rc"
want_calls=$(printf '%s\n' develop "$(cd "${c}/nix" && pwd -P)" --command "${c}/nix/scripts/check-test-grep-q.sh" a.test.sh b)
if [[ $(rc "${c}") == 0 && $(cat "${c}/nix-calls" 2>/dev/null) == "${want_calls}" ]]; then
  ok "shfmt か jq が無ければ、nix develop <nix> --command で同じ引数のまま入り直す"
else
  ng "devShell に入り直す" "rc=$(rc "${c}") calls=$(cat "${c}/nix-calls" 2>/dev/null) err=$(err "${c}")"
fi
rm -f "${c}/nix-calls"
CHECK_TEST_GREP_Q_REEXEC=1 NIX_CALLS="${c}/nix-calls" PATH="${c}/bin" "${BASH}" "${c}/nix/scripts/check-test-grep-q.sh" a.test.sh \
  >"${c}/out" 2>"${c}/err"
echo $? >"${c}/rc"
if [[ $(rc "${c}") == 2 && ! -e ${c}/nix-calls ]] && seen_err "${c}" 'shfmt'; then
  ok "入り直しても shfmt か jq が無ければ、入り直さずに exit 2"
else
  ng "入り直しても無い" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 7. このテストのファイル自身は通る (文字列とヒアドキュメントに「| grep -q」を多く持つ)
c=$(new_case t7)
run "${c}" "${self}"
if [[ $(rc "${c}") == 0 ]]; then
  ok "このテストのファイル自身 (文字列の中に「| grep -q」を持つ) は通る"
else
  ng "このテストのファイル自身" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 8. 実行ビット
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある"
else
  ng "script に実行ビットが無い (CI の lint ジョブが直に呼べない)" "${script}"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
