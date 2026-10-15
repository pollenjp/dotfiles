#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/setup.sh が最後に出すもの (「結果」の後の警告のまとめと、残りの手作業) を、
# 使い捨ての checkout と偽の手順で確かめる。
#
#   bash nix/tests/setup-post-notes.test.sh [<setup.sh のパス>]
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
#
# ## 作り
#
# setup.sh は自分の隣の bootstrap-*.sh を手順として並べるので、使い捨ての checkout
# (<ケース>/repo/nix/scripts/) に setup.sh を写し、偽の bootstrap-*.sh を置いて --steps で流す。
# 偽の手順は、子の script の warn() と同じ形 (見出しの行と、字下げした続きの行) で
# DOTFILES_SETUP_WARNINGS のファイルへ書く。shebang は $BASH から作る (サンドボックスに
# /usr/bin/env が無い)。PATH は要るコマンドだけを symlink で並べる (手元で流しても、本物の
# git・gh・nix を見せない)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
setup=${1:-${here}/../scripts/setup.sh}
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
for c in env jq awk sed grep sort head tr cat dirname basename readlink uname id mktemp mkdir rm chmod; do
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
    "${BASH}" "${c}/repo/nix/scripts/setup.sh" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}

rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
# 「結果」より後の stdout
after_result() { sed -n '/^==> 結果/,$p' "$1/out"; }
# 「残りの手作業」より後の stdout
after_post_notes() { sed -n '/^==> 残りの手作業/,$p' "$1/out"; }
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
if [[ $(rc "${c}") == 0 ]] && after_result "${c}" | grep -qx '⚠️  \[bootstrap-a\] 見出し A' \
  && after_result "${c}" | grep -qx '⚠️  \[bootstrap-c\] 見出し C'; then
  ok "子の手順の警告は、結果の後に [手順の id] を付けて出す"
else
  ng "子の手順の警告がまとめに出ない" "rc=$(rc "${c}") $(out "${c}")"
fi
if [[ $(line_after "${c}" '[bootstrap-a] 見出し A') =~ ^[[:space:]]+続き\ A1$ ]] \
  && grep -A2 -F '[bootstrap-a] 見出し A' "${c}/out" | sed -n '3p' | grep -qE '^[[:space:]]+続き A2$'; then
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
if [[ $(rc "${c}") == 1 ]] && after_result "${c}" | grep -qx '⚠️  \[bootstrap-a\] 見出し A' \
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
if [[ $(rc "${c}") == 0 ]] && after_result "${c}" | grep -q '^⚠️  \[本体の更新\] git の作業ツリーではないので更新できません'; then
  ok "--self-update で本体を更新しなかった理由は [本体の更新] で載る"
else
  ng "本体の更新の警告" "rc=$(rc "${c}") $(out "${c}") $(cat "${c}/err")"
fi

# 5. setup.sh の中の手順 (switch) の warn も載る。退避しない設定で ~/.bashrc が実ファイルなら警告する
#    (--dry-run なので switch は ✔ になる)。続きの行に、そのファイルが出る
c=$(new_case t5)
printf '# ディストリの初期ファイル\n' >"${c}/home/.bashrc"
run "${c}" --dry-run --host testhost --steps switch
if [[ $(rc "${c}") == 0 ]] && after_result "${c}" | grep -q '^⚠️  \[switch\] home-manager 管理下ではない実ファイルがあります' \
  && after_result "${c}" | grep -F "${c}/home/.bashrc" | grep -qE '^[[:space:]]+/'; then
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
if [[ $(rc "${c}") == 0 ]] && after_result "${c}" | grep -q '^⚠️  \[bootstrap-claude-env\] gh が見つかりません' \
  && ! after_post_notes "${c}" | grep -qE '\bgh\b'; then
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
if [[ $(rc "${c}") == 0 ]] && after_result "${c}" | grep -q '^⚠️  \[local-flake\] flake.nix が古い雛形のまま' \
  && ! after_post_notes "${c}" | grep -q '古い雛形'; then
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
if [[ $(rc "${c}") == 0 ]] && after_post_notes "${c}" | grep -q '古い雛形'; then
  ok "local-flake を流さないときは、残りの手作業で古い雛形を知らせる"
else
  ng "local-flake を流さないとき" "rc=$(rc "${c}") $(out "${c}")"
fi

# 9. switch が ✔ なら、その設定の home-manager の warnings (config.warnings) も [switch] で載る。
#    1 件目は末尾が改行の warning で、空白だけの続きの行ができる (それは出さない)
hm_out=$'notion.profile が未設定です。\n   規則に当たらない repo で止まります。\n   \nもう 1 件の warning'
c=$(new_case t9)
PATH_EXTRA=$(fake_hm_bin "${c}") FAKE_NIX_EVAL_OUT="${hm_out}" run "${c}" --host testhost --steps switch
if [[ $(rc "${c}") == 0 ]] && after_result "${c}" | grep -qx '⚠️  \[switch\] notion.profile が未設定です。' \
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
if [[ $(rc "${c}") == 0 ]] && grep -q 'config.warnings' "${c}/home/nix-calls" && ! after_post_notes "${c}" | grep -q '古い雛形'; then
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
if [[ $(rc "${c}") == 0 ]] && ! grep -q '途中で出た警告' "${c}/out" && after_post_notes "${c}" | grep -q '古い雛形'; then
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
if [[ $(rc "${c}") == 0 ]] && after_result "${c}" | grep -qE '^[[:space:]]+続き 6$' \
  && ! after_result "${c}" | grep -qE '^[[:space:]]+続き (7|12)$' \
  && after_result "${c}" | grep -qE '^[[:space:]]+続き 13$' && after_result "${c}" | grep -qE '^[[:space:]]+続き 15$' \
  && after_result "${c}" | grep -q '6 行を省いた'; then
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

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
