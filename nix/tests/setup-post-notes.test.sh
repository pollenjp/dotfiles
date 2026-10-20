#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/setup.sh が最後に出すもの (「結果」の後の警告のまとめと、残りの手作業) を、
# 使い捨ての checkout と偽の手順で確かめる。
#
#   bash nix/tests/setup-post-notes.test.sh [<nix/scripts のパス> | <setup.sh のパス>]
#
# nix/scripts のディレクトリを渡すと、雛形の版を見るケースのために、隣の local-flake-migrate.sh と
# setup-local-flake.sh も使う (setup.sh だけを渡したときは、そのケースを飛ばす)。
#
# flake の checks (setup-post-notes-test) が Nix のサンドボックスで流す。
#
# ## 確かめること
#
#   - 途中で出た警告 (DOTFILES_SETUP_WARNINGS のファイルに足された行) が、「結果」の後に ⚠ の枠で
#     まとめて出る。見出しの行には [手順の id] が付き、続きの行は字下げして下に並ぶ。
#     警告が無ければ何も出さない
#   - ✖ で止まった手順の警告は載せず、それより前の ✔ の手順の分は載せる
#   - --self-update で本体を更新しなかった理由 (setup.sh 自身の warn) は [本体の更新] で載る。
#     setup.sh の中の手順 (switch) の warn も載る
#   - switch が ✔ なら、その設定の home-manager の warnings (config.warnings を nix eval で読む) も
#     [switch] で載る。--dry-run では読まない。読めなければ黙って飛ばす
#   - bootstrap-claude-env の gh の警告は、まとめにだけ出る (残りの手作業で出し直さない)
#   - local-flake を流したとき・home-manager の warnings を読めたときは、古い雛形の案内を
#     残りの手作業で出し直さない (どちらでもなければ今どおり出す)
#   - 続きの行が長い警告は、頭と末尾 (直し方) を残して間を省く。空白だけの行は出さない
#   - 警告を溜めた一時ファイルを残さない (--self-update で本体を更新して exec し直すときも)
#   - gitViaGh のマシン (~/.local/state/dotfiles/git-via-gh.json の enable が true) では、origin が GitHub の
#     ssh の URL なら本体の更新の fetch を gh の資格情報 (git gh) で取る。git gh で取れず ssh (git) で取ったときの
#     警告は、本体を更新して exec し直したあとも [本体の更新] で載り、引き継ぎに使う変数は手順に渡らない。
#     exec されたのでない実行は、外から渡された引き継ぎの変数を読まない (TKT-221)
#   - origin が ssh の URL でない (https など) なら、gitViaGh のマシンでも gh を通さずに今までどおり git で取り、
#     fetch に失敗しても SSH 鍵の案内を付けない
#   - ローカル flake の「# 雛形の版:」の印が今の雛形と違えば (local-flake-migrate.sh check が 1)、手順が通ったときは
#     残りの手作業で「前の雛形から作られています」と移し方 (local-flake-migrate.sh prepare と skill) を知らせる。
#     印が同じなら出さない。local-flake を流したときは、setup-local-flake.sh の警告がまとめに載るので出さない
#   - switch が落ちたときは (残りの手作業は出ない)、印が今と違えば、失敗の案内のあとに、本体で option が削除・
#     改名されると旧い local のままでは評価が止まることと移し方を stderr に出す。印が同じなら出さない
#
# ## 作り
#
# setup.sh は自分の隣の bootstrap-*.sh を手順として並べるので、使い捨ての checkout
# (<ケース>/repo/nix/scripts/) に setup.sh を写し、偽の bootstrap-*.sh を置いて --steps で流す。
# 偽の手順は、子の script の warn() と同じ形 (見出しの行と、字下げした続きの行) で
# DOTFILES_SETUP_WARNINGS のファイルへ書く。shebang は $BASH から作る (サンドボックスに
# /usr/bin/env が無い)。PATH は要るコマンドだけを symlink で並べる (手元で流しても、本物の
# git・gh・nix を見せない)。switch の手順は、偽の home-manager (何もせず 0 を返す) と偽の nix
# (nix eval ならケースごとの warnings を返す) で流す。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
arg=${1:-${here}/../scripts}
if [[ -d ${arg} ]]; then
  scripts=${arg}
  setup=${arg}/setup.sh
else
  scripts=""
  setup=${arg}
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/setup-post-notes-test.XXXXXX")
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

# 要るコマンドだけを並べた PATH (git・gh・nix・home-manager は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq awk sed grep sort head tr cat dirname basename readlink uname id mktemp mkdir rm chmod cksum; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 1 ケースぶんの checkout と HOME を作り、その場所を出す。
#   <ケース>/repo/nix/scripts/setup.sh   写した setup.sh
#   <ケース>/repo/nix/hosts/default.nix  testhost だけの登録簿
#   <ケース>/home                         HOME
#   <ケース>/tmp                          TMPDIR (一時ファイルが残らないかを見る)
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/repo/nix/scripts" "${c}/repo/nix/hosts" "${c}/home" "${c}/tmp"
  cp "${setup}" "${c}/repo/nix/scripts/setup.sh"
  printf '{ mkHome }:\n{\n  testhost = mkHome {\n    username = "test";\n  };\n}\n' >"${c}/repo/nix/hosts/default.nix"
  echo "${c}"
}

# 偽の手順を置く。$1: ケース、$2: ファイル名 (bootstrap-a.sh など)、$3: 本体 (bash)
fake_step() {
  {
    printf '#!%s\n' "${BASH}"
    printf '# 偽の手順 (%s)\n' "$2"
    printf '%s\n' "$3"
  } >"$1/repo/nix/scripts/$2"
  chmod +x "$1/repo/nix/scripts/$2"
}

# 偽の home-manager と nix を置いた bin を作り、その場所を出す。home-manager は何もせず 0 を返す。
# nix は引数を <HOME>/nix-calls に書き、`nix eval` なら FAKE_NIX_EVAL_OUT を出して FAKE_NIX_EVAL_RC で
# 終わる (setup.sh が渡す --apply の整形を済ませた形を、そのまま渡す)。ほかの nix のコマンドは 0 を返す
fake_hm_bin() {
  local b="$1/fake-bin"
  mkdir -p "${b}"
  printf '#!%s\nexit 0\n' "${BASH}" >"${b}/home-manager"
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/nix-calls"
if [[ $1 == eval ]]; then
  [[ -z ${FAKE_NIX_EVAL_OUT-} ]] || printf '%s' "${FAKE_NIX_EVAL_OUT}"
  exit "${FAKE_NIX_EVAL_RC:-0}"
fi
exit 0
EOF
  } >"${b}/nix"
  chmod +x "${b}/home-manager" "${b}/nix"
  echo "${b}"
}

# DOTFILES_SETUP_WARNINGS へ子の warn() と同じ形で書く本体を作る。引数は 1 つが 1 行で、
# 2 つ目からは字下げした続きの行。子の warn() と同じく、変数が無ければ書かない
warn_body() {
  local line first=1 body=""
  for line in "$@"; do
    if ((first)); then
      body+="[[ -z \${DOTFILES_SETUP_WARNINGS-} ]] || printf '%s\\n' '${line}' >>\"\${DOTFILES_SETUP_WARNINGS}\""$'\n'
      first=0
    else
      body+="[[ -z \${DOTFILES_SETUP_WARNINGS-} ]] || printf '   %s\\n' '${line}' >>\"\${DOTFILES_SETUP_WARNINGS}\""$'\n'
    fi
  done
  printf '%s' "${body}"
}

# $1: ケース、残り: setup.sh の引数。stdout・stderr・終了コードを <ケース>/{out,err,rc} に残す。
# 環境変数 (PATH_EXTRA など) は呼び出し側で付ける
run() {
  local c=$1
  shift
  env -i HOME="${c}/home" USER=test TMPDIR="${c}/tmp" NO_COLOR=1 \
    PATH="${PATH_EXTRA:+${PATH_EXTRA}:}${sys_bin}" \
    DOTFILES_LOCAL_DIR="${c}/local" GIT_CONFIG_NOSYSTEM=1 \
    ${FAKE_NIX_EVAL_OUT+"FAKE_NIX_EVAL_OUT=${FAKE_NIX_EVAL_OUT}"} ${FAKE_NIX_EVAL_RC+"FAKE_NIX_EVAL_RC=${FAKE_NIX_EVAL_RC}"} \
    ${DOTFILES_SETUP_SELF_UPDATE_WARNINGS+"DOTFILES_SETUP_SELF_UPDATE_WARNINGS=${DOTFILES_SETUP_SELF_UPDATE_WARNINGS}"} \
    "${BASH}" "${c}/repo/nix/scripts/setup.sh" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}

rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
# 「結果」より後の stdout
after_result() { sed -n '/^==> 結果/,$p' "$1/out"; }
# 「残りの手作業」より後の stdout
after_post_notes() { sed -n '/^==> 残りの手作業/,$p' "$1/out"; }
# 判定の grep -q はパイプで受けず、<<< で渡す。sed から grep -q へパイプでつなぐと、grep が合って先に
# 抜けたあと sed が書こうとして SIGPIPE (141) で終わり、pipefail で「合わない」に見えることがある
# (check-test-grep-q.sh が CI の lint で落とす)。$1: ケース、残り: grep の引数
seen_after_result() {
  local c=$1
  shift
  grep -q "$@" <<<"$(after_result "${c}")"
}
seen_after_post_notes() {
  local c=$1
  shift
  grep -q "$@" <<<"$(after_post_notes "${c}")"
}
# 見出しの行 ($2) の次の行
line_after() { grep -A1 -F -- "$2" "$1/out" | sed -n '2p'; }
# 一時ファイルが残っていないか
tmp_left() { find "$1/tmp" -mindepth 1 2>/dev/null | head -5; }

echo "== setup.sh: 結果の後に出すもの (${setup})"

# 1. 警告が無ければ、まとめは出さない
c=$(new_case t1)
fake_step "${c}" bootstrap-a.sh 'echo "a を流した"'
run "${c}" --steps bootstrap-a
if [[ $(rc "${c}") == 0 ]] && grep -q '^==> 結果' "${c}/out" && ! grep -q '⚠️' "${c}/out"; then
  ok "警告が無ければ、まとめの枠は出さない"
else
  ng "警告が無い" "rc=$(rc "${c}") $(out "${c}")"
fi

# 2. 子の手順の警告が、結果の後に [id] 付きでまとめて出る。続きの行は字下げして見出しの下に並ぶ
c=$(new_case t2)
fake_step "${c}" bootstrap-a.sh "$(warn_body '見出し A' '続き A1' '続き A2')"
fake_step "${c}" bootstrap-b.sh 'echo "b は何も言わない"'
fake_step "${c}" bootstrap-c.sh "$(warn_body '見出し C')"
run "${c}" --steps bootstrap-a,bootstrap-b,bootstrap-c
if [[ $(rc "${c}") == 0 ]] && seen_after_result "${c}" -x '⚠️  \[bootstrap-a\] 見出し A' \
  && seen_after_result "${c}" -x '⚠️  \[bootstrap-c\] 見出し C'; then
  ok "子の手順の警告は、結果の後に [手順の id] を付けて出す"
else
  ng "子の手順の警告がまとめに出ない" "rc=$(rc "${c}") $(out "${c}")"
fi
if [[ $(line_after "${c}" '[bootstrap-a] 見出し A') =~ ^[[:space:]]+続き\ A1$ ]] \
  && [[ $(grep -A2 -F '[bootstrap-a] 見出し A' "${c}/out" | sed -n '3p') =~ ^[[:space:]]+続き\ A2$ ]]; then
  ok "続きの行は、見出しの下に字下げして並べる"
else
  ng "続きの行の並び" "$(out "${c}")"
fi
if grep -q '途中で出た警告が 2 件' "${c}/out"; then
  ok "件数は見出しの数で数える (続きの行は数えない)"
else
  ng "件数" "$(out "${c}")"
fi
if ! grep -q '\[bootstrap-b\]' "${c}/out"; then
  ok "警告を出さなかった手順は、まとめに載せない"
else
  ng "警告の無い手順が載っている" "$(out "${c}")"
fi
at_summary=$(grep -n '途中で出た警告' "${c}/out" | head -1 | cut -d: -f1)
at_result=$(grep -n '^==> 結果' "${c}/out" | head -1 | cut -d: -f1)
at_post=$(grep -n '^==> 残りの手作業' "${c}/out" | head -1 | cut -d: -f1)
if [[ -n ${at_summary} && -n ${at_result} && -n ${at_post} ]] && ((at_result < at_summary && at_summary < at_post)); then
  ok "まとめは結果と残りの手作業のあいだに出す"
else
  ng "まとめの位置" "$(out "${c}")"
fi
if [[ -z $(tmp_left "${c}") ]]; then
  ok "警告を溜めた一時ファイルを残さない"
else
  ng "一時ファイルが残っている" "$(tmp_left "${c}")"
fi

# 3. ✖ で止まったとき: それより前の ✔ の手順の警告は出し、✖ の手順の警告は載せない
c=$(new_case t3)
fake_step "${c}" bootstrap-a.sh "$(warn_body '見出し A')"
fake_step "${c}" bootstrap-b.sh "$(warn_body '見出し B')"$'\n''exit 1'
run "${c}" --steps bootstrap-a,bootstrap-b
if [[ $(rc "${c}") == 1 ]] && seen_after_result "${c}" -x '⚠️  \[bootstrap-a\] 見出し A' \
  && ! grep -q '見出し B' "${c}/out"; then
  ok "✖ で止まっても、それより前の ✔ の手順の警告は出し、✖ の手順の分は載せない"
else
  ng "✖ で止まったとき" "rc=$(rc "${c}") $(out "${c}")"
fi
if [[ -z $(tmp_left "${c}") ]]; then
  ok "✖ で止まっても一時ファイルを残さない"
else
  ng "✖ で止まると一時ファイルが残る" "$(tmp_left "${c}")"
fi

# 4. --self-update で本体を更新しなかった理由 (setup.sh 自身の warn) は [本体の更新] で載る
c=$(new_case t4)
fake_step "${c}" bootstrap-a.sh 'echo "a を流した"'
run "${c}" --self-update --steps bootstrap-a
if [[ $(rc "${c}") == 0 ]] && seen_after_result "${c}" '^⚠️  \[本体の更新\] git の作業ツリーではないので更新できません'; then
  ok "--self-update で本体を更新しなかった理由は [本体の更新] で載る"
else
  ng "本体の更新の警告" "rc=$(rc "${c}") $(out "${c}") $(cat "${c}/err")"
fi

# 5. setup.sh の中の手順 (switch) の warn も載る。退避しない設定で ~/.bashrc が実ファイルなら警告する
#    (--dry-run なので switch は ✔ になる)。続きの行に、そのファイルが出る
c=$(new_case t5)
printf '# ディストリの初期ファイル\n' >"${c}/home/.bashrc"
run "${c}" --dry-run --host testhost --steps switch
if [[ $(rc "${c}") == 0 ]] && seen_after_result "${c}" '^⚠️  \[switch\] home-manager 管理下ではない実ファイルがあります' \
  && grep -qE '^[[:space:]]+/' <<<"$(after_result "${c}" | grep -F "${c}/home/.bashrc")"; then
  ok "setup.sh の中の手順 (switch) の warn も、続きの行ごと載る"
else
  ng "switch の warn" "rc=$(rc "${c}") $(out "${c}") $(cat "${c}/err")"
fi

# 6. bootstrap-claude-env の gh の警告は、まとめにだけ出る (残りの手作業で出し直さない)
c=$(new_case t6)
mkdir -p "${c}/home/.local/state/dotfiles"
printf '%s\n' '{"managed":["credential.https://github.com.helper"],"gitConfig":[{"k":"credential.https://github.com.helper","v":"!gh auth git-credential"}]}' \
  >"${c}/home/.local/state/dotfiles/claude-env.json"
fake_step "${c}" bootstrap-claude-env.sh "$(warn_body 'gh が見つかりません。Claude の git は gh の資格情報で GitHub へ HTTPS で通します。' 'gh auth login するか、gitViaGh.enable = false にしてください。')"
run "${c}" --steps bootstrap-claude-env
if [[ $(rc "${c}") == 0 ]] && seen_after_result "${c}" '^⚠️  \[bootstrap-claude-env\] gh が見つかりません' \
  && ! seen_after_post_notes "${c}" -E '\bgh\b'; then
  ok "gh の警告はまとめにだけ出し、残りの手作業で出し直さない"
else
  ng "gh の警告" "rc=$(rc "${c}") $(out "${c}")"
fi

# 7. local-flake を流したときは、古い雛形の案内を残りの手作業で出し直さない
#    (偽の setup-local-flake.sh が古い雛形の flake.nix を置き、本物と同じく警告する)
old_flake='{ inputs.dotfiles.url = "path:/somewhere/nix"; outputs = { dotfiles, ... }: dotfiles; }'
c=$(new_case t7)
fake_step "${c}" setup-local-flake.sh "mkdir -p \"\${DOTFILES_LOCAL_DIR}\"
printf '%s\\n' '${old_flake}' >\"\${DOTFILES_LOCAL_DIR}/flake.nix\"
$(warn_body 'flake.nix が古い雛形のままです (dotfiles.lib.hostsWith / local が無い)。')"
run "${c}" --steps local-flake
if [[ $(rc "${c}") == 0 ]] && seen_after_result "${c}" '^⚠️  \[local-flake\] flake.nix が古い雛形のまま' \
  && ! seen_after_post_notes "${c}" '古い雛形'; then
  ok "local-flake を流したときは、古い雛形の案内をまとめにだけ出す"
else
  ng "local-flake を流したとき" "rc=$(rc "${c}") $(out "${c}")"
fi

# 8. local-flake を流さないときは、今どおり残りの手作業で古い雛形を知らせる
c=$(new_case t8)
mkdir -p "${c}/local"
printf '%s\n' "${old_flake}" >"${c}/local/flake.nix"
fake_step "${c}" bootstrap-a.sh 'echo "a を流した"'
run "${c}" --steps bootstrap-a
if [[ $(rc "${c}") == 0 ]] && seen_after_post_notes "${c}" '古い雛形'; then
  ok "local-flake を流さないときは、残りの手作業で古い雛形を知らせる"
else
  ng "local-flake を流さないとき" "rc=$(rc "${c}") $(out "${c}")"
fi

# 9. switch が ✔ なら、その設定の home-manager の warnings (config.warnings) も [switch] で載る。
#    1 件目は末尾が改行の warning で、空白だけの続きの行ができる (それは出さない)
hm_out=$'notion.profile が未設定です。\n   規則に当たらない repo で止まります。\n   \nもう 1 件の warning'
c=$(new_case t9)
PATH_EXTRA=$(fake_hm_bin "${c}") FAKE_NIX_EVAL_OUT="${hm_out}" run "${c}" --host testhost --steps switch
if [[ $(rc "${c}") == 0 ]] && seen_after_result "${c}" -x '⚠️  \[switch\] notion.profile が未設定です。' \
  && [[ $(line_after "${c}" '[switch] notion.profile が未設定です。') =~ ^[[:space:]]+規則に当たらない ]] \
  && [[ $(line_after "${c}" '規則に当たらない repo で止まります。') == '⚠️  [switch] もう 1 件の warning' ]] \
  && grep -q '途中で出た警告が 2 件' "${c}/out" && grep -q 'config.warnings' "${c}/home/nix-calls"; then
  ok "switch が ✔ なら home-manager の warnings も [switch] で載る (空白だけの行は出さない)"
else
  ng "home-manager の warnings" "rc=$(rc "${c}") calls=$(cat "${c}/home/nix-calls" 2>/dev/null) $(out "${c}") $(cat "${c}/err")"
fi

# 10. home-manager の warnings を読めたときは、残りの手作業で古い雛形を出し直さない
#     (notion.profile が未設定なら、あちらがまとめに載る。local の無い古い雛形でも同じ warning が出る)
c=$(new_case t10)
mkdir -p "${c}/local"
printf '%s\n' "${old_flake}" >"${c}/local/flake.nix"
PATH_EXTRA=$(fake_hm_bin "${c}") FAKE_NIX_EVAL_OUT='' run "${c}" --host testhost --steps switch
if [[ $(rc "${c}") == 0 ]] && grep -q 'config.warnings' "${c}/home/nix-calls" && ! seen_after_post_notes "${c}" '古い雛形'; then
  ok "home-manager の warnings を読めたときは、残りの手作業で古い雛形を出し直さない"
else
  ng "warnings を読めたとき" "rc=$(rc "${c}") $(out "${c}") $(cat "${c}/err")"
fi

# 11. home-manager の warnings を読めない (nix eval が失敗する) ときは黙って飛ばし、
#     残りの手作業は今どおり古い雛形を知らせる
c=$(new_case t11)
mkdir -p "${c}/local"
printf '%s\n' "${old_flake}" >"${c}/local/flake.nix"
PATH_EXTRA=$(fake_hm_bin "${c}") FAKE_NIX_EVAL_RC=1 run "${c}" --host testhost --steps switch
if [[ $(rc "${c}") == 0 ]] && ! grep -q '途中で出た警告' "${c}/out" && seen_after_post_notes "${c}" '古い雛形'; then
  ok "home-manager の warnings を読めなければ黙って飛ばし、残りの手作業で古い雛形を知らせる"
else
  ng "warnings を読めないとき" "rc=$(rc "${c}") $(out "${c}") $(cat "${c}/err")"
fi

# 12. --dry-run では switch しないので、home-manager の warnings も読まない
c=$(new_case t12)
PATH_EXTRA=$(fake_hm_bin "${c}") FAKE_NIX_EVAL_OUT='読まれないはずの warning' run "${c}" --dry-run --host testhost --steps switch
if [[ $(rc "${c}") == 0 ]] && ! grep -qs 'eval' "${c}/home/nix-calls" && ! grep -q '読まれないはずの' "${c}/out"; then
  ok "--dry-run では home-manager の warnings を読まない"
else
  ng "--dry-run の warnings" "rc=$(rc "${c}") calls=$(cat "${c}/home/nix-calls" 2>/dev/null) $(out "${c}")"
fi

# 13. 続きの行が長い警告 (pwsh.exe の出力ごと残したものなど) は、頭の 6 行と末尾の 3 行 (直し方) を
#     残して間を省き、省いた行の数を出す
c=$(new_case t13)
long=('長い見出し')
for ((i = 1; i <= 15; i++)); do long+=("続き ${i}"); done
fake_step "${c}" bootstrap-a.sh "$(warn_body "${long[@]}")"
run "${c}" --steps bootstrap-a
if [[ $(rc "${c}") == 0 ]] && seen_after_result "${c}" -E '^[[:space:]]+続き 6$' \
  && ! seen_after_result "${c}" -E '^[[:space:]]+続き (7|12)$' \
  && seen_after_result "${c}" -E '^[[:space:]]+続き 13$' && seen_after_result "${c}" -E '^[[:space:]]+続き 15$' \
  && seen_after_result "${c}" '6 行を省いた'; then
  ok "続きの行が長い警告は、頭と末尾を残して間を省き、省いた行の数を出す"
else
  ng "長い警告" "rc=$(rc "${c}") $(out "${c}")"
fi

# 14. --self-update で本体を更新できたら、新しい setup.sh で exec し直す。exec では EXIT の trap が
#     走らないので、その前に警告を溜める場所を片付ける (exec した先は自分で作って消す)
tgit() {
  HOME="${work}/githome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -c user.name=tester -c user.email=tester@example.test -c init.defaultBranch=main -c commit.gpgsign=false "$@"
}
git_bin="${work}/git-bin"
mkdir -p "${git_bin}" "${work}/githome"
ln -sf "$(command -v git)" "${git_bin}/git"
c=$(new_case t14)
# exec し直すときは shebang で起動する (サンドボックスに /usr/bin/env が無いので $BASH にする)
sed -i "1s|.*|#!${BASH}|" "${c}/repo/nix/scripts/setup.sh"
fake_step "${c}" bootstrap-a.sh 'echo "a を流した"'
tgit init -q --bare "${c}/origin.git"
tgit -C "${c}/repo" init -q
tgit -C "${c}/repo" add -A
tgit -C "${c}/repo" commit -qm init
tgit -C "${c}/repo" remote add origin "${c}/origin.git"
tgit -C "${c}/repo" push -q -u origin main 2>/dev/null
tgit clone -q "${c}/origin.git" "${c}/other"
printf 'next\n' >"${c}/other/next.txt"
tgit -C "${c}/other" add next.txt
tgit -C "${c}/other" commit -qm next
tgit -C "${c}/other" push -q 2>/dev/null
PATH_EXTRA="${git_bin}" run "${c}" --self-update --steps bootstrap-a
if [[ $(rc "${c}") == 0 && -f ${c}/repo/next.txt ]] && grep -q '新しい setup.sh で続けます' "${c}/out" \
  && grep -q 'a を流した' "${c}/out" && ! grep -q '途中で出た警告' "${c}/out" && [[ -z $(tmp_left "${c}") ]]; then
  ok "--self-update で本体を更新して exec し直しても、警告を溜めた一時ファイルを残さない"
else
  ng "本体を更新して exec し直すとき" "rc=$(rc "${c}") left=$(tmp_left "${c}") $(out "${c}") $(cat "${c}/err")"
fi

# 本体の更新で、origin が 1 commit 進んでいる checkout を作り、その場所を出す (14 番と同じ組み立て)。
# $1: ケースの名前、$2: 偽の手順 bootstrap-a.sh の本体 (checkout に commit するので、後から変えない)、
# $3: origin の URL の形 (ssh なら GitHub の ssh の URL にし、repo の insteadOf で手元の bare repo へ向ける。
# path なら手元の bare repo のパスのまま (https などの、ssh でない origin の代わり))。
# HOME に {"enable":true} の状態ファイルを置く (gitViaGh のマシン)
new_update_case() {
  local c
  c=$(new_case "$1")
  sed -i "1s|.*|#!${BASH}|" "${c}/repo/nix/scripts/setup.sh"
  fake_step "${c}" bootstrap-a.sh "$2"
  mkdir -p "${c}/home/.local/state/dotfiles"
  printf '{"enable":true}\n' >"${c}/home/.local/state/dotfiles/git-via-gh.json"
  tgit init -q --bare "${c}/origin.git"
  tgit -C "${c}/repo" init -q
  tgit -C "${c}/repo" add -A
  tgit -C "${c}/repo" commit -qm init
  if [[ ${3:-ssh} == ssh ]]; then
    tgit -C "${c}/repo" remote add origin git@github.com:pollenjp/dotfiles.git
    tgit -C "${c}/repo" config "url.${c}/origin.git.insteadOf" git@github.com:pollenjp/dotfiles.git
  else
    tgit -C "${c}/repo" remote add origin "${c}/origin.git"
  fi
  tgit -C "${c}/repo" push -q -u origin main 2>/dev/null
  tgit clone -q "${c}/origin.git" "${c}/other"
  printf 'next\n' >"${c}/other/next.txt"
  tgit -C "${c}/other" add next.txt
  tgit -C "${c}/other" commit -qm next
  tgit -C "${c}/other" push -q 2>/dev/null
  echo "${c}"
}

# 偽の gh と git-gh を置いた bin を作り、その場所を出す。$1: ケース、$2: git-gh が落ちるか (1 / 0)。
# gh は何にでも 0 を返す (ログイン済み)。git-gh は引数を <ケース>/gitgh.log に書き、落ちないなら本物の git に
# 渡す。run は env -i で流すので、書き留め先は中に書き込む
fake_gh_bin() {
  local b="$1/gh-bin"
  mkdir -p "${b}"
  printf '#!%s\nexit 0\n' "${BASH}" >"${b}/gh"
  {
    printf '#!%s\n' "${BASH}"
    printf 'printf '\''%%s\\n'\'' "$*" >>'\''%s'\''\n' "$1/gitgh.log"
    if [[ $2 == 1 ]]; then
      printf '%s\n' 'echo "git-gh (偽物): gh の資格情報で通れませんでした" >&2' 'exit 128'
    else
      printf '%s\n' 'exec git "$@"'
    fi
  } >"${b}/git-gh"
  chmod +x "${b}/gh" "${b}/git-gh"
  echo "${b}"
}

# 15. gitViaGh のマシン: 本体の更新の fetch を gh の資格情報 (git gh) で取り、警告は出さない
c=$(new_update_case t15 'echo "a を流した"')
gb=$(fake_gh_bin "${c}" 0)
PATH_EXTRA="${gb}:${git_bin}" run "${c}" --self-update --steps bootstrap-a
if [[ $(rc "${c}") == 0 && -f ${c}/repo/next.txt ]] && grep -q 'fetch origin main' "${c}/gitgh.log" 2>/dev/null \
  && grep -q 'gh の資格情報 (HTTPS) で取りました。' "${c}/out" && grep -q 'a を流した' "${c}/out" \
  && ! grep -q '途中で出た警告' "${c}/out" && [[ -z $(tmp_left "${c}") ]]; then
  ok "gitViaGh のマシンでは、本体の更新の fetch を gh の資格情報 (git gh) で取る"
else
  ng "本体の更新を gh で取る" "rc=$(rc "${c}") log=$(cat "${c}/gitgh.log" 2>/dev/null) $(out "${c}") $(cat "${c}/err")"
fi

# 16. git gh で取れず ssh (git) で取った: 本体を更新して exec し直したあとも [本体の更新] で載る。
#     引き継ぎに使う変数は、exec した先で手順に渡らない
# shellcheck disable=SC2016 # 偽の手順の中で展開する (手順に変数が渡っていないかを見る)
c=$(new_update_case t16 'echo "carried=${DOTFILES_SETUP_SELF_UPDATE_WARNINGS-unset}"')
gb=$(fake_gh_bin "${c}" 1)
PATH_EXTRA="${gb}:${git_bin}" run "${c}" --self-update --steps bootstrap-a
if [[ $(rc "${c}") == 0 && -f ${c}/repo/next.txt ]] && grep -q '新しい setup.sh で続けます' "${c}/out" \
  && seen_after_result "${c}" '^⚠️  \[本体の更新\] gh の資格情報では取れず、ssh (ssh-agent) で取りました。' \
  && seen_after_result "${c}" 'gh auth status で確かめてください' \
  && grep -q 'carried=unset' "${c}/out" && [[ -z $(tmp_left "${c}") ]]; then
  ok "gh で取れず ssh で取った本体の更新の警告は、exec し直したあとも [本体の更新] で載り、手順には渡らない"
else
  ng "exec をまたぐ本体の更新の警告" "rc=$(rc "${c}") left=$(tmp_left "${c}") $(out "${c}") $(cat "${c}/err")"
fi

# 17. exec されたのでない実行は、外から渡された引き継ぎの変数を読まない
c=$(new_case t17)
fake_step "${c}" bootstrap-a.sh 'echo "a を流した"'
DOTFILES_SETUP_SELF_UPDATE_WARNINGS='外から渡した警告' run "${c}" --steps bootstrap-a
if [[ $(rc "${c}") == 0 ]] && ! grep -q '外から渡した警告' "${c}/out" && ! grep -q '途中で出た警告' "${c}/out"; then
  ok "exec されたのでない実行は、外から渡された引き継ぎの変数を読まない"
else
  ng "外から渡された引き継ぎの変数" "rc=$(rc "${c}") $(out "${c}")"
fi

# 18. origin が GitHub の ssh の URL でない (https など): gitViaGh のマシンでも gh を通さず、今までどおり git で取る
c=$(new_update_case t18 'echo "a を流した"' path)
gb=$(fake_gh_bin "${c}" 0)
PATH_EXTRA="${gb}:${git_bin}" run "${c}" --self-update --steps bootstrap-a
if [[ $(rc "${c}") == 0 && -f ${c}/repo/next.txt && ! -e ${c}/gitgh.log ]] && ! grep -q 'gh の資格情報' "${c}/out" \
  && ! grep -q '途中で出た警告' "${c}/out"; then
  ok "origin が ssh の URL でなければ、gitViaGh のマシンでも gh を通さずに本体を取る"
else
  ng "ssh でない origin" "rc=$(rc "${c}") log=$(cat "${c}/gitgh.log" 2>/dev/null) $(out "${c}") $(cat "${c}/err")"
fi

# 19. ssh でない origin の fetch に失敗した: 警告に SSH 鍵の案内を付けない (ssh を通っていないため)
c=$(new_case t19)
fake_step "${c}" bootstrap-a.sh 'echo "a を流した"'
tgit -C "${c}/repo" init -q
tgit -C "${c}/repo" add -A
tgit -C "${c}/repo" commit -qm init
tgit -C "${c}/repo" remote add origin "${c}/無い.git"
tgit -C "${c}/repo" config branch.main.remote origin
tgit -C "${c}/repo" config branch.main.merge refs/heads/main
PATH_EXTRA="${git_bin}" run "${c}" --self-update --steps bootstrap-a
if [[ $(rc "${c}") == 0 ]] && seen_after_result "${c}" '^⚠️  \[本体の更新\] fetch に失敗しました' \
  && ! seen_after_result "${c}" 'SSH 鍵'; then
  ok "ssh でない origin の fetch に失敗しても、SSH 鍵の案内は付けない"
else
  ng "ssh でない origin の fetch の失敗" "rc=$(rc "${c}") $(out "${c}") $(cat "${c}/err")"
fi

# ---- ローカル flake の雛形の版 (setup.sh だけを渡したときは飛ばす) ----
if [[ -n ${scripts} ]]; then
  # ケースの checkout に local-flake-migrate.sh と本物の setup-local-flake.sh を写す (サンドボックスでは store から
  # 写すので読み取り専用になる。偽の手順で上書きできるよう、書き込みの権限を足す)
  with_migrate() {
    cp "${scripts}/local-flake-migrate.sh" "${scripts}/setup-local-flake.sh" "$1/repo/nix/scripts/"
    chmod u+w "$1/repo/nix/scripts/local-flake-migrate.sh" "$1/repo/nix/scripts/setup-local-flake.sh"
  }
  # 今の雛形の印
  current_id() { "${BASH}" "$1/repo/nix/scripts/local-flake-migrate.sh" id; }
  # 印 ($2) を持つローカル flake を置く (hostsWith と notion.profile も書き、ほかの案内を出させない)
  local_with_marker() {
    mkdir -p "$1/local"
    printf '# 雛形の版: %s\n{\n  inputs.dotfiles.url = "path:%s/repo/nix";\n  # dotfiles.lib.hostsWith / dotfiles.claude.notion.profile\n}\n' \
      "$2" "$1" >"$1/local/flake.nix"
  }
  # 何もせず 1 を返す偽の home-manager の bin
  failing_hm_bin() {
    local b="$1/failing-bin"
    mkdir -p "${b}"
    printf '#!%s\nexit 1\n' "${BASH}" >"${b}/home-manager"
    printf '#!%s\nexit 0\n' "${BASH}" >"${b}/nix"
    chmod +x "${b}/home-manager" "${b}/nix"
    echo "${b}"
  }

  # 20. 手順が通り、ローカル flake の印が前の版 → 残りの手作業に「前の雛形から作られています」と移し方
  c=$(new_case t20)
  with_migrate "${c}"
  local_with_marker "${c}" 0badf00d
  fake_step "${c}" bootstrap-a.sh 'echo "a を流した"'
  run "${c}" --steps bootstrap-a
  if [[ $(rc "${c}") == 0 ]] && seen_after_post_notes "${c}" -F "flake.nix は前の雛形から作られています (雛形の版 0badf00d → $(current_id "${c}"))" \
    && seen_after_post_notes "${c}" -F "local-flake-migrate.sh prepare --flake ${c}/local" \
    && seen_after_post_notes "${c}" -F 'pjp-dotfiles-local-flake-migrate'; then
    ok "印が前の版なら、残りの手作業で前の雛形から作られていることと移し方を知らせる"
  else
    ng "前の版の印 (残りの手作業)" "rc=$(rc "${c}") $(after_post_notes "${c}") $(cat "${c}/err")"
  fi

  # 21. 印が今と同じ → 出さない
  c=$(new_case t21)
  with_migrate "${c}"
  local_with_marker "${c}" "$(current_id "${c}")"
  fake_step "${c}" bootstrap-a.sh 'echo "a を流した"'
  run "${c}" --steps bootstrap-a
  if [[ $(rc "${c}") == 0 ]] && ! seen_after_post_notes "${c}" '前の雛形'; then
    ok "印が今の雛形と同じなら、残りの手作業に出さない"
  else
    ng "同じ印 (残りの手作業)" "rc=$(rc "${c}") $(after_post_notes "${c}")"
  fi

  # 22. local-flake の手順を選んだ → 残りの手作業には出さない (setup-local-flake.sh の警告がまとめに載る)。
  #     偽の setup-local-flake.sh は本物と同じく警告し、流れない heredoc を持つ (印はそこから決まる)
  c=$(new_case t22)
  with_migrate "${c}"
  local_with_marker "${c}" 0badf00d
  # shellcheck disable=SC2016 # 偽の手順の中に heredoc の原文をそのまま書く
  fake_step "${c}" setup-local-flake.sh "$(warn_body 'flake.nix は前の雛形から作られています (雛形の版 0badf00d → 偽)。')"'
if false; then
  cat >"${flake_file}" <<EOS
偽の雛形
EOS
fi'
  run "${c}" --steps local-flake
  if [[ $(rc "${c}") == 0 ]] && seen_after_result "${c}" '^⚠️  \[local-flake\] flake.nix は前の雛形から作られています' \
    && ! seen_after_post_notes "${c}" '前の雛形'; then
    ok "local-flake を流したときは、前の雛形の案内をまとめにだけ出す"
  else
    ng "local-flake を流したとき (前の雛形)" "rc=$(rc "${c}") $(out "${c}") $(cat "${c}/err")"
  fi

  # 23. switch が落ち、印が前の版 → 失敗の案内のあとに、option の削除・改名と移し方を stderr に出す
  c=$(new_case t23)
  with_migrate "${c}"
  local_with_marker "${c}" 0badf00d
  PATH_EXTRA=$(failing_hm_bin "${c}") run "${c}" --host testhost --steps switch
  at_fail=$(grep -n '失敗した手順があります' "${c}/err" | head -1 | cut -d: -f1)
  at_hint=$(grep -n 'は前の雛形から作られています' "${c}/err" | head -1 | cut -d: -f1)
  if [[ $(rc "${c}") == 1 && -n ${at_fail} && -n ${at_hint} ]] && ((at_fail < at_hint)) \
    && grep -q '削除・改名' "${c}/err" && grep -qF "local-flake-migrate.sh prepare --flake ${c}/local" "${c}/err" \
    && grep -qF "${c}/repo/nix/files/claude/skills/pjp-dotfiles-local-flake-migrate/SKILL.md" "${c}/err"; then
    ok "switch が落ち、印が前の版なら、失敗の案内のあとに option の削除・改名と移し方 (repo の SKILL.md の場所も) を出す"
  else
    ng "switch が落ちたとき (前の版)" "rc=$(rc "${c}") $(cat "${c}/err")"
  fi

  # 24. switch が落ちても、印が今と同じなら出さない
  c=$(new_case t24)
  with_migrate "${c}"
  local_with_marker "${c}" "$(current_id "${c}")"
  PATH_EXTRA=$(failing_hm_bin "${c}") run "${c}" --host testhost --steps switch
  if [[ $(rc "${c}") == 1 ]] && grep -q '失敗した手順があります' "${c}/err" && ! grep -q '前の雛形' "${c}/err"; then
    ok "switch が落ちても、印が今の雛形と同じなら前の雛形の案内は出さない"
  else
    ng "switch が落ちたとき (同じ印)" "rc=$(rc "${c}") $(cat "${c}/err")"
  fi
else
  echo "  (setup.sh だけを渡したので、ローカル flake の雛形の版のケースは飛ばす)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
