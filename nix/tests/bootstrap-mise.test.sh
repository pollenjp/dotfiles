#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-mise.sh が mise の遅延 (minimum_release_age) と claude を入れるときの遅延を、状態ファイル
# (~/.local/state/dotfiles/mise-release-age.json) と今の時刻から決めて書くことを、使い捨ての HOME と偽の mise で確かめる。
#
#   bash nix/tests/bootstrap-mise.test.sh [<bootstrap-mise.sh のパス>]
#
# flake の checks (bootstrap-mise-test) が Nix のサンドボックスで流す。使うのは bash・jq・coreutils だけ。
#
# ## 確かめること
#
#   - 上書きが無ければ minimum_release_age に minimumReleaseAge (9d・14d) を書き、claude は 1d で入れる
#     (既定が 0d なら claude も 0d)。上書きの行も警告も出さない
#   - 上書き中 (from の日 ≤ 今日 ≤ 上限の日 + 既定の日数) は、上限 (from + zeroDays − 1 の日の 23:59:59+09:00) を書き、
#     「上書き中」の 1 行に理由・上限の日・終わる日・mise up の案内を出す。claude は今日 ≤ 上限の日 + 1 のあいだ上限、
#     その後は 1d。上書き中の最後の日は警告しない
#   - 日付は Asia/Tokyo で読む (UTC の 10/21 15:30 は JST の 10/22 00:30 で、from = 10/22 の上書きが始まっている)
#   - from が今日より先の項目は写さず、「まだ始まっていない」の行を出す (警告にしない)
#   - 終わった項目 (今日 > 上限の日 + 既定の日数) は写さず、from・zeroDays・理由・終わった日と消す場所を警告する。
#     setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、まとめ用のファイルにも同じ行を残す
#   - 上書き中が複数なら、上限がいちばん新しい項目を書く。終わった項目は、上書き中の項目と並んでも (それだけを) 警告する
#   - 状態ファイルが無い・形が違う (暦に無い from・日の単位でない minimumReleaseAge)・jq が無いときは、警告して 9d を
#     書き、claude は 1d で入れる。exit 0 (setup を止めない)
#   - どのケースでも、ほかの settings (lockfile・fetch_remote_versions_timeout) と言語ランタイム (usage・go・node) は、
#     今までどおり遅延の env なしで打つ。minimum_release_age は 1 回だけ書く
#
# 偽の mise は、受けた env の MISE_MINIMUM_RELEASE_AGE と引数を「<env>|<引数>」の形で $HOME/mise.log に 1 行ずつ残す。
# 今の時刻は BOOTSTRAP_MISE_NOW (UNIX 秒) で渡す。偽の mise の shebang は $BASH から作る (Nix のサンドボックスには
# /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-mise.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-mise-test.XXXXXX")
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

# ISO 8601 (UTC) → UNIX 秒
at() { jq -nr --arg t "$1" '$t | fromdateiso8601'; }

# 状態ファイルの中身。$1: minimumReleaseAge、残り: 項目 (1 つずつ JSON)
state() {
  local age=$1
  shift
  jq -cn --arg age "${age}" '{minimumReleaseAge: $age, releaseAgeOverrides: ($ARGS.positional | map(fromjson))}' --args "$@"
}

# 1 ケースぶんの HOME を作る。$1: 名前、$2: 状態ファイルの中身 (空なら作らない)
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/bin" "${h}/.config/mise" "${h}/.local/state/dotfiles"
  : >"${h}/.config/mise/config.toml"
  : >"${h}/mise.log"
  if [[ -n $2 ]]; then printf '%s\n' "$2" >"${h}/.local/state/dotfiles/mise-release-age.json"; fi
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s|%s\n' "${MISE_MINIMUM_RELEASE_AGE-}" "$*" >>"${HOME}/mise.log"
if [[ $1 == config && $2 == ls ]]; then
  echo '{}'
fi
exit 0
EOF
  } >"${h}/bin/mise"
  chmod +x "${h}/bin/mise"
  echo "${h}"
}

# $1: HOME、$2: 今 (ISO 8601 の UTC)、$3: 偽の mise の後ろに続ける PATH (省けば今の PATH)。
# setup から走るときと同じく、警告のまとめ用のファイルを渡す
run() {
  local h=$1 now
  now=$(at "$2")
  env -u MISE_MINIMUM_RELEASE_AGE HOME="${h}" XDG_CONFIG_HOME="${h}/.config" PATH="${h}/bin:${3:-${PATH}}" \
    BOOTSTRAP_MISE_NOW="${now}" DOTFILES_SETUP_WARNINGS="${h}/warnings" \
    "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

# jq だけを持たない PATH。script が使うコマンドを symlink で並べる (PATH から jq のあるディレクトリを抜く形にしないのは、
# Nix の profile や GitHub の runner では jq が coreutils と同じディレクトリにあって抜けないため)
nojq_bin="${work}/nojq-bin"
mkdir -p "${nojq_bin}"
for c in cat head date; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${nojq_bin}/${c}"
done

# 偽の mise が受けた行と、出力
detail() { printf 'rc=%s\n--- mise.log\n%s\n--- out\n%s\n--- err\n%s' "$(cat "$1/rc")" "$(cat "$1/mise.log")" "$(cat "$1/out")" "$(cat "$1/err")"; }

# ほかの settings と言語ランタイムは、遅延の env なしで打つ
others_plain() {
  local line
  for line in '|settings set lockfile true' '|settings set fetch_remote_versions_timeout 14d' \
    '|use -g aqua:jdx/usage' '|use -g go' '|use -g node@24'; do
    grep -Fxq -- "${line}" "$1/mise.log" || return 1
  done
}

# minimum_release_age に $3 を 1 回だけ書き、claude を env $4 で入れ、ほかは env なしで打ち、exit 0 か。
# $1: ケースの名前、$2: HOME
expect_ages() {
  local name=$1 h=$2 setting=$3 claude=$4 n
  n=$(grep -c -- '|settings set minimum_release_age ' "${h}/mise.log")
  if [[ $(cat "${h}/rc") == 0 && ${n} == 1 ]] \
    && grep -Fxq -- "|settings set minimum_release_age ${setting}" "${h}/mise.log" \
    && grep -Fxq -- "${claude}|use -g claude@latest" "${h}/mise.log" \
    && others_plain "${h}"; then
    ok "${name}"
  else
    ng "${name}" "$(detail "${h}")"
  fi
}

# 警告が無い (stderr に「!! 」の行が無く、まとめ用のファイルも空)
no_warning() { ! grep -Fq '!! ' "$1/err" && [[ ! -s $1/warnings ]]; }

cap='2026-10-24T23:59:59+09:00'
# from 10/22 から 0d を 3 日 → 上限 10/24、既定 9d なら 11/02 の終わりで終わる
item_a='{"from":"2026-10-22","zeroDays":3,"reason":"修正版を入れる"}'

echo "== bootstrap-mise.sh: ${script}"

# 1. 上書きが無い
h=$(new_home none-9d "$(state 9d)")
run "${h}" 2026-10-22T03:00:00Z
expect_ages "上書きが無ければ minimum_release_age に 9d を書き、claude は 1d で入れる" "${h}" 9d 1d
if no_warning "${h}" && ! grep -Fq '上書き中' "${h}/out"; then
  ok "上書きが無ければ、上書きの行も警告も出さない"
else
  ng "上書きが無いときのほかの行" "$(detail "${h}")"
fi

h=$(new_home none-14d "$(state 14d)")
run "${h}" 2026-10-22T03:00:00Z
expect_ages "minimumReleaseAge = 14d なら 14d を書く (claude は 1d)" "${h}" 14d 1d

h=$(new_home none-0d "$(state 0d)")
run "${h}" 2026-10-22T03:00:00Z
expect_ages "minimumReleaseAge = 0d なら 0d を書き、claude も 0d で入れる" "${h}" 0d 0d

# 2. 上書き中 (0d の日)
h=$(new_home active-zero "$(state 9d "${item_a}")")
run "${h}" 2026-10-22T03:00:00Z
expect_ages "from の日 (JST 10/22 12:00) は上限 ${cap} を書き、claude も上限で入れる" "${h}" "${cap}" "${cap}"
line=$(grep -F '上書き中' "${h}/out")
if [[ ${line} == *修正版を入れる* && ${line} == *2026-10-24* && ${line} == *2026-11-02* && ${line} == *'mise up'* ]] \
  && no_warning "${h}"; then
  ok "上書き中は 1 行に理由・上限の日・終わる日・mise up の案内を出す"
else
  ng "上書き中の行" "$(detail "${h}")"
fi

# 3. 日付は Asia/Tokyo で読む
h=$(new_home jst-started "$(state 9d "${item_a}")")
run "${h}" 2026-10-21T15:30:00Z
expect_ages "UTC 10/21 15:30 (JST 10/22 00:30) は from の日なので上限を書く" "${h}" "${cap}" "${cap}"

h=$(new_home jst-pending "$(state 9d "${item_a}")")
run "${h}" 2026-10-21T14:30:00Z
expect_ages "UTC 10/21 14:30 (JST 10/21 23:30) はまだ始まっていないので 9d を書く" "${h}" 9d 1d
line=$(grep -F 'まだ始まっていない' "${h}/out")
if [[ ${line} == *2026-10-22* && ${line} == *修正版を入れる* ]] && no_warning "${h}" && ! grep -Fq '上書き中' "${h}/out"; then
  ok "まだ始まっていない項目は 1 行で知らせ、警告にしない"
else
  ng "まだ始まっていない項目" "$(detail "${h}")"
fi

# 4. 遅延が伸びる日々 (上限は据え置き)
h=$(new_home day-plus1 "$(state 9d "${item_a}")")
run "${h}" 2026-10-25T03:00:00Z
expect_ages "上限の翌日 (JST 10/25) は上限を書き、claude も上限 (1d より新しい版を取る)" "${h}" "${cap}" "${cap}"

h=$(new_home day-plus2 "$(state 9d "${item_a}")")
run "${h}" 2026-10-26T03:00:00Z
expect_ages "上限の 2 日後 (JST 10/26) は上限を書き、claude は 1d" "${h}" "${cap}" 1d

h=$(new_home last-day "$(state 9d "${item_a}")")
run "${h}" 2026-11-02T03:00:00Z
expect_ages "上書きの最後の日 (JST 11/02) は上限を書く" "${h}" "${cap}" 1d
if no_warning "${h}" && grep -Fq '上書き中' "${h}/out"; then
  ok "上書きの最後の日は警告しない"
else
  ng "上書きの最後の日" "$(detail "${h}")"
fi

# 5. 終わった項目
h=$(new_home ended "$(state 9d "${item_a}")")
run "${h}" 2026-11-02T15:30:00Z
expect_ages "上限 + 9d を過ぎた (JST 11/03 00:30) 項目は写さず 9d を書く" "${h}" 9d 1d
err=$(cat "${h}/err")
if [[ ${err} == *'!! '* && ${err} == *2026-10-22* && ${err} == *'zeroDays 3'* ]] \
  && [[ ${err} == *修正版を入れる* && ${err} == *2026-11-02* && ${err} == *nix/shared/* ]] \
  && grep -Fq '修正版を入れる' "${h}/warnings" && grep -Fq 'nix/shared/' "${h}/warnings" \
  && ! grep -Fq '!! ' "${h}/warnings" && ! grep -Fq '上書き中' "${h}/out"; then
  ok "終わった項目は from・zeroDays・理由・終わった日と消す場所を警告し、まとめ用のファイルにも残す"
else
  ng "終わった項目の警告" "$(detail "${h}")"$'\n--- warnings\n'"$(cat "${h}/warnings" 2>/dev/null)"
fi

# 6. 複数の項目
h=$(new_home many "$(state 9d '{"from":"2026-10-22","zeroDays":1,"reason":"あとの件"}' '{"from":"2026-10-20","zeroDays":5,"reason":"先の件"}')")
run "${h}" 2026-10-23T03:00:00Z
expect_ages "上書き中が複数なら、上限がいちばん新しい項目 (10/20 から 5 日 → 10/24) を書く" "${h}" "${cap}" "${cap}"
if grep -Fq '先の件' "${h}/out" && no_warning "${h}"; then
  ok "上書き中の行は、上限を使う項目の理由を出す"
else
  ng "複数の項目の行" "$(detail "${h}")"
fi

h=$(new_home ended-and-active "$(state 9d "${item_a}" '{"from":"2026-09-01","zeroDays":1,"reason":"前の件"}')")
run "${h}" 2026-10-23T03:00:00Z
expect_ages "終わった項目と上書き中の項目が並べば、上書き中の上限を書く" "${h}" "${cap}" "${cap}"
if grep -Fq '前の件' "${h}/warnings" && ! grep -Fq '修正版を入れる' "${h}/warnings"; then
  ok "終わった項目だけを警告する (上書き中の項目は警告しない)"
else
  ng "終わった項目だけの警告" "$(detail "${h}")"$'\n--- warnings\n'"$(cat "${h}/warnings" 2>/dev/null)"
fi

# 7. 読めない状態ファイル
h=$(new_home missing "")
run "${h}" 2026-10-22T03:00:00Z
expect_ages "状態ファイルが無ければ 9d を書き、claude は 1d で入れる (exit 0)" "${h}" 9d 1d
if grep -Fq 'mise-release-age.json' "${h}/warnings" && grep -Fq 'switch' "${h}/warnings"; then
  ok "状態ファイルが無いことを、switch を促して警告する"
else
  ng "状態ファイルが無いときの警告" "$(detail "${h}")"
fi

h=$(new_home no-jq "$(state 9d "${item_a}")")
run "${h}" 2026-10-22T03:00:00Z "${nojq_bin}"
expect_ages "jq が無ければ (上書き中の項目があっても) 9d を書き、claude は 1d で入れる (exit 0)" "${h}" 9d 1d
if grep -Fq 'jq' "${h}/warnings"; then
  ok "jq が無いことを警告する"
else
  ng "jq が無いときの警告" "$(detail "${h}")"
fi

for bad in "$(state 9d '{"from":"2026-02-30","zeroDays":1,"reason":""}')" "$(state 1w)"; do
  h=$(new_home "bad-$((pass + fail))" "${bad}")
  run "${h}" 2026-10-22T03:00:00Z
  expect_ages "形の違う状態ファイル (${bad}) なら 9d を書き、claude は 1d で入れる (exit 0)" "${h}" 9d 1d
  if grep -Fq 'mise-release-age.json' "${h}/warnings"; then
    ok "形の違う状態ファイル (${bad}) を警告する"
  else
    ng "形の違う状態ファイルの警告 (${bad})" "$(detail "${h}")"
  fi
done

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
