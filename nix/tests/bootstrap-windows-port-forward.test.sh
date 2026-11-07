#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-port-forward.sh の振る舞いを、使い捨ての HOME・Windows のホーム・dotfiles-private と、
# 偽の nix-instantiate で確かめる。
#
#   bash nix/tests/bootstrap-windows-port-forward.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-port-forward-test) が Nix のサンドボックスで流す。
# 使うのは bash・jq・coreutils・diffutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン (windows-files.json が無い・enable が false) と、正本 (dotfiles-private の ssh/port-forward.toml) が
#     無いときは、何も書かずに exit 0。windows-files.json が無い警告は、setup のまとめ用のファイルにも続きの行ごと残す
#   - 初回は hosts.json (version・note・hosts。日本語のメモはそのまま、組の前後の空白は落とす) と記録を書く。2 回目は 1 行で済ませる
#   - 正本の更新 (置き先が記録どおり) は上書きする。Windows で直したものと、置く前からあったものは衝突 (exit 1・触らない・
#     diff と解き方。1 行目は記録の有無で分ける)。記録が無く中身が同じなら記録だけ。--force は退避して上書き、--dry-run は何も書かない
#   - 正本の誤り (hosts の外のキー・hosts が無い / 表でない・値が配列でない (. の Host 名を囲み忘れた入れ子の表を含む)・
#     文字列でない要素・書き方の誤り・port の範囲・同じ手元の port・Host 名の空白・ワイルドカード・- の頭) は、
#     何も書かずに全部を並べて exit 1。全角の数字も書き方の誤りにする (jq の \d は Unicode の数字に合い、確かめの jq が
#     落ちても先へ進んでいた)。TOML として読めないときも exit 1
#   - --check は Windows の側も記録も見ずに正本だけを確かめる (OK なら Host と組の数、正本が無い・誤りは exit 1)
#   - 壊れた記録は exit 1。知らない引数と、--check とほかの組み合わせは exit 2。script に実行ビットがある
#
# ## 本物の nix-instantiate を見せない
#
# script は正本を nix-instantiate の builtins.fromTOML で JSON にするが、サンドボックスには nix-instantiate が無い。
# --argstr file <パス> を受けて <パス>.json (ケースごとに置く、fromTOML が返すはずの JSON) を出す偽物を、要るコマンドだけを
# symlink で並べた PATH に置く。<パス>.err があれば、その中身を stderr に出して 1 で終わる (TOML として読めないとき)。
# 偽物の shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。本物の nix-instantiate で読めることは、
# dotfiles-private のファイルに --check を流して確かめる (win/README.md の「port forwarding (pf)」)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-port-forward.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-port-forward-test.XXXXXX")
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

# 要るコマンドだけを並べた PATH (nix-instantiate・ghq は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed cat cut sha256sum mkdir mktemp mv rm cp dirname date diff; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'
# 正本を fromTOML で読んだはずの JSON (架空の Host と port)
toml_ok='{"hosts":{"example-a":["3000","8080 api"],"example-b":[" 15432:db:5432  ポスグレ "]}}'

# 1 ケースぶんの環境を作る。$1: 名前、$2: windows-files.json の中身 (空なら作らない。@WIN@ は配り先)、
# $3: 正本を読んだ JSON (空なら正本を置かない)
#   <case>/home     HOME
#   <case>/win      Windows のホームに見立てる
#   <case>/private  dotfiles-private (ssh/port-forward.toml と、偽の nix-instantiate が出す .json)
#   <case>/bin      偽の nix-instantiate
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/home/.local/state/dotfiles" "${c}/win" "${c}/private/ssh" "${c}/bin"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${c}/win}" >"${c}/home/.local/state/dotfiles/windows-files.json"
  fi
  if [[ -n ${3-} ]]; then
    set_toml "${c}" "$3"
  fi
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
file=""
while (($# > 0)); do
  if [[ $1 == --argstr && ${2-} == file ]]; then
    file=${3-}
    shift 3
  else
    shift
  fi
done
if [[ -z ${file} ]]; then
  echo "偽の nix-instantiate: --argstr file がありません" >&2
  exit 3
fi
if [[ -e ${file}.err ]]; then
  cat "${file}.err" >&2
  exit 1
fi
if [[ ! -e ${file}.json ]]; then
  echo "偽の nix-instantiate: ${file}.json がありません" >&2
  exit 3
fi
cat "${file}.json"
EOF
  } >"${c}/bin/nix-instantiate"
  chmod +x "${c}/bin/nix-instantiate"
  echo "${c}"
}

# 正本を置き直す。$1: ケース、$2: fromTOML が返すはずの JSON
set_toml() {
  printf '# toml\n' >"$1/private/ssh/port-forward.toml"
  printf '%s\n' "$2" >"$1/private/ssh/port-forward.toml.json"
}

# $1: ケース、残り: script の引数。DOTFILES_SETUP_WARNINGS は呼び出し側で付ける
run() {
  local c=$1
  shift
  env HOME="${c}/home" PATH="${c}/bin:${sys_bin}" DOTFILES_PRIVATE_DIR="${c}/private" \
    "${BASH}" "${script}" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
# 判定の grep -q はパイプで受けず、ファイルを直に読む (check-test-grep-q.sh が CI の lint で落とす)
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}
dst() { printf '%s' "$1/win/.config/port-forward/hosts.json"; }
record() { cat "$1/home/.local/state/dotfiles/windows-port-forward.deployed.json" 2>/dev/null; }
sha_of() { sha256sum <"$1" | cut -d' ' -f1; }
baks() { find "$1/win/.config/port-forward" -name 'hosts.json.dotfiles-bak-*' 2>/dev/null | wc -l; }

echo "== bootstrap-windows-port-forward.sh: ${script}"

# --- 実行ビット -------------------------------------------------------------
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある"
else
  ng "script に実行ビットがある"
fi

# --- 配らないマシン -----------------------------------------------------------
c=$(new_case nostate "" "${toml_ok}")
warnings="${c}/warnings"
: >"${warnings}"
DOTFILES_SETUP_WARNINGS="${warnings}" run "${c}"
if [[ $(rc "${c}") == 0 ]] && seen "${c}" '配り先の設定がありません' && [[ ! -e $(dst "${c}") ]] \
  && grep -q '配り先の設定がありません' "${warnings}" && grep -q 'この手順は飛ばします' "${warnings}"; then
  ok "windows-files.json が無ければ警告して exit 0 (まとめ用のファイルにも続きの行ごと残す)"
else
  ng "windows-files.json が無ければ警告して exit 0" "$(
    outerr "${c}"
    cat "${warnings}"
  )"
fi

c=$(new_case off "${state_off}" "${toml_ok}")
run "${c}"
if [[ $(rc "${c}") == 0 ]] && seen "${c}" 'Windows 側へ配りません' && [[ ! -e $(dst "${c}") ]]; then
  ok "enable が false なら何もしない"
else
  ng "enable が false なら何もしない" "$(outerr "${c}")"
fi

# --- 正本が無い ---------------------------------------------------------------
c=$(new_case nosrc "${state_on}")
run "${c}"
if [[ $(rc "${c}") == 0 ]] && seen "${c}" '正本がない' && [[ ! -e $(dst "${c}") ]] && [[ -z $(record "${c}") ]]; then
  ok "正本 (ssh/port-forward.toml) が無ければ何も書かずに exit 0"
else
  ng "正本が無ければ何も書かずに exit 0" "$(outerr "${c}")"
fi

c=$(new_case noprivate "${state_on}")
rm -rf "${c}/private"
mkdir -p "${c}/win/.config/port-forward"
printf 'old\n' >"$(dst "${c}")"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && seen "${c}" '正本がない' && [[ $(cat "$(dst "${c}")") == old ]]; then
  ok "dotfiles-private が無くても exit 0 で、置いてある hosts.json は消さない"
else
  ng "dotfiles-private が無くても exit 0" "$(outerr "${c}")"
fi

# --- 初回・2 回目 ---------------------------------------------------------------
c=$(new_case first "${state_on}" "${toml_ok}")
run "${c}"
d=$(dst "${c}")
if [[ $(rc "${c}") == 0 ]] && seen "${c}" '新しく置く' && [[ -f ${d} ]] \
  && [[ $(jq -r '.version' "${d}") == 1 ]] \
  && [[ $(jq -r '.note' "${d}") == *bootstrap-windows-port-forward.sh* ]] \
  && [[ $(jq -c '.hosts' "${d}") == '{"example-a":["3000","8080 api"],"example-b":["15432:db:5432  ポスグレ"]}' ]] \
  && grep -q 'ポスグレ' "${d}" \
  && [[ $(record "${c}" | jq -r '.files["hosts.json"]') == "$(sha_of "${d}")" ]] \
  && [[ $(record "${c}" | jq -r '.version') == 1 ]]; then
  ok "初回は hosts.json (日本語のメモはそのまま・前後の空白を落とす) と記録を書く"
else
  ng "初回は hosts.json と記録を書く" "$(
    outerr "${c}"
    cat "${d}" 2>/dev/null
    record "${c}"
  )"
fi
if [[ $(jq --indent 2 . "${d}") == "$(cat "${d}")" ]]; then
  ok "hosts.json は jq --indent 2 の形"
else
  ng "hosts.json は jq --indent 2 の形" "$(cat "${d}")"
fi

run "${c}"
if [[ $(rc "${c}") == 0 ]] && seen "${c}" '揃っています' && [[ $(wc -l <"${c}/out") == 1 ]]; then
  ok "2 回目は揃っていると 1 行で済ませる"
else
  ng "2 回目は揃っていると 1 行で済ませる" "$(outerr "${c}")"
fi

# --- 正本の更新 -----------------------------------------------------------------
set_toml "${c}" '{"hosts":{"example-a":["3000","8080 api","9000"]}}'
run "${c}"
if [[ $(rc "${c}") == 0 ]] && seen "${c}" '上書き (正本が更新された)' \
  && [[ $(jq -c '.hosts' "${d}") == '{"example-a":["3000","8080 api","9000"]}' ]] \
  && [[ $(record "${c}" | jq -r '.files["hosts.json"]') == "$(sha_of "${d}")" ]]; then
  ok "置き先が記録どおりなら、正本の更新として上書きする"
else
  ng "置き先が記録どおりなら上書きする" "$(outerr "${c}")"
fi

# --- 衝突 -----------------------------------------------------------------------
printf '{"hosts":{"example-a":["1"]}}\n' >"${d}"
before=$(cat "${d}")
run "${c}"
if [[ $(rc "${c}") == 1 ]] && seen "${c}" 'Windows 側で変わっています' && seen "${c}" -e '--force' \
  && seen "${c}" 'port-forward.toml へ取り込み' && seen "${c}" -F -- '--- hosts.json (Windows 側)' \
  && [[ $(cat "${d}") == "${before}" ]]; then
  ok "Windows で直した hosts.json は衝突 (exit 1・触らない・diff と解き方)"
else
  ng "Windows で直した hosts.json は衝突" "$(outerr "${c}")"
fi

run "${c}" --force
if [[ $(rc "${c}") == 0 ]] && seen "${c}" '上書き (--force)' && [[ $(baks "${c}") == 1 ]] \
  && [[ $(jq -c '.hosts' "${d}") == '{"example-a":["3000","8080 api","9000"]}' ]] \
  && [[ $(cat "$(find "${c}/win/.config/port-forward" -name 'hosts.json.dotfiles-bak-*')") == "${before}" ]]; then
  ok "--force は元を hosts.json.dotfiles-bak-<日時> に退避して上書きする"
else
  ng "--force は退避して上書きする" "$(outerr "${c}")"
fi

c=$(new_case handmade "${state_on}" "${toml_ok}")
mkdir -p "${c}/win/.config/port-forward"
printf '{"hosts":{}}\n' >"$(dst "${c}")"
run "${c}"
if [[ $(rc "${c}") == 1 ]] && seen "${c}" '置いた記録が無く' && ! seen "${c}" 'Windows 側で変わっています' \
  && [[ $(cat "$(dst "${c}")") == '{"hosts":{}}' ]] && [[ -z $(record "${c}") ]]; then
  ok "記録が無く中身の違う hosts.json は、置いた記録が無いと出して衝突"
else
  ng "記録が無く中身の違う hosts.json は衝突" "$(outerr "${c}")"
fi

c=$(new_case same "${state_on}" "${toml_ok}")
mkdir -p "${c}/win/.config/port-forward"
cp "$(dst "${work}/first")" "$(dst "${c}")"
set_toml "${c}" '{"hosts":{"example-a":["3000","8080 api","9000"]}}'
run "${c}"
if [[ $(rc "${c}") == 0 ]] && seen "${c}" '揃っています' \
  && [[ $(record "${c}" | jq -r '.files["hosts.json"]') == "$(sha_of "$(dst "${c}")")" ]]; then
  ok "記録が無くても中身が同じなら、記録だけする"
else
  ng "記録が無くても中身が同じなら記録だけ" "$(outerr "${c}")"
fi

# --- --dry-run --------------------------------------------------------------------
c=$(new_case dry "${state_on}" "${toml_ok}")
run "${c}" --dry-run
if [[ $(rc "${c}") == 0 ]] && seen "${c}" '\[dry-run\]' && [[ ! -e $(dst "${c}") ]] && [[ -z $(record "${c}") ]]; then
  ok "--dry-run は hosts.json も記録も書かない"
else
  ng "--dry-run は何も書かない" "$(outerr "${c}")"
fi

# --- 正本の誤り -------------------------------------------------------------------
bad='{"other":1,"hosts":{"bad host":["3000"],"web-*":["1"],"-x":["1"],"example":{"test":["1"]},"n":"3000",
"example-c":[3000,"0","65536","3000:","x","1:db:2 ok","1","2:[::1]:3"]}}'
c=$(new_case bad "${state_on}" "${bad}")
run "${c}"
errs=(
  '知らないキーがあります: other'
  'Host 名に空白・\* ? ! は使えません: bad host'
  'Host 名に空白・\* ? ! は使えません: web-\*'
  'Host 名は - で始められません: -x'
  'example: 値が配列ではありません'
  'n: 値は文字列の配列にする'
  'example-c: 1 番目が文字列ではありません: 3000'
  'example-c: port は 1〜65535 で書いてください: 0'
  'example-c: port は 1〜65535 で書いてください: 65536'
  'example-c: 書き方が違います: 3000:'
  'example-c: 書き方が違います: x'
  'example-c: 手元の port が重なっています: 1'
)
missing=()
for e in "${errs[@]}"; do
  if ! seen "${c}" -e "${e}"; then
    missing+=("${e}")
  fi
done
if [[ $(rc "${c}") == 1 ]] && ((${#missing[@]} == 0)) && seen "${c}" '"…" で囲む' && ! seen "${c}" '2:\[::1\]:3' \
  && [[ ! -e $(dst "${c}") ]] && [[ -z $(record "${c}") ]]; then
  ok "正本の誤りは何も書かずに全部を並べて exit 1 (. の Host 名は囲むよう出す)"
else
  ng "正本の誤りは全部を並べて exit 1" "足りない: ${missing[*]-}"$'\n'"$(outerr "${c}")"
fi

for t in '{}|\[hosts\] の表がありません' '{"hosts":["x"]}|hosts は表にする' '[1]|最上位が表ではありません'; do
  json=${t%%|*}
  msg=${t#*|}
  c=$(new_case "shape-${json//[^a-z0-9]/_}" "${state_on}" "${json}")
  run "${c}"
  if [[ $(rc "${c}") == 1 ]] && seen "${c}" -e "${msg}" && [[ ! -e $(dst "${c}") ]]; then
    ok "正本の形の誤り: ${json} → ${msg//\\/}"
  else
    ng "正本の形の誤り: ${json}" "$(outerr "${c}")"
  fi
done

c=$(new_case fullwidth "${state_on}" '{"hosts":{"example-a":["３０００","3000:db:５４３２"]}}')
run "${c}"
fw_run=$(rc "${c}")
fw_out=$(outerr "${c}")
run "${c}" --check
if [[ ${fw_run} == 1 ]] && [[ ${fw_out} == *'書き方が違います: ３０００'* ]] && [[ ${fw_out} == *'書き方が違います: 3000:db:５４３２'* ]] \
  && [[ ! -e $(dst "${c}") ]] && [[ -z $(record "${c}") ]] && [[ $(rc "${c}") == 1 ]]; then
  ok "全角の数字は書き方の誤り (何も書かずに exit 1。--check も exit 1)"
else
  ng "全角の数字は書き方の誤り" "${fw_run} ${fw_out}"$'\n'"$(outerr "${c}")"
fi

c=$(new_case parse "${state_on}" "${toml_ok}")
printf 'error: while parsing TOML: bad format\n' >"${c}/private/ssh/port-forward.toml.err"
run "${c}"
if [[ $(rc "${c}") == 1 ]] && seen "${c}" 'TOML として読めませんでした' && seen "${c}" 'while parsing TOML' && [[ ! -e $(dst "${c}") ]]; then
  ok "TOML として読めなければ exit 1 (nix-instantiate の理由も出す)"
else
  ng "TOML として読めなければ exit 1" "$(outerr "${c}")"
fi

# --- --check ------------------------------------------------------------------------
c=$(new_case check "" "${toml_ok}")
run "${c}" --check
if [[ $(rc "${c}") == 0 ]] && seen "${c}" -F 'ssh/port-forward.toml: OK (Host 2 件・組 3 件)' && [[ ! -e $(dst "${c}") ]]; then
  ok "--check は windows-files.json が無くても正本を確かめる (Host と組の数)"
else
  ng "--check は正本を確かめる" "$(outerr "${c}")"
fi
set_toml "${c}" "${bad}"
run "${c}" --check
if [[ $(rc "${c}") == 1 ]] && seen "${c}" '知らないキーがあります: other'; then
  ok "--check は正本の誤りで exit 1"
else
  ng "--check は正本の誤りで exit 1" "$(outerr "${c}")"
fi
c=$(new_case checknosrc "")
run "${c}" --check
if [[ $(rc "${c}") == 1 ]] && seen "${c}" '正本がありません'; then
  ok "--check は正本が無ければ exit 1"
else
  ng "--check は正本が無ければ exit 1" "$(outerr "${c}")"
fi

# --- 壊れた記録・引数 ------------------------------------------------------------------
c=$(new_case badrecord "${state_on}" "${toml_ok}")
printf 'not json\n' >"${c}/home/.local/state/dotfiles/windows-port-forward.deployed.json"
run "${c}"
if [[ $(rc "${c}") == 1 ]] && seen "${c}" '壊れています' && [[ ! -e $(dst "${c}") ]]; then
  ok "壊れた記録は exit 1"
else
  ng "壊れた記録は exit 1" "$(outerr "${c}")"
fi

c=$(new_case args "${state_on}" "${toml_ok}")
codes=""
for a in --bogus '--check --force' '--check --dry-run'; do
  # shellcheck disable=SC2086 # 引数の組を空白で分ける
  run "${c}" ${a}
  codes+="$(rc "${c}") "
done
if [[ ${codes} == '2 2 2 ' ]]; then
  ok "知らない引数と、--check とほかの組み合わせは exit 2"
else
  ng "知らない引数と組み合わせは exit 2" "${codes}"
fi

echo "== ${pass} passed, ${fail} failed"
((fail == 0))
