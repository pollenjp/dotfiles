#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-mise.sh が mise の遅延 (minimum_release_age) と、claude を入れるとき・cursor-agent の版を引くときの
# 遅延を、状態ファイル (~/.local/state/dotfiles/mise-release-age.json) と今の時刻から決めて書くことと、cursor-agent を
# ホストの option (~/.local/state/dotfiles/cursor-agent.json) に従って入れる・入れないことを、使い捨ての HOME と偽の
# checkout と偽の mise で確かめる。
#
#   bash nix/tests/bootstrap-mise.test.sh [<bootstrap-mise.sh のパス> [<cursor-agent の宣言の雛形のパス>]]
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
#   - cursor-agent が on (cursor-agent.json の enable が true) なら、どの遅延のケースでも、claude と同じ遅延の env で
#     mise latest cursor-agent を打って版を引き、その版を印つきの宣言 (~/.config/mise/conf.d/dotfiles-cursor-agent.toml)
#     に書いてから、env なしで mise install cursor-agent を打つ。mise upgrade cursor-agent・mise use -g cursor-agent は
#     打たない。宣言は、1 行目が印で、雛形の [tools.cursor-agent] の行から後ろの @version@ を版に替えたもの。conf.d が
#     無ければ作る
#   - on で 2 回続けて流すと、2 回目は宣言を書き換えず (同じファイルのまま)「のまま」と出し、install は打つ
#   - on で遅延を過ぎた版が無ければ今の宣言の版、宣言も無ければ入っている一番新しい版 (mise latest --installed) で書く。
#     どれも無ければ宣言を書かず、install も打たずに警告する
#   - on で遅延を過ぎた新しい版が出たら、宣言をその版に書き換える
#   - on で install が落ちたら、宣言を前の中身に戻し (前が無ければ消し)、警告する
#   - on で宣言の場所に手で置いたもの (印の無いファイル・印のあるファイルへの symlink・壊れた symlink) があれば、触らずに
#     警告し、版も引かず install も打たない
#   - on で mise latest が落ちても、今の宣言の版で入れる (警告しない)。形の合わない版 (TOML を壊す文字を含む版・数字で
#     始まらない語の latest) は使わず、宣言を書かずに警告する
#   - on で宣言の版が数字で始まらない語 (手で書いた latest) なら使わず、入っている一番新しい版で書き直す (警告しない)。
#     入っている版も無ければ、版を指していないその宣言を消して警告する (どちらでも latest の宣言を残さない)
#   - on で雛形が無い・形が違う (version = "@version@" の行が無い) ときは、宣言を書かずに警告する
#   - off (enable が false) なら cursor-agent を入れない。印つきの宣言は消し、手で置いたものは残す (どちらも警告しない)。
#     手で置いたものが無く、入っている版があれば、消し方 (mise uninstall --all cursor-agent) と、週 1 回の掃除で消えるのは
#     dotfiles.cleanup.enable のときだけであることを 1 行で知らせる
#   - cursor-agent.json が無い・形が違う ({"enable":"yes"}・{}・[]・空・JSON が 2 つ)・jq が無いときは、警告して宣言に
#     触らず、cursor-agent の mise は打たない
#   - cursor-agent の手順で何が起きても exit 0 で最後まで流れる (後ろの bootstrap を止めない)
#   - ヘッダの `# mise-tools:` (setup.sh が読み、残りの手作業の手順 5 で「setup が書く名前」として数えない) に、
#     mise use -g で ~/.config/mise/config.toml の [tools] に書く名前 (版を除く) を過不足なく並べている。足りないと
#     手順 5 が setup の書いた名前を手で消すよう出し、余ると setup が書かなくなった名前の残りを見逃す
#
# 偽の mise は、受けた env の MISE_MINIMUM_RELEASE_AGE と引数を「<env>|<引数>」の形で $HOME/mise.log に 1 行ずつ残す。
# FAKE_MISE_FAIL に引数の並び (例: install cursor-agent) を渡すと、その呼び出しだけ exit 1 で落ちる。latest cursor-agent
# には FAKE_MISE_LATEST (既定 2026.11.05-86047df。空なら何も出さない)、latest --installed cursor-agent には
# FAKE_MISE_INSTALLED (既定 空) を返す。install cursor-agent を受けたら、そのときの宣言を $HOME/decl-at-install に写す。
# 今の時刻は BOOTSTRAP_MISE_NOW (UNIX 秒) で渡す。偽の mise の shebang は $BASH から作る (Nix のサンドボックスには
# /usr/bin/env が無い)。script は自分のいる checkout の雛形を読むので、ケースごとの checkout (<HOME>/repo) に script と
# 雛形を写して流す。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-mise.sh}
template=${2:-${here}/../files/mise/conf.d/cursor-agent.toml}
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

# script が書く宣言の 1 行目の頭と、偽の mise が既定で返す版
mark='# dotfiles-managed: nix/scripts/bootstrap-mise.sh'
latest_default=2026.11.05-86047df

# 1 ケースぶんの HOME を作る。$1: 名前、$2: 遅延の状態ファイルの中身 (空なら作らない)、$3: cursor-agent の状態
# (on (省略時): {"enable":true}・off: {"enable":false}・none: 置かない・ほか: そのまま書く)。
# ~/.config/mise/conf.d は作らない (新しいマシンと同じ。前は home-manager の宣言が作っていた)
new_home() {
  local h="${work}/$1" cursor=${3-on}
  mkdir -p "${h}/bin" "${h}/.config/mise" "${h}/.local/state/dotfiles" "${h}/repo/nix/scripts" \
    "${h}/repo/nix/files/mise/conf.d"
  cp "${script}" "${h}/repo/nix/scripts/bootstrap-mise.sh"
  cp "${template}" "${h}/repo/nix/files/mise/conf.d/cursor-agent.toml"
  chmod u+w "${h}/repo/nix/scripts/bootstrap-mise.sh" "${h}/repo/nix/files/mise/conf.d/cursor-agent.toml"
  : >"${h}/.config/mise/config.toml"
  : >"${h}/mise.log"
  if [[ -n $2 ]]; then printf '%s\n' "$2" >"${h}/.local/state/dotfiles/mise-release-age.json"; fi
  case ${cursor} in
    on) printf '%s\n' '{"enable":true}' >"${h}/.local/state/dotfiles/cursor-agent.json" ;;
    off) printf '%s\n' '{"enable":false}' >"${h}/.local/state/dotfiles/cursor-agent.json" ;;
    none) ;;
    *) printf '%s\n' "${cursor}" >"${h}/.local/state/dotfiles/cursor-agent.json" ;;
  esac
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s|%s\n' "${MISE_MINIMUM_RELEASE_AGE-}" "$*" >>"${HOME}/mise.log"
# install のときの宣言を写す (落ちる呼び出しでも、受けた時点の宣言を残す)
if [[ $* == 'install cursor-agent' ]]; then
  decl="${XDG_CONFIG_HOME}/mise/conf.d/dotfiles-cursor-agent.toml"
  if [[ -e ${decl} ]]; then cp "${decl}" "${HOME}/decl-at-install"; fi
fi
if [[ -n ${FAKE_MISE_FAIL-} && $* == "${FAKE_MISE_FAIL}" ]]; then
  echo "偽の mise の失敗: $*" >&2
  exit 1
fi
case "$*" in
  'config ls'*) echo '{}' ;;
  'latest cursor-agent')
    if [[ -n ${FAKE_MISE_LATEST-} ]]; then printf '%s\n' "${FAKE_MISE_LATEST}"; fi
    ;;
  'latest --installed cursor-agent')
    if [[ -n ${FAKE_MISE_INSTALLED-} ]]; then printf '%s\n' "${FAKE_MISE_INSTALLED}"; fi
    ;;
esac
exit 0
EOF
  } >"${h}/bin/mise"
  chmod +x "${h}/bin/mise"
  echo "${h}"
}

# $1: HOME、$2: 今 (ISO 8601 の UTC)、$3: 偽の mise の後ろに続ける PATH (省けば今の PATH)。
# ケースの checkout の script を流す。setup から走るときと同じく、警告のまとめ用のファイルを渡す。
# 呼ぶ側の FAKE_MISE_FAIL・FAKE_MISE_LATEST・FAKE_MISE_INSTALLED は偽の mise へ渡す
run() {
  local h=$1 now
  now=$(at "$2")
  env -u MISE_MINIMUM_RELEASE_AGE HOME="${h}" XDG_CONFIG_HOME="${h}/.config" PATH="${h}/bin:${3:-${PATH}}" \
    BOOTSTRAP_MISE_NOW="${now}" DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_MISE_FAIL="${FAKE_MISE_FAIL-}" \
    FAKE_MISE_LATEST="${FAKE_MISE_LATEST-${latest_default}}" FAKE_MISE_INSTALLED="${FAKE_MISE_INSTALLED-}" \
    "${BASH}" "${h}/repo/nix/scripts/bootstrap-mise.sh" >"${h}/out" 2>"${h}/err"
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

# 宣言のパス
decl() { printf '%s' "$1/.config/mise/conf.d/dotfiles-cursor-agent.toml"; }
# 宣言 (ファイル $1) の版
decl_version() { sed -n 's/^version = "\(.*\)"$/\1/p' "$1"; }
# ファイル $1 が印つきの宣言 (symlink でない普通のファイルで、1 行目が印で始まる)
marked() { [[ -f $1 && ! -L $1 && $(head -n 1 "$1") == "${mark}"* ]]; }
# ファイル $1 の [tools.cursor-agent] の行から後ろ
body() { sed -n '/^\[tools\.cursor-agent\]$/,$p' "$1"; }
# 印つきの宣言 (前の setup が書いた形) の中身。$1: 版
ours_text() {
  printf '%s が書いた cursor-agent の宣言 (テストが置いた)\n' "${mark}"
  body "${template}" | sed "s/@version@/$1/"
}
# 印つきの宣言を HOME $1 に置く。$2: 版
place_ours() {
  mkdir -p "$1/.config/mise/conf.d"
  ours_text "$2" >"$(decl "$1")"
}
# 手で置いた (印の無い) 宣言を HOME $1 に置く
place_hand() {
  mkdir -p "$1/.config/mise/conf.d"
  printf '[tools.cursor-agent]\nversion = "2026.10.01-0000000"\n' >"$(decl "$1")"
}

# 偽の mise が受けた行と、出力と、宣言
detail() {
  printf 'rc=%s\n--- mise.log\n%s\n--- out\n%s\n--- err\n%s\n--- warnings\n%s\n--- 宣言\n%s' "$(cat "$1/rc")" \
    "$(cat "$1/mise.log")" "$(cat "$1/out")" "$(cat "$1/err")" "$(cat "$1/warnings" 2>/dev/null)" \
    "$(cat "$(decl "$1")" 2>/dev/null)"
}

# rc が 0 で、最後 (完了の行) まで流れた
finished() { [[ $(cat "$1/rc") == 0 ]] && grep -Fq '完了しました' "$1/out"; }

# ほかの settings と言語ランタイムは、遅延の env なしで打つ
others_plain() {
  local line
  for line in '|settings set lockfile true' '|settings set fetch_remote_versions_timeout 14d' \
    '|use -g aqua:jdx/usage' '|use -g go' '|use -g node@24'; do
    grep -Fxq -- "${line}" "$1/mise.log" || return 1
  done
}

# cursor-agent を on で入れた形か: env $2 で latest cursor-agent を打ち、その後で env なしの install cursor-agent を打ち、
# install のときの宣言が印つきで版が既定の版。upgrade と use -g は打たない。$1: HOME
cursor_lines() {
  local l i
  l=$(grep -nFx -- "$2|latest cursor-agent" "$1/mise.log" | cut -d: -f1)
  i=$(grep -nFx -- "|install cursor-agent" "$1/mise.log" | cut -d: -f1)
  [[ -n ${l} && -n ${i} && ${l} -lt ${i} ]] \
    && ! grep -Fq -- 'upgrade cursor-agent' "$1/mise.log" && ! grep -Fq -- 'use -g cursor-agent' "$1/mise.log" \
    && marked "$1/decl-at-install" && [[ $(decl_version "$1/decl-at-install") == "${latest_default}" ]]
}

# cursor-agent の mise を 1 つも打っていない
no_cursor_calls() { ! grep -Fq -- 'cursor-agent' "$1/mise.log"; }

# $3 が nocursor なら cursor-agent の mise を打っていないか、でなければ on で入れた形か (env $2)。$1: HOME
cursor_ok() {
  if [[ $3 == nocursor ]]; then
    no_cursor_calls "$1"
  else
    cursor_lines "$1" "$2"
  fi
}

# minimum_release_age に $3 を 1 回だけ書き、claude を env $4 で入れ、cursor-agent を env $4 で引いて入れ (第 5 引数が
# nocursor なら cursor-agent の mise は打たない)、ほかは env なしで打ち、exit 0 か。$1: ケースの名前、$2: HOME
expect_ages() {
  local name=$1 h=$2 setting=$3 claude=$4 cursor=${5-on} n
  n=$(grep -c -- '|settings set minimum_release_age ' "${h}/mise.log")
  if [[ $(cat "${h}/rc") == 0 && ${n} == 1 ]] \
    && grep -Fxq -- "|settings set minimum_release_age ${setting}" "${h}/mise.log" \
    && grep -Fxq -- "${claude}|use -g claude@latest" "${h}/mise.log" \
    && cursor_ok "${h}" "${claude}" "${cursor}" \
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
echo "== 雛形: ${template}"

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
expect_ages "from の日 (JST 10/22 12:00) は上限 ${cap} を書き、claude も上限で入れる (cursor-agent の版も上限で引く)" \
  "${h}" "${cap}" "${cap}"
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
  ng "終わった項目の警告" "$(detail "${h}")"
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
  ng "終わった項目だけの警告" "$(detail "${h}")"
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
expect_ages "jq が無ければ (上書き中の項目があっても) 9d を書き、claude は 1d で入れる (cursor-agent は打たない。exit 0)" \
  "${h}" 9d 1d nocursor
if grep -Fq 'jq' "${h}/warnings" && grep -Fq 'dotfiles.cursorAgent' "${h}/warnings"; then
  ok "jq が無いことを警告する (遅延と cursor-agent の両方)"
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

# 8. cursor-agent が on
h=$(new_home cursor-new "$(state 9d)")
run "${h}" 2026-11-10T03:00:00Z
d=$(decl "${h}")
expected=$(body "${template}" | sed "s/@version@/${latest_default}/")
if finished "${h}" && cursor_lines "${h}" 1d && marked "${d}" \
  && [[ $(decl_version "${d}") == "${latest_default}" && $(body "${d}") == "${expected}" ]] \
  && grep -Fxq 'bin_path = "bin"' "${d}" && grep -q '^postinstall = ' "${d}" && ! grep -Fq '@version@' "${d}" \
  && [[ $(cat "${d}") == "$(cat "${h}/decl-at-install")" ]] && no_warning "${h}" \
  && grep -Fq "${latest_default} を宣言に書いた" "${h}/out"; then
  ok "on: 遅延を過ぎた版を、印つきの宣言 (雛形の @version@ を替えたもの) に書いてから入れる (conf.d が無ければ作る)"
else
  ng "on: 遅延を過ぎた版" "$(detail "${h}")"
fi

# 2 回目 (同じ HOME で続けて流す)
first=$(cat "${d}")
inode=$(stat -c %i "${d}")
: >"${h}/mise.log"
rm -f "${h}/warnings" "${h}/decl-at-install"
run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && [[ $(cat "${d}") == "${first}" && $(stat -c %i "${d}") == "${inode}" ]] \
  && grep -Fq 'のまま' "${h}/out" && cursor_lines "${h}" 1d && no_warning "${h}"; then
  ok "on: 2 回続けて流すと、2 回目は宣言を書き換えず「のまま」と出し、install は打つ"
else
  ng "on: 2 回目" "$(detail "${h}")"
fi

h=$(new_home cursor-keep "$(state 9d)")
place_ours "${h}" 2026.11.01-aaaaaaa
FAKE_MISE_LATEST='' run "${h}" 2026-11-10T03:00:00Z
d=$(decl "${h}")
if finished "${h}" && marked "${d}" && [[ $(decl_version "${d}") == 2026.11.01-aaaaaaa ]] \
  && grep -Fxq '1d|latest cursor-agent' "${h}/mise.log" && ! grep -Fq 'latest --installed' "${h}/mise.log" \
  && grep -Fxq '|install cursor-agent' "${h}/mise.log" && no_warning "${h}"; then
  ok "on: 遅延を過ぎた版が無ければ、今の宣言の版で入れる (入っている版は引かない。警告しない)"
else
  ng "on: 遅延の中・宣言あり" "$(detail "${h}")"
fi

h=$(new_home cursor-installed "$(state 9d)")
FAKE_MISE_LATEST='' FAKE_MISE_INSTALLED=2026.11.05-86047df run "${h}" 2026-11-10T03:00:00Z
d=$(decl "${h}")
if finished "${h}" && marked "${d}" && [[ $(decl_version "${d}") == 2026.11.05-86047df ]] \
  && grep -Fxq '|latest --installed cursor-agent' "${h}/mise.log" && grep -Fxq '|install cursor-agent' "${h}/mise.log" \
  && no_warning "${h}"; then
  ok "on: 遅延を過ぎた版も宣言も無ければ、入っている一番新しい版で書いて入れる (前の作りで入れた版を拾う)"
else
  ng "on: 遅延の中・宣言なし・入っている版あり" "$(detail "${h}")"
fi

h=$(new_home cursor-none "$(state 9d)")
FAKE_MISE_LATEST='' FAKE_MISE_INSTALLED='' run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && [[ ! -e $(decl "${h}") ]] && ! grep -Fq 'install cursor-agent' "${h}/mise.log" \
  && grep -Fq '版を決められませんでした' "${h}/warnings"; then
  ok "on: 版が決まらなければ、宣言を書かず install も打たずに警告する (exit 0)"
else
  ng "on: 版が決まらない" "$(detail "${h}")"
fi

h=$(new_home cursor-newer "$(state 9d)")
place_ours "${h}" 2026.11.01-aaaaaaa
run "${h}" 2026-11-10T03:00:00Z
d=$(decl "${h}")
if finished "${h}" && marked "${d}" && [[ $(decl_version "${d}") == "${latest_default}" ]] \
  && grep -Fq '前は 2026.11.01-aaaaaaa' "${h}/out" && cursor_lines "${h}" 1d && no_warning "${h}"; then
  ok "on: 遅延を過ぎた新しい版が出たら、宣言をその版に書き換えて入れる"
else
  ng "on: 新しい版" "$(detail "${h}")"
fi

h=$(new_home cursor-install-fails "$(state 9d)")
place_ours "${h}" 2026.11.01-aaaaaaa
d=$(decl "${h}")
before=$(cat "${d}")
FAKE_MISE_FAIL='install cursor-agent' run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && [[ $(cat "${d}") == "${before}" ]] && marked "${d}" \
  && [[ $(decl_version "${h}/decl-at-install") == "${latest_default}" ]] \
  && grep -Fq '入れられませんでした' "${h}/warnings" && grep -Fq '2026.11.01-aaaaaaa' "${h}/warnings"; then
  ok "on: 新しい版の install が落ちたら、宣言を前の中身に戻して警告し、最後まで流れる (exit 0)"
else
  ng "on: install が落ちる (前の宣言あり)" "$(detail "${h}")"
fi

h=$(new_home cursor-install-fails-new "$(state 9d)")
FAKE_MISE_FAIL='install cursor-agent' run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && [[ ! -e $(decl "${h}") ]] && [[ $(decl_version "${h}/decl-at-install") == "${latest_default}" ]] \
  && grep -Fq '入れられませんでした' "${h}/warnings"; then
  ok "on: 前の宣言が無いときに install が落ちたら、書いた宣言を消して警告する (exit 0)"
else
  ng "on: install が落ちる (前の宣言なし)" "$(detail "${h}")"
fi

# 手で置いたもの: 印の無いファイル・印のあるファイルへの symlink・壊れた symlink
for kind in plain link dangling; do
  h=$(new_home "cursor-hand-${kind}" "$(state 9d)")
  d=$(decl "${h}")
  case ${kind} in
    plain) place_hand "${h}" ;;
    link)
      ours_text 2026.11.01-aaaaaaa >"${h}/elsewhere.toml"
      mkdir -p "${d%/*}"
      ln -s "${h}/elsewhere.toml" "${d}"
      ;;
    dangling)
      mkdir -p "${d%/*}"
      ln -s "${h}/nowhere.toml" "${d}"
      ;;
  esac
  before=$(stat -c %F "${d}")$(readlink "${d}")$(cat "${d}" 2>/dev/null)
  run "${h}" 2026-11-10T03:00:00Z
  after=$(stat -c %F "${d}")$(readlink "${d}")$(cat "${d}" 2>/dev/null)
  if finished "${h}" && [[ ${after} == "${before}" ]] && no_cursor_calls "${h}" && grep -Fq "${d}" "${h}/warnings"; then
    ok "on: 宣言の場所に手で置いたもの (${kind}) があれば、触らずに警告し、版も引かず install も打たない"
  else
    ng "on: 手で置いたもの (${kind})" "$(detail "${h}")"
  fi
done

h=$(new_home cursor-latest-fails "$(state 9d)")
place_ours "${h}" 2026.11.01-aaaaaaa
FAKE_MISE_FAIL='latest cursor-agent' run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && [[ $(decl_version "$(decl "${h}")") == 2026.11.01-aaaaaaa ]] \
  && grep -Fxq '|install cursor-agent' "${h}/mise.log" && no_warning "${h}" && grep -Fq '引けませんでした' "${h}/out"; then
  ok "on: mise latest が落ちても、今の宣言の版で入れる (1 行で知らせ、警告しない)"
else
  ng "on: mise latest が落ちる" "$(detail "${h}")"
fi

# 形の合わない版: TOML を壊す文字を含む版と、数字で始まらない語 (latest の宣言に戻さない)
for bad in '2026.11.05"x' latest; do
  h=$(new_home "cursor-bad-version-$((pass + fail))" "$(state 9d)")
  FAKE_MISE_LATEST=${bad} run "${h}" 2026-11-10T03:00:00Z
  if finished "${h}" && [[ ! -e $(decl "${h}") ]] && ! grep -Fq 'install cursor-agent' "${h}/mise.log" \
    && grep -Fq '形が違う' "${h}/warnings"; then
    ok "on: 形の合わない版 (${bad}) は使わず、宣言を書かずに警告する (exit 0)"
  else
    ng "on: 形の合わない版 (${bad})" "$(detail "${h}")"
  fi
done

# 印つきの宣言の版を手で latest にしたとき: その版は使わず、入っている版で書き直す。入っている版も無ければ、版を指して
# いない宣言を消す (どちらでも latest の宣言を残さない)
h=$(new_home cursor-hand-latest "$(state 9d)")
place_ours "${h}" latest
FAKE_MISE_LATEST='' FAKE_MISE_INSTALLED=2026.11.05-86047df run "${h}" 2026-11-10T03:00:00Z
d=$(decl "${h}")
if finished "${h}" && marked "${d}" && [[ $(decl_version "${d}") == 2026.11.05-86047df ]] \
  && grep -Fxq '|latest --installed cursor-agent' "${h}/mise.log" && grep -Fxq '|install cursor-agent' "${h}/mise.log" \
  && grep -Fq '版の形でない' "${h}/out" && no_warning "${h}"; then
  ok "on: 宣言の版が数字で始まらない語 (手で書いた latest) なら使わず、入っている版で書き直す (警告しない)"
else
  ng "on: 宣言の版が latest (入っている版あり)" "$(detail "${h}")"
fi

h=$(new_home cursor-hand-latest-none "$(state 9d)")
place_ours "${h}" latest
FAKE_MISE_LATEST='' FAKE_MISE_INSTALLED='' run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && [[ ! -e $(decl "${h}") ]] && ! grep -Fq 'install cursor-agent' "${h}/mise.log" \
  && grep -Fq '版を決められませんでした' "${h}/warnings" && grep -Fq '消しました' "${h}/warnings"; then
  ok "on: 宣言の版が latest で入っている版も無ければ、版を指していない宣言を消して警告する (exit 0)"
else
  ng "on: 宣言の版が latest (入っている版なし)" "$(detail "${h}")"
fi

for kind in missing latest; do
  h=$(new_home "cursor-template-${kind}" "$(state 9d)")
  t="${h}/repo/nix/files/mise/conf.d/cursor-agent.toml"
  case ${kind} in
    missing) rm -f "${t}" ;;
    latest) printf '[tools.cursor-agent]\nversion = "latest"\nbin_path = "bin"\n' >"${t}" ;;
  esac
  run "${h}" 2026-11-10T03:00:00Z
  if finished "${h}" && [[ ! -e $(decl "${h}") ]] && ! grep -Fq 'install cursor-agent' "${h}/mise.log" \
    && grep -Fq 'files/mise/conf.d/cursor-agent.toml' "${h}/warnings"; then
    ok "on: 雛形が ${kind} (無い / @version@ の行が無い) なら、宣言を書かずに警告する (exit 0)"
  else
    ng "on: 雛形が ${kind}" "$(detail "${h}")"
  fi
done

# 9. cursor-agent が off
h=$(new_home cursor-off-ours "$(state 9d)" off)
place_ours "${h}" 2026.11.01-aaaaaaa
run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && [[ ! -e $(decl "${h}") ]] && grep -Fq '消した' "${h}/out" \
  && [[ $(grep -F -- 'cursor-agent' "${h}/mise.log") == '|latest --installed cursor-agent' ]] && no_warning "${h}"; then
  ok "off: setup が書いた (印つきの) 宣言を消し、cursor-agent を入れない (警告しない)"
else
  ng "off: 印つきの宣言" "$(detail "${h}")"
fi

h=$(new_home cursor-off-hand "$(state 9d)" off)
place_hand "${h}"
before=$(cat "$(decl "${h}")")
run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && [[ $(cat "$(decl "${h}")") == "${before}" ]] && grep -Fq '残す' "${h}/out" \
  && no_cursor_calls "${h}" && no_warning "${h}"; then
  ok "off: 手で置いた (印の無い) 宣言は残し、1 行で知らせる (警告しない)"
else
  ng "off: 手で置いた宣言" "$(detail "${h}")"
fi

h=$(new_home cursor-off-left "$(state 9d)" off)
FAKE_MISE_INSTALLED=2026.11.05-86047df run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && grep -Fq 'mise uninstall --all cursor-agent' "${h}/out" && grep -Fq '2026.11.05-86047df' "${h}/out" \
  && grep -Fq 'dotfiles.cleanup.enable' "${h}/out" && ! grep -Fq 'install cursor-agent' "${h}/mise.log" && no_warning "${h}"; then
  ok "off: 入っている版が残っていれば、消し方 (mise uninstall --all cursor-agent) と、掃除で消えるのは dotfiles.cleanup.enable のときだけだと 1 行で知らせる (警告しない)"
else
  ng "off: 入っている版が残っている" "$(detail "${h}")"
fi

h=$(new_home cursor-off-clean "$(state 9d)" off)
run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && grep -Fq '入れない' "${h}/out" && ! grep -Fq 'mise uninstall' "${h}/out" && no_warning "${h}"; then
  ok "off: 入っている版が無ければ、消し方を出さない"
else
  ng "off: 入っている版が無い" "$(detail "${h}")"
fi

# 10. cursor-agent の状態ファイルを読めない
h=$(new_home cursor-nostate "$(state 9d)" none)
place_ours "${h}" 2026.11.01-aaaaaaa
before=$(cat "$(decl "${h}")")
run "${h}" 2026-11-10T03:00:00Z
if finished "${h}" && [[ $(cat "$(decl "${h}")") == "${before}" ]] && no_cursor_calls "${h}" \
  && grep -Fq 'cursor-agent.json' "${h}/warnings" && grep -Fq 'switch' "${h}/warnings"; then
  ok "cursor-agent.json が無ければ、switch を促して警告し、宣言に触らない (exit 0)"
else
  ng "cursor-agent.json が無い" "$(detail "${h}")"
fi

# '' は改行だけのファイル (jq は何も出さずに 0 で終わる)、2 つ目は JSON が 2 つ並んだファイル (jq は値を 2 行出す)
for bad in '{"enable":"yes"}' '{}' '[]' '' '{"enable":false} {"enable":true}'; do
  h=$(new_home "cursor-badstate-$((pass + fail))" "$(state 9d)" "${bad}")
  place_ours "${h}" 2026.11.01-aaaaaaa
  before=$(cat "$(decl "${h}")")
  run "${h}" 2026-11-10T03:00:00Z
  if finished "${h}" && [[ $(cat "$(decl "${h}")") == "${before}" ]] && no_cursor_calls "${h}" \
    && grep -Fq 'cursor-agent.json' "${h}/warnings"; then
    ok "形の違う cursor-agent.json (${bad}) なら、警告して宣言に触らない (exit 0)"
  else
    ng "形の違う cursor-agent.json (${bad})" "$(detail "${h}")"
  fi
done

# 11. ヘッダの `# mise-tools:` と、mise use -g で [tools] に書く名前 (版を除く) が同じ。ヘッダは setup.sh が読む
#     (script と setup.sh の間の取り決め) ので、ここで書く名前と突き合わせる
h=$(new_home mise-tools "$(state 9d)")
run "${h}" 2026-10-22T03:00:00Z
declared=$(sed -n 's/^#[[:space:]]*mise-tools:[[:space:]]*//p' "${script}" | tr -s '[:space:]' '\n' | sort)
written=$(sed -n 's/^[^|]*|use -g \([^@]*\).*$/\1/p' "${h}/mise.log" | sort)
if [[ $(cat "${h}/rc") == 0 && -n ${written} && ${declared} == "${written}" ]]; then
  ok "ヘッダの mise-tools: に、mise use -g で [tools] に書く名前 (版を除く) を過不足なく並べている"
else
  ng "ヘッダの mise-tools: (ヘッダ: ${declared//$'\n'/ } / 書いた名前: ${written//$'\n'/ })" "$(detail "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
