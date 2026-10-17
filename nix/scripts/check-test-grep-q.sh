#!/usr/bin/env bash
# shellcheck shell=bash
#
# テストの判定で、grep -q をパイプの先に置いていないかを確かめる。
#
#   check-test-grep-q.sh [<ファイルかディレクトリ>…]
#
# `outerr "$d" | grep -q …` のように grep -q (--quiet / --silent) をパイプの先に置くと、grep は合った時点で
# 抜けるので、前のコマンドがまだ書いている途中なら SIGPIPE (141) で終わる。テストは pipefail なので、合って
# いるのに「合わない」に見える (cat out err の err を書く前に grep が抜け、混んだ CI でたまに落ちた。TKT-110・
# TKT-155)。当たるのは前のコマンドが 2 回以上書くとき (out で合って err にも出力がある、など) だけで、1 回
# 流すだけではまず通るので、形で止める。grep には読むファイルを直に渡すか (nix/tests の seen / called)、
# 出力を `grep -q … <<<"$(…)"` で渡す。値を取るだけの `$(… | head -n 1)` などは、終了コードを見ないので数えない。
#
# 見るのは、引数のファイルと、引数のディレクトリの直下の *.sh。引数を省けば、この script の隣の nix/tests を
# 見る。shfmt で構文木にしてから探すので、コメント・文字列・ヒアドキュメントの中の「| grep -q」は数えず、
# 行をまたいだパイプも見つける。見つけたら「<ファイル>:<grep の行>: <その行>」を全部出して exit 1。構文木に
# できない (shfmt か jq が読めない) ファイル・無いパス・*.sh の無いディレクトリがあれば exit 2。
#
# 見るのはパイプの右に直に置いた grep (egrep / fgrep・command grep・\grep も) だけで、次の形は見えない:
# `| { grep -q …; }`・`| (grep -q …)`・`| env grep -q`・`| timeout 5 grep -q` のように包んだもの、grep -q を
# 中で呼ぶ関数へのパイプ、省いた長いオプション (--qu など)。今の nix/tests にこれらの形は無い。
#
# CI の lint ジョブが流す。shfmt か jq が PATH に無ければ、nix/ の devShell に入り直す (入り直しの
# nix develop 自体が落ちたときは、nix の終了コード (多くは 1) のまま終わる。CI は devShell の中から直に呼ぶ)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
テストの判定で、grep -q をパイプの先に置いていないかを確かめる。

使い方:
  check-test-grep-q.sh [<ファイルかディレクトリ>…]   確かめる (省けば、この script の隣の nix/tests)
  check-test-grep-q.sh -h, --help                     これ
EOS
}

targets=()
for arg in "$@"; do
  case ${arg} in
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
    *) targets+=("${arg}") ;;
  esac
done

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
nix_dir=$(dirname "${script_dir}")

have() { command -v "$1" &>/dev/null; }

if ! have shfmt || ! have jq; then
  if [[ -z ${CHECK_TEST_GREP_Q_REEXEC:-} ]] && have nix; then
    export CHECK_TEST_GREP_Q_REEXEC=1
    exec nix develop "${nix_dir}" --command "$0" "$@"
  fi
  echo "!! shfmt と jq が要ります。nix があれば nix/ の devShell へ自動で入り直します。" >&2
  exit 2
fi

if ((${#targets[@]} == 0)); then
  targets=("${nix_dir}/tests")
fi
files=()
for t in "${targets[@]}"; do
  if [[ -d ${t} ]]; then
    any=0
    for f in "${t}"/*.sh; do
      if [[ -f ${f} ]]; then
        files+=("${f}")
        any=1
      fi
    done
    if ((any == 0)); then
      echo "!! *.sh がありません: ${t}" >&2
      exit 2
    fi
  elif [[ -f ${t} ]]; then
    files+=("${t}")
  else
    echo "!! 見つかりません: ${t}" >&2
    exit 2
  fi
done

# shfmt の構文木 (JSON) から、パイプの先に置いた grep -q の行番号を 1 行に 1 つずつ出す
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
jq_find='
# 語が展開を含まなければ、その文字列 (引用符は外す)。含めば null
def lit:
  if all(.Parts[]; .Type == "Lit" or .Type == "SglQuoted"
    or (.Type == "DblQuoted" and all(.Parts[]?; .Type == "Lit")))
  then [.Parts[] | if .Type == "DblQuoted" then ([.Parts[]?.Value] | add // "") else .Value end] | add
  else null end;

# grep の引数 (コマンドの名前より後ろ) に -q (--quiet / --silent) があるか。GNU grep と同じく、パターンより
# 後ろのオプションも読み、-- より後ろは読まない。値を取るオプション (-e・-m など) の値は飛ばす
def quiet:
  reduce .[] as $a ({next: "opt", q: false};
    if .next == "rest" then .
    elif .next == "value" then .next = "opt"
    elif $a == null then .
    elif $a == "--" then .next = "rest"
    elif $a == "--quiet" or $a == "--silent" then .q = true
    elif ($a | test("^--(regexp|file|max-count|after-context|before-context|context|label|binary-files|devices|directories|include|exclude|exclude-from|exclude-dir|group-separator)$"))
    then .next = "value"
    elif ($a | test("^-[^-]")) then
      ($a[1:] | capture("^(?<opts>[^efmABCdD]*)(?<takes>[efmABCdD]?)(?<value>.*)$")) as $m
      | (if ($m.opts | contains("q")) then .q = true else . end)
      | (if $m.takes != "" and $m.value == "" then .next = "value" else . end)
    else . end)
  | .q;

[ ..
  | objects
  | select(.Type? == "BinaryCmd" and (.Op == "|" or .Op == "|&"))
  | .Y
  | select(.Cmd.Type? == "CallExpr")
  | [.Cmd.Args[]? | lit] as $w
  | (if $w[0] == "command" then $w[1:] else $w end) as $w
  | select(($w[0] // "") | ltrimstr("\\") | test("^(.*/)?[ef]?grep$"))
  | select($w[1:] | quiet)
  | .Pos.Line
] | unique | .[]
'

found=()
broken=()
for f in "${files[@]}"; do
  # nix/ の下のファイルは nix/ から書く (CI の出力を短くする)
  name=${f}
  if [[ ${f} == "${nix_dir}/"* ]]; then
    name="$(basename "${nix_dir}")/${f#"${nix_dir}/"}"
  fi
  if ! json=$(shfmt -ln bash --to-json <"${f}" 2>/dev/null); then
    broken+=("${name}: $(shfmt -ln bash --to-json <"${f}" 2>&1 >/dev/null || true)")
    continue
  fi
  # jq が落ちたら、見つからなかったことにせず止める
  if ! lines=$(jq -r "${jq_find}" <<<"${json}"); then
    broken+=("${name}: jq が構文木を読めませんでした")
    continue
  fi
  while IFS= read -r n; do
    [[ -n ${n} ]] || continue
    line=$(sed -n "${n}p" "${f}")
    line=${line#"${line%%[![:space:]]*}"}
    found+=("${name}:${n}: ${line}")
  done <<<"${lines}"
done

if ((${#broken[@]} > 0)); then
  echo "!! 構文木にできないファイルがあります (確かめられません):" >&2
  printf '   %s\n' "${broken[@]}" >&2
fi
if ((${#found[@]} > 0)); then
  echo "!! テストの判定で grep -q をパイプの先に置いています:" >&2
  printf '   %s\n' "${found[@]}" >&2
  echo "   grep は合った時点で抜けるので、前のコマンドが書き終える前なら SIGPIPE (141) で終わり、pipefail の下では" >&2
  echo "   合っているのに「合わない」に見えます (TKT-155)。grep には読むファイルを直に渡すか (nix/tests の seen / called)、" >&2
  echo "   出力を grep -q … <<<\"\$(…)\" で渡してください。" >&2
fi
if ((${#broken[@]} > 0)); then
  exit 2
fi
if ((${#found[@]} > 0)); then
  exit 1
fi
echo "テストの判定の grep -q: ${#files[@]} 本ともパイプで受けていない"
